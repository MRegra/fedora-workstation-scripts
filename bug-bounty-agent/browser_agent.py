#!/usr/bin/env python3
"""
AI-driven browser testing agent for bug bounty hunting.

Claude autonomously navigates web applications to find:
IDOR, auth bypass, privilege escalation, stored XSS, CSRF,
business logic flaws, mass assignment, sensitive data exposure.

Cost-optimized: Haiku for navigation decisions, Opus for analysis.
Playwright for browser control (headless Chromium).

Usage:
  python3 browser_agent.py --scope scope.yaml --url https://app.example.com
  python3 browser_agent.py --scope scope.yaml --url https://app.example.com --mode idor
  python3 browser_agent.py --scope scope.yaml --url https://app.example.com --mode logic
  python3 browser_agent.py --scope scope.yaml --url https://app.example.com --mode auth

  # Run all modes on all live hosts from orchestrator state:
  python3 browser_agent.py --scope scope.yaml --from-state output/state.json

Modes:
  discovery  Map all pages, API calls, find attack surface (default)
  idor       Two-session IDOR testing with test accounts
  logic      Business logic: pricing, quotas, roles, step-skipping
  auth       Login flows, OAuth, password reset, session management

Install:
  pip3 install playwright anthropic
  playwright install chromium

Env vars:
  ANTHROPIC_API_KEY   required
  OLLAMA_URL          optional — for pre-filtering page content
  OLLAMA_MODEL        optional
"""

import argparse
import asyncio
import base64
import json
import logging
import os
import re
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Optional
from urllib.parse import urlparse

import anthropic
import requests
import yaml

try:
    from playwright.async_api import async_playwright, Page, BrowserContext
    _HAS_PLAYWRIGHT = True
except ImportError:
    _HAS_PLAYWRIGHT = False

CLAUDE_NAV_MODEL = "claude-haiku-4-5-20251001"   # cheap: navigation decisions
CLAUDE_ANALYSIS_MODEL = "claude-opus-4-8"          # thorough: vulnerability analysis
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434")
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "llama3.3:70b")
MAX_STEPS = 40          # max tool calls per session
MAX_SESSIONS = 3        # max browser sessions (for IDOR: one per test account)
NETWORK_LOG_LIMIT = 15  # most recent network requests to include

log = logging.getLogger("browser_agent")

# ---------------------------------------------------------------------------
# Tool definitions for Claude
# ---------------------------------------------------------------------------

BROWSER_TOOLS = [
    {
        "name": "navigate",
        "description": (
            "Navigate to a URL. Use this to move between pages. "
            "Only URLs within the allowed scope will be followed."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "url": {"type": "string"},
            },
            "required": ["url"],
        },
    },
    {
        "name": "get_page_state",
        "description": (
            "Get the current page's visible text, URL, and recent network requests. "
            "Use this to understand what's on the current page and what API calls it made."
        ),
        "input_schema": {"type": "object", "properties": {}},
    },
    {
        "name": "screenshot",
        "description": "Take a screenshot. Use sparingly — only when visual context is needed.",
        "input_schema": {"type": "object", "properties": {}},
    },
    {
        "name": "click",
        "description": "Click an element. Provide a CSS selector OR visible text content.",
        "input_schema": {
            "type": "object",
            "properties": {
                "selector": {
                    "type": "string",
                    "description": "CSS selector (e.g. '#submit-btn') or text (e.g. 'Login')",
                },
            },
            "required": ["selector"],
        },
    },
    {
        "name": "fill",
        "description": "Fill an input field with a value.",
        "input_schema": {
            "type": "object",
            "properties": {
                "selector": {"type": "string", "description": "CSS selector for the input"},
                "value": {"type": "string"},
            },
            "required": ["selector", "value"],
        },
    },
    {
        "name": "submit_form",
        "description": "Press Enter on the focused element or click the nearest submit button.",
        "input_schema": {"type": "object", "properties": {}},
    },
    {
        "name": "evaluate_js",
        "description": (
            "Run JavaScript in the page context and return the result. "
            "Use for: reading localStorage/sessionStorage, checking cookies, "
            "getting element values not accessible via selectors."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "code": {"type": "string", "description": "JavaScript expression to evaluate"},
            },
            "required": ["code"],
        },
    },
    {
        "name": "new_session",
        "description": (
            "Create a new isolated browser session with fresh cookies/storage. "
            "Use for IDOR testing: create session for each test account."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "session_id": {
                    "type": "string",
                    "description": "Identifier for this session (e.g. 'account_a', 'account_b')",
                },
            },
            "required": ["session_id"],
        },
    },
    {
        "name": "switch_session",
        "description": "Switch the active browser session.",
        "input_schema": {
            "type": "object",
            "properties": {
                "session_id": {"type": "string"},
            },
            "required": ["session_id"],
        },
    },
    {
        "name": "get_all_links",
        "description": "Get all links on the current page. Useful for mapping application structure.",
        "input_schema": {"type": "object", "properties": {}},
    },
    {
        "name": "intercept_next_request",
        "description": (
            "Flag the next network request for detailed inspection "
            "(full headers, body, response). Call this before an action that makes a request."
        ),
        "input_schema": {"type": "object", "properties": {}},
    },
    {
        "name": "report_finding",
        "description": (
            "Report a confirmed security vulnerability. "
            "Only call this when you have verified evidence — not suspicion."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Clear, specific vulnerability title"},
                "type": {
                    "type": "string",
                    "enum": [
                        "idor", "xss-stored", "xss-reflected", "auth-bypass",
                        "privilege-escalation", "business-logic", "csrf",
                        "mass-assignment", "sensitive-data-exposure",
                        "broken-access-control", "open-redirect", "other",
                    ],
                },
                "severity": {
                    "type": "string",
                    "enum": ["critical", "high", "medium", "low"],
                },
                "url": {"type": "string", "description": "Affected URL or endpoint"},
                "description": {"type": "string", "description": "What the vulnerability is"},
                "steps_to_reproduce": {
                    "type": "string",
                    "description": "Exact, numbered steps a stranger can follow to reproduce",
                },
                "impact": {
                    "type": "string",
                    "description": "What an attacker could realistically do — be specific",
                },
                "poc_evidence": {
                    "type": "string",
                    "description": "The specific evidence that confirms this: response content, IDs, payload that fired, etc.",
                },
            },
            "required": ["name", "type", "severity", "url", "description",
                         "steps_to_reproduce", "impact"],
        },
    },
    {
        "name": "done",
        "description": "Signal that testing for this target is complete.",
        "input_schema": {
            "type": "object",
            "properties": {
                "summary": {
                    "type": "string",
                    "description": "What was tested and what was found (or not found)",
                },
            },
            "required": ["summary"],
        },
    },
]


# ---------------------------------------------------------------------------
# System prompts by mode
# ---------------------------------------------------------------------------

def _system_prompt(mode: str, scope_domains: list[str], program_name: str,
                   test_accounts: list[dict]) -> str:
    scope_str = ", ".join(scope_domains)
    accounts_str = ""
    if test_accounts and len(test_accounts) >= 2:
        a, b = test_accounts[0], test_accounts[1]
        accounts_str = (
            f"\nTest accounts (use ONLY these — never real user data):\n"
            f"  Account A: {a.get('username')} / {a.get('password')}\n"
            f"  Account B: {b.get('username')} / {b.get('password')}\n"
        )

    base = f"""You are an expert bug bounty researcher with authorization to test {program_name}.
You are finding security vulnerabilities — this is authorized by the program's safe harbor policy.

Allowed scope: {scope_str}
{accounts_str}
Non-negotiable constraints:
- NEVER visit URLs outside the allowed scope
- NEVER exfiltrate real user data — note the vulnerability, do not extract the data
- XSS PoC: use alert(document.domain) ONLY — never harvest credentials
- IDOR: only test with your own two test accounts — never access real user data
- No destructive actions (deleting data, modifying others' accounts)
- No DoS testing

When you find a vulnerability, call report_finding immediately with full evidence.
When testing is complete, call done with a summary.
"""

    mode_instructions = {
        "discovery": """
DISCOVERY MODE — Map the application's attack surface.

Strategy:
1. Navigate the app as an unauthenticated user first — note all public pages
2. Look for: login/register, password reset, OAuth, API calls (check network log)
3. Note any IDs in URLs (/user/123, /api/order/456) — mark for IDOR testing
4. Check all forms for XSS: inject <img src=x onerror=alert(document.domain)> in text fields
5. Look at the network log after each page — are APIs returning more data than displayed?
6. Check for: debug endpoints (/debug, /env, /.git), admin paths (/admin, /dashboard)
7. Inspect localStorage and sessionStorage for tokens/sensitive data
8. Look for sensitive data in page source (API keys, internal paths)

Report any confirmed findings immediately. Cover as many pages as possible within step budget.
""",
        "idor": """
IDOR MODE — Find Insecure Direct Object References using two test accounts.

Strategy:
1. Create session "account_a" — log in as Account A
2. Navigate the app, collect all URLs with numeric/UUID IDs — /api/users/ID, /orders/ID etc.
3. Note Account A's profile ID, order IDs, document IDs, etc. from the network log
4. Create session "account_b" — log in as Account B
5. With session B active, try accessing Account A's resources:
   - Navigate to URLs with A's IDs
   - Call API endpoints that returned A's data, from B's session
6. If B can access A's private data → IDOR confirmed

Look for IDORs in:
- User profiles (/users/{id})
- Orders/invoices (/orders/{id})
- Documents/files (/files/{id})
- Messages (/messages/{id})
- Settings (/settings?user={id})
- API endpoints returning user-specific data

For each confirmed IDOR: exactly what URL, what A's ID was, what data B could see.
""",
        "logic": """
BUSINESS LOGIC MODE — Find vulnerabilities in application logic.

Strategy (test each that applies to the app):
1. Price/quantity manipulation:
   - Add items to cart, modify quantity to 0 or negative before checkout
   - Change price values in request if shown in parameters
   - Apply discount codes multiple times

2. Step skipping:
   - Multi-step flows (checkout, verification) — try accessing step 3 URL directly
   - Can you complete a purchase without payment?
   - Can you get a verified badge without completing verification?

3. Role/privilege escalation:
   - Register as normal user, check if you can access admin paths (/admin/*)
   - Change role parameter in requests (role=admin, is_admin=true)
   - Check if normal user API tokens work on admin endpoints

4. Feature restriction bypass:
   - Features disabled in the UI — are the underlying API calls still allowed?
   - Rate limits — test if they apply consistently

5. Mass assignment:
   - Add extra fields to POST requests (is_admin, verified, balance, credits)
   - If the app accepts them, report what changed

For each issue: exact steps, request/response that proves it.
""",
        "auth": """
AUTH MODE — Find authentication and session management vulnerabilities.

Strategy:
1. Password reset flow:
   - Request reset for Account A's email
   - Check reset link — is the token predictable?
   - Does the token expire?
   - Can you reset another user's password by manipulating the email parameter?
   - Host header injection: send reset with X-Forwarded-Host: evil.com — does link contain evil.com?

2. OAuth/SSO (if present):
   - Check redirect_uri parameter — can you change it to an attacker domain?
   - State parameter — is it present and validated (CSRF protection)?
   - Check the access_token — does it leak in Referer header after OAuth?

3. Session management:
   - After logout, check if old session token still works (via evaluate_js + navigate)
   - Check cookie flags: Secure, HttpOnly, SameSite
   - After password change, are old sessions invalidated?

4. Registration:
   - Can you register with admin@yourdomain.com or existing user emails?
   - SQL injection in registration fields: admin'--
   - XSS in name/username fields that appear in admin views?

5. Login:
   - Username enumeration: does "wrong password" vs "user not found" differ?
   - Brute force protection: does it exist?
   - SQL injection: ' OR '1'='1 in username field

Report all confirmed issues immediately with exact evidence.
""",
    }

    return base + mode_instructions.get(mode, mode_instructions["discovery"])


# ---------------------------------------------------------------------------
# Browser executor
# ---------------------------------------------------------------------------

class BrowserExecutor:
    """Manages Playwright browser state and executes tool calls from Claude."""

    def __init__(self, scope: dict, output_dir: Path):
        self.scope = scope
        self.output_dir = output_dir
        self.playwright = None
        self.browser = None
        self.contexts: dict[str, BrowserContext] = {}
        self.pages: dict[str, Page] = {}
        self.current_session = "default"
        self.network_logs: dict[str, list[dict]] = {}
        self.intercept_next = False
        self.intercepted: Optional[dict] = None
        self.ss_dir = output_dir / "browser_screenshots"
        self.ss_dir.mkdir(parents=True, exist_ok=True)

    async def setup(self):
        self.playwright = await async_playwright().start()
        self.browser = await self.playwright.chromium.launch(
            headless=True,
            args=["--no-sandbox", "--disable-dev-shm-usage"],
        )
        await self._new_context("default")

    async def _new_context(self, session_id: str) -> None:
        ctx = await self.browser.new_context(
            viewport={"width": 1280, "height": 800},
            user_agent="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36",
            ignore_https_errors=True,
        )
        page = await ctx.new_page()
        self.network_logs[session_id] = []

        async def on_request(req):
            if self.current_session == session_id:
                entry = {"url": req.url, "method": req.method}
                if req.post_data:
                    entry["body"] = req.post_data[:500]
                self.network_logs[session_id].append(entry)
                if len(self.network_logs[session_id]) > 100:
                    self.network_logs[session_id] = self.network_logs[session_id][-50:]

        async def on_response(resp):
            if self.intercept_next and self.current_session == session_id:
                try:
                    body = await resp.text()
                    self.intercepted = {
                        "url": resp.url, "status": resp.status,
                        "headers": dict(resp.headers), "body": body[:2000],
                    }
                    self.intercept_next = False
                except Exception:
                    pass

        page.on("request", on_request)
        page.on("response", on_response)
        self.contexts[session_id] = ctx
        self.pages[session_id] = page

    async def teardown(self):
        if self.browser:
            await self.browser.close()
        if self.playwright:
            await self.playwright.stop()

    @property
    def _page(self) -> Page:
        return self.pages[self.current_session]

    def _is_in_scope(self, url: str) -> bool:
        if url.startswith(("http://", "https://")):
            host = urlparse(url).hostname or ""
        else:
            host = url.split(":")[0]
        host = host.lower().strip()
        excluded = [d.lower() for d in self.scope.get("in_scope", {}).get("exclude", [])]
        for excl in excluded:
            if host == excl or host.endswith("." + excl):
                return False
        for domain in self.scope.get("in_scope", {}).get("domains", []):
            domain = domain.lower()
            if domain.startswith("*."):
                if host.endswith("." + domain[2:]):
                    return True
            elif host == domain:
                return True
        return False

    async def execute(self, tool_name: str, tool_input: dict) -> dict:
        try:
            if tool_name == "navigate":
                url = tool_input["url"]
                if not self._is_in_scope(url):
                    return {"error": f"Out of scope: {url} — skipped"}
                await self._page.goto(url, wait_until="domcontentloaded", timeout=15000)
                await self._page.wait_for_timeout(1500)
                return {"url": self._page.url, "title": await self._page.title()}

            elif tool_name == "get_page_state":
                text = await self._page.inner_text("body")
                net = self.network_logs.get(self.current_session, [])[-NETWORK_LOG_LIMIT:]
                return {
                    "url": self._page.url,
                    "title": await self._page.title(),
                    "text": text[:4000],
                    "network_requests": net,
                    "intercepted": self.intercepted,
                }

            elif tool_name == "screenshot":
                name = f"{self.current_session}_{int(time.time())}.png"
                path = self.ss_dir / name
                await self._page.screenshot(path=str(path), full_page=False)
                data = base64.b64encode(path.read_bytes()).decode()
                return {"screenshot_path": str(path), "base64": data[:50000]}

            elif tool_name == "click":
                sel = tool_input["selector"]
                try:
                    await self._page.click(sel, timeout=5000)
                except Exception:
                    # Try by text
                    try:
                        await self._page.get_by_text(sel).first.click(timeout=5000)
                    except Exception as exc:
                        return {"error": str(exc)}
                await self._page.wait_for_timeout(800)
                return {"clicked": sel, "url": self._page.url}

            elif tool_name == "fill":
                sel, value = tool_input["selector"], tool_input["value"]
                await self._page.fill(sel, value, timeout=5000)
                return {"filled": sel, "value": value}

            elif tool_name == "submit_form":
                await self._page.keyboard.press("Enter")
                await self._page.wait_for_timeout(1000)
                return {"url": self._page.url}

            elif tool_name == "evaluate_js":
                result = await self._page.evaluate(tool_input["code"])
                return {"result": str(result)[:2000]}

            elif tool_name == "get_all_links":
                links = await self._page.evaluate("""
                    () => [...document.querySelectorAll('a[href]')]
                        .map(a => ({text: a.textContent.trim().slice(0,60), href: a.href}))
                        .filter(l => l.href.startsWith('http'))
                        .slice(0, 50)
                """)
                in_scope = [l for l in links if self._is_in_scope(l["href"])]
                return {"links": in_scope, "total": len(links)}

            elif tool_name == "new_session":
                sid = tool_input["session_id"]
                if sid not in self.contexts and len(self.contexts) < MAX_SESSIONS:
                    await self._new_context(sid)
                self.current_session = sid
                return {"session": sid, "created": True}

            elif tool_name == "switch_session":
                sid = tool_input["session_id"]
                if sid in self.pages:
                    self.current_session = sid
                    return {"session": sid, "url": self._page.url}
                return {"error": f"Session {sid} not found"}

            elif tool_name == "intercept_next_request":
                self.intercept_next = True
                self.intercepted = None
                return {"intercepting": True}

            elif tool_name == "report_finding":
                return {"reported": True, "finding": tool_input}

            elif tool_name == "done":
                return {"done": True, "summary": tool_input.get("summary", "")}

            else:
                return {"error": f"Unknown tool: {tool_name}"}

        except Exception as exc:
            return {"error": str(exc)[:300]}


# ---------------------------------------------------------------------------
# Agent loop
# ---------------------------------------------------------------------------

async def run_browser_session(
    url: str,
    mode: str,
    scope: dict,
    output_dir: Path,
    test_accounts: list[dict],
    client: anthropic.Anthropic,
) -> list[dict]:
    """
    Run one Claude-guided browser testing session on a URL.
    Returns list of reported findings.
    """
    if not _HAS_PLAYWRIGHT:
        log.error("playwright not installed: pip3 install playwright && playwright install chromium")
        return []

    executor = BrowserExecutor(scope, output_dir)
    await executor.setup()

    program_name = scope.get("program", {}).get("name", "Unknown Program")
    scope_domains = scope.get("in_scope", {}).get("domains", [])
    system = _system_prompt(mode, scope_domains, program_name, test_accounts)
    findings: list[dict] = []

    messages = [{
        "role": "user",
        "content": (
            f"Target: {url}\nMode: {mode}\n\n"
            f"Start testing. Navigate to the target and begin the {mode} strategy. "
            f"You have {MAX_STEPS} tool calls. Use them efficiently."
        ),
    }]

    # Use haiku for nav steps, track when to switch to opus for analysis
    nav_step_count = 0
    analysis_triggers = {"report_finding", "done", "screenshot"}

    log.info("Browser agent [%s] starting on %s (mode=%s)", CLAUDE_NAV_MODEL, url, mode)

    try:
        for step in range(MAX_STEPS):
            # Choose model: haiku for cheap navigation, opus when analyzing
            use_model = CLAUDE_ANALYSIS_MODEL if nav_step_count > 10 else CLAUDE_NAV_MODEL

            resp = client.messages.create(
                model=use_model,
                max_tokens=1024,
                system=system,
                tools=BROWSER_TOOLS,
                messages=messages,
            )

            # Collect tool calls
            tool_calls = [b for b in resp.content if b.type == "tool_use"]
            text_blocks = [b for b in resp.content if b.type == "text"]

            if text_blocks:
                log.debug("Claude: %s", text_blocks[0].text[:200])

            if not tool_calls or resp.stop_reason == "end_turn":
                log.info("Browser agent done (end_turn at step %d)", step)
                break

            # Build assistant message and execute tools
            messages.append({"role": "assistant", "content": resp.content})
            tool_results = []

            for tc in tool_calls:
                log.debug("[%d] %s(%s)", step, tc.name, json.dumps(tc.input)[:100])
                result = await executor.execute(tc.name, tc.input)

                if tc.name in analysis_triggers:
                    nav_step_count += 5  # push toward opus
                else:
                    nav_step_count += 1

                if tc.name == "report_finding" and "finding" in result:
                    f = result["finding"]
                    f["poc_status"] = "confirmed"
                    f["poc_source"] = "browser_agent"
                    f["host"] = url
                    f["name"] = f.get("name", "Browser agent finding")
                    findings.append(f)
                    log.info("Finding reported: [%s] %s", f.get("severity", "?"), f.get("name"))

                if tc.name == "done":
                    log.info("Browser agent: %s", result.get("summary", "")[:200])
                    break

                # Convert screenshots to vision content
                if tc.name == "screenshot" and "base64" in result:
                    tool_results.append({
                        "type": "tool_result",
                        "tool_use_id": tc.id,
                        "content": [
                            {"type": "image", "source": {
                                "type": "base64", "media_type": "image/png",
                                "data": result["base64"],
                            }},
                            {"type": "text", "text": f"Screenshot taken: {result.get('screenshot_path')}"},
                        ],
                    })
                else:
                    tool_results.append({
                        "type": "tool_result",
                        "tool_use_id": tc.id,
                        "content": json.dumps(result)[:3000],
                    })

                if tc.name == "done":
                    break

            messages.append({"role": "user", "content": tool_results})

            # Trim message history to avoid massive context (keep first + last 16)
            if len(messages) > 20:
                messages = messages[:2] + messages[-16:]

    finally:
        await executor.teardown()

    return findings


# ---------------------------------------------------------------------------
# Ollama pre-filter: check if a page is worth deep testing
# ---------------------------------------------------------------------------

def ollama_worth_testing(url: str, page_text: str) -> bool:
    """Quick Ollama check: is this page interesting enough for deep browser testing?"""
    prompt = f"""Is this web page interesting for security testing?
URL: {url}
Content (excerpt): {page_text[:500]}

A page is interesting if it has: forms, user IDs in the URL, authenticated content,
payment/checkout flows, file uploads, search functionality, API calls with user data,
admin features, or other attack surface.

Reply with ONLY: YES or NO"""
    try:
        resp = requests.post(f"{OLLAMA_URL}/api/generate",
                             json={"model": OLLAMA_MODEL, "prompt": prompt, "stream": False},
                             timeout=30)
        return "YES" in resp.json().get("response", "NO").upper()
    except Exception:
        return True  # if Ollama is down, test everything


# ---------------------------------------------------------------------------
# Main entrypoint
# ---------------------------------------------------------------------------

async def _async_main(args, scope: dict, output_dir: Path) -> list[dict]:
    if not _HAS_PLAYWRIGHT:
        log.error("Install: pip3 install playwright && playwright install chromium")
        sys.exit(1)

    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not api_key:
        log.error("ANTHROPIC_API_KEY not set")
        sys.exit(1)

    client = anthropic.Anthropic(api_key=api_key)
    test_accounts = scope.get("test_accounts", {}).get("accounts", [])
    all_findings: list[dict] = []

    # Determine targets
    urls: list[str] = []
    if args.url:
        urls = [args.url]
    elif args.from_state:
        state_path = Path(args.from_state)
        if state_path.exists():
            state = json.loads(state_path.read_text())
            live = state.get("live_hosts", [])
            urls = [
                (h.get("url", h) if isinstance(h, dict) else h)
                for h in live[:20]  # cap overnight run at 20 hosts
            ]
    else:
        log.error("Provide --url or --from-state")
        sys.exit(1)

    modes = args.mode.split(",") if "," in args.mode else [args.mode]

    for url in urls:
        for mode in modes:
            log.info("=== %s | %s | %s ===", url, mode, datetime.now().isoformat())
            try:
                findings = await run_browser_session(
                    url, mode, scope, output_dir, test_accounts, client
                )
                all_findings.extend(findings)
                log.info("Found %d issue(s) on %s [%s]", len(findings), url, mode)
            except Exception as exc:
                log.exception("Error on %s [%s]: %s", url, mode, exc)

    # Save findings
    out_path = output_dir / f"browser_findings_{datetime.now().strftime('%Y%m%d-%H%M%S')}.json"
    out_path.write_text(json.dumps(all_findings, indent=2))
    log.info("Browser agent complete: %d total findings → %s", len(all_findings), out_path)

    return all_findings


def main():
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s [%(levelname)s] %(message)s")

    parser = argparse.ArgumentParser()
    parser.add_argument("--scope", required=True)
    parser.add_argument("--url", help="Single target URL")
    parser.add_argument("--from-state", help="Path to orchestrator state.json")
    parser.add_argument("--mode",
                        default="discovery",
                        help="discovery | idor | logic | auth (comma-separated for multiple)")
    args = parser.parse_args()

    with open(args.scope) as f:
        scope = yaml.safe_load(f)
    output_dir = Path(scope.get("output", {}).get("directory", "./output"))
    output_dir.mkdir(parents=True, exist_ok=True)

    findings = asyncio.run(_async_main(args, scope, output_dir))
    print(f"\nFindings: {len(findings)}")
    for f in findings:
        print(f"  [{f.get('severity','?').upper()}] {f.get('name','?')}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
Playwright MCP server — expose browser tools to Claude Code directly.

This lets you type in Claude Code: "Use the browser to test https://target.com for IDOR"
and Claude will drive a real Chromium browser to navigate and test.

Setup (~/.claude/mcp.json):
  {
    "mcpServers": {
      "browser": {
        "command": "python3",
        "args": ["/absolute/path/to/playwright_mcp_server.py"],
        "env": {
          "BROWSER_HEADLESS": "true",
          "ALLOWED_DOMAINS": "example.com,api.example.com"
        }
      }
    }
  }

Env vars:
  BROWSER_HEADLESS   true|false (default: true)
  ALLOWED_DOMAINS    comma-separated allowed domains (enforces scope)
  SCREENSHOT_DIR     where to save screenshots (default: /tmp/bb_screenshots)
"""

import base64
import json
import os
import sys
import time
from pathlib import Path
from typing import Optional
from urllib.parse import urlparse

try:
    from playwright.sync_api import sync_playwright, Page, Browser, BrowserContext
    _HAS_PW = True
except ImportError:
    _HAS_PW = False

HEADLESS = os.environ.get("BROWSER_HEADLESS", "true").lower() != "false"
ALLOWED_RAW = os.environ.get("ALLOWED_DOMAINS", "")
ALLOWED_DOMAINS = [d.strip().lower() for d in ALLOWED_RAW.split(",") if d.strip()]
SS_DIR = Path(os.environ.get("SCREENSHOT_DIR", "/tmp/bb_screenshots"))
SS_DIR.mkdir(parents=True, exist_ok=True)

# --- Global browser state ---
_pw = None
_browser: Optional[Browser] = None
_contexts: dict[str, BrowserContext] = {}
_pages: dict[str, Page] = {}
_current: str = "default"
_net_log: dict[str, list] = {}


def _init_browser():
    global _pw, _browser
    if not _HAS_PW:
        return False
    if _browser is None:
        _pw = sync_playwright().start()
        _browser = _pw.chromium.launch(headless=HEADLESS,
                                        args=["--no-sandbox"])
    return True


def _ensure_session(sid: str = "default"):
    if sid not in _contexts:
        ctx = _browser.new_context(
            viewport={"width": 1280, "height": 800},
            ignore_https_errors=True,
            user_agent="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36",
        )
        page = ctx.new_page()
        _net_log[sid] = []

        def _on_req(req):
            if _current == sid:
                entry = {"url": req.url, "method": req.method}
                if req.post_data:
                    entry["body"] = req.post_data[:300]
                _net_log[sid].append(entry)
                if len(_net_log[sid]) > 80:
                    _net_log[sid] = _net_log[sid][-40:]

        page.on("request", _on_req)
        _contexts[sid] = ctx
        _pages[sid] = page


def _page() -> Page:
    _ensure_session(_current)
    return _pages[_current]


def _in_scope(url: str) -> bool:
    if not ALLOWED_DOMAINS:
        return True  # no restriction configured
    host = (urlparse(url).hostname or url.split(":")[0]).lower()
    for domain in ALLOWED_DOMAINS:
        if domain.startswith("*."):
            if host.endswith("." + domain[2:]):
                return True
        elif host == domain or host.endswith("." + domain):
            return True
    return False


# ---------------------------------------------------------------------------
# Tool implementations
# ---------------------------------------------------------------------------

def _nav(url: str) -> dict:
    if not _in_scope(url):
        return {"error": f"Out of scope: {url}"}
    _ensure_session(_current)
    _page().goto(url, wait_until="domcontentloaded", timeout=15000)
    _page().wait_for_timeout(1200)
    return {"url": _page().url, "title": _page().title()}


def _page_state() -> dict:
    try:
        text = _page().inner_text("body")[:4000]
    except Exception:
        text = ""
    return {
        "url": _page().url,
        "title": _page().title(),
        "text": text,
        "network_log": _net_log.get(_current, [])[-12:],
    }


def _screenshot() -> dict:
    name = f"{_current}_{int(time.time())}.png"
    path = SS_DIR / name
    _page().screenshot(path=str(path))
    data = base64.b64encode(path.read_bytes()).decode()
    return {"path": str(path), "base64_preview": data[:8000]}


def _click(selector: str) -> dict:
    try:
        _page().click(selector, timeout=5000)
    except Exception:
        try:
            _page().get_by_text(selector).first.click(timeout=5000)
        except Exception as exc:
            return {"error": str(exc)}
    _page().wait_for_timeout(700)
    return {"clicked": selector, "url": _page().url}


def _fill(selector: str, value: str) -> dict:
    _page().fill(selector, value, timeout=5000)
    return {"ok": True, "selector": selector}


def _js(code: str) -> dict:
    result = _page().evaluate(code)
    return {"result": str(result)[:2000]}


def _links() -> dict:
    links = _page().evaluate("""
        () => [...document.querySelectorAll('a[href]')]
            .map(a => ({text: a.textContent.trim().slice(0,50), href: a.href}))
            .filter(l => l.href.startsWith('http')).slice(0, 60)
    """)
    scoped = [l for l in links if _in_scope(l["href"])]
    return {"in_scope": scoped, "total_found": len(links)}


def _new_session(sid: str) -> dict:
    global _current
    if sid not in _contexts:
        _ensure_session(sid)
    _current = sid
    return {"session": sid}


def _switch_session(sid: str) -> dict:
    global _current
    if sid in _pages:
        _current = sid
        return {"session": sid, "url": _page().url}
    return {"error": f"Session {sid} not found. Use new_session first."}


def _get_cookies() -> dict:
    cookies = _contexts.get(_current, {}).cookies() if _current in _contexts else []
    return {"cookies": [{"name": c["name"], "httpOnly": c.get("httpOnly"), "secure": c.get("secure"), "sameSite": c.get("sameSite")} for c in cookies]}


def _close_all() -> dict:
    global _browser, _pw
    for ctx in _contexts.values():
        try:
            ctx.close()
        except Exception:
            pass
    _contexts.clear()
    _pages.clear()
    if _browser:
        _browser.close()
        _browser = None
    if _pw:
        _pw.stop()
        _pw = None
    return {"closed": True}


# ---------------------------------------------------------------------------
# MCP protocol
# ---------------------------------------------------------------------------

TOOLS = [
    {
        "name": "browser_navigate",
        "description": "Navigate browser to a URL (scope-enforced). Returns title + final URL.",
        "inputSchema": {"type": "object", "properties": {"url": {"type": "string"}}, "required": ["url"]},
    },
    {
        "name": "browser_page_state",
        "description": "Get current page text, URL, and recent network requests.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "browser_screenshot",
        "description": "Take a screenshot of the current browser view.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "browser_click",
        "description": "Click an element by CSS selector or visible text.",
        "inputSchema": {"type": "object", "properties": {"selector": {"type": "string"}}, "required": ["selector"]},
    },
    {
        "name": "browser_fill",
        "description": "Fill an input field.",
        "inputSchema": {"type": "object", "properties": {"selector": {"type": "string"}, "value": {"type": "string"}}, "required": ["selector", "value"]},
    },
    {
        "name": "browser_submit_form",
        "description": "Press Enter to submit the current form.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "browser_evaluate_js",
        "description": "Run JavaScript in the browser page and return the result.",
        "inputSchema": {"type": "object", "properties": {"code": {"type": "string"}}, "required": ["code"]},
    },
    {
        "name": "browser_get_links",
        "description": "Get all in-scope links on the current page.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "browser_new_session",
        "description": "Create a new isolated browser session (fresh cookies). For IDOR: one session per test account.",
        "inputSchema": {"type": "object", "properties": {"session_id": {"type": "string"}}, "required": ["session_id"]},
    },
    {
        "name": "browser_switch_session",
        "description": "Switch to a different browser session.",
        "inputSchema": {"type": "object", "properties": {"session_id": {"type": "string"}}, "required": ["session_id"]},
    },
    {
        "name": "browser_get_cookies",
        "description": "Get cookies for the current session (shows flags: HttpOnly, Secure, SameSite).",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "browser_close",
        "description": "Close the browser and all sessions.",
        "inputSchema": {"type": "object", "properties": {}},
    },
]


def _call_tool(name: str, args: dict) -> str:
    if not _init_browser():
        return json.dumps({"error": "playwright not installed: pip3 install playwright && playwright install chromium"})
    try:
        if name == "browser_navigate":
            return json.dumps(_nav(args["url"]))
        elif name == "browser_page_state":
            return json.dumps(_page_state())
        elif name == "browser_screenshot":
            return json.dumps(_screenshot())
        elif name == "browser_click":
            return json.dumps(_click(args["selector"]))
        elif name == "browser_fill":
            return json.dumps(_fill(args["selector"], args["value"]))
        elif name == "browser_submit_form":
            _page().keyboard.press("Enter")
            _page().wait_for_timeout(1000)
            return json.dumps({"url": _page().url})
        elif name == "browser_evaluate_js":
            return json.dumps(_js(args["code"]))
        elif name == "browser_get_links":
            return json.dumps(_links())
        elif name == "browser_new_session":
            return json.dumps(_new_session(args["session_id"]))
        elif name == "browser_switch_session":
            return json.dumps(_switch_session(args["session_id"]))
        elif name == "browser_get_cookies":
            return json.dumps(_get_cookies())
        elif name == "browser_close":
            return json.dumps(_close_all())
        else:
            return json.dumps({"error": f"Unknown tool: {name}"})
    except Exception as exc:
        return json.dumps({"error": str(exc)[:400]})


def _handle(req: dict) -> Optional[dict]:
    method = req.get("method", "")
    id_ = req.get("id")

    if method == "initialize":
        return {
            "jsonrpc": "2.0", "id": id_,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "playwright-browser-mcp", "version": "1.0.0"},
            },
        }
    if method in ("notifications/initialized", "notifications/cancelled"):
        return None
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": id_, "result": {"tools": TOOLS}}
    if method == "tools/call":
        params = req.get("params", {})
        name = params.get("name", "")
        args = params.get("arguments", {})
        result_text = _call_tool(name, args)
        return {
            "jsonrpc": "2.0", "id": id_,
            "result": {"content": [{"type": "text", "text": result_text}]},
        }
    return {
        "jsonrpc": "2.0", "id": id_,
        "error": {"code": -32601, "message": f"method not found: {method}"},
    }


def main():
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            req = json.loads(raw)
        except json.JSONDecodeError:
            continue
        resp = _handle(req)
        if resp is not None:
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()

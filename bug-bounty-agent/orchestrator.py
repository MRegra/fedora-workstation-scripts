#!/usr/bin/env python3
"""
Bug Bounty Orchestrator

Runs recon + scanning against in-scope targets, uses Ollama for bulk triage,
and Claude API for validation and professional report generation.

SAFETY: Every network request is gated by is_in_scope(). The script refuses
to probe any target not explicitly listed in scope.yaml.

Usage:
  python3 orchestrator.py --scope scope.yaml              # full run
  python3 orchestrator.py --scope scope.yaml --phase recon
  python3 orchestrator.py --scope scope.yaml --phase scan
  python3 orchestrator.py --scope scope.yaml --phase report
  python3 orchestrator.py --scope scope.yaml --dry-run

Overnight:
  nohup python3 orchestrator.py --scope scope.yaml >> output/run.log 2>&1 &
  echo $! > output/run.pid

Env vars:
  ANTHROPIC_API_KEY   required for Claude validation + reports
  OLLAMA_URL          default: http://localhost:11434
  OLLAMA_MODEL        default: llama3.3:70b
"""

import argparse
import fnmatch
import json
import logging
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Optional
from urllib.parse import urlparse

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
    """
    Returns True ONLY if target is explicitly in scope and not excluded.
    Called before every network operation.
    """
    raw = target
    if target.startswith("http://") or target.startswith("https://"):
        host = urlparse(target).hostname or ""
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
            base = domain[2:]
            if host.endswith("." + base):
                return True
        elif host == domain:
            return True

    # IP range check (simple /24 support)
    import ipaddress
    for cidr in scope.get("in_scope", {}).get("ip_ranges", []):
        try:
            if ipaddress.ip_address(host) in ipaddress.ip_network(cidr, strict=False):
                return True
        except ValueError:
            pass

    return False


def assert_in_scope(target: str, scope: dict, log: logging.Logger) -> None:
    if not is_in_scope(target, scope):
        log.error("SCOPE VIOLATION — refusing to probe out-of-scope target: %s", target)
        raise ValueError(f"Out-of-scope target: {target}")


# ---------------------------------------------------------------------------
# Tool runner
# ---------------------------------------------------------------------------

def run_tool(cmd: list, timeout: int = 600, log: Optional[logging.Logger] = None) -> str:
    cmd_str = " ".join(str(c) for c in cmd)
    if log:
        log.debug("Running: %s", cmd_str)
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout
        )
        if result.returncode not in (0, 1):  # nuclei exits 1 when findings found
            if log:
                log.debug("Tool stderr: %s", result.stderr[:500])
        return result.stdout.strip()
    except subprocess.TimeoutExpired:
        if log:
            log.warning("Tool timed out after %ds: %s", timeout, cmd_str)
        return ""
    except FileNotFoundError:
        if log:
            log.warning("Tool not found: %s (skipping)", cmd[0])
        return ""


def tool_available(name: str) -> bool:
    return subprocess.run(
        ["which", name], capture_output=True
    ).returncode == 0


# ---------------------------------------------------------------------------
# Ollama helpers
# ---------------------------------------------------------------------------

def ollama_chat(prompt: str, system: str = "", model: str = OLLAMA_MODEL) -> str:
    payload = {"model": model, "prompt": prompt, "stream": False}
    if system:
        payload["system"] = system
    try:
        resp = requests.post(
            f"{OLLAMA_URL}/api/generate", json=payload, timeout=180
        )
        resp.raise_for_status()
        return resp.json().get("response", "")
    except Exception as exc:
        return f"[Ollama error: {exc}]"


def ollama_triage_findings(raw_findings: list[dict], log: logging.Logger) -> list[dict]:
    """
    Send nuclei + nmap findings to Ollama in batches.
    Ollama deduplicates, removes obvious false positives, and adds triage notes.
    Returns a filtered list.
    """
    if not raw_findings:
        return []

    log.info("Sending %d raw findings to Ollama for triage...", len(raw_findings))
    batch_size = 20
    triaged: list[dict] = []

    for i in range(0, len(raw_findings), batch_size):
        batch = raw_findings[i : i + batch_size]
        batch_json = json.dumps(batch, indent=2)
        prompt = f"""You are a security triage assistant helping a bug bounty researcher.
Review these findings from automated security scanners and return ONLY valid security
findings worth investigating. Remove: duplicates, info-only findings with no security
impact, findings that are clearly false positives (e.g. nuclei "detect" templates that
just fingerprint tech with no vulnerability).

For each finding you KEEP, add a "triage_note" field with 1 sentence explaining
why it might be valid and what to verify.

Return ONLY a JSON array of kept findings with triage_note added. No commentary.

Findings:
{batch_json}
"""
        response = ollama_chat(prompt)
        try:
            # Extract JSON array from response
            start = response.find("[")
            end = response.rfind("]") + 1
            if start >= 0 and end > start:
                kept = json.loads(response[start:end])
                triaged.extend(kept)
                log.info("Ollama kept %d/%d from batch %d", len(kept), len(batch), i // batch_size + 1)
        except json.JSONDecodeError:
            log.warning("Ollama returned non-JSON for batch %d — keeping batch as-is", i // batch_size + 1)
            triaged.extend(batch)

    return triaged


# ---------------------------------------------------------------------------
# Claude validation + reporting
# ---------------------------------------------------------------------------

def claude_validate_and_report(
    findings: list[dict],
    program: dict,
    output_dir: Path,
    log: logging.Logger,
) -> None:
    if not _HAS_ANTHROPIC:
        log.error("anthropic SDK not installed — skipping Claude validation")
        log.error("pip3 install anthropic && export ANTHROPIC_API_KEY=sk-...")
        return

    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not api_key:
        log.error("ANTHROPIC_API_KEY not set — skipping Claude validation")
        return

    client = anthropic.Anthropic(api_key=api_key)
    platform = program.get("platform", "intigriti")
    reports_dir = output_dir / "reports"
    reports_dir.mkdir(exist_ok=True)

    log.info("Sending %d triaged findings to Claude for validation + reporting...", len(findings))

    system_prompt = f"""You are an expert bug bounty security researcher writing professional
vulnerability reports for the {platform.title()} platform.

For each finding:
1. Determine if it is a real, exploitable vulnerability (not a false positive).
2. Classify severity: Critical / High / Medium / Low / Informational.
3. Write a professional bug report in the correct format for {platform}.
4. Be conservative — do NOT overstate impact. Accurate reports build reputation.
5. If a finding is a false positive, output {{"valid": false, "reason": "..."}} and stop.

You are ONLY reporting, never exploiting. The tester has not accessed any real user data."""

    for idx, finding in enumerate(findings):
        log.info("Claude validating finding %d/%d: %s", idx + 1, len(findings), finding.get("name", "unknown"))

        user_prompt = f"""Validate and report this finding. Program: {program.get('name', 'Unknown')}.

Finding:
{json.dumps(finding, indent=2)}

If valid, produce a complete {platform} bug report with these sections:
- Title (clear, specific, no jargon)
- Severity (Critical/High/Medium/Low)
- CVSS Score + vector string (CVSSv3.1)
- Description (what the vulnerability is)
- Steps to Reproduce (numbered, exact)
- Impact (what an attacker could do — be realistic)
- Affected Asset (URL/endpoint)
- Remediation (concrete fix advice)
- References (CVE/CWE if applicable)

If this is a false positive or informational with no impact, say so and explain why.
"""

        try:
            response = client.messages.create(
                model=CLAUDE_MODEL,
                max_tokens=4096,
                thinking={"type": "adaptive"},
                system=system_prompt,
                messages=[{"role": "user", "content": user_prompt}],
            )

            report_text = ""
            for block in response.content:
                if block.type == "text":
                    report_text = block.text
                    break

            if not report_text:
                log.warning("Claude returned no text for finding %d", idx + 1)
                continue

            # Save report
            slug = (finding.get("name", f"finding-{idx+1}"))[:50].replace(" ", "-").replace("/", "-")
            ts = datetime.now().strftime("%Y%m%d-%H%M%S")
            report_path = reports_dir / f"{ts}-{slug}.md"
            report_path.write_text(
                f"# Bug Report: {finding.get('name', 'Finding')}\n\n"
                f"**Generated:** {datetime.now().isoformat()}\n"
                f"**Program:** {program.get('name', 'Unknown')}\n"
                f"**Platform:** {platform}\n\n"
                f"---\n\n{report_text}\n\n"
                f"---\n\n## Raw Finding Data\n\n```json\n{json.dumps(finding, indent=2)}\n```\n",
                encoding="utf-8",
            )
            log.info("Report saved: %s", report_path)

        except anthropic.APIError as exc:
            log.error("Claude API error for finding %d: %s", idx + 1, exc)
        except Exception as exc:
            log.error("Unexpected error for finding %d: %s", idx + 1, exc)

        time.sleep(2)  # avoid rate limits between reports


# ---------------------------------------------------------------------------
# Recon phase
# ---------------------------------------------------------------------------

def phase_recon(scope: dict, state: dict, output_dir: Path, log: logging.Logger, dry_run: bool) -> None:
    log.info("=== PHASE: RECON ===")
    domains_raw = scope.get("in_scope", {}).get("domains", [])
    # Expand wildcards to their base domain for subfinder
    base_domains = []
    for d in domains_raw:
        base = d.lstrip("*.").lower()
        if base not in base_domains:
            base_domains.append(base)

    discovered: list[str] = list(base_domains)

    skip = scope.get("scan", {}).get("skip_tools", [])

    # Subdomain enumeration
    if "subfinder" not in skip and tool_available("subfinder"):
        log.info("Running subfinder on %d base domain(s)...", len(base_domains))
        for domain in base_domains:
            if dry_run:
                log.info("[DRY-RUN] subfinder -d %s", domain)
                continue
            out = run_tool(["subfinder", "-d", domain, "-silent"], timeout=300, log=log)
            for sub in out.splitlines():
                sub = sub.strip().lower()
                if sub and is_in_scope(sub, scope) and sub not in discovered:
                    discovered.append(sub)
    else:
        log.info("subfinder not available or skipped — using base domains only")

    # Amass (optional, slower)
    if "amass" not in skip and tool_available("amass"):
        for domain in base_domains:
            if dry_run:
                log.info("[DRY-RUN] amass enum -passive -d %s", domain)
                continue
            out = run_tool(["amass", "enum", "-passive", "-d", domain], timeout=600, log=log)
            for sub in out.splitlines():
                sub = sub.strip().lower()
                if sub and is_in_scope(sub, scope) and sub not in discovered:
                    discovered.append(sub)

    log.info("Discovered %d in-scope host(s)", len(discovered))
    state["discovered_hosts"] = discovered
    _save_state(state, output_dir)

    # Probe live hosts with httpx
    if not dry_run and discovered and "httpx" not in skip and tool_available("httpx"):
        log.info("Probing live HTTP hosts with httpx...")
        hosts_file = output_dir / "hosts.txt"
        hosts_file.write_text("\n".join(discovered))
        out = run_tool(
            ["httpx", "-l", str(hosts_file), "-silent", "-status-code", "-title", "-json"],
            timeout=300, log=log,
        )
        live = []
        for line in out.splitlines():
            try:
                entry = json.loads(line)
                url = entry.get("url", "")
                if url and is_in_scope(url, scope):
                    live.append(entry)
            except json.JSONDecodeError:
                pass
        state["live_hosts"] = live
        log.info("Live hosts: %d", len(live))
        _save_state(state, output_dir)
    elif dry_run:
        log.info("[DRY-RUN] httpx probe of %d hosts", len(discovered))
        state["live_hosts"] = [{"url": f"https://{h}"} for h in discovered[:3]]

    # URL discovery
    if "gau" not in skip and tool_available("gau"):
        all_urls: list[str] = []
        for domain in base_domains:
            if dry_run:
                log.info("[DRY-RUN] gau %s", domain)
                continue
            delay = scope.get("rate_limit", {}).get("requests_per_second", 5)
            out = run_tool(
                ["gau", "--threads", "1", "--delay", str(1000 // delay), domain],
                timeout=300, log=log,
            )
            for url in out.splitlines():
                url = url.strip()
                if url and is_in_scope(url, scope):
                    all_urls.append(url)
        if all_urls:
            state["discovered_urls"] = all_urls
            log.info("Discovered %d URLs from gau", len(all_urls))
            (output_dir / "urls.txt").write_text("\n".join(all_urls))
            _save_state(state, output_dir)


# ---------------------------------------------------------------------------
# Scan phase
# ---------------------------------------------------------------------------

def phase_scan(scope: dict, state: dict, output_dir: Path, log: logging.Logger, dry_run: bool) -> None:
    log.info("=== PHASE: SCAN ===")
    live_hosts = state.get("live_hosts", [])
    targets = [h.get("url", h) if isinstance(h, dict) else h for h in live_hosts]
    targets = [t for t in targets if t and is_in_scope(t, scope)]

    if not targets:
        log.warning("No live targets to scan. Run recon phase first.")
        return

    scan_cfg = scope.get("scan", {})
    skip = scan_cfg.get("skip_tools", [])
    rate = scope.get("rate_limit", {}).get("nuclei_rate", 20)
    all_findings: list[dict] = []

    # Nuclei
    if "nuclei" not in skip and tool_available("nuclei"):
        templates = scan_cfg.get("nuclei_templates", ["misconfiguration", "exposures", "vulnerabilities"])
        severities = ",".join(scan_cfg.get("nuclei_severity", ["critical", "high", "medium"]))
        targets_file = output_dir / "live_targets.txt"
        targets_file.write_text("\n".join(targets))

        if dry_run:
            log.info("[DRY-RUN] nuclei -l %s -t %s -severity %s", targets_file, ",".join(templates), severities)
        else:
            log.info("Running nuclei against %d targets (templates: %s)...", len(targets), templates)
            nuclei_cmd = [
                "nuclei",
                "-l", str(targets_file),
                "-t", ",".join(templates),
                "-severity", severities,
                "-rate-limit", str(rate),
                "-json",
                "-silent",
                "-no-color",
            ]
            out = run_tool(nuclei_cmd, timeout=3600, log=log)
            for line in out.splitlines():
                try:
                    finding = json.loads(line)
                    host = finding.get("host", finding.get("url", ""))
                    if is_in_scope(host, scope):
                        all_findings.append(finding)
                except json.JSONDecodeError:
                    pass
            log.info("Nuclei found %d potential issues", len(all_findings))
    else:
        log.info("nuclei not available or skipped")

    # Nmap light scan
    if "nmap" not in skip and tool_available("nmap"):
        timing = scope.get("rate_limit", {}).get("nmap_timing", 3)
        ports = scan_cfg.get("nmap_ports", "80,443,8080,8443,8888")
        discovered_hosts = state.get("discovered_hosts", [])

        for host in discovered_hosts[:20]:  # cap at 20 hosts for overnight safety
            if not is_in_scope(host, scope):
                continue
            delay = scope.get("rate_limit", {}).get("delay_between_hosts", 2)
            if dry_run:
                log.info("[DRY-RUN] nmap -T%d -p %s %s", timing, ports, host)
                continue
            log.debug("nmap scanning %s", host)
            out = run_tool(
                ["nmap", f"-T{timing}", "-p", ports, "--open", "-oG", "-", host],
                timeout=120, log=log,
            )
            if "open" in out:
                all_findings.append({
                    "name": f"Open ports found: {host}",
                    "type": "nmap",
                    "host": host,
                    "raw": out,
                })
            time.sleep(delay)

    # Save raw findings
    if all_findings:
        raw_path = output_dir / "raw_findings.json"
        raw_path.write_text(json.dumps(all_findings, indent=2))
        log.info("Saved %d raw findings to %s", len(all_findings), raw_path)

    # Ollama triage
    if not dry_run and all_findings:
        triaged = ollama_triage_findings(all_findings, log)
        triaged_path = output_dir / "triaged_findings.json"
        triaged_path.write_text(json.dumps(triaged, indent=2))
        log.info("Ollama triaged: %d findings remain after filtering", len(triaged))
        state["triaged_findings"] = triaged
        _save_state(state, output_dir)
    elif dry_run:
        log.info("[DRY-RUN] Ollama triage would process %d findings", len(all_findings))


# ---------------------------------------------------------------------------
# Report phase
# ---------------------------------------------------------------------------

def phase_report(scope: dict, state: dict, output_dir: Path, log: logging.Logger, dry_run: bool) -> None:
    log.info("=== PHASE: REPORT ===")

    # Load triaged findings from state or file
    triaged = state.get("triaged_findings", [])
    if not triaged:
        triaged_path = output_dir / "triaged_findings.json"
        if triaged_path.exists():
            triaged = json.loads(triaged_path.read_text())

    if not triaged:
        log.info("No triaged findings to report.")
        return

    if dry_run:
        log.info("[DRY-RUN] Claude would validate and report %d findings", len(triaged))
        return

    program = scope.get("program", {})
    claude_validate_and_report(triaged, program, output_dir, log)

    # Notify
    _notify(scope, output_dir, log)


# ---------------------------------------------------------------------------
# Notification
# ---------------------------------------------------------------------------

def _notify(scope: dict, output_dir: Path, log: logging.Logger) -> None:
    topic = scope.get("output", {}).get("notify_ntfy_topic", "")
    if not topic:
        return
    reports = list((output_dir / "reports").glob("*.md")) if (output_dir / "reports").exists() else []
    msg = f"Bug bounty run complete. {len(reports)} report(s) generated. Check {output_dir}/reports/"
    try:
        requests.post(f"https://ntfy.sh/{topic}", data=msg.encode(), timeout=10)
        log.info("Sent ntfy.sh notification to topic: %s", topic)
    except Exception as exc:
        log.warning("ntfy.sh notification failed: %s", exc)


# ---------------------------------------------------------------------------
# State persistence (for overnight runs)
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
    parser = argparse.ArgumentParser(description="Bug bounty orchestrator")
    parser.add_argument("--scope", required=True, help="Path to scope.yaml")
    parser.add_argument(
        "--phase",
        choices=["recon", "scan", "report", "all"],
        default="all",
        help="Which phase to run (default: all)",
    )
    parser.add_argument("--dry-run", action="store_true", help="Show what would run without executing")
    parser.add_argument("--fresh", action="store_true", help="Ignore saved state and start from scratch")
    args = parser.parse_args()

    scope_path = Path(args.scope)
    if not scope_path.exists():
        print(f"ERROR: scope file not found: {scope_path}", file=sys.stderr)
        sys.exit(1)

    with open(scope_path) as f:
        scope = yaml.safe_load(f)

    output_dir = Path(scope.get("output", {}).get("directory", "./output"))
    log = _make_logger(output_dir)

    if args.dry_run:
        log.info("DRY-RUN mode — no network requests will be made")

    log.info("Program: %s | Platform: %s", scope["program"]["name"], scope["program"]["platform"])
    log.info("In-scope domains: %s", scope["in_scope"]["domains"])

    state = {} if args.fresh else _load_state(output_dir)

    try:
        if args.phase in ("recon", "all"):
            phase_recon(scope, state, output_dir, log, args.dry_run)

        if args.phase in ("scan", "all"):
            phase_scan(scope, state, output_dir, log, args.dry_run)

        if args.phase in ("report", "all"):
            phase_report(scope, state, output_dir, log, args.dry_run)

        log.info("=== DONE ===")

    except KeyboardInterrupt:
        log.info("Interrupted — state saved to %s/state.json. Resume with --phase.", output_dir)
        _save_state(state, output_dir)
        sys.exit(0)
    except Exception as exc:
        log.exception("Fatal error: %s", exc)
        _save_state(state, output_dir)
        sys.exit(1)


if __name__ == "__main__":
    main()

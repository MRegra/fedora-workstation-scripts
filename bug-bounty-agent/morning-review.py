#!/usr/bin/env python3
"""
Morning triage — reads overnight findings and shows a ranked, actionable summary.

Usage:
  python3 morning-review.py                    # reads ./output/
  python3 morning-review.py --dir ./output/    # explicit path
  python3 morning-review.py --top 3            # show top 3 only
"""

import argparse
import json
import os
import sys
from pathlib import Path

SEVERITY_SCORE = {"critical": 100, "high": 80, "medium": 50, "low": 15, "info": 2}
CATEGORY_TIME = {
    "idor": 20, "auth": 20, "sqli": 15, "ssrf": 15, "ssti": 15,
    "xss": 10, "cors": 10, "lfi": 10, "redirect": 8, "header-injection": 8,
    "secret": 8, "logic": 20, "misconfiguration": 8, "exposure": 6,
}

RESET = "\033[0m"
RED = "\033[31m"
YELLOW = "\033[33m"
GREEN = "\033[32m"
BOLD = "\033[1m"
DIM = "\033[2m"
CYAN = "\033[36m"

def _color(text, code):
    return f"{code}{text}{RESET}" if sys.stdout.isatty() else text

def _severity_color(s):
    s = s.lower()
    if s == "critical": return _color(s.upper(), RED + BOLD)
    if s == "high": return _color(s.upper(), RED)
    if s == "medium": return _color(s.upper(), YELLOW)
    return _color(s.upper(), DIM)

def _score(f):
    base = SEVERITY_SCORE.get(f.get("severity", "info").lower(), 2)
    poc = 15 if f.get("poc_confirmed") else 0
    evidence = min(len(f.get("evidence", [])) * 3, 15)
    browser = 10 if f.get("source") == "browser" else 0
    return base + poc + evidence + browser

def _est_time(f):
    cat = f.get("category", "").lower()
    return CATEGORY_TIME.get(cat, 12)

def _report_path(output_dir, finding_id):
    reports = output_dir / "reports"
    if reports.exists():
        matches = list(reports.glob(f"*{finding_id}*.md"))
        if matches:
            return matches[0]
        all_reports = sorted(reports.glob("*.md"))
        if all_reports:
            return all_reports[0]
    return None

def load_findings(output_dir):
    fpath = output_dir / "findings.json"
    if not fpath.exists():
        return []
    with open(fpath) as f:
        data = json.load(f)
    if isinstance(data, list):
        return data
    return data.get("findings", [])

def deduplicate(findings):
    seen = set()
    out = []
    for f in findings:
        key = (f.get("category", ""), f.get("url", "")[:80], f.get("severity", ""))
        if key not in seen:
            seen.add(key)
            out.append(f)
    return out

def print_header(output_dir, findings):
    total = len(findings)
    by_sev = {}
    for f in findings:
        s = f.get("severity", "info").lower()
        by_sev[s] = by_sev.get(s, 0) + 1

    print(_color("\n╔══════════════════════════════════════════════════╗", CYAN))
    print(_color("║         OVERNIGHT FINDINGS — MORNING REVIEW       ║", CYAN + BOLD))
    print(_color("╚══════════════════════════════════════════════════╝", CYAN))
    print(f"\n  Output: {output_dir}")
    print(f"  Total findings: {_color(str(total), BOLD)}", end="  ")
    for sev in ["critical", "high", "medium", "low"]:
        n = by_sev.get(sev, 0)
        if n:
            print(f"{_severity_color(sev)}: {n}", end="  ")
    print()

def print_finding(rank, f, output_dir):
    idx = f.get("id", f"#{rank}")
    sev = f.get("severity", "info")
    cat = f.get("category", "unknown")
    url = f.get("url", f.get("target", "—"))
    title = f.get("title", f"{cat} on {url[:60]}")
    poc = f.get("poc_confirmed", False)
    source = f.get("source", "scan")
    est = _est_time(f)

    print(f"\n  {_color(str(rank), BOLD + CYAN)}. [{_severity_color(sev)}] {title}")
    print(f"     URL     : {url[:90]}")
    print(f"     Category: {cat}  |  Source: {source}  |  PoC: {'YES' if poc else 'no'}  |  Est. submit time: ~{est} min")

    evidence = f.get("evidence", [])
    if evidence:
        print(f"     Evidence: {evidence[0][:100]}")

    rpath = _report_path(output_dir, str(idx))
    if rpath:
        print(f"     Draft   : {rpath}")
    else:
        print(f"     Draft   : {_color('no draft report found', DIM)}")

def print_summary(ranked, output_dir):
    total_time = sum(_est_time(f) for f in ranked)
    with_poc = sum(1 for f in ranked if f.get("poc_confirmed"))
    with_draft = sum(1 for f in ranked
                     if _report_path(output_dir, str(f.get("id", ""))) is not None)

    print(_color("\n  ─────────────────────────────────────────────", DIM))
    print(f"  Findings shown: {len(ranked)}  |  With PoC: {with_poc}  |  With draft: {with_draft}")
    print(f"  Total submit time estimate: ~{total_time} min")
    print()

def print_next_steps(ranked, platform, output_dir):
    print(_color("  WHAT TO DO NOW (1-hour routine):", BOLD))
    print()
    print("  1. Pick the top 1–2 findings above (prioritize: has PoC + high severity)")
    print("  2. Polish the draft report:")
    print(f"       python3 polish-report.py --dir {output_dir} --rank 1 --platform {platform}")
    print("  3. Review the polished output, paste into the platform, submit")
    print("  4. Queue tonight's run:")
    print(f"       python3 orchestrator.py --scope scope.yaml &")
    print()
    print(_color("  TIP: Submit no more than 2 reports per day. Quality over speed.", DIM))
    print()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default="./output", help="Output directory from orchestrator")
    ap.add_argument("--top", type=int, default=5, help="Show top N findings (default: 5)")
    ap.add_argument("--platform", default="intigriti", choices=["intigriti", "bugcrowd"])
    ap.add_argument("--all", action="store_true", help="Show all findings, not just top N")
    args = ap.parse_args()

    output_dir = Path(args.dir)
    if not output_dir.exists():
        print(f"Output directory not found: {output_dir}", file=sys.stderr)
        sys.exit(1)

    raw = load_findings(output_dir)
    if not raw:
        print(f"\n  No findings.json in {output_dir}. Did the orchestrator run?\n")
        sys.exit(0)

    findings = deduplicate(raw)
    findings.sort(key=_score, reverse=True)

    print_header(output_dir, findings)

    show = findings if args.all else findings[: args.top]
    for i, f in enumerate(show, 1):
        print_finding(i, f, output_dir)
        f["_rank"] = i  # tag for polish-report

    print_summary(show, output_dir)
    print_next_steps(show, args.platform, output_dir)


if __name__ == "__main__":
    main()

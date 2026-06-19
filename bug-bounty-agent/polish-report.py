#!/usr/bin/env python3
"""
Polish an overnight draft report into a platform-ready submission.

Usage:
  python3 polish-report.py --dir ./output --rank 1 --platform intigriti
  python3 polish-report.py --report ./output/reports/idor_api_users.md --platform bugcrowd
  python3 polish-report.py --dir ./output --rank 2 --platform bugcrowd --out ~/Desktop/submit.md
"""

import anthropic
import argparse
import json
import sys
from pathlib import Path

MODEL = "claude-opus-4-8"

INTIGRITI_SYSTEM = """You are a senior bug bounty researcher preparing a vulnerability report for
Intigriti. Rewrite the draft into a polished, submission-ready report that will score well with
professional triagers.

Requirements:
- Title: impact-first, max 80 chars. Format: "[Vuln Type]: [what an attacker can do] via [endpoint/mechanism]"
- Impact section: 2-3 sentences for a non-technical product manager. What data/action is at risk? GDPR? Revenue? Reputation?
- Severity: provide the CVSS v3.1 vector string and score. Be accurate — do not inflate.
- Steps to reproduce: numbered, copy-pasteable. A triager should reproduce in under 5 minutes.
- PoC: include the HTTP request or curl command from the draft evidence. If a screenshot is referenced, note its filename.
- Suggested remediation: 1-2 sentences.
- Format: clean Markdown, no fluff, no unnecessary headers.

Do NOT invent evidence that is not in the draft. Do NOT change the severity if it isn't supported.
Output only the polished report — no preamble, no explanation."""

BUGCROWD_SYSTEM = """You are a senior bug bounty researcher preparing a vulnerability report for
Bugcrowd. Rewrite the draft into a polished, submission-ready report optimized for Bugcrowd's
triage process.

Requirements:
- Title: short, impact-first, max 70 chars.
- VRT Category: identify the exact Bugcrowd Vulnerability Rating Taxonomy (VRT) path.
  Examples: "Broken Access Control > IDOR > Sensitive Data Exposure via API"
           "Injection > SQL Injection > Time-Based Blind"
           "Application-Level Denial of Service > Regular Expression Denial of Service"
- Description: what is the bug, why does it exist, what can an attacker do.
- Steps to reproduce: numbered, minimal, copy-pasteable.
- PoC: include the HTTP request or script from the draft evidence.
- Impact: 2-3 sentences, business-level.
- Format: clean Markdown.

Do NOT invent evidence. Do NOT upgrade severity beyond what the evidence supports.
Output only the polished report — no preamble."""

PLATFORM_SYSTEMS = {
    "intigriti": INTIGRITI_SYSTEM,
    "bugcrowd": BUGCROWD_SYSTEM,
}

def find_report_by_rank(output_dir, rank):
    findings_path = output_dir / "findings.json"
    reports_dir = output_dir / "reports"

    if not reports_dir.exists():
        return None, None

    all_reports = sorted(reports_dir.glob("*.md"))
    if not all_reports:
        return None, None

    if findings_path.exists():
        with open(findings_path) as f:
            data = json.load(f)
        findings = data if isinstance(data, list) else data.get("findings", [])
        findings.sort(key=lambda x: (
            {"critical": 4, "high": 3, "medium": 2, "low": 1}.get(x.get("severity","").lower(), 0)
        ), reverse=True)

        if rank <= len(findings):
            finding = findings[rank - 1]
            fid = str(finding.get("id", ""))
            matches = list(reports_dir.glob(f"*{fid}*.md")) if fid else []
            if matches:
                return matches[0], finding

    if rank <= len(all_reports):
        return all_reports[rank - 1], None

    return None, None

def load_context(output_dir, finding):
    context_parts = []

    if finding:
        poc = finding.get("poc_evidence", "")
        if poc:
            context_parts.append(f"PoC evidence from automated testing:\n{poc[:2000]}")
        evidence = finding.get("evidence", [])
        if evidence:
            context_parts.append("Additional evidence:\n" + "\n".join(str(e)[:300] for e in evidence[:5]))

    screenshots_dir = output_dir / "screenshots"
    if screenshots_dir.exists() and finding:
        host = finding.get("host", "")
        if host:
            shots = list(screenshots_dir.glob(f"*{host.replace('.', '_')}*.png"))
            if shots:
                context_parts.append(f"Screenshots available: {', '.join(s.name for s in shots[:3])}")

    return "\n\n".join(context_parts)

def polish(draft_text, context, platform, finding=None):
    api_key = __import__("os").environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        print("ERROR: ANTHROPIC_API_KEY not set.", file=sys.stderr)
        sys.exit(1)

    client = anthropic.Anthropic(api_key=api_key)

    user_content = f"Draft report:\n\n{draft_text}"
    if context:
        user_content += f"\n\n---\n\nAdditional context from automation:\n\n{context}"
    if finding:
        user_content += f"\n\n---\n\nFinding metadata: {json.dumps({k: v for k, v in finding.items() if k not in ('poc_evidence', 'evidence')}, indent=2)[:800]}"

    print(f"  Polishing with Claude Opus ({platform} format)...", file=sys.stderr)

    with client.messages.stream(
        model=MODEL,
        max_tokens=4096,
        thinking={"type": "adaptive"},
        system=PLATFORM_SYSTEMS[platform],
        messages=[{"role": "user", "content": user_content}],
    ) as stream:
        result = stream.get_final_message()

    for block in result.content:
        if block.type == "text":
            return block.text

    return ""

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default="./output", help="Output directory from orchestrator")
    ap.add_argument("--rank", type=int, default=1, help="Finding rank from morning-review (default: 1)")
    ap.add_argument("--report", help="Direct path to a draft .md report (overrides --rank)")
    ap.add_argument("--platform", default="intigriti", choices=["intigriti", "bugcrowd"])
    ap.add_argument("--out", help="Save polished report to this path (default: print to stdout)")
    args = ap.parse_args()

    output_dir = Path(args.dir)

    if args.report:
        report_path = Path(args.report)
        finding = None
    else:
        report_path, finding = find_report_by_rank(output_dir, args.rank)
        if not report_path:
            print(f"No report found for rank {args.rank} in {output_dir}", file=sys.stderr)
            print("Run morning-review.py first to see available findings.", file=sys.stderr)
            sys.exit(1)

    if not report_path.exists():
        print(f"Report file not found: {report_path}", file=sys.stderr)
        sys.exit(1)

    draft = report_path.read_text()
    print(f"  Draft: {report_path}", file=sys.stderr)

    context = load_context(output_dir, finding)
    polished = polish(draft, context, args.platform, finding)

    if not polished:
        print("ERROR: Claude returned empty response.", file=sys.stderr)
        sys.exit(1)

    if args.out:
        out_path = Path(args.out)
        out_path.write_text(polished)
        print(f"\n  Saved to: {out_path}", file=sys.stderr)
        print(f"  Open and review before submitting.", file=sys.stderr)
    else:
        sep = "=" * 60
        print(f"\n{sep}")
        print(f"  POLISHED REPORT ({args.platform.upper()})")
        print(f"  Source: {report_path.name}")
        print(sep)
        print()
        print(polished)
        print()
        print(sep)
        print("  Copy the report above and paste into the platform submission form.")
        print("  Review every claim before submitting — you own the submission.")
        print(sep)


if __name__ == "__main__":
    main()

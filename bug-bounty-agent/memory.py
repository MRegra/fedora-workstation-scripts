#!/usr/bin/env python3
"""
Per-program knowledge persistence for the bug bounty orchestrator.

Each program gets a JSON file: memory/{safe_program_name}.json
Accumulated across runs: auth patterns, known endpoints, submitted findings,
lessons learned, and surfaces to avoid.

The orchestrator reads this at startup and injects it into Claude's context.
At run end, Claude extracts new lessons and updates the file.
"""

import json
import logging
import os
import re
import time
from pathlib import Path
from typing import Optional

MEMORY_VERSION = 2
_CLAUDE_ANALYSIS_MODEL = "claude-opus-4-8"

DEFAULT_MEMORY: dict = {
    "version": MEMORY_VERSION,
    "program": "",
    "platform": "",
    "created": "",
    "last_run": "",
    "run_count": 0,
    "auth": {
        "login_endpoint": "",
        "token_format": "",         # JWT | session_cookie | api_key
        "token_expiry_minutes": 0,
        "notes": [],
    },
    "known_endpoints": [],          # interesting endpoints found in previous runs
    "submitted": [],                # {title, category, severity, status, bounty, date}
    "avoid": [],                    # endpoints/patterns confirmed OOS or heavily duped
    "rate_limits": {},              # {"/api/": "100/s", "/api/auth/": "10/min"}
    "tech_stack": [],               # detected technologies
    "lessons": [],                  # free-text notes extracted by Claude
    "custom_wordlist": [],          # params/paths found to work on this target
}


def _safe_name(program_name: str) -> str:
    return re.sub(r"[^a-z0-9_-]", "_", program_name.lower())[:60]


def load(program_name: str, memory_dir: Path) -> dict:
    memory_dir.mkdir(parents=True, exist_ok=True)
    path = memory_dir / f"{_safe_name(program_name)}.json"
    if not path.exists():
        mem = DEFAULT_MEMORY.copy()
        mem["program"] = program_name
        mem["created"] = _now()
        return mem
    with open(path) as f:
        data = json.load(f)
    if data.get("version", 1) < MEMORY_VERSION:
        data = _migrate(data)
    return data


def save(program_name: str, memory: dict, memory_dir: Path) -> None:
    memory_dir.mkdir(parents=True, exist_ok=True)
    path = memory_dir / f"{_safe_name(program_name)}.json"
    memory["last_run"] = _now()
    memory["run_count"] = memory.get("run_count", 0) + 1
    with open(path, "w") as f:
        json.dump(memory, f, indent=2)


def format_context(memory: dict) -> str:
    """Format memory as text for injection into Claude system prompts."""
    if not memory.get("run_count"):
        return ""

    parts = [f"=== PROGRAM MEMORY ({memory['program']}) ==="]
    parts.append(f"Runs completed: {memory['run_count']}  |  Last run: {memory.get('last_run', 'unknown')}")

    submitted = memory.get("submitted", [])
    if submitted:
        parts.append("\nAlready submitted findings (DO NOT re-submit these):")
        for s in submitted[-20:]:  # last 20
            status = s.get("status", "pending")
            bounty = f" ${s['bounty']}" if s.get("bounty") else ""
            parts.append(f"  [{status.upper()}{bounty}] {s.get('severity','?').upper()} — {s['title']}")

    avoid = memory.get("avoid", [])
    if avoid:
        parts.append("\nAvoid (confirmed OOS or heavily duped):")
        for a in avoid:
            parts.append(f"  - {a}")

    auth = memory.get("auth", {})
    if auth.get("login_endpoint") or auth.get("notes"):
        parts.append("\nAuth patterns:")
        if auth.get("login_endpoint"):
            parts.append(f"  Login: {auth['login_endpoint']}")
        if auth.get("token_format"):
            parts.append(f"  Token: {auth['token_format']}"
                         + (f" (~{auth['token_expiry_minutes']}min TTL)" if auth.get("token_expiry_minutes") else ""))
        for note in auth.get("notes", [])[-5:]:
            parts.append(f"  Note: {note}")

    rate_limits = memory.get("rate_limits", {})
    if rate_limits:
        parts.append("\nRate limits observed:")
        for endpoint, limit in list(rate_limits.items())[:10]:
            parts.append(f"  {endpoint}: {limit}")

    tech = memory.get("tech_stack", [])
    if tech:
        parts.append(f"\nTech stack: {', '.join(tech[:15])}")

    endpoints = memory.get("known_endpoints", [])
    if endpoints:
        parts.append(f"\nInteresting endpoints from prior runs ({len(endpoints)} total, showing newest 15):")
        for ep in endpoints[-15:]:
            parts.append(f"  {ep}")

    lessons = memory.get("lessons", [])
    if lessons:
        parts.append("\nLessons from previous runs:")
        for lesson in lessons[-10:]:
            parts.append(f"  • {lesson}")

    custom = memory.get("custom_wordlist", [])
    if custom:
        parts.append(f"\nParams/paths that worked on this target: {', '.join(custom[:30])}")

    parts.append("=== END MEMORY ===")
    return "\n".join(parts)


def update_from_run(
    memory: dict,
    state: dict,
    scope: dict,
    log: Optional[logging.Logger] = None,
) -> dict:
    """
    Call at end of run to extract lessons and update memory from this run's findings.
    Calls Claude Opus to do the extraction — falls back to simple heuristics if unavailable.
    """
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        return _heuristic_update(memory, state)

    try:
        import anthropic
        client = anthropic.Anthropic(api_key=api_key)
        return _claude_update(memory, state, scope, client, log)
    except Exception as exc:
        if log:
            log.warning("Memory Claude update failed (%s) — using heuristics", exc)
        return _heuristic_update(memory, state)


def record_submission(
    memory: dict,
    title: str,
    category: str,
    severity: str,
    status: str = "pending",
    bounty: int = 0,
) -> dict:
    """Call this manually (or from morning-review) when you submit a report."""
    memory.setdefault("submitted", []).append({
        "title": title,
        "category": category,
        "severity": severity,
        "status": status,
        "bounty": bounty,
        "date": _now()[:10],
    })
    return memory


def update_submission_status(memory: dict, title_fragment: str, status: str, bounty: int = 0) -> dict:
    """Update the status of a previously recorded submission (accepted/duplicate/na)."""
    for s in memory.get("submitted", []):
        if title_fragment.lower() in s["title"].lower():
            s["status"] = status
            if bounty:
                s["bounty"] = bounty
    return memory


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S")


def _migrate(data: dict) -> dict:
    data["version"] = MEMORY_VERSION
    data.setdefault("auth", {})
    data.setdefault("rate_limits", {})
    data.setdefault("tech_stack", [])
    data.setdefault("custom_wordlist", [])
    return data


def _heuristic_update(memory: dict, state: dict) -> dict:
    """Extract obvious facts from state without calling Claude."""
    findings = state.get("all_findings", [])
    for f in findings:
        ep = f.get("url", "")
        if ep and ep not in memory.get("known_endpoints", []):
            memory.setdefault("known_endpoints", []).append(ep)

    tech = state.get("technologies", [])
    for t in tech:
        if t not in memory.get("tech_stack", []):
            memory.setdefault("tech_stack", []).append(t)

    memory.setdefault("known_endpoints", [])
    memory["known_endpoints"] = memory["known_endpoints"][-500:]  # cap at 500
    return memory


def _claude_update(
    memory: dict,
    state: dict,
    scope: dict,
    client,
    log: Optional[logging.Logger],
) -> dict:
    findings_summary = json.dumps(state.get("all_findings", [])[:50], indent=2)[:6000]
    tech = json.dumps(state.get("technologies", []))
    endpoints = json.dumps(state.get("discovered_urls", [])[:100])
    current_memory_summary = json.dumps({
        k: v for k, v in memory.items()
        if k not in ("submitted",)
    }, indent=2)[:3000]

    prompt = f"""You are updating a bug bounty program's knowledge base after a completed run.

Current program memory (abridged):
{current_memory_summary}

This run's findings (up to 50):
{findings_summary}

Discovered endpoints this run:
{endpoints}

Detected technologies:
{tech}

Extract the following and return as JSON (only the JSON, no prose):
{{
  "new_lessons": ["list of 1-sentence lessons learned this run — rate limits hit, auth oddities, interesting patterns, what was a dead end"],
  "new_endpoints": ["interesting new endpoints NOT already in known_endpoints"],
  "new_avoid": ["endpoints/patterns confirmed heavily duped or OOS — infer from findings marked as duplicate or already-known"],
  "tech_stack_additions": ["new technologies detected"],
  "custom_wordlist_additions": ["parameter names or path segments that found vulnerabilities"],
  "auth_notes": ["new observations about auth behavior, token expiry, session handling"],
  "rate_limit_observations": {{"endpoint_pattern": "observed_limit"}}
}}

Be conservative — only add what you're confident about from this run's data.
Return only valid JSON."""

    if log:
        log.info("Updating program memory with Claude...")

    resp = client.messages.create(
        model=_CLAUDE_ANALYSIS_MODEL,
        max_tokens=2000,
        messages=[{"role": "user", "content": prompt}],
    )

    text = resp.content[0].text.strip()
    # Strip markdown code fences if present
    if text.startswith("```"):
        text = re.sub(r"^```[a-z]*\n?", "", text).rstrip("`").strip()

    try:
        extracted = json.loads(text)
    except json.JSONDecodeError:
        if log:
            log.warning("Memory extraction returned non-JSON — skipping Claude update")
        return _heuristic_update(memory, state)

    def _merge_list(key, extracted_key, cap=500):
        existing = set(memory.get(key, []))
        new_items = [x for x in extracted.get(extracted_key, []) if x and x not in existing]
        merged = list(existing) + new_items
        memory[key] = merged[-cap:]

    _merge_list("lessons", "new_lessons", cap=100)
    _merge_list("known_endpoints", "new_endpoints", cap=500)
    _merge_list("avoid", "new_avoid", cap=200)
    _merge_list("tech_stack", "tech_stack_additions", cap=100)
    _merge_list("custom_wordlist", "custom_wordlist_additions", cap=200)

    for note in extracted.get("auth_notes", []):
        if note not in memory.get("auth", {}).get("notes", []):
            memory.setdefault("auth", {}).setdefault("notes", []).append(note)
    memory["auth"]["notes"] = memory["auth"].get("notes", [])[-20:]

    for ep, limit in extracted.get("rate_limit_observations", {}).items():
        memory.setdefault("rate_limits", {})[ep] = limit

    return memory

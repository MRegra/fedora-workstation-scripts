#!/usr/bin/env python3
"""
Pre-flight check — run this before every overnight launch.

Usage:
  python3 pre-run-check.py scope.yaml
  python3 pre-run-check.py scope.yaml --fix   # auto-update nuclei templates

Prints GO / WARN / BLOCK for each check. Exits non-zero if any BLOCK found.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

try:
    import yaml
    _HAS_YAML = True
except ImportError:
    _HAS_YAML = False

RESET = "\033[0m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
RED = "\033[31m"
BOLD = "\033[1m"

def _c(text, code):
    return f"{code}{text}{RESET}" if sys.stdout.isatty() else text

def go(msg):   print(f"  {_c('GO   ', GREEN + BOLD)} {msg}")
def warn(msg): print(f"  {_c('WARN ', YELLOW + BOLD)} {msg}")
def block(msg):print(f"  {_c('BLOCK', RED + BOLD)}  {msg}")

def check_scope(scope_path: Path, scope: dict, blocks: list) -> None:
    print(_c("\n[1] Scope file", BOLD))

    prog = scope.get("program", {})
    if not prog.get("name"):
        block("program.name is empty"); blocks.append("program.name")
    else:
        go(f"program.name: {prog['name']}")

    platform = prog.get("platform", "")
    if platform not in ("intigriti", "bugcrowd"):
        block(f"program.platform must be 'intigriti' or 'bugcrowd', got: '{platform}'")
        blocks.append("platform")
    else:
        go(f"platform: {platform}")

    domains = scope.get("in_scope", {}).get("domains", [])
    if not domains:
        block("in_scope.domains is empty — nothing to scan"); blocks.append("domains")
    else:
        go(f"in_scope.domains: {len(domains)} entries")

    rl = scope.get("rate_limit", {})
    nmap_timing = rl.get("nmap_timing", 3)
    if nmap_timing >= 4:
        block(f"nmap_timing is {nmap_timing} — never use T4/T5 on bug bounty targets")
        blocks.append("nmap_timing")
    else:
        go(f"nmap timing: T{nmap_timing}")

    rps = rl.get("requests_per_second", 5)
    if rps > 20:
        warn(f"requests_per_second={rps} is high — triagers notice aggressive scanners")
    else:
        go(f"rate limit: {rps} req/s")


def check_api_key(blocks: list) -> None:
    print(_c("\n[2] API key", BOLD))
    key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not key:
        block("ANTHROPIC_API_KEY not set — export it before launching")
        blocks.append("ANTHROPIC_API_KEY")
    elif not key.startswith("sk-ant-"):
        warn("ANTHROPIC_API_KEY doesn't look like an Anthropic key (expected sk-ant-...)")
    else:
        go(f"ANTHROPIC_API_KEY set ({key[:12]}...)")


def check_tools(scope: dict, blocks: list) -> None:
    print(_c("\n[3] Security tools", BOLD))

    required = ["subfinder", "httpx", "nuclei", "katana"]
    optional = ["gau", "nmap", "dalfox", "ffuf", "sqlmap", "interactsh-client", "amass"]

    skip = scope.get("scan", {}).get("skip_tools", [])

    for tool in required:
        if shutil.which(tool):
            go(f"{tool}")
        else:
            block(f"{tool} not found — required for recon/scan phases")
            blocks.append(tool)

    for tool in optional:
        if tool in skip:
            go(f"{tool} (skipped by scope config)")
        elif shutil.which(tool):
            go(f"{tool}")
        else:
            warn(f"{tool} not found — some PoC capabilities will be skipped")

    if not shutil.which("python3"):
        block("python3 not found"); blocks.append("python3")

    # Check playwright
    try:
        result = subprocess.run(
            ["python3", "-c", "from playwright.sync_api import sync_playwright"],
            capture_output=True, timeout=5
        )
        if result.returncode == 0:
            go("playwright (Python)")
        else:
            warn("playwright not installed — browser phases will be skipped")
    except Exception:
        warn("playwright check failed")


def check_browser_config(scope: dict, blocks: list) -> None:
    browser_cfg = scope.get("browser", {})
    modes = browser_cfg.get("modes", [])
    if not modes:
        return

    print(_c("\n[4] Browser agent config", BOLD))
    go(f"browser modes: {', '.join(modes)}")

    if "idor" in modes:
        accounts = scope.get("test_accounts", {}).get("accounts", [])
        filled = [a for a in accounts if a.get("username") and a.get("password")]
        if len(filled) < 2:
            warn("IDOR mode enabled but fewer than 2 test accounts configured in scope.yaml")
            warn("  Add testuser1 and testuser2 under test_accounts.accounts")
        else:
            go(f"test accounts: {len(filled)} configured")

        login_url = scope.get("test_accounts", {}).get("auth", {}).get("login_url", "")
        if not login_url:
            warn("test_accounts.auth.login_url is empty — IDOR login flow may fail")
        else:
            go(f"auth login_url: {login_url[:60]}")


def check_disk(output_dir: Path, blocks: list) -> None:
    print(_c("\n[5] Disk space", BOLD))
    try:
        stat = shutil.disk_usage(output_dir.parent if not output_dir.exists() else output_dir)
        free_gb = stat.free / 1024**3
        if free_gb < 1.0:
            block(f"Only {free_gb:.1f}GB free — screenshots and nuclei output need ~1GB")
            blocks.append("disk")
        elif free_gb < 3.0:
            warn(f"{free_gb:.1f}GB free — tight, consider clearing old output/ directories")
        else:
            go(f"{free_gb:.1f}GB free")
    except Exception as exc:
        warn(f"Could not check disk space: {exc}")


def check_memory(scope: dict) -> None:
    print(_c("\n[6] Program memory", BOLD))
    import re
    safe_name = re.sub(r"[^a-z0-9_-]", "_", scope["program"]["name"].lower())[:60]
    mem_path = Path("memory") / f"{safe_name}.json"
    if mem_path.exists():
        with open(mem_path) as f:
            mem = json.load(f)
        submitted = len(mem.get("submitted", []))
        lessons = len(mem.get("lessons", []))
        runs = mem.get("run_count", 0)
        go(f"Memory found: {runs} prior runs, {submitted} submitted, {lessons} lessons")
    else:
        go("No memory file yet — first run for this program")


def check_nuclei_templates(fix: bool) -> None:
    print(_c("\n[7] Nuclei templates", BOLD))
    if not shutil.which("nuclei"):
        warn("nuclei not installed — skipping template check")
        return

    templates_dir = Path.home() / ".local" / "nuclei-templates"
    if not templates_dir.exists():
        warn("Nuclei templates not found — run: nuclei -update-templates")
        return

    if fix:
        print("  Updating nuclei templates...")
        subprocess.run(["nuclei", "-update-templates", "-silent"], capture_output=True)
        go("Templates updated")
    else:
        import time
        mtime = templates_dir.stat().st_mtime
        age_days = (time.time() - mtime) / 86400
        if age_days > 7:
            warn(f"Templates last updated {age_days:.0f} days ago — run with --fix to update")
        else:
            go(f"Templates updated {age_days:.0f} days ago")


def check_previous_run(output_dir: Path) -> None:
    print(_c("\n[8] Previous run check", BOLD))
    pid_file = Path("nightly.pid")
    if pid_file.exists():
        pid = pid_file.read_text().strip()
        try:
            os.kill(int(pid), 0)
            warn(f"Previous run (PID {pid}) appears still running — stop it first:")
            warn(f"  kill {pid}")
        except (ProcessLookupError, ValueError):
            go("No previous run still active")
    else:
        go("No previous run PID file")

    log = Path("nightly.log")
    if log.exists():
        size_kb = log.stat().st_size / 1024
        go(f"nightly.log exists ({size_kb:.0f}KB) — will be overwritten on next launch")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("scope", nargs="?", default="scope.yaml")
    ap.add_argument("--fix", action="store_true", help="Auto-fix where possible (update nuclei templates)")
    args = ap.parse_args()

    scope_path = Path(args.scope)
    blocks: list = []

    print(_c(f"\n╔══ Pre-flight check: {scope_path} ══╗", BOLD))

    if not scope_path.exists():
        block(f"Scope file not found: {scope_path}")
        print(f"\n  Create it with: cp scope.example.yaml {scope_path}\n")
        sys.exit(1)

    if not _HAS_YAML:
        block("pyyaml not installed: pip3 install pyyaml")
        sys.exit(1)

    with open(scope_path) as f:
        scope = yaml.safe_load(f)

    output_dir = Path(scope.get("output", {}).get("directory", "./output"))

    check_scope(scope_path, scope, blocks)
    check_api_key(blocks)
    check_tools(scope, blocks)
    check_browser_config(scope, blocks)
    check_disk(output_dir, blocks)
    check_memory(scope)
    check_nuclei_templates(args.fix)
    check_previous_run(output_dir)

    print()
    if blocks:
        print(_c(f"  BLOCKED — fix the following before launching: {', '.join(blocks)}", RED + BOLD))
        sys.exit(1)
    else:
        print(_c("  ALL CLEAR — safe to launch:", GREEN + BOLD))
        print(f"    bash nightly-launch.sh {scope_path}\n")


if __name__ == "__main__":
    main()

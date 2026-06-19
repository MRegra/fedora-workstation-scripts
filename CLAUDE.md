# fedora-workstation-scripts

Personal toolbox for a Fedora Linux power user + bug bounty hunter (Intigriti / Bugcrowd).

## Repository structure

```
soft-reboot/        — reboot-equivalent cleanup script (no actual reboot)
system-audit/       — security + performance audit with PASS/WARN/ALERT output
local-ai-agent/     — MCP server exposing local Ollama LLM to Claude Code
bug-bounty-agent/   — overnight AI pipeline: recon → scan → browser → PoC → report
```

## Active development branch

`claude/fedora-repo-status-fyb549` — all new work goes here, PR #1 open.

## bug-bounty-agent — the main project

An overnight automation pipeline. Claude Opus orchestrates; Claude Haiku handles cheap navigation steps; Ollama (llama3.3:70b) runs local triage for free.

### Key files

| File | Purpose |
|---|---|
| `orchestrator.py` | Main pipeline — `python3 orchestrator.py --scope scope.yaml` |
| `browser_agent.py` | Claude + Playwright agentic browser testing (4 modes) |
| `playwright_mcp_server.py` | MCP server for direct Claude Code browser control |
| `memory.py` | Per-program knowledge persistence across runs |
| `morning-review.py` | Triage overnight findings, ranked by severity + PoC |
| `polish-report.py` | Claude Opus rewrites draft reports for platform submission |
| `pre-run-check.py` | Pre-flight validation before overnight launches |
| `nightly-launch.sh` | Detach orchestrator to background with nohup |
| `scope.example.yaml` | Full config template — copy to scope.yaml |
| `daily-workflow.md` | Exact 60-minute daily routine for 3-5 reports/week |
| `private-programs.md` | How to get private program invites (Intigriti / Bugcrowd) |
| `ethical-guidelines.md` | Platform rules, prohibited actions, disclosure |
| `install-tools.sh` | Install all security tools |

### Daily workflow (1h/day, 3-5 reports/week)

```bash
# Morning
python3 morning-review.py --dir output/ --platform intigriti
python3 polish-report.py --rank 1 --platform intigriti
# Review + submit on platform

# Night
python3 pre-run-check.py scope.yaml
bash nightly-launch.sh scope.yaml
```

### Run a single phase

```bash
python3 orchestrator.py --scope scope.yaml --phases recon scan
python3 orchestrator.py --scope scope.yaml --phases browser poc report
```

### Memory system

Per-program knowledge accumulates in `memory/{program_name}.json`:
- Previously submitted findings (prevents re-submission)
- Auth patterns, rate limits, tech stack
- Lessons extracted by Claude after each run

View memory for a program:
```bash
python3 -c "import memory, json; print(json.dumps(memory.load('Program Name', __import__('pathlib').Path('memory')), indent=2))"
```

Record a submission outcome:
```bash
python3 -c "
import memory; from pathlib import Path
m = memory.load('Program Name', Path('memory'))
m = memory.update_submission_status(m, 'IDOR /api/invoices', 'accepted', bounty=500)
memory.save('Program Name', m, Path('memory'))
"
```

## Safety constraints (never change these)

- `is_in_scope()` is called before every network operation — removing it breaks the safety model
- sqlmap is hardcoded to `--level=1 --risk=1 --technique=BT --banner` — no data exfiltration
- Browser agent has a 40-step max per session and 3 session max per host

## Cost

~$120–130/month Claude API for 5 programs × 4 runs/week. Haiku for navigation, Opus for analysis and reports.

## Local AI setup

```bash
# ~/.claude/mcp.json
{
  "mcpServers": {
    "local-llm": {
      "command": "python3",
      "args": ["/home/user/fedora-workstation-scripts/local-ai-agent/mcp_server.py"]
    },
    "browser": {
      "command": "python3",
      "args": ["/home/user/fedora-workstation-scripts/bug-bounty-agent/playwright_mcp_server.py"],
      "env": { "ALLOWED_DOMAINS": "example.com" }
    }
  }
}
```

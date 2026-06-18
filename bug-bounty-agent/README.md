# Bug Bounty Agent

An overnight AI orchestrator for bug bounty hunting. Claude drives the full pipeline — recon,
scanning, browser-based manual testing, PoC generation, and report writing — while you sleep.

**Safety first:** Every network call is gated against `scope.yaml`. The agent will refuse to touch
anything outside the declared in-scope domains. Read `ethical-guidelines.md` before running.

---

## Architecture

```
scope.yaml
    │
    ▼
orchestrator.py
    │
    ├── phase_recon ─────── subfinder · httpx · katana · gau · JS analysis
    │                        (live hosts + URL corpus)
    │
    ├── phase_scan ──────── nuclei · nmap · ffuf · header injection · JS secrets
    │                        (vulnerability detection)
    │
    ├── phase_browser ───── browser_agent.py ──── Claude + Playwright
    │                        (manual-style AI testing)   (4 modes)
    │
    ├── phase_poc ───────── dalfox · sqlmap · interactsh · curl
    │                        (non-destructive proof of exploit)
    │
    └── phase_report ────── Claude Opus: validate · write · chain-analysis
                             (platform-ready reports + attack chains)
```

**Claude model routing (cost control)**

| Task | Model | Reason |
|---|---|---|
| Browser navigation decisions (steps 1-10) | `claude-haiku-4-5` | Cheap; navigation doesn't need heavy reasoning |
| Browser analysis (steps 11+) | `claude-opus-4-8` | Finds subtle logic bugs |
| Vulnerability validation | `claude-opus-4-8` | Eliminates false positives |
| Report writing | `claude-opus-4-8` | Platform-quality prose |
| Chain analysis | `claude-opus-4-8` | Links findings into multi-step attack chains |

**Local AI (Ollama) via MCP**

The `local-ai-agent/mcp_server.py` gives Claude Code a `local_llm` tool backed by Ollama
(`llama3.3:70b`). Use it for bulk triage that doesn't need Anthropic-level reasoning — it costs $0.

---

## Installation

### 1. Python dependencies

```bash
pip3 install --user anthropic requests pyyaml playwright
python3 -m playwright install chromium
```

### 2. Security tools

```bash
bash install-tools.sh
```

This installs: `subfinder`, `httpx`, `nuclei`, `katana`, `gau`, `dalfox`, `ffuf`,
`interactsh-client`, `sqlmap`, `nmap`. Requires Go and dnf.

### 3. Add ~/go/bin to PATH

```bash
echo 'export PATH="$PATH:$HOME/go/bin"' >> ~/.bashrc
source ~/.bashrc
```

### 4. API key

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
# Add to ~/.bashrc to persist
```

### 5. (Optional) Ollama for local triage

```bash
curl -fsSL https://ollama.com/install.sh | sh
sudo systemctl enable --now ollama
ollama pull llama3.3:70b        # ~40GB download
ollama pull qwen2.5-coder:32b   # ~20GB, better for code analysis
```

---

## Configuration

Copy and edit the scope file:

```bash
cp scope.example.yaml scope.yaml
$EDITOR scope.yaml
```

Key sections:

```yaml
program:
  name: "Example Corp"
  platform: "intigriti"   # intigriti | bugcrowd

in_scope:
  domains:
    - "*.example.com"
  exclude:
    - "staging.example.com"

rate_limit:
  requests_per_second: 5   # be conservative — triagers notice aggressive scanners
  nuclei_rate: 20
  nmap_timing: 3            # never T4 or T5

test_accounts:             # for IDOR testing — create these yourself on the target
  auth:
    login_url: "https://app.example.com/api/auth/login"
    body: '{"email":"{u}","password":"{p}"}'
    token_path: "$.data.token"
    token_header: "Authorization"
    token_prefix: "Bearer "
  accounts:
    - username: "testuser1@example.com"
      password: "testpass1"
    - username: "testuser2@example.com"
      password: "testpass2"
```

---

## Usage

### Dry run (shows what would happen, no network calls)

```bash
python3 orchestrator.py --scope scope.yaml --dry-run
```

### Full overnight run

```bash
python3 orchestrator.py --scope scope.yaml
```

### Specific phases only

```bash
python3 orchestrator.py --scope scope.yaml --phases recon scan
python3 orchestrator.py --scope scope.yaml --phases browser poc report
```

### Check output in the morning

```bash
ls output/
cat output/reports/*.md
cat output/findings.json | python3 -m json.tool | less
```

### Push notification when done (via ntfy.sh)

Set `output.notify_ntfy_topic: "your-topic"` in `scope.yaml`. Install the ntfy app on your
phone and subscribe to the topic.

---

## What Each Phase Produces

| Phase | Output |
|---|---|
| `recon` | `subdomains.txt`, `live_hosts.txt`, `urls.txt`, `js_files.txt`, screenshots |
| `scan` | `nuclei_findings.json`, `nmap_open_ports.txt`, `header_injection.json`, `js_secrets.json` |
| `browser` | `browser_findings.json`, screenshots per tested host |
| `poc` | `poc/` directory — HTTP request files, dalfox output, sqlmap banner, interactsh callbacks |
| `report` | `reports/*.md` per finding, `chain_analysis.md` for multi-step attacks |

---

## PoC Methodology (non-destructive)

The agent proves exploitability without causing harm:

| Vulnerability | PoC Technique | What It Proves |
|---|---|---|
| XSS | `dalfox` — injects `alert(1)` | JS execution confirmed |
| SQLi | `sqlmap --level=1 --risk=1 --technique=BT --banner` | DB banner only, no dump |
| Open redirect | Redirect to `portswigger.net` | Redirect confirmed |
| CORS | Reflect `evil.example.com` origin | Credential exposure |
| LFI | Request `/etc/passwd` (check response) | File read confirmed |
| SSTI | Inject `{{7*7}}` — verify `49` in response | Template execution |
| SSRF | `interactsh-client` OOB DNS/HTTP callback | Out-of-band callback confirmed |
| IDOR | Account A resource → Account B session | Cross-account access confirmed |
| JS secrets | Pattern match on live JS assets | Secret present in production |
| Header injection | Host/X-Forwarded-Host reflection | Header poisoning confirmed |

**Hard limits:** no `--dump`, no `--os-shell`, no destructive writes, no DoS.

---

## Browser Agent Modes

Claude autonomously drives Chromium to test each live host:

| Mode | What It Tests |
|---|---|
| `discovery` | Maps all pages, API endpoints, forms; logs network requests; looks for over-exposed data |
| `idor` | Two-session A/B: logs in as User A, grabs resource IDs, switches to User B, attempts access |
| `logic` | Price manipulation, workflow step skipping, role escalation, mass assignment |
| `auth` | OAuth flows, password reset poisoning, session persistence after logout, Host header injection |

Configure which modes run and how many hosts per run in `scope.yaml`:

```yaml
browser:
  modes: [discovery, idor, logic, auth]
  max_hosts: 10
```

---

## MCP Browser Server (for direct Claude Code use)

`playwright_mcp_server.py` lets you control a browser directly from Claude Code chat:

```json
// ~/.claude/mcp.json
{
  "mcpServers": {
    "browser": {
      "command": "python3",
      "args": ["/home/user/fedora-workstation-scripts/bug-bounty-agent/playwright_mcp_server.py"],
      "env": {
        "BROWSER_HEADLESS": "true",
        "ALLOWED_DOMAINS": "example.com,api.example.com"
      }
    }
  }
}
```

Then in Claude Code: *"Use the browser to navigate to app.example.com and test the login for
password reset poisoning"* — Claude will drive Chromium directly.

---

## Cost Breakdown (realistic monthly estimate)

Assumptions: 5 programs active, 1 overnight run per program per week (~20 runs/month),
~100 live hosts per run, browser mode on ~20 hosts per run.

| Component | Cost driver | Monthly cost |
|---|---|---|
| Recon phase | Haiku (URL analysis) | ~$3 |
| Scan phase | Haiku (finding classification) | ~$5 |
| Browser agent (nav steps 1-10/host) | Haiku × 20 hosts × 10 steps | ~$8 |
| Browser agent (analysis steps 11+/host) | Opus × 20 hosts × some steps | ~$60 |
| Report writing + validation | Opus (per finding, ~20 findings) | ~$25 |
| Chain analysis | Opus (1 call per run) | ~$10 |
| Local Ollama triage | Free (runs on your hardware) | $0 |
| **Total Claude API** | | **~$111/month** |
| Interactsh (OOB) | Self-hosted or interactsh.com | $0–$5 |
| Electricity (GPU Ollama) | Continuous 16h runs | ~$10 |
| **Total** | | **~$120–130/month** |

This is the realistic floor. It scales linearly — more programs or more hosts per run cost more.

---

## Realistic Earnings Timeline

Bug bounty income is highly non-linear. Here is a conservative trajectory assuming consistent
daily effort on top of the overnight automation:

| Month | Activity | Realistic range |
|---|---|---|
| 1 | Learning platform ropes, first public reports, lots of dups | $0–$200 |
| 2 | First valid bounties, refining report quality | $200–$800 |
| 3 | Invited to first private program, finding logic bugs | $800–$2,000 |
| 4 | Multiple private programs, recognizing patterns | $2,000–$4,000 |
| 5 | Consistent private program income, chain bugs | $4,000–$7,000 |
| 6 | Established researcher, select high-signal programs | $5,000–$12,000 |

**What drives the variance:**

- Private programs pay 2–5x more than public programs for equivalent bugs
- Logic bugs (IDOR, auth bypass, business logic) pay far more than XSS/info-disc
- Report quality is heavily weighted — unclear reports get closed or downgraded
- Being first matters: a well-known public target may have 100 researchers on it; a newly
  launched private program may have 20

**The $10k/month target is achievable but requires:** 3+ active private programs, consistently
finding P1/P2-equivalent bugs (IDOR, auth bypass, chain attacks), and Opus-quality reports.
The automation gets you to the finding; the report quality is what gets you paid.

---

## Report Quality Tips

Triagers read hundreds of reports. These are the things that get yours accepted at full severity:

1. **Lead with impact, not the bug.** "An unauthenticated attacker can read any user's private
   messages by changing the `user_id` parameter" is better than "Found IDOR in /api/messages".

2. **Include a reproduction curl/Python script.** Copy-pasteable. No manual steps required.

3. **Attach a PoC screenshot** of the actual impact (the data you read, the XSS firing,
   the OOB callback).

4. **State CVSS v3.1 score** for Intigriti. Calculate it at first.kvdt.com or the NVD calculator.
   Don't over-inflate — triagers will dock you if your vector string doesn't match the impact.

5. **Name the Bugcrowd VRT category** for Bugcrowd reports.
   E.g. `Broken Access Control > IDOR > Sensitive Data Exposure`.

6. **Include a one-paragraph business impact.** Why does this matter to a non-technical product
   manager? Revenue loss? Regulatory exposure? Reputation?

---

## Vulnerability Priority Guide

Focus time on these — they pay best relative to effort:

| Bug type | Typical payout (private) | Automation coverage |
|---|---|---|
| IDOR (P1/P2) | $2,000–$10,000 | Browser agent + PoC |
| Auth bypass | $3,000–$15,000 | Browser auth mode |
| SQLi (P1) | $2,000–$8,000 | sqlmap banner PoC |
| SSRF (P1) | $2,000–$10,000 | interactsh OOB |
| XSS + auth cookie (P2) | $500–$3,000 | dalfox + cookie check |
| Business logic | $1,000–$10,000 | Browser logic mode |
| Exposed secrets (P1) | $500–$5,000 | JS pattern scan |
| Open redirect | $50–$300 | curl PoC |
| Info disclosure | $50–$500 | nuclei exposures |

---

## Files in This Directory

| File | Purpose |
|---|---|
| `orchestrator.py` | Main pipeline — run this |
| `browser_agent.py` | Claude + Playwright browser testing engine |
| `playwright_mcp_server.py` | MCP server for direct Claude Code browser use |
| `scope.example.yaml` | Scope config template |
| `install-tools.sh` | Install all security tools |
| `requirements.txt` | Python dependencies |
| `ethical-guidelines.md` | Platform rules, prohibited actions, disclosure |
| `private-programs.md` | How to get private program invites |

---

## Quick Start Checklist

- [ ] `pip3 install --user anthropic requests pyyaml playwright`
- [ ] `python3 -m playwright install chromium`
- [ ] `bash install-tools.sh`
- [ ] Add `~/go/bin` to `$PATH`
- [ ] `export ANTHROPIC_API_KEY="sk-ant-..."`
- [ ] `cp scope.example.yaml scope.yaml` and fill in your target
- [ ] Create two test accounts on the target program
- [ ] `python3 orchestrator.py --scope scope.yaml --dry-run` (verify)
- [ ] `python3 orchestrator.py --scope scope.yaml` (run overnight)
- [ ] Check `output/reports/` in the morning
- [ ] Submit valid findings manually (review each one before submitting)

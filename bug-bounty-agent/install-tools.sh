#!/usr/bin/env bash
# Install security tools for the bug bounty orchestrator on Fedora.
# Run as your normal user (not root) — tools install to ~/go/bin and ~/.local/bin.
set -Eeuo pipefail

say()  { printf '\n=== %s ===\n' "$1"; }
ok()   { printf '  OK: %s\n' "$1"; }
skip() { printf '  SKIP: %s (already installed)\n' "$1"; }
warn() { printf '  WARN: %s\n' "$1"; }

# ── Python deps ──────────────────────────────────────────────────────────────
say "Python dependencies"
pip3 install --user anthropic requests pyyaml
ok "anthropic, requests, pyyaml"

# ── Go toolchain (needed for subfinder, httpx, nuclei, gau, katana) ─────────
say "Go toolchain"
if ! command -v go &>/dev/null; then
  warn "Go not found. Installing via dnf..."
  sudo dnf install -y golang
fi
GO_VERSION="$(go version 2>/dev/null | awk '{print $3}')"
ok "Go: $GO_VERSION"

# Ensure ~/go/bin is in PATH
GOBIN="$HOME/go/bin"
if ! echo "$PATH" | grep -q "$GOBIN"; then
  warn "Add this to ~/.bashrc or ~/.zshrc:"
  warn "  export PATH=\"\$PATH:$GOBIN\""
  export PATH="$PATH:$GOBIN"
fi

# ── Go-based tools ───────────────────────────────────────────────────────────
say "subfinder (subdomain enumeration)"
if command -v subfinder &>/dev/null; then skip subfinder
else go install -v github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest && ok subfinder
fi

say "httpx (HTTP prober)"
if command -v httpx &>/dev/null; then skip httpx
else go install -v github.com/projectdiscovery/httpx/cmd/httpx@latest && ok httpx
fi

say "nuclei (vulnerability scanner)"
if command -v nuclei &>/dev/null; then skip nuclei
else go install -v github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest && ok nuclei
fi

say "katana (web crawler)"
if command -v katana &>/dev/null; then skip katana
else go install -v github.com/projectdiscovery/katana/cmd/katana@latest && ok katana
fi

say "gau (URL discovery from archives)"
if command -v gau &>/dev/null; then skip gau
else go install -v github.com/lc/gau/v2/cmd/gau@latest && ok gau
fi

# ── System tools ─────────────────────────────────────────────────────────────
say "nmap"
if command -v nmap &>/dev/null; then skip nmap
else sudo dnf install -y nmap && ok nmap
fi

say "amass (optional — slower, thorough)"
if command -v amass &>/dev/null; then skip amass
else
  warn "amass not in dnf — install via snap or Go:"
  warn "  go install -v github.com/owasp-amass/amass/v4/...@master"
fi

# ── Nuclei templates ─────────────────────────────────────────────────────────
say "Nuclei templates"
if command -v nuclei &>/dev/null; then
  nuclei -update-templates -silent
  ok "Templates updated at ~/.local/nuclei-templates"
else
  warn "nuclei not found — run this after installing nuclei"
fi

# ── Ollama ───────────────────────────────────────────────────────────────────
say "Ollama (local LLM for triage)"
if command -v ollama &>/dev/null; then
  skip ollama
  say "Pulling triage model (llama3.3:70b — requires ~40GB, Ctrl+C to skip)"
  ollama pull llama3.3:70b || warn "Model pull failed or skipped"
else
  warn "Ollama not found. Install:"
  warn "  curl -fsSL https://ollama.com/install.sh | sh"
  warn "  sudo systemctl enable --now ollama"
  warn "  ollama pull llama3.3:70b"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
printf '\n'
say "Tool availability summary"
for t in subfinder httpx nuclei katana gau nmap amass ollama; do
  if command -v "$t" &>/dev/null; then printf '  %-12s INSTALLED\n' "$t"
  else printf '  %-12s MISSING\n' "$t"; fi
done

printf '\nSet your API key before running:\n'
printf '  export ANTHROPIC_API_KEY="sk-ant-..."\n\n'
printf 'Then run:\n'
printf '  cp scope.example.yaml scope.yaml\n'
printf '  # Edit scope.yaml for your program\n'
printf '  python3 orchestrator.py --scope scope.yaml --dry-run\n'
printf '  python3 orchestrator.py --scope scope.yaml\n\n'

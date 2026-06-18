# Implementation task: local LLM MCP server (OpenAI / Codex backend)

## Context

I run Claude Code as my primary AI coding assistant. I want to add OpenAI's
models (GPT-4o, o4-mini — the models that power Codex CLI) as a secondary tool
that Claude can call for parallel tasks, opinion checks, or when I want a
second-model perspective without leaving my Claude workflow.

Additionally, if you are running as the Codex CLI agent, this document also
describes how to configure yourself (Codex CLI) as a Claude Code equivalent
with the same MCP server available, so both agents share the same local tool.

The integration point is the Model Context Protocol (MCP): a JSON-RPC server
that Claude Code or Codex CLI spawns as a subprocess and calls via stdin/stdout.
I already have `mcp_server.py` (in the same directory as this file). Your job is
to install dependencies, configure credentials, and wire everything into both
Claude Code and Codex CLI configs.

## Can Codex back Claude, and vice versa? Yes.

The `mcp_server.py` supports two backends:
- `ollama` — free, local, offline
- `openai` — any OpenAI-compatible API, including the one Codex CLI uses

So from Claude's perspective, calling `local_llm(backend="openai", model="o4-mini")`
routes the request through OpenAI's API — effectively asking Codex's underlying
model. This is useful for:
- Getting a second opinion (different model, different training)
- Using o4-mini for fast cheap subtasks from inside a Claude session
- Running both agents on the same task and comparing results

## Prerequisites to verify first

1. Python 3.10+ (`python3 --version`)
2. pip (`pip --version` or `pip3 --version`)
3. An OpenAI API key with access to gpt-4o and/or o4-mini
4. Claude Code CLI (`claude --version`)
5. Optionally: Codex CLI (`codex --version`) — install via `npm install -g @openai/codex`

## Steps to implement

### 1. Install Python dependency

```bash
pip3 install --user requests
```

Verify: `python3 -c "import requests; print('ok')"` should print `ok`.

### 2. Store your OpenAI API key

Add to `~/.bashrc` or `~/.zshrc` (whichever shell you use):
```bash
export OPENAI_API_KEY="sk-..."
```

Then: `source ~/.bashrc` (or open a new terminal).

Verify: `echo $OPENAI_API_KEY` should show the key.

### 3. Find the absolute path to mcp_server.py

```bash
realpath mcp_server.py
```

Note this path — you need it in the next steps.

### 4. Wire into Claude Code

Create or merge into `~/.claude/mcp.json`
(replace `/ABSOLUTE/PATH` with the path from step 3):

```json
{
  "mcpServers": {
    "openai-llm": {
      "command": "python3",
      "args": ["/ABSOLUTE/PATH/TO/mcp_server.py"],
      "env": {
        "LOCAL_LLM_BACKEND": "openai",
        "OPENAI_MODEL": "o4-mini",
        "OPENAI_API_KEY": "sk-..."
      }
    }
  }
}
```

Note: storing the key in `mcp.json` is convenient but less secure than the
environment variable approach. If security matters, omit `OPENAI_API_KEY` from
`mcp.json` and ensure it's exported in your shell before launching Claude Code.

### 5. Wire into Codex CLI (optional — skip if not using Codex CLI)

Codex CLI reads MCP servers from `~/.codex/config.yaml`.
Create or merge the following:

```yaml
mcpServers:
  local-llm:
    command: python3
    args:
      - /ABSOLUTE/PATH/TO/mcp_server.py
    env:
      LOCAL_LLM_BACKEND: openai
      OPENAI_MODEL: o4-mini
      # OPENAI_API_KEY is already in your shell env
```

Now Codex CLI itself has the same `local_llm` tool available and can call
`o4-mini` as a fast cheap sub-task worker — or call `ollama` if you also
have Ollama installed.

### 6. Verify the MCP server starts cleanly

```bash
echo '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}' \
  | LOCAL_LLM_BACKEND=openai OPENAI_API_KEY="$OPENAI_API_KEY" OPENAI_MODEL=o4-mini \
    python3 /ABSOLUTE/PATH/TO/mcp_server.py
```

Expected output (one line):
```json
{"jsonrpc": "2.0", "id": 1, "result": {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}}, "serverInfo": {"name": "local-llm-mcp", "version": "1.0.0"}}}
```

### 7. Restart Claude Code and test

Open a new Claude Code session. Ask it:
```
Use the local_llm tool with backend="openai" and model="o4-mini" to summarize:
"Fedora is a Linux distribution sponsored by Red Hat."
```

Claude should call the tool and return o4-mini's summary.

## Using both backends simultaneously

You can register both backends as separate MCP servers so Claude can choose:

```json
{
  "mcpServers": {
    "local-llm-ollama": {
      "command": "python3",
      "args": ["/ABSOLUTE/PATH/TO/mcp_server.py"],
      "env": { "LOCAL_LLM_BACKEND": "ollama", "OLLAMA_MODEL": "qwen2.5-coder:32b" }
    },
    "local-llm-openai": {
      "command": "python3",
      "args": ["/ABSOLUTE/PATH/TO/mcp_server.py"],
      "env": { "LOCAL_LLM_BACKEND": "openai", "OPENAI_MODEL": "o4-mini", "OPENAI_API_KEY": "sk-..." }
    }
  }
}
```

Claude then has two `local_llm` tools available — one free/local, one paid/cloud.
A good delegation strategy:
- Offline or privacy-sensitive → Ollama
- Fast, high-volume API work → o4-mini
- Complex code tasks locally → qwen2.5-coder:32b
- Second opinion / diversity → either backend on the same prompt

## How Codex CLI acts as a peer agent

If you run Codex CLI in a separate terminal alongside Claude Code, you can:
1. Ask Claude to produce a plan or spec
2. Paste that spec into Codex CLI for implementation
3. Ask Claude to review Codex's output

This is a manual handoff today. A fully automated version requires an
orchestration script that calls both CLIs via subprocess — a future extension
not covered here.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `401 Unauthorized` | Check `OPENAI_API_KEY` is exported and valid |
| `model_not_found` | Verify your OpenAI account has access to `o4-mini` or `gpt-4o` |
| `ModuleNotFoundError: requests` | `pip3 install --user requests` |
| MCP server not found by Claude | Check absolute path in `mcp.json`, restart Claude |
| Codex CLI not found | `npm install -g @openai/codex` (requires Node 18+) |
| High latency | Switch model to `gpt-4o-mini` for lower latency at slight quality cost |

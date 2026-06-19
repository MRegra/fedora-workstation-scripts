#!/usr/bin/env python3
"""
Local LLM MCP server for Claude Code.

Exposes Ollama (local/free) and any OpenAI-compatible API (Codex, GPT-4o, etc.)
as tools that Claude can call during a session. Claude acts as orchestrator and
delegates cheaper/simpler tasks to whichever backend you configure.

Setup:
  pip install requests

  Add to ~/.claude/mcp.json:
  {
    "mcpServers": {
      "local-llm": {
        "command": "python3",
        "args": ["/absolute/path/to/mcp_server.py"],
        "env": {
          "LOCAL_LLM_BACKEND": "ollama",
          "OLLAMA_MODEL": "qwen2.5-coder:32b"
        }
      }
    }
  }

  For Codex CLI (~/.codex/config.yaml):
    mcpServers:
      local-llm:
        command: python3
        args: ["/absolute/path/to/mcp_server.py"]
        env:
          LOCAL_LLM_BACKEND: openai
          OPENAI_API_KEY: "sk-..."
          OPENAI_MODEL: "o4-mini"

Config env vars:
  LOCAL_LLM_BACKEND   ollama | openai      (default: ollama)
  OLLAMA_URL          default: http://localhost:11434
  OLLAMA_MODEL        default: llama3.3:70b
  OPENAI_URL          default: https://api.openai.com/v1
  OPENAI_API_KEY      required for openai backend
  OPENAI_MODEL        default: gpt-4o
"""

import json
import os
import sys
from typing import Optional

import requests

BACKEND = os.environ.get("LOCAL_LLM_BACKEND", "ollama")
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434")
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "llama3.3:70b")
OPENAI_URL = os.environ.get("OPENAI_URL", "https://api.openai.com/v1")
OPENAI_API_KEY = os.environ.get("OPENAI_API_KEY", "")
OPENAI_MODEL = os.environ.get("OPENAI_MODEL", "gpt-4o")


def call_ollama(prompt: str, system: Optional[str], model: Optional[str]) -> str:
    payload = {
        "model": model or OLLAMA_MODEL,
        "prompt": prompt,
        "stream": False,
    }
    if system:
        payload["system"] = system
    resp = requests.post(f"{OLLAMA_URL}/api/generate", json=payload, timeout=180)
    resp.raise_for_status()
    return resp.json()["response"]


def call_openai(prompt: str, system: Optional[str], model: Optional[str]) -> str:
    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})
    headers = {
        "Authorization": f"Bearer {OPENAI_API_KEY}",
        "Content-Type": "application/json",
    }
    payload = {"model": model or OPENAI_MODEL, "messages": messages}
    resp = requests.post(
        f"{OPENAI_URL}/chat/completions",
        json=payload,
        headers=headers,
        timeout=120,
    )
    resp.raise_for_status()
    return resp.json()["choices"][0]["message"]["content"]


TOOLS = [
    {
        "name": "local_llm",
        "description": (
            "Run a prompt through a secondary LLM (local Ollama model or OpenAI-compatible API). "
            "Use for tasks where speed/cost matter more than peak quality: "
            "summarizing long text before processing it yourself, "
            "simple code generation or refactoring, "
            "classification, entity extraction, translation, "
            "generating multiple drafts for review, "
            "or any repetitive/batch text work. "
            "Do NOT use for complex reasoning, security-sensitive output, or final user-facing answers."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "prompt": {
                    "type": "string",
                    "description": "The prompt to send to the local model.",
                },
                "system": {
                    "type": "string",
                    "description": "Optional system prompt to constrain the model's role or output format.",
                },
                "backend": {
                    "type": "string",
                    "enum": ["ollama", "openai"],
                    "description": (
                        "Which backend to use. "
                        "ollama = local free model (Llama, Qwen, Mistral, etc.). "
                        "openai = OpenAI-compatible API (GPT-4o, o4-mini, Codex). "
                        "Defaults to LOCAL_LLM_BACKEND env var."
                    ),
                },
                "model": {
                    "type": "string",
                    "description": (
                        "Optional model override. "
                        "Ollama examples: 'qwen2.5-coder:32b', 'llama3.3:70b', 'mistral-nemo'. "
                        "OpenAI examples: 'o4-mini', 'gpt-4o', 'gpt-4o-mini'."
                    ),
                },
            },
            "required": ["prompt"],
        },
    }
]


def handle(req: dict) -> Optional[dict]:
    method = req.get("method", "")
    id_ = req.get("id")

    if method == "initialize":
        return {
            "jsonrpc": "2.0",
            "id": id_,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "local-llm-mcp", "version": "1.0.0"},
            },
        }

    if method in ("notifications/initialized", "notifications/cancelled"):
        return None  # fire-and-forget

    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": id_, "result": {"tools": TOOLS}}

    if method == "tools/call":
        params = req.get("params", {})
        name = params.get("name", "")
        args = params.get("arguments", {})

        if name == "local_llm":
            prompt = args.get("prompt", "")
            system = args.get("system")
            backend = args.get("backend", BACKEND)
            model = args.get("model")

            try:
                if backend == "ollama":
                    text = call_ollama(prompt, system, model)
                else:
                    text = call_openai(prompt, system, model)
                return {
                    "jsonrpc": "2.0",
                    "id": id_,
                    "result": {"content": [{"type": "text", "text": text}]},
                }
            except Exception as exc:
                return {
                    "jsonrpc": "2.0",
                    "id": id_,
                    "result": {
                        "content": [{"type": "text", "text": f"local_llm error: {exc}"}],
                        "isError": True,
                    },
                }

    return {
        "jsonrpc": "2.0",
        "id": id_,
        "error": {"code": -32601, "message": f"method not found: {method}"},
    }


def main() -> None:
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            req = json.loads(raw)
        except json.JSONDecodeError:
            continue
        resp = handle(req)
        if resp is not None:
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()

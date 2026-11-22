#!/usr/bin/env python3
"""PreToolUse hook: the never list, enforced (lesson 11; sweep 2b amend c, 2026-11-22).

Refuses a Bash command or a web fetch that would reach something of T's:
  - T's Ollama (port 11434, or the `ollama` CLI not aimed at CC's own server on 11500),
  - T's Host (port 8787, its Tailscale tunnel, quitting / killing / launching AirPad Host.app or its bundled ollama),
  - T's PC and LM Studio (port 1234 anywhere, the `lms` CLI, any private-LAN / .local / Tailscale address),
  - scripts/gauntlet/run.sh (quits T's Host and serves 11434; amend b item 1).
Allowed (lesson 11's exception): CC's own server on 127.0.0.1:11500 and its scratch Host on 127.0.0.1:8799.

Text-level guard on what the tool call itself says; it can't see inside a script a command runs (those scripts refuse
the unsafe ports themselves). Exit 2 + stderr = refuse (Claude Code shows the reason to the model).
Dry check: `python3 never_list.py --selftest`.
"""
import json
import re
import sys

LOCAL = r"(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]|::1)"
RULES = [
    ("T's Ollama (port 11434)", re.compile(LOCAL + r":11434\b|OLLAMA_HOST=\S*11434|--ollama\s+\S*11434")),
    ("T's Host (port 8787)", re.compile(r"(?:" + LOCAL + r"|https?://[^\s/]+):8787\b")),
    ("T's Host app (quit / kill / launch / its bundled ollama)",
     re.compile(r"(?:quit\s+app|pkill|killall|kill\b[^;&|]*|open\s+(?:-a\s+)?)[^;&|]*AirPad Host"
                r"|AirPad Host\.app/Contents/(?:MacOS|Resources/ollama)", re.I)),
    ("LM Studio (port 1234 / lms CLI)", re.compile(r"[\w\].-]:1234\b|(?:^|[\s;&|(])lms\s+\w")),
    ("a machine on T's network (private LAN / .local / Tailscale)",
     re.compile(r"\b(?:192\.168|10)\.\d{1,3}\.\d{1,3}\.\d{1,3}\b|\b172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}\b"
                r"|\b100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}\b|[\w-]+\.local\b(?!host)|\.ts\.net\b", re.I)),
    ("scripts/gauntlet/run.sh (quits T's Host, serves 11434)",
     re.compile(r"\b(?:ba|z)?sh\s+(?!-n\b)[^;&|]*scripts/gauntlet/run\.sh\b|(?:^|[;&|(]\s*)(?:\S*/)?scripts/gauntlet/run\.sh\b")),
]
OLLAMA_CLI = re.compile(r"(?:^|[\s;&|(/])ollama\s+(?:run|pull|push|rm|cp|create|stop|ps|list|ls|show|serve|launch)\b")
OWN_SERVER = re.compile(r"OLLAMA_HOST=\S*(?:127\.0\.0\.1|localhost):11500\b")


def verdict(text: str):
    """Return the reason a call is refused, or None."""
    for reason, rx in RULES:
        if rx.search(text):
            return reason
    for segment in re.split(r"&&|\|\||;|\n", text):
        if OLLAMA_CLI.search(segment) and not OWN_SERVER.search(segment) and not OWN_SERVER.search(text):
            return "the ollama CLI not aimed at CC's own server (OLLAMA_HOST=127.0.0.1:11500)"
    return None


def call_text(event: dict) -> str:
    tool, inp = event.get("tool_name", ""), event.get("tool_input") or {}
    if tool == "Bash":
        return inp.get("command", "")
    if tool in ("WebFetch", "WebSearch"):
        return " ".join(str(inp.get(k, "")) for k in ("url", "query"))
    return ""


SAMPLES = [  # (command, refused?)
    ("curl -s http://127.0.0.1:11434/api/tags", True),
    ("curl -s localhost:11434/api/ps", True),
    ("OLLAMA_HOST=127.0.0.1:11434 ollama ps", True),
    ("ollama ps", True),
    ("ollama run qwen3.5:4b hi", True),
    ("osascript -e 'quit app \"AirPad Host\"'", True),
    ("pkill -9 -f \"AirPad Host.app/Contents\"", True),
    ("\"/Applications/AirPad Host.app/Contents/Resources/ollama\" serve", True),
    ("curl http://127.0.0.1:8787/health", True),
    ("curl http://192.168.1.20:1234/v1/models", True),
    ("curl http://tpc.local:1234/v1/models", True),
    ("lms ls", True),
    ("curl https://angelfish-tritone.ts.net/health", True),
    ("curl http://100.101.2.3:8080/", True),
    ("zsh scripts/gauntlet/run.sh all", True),
    ("OLLAMA_HOST=127.0.0.1:11500 build/scratch-ollama/ollama ps", False),
    ("curl -s http://127.0.0.1:11500/api/tags", False),
    ("curl -s http://127.0.0.1:8799/health -H 'Authorization: Bearer x'", False),
    ("GAUNTLET_OLLAMA=http://127.0.0.1:11500 zsh scripts/server/gauntlet_routes.sh host qwen3.5:4b UDID app out", False),
    ("grep -n \"11434\" scripts/server/gauntlet_routes.sh", False),
    ("xcodebuild -project AirPad.xcodeproj -scheme AirPad build", False),
    ("curl -s https://huggingface.co/api/models/mlx-community/Qwen3.5-4B-MLX-4bit", False),
    ("zsh -n scripts/gauntlet/run.sh", False),
    ("sed -n 60,80p scripts/gauntlet/run.sh", False),
    ("nohup zsh scripts/gauntlet/run.sh > x.log &", True),
    ("cd ws && ./scripts/gauntlet/run.sh", True),
]


def selftest() -> int:
    bad = 0
    for cmd, refuse in SAMPLES:
        got = verdict(cmd)
        ok = (got is not None) == refuse
        bad += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {'refused' if got else 'allowed'}: {cmd}" + (f"  ({got})" if got else ""))
    print(f"{len(SAMPLES) - bad}/{len(SAMPLES)} as expected")
    return 1 if bad else 0


def main() -> int:
    if "--selftest" in sys.argv:
        return selftest()
    try:
        event = json.load(sys.stdin)
    except Exception:
        return 0
    reason = verdict(call_text(event))
    if reason:
        print(f"Refused by the never list (lesson 11): this call would reach {reason}. CC uses its own server on "
              f"127.0.0.1:11500 and a scratch Host on 127.0.0.1:8799 only. Hook: .claude/hooks/never_list.py",
              file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())

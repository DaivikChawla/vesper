#!/usr/bin/python3
"""
A stand-in for `claude -p --chrome`, used by scripts/test-browser-task.sh
to exercise VesperBrowserTask.swift without subscription usage or Chrome.

It prints one-shot stream-json like the real CLI (shapes from a real
--chrome run on CLI 2.1.287): a system init line with the claude-in-chrome
MCP server, assistant lines holding tool_use blocks (ToolSearch first, then
browser tools), user lines with tool results, and a final result line.

A keyword in the task (the value after -p) picks the behavior:
  PLAY      tabs, navigate to youtube, find, click, then a two-line summary
  JS        tries javascript_tool, then hangs (must be killed at once)
  BASH      tries Bash, then hangs (must be killed at once)
  MAIL      navigates to mail.google.com, then hangs (must be killed)
  MANY      41 browser tool calls, then hangs (must be killed)
  STUBBORN  like BASH, ignoring SIGTERM (needs SIGKILL)
  HANG      says nothing and hangs (time limit)
  CRASH     exits 1 with an error on stderr, no result
  ERROR     an is_error result

Each launch appends a JSON line (argv, environment, cwd, pid) to a log
file whose path sits next to this script.
"""

import json
import os
import signal
import sys
import time

SCRIPT_DIRECTORY = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(SCRIPT_DIRECTORY, "fake-claude-cli.logpath")) as log_path_file:
    LOG_PATH = log_path_file.read().strip()

arguments = sys.argv[1:]
task = arguments[arguments.index("-p") + 1] if "-p" in arguments else ""
PREFIX = "mcp__claude-in-chrome__"

with open(LOG_PATH, "a") as log_file:
    log_file.write(json.dumps({"argv": arguments, "env": dict(os.environ),
                               "cwd": os.getcwd(), "pid": os.getpid(),
                               "stdin_is_tty": sys.stdin.isatty()}) + "\n")


def emit(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def emit_tool_use(tool_name, tool_input):
    emit({"type": "assistant", "message": {"content": [
        {"type": "tool_use", "id": "toolu_fake", "name": tool_name, "input": tool_input}]}})
    emit({"type": "user", "message": {"content": [
        {"type": "tool_result", "tool_use_id": "toolu_fake", "content": "ok"}]}})


def hang_forever():
    while True:
        time.sleep(1)


emit({"type": "system", "subtype": "init", "tools": ["ToolSearch"],
      "mcp_servers": [{"name": "claude-in-chrome", "status": "connected"}], "model": "claude-sonnet-5"})
emit_tool_use("ToolSearch", {"query": "select:" + PREFIX + "tabs_context_mcp"})

if "STUBBORN" in task:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    emit_tool_use("Bash", {"command": "ls"})
    hang_forever()
elif "BASH" in task:
    emit_tool_use("Bash", {"command": "ls"})
    hang_forever()
elif "JS" in task:
    emit_tool_use(PREFIX + "javascript_tool", {"text": "document.cookie"})
    hang_forever()
elif "MAIL" in task:
    emit_tool_use(PREFIX + "navigate", {"url": "https://mail.google.com/mail/u/0/", "tabId": 1})
    hang_forever()
elif "MANY" in task:
    for call_number in range(41):
        emit_tool_use(PREFIX + "computer", {"action": "scroll", "tabId": 1})
    hang_forever()
elif "HANG" in task:
    hang_forever()
elif "CRASH" in task:
    sys.stderr.write("Error: something broke\n")
    sys.exit(1)
elif "ERROR" in task:
    emit({"type": "result", "subtype": "error_during_execution", "is_error": True,
          "result": "Browser extension is not connected"})
else:  # PLAY
    emit_tool_use(PREFIX + "tabs_context_mcp", {"createIfEmpty": True})
    emit_tool_use(PREFIX + "navigate", {"url": "https://www.youtube.com/results?search_query=lofi", "tabId": 1})
    emit_tool_use(PREFIX + "find", {"query": "first video", "tabId": 1})
    emit_tool_use(PREFIX + "computer", {"action": "left_click", "ref": "ref_12", "tabId": 1})
    emit({"type": "assistant", "message": {"content": [{"type": "text", "text": "done"}]}})
    emit({"type": "result", "subtype": "success", "is_error": False,
          "result": "**Playing** lofi hip hop radio.\n\nIt's in the [Vesper] tab group."})

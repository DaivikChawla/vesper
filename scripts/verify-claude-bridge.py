#!/usr/bin/env python3
"""
Verifies that the local `claude` CLI still behaves the way Vesper's
ClaudeCodeCLIBridge.swift depends on — without building the app.

Run it after updating Claude Code, or whenever Vesper stops answering:

    python3 scripts/verify-claude-bridge.py

It uses the same flags and the same stripped-down environment the app uses
(a GUI app gets a minimal PATH, and the CLI needs USER/LOGNAME to find its
login in the keychain). If you change the flags in ClaudeCodeCLIBridge.swift,
change COMMAND_LINE_ARGUMENTS below to match.

Checks (about six short Claude requests on your subscription):
  1. logs in on the subscription (not an API key) in a GUI-like environment
  2. answers a question about an inline base64 image
  3. accepts a multi-megabyte screenshot payload without deadlocking
  4. puts a [POINT:x,y:label] tag first, within 10px of the real target
  5. interrupts a turn mid-reply, and the process keeps working afterwards
  6. writes nothing to ~/.claude/projects (--no-session-persistence)
  7. reports subscription usage via rate_limit_event
"""

import base64
import json
import math
import os
import random
import re
import struct
import subprocess
import sys
import tempfile
import threading
import time
import zlib
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
REFERENCE_SCREENSHOT = REPOSITORY_ROOT / "clicky-demo.gif"
# Where the Xcode "Run" button is in the reference frame, at 1280px wide.
REFERENCE_RUN_BUTTON_LOCATION = (254, 49)
MAXIMUM_POINTING_ERROR_PIXELS = 10

CANDIDATE_EXECUTABLE_PATHS = [
    Path.home() / ".local/bin/claude",
    Path("/opt/homebrew/bin/claude"),
    Path("/usr/local/bin/claude"),
    Path.home() / ".claude/local/claude",
]

TEST_SYSTEM_PROMPT = (
    "you are a terse test assistant. reply in at most eight lowercase words. "
    "when asked to point, START your reply with [POINT:x,y:label] using integer "
    "pixel coordinates in the screenshot (origin top-left)."
)

# Must match makeCommandLineArguments() in ClaudeCodeCLIBridge.swift.
COMMAND_LINE_ARGUMENTS = [
    "-p",
    "--input-format", "stream-json",
    "--output-format", "stream-json",
    "--verbose",
    "--include-partial-messages",
    "--tools", "",
    "--model", "sonnet",
    "--permission-prompts", "none",
    "--strict-mcp-config",
    "--setting-sources", "",
    "--disable-slash-commands",
    "--no-session-persistence",
    "--system-prompt", TEST_SYSTEM_PROMPT,
]


def locate_claude_executable():
    for candidate_path in CANDIDATE_EXECUTABLE_PATHS:
        if candidate_path.is_file() and os.access(candidate_path, os.X_OK):
            return str(candidate_path)
    sys.exit("❌ couldn't find the claude CLI in: " + ", ".join(map(str, CANDIDATE_EXECUTABLE_PATHS)))


def make_gui_like_environment(executable_path):
    """Mirrors makeProcessEnvironment() in ClaudeCodeCLIBridge.swift."""
    return {
        "PATH": ":".join([os.path.dirname(executable_path), "/usr/bin", "/bin", "/usr/sbin", "/sbin"]),
        "HOME": str(Path.home()),
        "USER": os.environ["USER"],
        "LOGNAME": os.environ.get("LOGNAME", os.environ["USER"]),
        "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
        "SHELL": os.environ.get("SHELL", "/bin/zsh"),
        "LANG": "en_US.UTF-8",
        # Thinking off by default; the app switches it on per turn.
        "MAX_THINKING_TOKENS": "0",
    }


def make_solid_color_png(width, height, rgb_color):
    raw_rows = b"".join(b"\x00" + bytes(rgb_color) * width for _ in range(height))

    def png_chunk(chunk_type, chunk_data):
        return (struct.pack(">I", len(chunk_data)) + chunk_type + chunk_data
                + struct.pack(">I", zlib.crc32(chunk_type + chunk_data) & 0xFFFFFFFF))

    return (b"\x89PNG\r\n\x1a\n"
            + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + png_chunk(b"IDAT", zlib.compress(raw_rows))
            + png_chunk(b"IEND", b""))


def make_noise_jpeg(temporary_directory, width=1512, height=982):
    """An incompressible screenshot-sized JPEG (~1MB) to stress the stdin pipe."""
    random_bytes = random.randbytes(width * height * 3)
    raw_rows = b"".join(b"\x00" + random_bytes[row * width * 3:(row + 1) * width * 3] for row in range(height))

    def png_chunk(chunk_type, chunk_data):
        return (struct.pack(">I", len(chunk_data)) + chunk_type + chunk_data
                + struct.pack(">I", zlib.crc32(chunk_type + chunk_data) & 0xFFFFFFFF))

    png_path = Path(temporary_directory) / "noise.png"
    jpeg_path = Path(temporary_directory) / "noise.jpg"
    png_path.write_bytes(b"\x89PNG\r\n\x1a\n"
                         + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                         + png_chunk(b"IDAT", zlib.compress(raw_rows, 1))
                         + png_chunk(b"IEND", b""))
    subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "60", str(png_path), "--out", str(jpeg_path)],
                   check=True, capture_output=True)
    return jpeg_path.read_bytes()


def make_reference_screenshot_jpeg(temporary_directory):
    jpeg_path = Path(temporary_directory) / "reference.jpg"
    subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "70", "-Z", "1280",
                    str(REFERENCE_SCREENSHOT), "--out", str(jpeg_path)], check=True, capture_output=True)
    return jpeg_path.read_bytes()


def image_block(image_bytes, media_type):
    return {"type": "image", "source": {"type": "base64", "media_type": media_type,
                                        "data": base64.b64encode(image_bytes).decode()}}


class ClaudeCLISession:
    """One long-lived CLI process, driven exactly the way the app drives it."""

    def __init__(self, executable_path, working_directory):
        self.process = subprocess.Popen(
            [executable_path] + COMMAND_LINE_ARGUMENTS,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1, cwd=working_directory,
            env=make_gui_like_environment(executable_path),
        )
        self.output_messages = []
        self.next_unread_index = 0
        self.standard_error_lines = []
        # Drain stdout and stderr continuously, like the app does. Leaving
        # either pipe unread lets it fill up and deadlocks the CLI.
        threading.Thread(target=self._drain_standard_output, daemon=True).start()
        threading.Thread(target=self._drain_standard_error, daemon=True).start()

    def _drain_standard_output(self):
        for output_line in self.process.stdout:
            try:
                self.output_messages.append(json.loads(output_line))
            except json.JSONDecodeError:
                pass

    def _drain_standard_error(self):
        for error_line in self.process.stderr:
            self.standard_error_lines.append(error_line)

    def send_json_line(self, message):
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def send_user_turn(self, content_blocks):
        self.send_json_line({"type": "user", "message": {"role": "user", "content": content_blocks}})

    def send_interrupt(self):
        self.send_json_line({"type": "control_request", "request_id": "verify-interrupt",
                             "request": {"subtype": "interrupt"}})

    def read_until_turn_finishes(self, timeout_seconds=120):
        """Returns (result message, streamed text, seconds to first text, all messages)."""
        started_at = time.time()
        streamed_text = ""
        first_text_seconds = None
        turn_messages = []
        while time.time() - started_at < timeout_seconds:
            while self.next_unread_index < len(self.output_messages):
                output_message = self.output_messages[self.next_unread_index]
                self.next_unread_index += 1
                turn_messages.append(output_message)
                if output_message.get("type") == "stream_event":
                    stream_event = output_message.get("event", {})
                    delta = stream_event.get("delta", {})
                    if stream_event.get("type") == "content_block_delta" and delta.get("type") == "text_delta":
                        if first_text_seconds is None:
                            first_text_seconds = time.time() - started_at
                        streamed_text += delta["text"]
                if output_message.get("type") == "result":
                    return output_message, streamed_text, first_text_seconds, turn_messages
            if self.process.poll() is not None and self.next_unread_index >= len(self.output_messages):
                return None, streamed_text, first_text_seconds, turn_messages
            time.sleep(0.01)
        return None, streamed_text, first_text_seconds, turn_messages

    def close(self):
        try:
            self.process.stdin.close()
        except OSError:
            pass
        self.process.terminate()


def main():
    executable_path = locate_claude_executable()
    print(f"claude CLI: {executable_path}")
    failures = []

    def report(check_passed, description, detail=""):
        print(f"{'✅' if check_passed else '❌'} {description}" + (f" — {detail}" if detail else ""))
        if not check_passed:
            failures.append(description)

    with tempfile.TemporaryDirectory() as working_directory:
        # The CLI names its per-project folder after the working directory.
        projects_folder = Path.home() / ".claude/projects" / re.sub(r"[^A-Za-z0-9]", "-", os.path.realpath(working_directory))

        session = ClaudeCLISession(executable_path, working_directory)
        try:
            # 1 + 2: login and an inline image
            session.send_user_turn([image_block(make_solid_color_png(64, 64, (220, 30, 30)), "image/png"),
                                    {"type": "text", "text": "what single color fills this image?"}])
            result, streamed_text, _, turn_messages = session.read_until_turn_finishes()
            init_message = next((m for m in turn_messages if m.get("type") == "system" and m.get("subtype") == "init"), {})
            if result is None:
                report(False, "login in a GUI-like environment", "".join(session.standard_error_lines)[-300:])
                sys.exit(1)
            report(init_message.get("apiKeySource") == "none" and not result.get("is_error"),
                   "logs in on the subscription (no API key) in a GUI-like environment",
                   f"apiKeySource={init_message.get('apiKeySource')!r}, reply={result.get('result')!r}")
            report("red" in streamed_text.lower(), "answers about an inline base64 image", repr(streamed_text))

            # 7: subscription usage
            usage_events = [m for m in turn_messages if m.get("type") == "rate_limit_event"]
            usage_windows = usage_events[-1].get("rate_limit_info", {}).get("unifiedWindows", {}) if usage_events else {}
            report("five_hour" in usage_windows, "reports subscription usage (rate_limit_event)",
                   ", ".join(f"{name} {window.get('utilization', 0):.0%}" for name, window in usage_windows.items()))

            # 3: multi-megabyte payload
            noise_jpeg = make_noise_jpeg(working_directory)
            write_started_at = time.time()
            session.send_user_turn([image_block(noise_jpeg, "image/jpeg"), image_block(noise_jpeg, "image/jpeg"),
                                    {"type": "text", "text": "these are noise. reply with exactly: got both"}])
            write_seconds = time.time() - write_started_at
            result, streamed_text, _, _ = session.read_until_turn_finishes()
            payload_megabytes = 2 * len(base64.b64encode(noise_jpeg)) / 1_048_576
            report(result is not None and not result.get("is_error"),
                   "accepts a multi-megabyte screenshot payload without deadlocking",
                   f"{payload_megabytes:.1f}MB written in {write_seconds:.1f}s")

            # 4: point tag first, and accurate
            session.send_user_turn([image_block(make_reference_screenshot_jpeg(working_directory), "image/jpeg"),
                                    {"type": "text", "text": "(image dimensions: 1280x832 pixels) point at the button that runs the app."}])
            result, streamed_text, first_text_seconds, _ = session.read_until_turn_finishes()
            point_match = re.match(r"\s*\[POINT:(\d+)\s*,\s*(\d+)", streamed_text)
            if point_match:
                pointing_error = math.hypot(int(point_match[1]) - REFERENCE_RUN_BUTTON_LOCATION[0],
                                            int(point_match[2]) - REFERENCE_RUN_BUTTON_LOCATION[1])
                report(pointing_error <= MAXIMUM_POINTING_ERROR_PIXELS,
                       "puts a [POINT] tag first, on target",
                       f"{pointing_error:.0f}px off, first text after {first_text_seconds:.2f}s")
            else:
                report(False, "puts a [POINT] tag first, on target", repr(streamed_text[:80]))

            # 5: interrupt, then keep working
            session.send_user_turn([{"type": "text", "text": "count from 1 to 300, one number per line, nothing else."}])
            time.sleep(3)
            session.send_interrupt()
            interrupted_result, _, _, _ = session.read_until_turn_finishes(timeout_seconds=30)
            session.send_user_turn([{"type": "text", "text": "reply with exactly: still alive"}])
            result, streamed_text, _, _ = session.read_until_turn_finishes()
            report(interrupted_result is not None and "still alive" in streamed_text.lower(),
                   "interrupts a turn, and the process keeps working", repr(streamed_text))

            # 8: thinking is off by default (MAX_THINKING_TOKENS=0), and the
            # per-turn switch Vesper sends is acknowledged.
            hard_question = ("think it through: a bat and a ball cost 1.10 together and the bat costs 1.00 more "
                             "than the ball. what does the ball cost? one short sentence.")
            session.send_user_turn([{"type": "text", "text": hard_question}])
            _, _, _, turn_messages = session.read_until_turn_finishes()
            thinking_blocks = [m for m in turn_messages if m.get("type") == "stream_event"
                               and m.get("event", {}).get("type") == "content_block_start"
                               and m.get("event", {}).get("content_block", {}).get("type") in ("thinking", "redacted_thinking")]
            report(not thinking_blocks, "no thinking with MAX_THINKING_TOKENS=0 (fast answers)",
                   f"{len(thinking_blocks)} thinking block(s)")
            session.send_json_line({"type": "control_request", "request_id": "verify-thinking-on",
                                    "request": {"subtype": "set_max_thinking_tokens", "max_thinking_tokens": 16000}})
            session.send_user_turn([{"type": "text", "text": "reply with exactly: thinking allowed"}])
            result, streamed_text, _, turn_messages = session.read_until_turn_finishes()
            acknowledged = any(m.get("type") == "control_response"
                               and m.get("response", {}).get("request_id") == "verify-thinking-on"
                               and m.get("response", {}).get("subtype") == "success" for m in turn_messages)
            report(acknowledged and result is not None and not result.get("is_error"),
                   "accepts the per-turn thinking switch (set_max_thinking_tokens) and keeps answering",
                   repr(streamed_text[:60]))
        finally:
            session.close()

        # 6: nothing persisted
        time.sleep(0.5)
        persisted_session_files = list(projects_folder.glob("*.jsonl")) if projects_folder.exists() else []
        report(not persisted_session_files, "writes nothing to ~/.claude/projects",
               f"{len(persisted_session_files)} session file(s) found")

    print()
    if failures:
        print(f"❌ {len(failures)} check(s) failed. Vesper's bridge may need updating for this CLI version.")
        sys.exit(1)
    print("✅ all checks passed — the claude CLI behaves the way Vesper expects.")


if __name__ == "__main__":
    main()

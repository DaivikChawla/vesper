#!/usr/bin/env python3
"""
Compares Claude models for Vesper: speed to first word, and how accurately
each one points at UI elements in a real screenshot.

This is how Sonnet was chosen as the default (measured 2026-09-22 on an M2):
    sonnet   first text ~1.3-1.4s, pointing error 1-2px
    opus     first text ~3.0-7.8s, pointing error 0-1px
    haiku    first text ~6-12s in that run (not pursued)
    sonnet --effort low: no faster
Measured again 2026-09-24 with Vesper's real prompt (CLI 2.1.281, claude-sonnet-5):
    "where is X" questions: no thinking, first text 0.9-1.5s, same with --effort low
    action / explain questions: Sonnet 5 thinks adaptively. "is there a bug?"
    thought ~3s before its first word (4.2s; 3.6s at --effort low) — the source
    of the ~5s fresh-question delay in Vesper.log. --effort low skipped
    thinking on one of three.
Re-run it when new models come out.

⚠️ Uses about 9 requests (3 per model) on your Claude subscription.

Usage: python3 scripts/compare-claude-models.py [model[:effort] ...] [--vesper-prompt]
       python3 scripts/compare-claude-models.py sonnet opus
       python3 scripts/compare-claude-models.py sonnet sonnet:low --vesper-prompt

--action-questions asks action and explanation requests like the slow ones in
Vesper.log instead of "where is X" (no pointing score).
--vesper-prompt uses Vesper's real system prompt (read from CompanionManager.swift)
instead of the short stand-in, so thinking behaviour matches the app. Each turn
also reports whether Claude spent time in a hidden thinking block before the
first word, and how many output tokens it used.
"""

import base64
import json
import math
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
REFERENCE_SCREENSHOT = REPOSITORY_ROOT / "clicky-demo.gif"
CLAUDE_EXECUTABLE = Path.home() / ".local/bin/claude"

SYSTEM_PROMPT = (
    "you are vesper, a voice companion that can see the user's screen. reply in one short spoken "
    "sentence, lowercase. when pointing helps, START your reply with a tag [POINT:x,y:label] using "
    "integer pixel coords in the screenshot (origin top-left; the image is 1280x832). "
    "if not, start with [POINT:none]."
)

# Questions about the reference frame, with where the answer really is
# (measured by eye on the 1280px-wide frame).
QUESTIONS_WITH_TRUE_LOCATIONS = [
    ("where's the button to run my app?", (254, 49)),
    ("which dock icon is spotify?", (379, 803)),
    ("where's the wifi icon?", (1044, 12)),
]


# Requests shaped like the slow real-life turns in Vesper.log (actions and
# explanations rather than "where is X"), with the control line the app adds.
# They have no true location, so pointing isn't scored.
ACTION_QUESTIONS = [
    ("(control: quick actions. OPEN, MUSIC and VOLUME work. clicking, typing and keys are off.)\n"
     "open youtube and play some lofi radio", None),
    ("(control: quick actions. OPEN, MUSIC and VOLUME work. clicking, typing and keys are off.)\n"
     "what's going on in this code, is there a bug?", None),
    ("(control: hands-on. every tag works. at most 30 steps per task.)\n"
     "open fiverr and draft a reply to the latest conversation, then ask me before sending", None),
]


def make_reference_screenshot_base64(temporary_directory):
    jpeg_path = Path(temporary_directory) / "reference.jpg"
    subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "70", "-Z", "1280",
                    str(REFERENCE_SCREENSHOT), "--out", str(jpeg_path)], check=True, capture_output=True)
    return base64.b64encode(jpeg_path.read_bytes()).decode()


def read_vesper_system_prompt():
    """The real prompt, from the Swift source, so the probe matches the app."""
    swift_source = (REPOSITORY_ROOT / "leanring-buddy" / "CompanionManager.swift").read_text()
    prompt_match = re.search(r'vesperVoiceResponseSystemPrompt = """\n(.*?)\n    """', swift_source, re.S)
    if not prompt_match:
        sys.exit("couldn't find vesperVoiceResponseSystemPrompt in CompanionManager.swift")
    return "\n".join(line[4:] if line.startswith("    ") else line for line in prompt_match.group(1).split("\n"))


def measure_model(model_variant, screenshot_base64, system_prompt, questions_with_true_locations):
    model_name, _, effort_level = model_variant.partition(":")
    environment = {
        "PATH": "/usr/bin:/bin",
        "HOME": str(Path.home()),
        "USER": os.environ["USER"],
        "LOGNAME": os.environ.get("LOGNAME", os.environ["USER"]),
    }
    process = subprocess.Popen(
        [str(CLAUDE_EXECUTABLE), "-p", "--input-format", "stream-json", "--output-format", "stream-json",
         "--verbose", "--include-partial-messages", "--tools", "", "--model", model_name,
         "--permission-prompts", "none", "--strict-mcp-config", "--setting-sources", "",
         "--disable-slash-commands", "--no-session-persistence", "--system-prompt", system_prompt]
        + (["--effort", effort_level] if effort_level else []),
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, bufsize=1, env=environment,
    )
    output_lines = []
    threading.Thread(target=lambda: [output_lines.append(line) for line in process.stdout], daemon=True).start()
    next_unread_index = 0
    time.sleep(2.5)  # let it boot, so we measure warm turns like the app does

    for question_number, (question, true_location) in enumerate(questions_with_true_locations, start=1):
        sent_at = time.time()
        first_text_seconds = None
        thinking_started_seconds = None
        reply_text = ""
        finished = None
        resolved_model = None
        process.stdin.write(json.dumps({"type": "user", "message": {"role": "user", "content": [
            {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": screenshot_base64}},
            # Labelled like the app labels its screenshots.
            {"type": "text", "text": "screen 1 of 1 (primary focus) (image dimensions: 1280x832 pixels)"},
            {"type": "text", "text": question}]}}) + "\n")
        process.stdin.flush()

        while finished is None and time.time() - sent_at < 120:
            while next_unread_index < len(output_lines):
                output_message = json.loads(output_lines[next_unread_index])
                next_unread_index += 1
                if output_message.get("type") == "system" and output_message.get("subtype") == "init":
                    resolved_model = output_message.get("model")
                if output_message.get("type") == "stream_event":
                    stream_event = output_message["event"]
                    if (stream_event.get("type") == "content_block_start"
                            and stream_event.get("content_block", {}).get("type") in ("thinking", "redacted_thinking")
                            and thinking_started_seconds is None):
                        thinking_started_seconds = time.time() - sent_at
                    delta = stream_event.get("delta", {})
                    if stream_event.get("type") == "content_block_delta" and delta.get("type") == "text_delta":
                        if first_text_seconds is None:
                            first_text_seconds = time.time() - sent_at
                        reply_text += delta["text"]
                if output_message.get("type") == "result":
                    finished = output_message
            time.sleep(0.01)

        point_match = re.search(r"\[POINT:(\d+)\s*,\s*(\d+)", reply_text)
        if true_location is None:
            pointing_error = "n/a"
        elif point_match:
            pointing_error = f"{math.hypot(int(point_match[1]) - true_location[0], int(point_match[2]) - true_location[1]):.0f}px"
        else:
            pointing_error = "no tag"
        first_text_display = f"{first_text_seconds:.2f}s" if first_text_seconds else "n/a"
        thinking_display = f"thinking from {thinking_started_seconds:.2f}s" if thinking_started_seconds else "no thinking"
        output_tokens = (finished or {}).get("usage", {}).get("output_tokens", "?")
        print(f"{model_variant:12} q{question_number}  first text {first_text_display:>6}  "
              f"total {time.time() - sent_at:5.2f}s  pointing error {pointing_error:>7}  "
              f"{thinking_display}, {output_tokens} output tokens  ({resolved_model})")

    process.stdin.close()
    process.terminate()


def main():
    arguments = sys.argv[1:]
    use_vesper_prompt = "--vesper-prompt" in arguments
    questions_with_true_locations = ACTION_QUESTIONS if "--action-questions" in arguments else QUESTIONS_WITH_TRUE_LOCATIONS
    model_variants = [argument for argument in arguments if not argument.startswith("--")] or ["sonnet", "opus"]
    system_prompt = read_vesper_system_prompt() if use_vesper_prompt else SYSTEM_PROMPT
    print(f"⚠️  about {3 * len(model_variants)} requests on your Claude subscription"
          f"{' (with Vesper’s real system prompt)' if use_vesper_prompt else ''}\n")
    with tempfile.TemporaryDirectory() as temporary_directory:
        screenshot_base64 = make_reference_screenshot_base64(temporary_directory)
        for model_variant in model_variants:
            measure_model(model_variant, screenshot_base64, system_prompt, questions_with_true_locations)


if __name__ == "__main__":
    main()

#!/usr/bin/python3
"""
A stand-in for the `claude` CLI, used by scripts/test-claude-bridge.sh to
exercise ClaudeCodeCLIBridge.swift without spending subscription usage.

It speaks the same stream-json protocol the real CLI does (as verified by
scripts/verify-claude-bridge.py): one JSON user message per stdin line in,
`system`/`stream_event`/`rate_limit_event`/`result` lines out, and
`control_request` interrupts.

A keyword in the user's text picks the behavior:
  SLOW      streams a long reply slowly (for interrupting mid-answer)
  CRASH     starts replying, then the process dies
  STALL     never replies until interrupted
  WEDGED    never replies, ignores interrupts and SIGTERM (never sends a result)
  LIMITED   usage limit reached: rejected status + error result
  LOGGEDOUT the "Not logged in" error result
  BIG       reports a huge context (triggers rollover)
  otherwise a short normal reply that echoes the question

Every launch and every received message is appended as a JSON line to a
log file, so the test can check what the app sent. The bridge builds the
CLI's environment from scratch (no custom variables get through), so the log
file's path is read from fake-claude-cli.logpath, sitting next to this script.
"""

import json
import os
import signal
import sys
import threading
import time

SCRIPT_DIRECTORY = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(SCRIPT_DIRECTORY, "fake-claude-cli.logpath")) as log_path_file:
    LOG_PATH = log_path_file.read().strip()

output_lock = threading.Lock()
interrupt_requested = threading.Event()


def log_event(event_details):
    event_details["pid"] = os.getpid()
    with open(LOG_PATH, "a") as log_file:
        log_file.write(json.dumps(event_details) + "\n")


def emit(message):
    with output_lock:
        sys.stdout.write(json.dumps(message) + "\n")
        sys.stdout.flush()


def emit_text_delta(text):
    emit({"type": "stream_event", "event": {"type": "content_block_delta",
                                           "delta": {"type": "text_delta", "text": text}}})


def emit_rate_limit(status="allowed", five_hour=0.42, seven_day=0.21):
    reset_epoch = int(time.time()) + 3600
    emit({"type": "rate_limit_event", "rate_limit_info": {
        "status": status, "resetsAt": reset_epoch, "rateLimitType": "five_hour",
        "unifiedWindows": {"five_hour": {"utilization": five_hour, "resetsAt": reset_epoch},
                           "seven_day": {"utilization": seven_day, "resetsAt": reset_epoch + 86400}}}})


def emit_result(result_text, is_error=False, context_tokens=1500, api_error_status=None):
    emit({"type": "result", "subtype": "error" if is_error else "success", "is_error": is_error,
          "result": result_text, "api_error_status": api_error_status,
          "stop_reason": None if interrupt_requested.is_set() else "end_turn",
          "usage": {"input_tokens": 10, "cache_read_input_tokens": context_tokens - 10,
                    "cache_creation_input_tokens": 0}})


def stream_words(words, seconds_between_words):
    """Streams words; stops early (returns False) if interrupted."""
    for word in words:
        if interrupt_requested.is_set():
            return False
        emit_text_delta(word + " ")
        time.sleep(seconds_between_words)
    return True


def handle_user_turn(user_text):
    interrupt_requested.clear()
    emit({"type": "system", "subtype": "init", "apiKeySource": "none", "model": "fake-model"})

    if "LOGGEDOUT" in user_text:
        emit_result("Not logged in · Please run /login", is_error=True)
        return
    if "LIMITED" in user_text:
        emit_rate_limit(status="rejected", five_hour=1.0)
        emit_result("You've hit your limit", is_error=True, api_error_status=429)
        return
    if "WEDGED" in user_text:
        # (SIGTERM is ignored from the main thread, when the turn arrives.)
        while True:
            time.sleep(0.05)
    if "STALL" in user_text:
        while not interrupt_requested.is_set():
            time.sleep(0.05)
        emit_result("")
        return
    if "CRASH" in user_text:
        emit_text_delta("starting to answer ")
        time.sleep(0.2)
        sys.stderr.write("fake crash for testing\n")
        sys.stderr.flush()
        os._exit(3)
    if "SLOW" in user_text:
        completed = stream_words(["stale"] * 60, 0.05)
        emit_rate_limit()
        emit_result("" if not completed else "stale " * 60)
        return

    reply_text = f"[POINT:10,20:thing] you asked: {user_text.strip()[-40:]}. done."
    stream_words(reply_text.split(" "), 0.01)
    emit_rate_limit()
    emit_result(reply_text, context_tokens=60_000 if "BIG" in user_text else 1500)


def main():
    log_event({"event": "start", "pid": os.getpid(), "args": sys.argv[1:], "environment_keys": sorted(os.environ.keys()),
               "user": os.environ.get("USER"), "logname": os.environ.get("LOGNAME"),
               "cwd": os.getcwd()})

    turn_threads = []
    for input_line in sys.stdin:
        input_message = json.loads(input_line)
        if input_message.get("type") == "control_request":
            request_subtype = input_message.get("request", {}).get("subtype")
            if request_subtype == "set_max_thinking_tokens":
                # Like the real CLI: acknowledged, and it affects later turns only.
                log_event({"event": "thinking", "max_thinking_tokens": input_message["request"].get("max_thinking_tokens")})
                emit({"type": "control_response", "response": {
                    "subtype": "success", "request_id": input_message.get("request_id")}})
                continue
            interrupt_requested.set()
            log_event({"event": "interrupt"})
            emit({"type": "control_response", "response": {
                "subtype": "success", "request_id": input_message.get("request_id")}})
            continue
        if input_message.get("type") == "user":
            content_blocks = input_message["message"]["content"]
            text_blocks = [block.get("text", "") for block in content_blocks if block.get("type") == "text"]
            user_text = " ".join(text_blocks)
            image_count = sum(1 for block in content_blocks if block.get("type") == "image")
            log_event({"event": "user", "text": user_text, "image_count": image_count})
            # Behavior keywords come only from the question itself (the last
            # text block), never from a recap that quotes earlier questions.
            question_text = text_blocks[-1] if text_blocks else ""
            if "WEDGED" in question_text:
                # Signal handlers can only be set on the main thread.
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
            # Like the real CLI, turns run one at a time, in order.
            for previous_thread in turn_threads:
                previous_thread.join()
            turn_thread = threading.Thread(target=handle_user_turn, args=(question_text,))
            turn_thread.start()
            turn_threads.append(turn_thread)

    for turn_thread in turn_threads:
        turn_thread.join()
    log_event({"event": "stdin_closed_exit"})


if __name__ == "__main__":
    main()

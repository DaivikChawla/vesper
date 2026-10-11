#!/usr/bin/env python3
"""
Reads Vesper's log (~/Library/Logs/Vesper.log, plus Vesper.log.1) and her
crash reports, and reports what she did — what went right and what went
wrong — interaction by interaction, with a list of problems found and what
usually fixes each one.

Usage:
    python3 scripts/vesper-log-report.py             # everything in the log
    python3 scripts/vesper-log-report.py --hours 3   # only the last 3 hours
    python3 scripts/vesper-log-report.py --last 10   # detail for the last 10 interactions

No Claude usage, nothing sent anywhere; it only reads local files.
"""

import argparse
import datetime
import json
import re
import statistics
from collections import Counter, defaultdict
from pathlib import Path

LOG_DIRECTORY = Path.home() / "Library/Logs"
LOG_FILES = [LOG_DIRECTORY / "Vesper.log.1", LOG_DIRECTORY / "Vesper.log"]
CRASH_REPORT_DIRECTORY = LOG_DIRECTORY / "DiagnosticReports"

LINE_STAMP_PATTERN = re.compile(r"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})\] (.*)$")
SLOW_FIRST_WORD_SECONDS = 4.0


class Interaction:
    """Everything logged from one hotkey press until the next."""

    def __init__(self, started_at, started_by):
        self.started_at = started_at
        self.started_by = started_by
        self.lines = []
        self.transcript = None
        self.microphone_name = None
        self.voice_check = None
        self.first_spoken_word_seconds = None
        self.claude_first_text_seconds = None
        self.did_think = False
        self.problems = []
        self.actions = []

    def summary_line(self):
        time_text = self.started_at.strftime("%H:%M:%S") if self.started_at else "??:??:??"
        heard = f'"{self.transcript[:70]}"' if self.transcript else "(nothing understood)"
        details = []
        if self.first_spoken_word_seconds is not None:
            details.append(f"first word {self.first_spoken_word_seconds:.1f}s")
        if self.did_think:
            details.append("thought first")
        if self.voice_check:
            details.append(self.voice_check)
        if self.actions:
            details.append("did: " + ", ".join(self.actions[:4]) + ("…" if len(self.actions) > 4 else ""))
        status = "✅" if not self.problems else "⚠️"
        problems = ("  → " + "; ".join(self.problems)) if self.problems else ""
        return f"{status} {time_text} {heard}  [{' · '.join(details)}]{problems}"


def read_log_lines(since):
    """(timestamp or None, text) for every line, oldest first."""
    log_lines = []
    for log_file in LOG_FILES:
        if not log_file.exists():
            continue
        for raw_line in log_file.read_text(errors="replace").splitlines():
            stamp_match = LINE_STAMP_PATTERN.match(raw_line)
            if stamp_match:
                timestamp = datetime.datetime.strptime(stamp_match[1], "%Y-%m-%d %H:%M:%S.%f")
                line_text = stamp_match[2]
            else:
                timestamp, line_text = None, raw_line
            # With a time window, lines without a stamp (older builds) can't
            # be placed, so they're left out.
            if since and (timestamp is None or timestamp < since):
                continue
            log_lines.append((timestamp, line_text))
    return log_lines


def split_into_interactions(log_lines):
    interactions = []
    current_interaction = None
    last_known_timestamp = None
    for timestamp, line_text in log_lines:
        last_known_timestamp = timestamp or last_known_timestamp
        if "hotkey pressed" in line_text:
            # Older logs have no stamp per line, but the ⏱️ lines carry the time.
            press_time_match = re.search(r"⏱️ (\d{2}:\d{2}:\d{2})\.\d{3} hotkey pressed", line_text)
            if timestamp is None and press_time_match:
                last_known_timestamp = datetime.datetime.strptime(press_time_match[1], "%H:%M:%S")
            current_interaction = Interaction(last_known_timestamp, "hotkey")
            interactions.append(current_interaction)
        elif "Listening for an answer" in line_text or "👂 Listening" in line_text:
            current_interaction = Interaction(last_known_timestamp, "listening for an answer")
            interactions.append(current_interaction)
        if current_interaction is not None:
            current_interaction.lines.append(line_text)
    return interactions


def analyze_interaction(interaction):
    for line_text in interaction.lines:
        if "received transcript:" in line_text:
            interaction.transcript = line_text.split("received transcript:", 1)[1].strip()
        if match := re.search(r"mic live \((.+)\)", line_text):
            interaction.microphone_name = match[1]
        if "🔐 Voice check:" in line_text:
            interaction.voice_check = line_text.split("🔐 Voice check:", 1)[1].strip()
            if "not you" in line_text:
                interaction.problems.append("voice check rejected it" + (f" on {interaction.microphone_name}" if interaction.microphone_name else ""))
        if match := re.search(r"release→first spoken word ([\d.]+)s", line_text):
            interaction.first_spoken_word_seconds = float(match[1])
        if match := re.search(r"claude first text ([\d.]+)s", line_text):
            interaction.claude_first_text_seconds = float(match[1])
        if "started a thinking block" in line_text or "started a redacted_thinking block" in line_text:
            interaction.did_think = True
        if line_text.startswith("⚡ Quick action:") or line_text.startswith("⚡ Shortcut:"):
            interaction.actions.append(line_text.split(":", 1)[1].strip()[:40])
        if line_text.startswith("🖐️ ") and not any(word in line_text for word in ("Waiting", "stopped", "Skipped", "Confirmation", "Screen changed")):
            interaction.actions.append(line_text[2:].strip()[:40])
        if "📅 Added" in line_text or "⏰" in line_text:
            interaction.actions.append(line_text.split(" ", 1)[1][:40])
        if "Waiting for a yes" in line_text:
            interaction.actions.append("asked for a yes")
        if any(marker in line_text for marker in ("failed to start recognition", "Mic didn't start", "wouldn't start", "Released before the mic started")):
            interaction.problems.append("mic didn't start")
        if "No words recognized" in line_text:
            heard_match = re.search(r"\(([\d.]+)s of sound heard\)", line_text)
            heard_seconds = float(heard_match[1]) if heard_match else 0
            interaction.problems.append("speech heard but no words understood" if heard_seconds > 0.5 else "heard nothing (mic off? lid closed?)")
        if "no reply after" in line_text or "reply stalled" in line_text:
            interaction.problems.append("Claude didn't answer in time")
        if "process exited unexpectedly" in line_text:
            interaction.problems.append("Claude process crashed")
        if "Vesper response error" in line_text:
            interaction.problems.append("error: " + line_text.split(":", 1)[-1].strip()[:80])
        if "refused" in line_text.lower() and ("⚡" in line_text or "🖐️" in line_text):
            interaction.problems.append(line_text.strip()[:80])
        if "Kokoro:" in line_text and ("took over" in line_text or "hung" in line_text):
            interaction.problems.append("Kokoro voice hung")
        if "never finished playing" in line_text:
            interaction.problems.append("speech got stuck (audio output vanished?)")
    if interaction.first_spoken_word_seconds and interaction.first_spoken_word_seconds > SLOW_FIRST_WORD_SECONDS:
        interaction.problems.append(f"slow: first word after {interaction.first_spoken_word_seconds:.1f}s")


def recent_crash_reports(since):
    crash_reports = []
    if not CRASH_REPORT_DIRECTORY.exists():
        return crash_reports
    for crash_report_path in sorted(CRASH_REPORT_DIRECTORY.glob("Vesper-*.ips")):
        modified_at = datetime.datetime.fromtimestamp(crash_report_path.stat().st_mtime)
        if since and modified_at < since:
            continue
        crash_description = "unknown"
        try:
            report_text = crash_report_path.read_text(errors="replace")
            body = json.loads(report_text.split("\n", 1)[1])
            exception = body.get("exception", {})
            crash_description = f"{exception.get('type', '?')} {exception.get('signal', '')}".strip()
            faulting_thread = body.get("threads", [{}])[body.get("faultingThread", 0)] if body.get("threads") else {}
            frame_symbols = [frame.get("symbol") for frame in faulting_thread.get("frames", []) if frame.get("symbol")]
            if frame_symbols:
                crash_description += " in " + " ← ".join(frame_symbols[:3])
        except (ValueError, IndexError, KeyError):
            pass
        crash_reports.append((modified_at, crash_report_path.name, crash_description))
    return crash_reports


def main():
    argument_parser = argparse.ArgumentParser(description="What Vesper did, and what went wrong.")
    argument_parser.add_argument("--hours", type=float, help="only the last N hours")
    argument_parser.add_argument("--last", type=int, default=15, help="show the last N interactions in detail (default 15)")
    arguments = argument_parser.parse_args()
    since = datetime.datetime.now() - datetime.timedelta(hours=arguments.hours) if arguments.hours else None

    log_lines = read_log_lines(since)
    interactions = split_into_interactions(log_lines)
    for interaction in interactions:
        analyze_interaction(interaction)

    print(f"# Vesper activity report ({len(interactions)} interactions{f', last {arguments.hours:g} h' if arguments.hours else ''})\n")

    first_word_times = [interaction.first_spoken_word_seconds for interaction in interactions if interaction.first_spoken_word_seconds]
    if first_word_times:
        print(f"- Time to her first word: median {statistics.median(first_word_times):.1f}s, "
              f"fastest {min(first_word_times):.1f}s, slowest {max(first_word_times):.1f}s ({len(first_word_times)} replies)")
    thinking_count = sum(interaction.did_think for interaction in interactions)
    print(f"- Replies where Claude thought first: {thinking_count}")
    print(f"- Interactions with no problems: {sum(not interaction.problems for interaction in interactions)} of {len(interactions)}")
    all_actions = [action for interaction in interactions for action in interaction.actions]
    if all_actions:
        example_actions = list(dict.fromkeys(all_actions))[:3]
        print(f"- Actions taken: {len(all_actions)} (e.g. {'; '.join(example_actions)})")

    problem_counts = Counter(problem.split(" on ")[0] if problem.startswith("voice check") else re.sub(r"[\d.]+s", "Ns", problem)
                             for interaction in interactions for problem in interaction.problems)
    print("\n## Problems found\n")
    if not problem_counts:
        print("None. 🎉")
    for problem, count in problem_counts.most_common():
        print(f"- {count}× {problem}")

    voice_scores_by_microphone = defaultdict(list)
    for timestamp, line_text in log_lines:
        if match := re.search(r"Voice check: (?:you|not you) \(([\d.]+)\)(?: on (.+?))?(?: — ignored)?$", line_text):
            voice_scores_by_microphone[match[2] or "mic not logged"].append(float(match[1]))
    if voice_scores_by_microphone:
        print("\n## Voice check scores by microphone (threshold 0.65)\n")
        for microphone_name, scores in voice_scores_by_microphone.items():
            rejected_count = sum(score < 0.65 for score in scores)
            print(f"- {microphone_name}: {len(scores)} checks, median {statistics.median(scores):.2f}, "
                  f"range {min(scores):.2f}–{max(scores):.2f}, {rejected_count} rejected")

    audio_output_changes = sum("audio output changed" in line_text for _, line_text in log_lines)
    microphone_switches = sum("Mac's microphone" in line_text or "fresh audio engine" in line_text for _, line_text in log_lines)
    if audio_output_changes or microphone_switches:
        print(f"\n## Audio devices\n\n- Audio output changes mid-reply: {audio_output_changes}\n- Mic engine rebuilt: {microphone_switches}")

    crash_reports = recent_crash_reports(since)
    if crash_reports:
        print("\n## Crashes\n")
        for modified_at, file_name, crash_description in crash_reports:
            print(f"- {modified_at:%Y-%m-%d %H:%M} {crash_description}  ({file_name})")

    print("\n## What usually fixes these\n")
    hints = {
        "voice check rejected it": "Redo \"only my voice\" setup on the mic you're using (each mic keeps its own voiceprint).",
        "mic didn't start": "Usually a Bluetooth headset switching modes; the new build rebuilds the mic engine and retries. Repeated: check System Settings → Sound → Input.",
        "heard nothing (mic off? lid closed?)": "With the lid closed the built-in mic is off; use AirPods or open the lid.",
        "speech heard but no words understood": "Speak a little longer or closer; very short or noisy clips get no words.",
        "Claude didn't answer in time": "Network or Claude being slow; she replaces the stuck process automatically.",
        "speech got stuck (audio output vanished?)": "Output device disappeared mid-sentence; the playback watchdog moves on.",
        "Kokoro voice hung": "Kokoro reloads itself; after two hangs it's off until restart.",
    }
    shown_hint = False
    for problem in problem_counts:
        for hint_key, hint_text in hints.items():
            if problem.startswith(hint_key):
                print(f"- **{hint_key}**: {hint_text}")
                shown_hint = True
    if any(problem.startswith("slow") for problem in problem_counts):
        print("- **slow replies**: check whether those turns 'thought first' (hands-on or 'think' questions) — that's expected there.")
        shown_hint = True
    if not shown_hint:
        print("- Nothing to fix.")

    print(f"\n## Last {min(arguments.last, len(interactions))} interactions\n")
    for interaction in (interactions[-arguments.last:] if arguments.last > 0 else []):
        print("- " + interaction.summary_line())


if __name__ == "__main__":
    main()

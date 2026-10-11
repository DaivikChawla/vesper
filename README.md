# Vesper

A personal screen companion that lives in the macOS menu bar. Hold **Control + Option**, ask a question out loud, and Vesper looks at your screen, answers in her own voice, and flies a small blue cursor to whatever she's talking about, one step at a time.

- **Claude** runs through your own `claude` CLI (Claude Code), on your Claude subscription. The app has no Anthropic API key.
- **Speech recognition** is Apple's on-device SpeechAnalyzer. Nothing is uploaded.
- **Her voice** is Google's Chirp 3 HD, Kokoro running on your Mac, or both (see [Voices](#voices)).

Forked from [farzaa/clicky](https://github.com/farzaa/clicky) (MIT).

## Requirements

- macOS 26.6 or later. The app runs on any macOS 26 release, but 26.5 has an Apple bug that can crash the Kokoro voice, fixed in 26.6.
- Xcode 26 or later (the macOS platform alone is enough)
- [Claude Code](https://claude.com/claude-code), installed and logged in: run `claude` once in Terminal and log in with your Claude account

## Setup

1. Open `leanring-buddy.xcodeproj` in Xcode. The first time, Xcode downloads the FluidAudio package (the Kokoro voice engine); wait until it finishes.
2. Select the target, go to **Signing & Capabilities**, and pick your own team. A free Personal Team works.
   Keep **"Apple Development"** signing. Don't use "Sign to Run Locally": its signature changes on every build, and macOS then asks for Screen Recording and Accessibility permission again each time.
3. Press **Cmd+R**. Grant the four permissions the panel asks for (Microphone, Accessibility, Screen Recording, Screen Content). After Screen Recording, quit Vesper and press Cmd+R again, because macOS only applies that permission on restart. Then click **Start**.
4. For the Google voice, add a Google API key (see [Getting a Google API key](#getting-a-google-api-key)). Without one, she uses Kokoro.

On first launch, two things download in the background: the on-device speech recognition model, and the Kokoro voice (~174 MB, skipped if it's already cached). Kokoro then takes about 15–20 seconds to prepare the first time. Until each is ready she uses a fallback, so she's never silent.

## Voices

In the menu bar panel, **Voice** has three modes:

| Mode | What it does |
|---|---|
| **Auto** (default) | For the first sentence of each reply, Google and Kokoro start at the same time. If Google answers within about 0.7 s, Google speaks the whole reply. If Google is slower, Kokoro's version (already made) speaks instead, so you never wait on a slow connection. If Google loses three times in a row, Auto uses Kokoro only for the next 10 minutes. |
| **Google** | Always Google's Chirp 3 HD voice. Needs the internet. |
| **Kokoro** | Always Kokoro, on your Mac. Offline, instant, unlimited, about 0.3 s per sentence. |

- **Google voice** lets you pick which female Chirp 3 HD voice she uses: Aoede, Kore, Leda, Zephyr, and more.
- **Kokoro** uses about 500 MB of memory while loaded, so it's only loaded in Auto and Kokoro modes.
- **If a voice fails, that sentence falls back** (to Kokoro in Auto, then to the macOS voice), so she never goes silent.
- The panel shows each voice's status and which one spoke last.

## Getting a Google API key

Google gives **1,000,000 Chirp 3 HD characters free every month**, roughly 3–6 times what Vesper uses. Vesper counts every character it sends and **stops using Google at 950,000 in a month**, so it can't run up a bill; after that, Auto and Google modes use Kokoro until the next month. Google still requires a card on file.

1. Go to **https://console.cloud.google.com** and sign in with your Google account. Accept the terms if asked.
2. **Create a project.** Use the project picker at the top of the page → **New Project**, name it `vesper`, click **Create**, then make sure `vesper` is selected in the picker.
3. **Turn on billing.** Menu (☰) → **Billing** → link a billing account to the project and add your card. You won't be charged while under the free 1,000,000 characters a month.
4. **Enable the API.** Menu → **APIs & Services** → **Library** → search for **Cloud Text-to-Speech API** → **Enable**.
5. **Create the key.** Menu → **APIs & Services** → **Credentials** → **Create credentials** → **API key**, then copy the key it shows.
6. **Lock the key to text-to-speech,** so it's useless for anything else if it ever leaks. On the Credentials page, click the new key → **API restrictions** → **Restrict key** → tick **Cloud Text-to-Speech API** → **Save**.
7. Optional safety net: Menu → **Billing** → **Budgets & alerts** → **Create budget** of $1 with email alerts.
8. In Vesper's panel, paste the key into **Google API key** and click **Save**. It's stored in your Mac's Keychain.

If something's wrong, the panel's Google status line says what, for example "billing isn't enabled on the Google Cloud project" or "Text-to-Speech API isn't enabled on the project".

## Using it

- **Hold Control + Option**, ask, and let go. She answers out loud, with a caption beside the cursor.
- **Press the shortcut again while she's talking** to interrupt her and ask something else.
- The menu bar panel shows your Claude usage (5-hour and weekly windows) and lets you:
  - switch between Sonnet (faster) and Opus;
  - choose the voice mode and the Google voice;
  - choose how much she can do on your Mac (see below);
  - toggle captions;
  - keep the cursor always visible, or only while you're talking to her;
  - start a new conversation.
- At 80% Claude usage she switches to **saver mode**: she sends a smaller screenshot of only the screen your cursor is on.
- If your plan's limit is reached, she tells you when she'll be back, instead of failing silently.

## Letting her do things

**Control** in the panel sets how much she can do on your Mac:

- **Off**: she only talks and points.
- **Quick** (default): she can open apps and websites ("open youtube in chrome and search lofi"), control Apple Music ("play some queen", "pause", "skip"), and set the volume. These run instantly and cost no extra Claude usage. Music can only play what's in your library; macOS asks once for permission to control Music.
- **Hands-on**: she can also click, type, press keys and scroll, step by step. She acts, looks at the screen again, and picks the next step until the job's done, for example "open fiverr, read my new buyer messages, summarise them and draft a reply". Each step is one short Claude request with a screenshot. **Max steps per task** (default 30) caps a single task.

Hands-on safety, enforced by Vesper itself, not left to Claude:

- Before clicking anything that looks like send, post, buy, pay, delete, submit or accept, and before pressing Return in a message box, she **asks out loud**. Hold Control + Option and say "yes" to go ahead, "no" to stop, or say what to change instead.
- She **never types or pastes into password fields**. Passwords, card numbers and codes are yours to enter.
- **Control + Option stops her** mid-task (so does Stop in the panel). The cursor turns **amber** while she has the controls.
- Text on web pages, messages and emails is treated as information, never as instructions to her.
- It's a safety net, not a guarantee. An icon-only button in an app that hides itself from Accessibility can look harmless to her. Watch what she does, especially the first few times.

## Checking things from the terminal

Don't run `xcodebuild` from the terminal. Building from there invalidates macOS privacy permissions. These are safe instead:

```bash
scripts/typecheck.sh                     # compile errors, without building the app
python3 scripts/verify-claude-bridge.py  # the claude CLI still behaves the way Vesper expects (~6 Claude requests)
scripts/test-claude-bridge.sh            # the Claude connection against a fake CLI
scripts/test-response-parser.sh          # splitting replies into sentences, [POINT] and action tags
scripts/test-computer-control.sh         # computer-control safety checks (nothing is clicked for real)
scripts/test-voice-router.sh             # which voice speaks, in each mode
scripts/test-google-voice.sh             # the Google voice against a fake Google server
scripts/test-kokoro-voice.sh             # Kokoro with the real model
scripts/test-speech-output.sh            # plays test sentences out loud
```

All of them except `verify-claude-bridge.py` use no Claude usage and need no API keys.

## How it works

```
 hotkey (CGEvent tap) ──► BuddyDictationManager ──► SpeechAnalyzer (on-device transcript)
          │                     │                └► utterance recorder ─► VesperVoiceIdentity (only-my-voice check)
          │                     ▼
          │             CompanionManager  ◄── screenshot (ScreenCaptureKit), memory notes, control mode
          │                     │
          │                     ▼
          │         ClaudeCodeCLIBridge ── one long-lived `claude -p` (stream-json) ──► text deltas
          │                     │
          │                     ▼
          │         VesperResponseStreamParser ──► segments: (sentence, [POINT], [actions])
          │                     │
          │        ┌────────────┼──────────────────────────────┐
          │        ▼            ▼                              ▼
          │  VesperSpeechPlaybackEngine          VesperCursorOverlayController   quick actions / hands-on runner
          │  └ VesperVoiceRouter                 (Core Animation cursor,         (VesperComputerControl +
          │    ├ Google Chirp 3 HD (REST)         SwiftUI caption islands)        VesperActionSafety)
          │    ├ Kokoro 82M (FluidAudio, ANE)
          │    └ macOS voice (fallback)
          └── barge-in: pressing the hotkey while she talks interrupts the CLI turn and stops audio
```

- **Claude bridge (`ClaudeCodeCLIBridge.swift`).** One `claude -p` process stays alive and speaks stream-json over stdin/stdout, which avoids a ~1.7 s boot on every question and keeps the conversation. All tools, MCP servers and settings are switched off, nothing is saved to disk, and it rolls over to a fresh process with a short recap when the context grows, after 10 idle minutes, or after a crash.
- **Transcription.** Apple SpeechAnalyzer runs fully on-device and streams while the hotkey is held.
- **Speech.** One `AVAudioEngine` plays sentences from Google, Kokoro or the macOS voice, picked by `VesperVoiceRouter`. The next sentence is synthesised while the current one plays.
- **Overlay.** Each screen gets a transparent full-screen window. The cursor is Core Animation layers; SwiftUI draws only the small islands (captions, waveform, thinking dots).

The app target is still named `leanring-buddy`, as in the original Clicky project.

## Credit

Vesper started as a fork of [Clicky](https://github.com/farzaa/clicky) by Farza, released under the MIT licence. The original copyright notice is kept in [LICENSE](LICENSE).

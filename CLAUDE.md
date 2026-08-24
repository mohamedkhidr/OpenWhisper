# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

OpenSuperWhisper is a native macOS menu-bar app (SwiftUI + AppKit) that records audio and transcribes it locally via Whisper (whisper.cpp) or Parakeet (FluidAudio), then inserts the text into the focused app. macOS 14+, Apple Silicon or Intel (x86_64).

## Build & run

Requires macOS with Xcode. First-time setup:

```shell
git submodule update --init --recursive
brew install cmake libomp rust ruby
gem install xcpretty
```

- `./run.sh build` — builds `libwhisper` (CMake), copies `libomp.dylib`, then `xcodebuild`s the app (Debug, ad-hoc/unsigned). Output at `Build/Build/Products/Debug/OpenSuperWhisper.app`.
- `./run.sh` (no args) — same build, then launches the resulting app and streams its logs.
- CI (`.github/workflows/build.yml`) just runs `./run.sh build` on `macos-latest`; treat that script as the source of truth for the build steps.

`libwhisper/whisper.cpp` is a git submodule — do not edit CMake output artifacts directly; rebuild via `run.sh`. Swift Package Manager pulls `GRDB.swift`, `KeyboardShortcuts`, and `FluidAudio`.

## Tests

Two XCTest targets: `OpenSuperWhisperTests` (unit + integration) and `OpenSuperWhisperUITests`. Run from Xcode or:

```shell
xcodebuild test -scheme OpenSuperWhisper -destination "platform=macOS,arch=$(uname -m)"
```

Single test class/method:

```shell
xcodebuild test -scheme OpenSuperWhisper -destination "platform=macOS,arch=$(uname -m)" \
  -only-testing:OpenSuperWhisperTests/WhisperEngineConversionTests/testSequentialConversionPreservesFullDuration
```

Notes:
- Some tests (`WhisperStateIsolationTests`) need `ggml-tiny.en.bin` and `jfk.wav` present at the repo root and `XCTSkip` themselves otherwise.
- `ClipboardUtilPasteIntegrationTests` and the keyboard-layout tests drive real system input sources and launch TextEdit via Accessibility APIs — they require Accessibility permission for the test runner and will skip layouts that aren't installed on the machine.
- `MicrophoneInventoryTests` enumerates real audio hardware; expect environment-dependent output, not fixed assertions.

## Release

`./make_release.sh <version> <code_sign_identity> [github_token]` bumps `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in the pbxproj, calls `notarize_app.sh` to build/sign/notarize, produces a DMG + dSYM, tags and pushes, and (with a token) creates a GitHub release and uploads assets, plus prints an updated Homebrew cask stanza. This is a maintainer-only, destructive/publishing script — never run it without explicit instruction.

## Architecture

**Transcription engines.** `TranscriptionEngine` (Engines/TranscriptionEngine.swift) is the protocol both backends implement:
- `WhisperEngine` — wraps whisper.cpp through the `Whis/` Swift layer (`WhisperContextParams`, `WhisperFullParams`, `MyWhisperContext`, etc.) and the C bridging header (`Bridge.h` → `whisper.h`). Loads the model **without** a decoding state (`initFromFileNoState`) and creates a fresh `whisper_state` per transcription (`initState`/`freeState`) so one recording's decode context can never leak into the next. Runs the bundled Silero VAD (`ggml-silero-v5.1.2.bin`) before decoding so whisper never sees non-speech audio (avoids hallucinations on silence); VAD trimming is skipped when timestamps are requested since trimmed audio no longer maps to original offsets. Audio is resampled to 16kHz mono; long files go through a parallel conversion path.
- `FluidAudioEngine` — wraps the FluidAudio (Parakeet) SPM package.

`TranscriptionService` (singleton, `@MainActor`) owns the currently loaded engine and **serializes** all transcription calls — a whisper context must not process two transcriptions concurrently, and both the hotkey/indicator flow and the file queue flow can reach it, so calls queue on `transcriptionTask`.

**Recording pipeline.** `TranscriptionQueue` (singleton, `@MainActor`) is the single consumer that pulls pending `Recording`s (persisted via GRDB/SQLite in `RecordingStore`, `Models/Recording.swift`) and drives them through convert → transcribe → store. Two distinct sources feed the queue and are handled differently on completion:
- Hotkey dictations (`AudioRecorder`'s temp dir) are **moved** into the recordings directory, and empty-text results are silently discarded and deleted (`TranscriptionQueue.shouldDiscardEmptyDictation`).
- User-dropped/imported files (`FileDropHandler`, `application(_:open:)` in `OpenSuperWhisperApp.swift`) are **copied**, and empty results are kept (the user explicitly asked to transcribe that file).

**Global hotkey / recording trigger.** `ShortcutManager` is the single owner of exactly one of three mutually-exclusive trigger modes (torn down and re-armed together whenever preferences change): a regular `KeyboardShortcuts` combo, a single modifier key (`ModifierKeyMonitor`, e.g. Left ⌘/Right ⌥/Fn), or a mouse button (`MouseButtonMonitor`, e.g. middle/thumb button). Each supports hold-to-record and (for modifier keys) double-tap-to-trigger. On key-down it immediately starts `AudioRecorder` before resolving where to anchor the floating indicator (`FocusUtils` AX lookup, race against a timeout) — recording must never wait on a possibly-hung focused app.

**Text insertion.** `ClipboardUtil` + `FocusUtils` insert transcribed text into the focused app via the clipboard/AX APIs, aware of the active keyboard input source (`KeyboardLayoutProvider` resolves per-layout key labels so paste-based typing works across non-QWERTY layouts).

**UI shell.** `OpenSuperWhisperApp`/`AppDelegate` run as a status-bar app with one `WindowGroup` (settings/history) plus a borderless `IndicatorWindow` (via `IndicatorWindowManager`) shown near the cursor while recording/transcribing. The app can hide to the menu bar (`startHiddenInMenuBar`) and adopts/re-adopts the SwiftUI-owned main window through window-notification observers rather than owning it directly, since SwiftUI can recreate or redelegate it.

**Models & settings.** `WhisperModelManager` manages downloadable `.bin` models under Application Support (bundles a default `ggml-tiny.en.bin`); `AppPreferences` is the `UserDefaults`-backed settings singleton; `PermissionsManager` handles mic/Accessibility permission prompts/checks.

**`agent/`** is a standalone Python dev tool (not part of the app) that picks an open GitHub issue, drives `aider` to implement it, builds via `run.sh`, and opens a PR — unrelated to app runtime code.

## Repo conventions

- `run.sh` is the canonical build recipe — when build steps change, update it (and this file's summary), not just CI.
- Whisper decode isolation (fresh `whisper_state` per call) and the dictation-vs-imported-file distinction in `TranscriptionQueue` are load-bearing invariants with regression tests (`WhisperStateIsolationTests`, `EmptyDictationDiscardTests`) — preserve them when touching transcription or queue code.

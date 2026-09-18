# Development and verification

The [main README](../README.md) is the installation and user guide for DAVE 1.0.0. This document replaces the development-version release notes and obsolete implementation plans.

## Source layout

| Path | Purpose |
| --- | --- |
| `macos/Sources/` | Native SwiftUI/AppKit interface, permissions, recording, playback, document preparation, and preferences |
| `macos/Tests/` | Standalone Swift behavior tests and fixed public speech fixture |
| `windows/LocalVoice/` | Native .NET Windows Forms interface, audio, shortcuts, and UI Automation integration |
| `windows/Tests/` | Portable C# document, preference, and speaker-correction tests |
| `core/` | Local model engine, integrity-checked catalogs, audio resampling, synthesis and recognition runtimes |
| `macos/backend/` | Shared JSONL service used by both apps, segmentation and speaker identification |
| `scripts/`, platform `scripts/` directories | Current regression checks, model checks, builds, and packaging |

The service accepts bounded requests, validates model IDs and audio, and confines temporary files to a private session directory. Downloading curated model files is explicit; inference uses local files. Models and preferences are not build artifacts and should not be removed during cleanup.

## Tests

Use Node.js 24 and npm. Mac checks require macOS 14+ and Apple Command Line Tools. Full Xcode is not required for standalone Swift test executables.

```sh
npm ci
npm run check:repository
npm run test:core
npm test
```

`test:core` runs the shared engine, model integrity, audio, acceleration, cancellation, and speaker regressions. `npm test` runs Mac document/preferences, system integration rules, interactions, and transcription controller tests on macOS. On Windows it runs C# domain checks plus offscreen UI and buffered-audio-seek checks; renders are saved under `test-results/windows-ui`. Tests that access the pasteboard, audio system, or GPU need normal macOS service access; a sandbox denial is not a product pass. These are not XCUITest results.

For real model execution:

```sh
npm run models:smoke
npm run test:smoke
npm run test:speech
npm run test:audio
npm run test:transcription-backend
npm run test:transcription-real
npm run test:transcription-playback
node scripts/speaker-model-check.mjs
node scripts/speaker-correction-check.mjs --packaged
```

`models:smoke` explicitly downloads basic test models into `.cache/models`. Speaker tests also need their speaker packs. `node macos/scripts/transcription-backend-check.mjs --download-fixtures` explicitly downloads hash-pinned public voice fixtures into `.cache/transcription-fixtures`; regular runs do not fetch fixtures. The independent fixed WAV is `macos/Tests/Fixtures/speech.wav`.

The larger speaker check expects Compact in `.cache/models` and Accurate/Precision in `.cache/speaker-quality`. The correction check uses Accurate plus Whisper Tiny GPU files in `.cache/acceleration-models`, and the two-speaker fixture produced by the backend check. The scripts report missing prerequisites rather than silently treating a skipped model as a pass. See [speaker models](SPEAKER_MODELS.md), [Metal runtime](METAL.md), and [Supertonic](SUPERTONIC.md) for specialized commands and caches.

## Package Mac

```sh
npm run build:native
npm run test:package
node macos/scripts/archive.mjs
node macos/scripts/dmg.mjs
node scripts/release-check.mjs
```

Output: `release/native/DAVE.app`, a ZIP, and a DMG named with the package version and CPU architecture. The backend dependency directory is rebuilt from the current production dependency graph so removed packages cannot linger in a bundle. The build verifies its code signature. Local ad-hoc signing is not Developer ID signing or notarization; permission grants can become stale after a rebuild. Apple Silicon Metal builds use pinned whisper.cpp and CMake downloads. Intel GPU execution is not claimed.

## Package Windows

```sh
npm run build:windows
```

This runs portable C# tests, publishes the self-contained Windows x64 app, installs locked Windows native inference dependencies, verifies pinned runtime downloads, and creates `release/DAVE-Windows-1.0.0-x64.zip` with a SHA256 file. The package includes the main README and its linked documentation. The optional installer lives beside `DAVE.exe` and preserves preferences and models.

`windows/toolchain/pins.json` pins official .NET SDK, Node, whisper.cpp CPU/CUDA, and Microsoft VCLibs archives. Hashes are verified before extraction. Windows uses `dotnet` from PATH; Apple Silicon Mac downloads a repository-local SDK. Other build hosts can set `LOCALVOICE_DOTNET` to their SDK executable. Native optional npm packages target Windows x64 and installation scripts stay disabled; packaging checks their presence. Windows packaging runs on Windows or Apple Silicon Mac; it does not establish that the app executes on the build host. CI workflows are `.github/workflows/verify.yml` (Mac) and `.github/workflows/windows.yml` (Windows). Hosted Windows runners do not provide NVIDIA GPU acceptance.

On a real Windows NVIDIA machine, download Tiny GPU files in the app, then run:

```sh
node windows/scripts/runtime-check.mjs
```

The check uses the installed model directory (or `LOCALVOICE_MODELS`) and exercises the packaged service with real recorded speech. It requires meaningful words and evidence of an initialized GPU backend, not merely a compiled CUDA capability. It deliberately fails on non-Windows hosts. Reading and speaker identification remain CPU operations.

## Release acceptance and known limits

The 1.0.0 baseline was exercised on Apple Silicon with actual local synthesis, Whisper Metal recognition, per-caption speaker embeddings, repeated-voice fixtures, native correction/undo/export tests, preference persistence, and package integrity checks. A successful unit test is not evidence that another application's field accepts text. The Windows update has been built on Windows, rendered at two window widths, and tested with actual packaged CUDA recognition on an RTX 3090. Microphone, output-device behavior, external-app interaction, and mixed-DPI monitor acceptance are still pending. See [Windows parity and validation](WINDOWS_PARITY.md).

Before a public release:

1. On the exact Mac bundle, verify permissions and physically test the reading and dictation shortcuts in a disposable browser/TextEdit field. Test changed focus, a secure field, right-side modifier matching, clipboard fallback, compact controls, and microphone completion. Permission-toggle appearance or synthetic callbacks alone do not establish this.
2. On Windows, test microphone start/stop, Enter/shortcut completion, global selected-text reading, exact-target paste protection, clipboard fallback, shortcut conflicts, local/system voice playback, pause/seek/speed, file captions, speaker correction/undo/export, and the per-user installer. Run the GPU check on compatible NVIDIA hardware.
3. Compare models on representative recordings. Similar voices, roleplay, laughter, overlapping speech, and one mixed microphone can confuse speaker labels. Larger model capacity is not a measured guarantee of better D&D accuracy.
4. Establish release hosting, project distribution licensing, stable Mac Developer ID signing/notarization, and Windows Authenticode signing. No public package-manager entry is currently published.

Speaker corrections use confirmed examples for the current recording; they do not fine-tune model weights or save a cross-recording voice profile. At least two confirmed identities are needed for conservative reassignment. Manual corrections are protected; Undo preserves new captions that arrived after an edit. Caption timing is phrase-level, with audio-region fallback when word alignment is unavailable. Export transcripts before quitting because sessions are not automatically saved.

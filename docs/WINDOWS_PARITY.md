# Windows parity and validation

The Windows app shares model catalogs, local inference, acceleration reporting, and speaker processing with the Mac app. Its Windows presentation uses WPF with a WinForms host for the existing audio and system integration controller. Recognition installs and automatic acceleration defaults are shared with the Mac app.

## Implemented

- Sidebar navigation, consistent button states, readable tables, high-contrast palette support, wrapping toolbars and settings, and per-monitor DPI awareness.
- Shared-mode, event-driven WASAPI playback; buffered audio and pitch state reset on seek; replay after completion; generated audio files released before deletion.
- Bounded Windows CPU thread pools for Transformers/ONNX and Whisper, leaving one logical processor available up to an eight-thread maximum. This is a resource policy, not a measured speedup claim. Supertonic and speaker identification retain their existing conservative thread counts.
- Separate Automatic/CPU/NVIDIA recognition choices, honest fallback reporting, and packaged CUDA dependencies.
- Dictation read-back and optional local wording suggestions with explicit acceptance; selected-text reading restores the prior clipboard when its copied contents have not subsequently changed.
- Compact playback/recording controls on the active monitor, with top/bottom preference.
- Wrapped reading passages with headings, bold emphasis and fenced-code styling; optional code reading; click-to-read and double-click-to-edit; cancelable dictation.
- Platform-aware `npm start` and `npm test`; actionable SDK detection; Windows UI checks in packaging; ZIP creation through the Windows tar utility.

## September 24 update

- Windows now follows the Mac source layout in `macos/Sources/Views.swift`, `TranscriptionView.swift`, and `CompactPanel.swift`: light 175-point sidebar, bottom Settings entry, separate grouped settings window, compact top toolbar, Read/Edit segmented controls, centered reader empty state, sentence navigation, dictation waveform, and grouped model library.
- The application icon is generated from the same `build/icon.svg` artwork. Toolbar icons are original vector equivalents of the Mac symbols, not Apple SF Symbols assets. Windows retains its own window chrome and Segoe UI font. Visual checks here are against the SwiftUI source structure; a Mac screenshot comparison is still needed before claiming pixel-identical rendering.
- Reading speed now uses SoundTouch tempo processing instead of resampling plus phase-vocoder pitch correction. Normal speed is sample-exact. Tests cover 0.5, 1, 1.2, 1.5 and 2 times speed at 16/24/48 kHz, mono/stereo, expected duration, pitch, seeking, and live rate changes. SoundTouch is shipped as a separate replaceable DLL with its LGPL license and source reference.
- The library identifies the selected GPU and its dedicated memory. Recognition models explain their recommended uses and include NVIDIA GPU plus CPU fallback. Reading voices explicitly say CPU; no GPU reading speedup is implied.
- WPF settings have per-voice sample controls, cancelable previews, persistent acceleration selection and keyboard shortcut capture. Wording proposals appear inline and speaker corrections use WPF dialogs.
- The tray menu mirrors the Mac menu-bar actions. Closing the main window keeps DAVE available for global shortcuts; choose **Quit DAVE** in the tray menu to exit.
- Offscreen checks render empty/edit/read states, all main pages at 760 and 1040 logical pixels, settings and compact controls. They check control bounds and reopen settings to catch stale visual ownership. Physical microphone, screen-reader and mixed-monitor acceptance remain manual gates.
- `node windows/scripts/build-check.mjs --parity` builds to `release/windows-parity/DAVE` without overwriting a running older app. Add `--parity` to the packaged runtime and reading checks to test this folder.

### Validation and local signing blocker

Release compilation succeeds with zero warnings/errors. The WPF render and SoundTouch checks passed before the final combo-box text-clipping adjustment. Windows Code Integrity then rejected the rebuilt `DAVE.dll` with event 3077 and error `0x800711C7`; final UI execution is blocked by Windows Application Control. Smart App Control is enabled on this PC (`VerifiedAndReputablePolicyState = 1`); the event's wording does not establish that the PC is organization-managed. No trusted code-signing certificate was found in the current user store. Signing trusted by the active policy is required; security policy was not changed.

The packaged GPU fixture selected the RTX 3090 through CUDA and returned the expected transcript. Automatic fallback with a complete Tiny model bundle used ONNX CPU and returned the same transcript. A legacy GPU-only install hit a signing block on native `runtime/cpu/whisper.dll`; completing its CPU model files enables the ONNX path. Packaged Kokoro generation/cache/cancellation checks passed (first generation about 6.24 seconds; cached retrieval about 0.00044 seconds). These results do not establish subjective speech quality or pixel-identical Mac appearance.

## September 18 update

- Recognition installation now downloads both CPU and GPU files on Mac and Windows. Partial installs resume without redownloading verified files; removal covers the whole bundle.
- Automatic recognition prefers GPU and falls back to CPU. Legacy processor selections migrate once to Automatic; subsequent explicit choices are preserved. Windows lists NVIDIA adapters by name and memory, stores explicit choices by UUID, and selects the largest dedicated-memory adapter by default. Intel/AMD adapters are not claimed as CUDA devices.
- Windows settings use spaced cards and stacked labels; rounded buttons and quieter navigation replace rectangular outlines. The green notification countdown is removed.
- Reading keeps its service and model warm, warms the selected voice in advance, suppresses redundant document rendering, and caches up to 64 MB of generated audio per service session. Canceling queued reading work no longer kills the service.
- Real Kokoro test on this PC: initial synthesis about 6.0 seconds, cached retrieval about 0.0005 seconds. The old warm uncached baseline was about 5 seconds for 4.85 seconds of audio. Cache retrieval excludes playback startup; this is a replay/seek improvement, not faster generation of unseen text. A DirectML probe failed on a Kokoro ConvTranspose operation, so GPU reading is not enabled or claimed.
- Packaged automatic recognition selected the RTX 3090 by UUID and reported CUDA. With a deliberately unavailable saved GPU, the same fixture completed on CPU and reported the fallback reason.
- Native domain tests pass 22 assertions. Shared tests pass except the two pre-existing Windows symbolic-link permission failures described below.
- New tests cover bundle completion, interrupted downloads, stable multi-GPU routing, cached synthesis, cancellation, and regeneration of deleted files. `node windows/scripts/reading-check.mjs --packaged` checks the packaged reader using an installed Kokoro model.
- Mac source changes need compilation and UI acceptance on macOS; this Windows machine cannot run those checks.

## Earlier verification on September 17, 2026

- Windows Release build: zero compiler errors or warnings.
- Native domain checks: 20 assertions passed.
- Five UI pages rendered at 960- and 1280-pixel window widths; images inspected for clipped labels and button layout. The harness also checks buffered seek against a fresh audio provider without playing sound.
- Shared Node suite: 48/50 passed. Two existing model-storage tests cannot create their symbolic-link fixtures under this machine's Windows permissions; they remain failures rather than being hidden as passes.
- Packaged CPU recognition also returned the exact fixed-fixture transcript with `provider: cpu`.
- Packaged Whisper Tiny on NVIDIA GeForce RTX 3090, driver 581.57: exact fixed-fixture transcript, with `provider: cuda` from initialized-backend diagnostics. The fixture says “The garden is quiet today. Please bring three blue notebooks to the kitchen.” This validates recognition, not speaker identification or every model size.

Reproduce GPU recognition with `node windows/scripts/runtime-check.mjs`; add `--cpu` for the packaged CPU path. Both use installed Tiny GPU-format weights, or `LOCALVOICE_MODELS` pointing to a managed test model directory. Models downloaded for this validation are isolated in `.cache/windows-validation-models` and do not change the user's model selections.

## Remaining parity and acceptance work

- The Windows reader supports common Markdown presentation, not full Markdown fidelity. Mac generation-progress visualization is still richer; Windows reports generation/buffering status as text.
- Windows x64 NVIDIA acceleration is supported. AMD/Intel GPU acceleration and Windows ARM64 are not included; those require separately packaged and validated runtimes. Reading and speaker identification still run on CPU.
- Physically verify microphone start/stop, dictation insertion and changed-focus protection, clipboard restoration across third-party apps, shortcut conflicts, playback device changes, mixed-DPI monitors, keyboard/screen-reader navigation, and installer updates.
- Model quality and throughput on long recordings, all supported model sizes, and battery behavior require representative benchmarks. No universal performance or complete feature-parity claim is made by a successful build.

Keep the Mac and Windows acceptance lists in `DEVELOPMENT.md` as the release gate.

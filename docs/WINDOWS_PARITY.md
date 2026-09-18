# Windows parity and validation

The Windows app shares model catalogs, local inference, acceleration reporting, and speaker processing with the Mac app. Its native UI remains WinForms. These changes improve Windows behavior without changing Mac inference settings.

## Implemented

- Sidebar navigation, consistent button states, readable tables, high-contrast palette support, wrapping toolbars and settings, and per-monitor DPI awareness.
- Shared-mode, event-driven WASAPI playback; buffered audio and pitch state reset on seek; replay after completion; generated audio files released before deletion.
- Bounded Windows CPU thread pools for Transformers/ONNX and Whisper, leaving one logical processor available up to an eight-thread maximum. This is a resource policy, not a measured speedup claim. Supertonic and speaker identification retain their existing conservative thread counts.
- Separate Automatic/CPU/NVIDIA recognition choices, honest fallback reporting, and packaged CUDA dependencies.
- Dictation read-back and optional local wording suggestions with explicit acceptance; selected-text reading restores the prior clipboard when its copied contents have not subsequently changed.
- Compact playback/recording controls on the active monitor, with top/bottom preference.
- Wrapped reading passages with headings, bold emphasis and fenced-code styling; optional code reading; click-to-read and double-click-to-edit; cancelable dictation.
- Platform-aware `npm start` and `npm test`; actionable SDK detection; Windows UI checks in packaging; ZIP creation through the Windows tar utility.

## Verification on September 17, 2026

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

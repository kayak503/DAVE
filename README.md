# DAVE — Dictation And Voice Engine

**Everything on your device.**

Version 1.0.0

Private reading, dictation, and audio-file transcription, with separate native Mac and Windows apps. Download models once, then process audio and text locally. No account, cloud inference, or model server is required.

The Mac interface uses SwiftUI/AppKit. The Windows interface uses WinForms. Both bundle their local speech engine. English is the initial supported language.

## Install on Mac

Requires macOS 14 or newer. The Apple Silicon build is in `release/native/DAVE.app`.

- Open `release/DAVE-1.0.0-macos-arm64.dmg` and drag **DAVE** into **Applications**, then open it.
- Alternatively, extract `release/DAVE-Native-1.0.0-arm64.zip` and move the app into Applications.
- From this source checkout, after building, run `bash macos/scripts/install.sh` to install into your personal Applications folder and open it. The installer refuses to overwrite an existing copy; save your session and quit before replacing it in Finder.

The current local Mac artifact is **ad-hoc signed, not notarized**. A trusted public download needs Developer ID signing and notarization. There is no published Homebrew package or public download URL yet. Do not disable Gatekeeper or remove quarantine to install it. Mac System Voice works immediately; other voices and recognition models are downloaded from within the app.

### Permissions and verification

Microphone access is requested when recording starts. Accessibility is needed for global shortcuts, reading selected text, and inserting into another app.

In Settings, click **Verify Accessibility**. It checks the running process, compares a fresh process, and retries shortcut registration. **Reveal This App** locates the exact copy you are running. If macOS still denies this copy despite an enabled entry, remove the stale entry in System Settings → Privacy & Security → Accessibility and add that exact app. An ad-hoc rebuild can invalidate a previous grant. Save your work and reopen the app if verification reports that only the fresh process sees permission.

Verification does not promise that every third-party text field supports insertion. External dictation is always copied to the clipboard as a fallback. Secure fields are excluded. Reading uses the target app’s Copy command for the selected text, preserves the original clipboard, and falls back to Accessibility selection lookup. It never sends Select All.

## Install on Windows

Requires Windows 10/11 x64. The self-contained package includes .NET, Node, CPU inference, and NVIDIA CUDA dependencies. No Python, Node, or .NET installation is needed to run it.

1. Extract `release/DAVE-Windows-1.0.0-x64.zip` into a writable folder.
2. Open the extracted **DAVE** folder and run **DAVE.exe**. Keep every accompanying folder with the executable.
3. For a per-user installation and Start Menu shortcut, open PowerShell in that extracted folder and run `./install.ps1`. No administrator access is needed. If your organization blocks unsigned scripts, use the portable app or ask your administrator about deployment.

Quit the app after exporting session work before installing an update. The installer preserves models and preferences. These local builds are **not Authenticode-signed**. There is no published winget/Chocolatey package or public download URL yet. Windows runtime acceptance is still pending; compilation does not verify its microphone, shortcuts, or GPU.

### Windows permissions, shortcuts, and GPU

Defaults are **Ctrl+Alt+R** for selected-text reading and **Ctrl+Alt+D** to start/finish dictation. Record Ctrl/Alt/Shift shortcuts in Settings; left/right modifiers are not distinguished on Windows. The verification button re-registers shortcuts and briefly checks microphone capture. Microphone access is controlled by **Settings → Privacy → Microphone**, including access for desktop apps. Windows has no macOS Accessibility permission.

Dictation copies text first, then requests paste only if the original nonpassword editable field is still focused. Changed, unsupported, or elevated targets may require manual **Ctrl+V**. A paste request does not prove the destination accepted the text.

For NVIDIA acceleration, install a driver compatible with **CUDA 12.4**, download the selected recognition model's **GPU files** in Models, then choose **Automatic** or **NVIDIA GPU** in Settings. Automatic reports CPU fallback; explicit GPU reports failure if CUDA cannot start. AMD and Intel GPUs use CPU in this build.

## What it does

- **Read:** paste text or open Markdown. Read mode renders the document; Edit mode exposes its source. Click a sentence to seek, double-click to edit. Click **Speed** to cycle 0.5×, 1×, 1.2×, 1.5×, and 2× without regenerating audio. The Mac reader supports arrow-key sentence skipping and 3–10 sentences of generation ahead. Generation progress and throughput warnings explain when a model cannot keep up.
- **Dictate:** start recording and press the button or shortcut again to finish. The Mac waveform scrolls right to left. Review or copy the text; external dictation attempts insertion and retains a clipboard fallback. Plain transcription and optional local wording suggestions are separate choices.
- **Transcribe:** import a recording, receive captions incrementally, listen to the recording, click captions to seek, and export TXT, SRT, or WebVTT. Long audio is decoded in bounded chunks. Stop retains completed captions.
- **Correct speakers:** first naming Speaker 1 as Seb renames that identity throughout the transcript. Later edits can correct just one passage to John. Confirmed examples can conservatively reclassify similar, unconfirmed passages. Undo restores corrections; exports retain names. Overlapping voices and very short turns remain difficult.
- **Choose models:** independent recognition settings for dictation and transcription; multiple reading voices within Kokoro and Supertonic; compact, accurate, and precision speaker-identification packs. Downloads are explicit, and inference stays local.

On Mac the default shortcuts are **Option+Q** to read selected text and **Option+W** to start/finish dictation. Settings save automatically. Shortcut capture supports modifier combinations and left/right variants. Compact controls can appear at the top or bottom of the screen.

## Models and acceleration

Whisper recognition models and WeSpeaker speaker-identification models solve different problems. A larger Whisper model can improve words without fixing who said them.

The optional **WeSpeaker ResNet293 LM (Precision)** pack is approximately **120.3 MB**, alongside Compact and ResNet152 Accurate. Each pack uses its own matching thresholds. Repeated-voice tests verify identity consistency and usable correction embeddings, but do not establish that the largest model is best for your D&D recording. Compare a representative excerpt before transcribing hours of audio. See [speaker model details and evidence](docs/SPEAKER_MODELS.md).

Apple Silicon recognition supports **Metal**, with separate Automatic/CPU/Apple GPU choices for dictation and transcription. Windows uses a bundled **CUDA** recognition runtime for compatible NVIDIA GPUs. Download the GPU model files in the app; they are distinct from CPU ONNX model files. Explicit GPU mode reports failure instead of silently claiming acceleration. Automatic mode reports CPU fallback. **Reading and speaker identification currently use CPU**, even when recognition uses GPU. See [Mac acceleration internals](docs/METAL.md) and [Supertonic models](docs/SUPERTONIC.md).

## Data and privacy

Mac preferences live in `~/Library/Application Support/LocalVoiceNative/preferences.json`. Existing models in `~/Library/Application Support/Hearth/models` are reused when present; otherwise models live under `LocalVoiceNative/models`. Windows stores models, preferences, and temporary sessions under `%LOCALAPPDATA%\Local Voice`; the optional installer puts the app under `%LOCALAPPDATA%\Programs\DAVE`. Documents and transcripts are session-only: export work before quitting or updating. Temporary audio is removed after use or clean shutdown. Clipboard copies remain on the system clipboard until replaced.

## Build and verify

Mac developers need Node.js 24, npm, and Apple Command Line Tools:

```sh
npm ci
npm run build:native
npm start
```

For the native Windows package, run `npm run build:windows` after `npm ci`. The build uses checksum-pinned runtime downloads and either the Windows .NET SDK or a repository-local SDK on Apple Silicon Mac. Compilation on Mac is not Windows runtime validation.

See [development and verification](docs/DEVELOPMENT.md) for test commands, fixtures, packaging, architecture, and outstanding platform checks. See [dependencies and model notices](docs/DEPENDENCIES.md) for the runtime inventory. Public distribution still needs hosting, signing, and platform acceptance testing.

## Upgrading from Local Voice

DAVE keeps the existing app identity and model/settings storage paths for compatibility. No redownload or manual data migration is needed. Save/export your work and quit Local Voice before opening DAVE; the Mac single-instance check prevents both versions from running together. The Windows installer checks for both executable names. Install DAVE, then remove the old app/shortcut when you no longer need it; keep the data folders listed above.

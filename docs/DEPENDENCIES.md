# Dependencies and model sources

Project distribution license is intentionally undecided (`UNLICENSED`); this is not a grant to distribute the project's own source. Public distribution needs a project license decision and the normal third-party notices review.

| Component | Role | Declared upstream license | Source |
|---|---|---|---|
| Transformers.js 3.8.1 | Local model orchestration | Apache-2.0 | https://github.com/huggingface/transformers.js |
| ONNX Runtime Node 1.21.0 | Native CPU inference | MIT | https://github.com/microsoft/onnxruntime |
| Kokoro.js 1.2.1 | Local speech synthesis wrapper | Apache-2.0 | https://github.com/hexgrad/kokoro |
| phonemizer | Local text-to-phoneme runtime | Inspect installed package and bundled eSpeak NG notices before public redistribution | https://github.com/xenova/phonemizer.js |
| Whisper Tiny/Base/Small/Medium English and Large v3 Turbo ONNX | Speech recognition assets | MIT model cards | https://huggingface.co/onnx-community/whisper-tiny.en |
| Kokoro 82M v1 ONNX and bundled voices | Text-to-speech assets | Apache-2.0 model card | https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX |
| Flan-T5 small ONNX | Optional experimental rewording | Apache-2.0 model card | https://huggingface.co/Xenova/flan-t5-small |

Exact repository revisions, asset paths and integrity hashes are in `core/catalog.json`. The application does not execute downloaded model code. Hugging Face is used for model acquisition only; inference uses local files with remote access disabled. This table is engineering inventory, not a claim that a full distribution/legal review has been completed.

The local-only boundary is tested by replacing network fetch with a throwing guard (and a positive-control request), loading actual installed models, generating audio, and transcribing it. It establishes that those exercised inference paths made no fetch calls. It is not an OS-wide packet capture or a blanket guarantee about every dependency on every platform.

Native interfaces use SwiftUI/AppKit on Mac and .NET 8 Windows Forms on Windows. Windows bundles NAudio and System.Speech; exact versions are in `windows/LocalVoice/LocalVoice.csproj`. Runtime archive pins and hashes are in `windows/toolchain/pins.json` (Node, .NET, whisper.cpp CPU/CUDA, and app-local Microsoft Visual C++ libraries). Packaging retains dependency licenses and third-party notices.

Additional model/runtime documentation: [Metal and whisper.cpp](METAL.md), [speaker identification and attribution](SPEAKER_MODELS.md), and [Supertonic models](SUPERTONIC.md). `macos/backend/speaker-models.json` and `core/supertonic-catalog.json` are the authoritative asset catalogs. Speaker inference uses sherpa-onnx-node; these model licenses are distinct from the inference toolkit's license.

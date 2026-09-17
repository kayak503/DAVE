# Local speaker identification

Whisper recognizes words. Speaker identification is a separate model; selecting a larger Whisper does not improve voice identity embeddings.

| Pack | Embedding | Total download | Use |
| --- | --- | --- | --- |
| Compact | WeSpeaker English VoxCeleb ResNet34 LM | 32.5 MB | Faster local speaker labeling |
| Larger | WeSpeaker English VoxCeleb ResNet152 LM | 85.2 MB | Higher-capacity option for group recordings; slower CPU inference |
| Largest | WeSpeaker English VoxCeleb ResNet293 LM | 120.3 MB | Largest supported English pack; more CPU work and model-specific thresholds |

All three include the same 6 MB Pyannote segmentation 3.0 conversion. Installation is explicit, checks exact byte size and SHA-256, and stores the packs separately. Existing compact installs remain valid. No inference requires network access. ResNet152 and ResNet293 are larger architectures, not a guarantee of higher accuracy on a particular recording. Similar voices, character voices, laughter, noise, short interjections and overlapping speech remain difficult. There is no source separation: overlapping participants cannot be reliably recovered from one mixed microphone by renaming a caption.

## Integration

`new LocalDiarization(modelDir, { modelID: 'compact' | 'accurate' | 'precision' })` exposes the existing `installed`, `install`, `process` and `reset` methods. `speakerModelCatalog` contains display metadata, expected asset hashes and model-specific clustering thresholds. Unknown IDs throw before filesystem access.

`await embeddingFor(Float32Array)` returns a normalized numeric array, or `undefined` for under 1.5 seconds, silence, or an invalid/unavailable embedding. Input is 16 kHz mono, finite, normalized and at most 60 seconds; embedding work is bounded to the first 12 seconds. The caller must supply **only one non-overlapping caption**, never a pooled speaker group, and preserve the model ID alongside corrections. The API cannot prove that arbitrary audio contains one person. Embeddings from different models must never be mixed. `process` also excludes overlapping intervals before calculating pooled cluster identities.

## Validation and limits

`node scripts/speaker-model-check.mjs` checks all three installed packs offline against three hash-pinned public speech fixtures: two different utterances from one English speaker and one from another. It requires same-speaker similarity to exceed different-speaker similarity by at least 0.2; checks stable labels across recordings and a combined two-speaker timeline; rejects silent correction references. These are functional smoke tests, not a D&D diarization benchmark.

ResNet152 embeddings have a different cosine distribution from ResNet34. The larger pack uses a conservative 0.75 cross-chunk match threshold and 0.25 agglomerative cosine-distance threshold, compared with compact 0.55/0.5. These thresholds are initial engineering defaults validated on the fixtures, not universally calibrated probabilities. On our three-clip test, raw same/different similarities were approximately 0.949/0.630 for larger and 0.872/0.368 for compact. Thus a common 0.55 identity threshold would incorrectly merge the larger model's two voices. Similarity itself is not an accuracy metric; the larger model did not demonstrate a wider same/different margin on this small test.

The ResNet293 pack uses a 0.84 cross-chunk match threshold and 0.16 clustering distance. Its fixture similarities were 0.953/0.743, so the ResNet152 threshold would be too close to the different-speaker score. Correction learning uses 0.88 minimum similarity and the existing 0.12 runner-up margin for this pack. Confirmed corrections remain protected. This model ran the embedding/diarization smoke workflow in about 9.9 seconds on the development M4 Pro, compared with 5.2 seconds for ResNet152 and 2.2 seconds for compact. These timings cover the script's repeated recordings, not a real-time transcription benchmark.

ResNet293 is the largest English WeSpeaker model distributed in the supported Sherpa speaker model release. We selected its compatible ONNX runtime rather than introducing a separate Python/PyTorch stack. Larger self-supervised WeSpeaker research checkpoints exist, but are not interchangeable with this runtime. On these fixtures ResNet293 did **not** show a larger same/different separation margin. The app therefore offers it explicitly without claiming it fixes D&D roleplay, similar voices, or overlap. For the best input, use separate participant tracks where possible and correct clean, single-person passages; speaker counts cannot separate overlapping mixed audio.

The new pack is downloaded only on request; `precision` never replaces existing pack files. For a new developer cache, download the public fixtures and compact/larger packs first, then run `node scripts/speaker-model-check.mjs --install-precision` to download and verify the largest pack through the production installer. Normal test runs block all network access. The `--prepare` option imports already downloaded developer files and checks them before inference.

## Sources and licenses

- [Sherpa speaker identification documentation](https://k2-fsa.github.io/sherpa/onnx/speaker-identification/index.html) and its [supported model release](https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-recongition-models).
- [WeSpeaker pretrained model documentation](https://github.com/wenet-e2e/wespeaker/blob/master/docs/pretrained.md): ResNet34/152/293 English VoxCeleb models, large-margin fine tuning, and model license. The toolkit is Apache-2.0; the VoxCeleb pretrained models follow the dataset's CC BY 4.0 license. Attribution: WeSpeaker authors and VoxCeleb creators. Downloads retain unmodified model weights.
- [Pyannote segmentation conversion](https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0), MIT conversion, used by the existing compact pack.
- [Public test speech](https://github.com/csukuangfj/sr-data/tree/main/test/3d-speaker), used only for the explicit local validation script.

## Caption timing and fixtures

Speaker count is a file-wide upper bound, not a requirement that every chunk contain every speaker. Overlapping turns are decoded once with a combined label because segmentation does not isolate independent audio tracks. Unknown intervals are transcribed without an identity. Whisper provides segment timing; when timestamp decoding fails but ordinary decoding succeeds, the caption covers the real decoded audio region instead of inventing word alignment.

Public hash-pinned voice fixtures are downloaded explicitly with `node macos/scripts/transcription-backend-check.mjs --download-fixtures`. They are cached under `.cache/transcription-fixtures` and are not bundled in the app. The regular backend check expects Whisper Tiny and the speaker pack in `.cache/models` (override with `LOCALVOICE_TEST_MODELS`). See [development checks](DEVELOPMENT.md) for the full workflow.

# Local Supertonic reading models

DAVE supports two distinct CPU ONNX reading models from Supertone:

| Model                                                         | Pinned revision                            | Download | Voices       |
| ------------------------------------------------------------- | ------------------------------------------ | -------- | ------------ |
| [Supertonic 2](https://huggingface.co/Supertone/supertonic-2) | `75e6727618a02f323c720cba9478152d4bc16ca4` | 268 MB   | F1–F5, M1–M5 |
| [Supertonic 3](https://huggingface.co/Supertone/supertonic-3) | `3cadd1ee6394adea1bd021217a0e650ede09a323` | 402 MB   | F1–F5, M1–M5 |

These are alternatives to Kokoro, not guarantees of a universally better voice. Supertonic 3 uses a larger network. Preview voices on your machine to compare pronunciation and speed. DAVE currently uses English language tags for both models. The 10 voice styles are included in each model download; selecting another style does not require a separate download.

The manifest includes immutable revisions, byte sizes, and SHA-256 hashes for ONNX assets; Git blob SHA-1 hashes cover ordinary repository files. Installation includes the models' OpenRAIL-M license. The runtime is adapted from Supertone's [official MIT-licensed Node implementation](https://github.com/supertone-inc/supertonic/blob/main/nodejs/helper.js), with attribution and the full license included in its source.

`core/supertonic.mjs` opens local files only and explicitly uses the CPU ONNX provider. There is no inference download path. Each utterance uses five refinement steps. Text is bounded to 300-character chunks and 20,000 characters per request; long unspaced tokens are also split. Unknown characters are removed before embedding lookup. Generated durations are checked before allocating audio buffers. Graphs and temporary tensors are released when unloaded or after a failed operation.

Playback speed should continue to be applied by the native player, allowing dynamic changes without regenerating audio. The generation API also validates optional speed values for other callers.

## Verification

- `node --test tests/supertonic.test.mjs`: chunk limits, normalization, invalid inputs, manifest shape and all 20 included voice files.
- `node scripts/supertonic-check.mjs`: hash-verifies every installed asset, synthesizes real speech in F1 and M1 for both models, checks finite non-silent audio, and runs the generated audio through local Whisper Tiny to verify recognizable words. Network access is deliberately blocked throughout inference. It also tests invalid voice IDs, invalid speed, and unloading.

The real check expects the two models installed under `.cache/supertonic-check` (override with `SUPERTONIC_MODEL_DIR`) and an existing Whisper Tiny installation under `.cache/models/whisper-tiny`. It never downloads files implicitly. WAV evidence is written to `test-results/supertonic-{2,3}-{F1,M1}.wav`.

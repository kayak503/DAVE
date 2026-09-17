/* Supertonic ONNX inference, adapted from https://github.com/supertone-inc/supertonic/nodejs/helper.js
 * Copyright (c) 2025 Supertone Inc. MIT License.
 * Permission is hereby granted, free of charge, to any person obtaining a copy of this software
 * and associated documentation files (the "Software"), to deal in the Software without restriction,
 * including without limitation the rights to use, copy, modify, merge, publish, distribute,
 * sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions: The above copyright notice and this
 * permission notice shall be included in all copies or substantial portions of the Software.
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
 * BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
 * DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import * as ort from 'onnxruntime-node';

export const supertonicVoices = Object.freeze([
  'F1',
  'F2',
  'F3',
  'F4',
  'F5',
  'M1',
  'M2',
  'M3',
  'M4',
  'M5',
]);
const networks = ['duration_predictor', 'text_encoder', 'vector_estimator', 'vocoder'];

export function speechChunks(text, limit = 300) {
  if (typeof text !== 'string' || !text.trim()) throw new Error('Enter some text to read.');
  if (text.length > 20000) throw new Error('Read text in sections of at most 20,000 characters.');
  if (!Number.isInteger(limit) || limit < 10) throw new Error('Invalid text chunk limit.');
  const chunks = [];
  let rest = text.replace(/\s+/gu, ' ').trim();
  while (rest.length > limit) {
    let cut = rest.lastIndexOf(' ', limit);
    if (cut < limit / 2) cut = limit;
    // Keep surrogate pairs intact when breaking a long unspaced token.
    if (/[\uD800-\uDBFF]/u.test(rest[cut - 1])) cut--;
    chunks.push(rest.slice(0, cut).trim());
    rest = rest.slice(cut).trim();
  }
  if (rest) chunks.push(rest);
  return chunks;
}

export function encodeText(text, indexer) {
  let normalized = text
    .normalize('NFKD')
    .replace(/[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}]/gu, '')
    .replace(/[–‑—]/gu, '-')
    .replace(/[“”]/gu, '"')
    .replace(/[‘’´`]/gu, "'")
    .replace(/[_\[\]|/#→←]/gu, ' ')
    .replace(/[♥☆♡©\\]/gu, '')
    .replace(/@/gu, ' at ')
    .replace(/e\.g\.,/gu, 'for example, ')
    .replace(/i\.e\.,/gu, 'that is, ')
    .replace(/\s+([,.!?;:'])/gu, '$1')
    .replace(/"{2,}/gu, '"')
    .replace(/'{2,}/gu, "'")
    .replace(/\s+/gu, ' ')
    .trim();
  // Unsupported symbols must never produce undefined/negative embedding indices.
  normalized = Array.from(normalized)
    .filter((c) => Number.isInteger(indexer[c.codePointAt(0)]) && indexer[c.codePointAt(0)] >= 0)
    .join('')
    .trim();
  if (!normalized) throw new Error('This text contains no supported spoken characters.');
  if (!/[.!?;:,'"\)\]}…。」』】〉》›»]$/u.test(normalized)) normalized += '.';
  return BigInt64Array.from(Array.from(`<en>${normalized}</en>`), (c) => {
    const id = indexer[c.codePointAt(0)];
    if (!Number.isInteger(id) || id < 0)
      throw new Error('The installed text index is invalid. Reinstall this model.');
    return BigInt(id);
  });
}

function floatTensor(data, dims) {
  return new ort.Tensor('float32', data, dims);
}
function styleTensor(style) {
  if (
    !style ||
    !Array.isArray(style.dims) ||
    style.dims.length !== 3 ||
    style.dims[0] !== 1 ||
    !style.dims.every((n) => Number.isInteger(n) && n > 0)
  )
    throw new Error('Invalid installed voice style.');
  const flat = style.data?.flat(Infinity);
  if (
    !flat ||
    flat.length !== style.dims.reduce((a, b) => a * b, 1) ||
    !flat.every(Number.isFinite)
  )
    throw new Error('Invalid installed voice data.');
  return floatTensor(Float32Array.from(flat), style.dims);
}

// No downloader or remote loader is reachable here. Model installation is a separate explicit action.
export async function createSupertonic(directory, model) {
  if (!path.isAbsolute(directory) || !['supertonic-2', 'supertonic-3'].includes(model?.id))
    throw new Error('Invalid local Supertonic model.');
  const json = async (file) => JSON.parse(await readFile(path.join(directory, file), 'utf8'));
  const config = await json('onnx/tts.json');
  const indexer = await json('onnx/unicode_indexer.json');
  const sampleRate = config.ae?.sample_rate;
  const chunkSize = config.ae?.base_chunk_size * config.ttl?.chunk_compress_factor;
  const channels = config.ttl?.latent_dim * config.ttl?.chunk_compress_factor;
  if (
    ![sampleRate, chunkSize, channels].every((n) => Number.isInteger(n) && n > 0) ||
    sampleRate > 96000 ||
    channels > 2048
  )
    throw new Error('Invalid installed speech configuration.');
  const sessions = [];
  const styles = new Map();
  let disposed = false;
  let busy = false;
  try {
    // Sequential loading permits complete cleanup if any graph fails to load.
    for (const name of networks)
      sessions.push(
        await ort.InferenceSession.create(path.join(directory, 'onnx', `${name}.onnx`), {
          executionProviders: ['cpu'],
          intraOpNumThreads: 2,
          interOpNumThreads: 1,
        }),
      );
  } catch (error) {
    await Promise.allSettled(sessions.map((s) => s.release()));
    throw error;
  }
  const [durationPredictor, textEncoder, vectorEstimator, vocoder] = sessions;
  const steps = 5;

  async function infer(text, style, speed) {
    const tensors = new Set();
    const keep = (t) => {
      tensors.add(t);
      return t;
    };
    const outputs = (result) => {
      for (const t of Object.values(result)) keep(t);
      return result;
    };
    try {
      const ids = encodeText(text, indexer);
      const textIDs = keep(new ort.Tensor('int64', ids, [1, ids.length]));
      const mask = keep(floatTensor(new Float32Array(ids.length).fill(1), [1, 1, ids.length]));
      const duration =
        outputs(
          await durationPredictor.run({ text_ids: textIDs, style_dp: style.dp, text_mask: mask }),
        ).duration.data[0] / speed;
      if (!Number.isFinite(duration) || duration <= 0 || duration > 60)
        throw new Error('Speech duration was invalid. Try a shorter sentence.');
      const sampleCount = Math.floor(duration * sampleRate);
      const length = Math.ceil(sampleCount / chunkSize);
      const embedding = outputs(
        await textEncoder.run({ text_ids: textIDs, style_ttl: style.ttl, text_mask: mask }),
      ).text_emb;
      const noise = new Float32Array(channels * length);
      for (let i = 0; i < noise.length; i++)
        noise[i] =
          Math.sqrt(-2 * Math.log(Math.max(1e-10, Math.random()))) *
          Math.cos(2 * Math.PI * Math.random());
      let latent = keep(floatTensor(noise, [1, channels, length]));
      const latentMask = keep(floatTensor(new Float32Array(length).fill(1), [1, 1, length]));
      const totalStep = keep(floatTensor(Float32Array.of(steps), [1]));
      for (let step = 0; step < steps; step++) {
        const currentStep = keep(floatTensor(Float32Array.of(step), [1]));
        const result = outputs(
          await vectorEstimator.run({
            noisy_latent: latent,
            text_emb: embedding,
            style_ttl: style.ttl,
            text_mask: mask,
            latent_mask: latentMask,
            total_step: totalStep,
            current_step: currentStep,
          }),
        );
        tensors.delete(latent);
        latent.dispose();
        tensors.delete(currentStep);
        currentStep.dispose();
        latent = result.denoised_latent;
      }
      const result = outputs(await vocoder.run({ latent }));
      const audio = Float32Array.from(result.wav_tts.data.subarray(0, sampleCount));
      if (!audio.length || !audio.every(Number.isFinite))
        throw new Error('The reading model produced invalid audio.');
      return audio;
    } finally {
      for (const tensor of tensors) tensor.dispose();
    }
  }
  return {
    async generate(text, { voice = 'F1', speed = 1 } = {}) {
      if (disposed) throw new Error('This speech model has been unloaded.');
      if (busy) throw new Error('Speech generation is already in progress.');
      if (!supertonicVoices.includes(voice))
        throw new Error('Choose a Supertonic voice from F1–F5 or M1–M5.');
      if (!Number.isFinite(speed) || speed < 0.5 || speed > 2)
        throw new Error('Speech speed must be between 0.5 and 2.');
      const chunks = speechChunks(text);
      busy = true;
      try {
        let style = styles.get(voice);
        if (!style) {
          const data = await json(`voice_styles/${voice}.json`);
          const ttl = styleTensor(data.style_ttl);
          try {
            style = { ttl, dp: styleTensor(data.style_dp) };
          } catch (error) {
            ttl.dispose();
            throw error;
          }
          styles.set(voice, style);
        }
        const pieces = [];
        for (const chunk of chunks) {
          if (pieces.length) pieces.push(new Float32Array(Math.round(sampleRate * 0.15)));
          pieces.push(await infer(chunk, style, speed));
        }
        const audio = new Float32Array(pieces.reduce((sum, p) => sum + p.length, 0));
        let offset = 0;
        for (const piece of pieces) {
          audio.set(piece, offset);
          offset += piece.length;
        }
        return { audio, sampling_rate: sampleRate };
      } finally {
        busy = false;
      }
    },
    async dispose() {
      if (disposed) return;
      if (busy) throw new Error('Cannot unload speech while generation is in progress.');
      disposed = true;
      for (const style of styles.values()) {
        style.ttl.dispose();
        style.dp.dispose();
      }
      styles.clear();
      const outcomes = await Promise.allSettled(sessions.map((s) => s.release()));
      const failure = outcomes.find((o) => o.status === 'rejected');
      if (failure) throw failure.reason;
    },
  };
}

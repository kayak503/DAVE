import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { createSupertonic } from '../core/supertonic.mjs';
const models = JSON.parse(
  await readFile(new URL('../core/supertonic-catalog.json', import.meta.url)),
);
// A download is never performed by this test or the runtime. Install first, then run entirely offline.
globalThis.fetch = () => {
  throw new Error('Network access attempted during local inference');
};
await mkdir('test-results', { recursive: true });
const hf = await import('@huggingface/transformers');
hf.env.allowRemoteModels = false;
hf.env.allowLocalModels = true;
hf.env.useFSCache = false;
hf.env.useBrowserCache = false;
const recognizer = await hf.pipeline(
  'automatic-speech-recognition',
  path.resolve('.cache/models/whisper-tiny'),
  { device: 'cpu', dtype: 'q8', local_files_only: true },
);
try {
  for (const model of models) {
    const directory = path.resolve(
      process.env.SUPERTONIC_MODEL_DIR || '.cache/supertonic-check',
      model.id,
    );
    for (const f of model.files) {
      const b = await readFile(path.join(directory, f.path));
      assert.equal(b.length, f.size);
      const h = createHash(f.algorithm === 'sha256' ? 'sha256' : 'sha1');
      if (f.algorithm === 'git-sha1') h.update(`blob ${b.length}\0`);
      assert.equal(h.update(b).digest('hex'), f.hash, `${model.id}/${f.path} checksum`);
    }
    const start = performance.now();
    const runtime = await createSupertonic(directory, model);
    try {
      await assert.rejects(
        runtime.generate('Hello', { voice: '../../etc/passwd' }),
        /Choose a Supertonic voice/,
      );
      await assert.rejects(runtime.generate('Hello', { speed: NaN }), /speed/);
      let first;
      for (const voice of ['F1', 'M1']) {
        const { audio, sampling_rate } = await runtime.generate(
          'The garden is quiet today. Please bring three blue notebooks to the kitchen.',
          { voice, speed: 1 },
        );
        assert.equal(sampling_rate, 44100);
        assert(audio.length > sampling_rate);
        assert(audio.every(Number.isFinite));
        const rms = Math.sqrt(audio.reduce((s, x) => s + x * x, 0) / audio.length);
        assert(rms > 0.005 && rms < 1, `nonsilent finite ${voice} output`);
        const hash = createHash('sha256').update(Buffer.from(audio.buffer)).digest('hex');
        if (first) assert.notEqual(hash, first);
        first = hash;
        const wav = Buffer.alloc(44 + audio.length * 2);
        wav.write('RIFF');
        wav.writeUInt32LE(wav.length - 8, 4);
        wav.write('WAVEfmt ', 8);
        wav.writeUInt32LE(16, 16);
        wav.writeUInt16LE(1, 20);
        wav.writeUInt16LE(1, 22);
        wav.writeUInt32LE(sampling_rate, 24);
        wav.writeUInt32LE(sampling_rate * 2, 28);
        wav.writeUInt16LE(2, 32);
        wav.writeUInt16LE(16, 34);
        wav.write('data', 36);
        wav.writeUInt32LE(audio.length * 2, 40);
        for (let i = 0; i < audio.length; i++)
          wav.writeInt16LE(Math.round(Math.max(-1, Math.min(1, audio[i])) * 32767), 44 + i * 2);
        await writeFile(`test-results/${model.id}-${voice}.wav`, wav);
        const input = new Float32Array(Math.floor((audio.length * 16000) / sampling_rate));
        for (let i = 0; i < input.length; i++) {
          const x = (i * sampling_rate) / 16000,
            j = Math.floor(x),
            f = x - j;
          input[i] = audio[j] * (1 - f) + audio[Math.min(j + 1, audio.length - 1)] * f;
        }
        const transcript = (
          await recognizer(input, { max_new_tokens: 96, do_sample: false })
        ).text.toLowerCase();
        const matched = ['garden', 'quiet', 'notebooks', 'kitchen'].filter((word) =>
          transcript.includes(word),
        );
        assert(
          matched.length >= 3,
          `Generated speech intelligibility (${model.id}/${voice}): ${transcript}`,
        );
        console.log(
          `${model.id} ${voice}: ${(audio.length / sampling_rate).toFixed(2)}s audio, RMS ${rms.toFixed(4)}, recognized: ${transcript}`,
        );
      }
    } finally {
      await runtime.dispose();
    }
    await assert.rejects(runtime.generate('Already unloaded'), /unloaded/);
    await runtime.dispose();
    console.log(
      `${model.id}: ${((performance.now() - start) / 1000).toFixed(2)}s load and two generations`,
    );
  }
} finally {
  await recognizer.dispose();
}
console.log('SUPERTONIC_REAL_OK');

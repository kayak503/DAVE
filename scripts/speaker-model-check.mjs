import assert from 'node:assert/strict';
import path from 'node:path';
import { readFile, mkdir, copyFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import sherpa from 'sherpa-onnx-node';
import { LocalDiarization } from '../macos/backend/diarization.mjs';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const models = path.join(root, '.cache/speaker-quality');
const accurate = new LocalDiarization(models, { modelID: 'accurate' });
if (process.argv.includes('--prepare')) {
  await mkdir(accurate.directory, { recursive: true });
  await copyFile(path.join(root, '.cache/models/speaker-diarization/segmentation.onnx'), path.join(accurate.directory, 'segmentation.onnx'));
  await copyFile(path.join(models, 'resnet152.onnx'), path.join(accurate.directory, 'embedding.onnx'));
}
const precision = new LocalDiarization(models, { modelID: 'precision' });
if (process.argv.includes('--prepare')) {
  await mkdir(precision.directory, { recursive: true });
  await copyFile(path.join(accurate.directory, 'segmentation.onnx'), path.join(precision.directory, 'segmentation.onnx'));
  await copyFile(path.join(models, 'resnet293.onnx'), path.join(precision.directory, 'embedding.onnx'));
}
if (process.argv.includes('--install-precision')) await precision.install();
const originalFetch = globalThis.fetch;
globalThis.fetch = () => { throw new Error('Speaker inference attempted network access.'); };
try {
  const names = ['speaker1-a', 'speaker1-b', 'speaker2-a'];
  const hashes = ['cb35bff3dac9aec36e259461fecae1e1bc2ec029615f30713111cd598993676c', 'd7daff767e13d9a2187b676d958065121cd5e26da046d65cd9604e91a87525a2', 'a723c134978a17fe12ca2374d0281a8003a56fa44ff9d2249a08791714983362'];
  const waves = [];
  for (let i = 0; i < names.length; i++) {
    const file = path.join(root, '.cache/transcription-fixtures', `${names[i]}.wav`);
    assert.equal(createHash('sha256').update(await readFile(file)).digest('hex'), hashes[i]);
    const wave = sherpa.readWave(file); assert.equal(wave.sampleRate, 16000); waves.push(wave.samples);
  }
  for (const service of [new LocalDiarization(path.join(root, '.cache/models')), accurate, precision]) {
    assert(await service.installed(), `Install ${service.modelID} in the test cache first.`);
    const begin = performance.now();
    const vectors = [];
    for (const wave of waves) vectors.push(await service.embeddingFor(wave));
    assert(vectors.every(v => v?.length === 256 && v.every(Number.isFinite)));
    const dot = (a, b) => a.reduce((sum, x, i) => sum + x * b[i], 0);
    const same = dot(vectors[0], vectors[1]), different = dot(vectors[0], vectors[2]);
    assert(same > service.model.matchThreshold && different < service.model.matchThreshold, `${service.modelID}: calibrated identity threshold must separate fixture speakers`);
    assert(same > different + 0.2, `${service.modelID}: same voice must match more closely than different voices`);
    assert.equal(await service.embeddingFor(new Float32Array(24000)), undefined);
    const labels = [];
    for (const i of [0, 2, 1]) labels.push([...new Set((await service.process(waves[i], 'real-repeat', 2)).map(t => t.speaker))]);
    assert.deepEqual(labels, [['Speaker 1'], ['Speaker 2'], ['Speaker 1']]);
    const mix = new Float32Array(waves[0].length + 16000 + waves[2].length); mix.set(waves[0]); mix.set(waves[2], waves[0].length + 16000);
    for (const count of [0, 2]) {
      const turns = await service.process(mix, `real-two-${count}`, count);
      assert.equal(new Set(turns.map(t => t.speaker).filter(Boolean)).size, 2, `${service.modelID}: mixed timeline with speaker count ${count}`);
    }
    console.log(JSON.stringify({ model: service.modelID, sameVoiceCosine: same, differentVoiceCosine: different, elapsedMS: Math.round(performance.now() - begin), embeddingDimension: 256, repeatedSpeakerLabels: labels }));
  }
  console.log('SPEAKER_MODELS_REAL_OK');
} finally { globalThis.fetch = originalFetch; }

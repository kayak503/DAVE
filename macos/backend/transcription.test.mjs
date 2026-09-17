import test from 'node:test';
import path from 'node:path';
import assert from 'node:assert/strict';
import { SpeakerClusters, speakerRegions, captionSegments, validatePCM, validateJobID } from './transcription.mjs';
import { LocalDiarization } from './diarization.mjs';

test('similar but locally distinct speakers retain separate identities in a chunk', () => {
  const speakers = new SpeakerClusters(2);
  const a = [1, 0], b = [0.8, 0.6]; // Cosine 0.8: formerly both assigned Speaker 1.
  assert.deepEqual(speakers.assignBatch([a, b]), ['Speaker 1', 'Speaker 2']);
  assert.deepEqual(speakers.assignBatch([b, a]), ['Speaker 2', 'Speaker 1']);
  assert.equal(speakers.assign(a), 'Speaker 1');
  assert.equal(speakers.assign(b), 'Speaker 2');
  assert.equal(speakers.centroids.length, 2);
});

test('strongest match claims existing identity before a less certain new voice', () => {
  const speakers = new SpeakerClusters();
  assert.equal(speakers.assign([1, 0]), 'Speaker 1');
  assert.deepEqual(speakers.assignBatch([[0.8, 0.6], [1, 0]]), ['Speaker 2', 'Speaker 1']);
});

test('speaker cap, empty batches, and invalid embeddings do not corrupt identities', () => {
  const speakers = new SpeakerClusters(2);
  assert.deepEqual(speakers.assignBatch([]), []);
  assert.deepEqual(speakers.assignBatch([[1, 0], [0, 1], [0.01, 0.99]]), ['Speaker 1', 'Speaker 2', 'Speaker 2']);
  const before = JSON.stringify(speakers.centroids);
  for (const vectors of [[[0, 0]], [[NaN, 1]], [[1, 0, 0]], [[1, 0], [0, 0]]]) {
    assert.throws(() => speakers.assignBatch(vectors), /embedding/);
    assert.equal(JSON.stringify(speakers.centroids), before);
  }
  assert.throws(() => new SpeakerClusters(0));
  assert.throws(() => new SpeakerClusters(33));
  assert.throws(() => new SpeakerClusters(2, NaN));
  assert.deepEqual(new SpeakerClusters(1).assignBatch([[1, 0], [0, 1]]), ['Speaker 1', 'Speaker 1']);
  assert.deepEqual(new SpeakerClusters(1).assignBatch([[1, 0], [-1, 0]]), ['Speaker 1', 'Speaker 1']);
});

test('diarization passes distinct local voices together and retains names across chunks', async () => {
  const service = new LocalDiarization('/unused-model-directory');
  let reverse = false;
  service.runtime = { process: () => [
    { start: 0, end: 1, speaker: reverse ? 8 : 4 },
    { start: 1, end: 2, speaker: reverse ? 4 : 8 },
  ] };
  service.extractor = {
    createStream: () => ({ acceptWaveform({ samples }) { this.samples = samples; } }),
    isReady: () => true,
    compute: stream => stream.samples[0] > 0.5 ? [1, 0] : [0.8, 0.6],
  };
  const audio = new Float32Array(32000); audio.fill(0.9, 0, 16000); audio.fill(0.2, 16000);
  assert.deepEqual((await service.process(audio, 'job', 2)).map(t => t.speaker), ['Speaker 1', 'Speaker 2']);
  reverse = true; audio.fill(0.2, 0, 16000); audio.fill(0.9, 16000);
  assert.deepEqual((await service.process(audio, 'job', 2)).map(t => t.speaker), ['Speaker 2', 'Speaker 1']);
  await assert.rejects(service.process(audio, 'job', 3), /settings changed/);
  service.reset('job'); assert.equal(service.jobs.size, 0);
  assert.deepEqual((await service.process(audio, 'new-job', 2)).map(t => t.speaker), ['Speaker 1', 'Speaker 2']);
});

test('brief and unvoiced regions remain unlabeled, overlaps remain explicit', async () => {
  const service = new LocalDiarization('/unused-model-directory');
  service.runtime = { process: () => [{ start: 0, end: 0.2, speaker: 7 }] };
  service.extractor = { createStream() { throw new Error('Brief speech should not be embedded'); } };
  assert.deepEqual(await service.process(new Float32Array(16000), 'short'), [{ start: 0, end: 0.2 }]);
  assert.deepEqual(speakerRegions([
    { start: 1, end: 3, speaker: 'Speaker 1' }, { start: 2, end: 4, speaker: 'Speaker 2' },
  ], 5), [
    { start: 0, end: 1 }, { start: 1, end: 2, speaker: 'Speaker 1' },
    { start: 2, end: 3, speaker: 'Speaker 1 + Speaker 2' },
    { start: 3, end: 4, speaker: 'Speaker 2' }, { start: 4, end: 5 },
  ]);
});

test('caption boundaries preserve speaker changes and bounded timestamps', () => {
  assert.deepEqual(captionSegments({ chunks: [
    { text: 'hello', timestamp: [-1, 1] }, { text: 'there', timestamp: [1, 2] },
  ] }, 2, [{ start: 0, end: 1, speaker: 'Speaker 1' }, { start: 1, end: 2, speaker: 'Speaker 2' }]), [
    { start: 0, end: 1, text: 'hello', speaker: 'Speaker 1' },
    { start: 1, end: 2, text: 'there', speaker: 'Speaker 2' },
  ]);
  assert.throws(() => validatePCM(new Float32Array([NaN])));
  assert.throws(() => validateJobID('../private'));
});

test('speaker packs are independently addressed and never accept arbitrary paths', async () => {
  const compact = new LocalDiarization('/models');
  const larger = new LocalDiarization('/models', { modelID: 'accurate' });
  const precision = new LocalDiarization('/models', { modelID: 'precision' });
  assert.equal(precision.directory, path.join('/models', 'speaker-diarization-precision'));
  assert(precision.model.sizeMB > larger.model.sizeMB);
  assert(precision.model.matchThreshold > larger.model.matchThreshold);
  assert.equal(compact.directory, path.join('/models', 'speaker-diarization'));
  assert.equal(larger.directory, path.join('/models', 'speaker-diarization-accurate'));
  assert(larger.model.sizeMB > compact.model.sizeMB * 2);
  assert.throws(() => new LocalDiarization('/models', { modelID: '../escape' }), /Unknown speaker model/);
  for (const service of [compact, larger, precision]) {
    assert.equal(service.model.sizeMB, service.assets.reduce((sum, asset) => sum + asset.size, 0) / 1e6);
    assert(service.model.matchThreshold > 0 && service.model.matchThreshold < 1);
    assert(service.model.clusteringThreshold > 0 && service.model.clusteringThreshold < 1);
    for (const asset of service.assets) {
      assert.match(asset.sha256, /^[a-f0-9]{64}$/); assert(asset.size > 0); assert(asset.url.startsWith('https://'));
    }
  }
});

test('correction embeddings are bounded, normalized and exclude too-short or silent audio', async () => {
  const service = new LocalDiarization('/unused');
  let lengths = [];
  service.runtime = {};
  service.extractor = {
    createStream: () => ({ acceptWaveform({ samples }) { lengths.push(samples.length); } }),
    isReady: () => true, compute: () => [3, 4],
  };
  assert.equal(await service.embeddingFor(new Float32Array(23999).fill(0.2)), undefined);
  assert.equal(await service.embeddingFor(new Float32Array(32000)), undefined);
  assert.deepEqual(lengths, []);
  assert.deepEqual(await service.embeddingFor(new Float32Array(32000).fill(0.2)), [0.6, 0.8]);
  await service.embeddingFor(new Float32Array(320000).fill(0.2));
  assert.deepEqual(lengths, [32000, 192000]);
  service.extractor.compute = () => [NaN, 1];
  assert.equal(await service.embeddingFor(new Float32Array(32000).fill(0.2)), undefined);
});

test('speaker reference intervals remove overlap, including speaker zero', async () => {
  const { cleanSpeakerTurns } = await import('./transcription.mjs');
  const turns = [{ start: 0, end: 5, speaker: 0 }, { start: 2, end: 3, speaker: 1 }];
  assert.deepEqual(cleanSpeakerTurns(turns, 0), [{ start: 0, end: 2, speaker: 0 }, { start: 3, end: 5, speaker: 0 }]);
  assert.deepEqual(cleanSpeakerTurns(turns, 1), []);
});

test('overlapping voices never contaminate the embeddings used to assign identities', async () => {
  const service = new LocalDiarization('/unused');
  service.runtime = { process: () => [{ start: 0, end: 3, speaker: 0 }, { start: 1, end: 2, speaker: 1 }] };
  const accepted = [];
  service.extractor = {
    createStream: () => ({ acceptWaveform({ samples }) { accepted.push(samples); } }),
    isReady: () => true, compute: () => [1, 0],
  };
  const audio = new Float32Array(48000).fill(0.2); audio.fill(0.9, 16000, 32000);
  const turns = await service.process(audio, 'overlap');
  assert.equal(accepted.length, 1); assert.equal(accepted[0].length, 32000);
  assert(accepted[0].every(x => x < 0.3));
  assert.equal(turns[0].speaker, 'Speaker 1'); assert.equal(turns[1].speaker, undefined);
});

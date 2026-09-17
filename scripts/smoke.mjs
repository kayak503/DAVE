import assert from 'node:assert/strict';
import path from 'node:path';
import { mkdir, writeFile } from 'node:fs/promises';
import { performance } from 'node:perf_hooks';
import { SpeechEngine } from '../core/engine.mjs';
import { resampleAudio } from '../core/audio.mjs';
const modelDir = path.resolve(process.env.LOCALVOICE_MODEL_DIR || '.cache/models');
let attempts = 0;
const originalFetch = globalThis.fetch;
globalThis.fetch = async () => {
  attempts++;
  throw new Error('Network is forbidden in offline speech verification.');
};
// Positive control proves our network guard really rejects a attempted request.
await assert.rejects(() => fetch('https://example.invalid'), /forbidden/);
assert.equal(attempts, 1);
attempts = 0;
const engine = new SpeechEngine({ modelDir });
const source = 'The garden is quiet today. Please bring three blue notebooks to the kitchen.';
try {
  const installed = await engine.listModels();
  for (const id of ['kokoro-q8', 'whisper-tiny'])
    assert.ok(
      installed.find((m) => m.id === id)?.installed,
      `${id} must first be installed with npm run models:smoke`,
    );
  const started = performance.now();
  const result = await engine.synthesize({
    modelId: 'kokoro-q8',
    text: source,
    voice: 'af_heart',
    speed: 1,
    device: 'cpu',
  });
  const synthMs = Math.round(performance.now() - started);
  assert.equal(result.sampleRate, 24000);
  assert.ok(result.audio.length > 24000 && result.audio.length < 24000 * 30);
  assert.ok(result.audio.every(Number.isFinite));
  assert.ok(
    result.audio.some((v) => Math.abs(v) > 0.02),
    'Generated audio must be non-silent',
  );
  const audio = resampleAudio(result.audio, result.sampleRate);
  const transcriptionStarted = performance.now();
  const transcript = await engine.transcribe({
    modelId: 'whisper-tiny',
    audio,
    sampleRate: 16000,
    device: 'cpu',
  });
  const sttMs = Math.round(performance.now() - transcriptionStarted);
  assert.match(transcript.text.toLowerCase(), /garden/);
  assert.match(transcript.text.toLowerCase(), /notebooks/);
  assert.match(transcript.text.toLowerCase(), /kitchen/);
  assert.equal(
    (
      await engine.transcribe({
        modelId: 'whisper-tiny',
        audio: new Float32Array(16000),
        sampleRate: 16000,
      })
    ).text,
    '',
  );
  let rewriteSuggestion = null;
  if (installed.find((m) => m.id === 'flan-t5-small')?.installed) {
    rewriteSuggestion = (
      await engine.rewrite({
        modelId: 'flan-t5-small',
        text: 'The garden is quiet today. Please bring three blue notebooks to the kitchen.',
      })
    ).text;
    assert.ok(rewriteSuggestion.length > 0);
  }
  assert.equal(attempts, 0, 'No inference request may attempt a network fetch');
  const metrics = {
    platform: process.platform,
    arch: process.arch,
    ttsModel: 'kokoro-q8',
    sttModel: 'whisper-tiny',
    source,
    transcript: transcript.text,
    audioSeconds: result.audio.length / result.sampleRate,
    coldSynthesisMs: synthMs,
    coldTranscriptionMs: sttMs,
    networkAttempts: attempts,
    rewriteSuggestion,
  };
  await mkdir('test-results', { recursive: true });
  await writeFile('test-results/speech-smoke.json', JSON.stringify(metrics, null, 2));
  // WAV artifact contains only the fixed public test sentence, never user content.
  const wav = Buffer.alloc(44 + result.audio.length * 2);
  wav.write('RIFF');
  wav.writeUInt32LE(wav.length - 8, 4);
  wav.write('WAVEfmt ', 8);
  wav.writeUInt32LE(16, 16);
  wav.writeUInt16LE(1, 20);
  wav.writeUInt16LE(1, 22);
  wav.writeUInt32LE(result.sampleRate, 24);
  wav.writeUInt32LE(result.sampleRate * 2, 28);
  wav.writeUInt16LE(2, 32);
  wav.writeUInt16LE(16, 34);
  wav.write('data', 36);
  wav.writeUInt32LE(result.audio.length * 2, 40);
  result.audio.forEach((value, i) =>
    wav.writeInt16LE(Math.round(Math.max(-1, Math.min(1, value)) * 32767), 44 + i * 2),
  );
  await writeFile('test-results/speech-smoke.wav', wav);
  console.log(JSON.stringify(metrics));
  console.log('LOCALVOICE_OFFLINE_SPEECH_OK');
} finally {
  await engine.dispose();
  globalThis.fetch = originalFetch;
}

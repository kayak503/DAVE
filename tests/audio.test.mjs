import test from 'node:test';
import assert from 'node:assert/strict';
import { resampleAudio } from '../core/audio.mjs';

const rms = (samples) =>
  Math.sqrt(samples.reduce((sum, value) => sum + value * value, 0) / samples.length);
const tone = (hz, rate, seconds = 0.1) =>
  Float32Array.from({ length: rate * seconds }, (_, i) => Math.sin((2 * Math.PI * hz * i) / rate));

test('resampling preserves duration, DC, low speech frequencies and filters aliases', () => {
  const dc = resampleAudio(new Float32Array(4800).fill(0.25), 48000);
  assert.equal(dc.length, 1600);
  assert.ok(dc.every((value) => Math.abs(value - 0.25) < 1e-6));
  const speech = resampleAudio(tone(1000, 48000), 48000).slice(100, -100);
  const rejected = resampleAudio(tone(12000, 48000), 48000).slice(100, -100);
  assert.ok(rms(speech) > 0.69 && rms(speech) < 0.72);
  assert.ok(rms(rejected) < 0.005);
  const fractional = resampleAudio(tone(400, 44100), 44100);
  assert.equal(fractional.length, 1600);
  assert.ok(rms(fractional) > 0.69);
  const upsampled = resampleAudio(new Float32Array(800).fill(0.4), 8000, 16000);
  assert.equal(upsampled.length, 1600);
  assert.ok(upsampled.every((value) => Math.abs(value - 0.4) < 1e-6));
});

test('audio edge cases are explicit', () => {
  const input = new Float32Array([0, 0.5, -0.5]);
  assert.deepEqual(resampleAudio(input, 16000), input);
  assert.notEqual(resampleAudio(input, 16000), input);
  assert.equal(resampleAudio(new Float32Array(), 44100).length, 0);
  assert.throws(() => resampleAudio(input, 0), /sample rate/);
  assert.throws(() => resampleAudio(new Float32Array([NaN]), 48000), /invalid/);
});

test('very short buffers and fractional rate changes remain finite without mutating input', () => {
  const input = new Float32Array([0.75]);
  assert.equal(resampleAudio(input, 48000).length, 0);
  const up = resampleAudio(input, 8000);
  assert.deepEqual(up, new Float32Array([0.75, 0.75]));
  assert.deepEqual(input, new Float32Array([0.75]));
  const output = resampleAudio(tone(1000, 16000), 16000, 44100);
  assert.equal(output.length, 4410);
  assert.ok(output.every(Number.isFinite));
  assert.ok(rms(output) > 0.69 && rms(output) < 0.72);
});

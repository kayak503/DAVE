import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import {
  speechChunks,
  encodeText,
  createSupertonic,
  supertonicVoices,
} from '../core/supertonic.mjs';

test('chunking bounds very long sentences and preserves their content', () => {
  const text = ('a'.repeat(501) + ' a short sentence. ').repeat(3).trim();
  const chunks = speechChunks(text);
  assert(chunks.every((c) => c.length <= 300));
  assert.equal(chunks.join('').replaceAll(' ', ''), text.replaceAll(' ', ''));
  assert.throws(() => speechChunks(' '), /Enter/);
  assert.throws(() => speechChunks('a'.repeat(20001)), /20,000/);
  assert.throws(() => speechChunks('valid text', 0), /limit/);
});
test('normalizer adds language tokens and safely removes unsupported code points', () => {
  const indexer = Array.from({ length: 128 }, (_, i) => i);
  const decode = (value) => String.fromCodePoint(...Array.from(value, Number));
  assert.equal(decode(encodeText('Hello — world! 😃', indexer)), '<en>Hello - world!</en>');
  assert.equal(decode(encodeText('john@example.com', indexer)), '<en>john at example.com.</en>');
  assert.throws(() => encodeText('😃', indexer), /no supported/);
  assert.throws(() => encodeText('hello', []), /no supported/);
  assert.equal(decode(encodeText('café', indexer)), '<en>cafe.</en>');
});
test('catalog contains distinct pinned local networks and ten verified voice styles each', async () => {
  const models = JSON.parse(
    await readFile(new URL('../core/supertonic-catalog.json', import.meta.url)),
  );
  assert.deepEqual(
    models.map((m) => m.id),
    ['supertonic-2', 'supertonic-3'],
  );
  assert.notEqual(
    models[0].files.find((f) => f.path === 'onnx/vector_estimator.onnx').hash,
    models[1].files.find((f) => f.path === 'onnx/vector_estimator.onnx').hash,
  );
  for (const model of models) {
    assert.match(model.revision, /^[a-f0-9]{40}$/);
    assert.equal(model.engine, 'supertonic');
    assert.deepEqual(model.devices, ['cpu']);
    assert.deepEqual(
      model.voices.map((v) => v.id),
      [...supertonicVoices],
    );
    for (const voice of supertonicVoices)
      assert(model.files.some((f) => f.path === `voice_styles/${voice}.json`));
    assert.equal(model.files.filter((f) => f.path.endsWith('.onnx')).length, 4);
    for (const file of model.files) {
      assert(file.size > 0);
      assert.match(file.hash, file.algorithm === 'sha256' ? /^[a-f0-9]{64}$/ : /^[a-f0-9]{40}$/);
    }
  }
});
test('local loader rejects remote directories and unknown IDs before opening any sessions', async () => {
  await assert.rejects(
    createSupertonic('https://example.com', { id: 'supertonic-2' }),
    /Invalid local/,
  );
  await assert.rejects(createSupertonic('/tmp', { id: 'unknown' }), /Invalid local/);
  await assert.rejects(
    createSupertonic('/tmp/does-not-exist-supertonic', { id: 'supertonic-3' }),
    /ENOENT/,
  );
});

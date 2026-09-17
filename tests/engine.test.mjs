import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, mkdir, rm, symlink, utimes } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { SpeechEngine, catalog, verifyFile } from '../core/engine.mjs';

async function fixture(t) {
  const dir = await mkdtemp(path.join(tmpdir(), 'hearth-engine-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  return { dir, engine: new SpeechEngine({ modelDir: path.join(dir, 'models') }) };
}
test('catalog pins curated offline models and complete voice assets', () => {
  assert.ok(catalog.length >= 8);
  for (const m of catalog) {
    assert.match(m.revision, /^[a-f0-9]{40}$/);
    assert.deepEqual(m.devices, m.engine === 'whisper-metal' ? ['cpu', 'gpu'] : ['cpu']);
    assert.ok(m.files.some((f) => f.path.endsWith(m.engine === 'whisper-metal' ? '.bin' : '.onnx')));
    for (const f of m.files) {
      assert.ok(!f.path.includes('..') && !path.isAbsolute(f.path));
      assert.match(f.hash, f.algorithm === 'sha256' ? /^[a-f0-9]{64}$/ : /^[a-f0-9]{40}$/);
    }
    for (const v of m.voices ?? []) assert.ok(m.files.some((f) => f.path === (m.engine === "supertonic" ? `voice_styles/${v.id}.json` : `voices/${v.id}.bin`)));
  }
});
test('hash verification rejects same-size corruption and symbolic files', async (t) => {
  const { dir } = await fixture(t);
  const file = path.join(dir, 'asset');
  await writeFile(file, 'correct');
  const asset = {
    path: 'asset',
    size: 7,
    algorithm: 'sha256',
    hash: createHash('sha256').update('correct').digest('hex'),
  };
  await verifyFile(file, asset);
  await writeFile(file, 'corrupt');
  await assert.rejects(verifyFile(file, asset), /Integrity/);
  await writeFile(file, 'correct');
  await symlink(file, path.join(dir, 'link'));
  await assert.rejects(verifyFile(path.join(dir, 'link'), asset), /type/);
  await verifyFile(file, {
    ...asset,
    algorithm: 'git-sha1',
    hash: createHash('sha1').update('blob 7\0correct').digest('hex'),
  });
});
test('listing, missing inference, and invalid imports perform no network access', async (t) => {
  const { engine, dir } = await fixture(t);
  const original = globalThis.fetch;
  globalThis.fetch = () => {
    throw new Error('Unexpected network request');
  };
  t.after(() => {
    globalThis.fetch = original;
  });
  assert.ok((await engine.listModels()).every((m) => !m.installed));
  await assert.rejects(
    engine.synthesize({ modelId: 'kokoro-q8', text: 'Hello.' }),
    /Install or import/,
  );
  await assert.rejects(engine.importModel('kokoro-q8', dir), /ENOENT/);
  assert.ok((await engine.listModels()).every((m) => !m.installed));
});
test('unknown model IDs cannot traverse or delete storage', async (t) => {
  const { engine, dir } = await fixture(t);
  await writeFile(path.join(dir, 'keep'), 'safe');
  for (const id of ['../keep', '/tmp', 'other'])
    await assert.rejects(engine.removeModel(id), /Unknown/);
});
test('input validation rejects unsafe, oversized, or unsupported inference', async (t) => {
  const { engine } = await fixture(t);
  await assert.rejects(engine.synthesize({ modelId: 'kokoro-q8', text: '' }), /nonempty/);
  await assert.rejects(
    engine.synthesize({ modelId: 'kokoro-q8', text: 'Hi', voice: '../bad' }),
    /voice/,
  );
  await assert.rejects(
    engine.synthesize({ modelId: 'kokoro-q8', text: 'Hi', speed: NaN }),
    /speed/,
  );
  await assert.rejects(
    engine.synthesize({ modelId: 'kokoro-q8', text: 'Hi', device: 'webgpu' }),
    /CPU/,
  );
  await assert.rejects(
    engine.transcribe({
      modelId: 'whisper-tiny',
      audio: new Float32Array([NaN]),
      sampleRate: 16000,
    }),
    /Float32/,
  );
  await assert.rejects(
    engine.transcribe({ modelId: 'whisper-tiny', audio: new Float32Array([0]), sampleRate: 48000 }),
    /16 kHz/,
  );
  await assert.rejects(
    engine.rewrite({ modelId: 'flan-t5-small', text: 'x'.repeat(1501) }),
    /1500/,
  );
});
test('failed explicit download leaves no installed model and cleans staging', async (t) => {
  const { engine } = await fixture(t);
  const original = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async (url) => {
    calls++;
    assert.match(url, /resolve\/[a-f0-9]{40}\//);
    return new Response('bad', { status: 503 });
  };
  t.after(() => {
    globalThis.fetch = original;
  });
  await assert.rejects(engine.installModel('kokoro-q8'), /503/);
  assert.equal(calls, 1);
  const { readdir } = await import('node:fs/promises');
  assert.deepEqual(await readdir(engine.modelDir), []);
});
test('cancellation aborts explicit download and removes partial state', async (t) => {
  const { engine } = await fixture(t);
  const original = globalThis.fetch;
  globalThis.fetch = async (_, { signal }) => {
    engine.cancel();
    signal.throwIfAborted();
  };
  t.after(() => {
    globalThis.fetch = original;
  });
  await assert.rejects(engine.installModel('whisper-tiny'), /abort/i);
  assert.equal(engine.controller, null);
  assert.ok((await engine.listModels()).every((m) => !m.installed));
});
test('verified import commits atomically; corrupt replacement preserves installed content; delete removes only model', async (t) => {
  const { engine, dir } = await fixture(t);
  const bytes = Buffer.from('test weight bytes');
  const model = {
    id: 'test-fixture',
    name: 'fixture',
    revision: 'a'.repeat(40),
    files: [
      {
        path: 'onnx/model.onnx',
        size: bytes.length,
        algorithm: 'sha256',
        hash: createHash('sha256').update(bytes).digest('hex'),
      },
    ],
  };
  catalog.push(model);
  t.after(() => {
    catalog.splice(catalog.indexOf(model), 1);
  });
  const source = path.join(dir, 'source');
  await mkdir(path.join(source, 'onnx'), { recursive: true });
  await writeFile(path.join(source, 'onnx/model.onnx'), bytes);
  await engine.importModel(model.id, source);
  assert.equal(await engine.installed(model), true);
  await writeFile(path.join(source, 'onnx/model.onnx'), Buffer.alloc(bytes.length));
  await assert.rejects(engine.importModel(model.id, source), /Integrity/);
  await verifyFile(path.join(engine.directory(model.id), 'onnx/model.onnx'), model.files[0]);
  await engine.removeModel(model.id);
  assert.equal(await engine.installed(model), false);
  const { stat } = await import('node:fs/promises');
  assert.ok((await stat(source)).isDirectory());
});
test('failed replacement rename restores the previous installation', async (t) => {
  const { dir } = await fixture(t);
  const { replaceDirectory } = await import('../core/engine.mjs');
  const { rename, readFile } = await import('node:fs/promises');
  const old = path.join(dir, 'old'),
    temp = path.join(dir, 'temp'),
    backup = path.join(dir, 'backup');
  await mkdir(old);
  await mkdir(temp);
  await writeFile(path.join(old, 'version'), 'previous');
  await writeFile(path.join(temp, 'version'), 'replacement');
  await assert.rejects(
    replaceDirectory(temp, old, backup, async (source, destination) => {
      if (source === temp) throw new Error('Injected rename failure');
      await rename(source, destination);
    }),
    /Injected/,
  );
  assert.equal(await readFile(path.join(old, 'version'), 'utf8'), 'previous');
  await replaceDirectory(temp, old, backup);
  assert.equal(await readFile(path.join(old, 'version'), 'utf8'), 'replacement');
});
test('startup restores interrupted backup and deletes only owned real partial directories', async (t) => {
  const { engine, dir } = await fixture(t);
  const { readdir, readFile } = await import('node:fs/promises');
  await mkdir(engine.modelDir);
  const backup = path.join(engine.modelDir, '.kokoro-q8.backup');
  await mkdir(backup);
  await writeFile(path.join(backup, 'preserved'), 'old bytes');
  const partial = '.kokoro-q8-12345678-1234-1234-1234-123456789abc.partial';
  const unknown = '.unknown-12345678-1234-1234-1234-123456789abc.partial';
  const linked = '.kokoro-q8-22222222-1234-1234-1234-123456789abc.partial';
  await mkdir(path.join(engine.modelDir, partial));
  await utimes(path.join(engine.modelDir, partial), new Date(0), new Date(0));
  await mkdir(path.join(engine.modelDir, unknown));
  const external = path.join(dir, 'external');
  await mkdir(external);
  await writeFile(path.join(external, 'keep'), 'safe');
  await symlink(external, path.join(engine.modelDir, linked), 'dir');
  await engine.listModels();
  assert.equal(
    await readFile(path.join(engine.modelDir, 'kokoro-q8', 'preserved'), 'utf8'),
    'old bytes',
  );
  const names = await readdir(engine.modelDir);
  assert.ok(!names.includes(partial));
  assert.ok(names.includes(unknown));
  assert.ok(names.includes(linked));
  assert.equal(await readFile(path.join(external, 'keep'), 'utf8'), 'safe');
});
test('recovery preserves verified new installs and rolls corrupt new installs back to verified backup', async (t) => {
  const { dir } = await fixture(t);
  const { rename, readFile, readdir } = await import('node:fs/promises');
  const bytes = Buffer.from('verified');
  const model = {
    id: 'recovery-fixture',
    revision: 'b'.repeat(40),
    files: [
      {
        path: 'asset',
        size: bytes.length,
        algorithm: 'sha256',
        hash: createHash('sha256').update(bytes).digest('hex'),
      },
    ],
  };
  catalog.push(model);
  t.after(() => catalog.splice(catalog.indexOf(model), 1));
  for (const corrupt of [false, true]) {
    const modelDir = path.join(dir, String(corrupt));
    await mkdir(modelDir);
    const destination = path.join(modelDir, model.id),
      backup = path.join(modelDir, `.${model.id}.backup`);
    await mkdir(destination);
    await mkdir(backup);
    await writeFile(path.join(destination, 'asset'), corrupt ? Buffer.alloc(bytes.length) : bytes);
    await writeFile(path.join(backup, 'asset'), bytes);
    await new SpeechEngine({ modelDir }).recover();
    assert.equal(await readFile(path.join(destination, 'asset'), 'utf8'), 'verified');
    assert.deepEqual(await readdir(modelDir), [model.id]);
  }
});


test('another service never removes an active download while listing models', async t => {
  const {engine}=await fixture(t);
  await mkdir(engine.modelDir,{recursive:true});
  const partial=path.join(engine.modelDir,'.whisper-medium-11111111-1234-1234-1234-123456789abc.partial');
  await mkdir(partial);
  await writeFile(path.join(partial,'.owner.json'),JSON.stringify({pid:process.pid}));
  await utimes(partial,new Date(0),new Date(0));
  await new SpeechEngine({modelDir:engine.modelDir}).listModels();
  assert.equal(JSON.parse(await (await import('node:fs/promises')).readFile(path.join(partial,'.owner.json'))).pid,process.pid);
});

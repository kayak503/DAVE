import { mkdir, readFile, access, writeFile, mkdtemp, rename } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const cache = resolve(root, '.cache/metal-build');
const revision = '2eeeba56e9edd762b4b38467bab96c2517163158';
const run = (cmd, args) => { const r = spawnSync(cmd, args, { stdio: 'inherit' }); if (r.status !== 0) throw Error(`${cmd} failed: ${r.status}`); };
async function download(name, url, sha) {
  const path = resolve(cache, name);
  try { await access(path); } catch { run('curl', ['--fail', '--location', '--retry', '3', url, '-o', path]); }
  if (createHash('sha256').update(await readFile(path)).digest('hex') !== sha) throw Error(`Hash mismatch: ${path}`);
  return path;
}
if (process.platform !== 'darwin' || process.arch !== 'arm64') throw Error('Metal runtime build requires an Apple Silicon Mac.');
await mkdir(cache, { recursive: true });
const sourceArchive = await download('source.tar.gz', `https://codeload.github.com/ggml-org/whisper.cpp/tar.gz/${revision}`, '089b898aa83b24a8321e0fd554eeb0967fb03dd687e27f6374c72d3363b5b429');
const cmakeArchive = await download('cmake.tar.gz', 'https://github.com/Kitware/CMake/releases/download/v3.31.6/cmake-3.31.6-macos-universal.tar.gz', '330b9514f5112e5ed4fb08b8b05803b776fd9b539a6ae12927d14dcc0ee2ba8d');
// Never extract over an existing CMake.app: macOS can protect previously
// executed bundles against in-place replacement. Each extraction is immutable;
// the pointer is committed only after extraction and an actual version check.
const cmakeHash = '330b9514f5112e5ed4fb08b8b05803b776fd9b539a6ae12927d14dcc0ee2ba8d';
const cmakeRelative = 'cmake-3.31.6-macos-universal/CMake.app/Contents/bin/cmake';
const pointer = resolve(cache, 'cmake-unpacked.json');
const validatesCmake = (binary) => {
  const result = spawnSync(binary, ['--version'], { encoding: 'utf8', timeout: 30000 });
  return result.status === 0 && /^cmake version 3\.31\.6(?:\r?\n|$)/.test(result.stdout);
};
let cmake;
try {
  const saved = JSON.parse(await readFile(pointer, 'utf8'));
  if (saved.sha256 === cmakeHash && /^unpacked-cmake-[A-Za-z0-9]+$/.test(saved.directory)) {
    const candidate = resolve(cache, saved.directory, cmakeRelative);
    if (validatesCmake(candidate)) cmake = candidate;
  }
} catch { /* A missing or incomplete extraction is replaced in a fresh directory. */ }
if (!cmake) {
  const stage = await mkdtemp(resolve(cache, 'unpacked-cmake-'));
  run('tar', ['-xzf', cmakeArchive, '-C', stage]);
  const candidate = resolve(stage, cmakeRelative);
  if (!validatesCmake(candidate)) throw Error('Extracted CMake did not pass its version check.');
  const stagedPointer = `${stage}.json`;
  await writeFile(stagedPointer, JSON.stringify({ sha256: cmakeHash, directory: stage.slice(cache.length + 1) }));
  await rename(stagedPointer, pointer);
  cmake = candidate;
}
run('tar', ['-xzf', sourceArchive, '-C', cache]);
const source = resolve(cache, `whisper.cpp-${revision}`);
const build = resolve(cache, 'build');
run(cmake, ['-S', source, '-B', build, '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0', '-DBUILD_SHARED_LIBS=OFF', '-DGGML_METAL=ON', '-DGGML_METAL_EMBED_LIBRARY=ON', '-DGGML_NATIVE=OFF', '-DWHISPER_BUILD_TESTS=OFF', '-DWHISPER_BUILD_EXAMPLES=ON', '-DWHISPER_CURL=OFF']);
run(cmake, ['--build', build, '--config', 'Release', '--target', 'whisper-cli', '-j', '8']);
const license = await readFile(resolve(source, 'LICENSE'), 'utf8');
await writeFile(resolve(root, 'macos/metal/LICENSE-whisper.txt'), license + '\nAdditional MIT-licensed components (same permission and warranty terms above):\nJSON for Modern C++: Copyright (c) 2013-2022 Niels Lohmann <https://nlohmann.me>\nMetal kernels: Copyright (c) 2023 Jeffrey Quesnelle and Bowen Peng.\n');
console.log(`METAL_BUILD_OK ${resolve(build, 'bin/whisper-cli')}`);

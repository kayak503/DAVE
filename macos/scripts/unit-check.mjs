import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const work = mkdtempSync(join(tmpdir(), 'localvoice-native-unit-'));
function run(command, args) {
  const result = spawnSync(command, args, { cwd: root, encoding: 'utf8', timeout: 120000 });
  if (result.stdout) process.stdout.write(result.stdout);
  if (result.stderr) process.stderr.write(result.stderr);
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command} exited ${result.status ?? result.signal}`);
}
try {
  const arch = process.arch === 'arm64' ? 'arm64' : 'x86_64';
  const binary = join(work, 'CoreTests');
  run('/usr/bin/xcrun', ['swiftc', '-swift-version', '5', '-target', `${arch}-apple-macosx14.0`, '-module-cache-path', join(work, 'modules'), '-o', binary,
    'macos/Sources/DocumentCore.swift', 'macos/Sources/Preferences.swift', 'macos/Tests/CoreTests.swift']);
  run(binary, []);
} finally { rmSync(work, { recursive: true, force: true }); }

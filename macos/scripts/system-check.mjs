import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../../', import.meta.url));
if (process.platform !== 'darwin') throw new Error('Native system tests require macOS and Command Line Tools.');
const temp = mkdtempSync(join(tmpdir(), 'localvoice-system-'));
function run(command, args) {
  const result = spawnSync(command, args, { cwd: root, encoding: 'utf8', timeout: 180000 });
  process.stdout.write(result.stdout || ''); process.stderr.write(result.stderr || '');
  if (result.error || result.status !== 0) throw result.error || new Error(`${command} exited ${result.status}`);
}
try {
  run('xcrun', ['swiftc', '-swift-version', '5', '-target', `${process.arch === 'arm64' ? 'arm64' : 'x86_64'}-apple-macos14.0`, '-module-cache-path', join(temp, 'modules'), 'macos/Sources/InteractionState.swift', 'macos/Sources/Preferences.swift', 'macos/Sources/MacSystem.swift', 'macos/Tests/SystemTests.swift', '-o', join(temp, 'system-tests')]);
  run(join(temp, 'system-tests'), []);
} finally { rmSync(temp, { recursive: true, force: true }); }

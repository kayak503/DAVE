import { spawnSync } from 'node:child_process';
import { access, rm, readFile } from 'node:fs/promises';
import path from 'node:path';
const {version}=JSON.parse(await readFile("package.json", "utf8"));
const app = path.resolve('release/native/Local Voice.app');
await access(app);
const output = path.resolve(`release/Local Voice-Native-${version}-${process.arch}.zip`);
await rm(output, { force: true });
for (const [command, args] of [
  ['codesign', ['--verify', '--deep', '--strict', app]],
  ['ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', app, output]],
]) {
  const result = spawnSync(command, args, { stdio: 'inherit' });
  if (result.status !== 0) throw new Error(`${command} failed: ${result.status}`);
}
console.log(`NATIVE_ARCHIVE_OK ${output}`);

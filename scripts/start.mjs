import { spawn } from 'node:child_process';
import { access } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../', import.meta.url));
const windows = process.platform === 'win32';
const app = fileURLToPath(new URL(windows ? '../release/windows/DAVE/DAVE.exe' : '../release/native/DAVE.app', import.meta.url));
try { await access(app); }
catch { throw new Error(`Build DAVE first: npm run ${windows ? 'build:windows' : 'build:native'}`); }
const child = spawn(windows ? app : 'open', windows ? [] : [app], { cwd: root, stdio: 'inherit' });
child.on('error', error => { console.error(error.message); process.exitCode = 1; });
child.on('exit', code => { process.exitCode = code ?? 1; });

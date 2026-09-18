import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const cwd = fileURLToPath(new URL('../', import.meta.url));
function run(binary, args) {
  const result = spawnSync(binary, args, { cwd, stdio: 'inherit' });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}
if (process.platform === 'win32') {
  const { dotnet, cache } = await import('../windows/scripts/toolchain.mjs');
  process.env.DOTNET_CLI_HOME ??= cache;
  const sdk = await dotnet();
  run(sdk, ['run', '--project', 'windows/Tests/DomainTests.csproj']);
  run(sdk, ['run', '--project', 'windows/UITests/UITests.csproj', '-c', 'Release']);
} else {
  for (const name of ['unit', 'system', 'interaction', 'transcription']) run(process.execPath, [`macos/scripts/${name}-check.mjs`]);
}

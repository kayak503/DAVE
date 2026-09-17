import sharp from 'sharp';
import { mkdir } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
if (process.platform === 'darwin') {
  await mkdir('.cache/LocalVoice.iconset', { recursive: true });
  for (const size of [16, 32, 128, 256, 512])
    for (const scale of [1, 2])
      await sharp('build/icon.svg')
        .resize(size * scale)
        .png()
        .toFile(`.cache/LocalVoice.iconset/icon_${size}x${size}${scale === 2 ? '@2x' : ''}.png`);
  const result = spawnSync(
    'iconutil',
    ['-c', 'icns', '.cache/LocalVoice.iconset', '-o', 'build/icon.icns'],
    { stdio: 'inherit' },
  );
  if (result.status !== 0) process.exit(result.status || 1);
}

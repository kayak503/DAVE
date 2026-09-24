import sharp from 'sharp';
import { mkdir, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
// Use the very same artwork as the Mac app for Windows taskbar, title bar and shortcuts.
if (process.platform === 'win32') {
  const sizes = [16, 32, 48, 64, 128, 256];
  const images = await Promise.all(sizes.map(size => sharp('build/icon.svg').resize(size).png().toBuffer()));
  const header = Buffer.alloc(6 + images.length * 16);
  header.writeUInt16LE(1, 2); header.writeUInt16LE(images.length, 4);
  let offset = header.length;
  images.forEach((png, i) => {
    const entry = 6 + i * 16;
    header[entry] = header[entry + 1] = sizes[i] === 256 ? 0 : sizes[i];
    header.writeUInt16LE(1, entry + 4); header.writeUInt16LE(32, entry + 6);
    header.writeUInt32LE(png.length, entry + 8); header.writeUInt32LE(offset, entry + 12);
    offset += png.length;
  });
  await writeFile('build/icon.ico', Buffer.concat([header, ...images]));
}
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

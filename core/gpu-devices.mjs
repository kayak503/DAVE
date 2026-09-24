import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
const execute = promisify(execFile);

export function parseNvidiaDevices(csv) {
  return csv.trim().split(/\r?\n/).filter(Boolean).map(line => {
    const [index, id, name, memory] = line.split(',').map(value => value.trim());
    if (!/^\d+$/.test(index) || !/^GPU-[a-f\d-]+$/i.test(id) || !name || !/^\d+$/.test(memory)) return null;
    return { index: Number(index), id, name, memoryMB: Number(memory), provider: 'cuda' };
  }).filter(Boolean);
}

let cachedDevices, checkedAt = 0;
export async function gpuDevices(refresh = false) {
  if (!refresh && cachedDevices && Date.now() - checkedAt < 60000) return cachedDevices;
  if (process.platform !== 'win32') return [];
  try {
    const { stdout } = await execute('nvidia-smi.exe', ['--query-gpu=index,uuid,name,memory.total', '--format=csv,noheader,nounits'], { windowsHide: true, timeout: 4000, maxBuffer: 65536 });
    cachedDevices = parseNvidiaDevices(stdout); checkedAt = Date.now(); return cachedDevices;
  } catch { return []; }
}

export function chooseGpu(devices, selection = 'auto') {
  if (selection !== 'auto') {
    const chosen = devices.find(device => device.id === selection);
    if (!chosen) throw new Error('The selected NVIDIA GPU is unavailable. Choose Automatic GPU or reconnect it.');
    return chosen;
  }
  return [...devices].sort((a, b) => b.memoryMB - a.memoryMB || a.index - b.index)[0] ?? null;
}

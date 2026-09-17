import { spawn } from 'node:child_process';
import { mkdtemp, writeFile, readFile, rm, access } from 'node:fs/promises';
import { tmpdir, availableParallelism } from 'node:os';
import { resolve, join } from 'node:path';

// Compiled capabilities and device enumeration are not evidence of an active GPU backend.
export function accelerationFromDiagnostics(diagnostics, requested) {
  let provider = 'cpu';
  if (requested === 'gpu') {
    if (/whisper_backend_init_gpu: using Metal backend/.test(diagnostics)) provider = 'metal';
    else if (/whisper_backend_init_gpu: using (?:Vulkan|Vulkan\d+) backend/i.test(diagnostics)) provider = 'vulkan';
    else if (/whisper_backend_init_gpu: using (?:CUDA|CUDA\d+) backend/i.test(diagnostics)) provider = 'cuda';
  }
  const names = { metal: 'Apple Metal', vulkan: 'Vulkan GPU', cuda: 'NVIDIA CUDA' };
  return { requested, provider, detail: provider !== 'cpu' ? `Whisper uses ${names[provider]}; audio preprocessing uses CPU.` : requested === 'gpu' ? 'The GPU backend was unavailable; Whisper ran on CPU.' : 'Whisper ran on CPU.' };
}
export function encodeWhisperWav(audio, sampleRate) {
  if (!(audio instanceof Float32Array) || audio.length === 0 || audio.length > 16000 * 300) throw Error('Whisper requires a nonempty Float32 audio chunk of at most 300 seconds.');
  if (sampleRate !== 16000) throw Error('Whisper requires 16 kHz mono audio.');
  const out = Buffer.alloc(44 + audio.length * 2);
  out.write('RIFF'); out.writeUInt32LE(out.length - 8, 4); out.write('WAVEfmt ', 8); out.writeUInt32LE(16, 16); out.writeUInt16LE(1, 20); out.writeUInt16LE(1, 22); out.writeUInt32LE(sampleRate, 24); out.writeUInt32LE(sampleRate * 2, 28); out.writeUInt16LE(2, 32); out.writeUInt16LE(16, 34); out.write('data', 36); out.writeUInt32LE(audio.length * 2, 40);
  for (let i = 0; i < audio.length; i++) {
    if (!Number.isFinite(audio[i])) throw Error('Audio contains non-finite samples.');
    const sample = Math.max(-1, Math.min(1, audio[i])); out.writeInt16LE(Math.round(sample * (sample < 0 ? 32768 : 32767)), 44 + i * 2);
  }
  return out;
}
export function parseWhisperResult(json, duration) {
  if (!Array.isArray(json.transcription)) throw Error('Whisper returned invalid captions.');
  const chunks = json.transcription.map(segment => {
    const start = Number(segment.offsets?.from) / 1000, end = Number(segment.offsets?.to) / 1000;
    if (typeof segment.text !== 'string' || !Number.isFinite(start) || !Number.isFinite(end) || start < 0 || end < start) throw Error('Whisper returned invalid caption timing.');
    return { text: segment.text.trim(), timestamp: [Math.min(duration, start), Math.min(duration, end)] };
  }).filter(c => c.text && c.timestamp[1] > c.timestamp[0]);
  return { text: chunks.map(c => c.text).join(' ').trim(), chunks };
}
export async function createWhisperMetal(modelDirectory, model, { device = 'gpu', binary = device === 'cpu' ? (process.env.LOCALVOICE_WHISPER_CPU_BIN || process.env.LOCALVOICE_WHISPER_BIN) : process.env.LOCALVOICE_WHISPER_BIN, binaryArgs = [] } = {}) {
  if (!['cpu', 'gpu'].includes(device)) throw Error('Unknown Whisper device.');
  if (!binary) throw Error('The bundled Whisper GPU runtime is missing. Reinstall Local Voice.');
  const filename = model.files?.find(f => /^ggml-[a-z0-9.-]+\.bin$/.test(f.path))?.path;
  if (!filename) throw Error('Invalid Whisper GPU model.');
  const modelPath = resolve(modelDirectory, filename);
  await access(modelPath); await access(binary);
  let child = null, disposed = false, busy = false, canceled = false, killTimer;
  const onExit = () => child?.kill('SIGKILL');
  process.on('exit', onExit);
  const terminate = () => {
    if (!child) return;
    const active = child; clearTimeout(killTimer); active.kill('SIGTERM');
    killTimer = setTimeout(() => active.kill('SIGKILL'), 1000); killTimer.unref();
  };
  return {
    async transcribe(audio, sampleRate, { timestamps = false, signal } = {}) {
      if (disposed) throw Error('Whisper runtime has been disposed.');
      if (busy) throw Error('Whisper runtime is already transcribing.');
      signal?.throwIfAborted();
      const wav = encodeWhisperWav(audio, sampleRate);
      busy = true; canceled = false;
      let directory;
      try {
        directory = await mkdtemp(join(tmpdir(), 'localvoice-whisper-'));
        await writeFile(join(directory, 'audio.wav'), wav, { mode: 0o600 });
        if (disposed || canceled || signal?.aborted) throw new DOMException('Transcription canceled.', 'AbortError');
        const output = join(directory, 'result');
        const args = ['-m', modelPath, '-f', join(directory, 'audio.wav'), '-oj', '-of', output, '-l', 'en', '-t', String(Math.min(8, availableParallelism())), '-sns'];
        if (device === 'cpu') args.push('-ng');
        let diagnostic = '';
        await new Promise((resolveRun, reject) => {
          let timeout;
          child = spawn(binary, [...binaryArgs, ...args], { stdio: ['ignore', 'ignore', 'pipe'], windowsHide: true });
          child.stderr.on('data', d => { diagnostic = (diagnostic + d.toString()).slice(-256 * 1024); });
          let timedOut = false;
          timeout = setTimeout(() => { timedOut = true; terminate(); }, 10 * 60 * 1000); timeout.unref();
          signal?.addEventListener('abort', terminate, { once: true });
          const cleanup = () => { clearTimeout(timeout); clearTimeout(killTimer); signal?.removeEventListener('abort', terminate); child = null; if (disposed) process.removeListener('exit', onExit); };
          child.once('error', e => { cleanup(); reject(e); });
          child.once('close', code => {
            cleanup();
            if (disposed || canceled || signal?.aborted) reject(new DOMException('Transcription canceled.', 'AbortError'));
            else if (timedOut) reject(Error('Whisper transcription timed out. Try a smaller model.'));
            else if (code !== 0) reject(Error(`Whisper exited with code ${code}. ${diagnostic.slice(-1800)}`));
            else resolveRun();
          });
        });
        const result = parseWhisperResult(JSON.parse(await readFile(`${output}.json`, 'utf8')), audio.length / sampleRate);
        if (disposed || canceled || signal?.aborted) throw new DOMException('Transcription canceled.', 'AbortError');
        return { ...result, ...(timestamps ? {} : { chunks: [] }), acceleration: accelerationFromDiagnostics(diagnostic, device) };
      } finally {
        busy = false;
        if (directory) await rm(directory, { recursive: true, force: true });
      }
    },
    cancel() { canceled = true; terminate(); },
    dispose() { disposed = true; terminate(); if (!child) process.removeListener('exit', onExit); }
  };
}

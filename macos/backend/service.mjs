import path from 'node:path';
import os from 'node:os';
import { existsSync } from 'node:fs';
import { readFile, writeFile, lstat, realpath, unlink } from 'node:fs/promises';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { captionSegments, speakerRegions, validateJobID, validatePCM } from './transcription.mjs';
import { LocalDiarization, speakerModelCatalog } from './diarization.mjs';
// Only an entire response made of recognized sound-event labels means no speech.
// Preserve bracketed prose and marker names embedded in actual spoken text.
export function normalizeTranscript(text) {
  return /^(?:\s*\[\s*(?:blank_audio|no_speech|silence|typing|keyboard typing|music|applause|laughter|laughing|noise|background noise|rustling|breathing|coughing|footsteps|tapping|clicking|static|wind)\s*\]\s*)+$/i.test(text) ? '' : text;
}
export function cleanSpeakerInterval(turns, start, end) {
  const selected = turns.filter(t => t.start < end && t.end > start);
  if (!selected.length || selected.some(t => !t.speaker || t.speaker.includes(' + '))) return false;
  for (let i = 0; i < selected.length; i++) for (let j = i + 1; j < selected.length; j++) {
    if (Math.max(start, selected[i].start, selected[j].start) < Math.min(end, selected[i].end, selected[j].end)) return false;
  }
  return new Set(selected.map(t => t.speaker)).size === 1;
}
async function serve() {
const here = path.dirname(fileURLToPath(import.meta.url));
const core = existsSync(path.join(here, 'core/engine.mjs')) ? path.join(here, 'core/engine.mjs') : path.resolve(here, '../../core/engine.mjs');
// Libraries sometimes log diagnostics: stdout is exclusively the response protocol.
console.log = (...args) => console.error(...args);
const { SpeechEngine, catalog } = await import(pathToFileURL(core));
const { installBundle, removeBundle, describeBundles } = await import(pathToFileURL(path.join(path.dirname(core), 'model-bundles.mjs')));
const { gpuDevices } = await import(pathToFileURL(path.join(path.dirname(core), 'gpu-devices.mjs')));
const oldModels = path.join(os.homedir(), 'Library/Application Support/Hearth/models');
const modelDir = process.env.LOCALVOICE_MODELS || (existsSync(oldModels) ? oldModels : path.join(os.homedir(), 'Library/Application Support/LocalVoiceNative/models'));
const tempDir = await realpath(process.env.LOCALVOICE_SESSION);
let allowNetwork = false;
const networkFetch = globalThis.fetch;
globalThis.fetch = (...args) => { if (!allowNetwork) throw new Error('Network access is disabled outside explicit model installation.'); return networkFetch(...args); };
const engine = new SpeechEngine({ modelDir });
const diarizers = new Map();
const speechCache = new Map(); let speechCacheBytes = 0;
function speakerRuntime(id = 'compact') {
  if (!speakerModelCatalog.some(m => m.id === id)) throw new Error('Choose a supported speaker identification model.');
  if (!diarizers.has(id)) diarizers.set(id, new LocalDiarization(modelDir, { modelID: id }));
  return diarizers.get(id);
}
function wav(audio, rate) {
  const b = Buffer.alloc(44 + audio.length * 2);
  b.write('RIFF'); b.writeUInt32LE(b.length - 8, 4); b.write('WAVEfmt ', 8); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22); b.writeUInt32LE(rate, 24); b.writeUInt32LE(rate * 2, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34); b.write('data', 36); b.writeUInt32LE(audio.length * 2, 40);
  audio.forEach((v, i) => b.writeInt16LE(Math.round(Math.max(-1, Math.min(1, v)) * 32767), 44 + i * 2)); return b;
}
async function dispatch(r) {
  switch (r.command) {
    case 'list': return describeBundles(await engine.listModels());
    case 'gpu-devices': return await gpuDevices(true);
    case 'install': allowNetwork = true; try { await installBundle(engine, catalog, r.model); return {}; } finally { allowNetwork = false; }
    case 'remove': await removeBundle(engine, catalog, r.model); return {};
    case 'warmup-reading': await engine.load(r.model, 'tts', 'cpu'); return {};
    case 'synthesize': {
      const cacheKey = JSON.stringify([r.model, r.voice, r.text]);
      const cached = speechCache.get(cacheKey);
      if (cached && existsSync(cached.path)) {
        speechCache.delete(cacheKey); speechCache.set(cacheKey, cached);
        return { path: cached.path, cached: true };
      }
      if (cached) { speechCacheBytes -= cached.bytes; speechCache.delete(cacheKey); }
      const result = await engine.synthesize({ modelId: r.model, text: r.text, voice: r.voice, speed: 1 });
      const output = path.join(tempDir, `${randomUUID()}.wav`); const bytes = wav(result.audio, result.sampleRate); await writeFile(output, bytes, { flag: 'wx', mode: 0o600 });
      speechCache.set(cacheKey, { path: output, bytes: bytes.length }); speechCacheBytes += bytes.length;
      while (speechCacheBytes > 64 * 1024 * 1024 && speechCache.size > 1) { const [key, old] = speechCache.entries().next().value; speechCache.delete(key); speechCacheBytes -= old.bytes; await unlink(old.path).catch(() => {}); }
      return { path: output, cached: false };
    }
    case 'transcribe': {
      if (typeof r.path !== 'string' || path.dirname(await realpath(r.path)) !== tempDir) throw new Error('Recording must be in the private session folder.');
      const stat = await lstat(r.path); if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 16000 * 300 * 4 || stat.size % 4) throw new Error('Invalid recording size or format.');
      const b = await readFile(r.path); const audio = new Float32Array(b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength));
      const result = await engine.transcribe({ modelId: r.model, device: r.device ?? 'auto', gpu: r.gpu ?? 'auto', audio, sampleRate: 16000 });
      return { ...result, text: normalizeTranscript(result.text) };
    }
    case 'speaker-models': return await Promise.all(speakerModelCatalog.map(async model => ({ ...model, installed: await speakerRuntime(model.id).installed() })));
    case 'diarization-status': return { installed: await speakerRuntime(r.speakerModel).installed() };
    case 'install-diarization': allowNetwork = true; try { await speakerRuntime(r.speakerModel).install(); return {}; } finally { allowNetwork = false; }
    case 'reset-transcription': for (const runtime of diarizers.values()) runtime.reset(r.jobID); return {};
    case 'transcribe-chunk': {
      validateJobID(r.jobID);
      if (typeof r.path !== 'string' || path.dirname(await realpath(r.path)) !== tempDir) throw new Error('Audio chunk must be in the private session folder.');
      const stat = await lstat(r.path);
      if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 16000 * 60 * 4 || stat.size % 4) throw new Error('Invalid audio chunk size or format.');
      const b = await readFile(r.path);
      const audio = new Float32Array(b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength));
      validatePCM(audio);
      const diarization = r.separateSpeakers === true ? speakerRuntime(r.speakerModel) : null;
      const turns = r.separateSpeakers === true ? await diarization.process(audio, r.jobID, r.expectedSpeakers ?? 0) : [];
      if (r.separateSpeakers === true && turns.length) {
        // Decode each real neural speaker turn independently. Whole-chunk Whisper timestamps
        // can cover several speakers and must not be mislabeled as a single person's words.
        const segments = [];
        let acceleration;
        for (const turn of speakerRegions(turns, audio.length / 16000)) {
          const start = Math.max(0, Math.floor(turn.start * 16000));
          const end = Math.min(audio.length, Math.ceil(turn.end * 16000));
          if (end <= start) continue;
          const result = await engine.transcribe({ modelId: r.model, device: r.device ?? 'auto', gpu: r.gpu ?? 'auto', audio: audio.slice(start, end), sampleRate: 16000, timestamps: true });
          acceleration = result.acceleration;
          if (!normalizeTranscript(result.text)) continue;
          for (const caption of captionSegments(result, (end - start) / 16000, [], false).filter(s => normalizeTranscript(s.text))) {
            const from = start + Math.floor(caption.start * 16000), to = Math.min(end, start + Math.floor(caption.end * 16000));
            // Only this caption's audio: a group-average embedding could teach the wrong voice.
            const speakerEmbedding = turn.speaker && !turn.speaker.includes(' + ') && cleanSpeakerInterval(turns, from / 16000, to / 16000) ? await diarization.embeddingFor(audio.slice(from, to)) : undefined;
            segments.push({ ...caption, start: caption.start + start / 16000, end: caption.end + start / 16000, speaker: turn.speaker, ...(speakerEmbedding ? { speakerEmbedding } : {}) });
          }
        }
        return { acceleration, segments: segments.sort((a, b) => a.start - b.start) };
      }
      const result = await engine.transcribe({ modelId: r.model, device: r.device ?? 'auto', gpu: r.gpu ?? 'auto', audio, sampleRate: 16000, timestamps: true });
      if (!normalizeTranscript(result.text)) return { acceleration: result.acceleration, segments: [] };
      return { acceleration: result.acceleration, segments: captionSegments(result, audio.length / 16000, [], false).filter(s => normalizeTranscript(s.text)) };
    }
    case 'rewrite': return await engine.rewrite({ modelId: 'flan-t5-small', text: r.text });
    default: throw new Error('Unknown speech command.');
  }
}
function send(r) { if (stopping) return; process.stdout.write(`${JSON.stringify(r)}\n`); }
let queue = Promise.resolve(), pending = 0, buffer = '', stopping = false, generation = 0;
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => {
  buffer += chunk;
  if (Buffer.byteLength(buffer) > 65536) { process.stderr.write('Request exceeds 64 KB.\n'); process.exit(2); }
  let index;
  while ((index = buffer.indexOf('\n')) >= 0) {
    const line = buffer.slice(0, index); buffer = buffer.slice(index + 1);
    let r; try { r = JSON.parse(line); if (!r || typeof r.id !== 'string' || r.id.length > 100) throw new Error(); } catch { send({ id: null, error: 'Invalid JSON request or request id.' }); continue; }
    if (r.command === 'cancel-work') { generation++; engine.cancel(); send({ id: r.id, result: {} }); continue; }
    const requestGeneration = generation;
    if (pending >= 16) { send({ id: r.id, error: 'Speech service is busy.' }); continue; }
    pending++;
    queue = queue.then(async () => { try { if (stopping) return; if (requestGeneration !== generation) throw new Error('Canceled.'); send({ id: r.id, result: await dispatch(r) }); } catch (e) { send({ id: r.id, error: e.message || 'Speech operation failed.' }); } finally { pending--; } });
  }
});
function shutdown() {
  if (stopping) return;
  stopping = true; engine.cancel();
  // Let the Metal subprocess close and remove its private audio before exiting.
  queue.finally(async () => { await engine.dispose(); process.exit(0); });
}
process.stdin.on('end', shutdown);
process.on('SIGTERM', shutdown);

}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) await serve();

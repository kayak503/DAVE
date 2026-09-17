import path from 'node:path';
import { mkdir, lstat, rename, rm, readdir } from 'node:fs/promises';
import { createReadStream, createWriteStream } from 'node:fs';
import { createHash, randomUUID } from 'node:crypto';
import { pipeline } from 'node:stream/promises';
import { Transform } from 'node:stream';
import { SpeakerClusters, validateJobID, validatePCM, cleanSpeakerTurns } from './transcription.mjs';

import catalog from './speaker-models.json' with { type: 'json' };

// Downloads are explicit and every model is pinned by byte size and SHA-256.
export const speakerModelCatalog = catalog;
export const speakerAssets = catalog[0].assets; // Backward-compatible compact pack.
async function directory(filename) {
  const stat = await lstat(filename);
  if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('Speaker model folder must be a real directory.');
}
export async function verifySpeakerAsset(filename, asset) {
  const stat = await lstat(filename);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size !== asset.size) throw new Error('Speaker model file has an invalid size or type.');
  const hash = createHash('sha256');
  for await (const part of createReadStream(filename)) hash.update(part);
  if (hash.digest('hex') !== asset.sha256) throw new Error('Speaker model integrity check failed.');
}
export class LocalDiarization {
  constructor(modelDir, { modelID = 'compact' } = {}) {
    const model = catalog.find(m => m.id === modelID);
    if (!model) throw new Error('Unknown speaker model.');
    this.modelID = modelID; this.model = model; this.assets = model.assets;
    this.modelDir = modelDir; this.directory = path.join(modelDir, model.directory); this.jobs = new Map();
  }
  async recover() {
    await directory(this.modelDir);
    const backup = path.join(this.modelDir, `.${this.model.directory}.backup`);
    const exists = async p => { try { await lstat(p); return true; } catch(e) { if(e.code==='ENOENT') return false; throw e; } };
    if (await exists(backup)) {
      await directory(backup);
      if (!(await exists(this.directory))) await rename(backup, this.directory);
      else {
        try { await this.verify(); await rm(backup, { recursive: true }); }
        catch {
          for (const asset of this.assets) await verifySpeakerAsset(path.join(backup, asset.name), asset);
          await directory(this.directory); await rm(this.directory, { recursive: true }); await rename(backup, this.directory);
        }
      }
    }
    for (const name of await readdir(this.modelDir)) {
      if (!/^\.speaker-[0-9a-f-]{36}\.partial$/.test(name)) continue;
      const stale = path.join(this.modelDir, name);
      const stat = await lstat(stale);
      if (stat.isDirectory() && !stat.isSymbolicLink() && Date.now() - stat.mtimeMs > 24 * 60 * 60 * 1000) await rm(stale, { recursive: true });
    }
  }
  async verify() {
    await directory(this.modelDir); await directory(this.directory);
    for (const asset of this.assets) await verifySpeakerAsset(path.join(this.directory, asset.name), asset);
  }
  async installed() { try { await this.recover(); await this.verify(); return true; } catch { return false; } }
  async install() {
    await mkdir(this.modelDir, { recursive: true }); await directory(this.modelDir);
    if (await this.installed()) return;
    const temp = path.join(this.modelDir, `.speaker-${randomUUID()}.partial`);
    const backup = path.join(this.modelDir, `.${this.model.directory}.backup`);
    await mkdir(temp, { mode: 0o700 });
    let moved = false;
    try {
      for (const asset of this.assets) {
        const response = await fetch(asset.url, { signal: AbortSignal.timeout(300000) });
        if (!response.ok || !response.body) throw new Error(`Speaker model download failed (${response.status}).`);
        let size = 0;
        const limit = new Transform({ transform(chunk, encoding, next) { size += chunk.length; next(size > asset.size ? new Error('Speaker model download exceeded its expected size.') : null, chunk); } });
        const dest = path.join(temp, asset.name);
        await pipeline(response.body, limit, createWriteStream(dest, { flags: 'wx', mode: 0o600 }));
        await verifySpeakerAsset(dest, asset);
      }
      try { await directory(this.directory); await rename(this.directory, backup); moved = true; }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
      try { await rename(temp, this.directory); }
      catch (error) { if (moved) await rename(backup, this.directory); throw error; }
      if (moved) await rm(backup, { recursive: true });
      this.runtime = null; this.extractor = null; this.jobs.clear();
    } finally { await rm(temp, { recursive: true, force: true }); }
  }
  async load() {
    if (this.runtime) return;
    await this.recover(); await this.verify();
    const { default: sherpa } = await import('sherpa-onnx-node');
    const embedding = { model: path.join(this.directory, 'embedding.onnx'), numThreads: 2, provider: 'cpu', debug: false };
    this.extractor = new sherpa.SpeakerEmbeddingExtractor(embedding);
    this.runtime = new sherpa.OfflineSpeakerDiarization({
      segmentation: { pyannote: { model: path.join(this.directory, 'segmentation.onnx') }, numThreads: 2, provider: 'cpu', debug: false },
      embedding,
      // A file-wide speaker count cannot be imposed on every chunk: some contain one voice.
      clustering: { numClusters: -1, threshold: this.model.clusteringThreshold },
      minDurationOn: 0.3, minDurationOff: 0.35,
    });
  }
  // Call only for one clean, non-overlapping caption. Never pool multiple
  // captions into a reference: a mistaken cluster would contaminate its examples.
  async embeddingFor(audio) {
    validatePCM(audio);
    if (audio.length < 24000) return undefined;
    const samples = audio.subarray(0, 192000);
    const energy = samples.reduce((sum, v) => sum + v * v, 0) / samples.length;
    if (energy < 1e-8) return undefined;
    await this.load();
    const stream = this.extractor.createStream();
    stream.acceptWaveform({ sampleRate: 16000, samples });
    if (!this.extractor.isReady(stream)) return undefined;
    const vector = Array.from(this.extractor.compute(stream));
    const norm = Math.hypot(...vector);
    if (!vector.length || !Number.isFinite(norm) || norm < 1e-10) return undefined;
    return vector.map(v => v / norm);
  }
  reset(jobID) { this.jobs.delete(validateJobID(jobID)); }
  async process(audio, jobID, expectedSpeakers = 0) {
    validatePCM(audio); validateJobID(jobID);
    if (!Number.isInteger(expectedSpeakers) || expectedSpeakers < 0 || expectedSpeakers > 32) throw new Error('Choose between 1 and 32 speakers, or automatic detection.');
    await this.load();
    if (!this.jobs.has(jobID)) {
      if (this.jobs.size >= 8) throw new Error('Too many active transcription sessions. Finish or cancel another session.');
      this.jobs.set(jobID, new SpeakerClusters(expectedSpeakers || 32, this.model.matchThreshold));
    }
    const clusters = this.jobs.get(jobID);
    if (clusters.maximum !== (expectedSpeakers || 32)) throw new Error('Speaker settings changed during transcription. Start a new transcription to apply them.');
    const turns = this.runtime.process(audio).filter(t => Number.isFinite(t.start) && Number.isFinite(t.end) && t.end > t.start).sort((a, b) => a.start - b.start);
    const labels = new Map(), identities = [], embeddings = [];
    for (const localSpeaker of new Set(turns.map(t => t.speaker))) {
      // Gather up to 12 seconds of speech for a robust embedding, bounded independently of file length.
      const pieces = []; let length = 0;
      for (const turn of cleanSpeakerTurns(turns, localSpeaker)) {
        const start = Math.max(0, Math.floor(turn.start * 16000));
        const end = Math.min(audio.length, Math.floor(turn.end * 16000), start + 192000 - length);
        if (end > start) { pieces.push(audio.subarray(start, end)); length += end - start; }
        if (length >= 192000) break;
      }
      if (length < 8000) continue; // Too brief to identify reliably: leave this speech unlabeled.
      const samples = new Float32Array(length); let offset = 0;
      for (const piece of pieces) { samples.set(piece, offset); offset += piece.length; }
      const stream = this.extractor.createStream();
      stream.acceptWaveform({ sampleRate: 16000, samples });
      if (!this.extractor.isReady(stream)) continue;
      identities.push(localSpeaker); embeddings.push(this.extractor.compute(stream));
    }
    clusters.assignBatch(embeddings).forEach((label, i) => labels.set(identities[i], label));
    return turns.map(t => ({ start: t.start, end: t.end, ...(labels.has(t.speaker) ? { speaker: labels.get(t.speaker) } : {}) }));
  }
}

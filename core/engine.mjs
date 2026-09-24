import { readFile, writeFile, mkdir, rm, rename, copyFile, lstat, readdir } from 'node:fs/promises';
import { createReadStream, createWriteStream } from 'node:fs';
import { createHash, randomUUID } from 'node:crypto';
import { pipeline as streamPipeline } from 'node:stream/promises';
import { Transform } from 'node:stream';
import path from 'node:path';
import { gpuDevices, chooseGpu } from './gpu-devices.mjs';
import { inferenceSessionOptions } from './hardware.mjs';

export const catalog = [...JSON.parse(await readFile(new URL('./catalog.json', import.meta.url), 'utf8')), ...JSON.parse(await readFile(new URL('./metal-catalog.json', import.meta.url), 'utf8'))];
export function getModel(id) {
  const model = catalog.find((m) => m.id === id);
  if (!model) throw new Error('Unknown curated model.');
  return model;
}
export async function verifyFile(filename, asset) {
  const stat = await lstat(filename);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size !== asset.size)
    throw new Error(`Invalid asset size or type: ${asset.path}`);
  const hash = createHash(asset.algorithm === 'git-sha1' ? 'sha1' : 'sha256');
  if (asset.algorithm === 'git-sha1') hash.update(`blob ${stat.size}\0`);
  for await (const chunk of createReadStream(filename)) hash.update(chunk);
  if (hash.digest('hex') !== asset.hash) throw new Error(`Integrity check failed: ${asset.path}`);
}
async function safeDirectory(directory) {
  const s = await lstat(directory);
  if (!s.isDirectory() || s.isSymbolicLink())
    throw new Error('Model directories must be real directories, not links.');
}
async function verifyDirectory(directory, model) {
  await safeDirectory(directory);
  for (const asset of model.files) {
    const parent = path.dirname(asset.path);
    if (parent !== '.') await safeDirectory(path.join(directory, parent));
    await verifyFile(path.join(directory, asset.path), asset);
  }
}
async function exists(filename) {
  try {
    await lstat(filename);
    return true;
  } catch (error) {
    if (error.code === 'ENOENT') return false;
    throw error;
  }
}
// A same-volume backup makes replacement recoverable after a failed rename or worker termination.
export async function replaceDirectory(temp, destination, backup, renameFile = rename) {
  if (await exists(backup))
    throw new Error('An earlier model backup needs recovery before installation.');
  const hadPrevious = await exists(destination);
  if (hadPrevious) {
    await safeDirectory(destination);
    await renameFile(destination, backup);
  }
  try {
    await renameFile(temp, destination);
  } catch (error) {
    if (hadPrevious) {
      try {
        await renameFile(backup, destination);
      } catch (rollbackError) {
        throw new AggregateError(
          [error, rollbackError],
          'Installation failed; the previous model remains in its backup folder for startup recovery.',
        );
      }
    }
    throw error;
  }
  if (hadPrevious) await rm(backup, { recursive: true, force: true });
}
function validateDevice(device) {
  if (device && device !== 'cpu')
    throw new Error('This release supports CPU inference. GPU acceleration is not yet validated.');
}
function validateText(text, max = 1200) {
  if (typeof text !== 'string' || !text.trim() || text.length > max)
    throw new Error(`Provide nonempty text up to ${max} characters per chunk.`);
}

export class SpeechEngine {
  constructor({ modelDir, onProgress = () => {} }) {
    if (!modelDir || !path.isAbsolute(modelDir))
      throw new Error('modelDir must be an absolute path.');
    this.modelDir = path.resolve(modelDir);
    this.onProgress = onProgress;
    this.loaded = null;
    this.controller = null;
    this.epoch = 0;
    this.recovery = null;
    this.gpuFailures = new Map();
  }
  directory(id) {
    return path.join(this.modelDir, getModel(id).id);
  }
  // Reader, dictation, preview and transcription services can share model storage.
  async recover() {
    if (!this.recovery)
      this.recovery = this.recoverStorage().catch((error) => {
        this.recovery = null;
        throw error;
      });
    return this.recovery;
  }
  async recoverStorage() {
    await mkdir(this.modelDir, { recursive: true });
    await safeDirectory(this.modelDir);
    const names = await readdir(this.modelDir);
    const activeModels = new Set();
    const stalePartials = [];
    for (const name of names) {
      const model = catalog.find(m => name.startsWith(`.${m.id}-`) &&
        /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.partial$/.test(name.slice(m.id.length + 2)));
      if (!model) continue;
      const filename = path.join(this.modelDir, name);
      let stat;
      try { stat = await lstat(filename); } catch (error) { if (error.code === 'ENOENT') continue; throw error; }
      if (!stat.isDirectory() || stat.isSymbolicLink()) continue;
      let live = Date.now() - stat.mtimeMs < 60_000; // covers mkdir → owner-file publication
      try {
        const owner = JSON.parse(await readFile(path.join(filename, '.owner.json'), 'utf8'));
        if (Number.isInteger(owner.pid) && owner.pid > 0) {
          try { process.kill(owner.pid, 0); live = true; }
          catch (error) { if (error.code !== 'ESRCH') live = true; }
        }
      } catch {}
      if (live) activeModels.add(model.id); else stalePartials.push(filename);
    }
    for (const model of catalog) {
      if (activeModels.has(model.id)) continue;
      const destination = this.directory(model.id);
      const backup = path.join(this.modelDir, `.${model.id}.backup`);
      if (!(await exists(backup))) continue;
      await safeDirectory(backup);
      if (!(await exists(destination))) await rename(backup, destination);
      else {
        await safeDirectory(destination);
        try {
          await verifyDirectory(destination, model);
        } catch {
          // Never discard either copy unless the backup is proven complete.
          await verifyDirectory(backup, model);
          await rm(destination, { recursive: true });
          await rename(backup, destination);
          continue;
        }
        await rm(backup, { recursive: true });
      }
    }
    for (const filename of stalePartials) await rm(filename, { recursive: true, force: true });
  }

  async installed(model) {
    try {
      await safeDirectory(this.directory(model.id));
      const manifest = JSON.parse(
        await readFile(path.join(this.directory(model.id), 'installed.json'), 'utf8'),
      );
      if (manifest.revision !== model.revision || manifest.id !== model.id) return false;
      for (const asset of model.files) {
        if (path.dirname(asset.path) !== '.')
          await safeDirectory(path.join(this.directory(model.id), path.dirname(asset.path)));
        const s = await lstat(path.join(this.directory(model.id), asset.path));
        if (!s.isFile() || s.isSymbolicLink() || s.size !== asset.size) return false;
      }
      return true;
    } catch {
      return false;
    }
  }
  async listModels() {
    await this.recover();
    return Promise.all(
      catalog.map(async ({ files, revision, dtype, ...model }) => ({
        ...model,
        installed: await this.installed(getModel(model.id)),
      })),
    );
  }
  cancel() {
    this.epoch++;
    this.controller?.abort();
    this.loaded?.runtime.cancel?.();
  }
  async dispose() {
    this.cancel();
    if (this.loaded) {
      await (this.loaded.runtime.dispose?.() ?? this.loaded.runtime.model?.dispose?.());
      this.loaded = null;
    }
  }
  async removeModel(id) {
    getModel(id);
    await this.recover();
    if (this.loaded?.id === id) await this.dispose();
    await mkdir(this.modelDir, { recursive: true });
    await safeDirectory(this.modelDir);
    await rm(this.directory(id), { recursive: true, force: true });
  }
  async installModel(id) {
    return this.stage(id);
  }
  async importModel(id, sourceDir) {
    if (typeof sourceDir !== 'string' || !path.isAbsolute(sourceDir))
      throw new Error('Select an absolute model folder.');
    return this.stage(id, sourceDir);
  }
  async stage(id, sourceDir) {
    const model = getModel(id);
    if (this.controller) throw new Error('A model operation is already running.');
    const controller = (this.controller = new AbortController());
    const signal = controller.signal;
    const temp = path.join(this.modelDir, `.${id}-${randomUUID()}.partial`);
    try {
      await this.recover();
      await mkdir(this.modelDir, { recursive: true });
      await safeDirectory(this.modelDir);
      await mkdir(temp);
      await writeFile(path.join(temp, ".owner.json"), JSON.stringify({ pid: process.pid }), { flag: "wx", mode: 0o600 });
      if (sourceDir) await verifyDirectory(sourceDir, model);
      let completed = 0;
      const total = model.files.reduce((sum, f) => sum + f.size, 0);
      for (const asset of model.files) {
        signal.throwIfAborted();
        const dest = path.join(temp, asset.path);
        await mkdir(path.dirname(dest), { recursive: true });
        if (sourceDir) await copyFile(path.join(sourceDir, asset.path), dest);
        else {
          // Network access exists only inside this explicitly requested installation path.
          const url = `https://huggingface.co/${model.repo}/resolve/${model.revision}/${asset.path}`;
          const response = await fetch(url, { signal });
          if (!response.ok || !response.body)
            throw new Error(`Download failed (${response.status}): ${asset.path}`);
          let received = 0;
          const progress = new Transform({
            transform: (chunk, _, callback) => {
              received += chunk.length;
              if (received > asset.size)
                return callback(new Error(`Oversized download: ${asset.path}`));
              this.onProgress({
                type: 'progress',
                modelId: id,
                status: 'Downloading',
                file: asset.path,
                progress: ((completed + received) / total) * 100,
              });
              callback(null, chunk);
            },
          });
          await streamPipeline(response.body, progress, createWriteStream(dest, { flags: 'wx' }), {
            signal,
          });
        }
        await verifyFile(dest, asset);
        completed += asset.size;
      }
      signal.throwIfAborted();
      await writeFile(
        path.join(temp, 'installed.json'),
        JSON.stringify({ id, revision: model.revision }),
      );
      if (this.loaded?.id === id) {
        await (this.loaded.runtime.dispose?.() ?? this.loaded.runtime.model?.dispose?.());
        this.loaded = null;
      }
      signal.throwIfAborted();
      await replaceDirectory(temp, this.directory(id), path.join(this.modelDir, `.${id}.backup`));
      this.onProgress({
        type: 'progress',
        modelId: id,
        status: 'Installed and verified',
        progress: 100,
      });
    } finally {
      this.controller = null;
      await rm(temp, { recursive: true, force: true });
    }
  }
  async load(id, task, device, gpu = 'auto') {
    const model = getModel(id);
    if (model.engine !== 'whisper-metal') validateDevice(device);
    await this.recover();
    if (model.task !== task) throw new Error('Model task does not match this operation.');
    if (this.loaded?.id === id && this.loaded.device === device && (this.loaded.gpu ?? 'auto') === gpu) return this.loaded.runtime;
    if (!(await this.installed(model)))
      throw new Error(`Install or import ${model.name} before using it.`);
    await verifyDirectory(this.directory(id), model);
    if (this.loaded) {
      await (this.loaded.runtime.dispose?.() ?? this.loaded.runtime.model?.dispose?.());
      this.loaded = null;
    }
    if (model.engine === 'whisper-metal') {
      const { createWhisperMetal } = await import('./whisper-metal.mjs');
      const runtime = await createWhisperMetal(this.directory(id), model, { device, gpu });
      this.loaded = { id, device, gpu, runtime };
      return runtime;
    }
    if (model.engine === 'supertonic') {
      const { createSupertonic } = await import('./supertonic.mjs');
      const runtime = await createSupertonic(this.directory(id), model);
      this.loaded = { id, device, runtime };
      return runtime;
    }
    const hf = await import('@huggingface/transformers');
    hf.env.allowRemoteModels = false;
    hf.env.allowLocalModels = true;
    hf.env.useBrowserCache = false;
    hf.env.useFSCache = false;
    const options = { dtype: model.dtype, device: 'cpu', local_files_only: true, session_options: inferenceSessionOptions() };
    this.onProgress({ type: 'progress', modelId: id, status: 'Loading local model' });
    let runtime;
    if (task === 'tts') {
      const { KokoroTTS } = await import('kokoro-js');
      const [onnx, tokenizer] = await Promise.all([
        hf.StyleTextToSpeech2Model.from_pretrained(this.directory(id), options),
        hf.AutoTokenizer.from_pretrained(this.directory(id), options),
      ]);
      runtime = new KokoroTTS(onnx, (text, options) =>
        tokenizer(text, { ...options, truncation: false }),
      );
      // Override upstream voice loading. Only our verified local voice assets may be read.
      const voices = new Map();
      runtime.generate_from_ids = async (input_ids, { voice = 'af_heart', speed = 1 } = {}) => {
        if (!model.voices.some((v) => v.id === voice))
          throw new Error('Choose an installed English voice.');
        if (!voices.has(voice)) {
          const bytes = await readFile(path.join(this.directory(id), 'voices', `${voice}.bin`));
          voices.set(
            voice,
            new Float32Array(
              bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength),
            ),
          );
        }
        if (input_ids.dims.at(-1) > 512)
          throw new Error('This speech chunk is too long. Split it into shorter sentences.');
        const offset = 256 * Math.min(Math.max(input_ids.dims.at(-1) - 2, 0), 509);
        const { waveform } = await onnx({
          input_ids,
          style: new hf.Tensor('float32', voices.get(voice).slice(offset, offset + 256), [1, 256]),
          speed: new hf.Tensor('float32', [speed], [1]),
        });
        return new hf.RawAudio(waveform.data, 24000);
      };
    } else {
      runtime = await hf.pipeline(
        task === 'stt' ? 'automatic-speech-recognition' : 'text2text-generation',
        this.directory(id),
        options,
      );
    }
    this.loaded = { id, device, runtime };
    return runtime;
  }
  async synthesize({ modelId, text, voice, speed = 1, device = 'cpu' }) {
    validateText(text);
    if (!Number.isFinite(speed) || speed < 0.5 || speed > 2)
      throw new Error('Speech speed must be between 0.5 and 2.');
    const m = getModel(modelId);
    voice ??= m.voices?.[0]?.id;
    if (!m.voices?.some((v) => v.id === voice))
      throw new Error('Choose an installed English voice.');
    const epoch = this.epoch;
    const runtime = await this.load(modelId, 'tts', device);
    const result = await runtime.generate(text, { voice, speed });
    if (epoch !== this.epoch) throw new Error('Cancelled.');
    return { audio: result.audio, sampleRate: result.sampling_rate };
  }
  async transcribe({ modelId, audio, sampleRate, device = 'auto', gpu = 'auto', timestamps = false }) {
    if (
      sampleRate !== 16000 ||
      !(audio instanceof Float32Array) ||
      !audio.length ||
      audio.length > 16000 * 300 ||
      audio.some((x) => !Number.isFinite(x) || Math.abs(x) > 1.01)
    )
      throw new Error('Provide up to five minutes of normalized mono Float32 audio at 16 kHz.');
    const epoch = this.epoch;
    if (!['auto', 'cpu', 'metal', 'gpu'].includes(device)) throw new Error('Choose Automatic, CPU, or GPU.');
    const original = getModel(modelId);
    if (original.task !== 'stt') throw new Error('Choose a recognition model.');
    const companion = original.engine === 'whisper-metal' ? original : catalog.find(m => m.variantOf === modelId);
    const metalInstalled = companion && await this.installed(companion);
    const explicitGPU = device === 'metal' || device === 'gpu';
    let energy = 0;
    for (const x of audio) energy += x * x;
    if (Math.sqrt(energy / audio.length) < 0.0005) return { text: '', chunks: [], acceleration: { requested: device, provider: 'none', detail: 'No speech detected; recognition was not needed.' } };
    let acceleration = { requested: device, provider: 'cpu', detail: device === 'auto' ? 'CPU · complete this model’s installation in Models to enable acceleration' : 'CPU · selected in Settings' };
    if (explicitGPU && !metalInstalled) throw new Error('Complete this model’s installation in Models to enable GPU acceleration.');
    if (metalInstalled && (device !== 'cpu' || original.engine === 'whisper-metal' || !(await this.installed(original)))) {
      try {
        const previousFailure = this.gpuFailures.get(`${companion.id}:${gpu}`);
        if (device === 'auto' && previousFailure && Date.now() - previousFailure.at < 60000) throw new Error(previousFailure.message);
        const selectedGpu = device !== 'cpu' && process.platform === 'win32' ? chooseGpu(await gpuDevices(), gpu)?.id ?? 'auto' : 'auto';
        const metal = await this.load(companion.id, 'stt', device === 'cpu' ? 'cpu' : 'gpu', selectedGpu);
        if (epoch !== this.epoch) throw new Error('Cancelled.');
        const result = await metal.transcribe(audio, sampleRate, { timestamps });
        if (epoch !== this.epoch) throw new Error('Cancelled.');
        if (explicitGPU && !(process.platform === 'win32' ? ['cuda', 'vulkan'] : ['metal']).includes(result.acceleration?.provider)) throw new Error('GPU acceleration could not start. Choose CPU or Automatic in Settings.');
        this.gpuFailures.delete(`${companion.id}:${gpu}`);
        return { ...result, acceleration: { ...result.acceleration, requested: device } };
      } catch (error) {
        if (epoch !== this.epoch || explicitGPU || device === 'cpu') throw error;
        if (!this.gpuFailures.has(`${companion.id}:${gpu}`) || Date.now() - this.gpuFailures.get(`${companion.id}:${gpu}`).at >= 60000) this.gpuFailures.set(`${companion.id}:${gpu}`, { at: Date.now(), message: error.message });
        acceleration.detail = `CPU fallback · GPU unavailable: ${error.message}`;
        // GGML weights work on CPU too. Windows ships a separate CPU executable so
        // a missing CUDA driver must not require another model download.
        if (original.engine === 'whisper-metal' || !(await this.installed(original))) {
          const cpu = await this.load(companion.id, 'stt', 'cpu');
          if (epoch !== this.epoch) throw new Error('Cancelled.');
          const result = await cpu.transcribe(audio, sampleRate, { timestamps });
          if (epoch !== this.epoch) throw new Error('Cancelled.');
          return { ...result, acceleration };
        }
      }
    }
    const runtime = await this.load(modelId, 'stt', 'cpu');
    const languageOptions = getModel(modelId).language ? { language: getModel(modelId).language, task: 'transcribe' } : {};
    const result = await runtime(audio, {
      ...languageOptions,
      chunk_length_s: 30,
      stride_length_s: 5,
      return_timestamps: timestamps,
    });
    if (epoch !== this.epoch) throw new Error('Cancelled.');
    // Some Whisper ONNX exports emit only a timestamp token for audible speech.
    // Retry ordinary decoding, retaining honest audio-region bounds rather than inventing word times.
    if (timestamps && !result.text.trim()) {
      const retry = await runtime(audio, { ...languageOptions, chunk_length_s: 30, stride_length_s: 5, return_timestamps: false });
      if (epoch !== this.epoch) throw new Error('Cancelled.');
      return { acceleration, text: retry.text.trim(), chunks: retry.text.trim() ? [{ text: retry.text.trim(), timestamp: [0, audio.length / sampleRate] }] : [], timestampSource: 'audio-region' };
    }
    return { acceleration, text: result.text.trim(), ...(timestamps ? { chunks: result.chunks || [], timestampSource: 'model' } : {}) };
  }
  async rewrite({ modelId, text, device = 'cpu' }) {
    validateText(text, 1500);
    const epoch = this.epoch;
    const runtime = await this.load(modelId, 'rewrite', device);
    const result = await runtime(
      `Rewrite this transcript with clear grammar. Preserve the meaning, names, numbers and negations: ${text}`,
      { max_new_tokens: 256, do_sample: false },
    );
    if (epoch !== this.epoch) throw new Error('Cancelled.');
    const output = result[0]?.generated_text?.trim();
    if (!output)
      throw new Error('The model returned no suggestion. Your original transcript is unchanged.');
    return { text: output };
  }
}

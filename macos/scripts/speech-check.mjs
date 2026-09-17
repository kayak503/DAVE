import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtemp, readFile, writeFile, rm, realpath } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';
import { resampleAudio } from '../../core/audio.mjs';
import { normalizeTranscript } from '../backend/service.mjs';
for (const text of ['[BLANK_AUDIO]', '[blank_audio]', '[No_Speech]', '[typing]', '[keyboard typing]', '[music]', '[applause]', '[laughter]', '[silence]', ' [ Typing ] ', '[typing] [MUSIC] [Silence]']) {
  assert.equal(normalizeTranscript(text), '', `Non-speech annotation leaked: ${text}`);
}
for (const text of ['[Bring three notebooks]', '[music theory]', 'I wrote [BLANK_AUDIO] in the notes.', 'Please stop [typing] now.', '[typing] [Bring three notebooks]', 'The garden is quiet today.']) {
  assert.equal(normalizeTranscript(text), text, `Actual text was removed: ${text}`);
}
const root = path.resolve(import.meta.dirname, '../..');
const session = await realpath(await mkdtemp(path.join(os.tmpdir(), 'native-speech-check-')));
const compile = spawnSync('swiftc', ['-swift-version', '5', '-module-cache-path', path.join(os.tmpdir(), 'localvoice-swift-cache'), '-target', 'arm64-apple-macosx14.0', '-parse-as-library', '-emit-module', path.join(root, 'macos/Sources/InteractionState.swift'), path.join(root, 'macos/Sources/LocalSpeech.swift'), path.join(root, 'macos/Sources/Transcription.swift'), '-o', path.join(session, 'Speech.swiftmodule')], { encoding: 'utf8' });
assert.equal(compile.status, 0, compile.stderr);
// Queue a stale cancellation, then enter the next render before yielding to its handler.
const lifecycleSource = path.join(session, 'Lifecycle.swift');
await writeFile(lifecycleSource, `
import Foundation
@main struct LifecycleCheck {
    @MainActor static func main() async {
        let speech = LocalSpeech()
        let old = Task { try await speech.speak("An earlier sentence.", model: "system", voice: "af_heart", rate: 1) }
        while speech.status != "Preparing speech…" { await Task.yield() }
        old.cancel()
        speech.stopSpeaking()
        let inspector = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            let preserved = speech.status == "Preparing speech…" || speech.status == "Reading"
            speech.stopSpeaking()
            return preserved
        }
        do { try await speech.speak("The next sentence must survive cancellation of the previous sentence.", model: "system", voice: "af_heart", rate: 1) } catch {}
        let preserved = await inspector.value
        _ = try? await old.value
        speech.shutdown()
        if !preserved { fatalError("Stale cancellation stopped the next speech generation.") }
        print("NATIVE_SPEECH_LIFECYCLE_OK")
    }
}
`);
const lifecycleBinary = path.join(session, 'lifecycle');
const lifecycleBuild = spawnSync('swiftc', ['-swift-version', '5', '-module-cache-path', path.join(os.tmpdir(), 'localvoice-swift-cache'), '-target', 'arm64-apple-macosx14.0', path.join(root, 'macos/Sources/InteractionState.swift'), path.join(root, 'macos/Sources/LocalSpeech.swift'), path.join(root, 'macos/Sources/Transcription.swift'), lifecycleSource, '-o', lifecycleBinary], { encoding: 'utf8' });
assert.equal(lifecycleBuild.status, 0, lifecycleBuild.stderr);
const lifecycleRun = spawnSync(lifecycleBinary, [], { encoding: 'utf8', timeout: 10000 });
assert.equal(lifecycleRun.status, 0, lifecycleRun.stderr);
assert.match(lifecycleRun.stdout, /NATIVE_SPEECH_LIFECYCLE_OK/);

const child = spawn(process.execPath, [path.join(root, 'macos/backend/service.mjs')], { env: { ...process.env, LOCALVOICE_MODELS: path.join(root, '.cache/models'), LOCALVOICE_SESSION: session }, stdio: ['pipe', 'pipe', 'pipe'] });
let serial = 0, stderr = ''; const pending = new Map();
child.stderr.on('data', b => stderr += b);
readline.createInterface({ input: child.stdout }).on('line', line => { const r = JSON.parse(line); const p = pending.get(r.id); if (!p) return; pending.delete(r.id); r.error ? p.reject(new Error(r.error)) : p.resolve(r.result); });
child.on('exit', code => { for (const p of pending.values()) p.reject(new Error(`Service exited ${code}: ${stderr}`)); pending.clear(); });
function request(command, fields = {}) { const id = String(++serial); return new Promise((resolve, reject) => { pending.set(id, { resolve, reject }); child.stdin.write(JSON.stringify({ id, command, ...fields }) + '\n'); }); }
const deadline = setTimeout(() => child.kill('SIGKILL'), 180000);
try {
  const models = await request('list');
  for (const id of ['kokoro-q8', 'whisper-tiny']) assert.ok(models.find(m => m.id === id)?.installed, `Missing cached ${id}`);
  await assert.rejects(request('unknown'), /Unknown/);
  await assert.rejects(request('synthesize', { model: 'kokoro-q8', text: '', voice: 'af_heart' }), /nonempty/);
  const result = await request('synthesize', { model: 'kokoro-q8', text: 'The garden is quiet today. Please bring three blue notebooks to the kitchen.', voice: 'af_heart' });
  assert.equal(path.dirname(result.path), session);
  const audio = await readFile(result.path); assert.equal(audio.toString('ascii', 0, 4), 'RIFF'); assert.equal(audio.readUInt32LE(24), 24000); assert.ok(audio.length > 48000);
  let peak = 0; for (let i = 44; i < audio.length; i += 2) peak = Math.max(peak, Math.abs(audio.readInt16LE(i))); assert.ok(peak > 1000);
  // Transcribe the independent fixed WAV artifact, not the just-generated result.
  const fixed = await readFile(path.join(root, 'macos/Tests/Fixtures/speech.wav'));
  assert.equal(fixed.readUInt16LE(20), 1); assert.equal(fixed.readUInt16LE(22), 1); assert.equal(fixed.readUInt16LE(34), 16);
  const floats = new Float32Array((fixed.length - 44) / 2); for (let i = 0; i < floats.length; i++) floats[i] = fixed.readInt16LE(44 + i * 2) / 32768;
  const pcm = resampleAudio(floats, fixed.readUInt32LE(24)); const pcmPath = path.join(session, 'fixed.f32'); await writeFile(pcmPath, Buffer.from(pcm.buffer));
  const transcript = await request('transcribe', { model: 'whisper-tiny', path: pcmPath });
  for (const word of ['garden', 'notebooks', 'kitchen']) assert.match(transcript.text.toLowerCase(), new RegExp(word));
  await assert.rejects(request('transcribe', { model: 'whisper-tiny', path: path.join(root, 'macos/Tests/Fixtures/speech.wav') }), /private session/);
  // A fixed three-second, mono16k PCM WAV of quiet-room silence travels through the same
  // WAV-to-Float32 conversion and service protocol as the speech fixture.
  const silenceWav = Buffer.alloc(44 + 16000 * 3 * 2);
  silenceWav.write('RIFF'); silenceWav.writeUInt32LE(silenceWav.length - 8, 4); silenceWav.write('WAVEfmt ', 8);
  silenceWav.writeUInt32LE(16, 16); silenceWav.writeUInt16LE(1, 20); silenceWav.writeUInt16LE(1, 22);
  silenceWav.writeUInt32LE(16000, 24); silenceWav.writeUInt32LE(32000, 28); silenceWav.writeUInt16LE(2, 32); silenceWav.writeUInt16LE(16, 34);
  silenceWav.write('data', 36); silenceWav.writeUInt32LE(silenceWav.length - 44, 40);
  // Low-level 60Hz input hum exceeds the engine's silence shortcut, exercising
  // real Whisper inference; this cached model returns [BLANK_AUDIO] for it.
  for (let i = 0; i < 48000; i++) silenceWav.writeInt16LE(Math.round(Math.sin(2 * Math.PI * 60 * i / 16000) * 0.002 * 32767), 44 + i * 2);
  const silencePath = path.join(session, 'silence.wav'); await writeFile(silencePath, silenceWav);
  const silence = await readFile(silencePath); const silenceAudio = new Float32Array((silence.length - 44) / 2);
  for (let i = 0; i < silenceAudio.length; i++) silenceAudio[i] = silence.readInt16LE(44 + i * 2) / 32768;
  assert.ok(Math.sqrt(silenceAudio.reduce((sum, v) => sum + v * v, 0) / silenceAudio.length) > 0.0005);
  const silencePCMPath = path.join(session, 'silence.f32'); await writeFile(silencePCMPath, Buffer.from(silenceAudio.buffer));
  assert.equal((await request('transcribe', { model: 'whisper-tiny', path: silencePCMPath })).text, '');

  if (models.find(m => m.id === 'flan-t5-small')?.installed) { const rewritten = await request('rewrite', { text: 'The garden is quiet today.' }); assert.ok(rewritten.text.length); }
  else await assert.rejects(request('rewrite', { text: 'The garden is quiet today.' }), /Install or import/);
  console.log(JSON.stringify({ transcript: transcript.text, synthesizedBytes: audio.length, localOnly: true }));
  console.log('NATIVE_SPEECH_OK');
} finally { clearTimeout(deadline); if (child.exitCode === null && child.signalCode === null) { child.kill(); await new Promise(resolve => child.once('exit', resolve)); } await rm(session, { recursive: true, force: true }); }

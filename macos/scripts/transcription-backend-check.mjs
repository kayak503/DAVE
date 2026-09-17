import assert from 'node:assert/strict';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { mkdtemp, readFile, writeFile, rm, mkdir, symlink } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import sherpa from 'sherpa-onnx-node';
import { captionSegments, speakerRegions, SpeakerClusters, validatePCM, validateJobID } from '../backend/transcription.mjs';
import { LocalDiarization, verifySpeakerAsset, speakerAssets } from '../backend/diarization.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const models = process.env.LOCALVOICE_TEST_MODELS || path.join(root, '.cache/models');
const fixtures = path.join(root, '.cache/transcription-fixtures');
const fixtureSpecs = [
  ['speaker1-a', 'speaker1_a_en_16k.wav', 'cb35bff3dac9aec36e259461fecae1e1bc2ec029615f30713111cd598993676c'],
  ['speaker1-b', 'speaker1_b_en_16k.wav', 'd7daff767e13d9a2187b676d958065121cd5e26da046d65cd9604e91a87525a2'],
  ['speaker2-a', 'speaker2_a_en_16k.wav', 'a723c134978a17fe12ca2374d0281a8003a56fa44ff9d2249a08791714983362'],
];
if (process.argv.includes('--download-fixtures')) {
  await mkdir(fixtures, { recursive: true });
  for (const [name, remote, hash] of fixtureSpecs) {
    const response = await fetch(`https://raw.githubusercontent.com/csukuangfj/sr-data/main/test/3d-speaker/${remote}`);
    assert(response.ok); const bytes = Buffer.from(await response.arrayBuffer());
    assert.equal(createHash('sha256').update(bytes).digest('hex'), hash);
    await writeFile(path.join(fixtures, `${name}.wav`), bytes);
  }
}
for (const [name, , hash] of fixtureSpecs) assert.equal(createHash('sha256').update(await readFile(path.join(fixtures, `${name}.wav`))).digest('hex'), hash, `Public fixture ${name} integrity`);

// Pure unit checks: malformed samples, timestamps, caption ownership and stable clustering.
assert.throws(() => validatePCM(new Float32Array([NaN])));
assert.throws(() => validatePCM(new Float32Array(16000 * 61)));
assert.throws(() => validatePCM(new Float32Array([1.2])));
assert.throws(() => validateJobID('../escape'));
assert.equal(validateJobID('job-123'), 'job-123');
assert.deepEqual(captionSegments({ chunks: [{text:' one',timestamp:[-2,1]}, {text:' two.',timestamp:[1,2]}, {text:' three',timestamp:[2,null]}] },3), [{start:0,end:2,text:'one two.'},{start:2,end:3,text:'three'}]);
assert.deepEqual(captionSegments({chunks:[{text:' out',timestamp:[6,7]}]},5),[]);
assert.equal(captionSegments({chunks:[{text:' hi',timestamp:[0,1]}]},2,[{start:0,end:0.8,speaker:'Speaker 2'}])[0].speaker,'Speaker 2');
assert.equal(captionSegments({text:'Speech without reliable speaker assignment'},2,[])[0].speaker,undefined);
assert.deepEqual(speakerRegions([{start:1,end:3,speaker:'Speaker 1'},{start:2,end:4,speaker:'Speaker 2'}],5),[
  {start:0,end:1},{start:1,end:2,speaker:'Speaker 1'},{start:2,end:3,speaker:'Speaker 1 + Speaker 2'},{start:3,end:4,speaker:'Speaker 2'},{start:4,end:5}
]);
const clusters=new SpeakerClusters(2);
assert.equal(clusters.assign(new Float32Array([1,0,0])),'Speaker 1');
assert.equal(clusters.assign(new Float32Array([0,1,0])),'Speaker 2');
assert.equal(clusters.assign(new Float32Array([0.99,0.01,0])),'Speaker 1');
assert.throws(()=>clusters.assign(new Float32Array([0,0,0])));

const temp=await mkdtemp(path.join(os.tmpdir(),'localvoice-transcription-check-'));
let child;
try {
  const bad=path.join(temp,'bad.onnx');await writeFile(bad,'wrong');
  await assert.rejects(verifySpeakerAsset(bad,{size:5,sha256:'0'.repeat(64)}),/integrity/);
  const link=path.join(temp,'link.onnx');await symlink(bad,link);
  await assert.rejects(verifySpeakerAsset(link,{size:5,sha256:'0'.repeat(64)}),/type/);
  const downloadTest=new LocalDiarization(path.join(temp,'installer-models'));
  const originalFetch=globalThis.fetch;
  try {
    // Exercise staging and hash validation with real model bytes and a controlled transport.
    globalThis.fetch=async()=>new Response(Buffer.from('corrupt'));
    await assert.rejects(downloadTest.install(),/invalid size/);
    assert.equal(await downloadTest.installed(),false);
    let downloads=0;
    globalThis.fetch=async url=>{downloads++;const asset=speakerAssets.find(a=>a.url===url);assert(asset);return new Response(await readFile(path.join(models,'speaker-diarization',asset.name)));};
    await downloadTest.install();assert.equal(downloads,2);assert.equal(await downloadTest.installed(),true);
    await downloadTest.install();assert.equal(downloads,2,'An installed model must never be downloaded again.');
  } finally {globalThis.fetch=originalFetch;}
  const diarization=new LocalDiarization(models);
  assert.equal(await diarization.installed(),true,'Install the optional speaker model in the test cache first.');
  const wave=name=>sherpa.readWave(path.join(fixtures,`${name}.wav`)).samples;
  const first=await diarization.process(wave('speaker1-a'),'stable-labels');
  const second=await diarization.process(wave('speaker2-a'),'stable-labels');
  const repeat=await diarization.process(wave('speaker1-b'),'stable-labels');
  assert(first.length>0&&second.length>0&&repeat.length>0);
  assert.deepEqual([...new Set(first.map(t=>t.speaker))],['Speaker 1']);
  assert.deepEqual([...new Set(second.map(t=>t.speaker))],['Speaker 2']);
  assert.deepEqual([...new Set(repeat.map(t=>t.speaker))],['Speaker 1']);
  diarization.reset('stable-labels');assert.equal(diarization.jobs.size,0);
  console.log('Real local diarization: two distinct English speakers, same speaker re-identified across different recordings.');

  const pending=new Map();let output='',errors='';
  child=spawn(process.execPath,[path.join(root,'macos/backend/service.mjs')],{env:{...process.env,LOCALVOICE_MODELS:models,LOCALVOICE_SESSION:temp},stdio:['pipe','pipe','pipe']});
  child.stderr.on('data',b=>{errors=(errors+b).slice(-4000);});
  child.stdout.on('data',b=>{output+=b;let end;while((end=output.indexOf('\n'))>=0){const message=JSON.parse(output.slice(0,end));output=output.slice(end+1);const p=pending.get(message.id);if(p){pending.delete(message.id);clearTimeout(p.timer);message.error?p.reject(new Error(message.error)):p.resolve(message.result);}}});
  child.on('exit',code=>{for(const p of pending.values()){clearTimeout(p.timer);p.reject(new Error(`Service exited ${code}: ${errors}`));}pending.clear();});
  const request=(command,args={})=>new Promise((resolve,reject)=>{const id=randomUUID();const timer=setTimeout(()=>{pending.delete(id);reject(new Error(`Timed out: ${command}: ${errors}`));},120000);pending.set(id,{resolve,reject,timer});child.stdin.write(JSON.stringify({id,command,...args})+'\n');});
  const transcribe=async(samples,args={})=>{const filename=path.join(temp,`${randomUUID()}.pcm`);await writeFile(filename,Buffer.from(samples.buffer,samples.byteOffset,samples.byteLength));try{return await request('transcribe-chunk',{path:filename,model:'whisper-tiny',jobID:'integration',...args});}finally{await rm(filename,{force:true});}};
  assert.equal((await request('diarization-status')).installed,true);
  await assert.rejects(request('transcribe-chunk',{path:path.join(root,'macos/Tests/Fixtures/speech.wav'),model:'whisper-tiny',jobID:'integration'}),/private session/);
  await assert.rejects(transcribe(new Float32Array([NaN])),/normalized/);
  const fixture=sherpa.readWave(path.join(root,'macos/Tests/Fixtures/speech.wav'));
  const samples=new sherpa.LinearResampler(fixture.sampleRate,16000).flush(fixture.samples);
  const recognized=await transcribe(samples);
  assert.match(recognized.segments.map(s=>s.text).join(' '),/garden.*quiet.*three blue notebooks.*kitchen/i);
  assert(recognized.segments.every(s=>Number.isFinite(s.start)&&s.end>s.start&&s.end<=samples.length/16000));
  assert.deepEqual((await transcribe(new Float32Array(16000))).segments,[]);
  const a=wave('speaker1-a'),b=wave('speaker2-a'),mix=new Float32Array(a.length+16000+b.length);mix.set(a);mix.set(b,a.length+16000);
  const identified=await transcribe(mix,{separateSpeakers:true,expectedSpeakers:2});
  assert.match(identified.segments.filter(s=>s.speaker==='Speaker 1').map(s=>s.text).join(' '),/letter.*family/i);
  assert.match(identified.segments.filter(s=>s.speaker==='Speaker 2').map(s=>s.text).join(' '),/trying.*painting/i);
  const speakers=new Set(identified.segments.filter(s=>s.text.trim()).map(s=>s.speaker));
  assert(speakers.has('Speaker 1')&&speakers.has('Speaker 2'),JSON.stringify(identified));
  assert(identified.segments.every(s=>s.start>=0&&s.end<=mix.length/16000));
  await request('reset-transcription',{jobID:'integration'});
  console.log('Real JSONL integration: timestamped Whisper captions, silence, private-file rejection, invalid PCM, two-speaker transcription and reset passed.');
  console.log('TRANSCRIPTION_BACKEND_OK');
} finally { if(child){child.kill('SIGTERM');}await rm(temp,{recursive:true,force:true}); }

import assert from 'node:assert/strict';
import { readFile, writeFile, mkdtemp, rm, cp } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { tmpdir } from 'node:os';
import { spawn } from 'node:child_process';
import { SpeechEngine } from '../core/engine.mjs';
import { createInterface } from 'node:readline';
const packaged=process.argv.includes('--packaged');
const resources=resolve('release/native/DAVE.app/Contents/Resources');
const wav=await readFile('test-results/transcription-two-speakers.wav');
let p=12,pcm;
while(p+8<=wav.length){const n=wav.readUInt32LE(p+4);if(wav.toString('ascii',p,p+4)==='data'){pcm=wav.subarray(p+8,p+8+n);break;}p+=8+n+(n%2);}
assert(pcm);const audio=Float32Array.from({length:pcm.length/2},(_,i)=>pcm.readInt16LE(i*2)/32768);
const session=await mkdtemp(join(tmpdir(),'localvoice-acceleration-check-'));
const binary=packaged?join(resources,'runtime/whisper-cli'):resolve('.cache/metal-build/build/bin/whisper-cli');
const modelDir=resolve('.cache/acceleration-models');
const installer=new SpeechEngine({modelDir});
for (const id of ['whisper-tiny-metal','whisper-small-metal']) {
 const models=await installer.listModels();
 if (!models.find(m=>m.id===id)?.installed) await installer.importModel(id,resolve('.cache/metal-models',id));
}
await installer.dispose();
await cp(resolve('.cache/models/speaker-diarization'),join(modelDir,'speaker-diarization'),{recursive:true});
const child=spawn(packaged?join(resources,'runtime/node'):process.execPath,[packaged?join(resources,'backend/service.mjs'):resolve('macos/backend/service.mjs')],{env:{...process.env,LOCALVOICE_MODELS:modelDir,LOCALVOICE_SESSION:session,LOCALVOICE_WHISPER_BIN:binary},stdio:['pipe','pipe','pipe']});
const pending=new Map();let counter=0,errors='';child.stderr.on('data',d=>errors+=d);
createInterface({input:child.stdout}).on('line',line=>{const r=JSON.parse(line);const p=pending.get(r.id);if(p){pending.delete(r.id);r.error?p.reject(Error(r.error)):p.resolve(r.result);}});
child.on('exit',()=>{for(const p of pending.values())p.reject(Error('service exited '+errors));});
function request(command,values={}){return new Promise((resolve,reject)=>{const id=String(++counter);pending.set(id,{resolve,reject});child.stdin.write(JSON.stringify({id,command,...values})+'\n');});}
const timeout=setTimeout(()=>child.kill('SIGKILL'),120000);
try {
 const file=join(session,'speech.f32');await writeFile(file,Buffer.from(audio.buffer));
 for(const device of ['metal','cpu','auto']) {
  const result=await request('transcribe',{model:'whisper-tiny',device,path:file});
  assert.match(result.text.toLowerCase(),/letter/);assert.match(result.text.toLowerCase(),/painting/);
  assert.equal(result.acceleration.provider,device==='cpu'?'cpu':'metal');
  console.log(device,result.acceleration);
 }
 for (const separateSpeakers of [false,true]) {
 const chunk=await request('transcribe-chunk',{model:'whisper-small',device:'metal',path:file,jobID:'gpu-check-'+separateSpeakers,separateSpeakers,expectedSpeakers:2});
 assert.equal(chunk.acceleration.provider,'metal');assert.ok(chunk.segments.length>=2);
 assert.ok(chunk.segments.every(s=>s.start>=0&&s.end<=audio.length/16000));
 if(separateSpeakers) assert.equal(new Set(chunk.segments.map(s=>s.speaker).filter(Boolean)).size,2);
 }
 await assert.rejects(request('transcribe',{model:'whisper-medium',device:'metal',path:file}),/Download GPU files/);
 console.log('ACCELERATION_REAL_OK '+(packaged?'packaged':'source'));
} finally { clearTimeout(timeout);child.kill('SIGTERM');await rm(session,{recursive:true,force:true}); }

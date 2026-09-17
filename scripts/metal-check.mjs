import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';
import { createWhisperMetal } from '../core/whisper-metal.mjs';
const catalog=JSON.parse(await readFile(new URL('../core/metal-catalog.json',import.meta.url)));
const bin=process.env.LOCALVOICE_WHISPER_BIN || resolve('.cache/metal-build/build/bin/whisper-cli');
const wav=await readFile('test-results/transcription-two-speakers.wav');
let offset=12,pcm;
while(offset+8<=wav.length){const length=wav.readUInt32LE(offset+4);if(wav.toString('ascii',offset,offset+4)==='data'){pcm=wav.subarray(offset+8,offset+8+length);break;}offset+=8+length+(length%2);}
assert.ok(pcm?.length);const audio=Float32Array.from({length:pcm.length/2},(_,i)=>pcm.readInt16LE(i*2)/32768);
for(const id of ['whisper-tiny-metal','whisper-small-metal']){
 const model=catalog.find(m=>m.id===id),dir=resolve('.cache/metal-models',id);
 assert.equal(createHash('sha256').update(await readFile(resolve(dir,model.files[0].path))).digest('hex'),model.files[0].hash);
 for(const device of ['cpu','gpu']){
  const runtime=await createWhisperMetal(dir,model,{device,binary:bin});const start=performance.now();
  try { const result=await runtime.transcribe(audio,16000,{timestamps:true});
   assert.equal(result.acceleration.provider,device==='gpu'?'metal':'cpu');
   assert.match(result.text.toLowerCase(),/letter/);assert.match(result.text.toLowerCase(),/painting/);assert.ok(result.chunks.length>=2);
   assert.ok(result.chunks.every(c=>c.timestamp[1]<=audio.length/16000 && c.timestamp[1]>c.timestamp[0]));
   console.log(JSON.stringify({model:id,device,seconds:((performance.now()-start)/1000).toFixed(2),text:result.text,segments:result.chunks.length,acceleration:result.acceleration}));
  }finally{runtime.dispose();}
 }
 const canceled=await createWhisperMetal(dir,model,{device:'gpu',binary:bin});const work=canceled.transcribe(audio,16000,{timestamps:true});const check=assert.rejects(work,{name:'AbortError'});setTimeout(()=>canceled.dispose(),30);await check;
}
console.log('METAL_REAL_OK');

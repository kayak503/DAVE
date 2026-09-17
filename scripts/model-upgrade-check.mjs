import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
const {SpeechEngine,catalog} = await import(new URL(process.argv.includes('--packaged') ? '../release/native/Local Voice.app/Contents/Resources/backend/core/engine.mjs' : '../core/engine.mjs', import.meta.url));
import {resampleAudio} from '../core/audio.mjs';
const engine=new SpeechEngine({modelDir:path.resolve('.cache/models')});
const wav=await fs.readFile('macos/Tests/Fixtures/speech.wav');
const floats=new Float32Array((wav.length-44)/2);
for(let i=0;i<floats.length;i++)floats[i]=wav.readInt16LE(44+i*2)/32768;
const audio=resampleAudio(floats,wav.readUInt32LE(24));
for(const id of ['whisper-medium','whisper-large-turbo']){
 const m=catalog.find(x=>x.id===id);
 assert.ok(m&&m.files.every(f=>f.size>0&&f.hash));
 if(process.argv.includes('--install'))await engine.installModel(id);
 const network=globalThis.fetch;globalThis.fetch=()=>{throw new Error('Inference attempted network access')};
 try{
 const result=await engine.transcribe({modelId:id,audio,sampleRate:16000,timestamps:true});
 assert.match(result.text.toLowerCase(),/garden/);assert.match(result.text.toLowerCase(),/notebooks/);
 assert.ok(result.chunks.length>0);assert.ok(result.chunks.every(x=>x.timestamp?.[0]>=0));
 console.log(id,JSON.stringify(result.text));
 }finally{globalThis.fetch=network;await engine.dispose();}
}
const reading = new SpeechEngine({modelDir:path.resolve('.cache/supertonic-check')});
const network = globalThis.fetch; globalThis.fetch=()=>{throw new Error('Reading inference attempted network access')};
try {
 for(const id of ['supertonic-2','supertonic-3']) {
  const list=await reading.listModels(); const model=list.find(x=>x.id===id);
  assert.ok(model.installed && model.voices.length===10);
  const result=await reading.synthesize({modelId:id,text:'The garden is quiet today.',voice:'M2'});
  assert.equal(result.sampleRate,44100);assert.ok(result.audio.some(x=>Math.abs(x)>0.01));
  console.log(id,'engine integration passed');
 }
}finally{globalThis.fetch=network;await reading.dispose();}
console.log('MODEL_UPGRADE_OK');

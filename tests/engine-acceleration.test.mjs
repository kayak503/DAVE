import test from 'node:test';
import assert from 'node:assert/strict';
import {SpeechEngine} from '../core/engine.mjs';
const audio=new Float32Array(1600).fill(.1);
function engine({original=false,cancel=false}={}){
 const e=new SpeechEngine({modelDir:'/unused-test-models'}),loads=[];
 e.installed=async m=>m.engine==='whisper-metal'||original;
 e.load=async(id,task,device)=>{loads.push({id,device});if(device==='gpu')return {transcribe:async()=>{if(cancel)e.epoch++;throw Error('CUDA driver unavailable');}};if(id.endsWith('-metal'))return {transcribe:async()=>({text:'CPU result',chunks:[],acceleration:{provider:'cpu'}})};return async()=>({text:'ONNX result'});};
 return {e,loads};
}
test('Automatic uses downloaded GPU weights on CPU when GPU cannot start and ONNX is absent',async()=>{
 const {e,loads}=engine();const r=await e.transcribe({modelId:'whisper-tiny',audio,sampleRate:16000,device:'auto'});
 assert.equal(r.text,'CPU result');assert.equal(r.acceleration.provider,'cpu');assert.equal(r.acceleration.requested,'auto');assert.match(r.acceleration.detail,/GPU unavailable/);assert.deepEqual(loads.map(x=>x.device),['gpu','cpu']);
});
test('Automatic retains installed ONNX fallback',async()=>{const {e}=engine({original:true});const r=await e.transcribe({modelId:'whisper-tiny',audio,sampleRate:16000,device:'auto'});assert.equal(r.text,'ONNX result');assert.equal(r.acceleration.provider,'cpu');});
test('Explicit GPU failure never silently retries CPU',async()=>{const {e,loads}=engine();await assert.rejects(e.transcribe({modelId:'whisper-tiny',audio,sampleRate:16000,device:'gpu'}),/CUDA driver/);assert.equal(loads.length,1);});
test('Cancelled GPU job never starts fallback work',async()=>{const {e,loads}=engine({cancel:true});await assert.rejects(e.transcribe({modelId:'whisper-tiny',audio,sampleRate:16000,device:'auto'}));assert.equal(loads.length,1);});

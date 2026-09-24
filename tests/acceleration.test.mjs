import test from 'node:test';
import assert from 'node:assert/strict';
import { SpeechEngine } from '../core/engine.mjs';
const audio = new Float32Array(160).fill(0.1);
function engine({cpu=true,gpu=true,fail=false,provider='metal'}={}) {
 const e=new SpeechEngine({modelDir:'/tmp/acceleration-unit'}), calls=[];
 e.installed=async m=>m.variantOf ? gpu : cpu;
 e.load=async(id,task,device)=>{calls.push({id,device}); if(id.endsWith('-metal')) return {transcribe:async()=>{if(fail)throw Error('Metal unavailable');return {text:'hello',acceleration:{provider,detail:provider}}}}; return async()=>({text:'hello CPU'});};
 return {e,calls};
}
const run=(e,device)=>e.transcribe({modelId:'whisper-tiny',audio,sampleRate:16000,device});
test('Automatic uses Metal companion and reports actual provider',async()=>{const {e,calls}=engine();assert.equal((await run(e,'auto')).acceleration.provider,'metal');assert.deepEqual(calls,[{id:'whisper-tiny-metal',device:'gpu'}]);});
test('Automatic CPU fallback states why; explicit GPU never silently falls back',async()=>{const {e}=engine({fail:true});assert.match((await run(e,'auto')).acceleration.detail,/CPU fallback/);await assert.rejects(run(e,'metal'),/Metal unavailable/);const f=engine({provider:'cpu'});await assert.rejects(run(f.e,'metal'),/could not start/);});
test('Missing companion remains CPU automatically and actionable error explicitly',async()=>{const {e}=engine({gpu:false});assert.equal((await run(e,'auto')).acceleration.provider,'cpu');await assert.rejects(run(e,'metal'),/Complete this model/);});
test('CPU selection cannot reuse GPU and supports companion-only installs',async()=>{const {e,calls}=engine();await run(e,'cpu');assert.equal(calls[0].device,'cpu');assert.equal(calls[0].id,'whisper-tiny');const f=engine({cpu:false,provider:'cpu'});await run(f.e,'cpu');assert.equal(f.calls[0].id,'whisper-tiny-metal');assert.equal(f.calls[0].device,'cpu');});
test('Cancellation cannot fall back or return a stale result',async()=>{const {e}=engine();e.load=async()=>({transcribe:async()=>{e.cancel();throw Error('interrupted');}});await assert.rejects(run(e,'auto'),/interrupted/);});
test('Unknown devices rejected before execution',async()=>{const {e,calls}=engine();await assert.rejects(run(e,'magic'),/Choose/);assert.equal(calls.length,0);});
test('Silence does not invoke Whisper or invent GPU activity',async()=>{const {e,calls}=engine();const r=await e.transcribe({modelId:'whisper-tiny',audio:new Float32Array(16000),sampleRate:16000,device:'metal'});assert.equal(r.text,'');assert.equal(r.acceleration.provider,'none');assert.equal(calls.length,0);});
test('Runtime cache includes processor, not only model ID',async()=>{const e=new SpeechEngine({modelDir:'/tmp/acceleration-cache-unit'});e.recover=async()=>{};e.installed=async()=>false;const runtime={};e.loaded={id:'whisper-tiny-metal',device:'gpu',runtime};assert.equal(await e.load('whisper-tiny-metal','stt','gpu'),runtime);await assert.rejects(e.load('whisper-tiny-metal','stt','cpu'),/Install or import/);});

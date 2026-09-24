import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, chmod, rm, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { accelerationFromDiagnostics, encodeWhisperWav, parseWhisperResult, createWhisperMetal, whisperProcessError } from '../core/whisper-metal.mjs';

test('Windows signing-policy failures explain model completion and trusted approval',()=>{
 assert.match(whisperProcessError(3236495362).message,/application control.*ONNX CPU fallback/);
 assert.match(whisperProcessError(-1058471934).message,/application control/);
 assert.match(whisperProcessError(3,'model failure').message,/code 3.*model failure/);
});

test('selected GPU UUID is isolated in the child process, not confused with an integrated adapter index',async()=>{
 const dir=await mkdtemp(join(tmpdir(),'dave-device-test-'));
 try{
  await writeFile(join(dir,'ggml-test.bin'),'fixture');
  const script=join(dir,'device.mjs');
  await writeFile(script,`import {writeFile} from 'node:fs/promises';if(process.env.CUDA_VISIBLE_DEVICES!=='GPU-aaaa')process.exit(5);const output=process.argv[process.argv.indexOf('-of')+1];await writeFile(output+'.json',JSON.stringify({transcription:[{text:'selected GPU',offsets:{from:0,to:1000}}]}));process.stderr.write('whisper_backend_init_gpu: using CUDA0 backend\\n');`);
  const runtime=await createWhisperMetal(dir,{files:[{path:'ggml-test.bin'}]},{gpu:'GPU-aaaa',binary:process.execPath,binaryArgs:[script]});
  try{const result=await runtime.transcribe(new Float32Array(16000),16000);assert.equal(result.acceleration.gpu,'GPU-aaaa');assert.equal(result.acceleration.provider,'cuda');}finally{runtime.dispose();}
  await assert.rejects(createWhisperMetal(dir,{},{gpu:'0; bad',binary:process.execPath}),/Invalid GPU/);
 }finally{await rm(dir,{recursive:true,force:true});}
});

test('reports effective backend, never equates compiled Metal support to actual use', () => {
  assert.equal(accelerationFromDiagnostics('Metal : EMBED_LIBRARY = 1', 'gpu').provider, 'cpu');
  assert.equal(accelerationFromDiagnostics('whisper_backend_init_gpu: using Metal backend', 'gpu').provider, 'metal');
  assert.equal(accelerationFromDiagnostics('whisper_backend_init_gpu: using Metal backend', 'cpu').provider, 'cpu');
});
test('validates audio and encodes a bounded 16-bit mono WAV', () => {
  const b = encodeWhisperWav(new Float32Array([-1,0,1]),16000);
  assert.equal(b.readInt16LE(44),-32768); assert.equal(b.readInt16LE(48),32767); assert.equal(b.readUInt32LE(40),6);
  for (const bad of [new Float32Array(), new Float32Array([NaN]), new Float32Array([Infinity]), []]) assert.throws(()=>encodeWhisperWav(bad,16000));
  assert.throws(()=>encodeWhisperWav(new Float32Array(4),48000));
});
test('parses, bounds and validates real segment timestamps', () => {
  assert.deepEqual(parseWhisperResult({transcription:[{text:' hello ',offsets:{from:100,to:2500}}]},2),{text:'hello',chunks:[{text:'hello',timestamp:[.1,2]}]});
  assert.throws(()=>parseWhisperResult({transcription:[{text:'x',offsets:{from:3,to:1}}]},2));
  assert.throws(()=>parseWhisperResult({},2));
});
test('five companion models use immutable revisions and SHA256 weights', async () => {
  const catalog=JSON.parse(await readFile(new URL('../core/metal-catalog.json',import.meta.url)));
  assert.equal(catalog.length,5);assert.equal(new Set(catalog.map(m=>m.variantOf)).size,5);
  for(const m of catalog){assert.match(m.revision,/^[a-f0-9]{40}$/);assert.equal(m.engine,'whisper-metal');assert.equal(m.files.length,1);assert.match(m.files[0].hash,/^[a-f0-9]{64}$/);assert.equal(m.files[0].algorithm,'sha256');assert.ok(m.files[0].size>70000000);}
});
test('dispose kills live subprocess, rejects canceled inference, prevents reuse', async () => {
  const dir=await mkdtemp(join(tmpdir(),'metal-cancel-test-'));
  try {
    await writeFile(join(dir,'ggml-test.bin'),'fixture');
    const bin=join(dir,'fake-runtime.mjs');
    await writeFile(bin,`#!${process.execPath}\nprocess.stderr.write('whisper_backend_init_gpu: using Metal backend\\n');setInterval(()=>{},1000);`);await chmod(bin,0o700);
    const runtime=await createWhisperMetal(dir,{files:[{path:'ggml-test.bin'}]},{device:'gpu',binary:process.execPath,binaryArgs:[bin]});
    const work=runtime.transcribe(new Float32Array(16000),16000);
    const check=assert.rejects(work,{name:'AbortError'});
    setTimeout(()=>runtime.dispose(),100);
    await check;
    await assert.rejects(runtime.transcribe(new Float32Array(16000),16000),/disposed/);
  } finally {await rm(dir,{recursive:true,force:true});}
});
test('aborted signal and invalid model fail before inference',async()=>{
  await assert.rejects(createWhisperMetal('/tmp',{files:[{path:'../ggml-test.bin'}]},{binary:'/bin/false'}),/Invalid/);
  await assert.rejects(createWhisperMetal('/tmp',{}, {device:'unknown'}),/Unknown/);
});
test('cancel rejects live work without permanently disposing the model', async () => {
  const dir=await mkdtemp(join(tmpdir(),'metal-reuse-test-'));
  try {
    await writeFile(join(dir,'ggml-test.bin'),'fixture');
    const bin=join(dir,'fake-runtime.mjs');
    await writeFile(bin,`#!${process.execPath}\nsetInterval(()=>{},1000);`);await chmod(bin,0o700);
    const runtime=await createWhisperMetal(dir,{files:[{path:'ggml-test.bin'}]},{device:'cpu',binary:process.execPath,binaryArgs:[bin]});
    try {
      for(let i=0;i<2;i++){
        const work=runtime.transcribe(new Float32Array(16000),16000);
        const check=assert.rejects(work,{name:'AbortError'});
        await assert.rejects(runtime.transcribe(new Float32Array(16000),16000),/already/);
        setTimeout(()=>runtime.cancel(),50); await check;
      }
    } finally {runtime.dispose();}
  } finally {await rm(dir,{recursive:true,force:true});}
});

test('Windows GPU claims require an initialized backend, not advertised hardware', () => {
  for (const log of ['ggml_vulkan: Found 1 Vulkan devices', 'CUDA : ARCHS = 750', 'ggml_cuda_init: found 1 CUDA devices']) assert.equal(accelerationFromDiagnostics(log, 'gpu').provider, 'cpu');
  for (const [log, provider] of [['whisper_backend_init_gpu: using Vulkan0 backend', 'vulkan'], ['whisper_backend_init_gpu: using Vulkan backend', 'vulkan'], ['whisper_backend_init_gpu: using CUDA0 backend', 'cuda']]) {
    assert.equal(accelerationFromDiagnostics(log, 'gpu').provider, provider);
    assert.equal(accelerationFromDiagnostics(log, 'cpu').provider, 'cpu');
  }
});

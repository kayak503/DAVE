import test from 'node:test';
import assert from 'node:assert/strict';
import { modelBundle, installBundle, removeBundle, describeBundles } from '../core/model-bundles.mjs';
import { parseNvidiaDevices, chooseGpu } from '../core/gpu-devices.mjs';

const catalog=[{id:'tiny',sizeMB:40},{id:'tiny-gpu',variantOf:'tiny',sizeMB:75},{id:'voice',sizeMB:80}];
test('one install includes CPU and GPU, resumes partial installs, and removal covers both',async()=>{
 const installed=new Set(['tiny-gpu']),calls=[];
 const engine={installed:async m=>installed.has(m.id),installModel:async id=>{calls.push(id);installed.add(id);},removeModel:async id=>installed.delete(id)};
 assert.deepEqual(modelBundle(catalog,'tiny-gpu').map(m=>m.id),['tiny','tiny-gpu']);
 await installBundle(engine,catalog,'tiny');assert.deepEqual(calls,['tiny']);
 await installBundle(engine,catalog,'tiny');assert.deepEqual(calls,['tiny']);
 await removeBundle(engine,catalog,'tiny');assert.equal(installed.size,0);
 assert.throws(()=>modelBundle(catalog,'untrusted'),/Unknown/);
});
test('GPU-only legacy installs are ready but incomplete, with combined download size',()=>{
 const models=describeBundles(catalog.map(m=>({...m,installed:m.id==='tiny-gpu'})));
 assert.equal(models[0].installed,true);assert.equal(models[0].cpuInstalled,false);assert.equal(models[0].bundleComplete,false);assert.equal(models[0].bundleSizeMB,115);
});
test('partial download failure preserves completed files and retries only missing files',async()=>{
 const installed=new Set();let fail=true;
 const engine={installed:async m=>installed.has(m.id),installModel:async id=>{if(id==='tiny-gpu'&&fail)throw Error('offline');installed.add(id);}};
 await assert.rejects(installBundle(engine,catalog,'tiny'),/offline/);assert.deepEqual([...installed],['tiny']);
 fail=false;await installBundle(engine,catalog,'tiny');assert.equal(installed.size,2);
});
test('automatic selects greatest dedicated memory; explicit selection uses stable UUID',()=>{
 const devices=parseNvidiaDevices('0, GPU-aaaa, NVIDIA Small, 4096\n1, GPU-bbbb, NVIDIA Large, 24576\ninvalid');
 assert.equal(chooseGpu(devices).id,'GPU-bbbb');assert.equal(chooseGpu(devices,'GPU-aaaa').index,0);
 assert.throws(()=>chooseGpu(devices,'GPU-cccc'),/unavailable/);assert.equal(chooseGpu([]),null);
});

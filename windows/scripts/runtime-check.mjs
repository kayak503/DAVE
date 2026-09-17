import assert from 'node:assert/strict';
import {mkdtemp,readFile,writeFile,rm} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {createInterface} from 'node:readline';
if(process.platform!=='win32')throw Error('Windows GPU validation requires Windows hardware; a macOS cross-build cannot satisfy this check.');
const root=path.resolve(import.meta.dirname,'../..'),app=path.join(root,'release/windows/Local Voice');
const modelDirectory=process.env.LOCALVOICE_MODELS??path.join(process.env.LOCALAPPDATA??path.join(os.homedir(),'AppData/Local'),'Local Voice/models');
try { const manifest=JSON.parse(await readFile(path.join(modelDirectory,'whisper-tiny-metal/installed.json'),'utf8'));assert.equal(manifest.id,'whisper-tiny-metal'); }
catch { throw Error('Download Whisper Tiny GPU files in Local Voice first, or set LOCALVOICE_MODELS to a valid managed model folder containing whisper-tiny-metal/installed.json. Raw GGML files alone are not an installed model.'); }
const session=await mkdtemp(path.join(os.tmpdir(),'localvoice-gpu-test-'));
const wav=await readFile(path.join(root,'macos/Tests/Fixtures/speech.wav'));
assert.equal(wav.toString('ascii',0,4),'RIFF');let position=12,data,rate,channels,bits;
while(position+8<=wav.length){const id=wav.toString('ascii',position,position+4),size=wav.readUInt32LE(position+4),start=position+8;if(id==='fmt '){assert.equal(wav.readUInt16LE(start),1);channels=wav.readUInt16LE(start+2);rate=wav.readUInt32LE(start+4);bits=wav.readUInt16LE(start+14);}if(id==='data')data=wav.subarray(start,start+size);position=start+size+(size%2);}
assert.ok(rate>=16000);assert.equal(channels,1);assert.equal(bits,16);assert.ok(data);
const count=Math.floor(data.length/2*16000/rate),pcm=Buffer.alloc(count*4);for(let i=0;i<count;i++){const offset=i*rate/16000,left=Math.floor(offset),right=Math.min(data.length/2-1,left+1),fraction=offset-left;pcm.writeFloatLE((data.readInt16LE(left*2)*(1-fraction)+data.readInt16LE(right*2)*fraction)/32768,i*4);}const file=path.join(session,'speech.f32');await writeFile(file,pcm);
const child=spawn(path.join(app,'runtime/node.exe'),[path.join(app,'backend/service.mjs')],{env:{...process.env,LOCALVOICE_SESSION:session,LOCALVOICE_MODELS:modelDirectory,LOCALVOICE_WHISPER_BIN:path.join(app,'runtime/cuda/whisper-cli.exe'),LOCALVOICE_WHISPER_CPU_BIN:path.join(app,'runtime/cpu/whisper-cli.exe')},stdio:['pipe','pipe','pipe'],windowsHide:true});
let stderr='';child.stderr.on('data',d=>stderr+=d);const lines=createInterface({input:child.stdout});const timeout=setTimeout(()=>child.kill(),180000);
try{const response=new Promise((resolve,reject)=>{lines.on('line',line=>{try{const r=JSON.parse(line);if(r.id==='gpu-check')resolve(r);}catch(e){reject(e);}});child.on('error',reject);child.on('exit',code=>reject(Error(`Backend exited ${code}: ${stderr}`)));});child.stdin.write(JSON.stringify({id:'gpu-check',command:'transcribe',model:'whisper-tiny',device:'gpu',path:file})+'\n');const r=await response;assert.equal(r.error,undefined);assert.match(r.result.text,/garden|notebooks|kitchen/i);assert.ok(['cuda','vulkan'].includes(r.result.acceleration?.provider),JSON.stringify(r));console.log('WINDOWS_RUNTIME_GPU_OK '+JSON.stringify(r.result));}finally{clearTimeout(timeout);child.stdin.end();child.kill();lines.close();await rm(session,{recursive:true,force:true});}

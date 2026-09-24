import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { mkdtemp, rm, writeFile, readFile, unlink } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';

const root=path.resolve(import.meta.dirname,'../..');
const packaged=process.argv.includes('--packaged');
const app=path.join(root,process.argv.includes('--parity')?'release/windows-parity/DAVE':'release/windows/DAVE');
const session=await mkdtemp(path.join(os.tmpdir(),'dave-reading-check-'));
const child=spawn(packaged?path.join(app,'runtime/node.exe'):process.execPath,[path.join(packaged?app:root,packaged?'backend/service.mjs':'macos/backend/service.mjs')],{
 env:{...process.env,LOCALVOICE_SESSION:session,LOCALVOICE_MODELS:process.env.LOCALVOICE_MODELS??path.join(process.env.LOCALAPPDATA,'Local Voice/models')},stdio:['pipe','pipe','pipe'],windowsHide:true,
});
let sequence=0,diagnostics='';const pending=new Map();
child.stderr.on('data',bytes=>{diagnostics=(diagnostics+bytes).slice(-4000);});
const lines=createInterface({input:child.stdout});
lines.on('line',line=>{const r=JSON.parse(line);const task=pending.get(r.id);if(task){pending.delete(r.id);r.error?task.reject(Error(r.error)):task.resolve(r.result);}});
const exited=new Promise(resolve=>child.once('exit',code=>{for(const task of pending.values())task.reject(Error(`Service exited ${code}: ${diagnostics}`));resolve();}));
child.on('error',error=>{for(const task of pending.values())task.reject(error);});
function request(command,values={}){return new Promise((resolve,reject)=>{const id=String(++sequence);pending.set(id,{resolve,reject});child.stdin.write(JSON.stringify({id,command,...values})+'\n');});}
function batch(commands){const messages=[];const tasks=commands.map(command=>new Promise((resolve,reject)=>{const id=String(++sequence);pending.set(id,{resolve,reject});messages.push(JSON.stringify({id,...command}));}));child.stdin.write(messages.join('\n')+'\n');return tasks;}
const timeout=setTimeout(()=>child.kill(),120000);
const input={model:'kokoro-q8',voice:'af_heart',text:'The garden is quiet today. Please bring three blue notebooks to the kitchen.'};
const results=[];
try{
 for(let run=0;run<3;run++){
  const started=performance.now();const result=await request('synthesize',input);
  results.push({run:run+1,seconds:(performance.now()-started)/1000,cached:result.cached});
  assert.equal(result.cached,run>0);const wav=await readFile(result.path);assert.equal(wav.toString('ascii',0,4),'RIFF');assert.ok(wav.length>48000);
  await request('cancel-work');
 }
 // Submit one protocol batch so cancellation deterministically precedes execution.
 const work=batch([{command:'synthesize',...input,text:'A different sentence to exercise cancellation.'},{command:'synthesize',...input},{command:'cancel-work'}]);
 const first=work[0].then(()=>({ok:true}),error=>({error}));
 const queued=work[1].then(()=>({ok:true}),error=>({error}));
 await work[2];
 for(const outcome of await Promise.all([first,queued]))assert.match(outcome.error?.message??'',/cancel/i);
 const replay=await request('synthesize',input);assert.equal(replay.cached,true);
 // Mac playback deletes completed files: the service must regenerate instead of returning a stale path.
 await unlink(replay.path);assert.equal((await request('synthesize',input)).cached,false);
 await writeFile(path.join(root,'test-results/reading-service-benchmark.json'),JSON.stringify(results,null,2));
 console.log('WINDOWS_READING_SERVICE_OK '+JSON.stringify(results));
}finally{clearTimeout(timeout);child.stdin.end();await exited;lines.close();await rm(session,{recursive:true,force:true});}


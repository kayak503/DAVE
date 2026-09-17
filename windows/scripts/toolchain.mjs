import {readFile,mkdir,writeFile,access,rm} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {spawnSync} from 'node:child_process';
import path from 'node:path';
export const root=path.resolve(import.meta.dirname,'../..');
export const cache=path.join(root,'.cache/windows-toolchain');
export const pins=JSON.parse(await readFile(path.join(root,'windows/toolchain/pins.json')));
export function run(bin,args,options={}) {const r=spawnSync(bin,args,{stdio:'inherit',cwd:root,...options});if(r.status!==0)throw Error(`${bin} failed (${r.status}): ${r.error?.message??''}`);}
export async function exists(p){try{await access(p);return true;}catch{return false;}}
export async function download(pin){await mkdir(cache,{recursive:true});const target=path.join(cache,path.basename(new URL(pin.url).pathname));const algorithm=pin.sha512?'sha512':'sha256',expected=pin[algorithm];if(await exists(target)){if(createHash(algorithm).update(await readFile(target)).digest('hex')===expected)return target;await rm(target);}
 run(process.platform==='win32'?'curl.exe':'curl',['--fail','--location','--retry','3',pin.url,'--output',target+'.part']); const data=await readFile(target+'.part');if(createHash(algorithm).update(data).digest('hex')!==expected)throw Error(`Checksum mismatch: ${pin.url}`);await writeFile(target,data);await rm(target+'.part');return target;}
export async function unzip(archive,destination){await mkdir(destination,{recursive:true});run('tar',['-xf',archive,'-C',destination]);}
export async function dotnet(){if(process.env.LOCALVOICE_DOTNET)return process.env.LOCALVOICE_DOTNET;if(process.platform==='win32')return 'dotnet';if(process.platform!=='darwin'||process.arch!=='arm64')throw Error('Set LOCALVOICE_DOTNET to a .NET 8 SDK executable.');const dir=path.join(cache,'dotnet');const bin=path.join(dir,'dotnet');if(!await exists(bin))await unzip(await download(pins.sdk),dir);return bin;}
if(process.argv.includes('--setup')){console.log(await dotnet());await Promise.all([download(pins.node),download(pins.whisperGPU),download(pins.whisperCPU)]);console.log('WINDOWS_TOOLCHAIN_READY');}

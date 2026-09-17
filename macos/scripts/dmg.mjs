import {spawnSync} from 'node:child_process';
import {mkdtemp, readFile, symlink, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
if(process.platform!=='darwin')throw Error('DMG packaging requires macOS');
const {version}=JSON.parse(await readFile('package.json','utf8'));
const app=path.resolve('release/native/DAVE.app');
const staging=await mkdtemp(path.join(tmpdir(),'localvoice-dmg-'));
const output=path.resolve(`release/DAVE-${version}-macos-${process.arch}.dmg`);
function run(bin,args){const r=spawnSync(bin,args,{stdio:'inherit'});if(r.status!==0)throw Error(`${bin} failed`);}
try{
 run('codesign',['--verify','--deep','--strict',app]);
 run('ditto',[app,path.join(staging,'DAVE.app')]);
 await symlink('/Applications',path.join(staging,'Applications'));
 run('hdiutil',['create','-volname',`DAVE ${version}`,'-srcfolder',staging,'-ov','-format','UDZO',output]);
 run('hdiutil',['verify',output]);
 console.log('NATIVE_DMG_OK '+output);
}finally{await rm(staging,{recursive:true,force:true});}

import {spawnSync} from 'node:child_process';
import {mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
const dir=mkdtempSync(join(tmpdir(),'native-interactions-'));
try {
 for(const [bin,args] of [['xcrun',['swiftc','-swift-version','5','-module-cache-path','.cache/native-build/modules','macos/Sources/InteractionState.swift','macos/Tests/InteractionTests.swift','-o',join(dir,'tests')]],[join(dir,'tests'),[]]]) {
  const result=spawnSync(bin,args,{encoding:'utf8',timeout:120000});
  process.stdout.write(result.stdout||'');process.stderr.write(result.stderr||'');
  if(result.status!==0)throw result.error||new Error(`${bin} exited ${result.status}`);
 }
}finally{rmSync(dir,{recursive:true,force:true});}

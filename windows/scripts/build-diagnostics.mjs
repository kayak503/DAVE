import {spawnSync} from 'node:child_process';

export function applicationControlFailure(events, workspace) {
 const normalize=value=>value.replaceAll('\\','/').toLowerCase();
 const prefix=normalize(workspace).replace(/\/$/,'')+'/';
 const event=events.find(event=>/0x800711c7/i.test(event.Message??'') &&
  /Application: UITests\.exe/i.test(event.Message??'') && normalize(event.Message).includes(prefix));
 if(!event)return null;
 return 'Windows Application Control blocked the rebuilt DAVE UI test (0x800711C7). '+
  'The SDK was found; changing the Node command will not resolve this. '+
  'The blocked binaries need a signature trusted by the active policy. '+
  'Check Windows Security > App & browser control > Smart App Control and the CodeIntegrity event log. '+
  'The existing release package was preserved.\n\n'+event.Message;
}

// Only inspect events from this test run. A generic CLR crash is not evidence of a policy block.
export function diagnoseUIFailure(startedAt, workspace) {
 if(process.platform!=='win32')return null;
 const result=spawnSync('powershell.exe',['-NoProfile','-NonInteractive','-Command',
  "$ErrorActionPreference='Stop'; @(Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='.NET Runtime'; StartTime=[DateTime]::Parse($env:DAVE_DIAGNOSTIC_START)} -ErrorAction SilentlyContinue | Select-Object -First 20 Message) | ConvertTo-Json -Compress"],
 {encoding:'utf8',timeout:10000,windowsHide:true,env:{...process.env,DAVE_DIAGNOSTIC_START:startedAt.toISOString()}});
 if(result.status!==0 || !result.stdout?.trim())return null;
 try{const events=JSON.parse(result.stdout);return applicationControlFailure(Array.isArray(events)?events:[events],workspace);}catch{return null;}
}

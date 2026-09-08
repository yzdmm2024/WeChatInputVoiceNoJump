// 最后确认：列出 /usr/lib 与 cryptex usr/lib，找 TweakInject/dpkg/包管理器
'use strict';
function run() {
  const fm = ObjC.classes.NSFileManager.defaultManager();
  const out = {};
  function exist(p){ return fm.fileExistsAtPath_(ObjC.classes.NSString.stringWithString_(p)); }
  function listdir(p){
    const u = ObjC.classes.NSString.stringWithString_(p);
    const e = Memory.alloc(8);
    const arr = fm.contentsOfDirectoryAtPath_error_(u, e);
    if(!arr) return null;
    const r = []; for(let i=0;i<arr.count();i++) r.push(arr.objectAtIndex_(i).toString());
    return r;
  }
  const pre = '/private/preboot/41A3D48C1AD4F83F1189A8BF097F0AE11FA8E3ACFCB3605DA3F61B137AFEAA7E38AC0602FD209A79F03C2C5CB5D6AFD3';
  out.usr_lib = listdir('/usr/lib');
  out.cryptex_usr_lib = listdir(pre + '/usr/lib');
  out.cryptex_usr_lib_ti = listdir(pre + '/usr/lib/TweakInject');
  out.cryptex_usr_bin = listdir(pre + '/usr/bin');
  out.usr_bin_dpkg = exist('/usr/bin/dpkg');
  out.usr_bin_apt = exist('/usr/bin/apt');
  out.usr_bin_sudo = exist('/usr/bin/sudo');
  // 包管理器 APP
  out.apps_varjb = listdir('/var/jb/Applications');
  out.apps_root = listdir('/Applications');
  // /var/mobile/Library 里有没有 TweakInject / Cydia / Sileo 痕迹
  out.mobile_lib = listdir('/var/mobile/Library');
  console.log('DIAG6 ' + JSON.stringify(out, null, 2));
}
run();

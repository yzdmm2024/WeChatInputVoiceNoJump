// 最终确认：stat() 交叉验证 + 列 cryptex usr/bin、usr/lib、/ 顶层、/private 顶层
'use strict';
function run() {
  const fm = ObjC.classes.NSFileManager.defaultManager();
  const out = {};
  const stat = Module.findExportByName(null, 'stat64');
  const st = new NativeFunction(stat, 'int', ['pointer','pointer']);
  function st_exists(p){ const ps = Memory.allocUtf8String(p); const buf = Memory.alloc(128); return st(ps, buf) === 0; }
  function listdir(p){
    const u = ObjC.classes.NSString.stringWithString_(p);
    const e = Memory.alloc(8);
    const arr = fm.contentsOfDirectoryAtPath_error_(u, e);
    if(!arr) return null;
    const r = []; for(let i=0;i<arr.count();i++) r.push(arr.objectAtIndex_(i).toString());
    return r;
  }
  const pre = '/private/preboot/41A3D48C1AD4F83F1189A8BF097F0AE11FA8E3ACFCB3605DA3F61B137AFEAA7E38AC0602FD209A79F03C2C5CB5D6AFD3';
  out.stat_varjb = st_exists('/var/jb');
  out.stat_varjb_ti = st_exists('/var/jb/usr/lib/TweakInject');
  out.stat_dpkg_usrbin = st_exists('/usr/bin/dpkg');
  out.stat_dpkg_varjb = st_exists('/var/jb/usr/bin/dpkg');
  out.stat_pl = st_exists('/var/jb/Library/PreferenceLoader/Preferences');
  out.stat_sileo = st_exists('/var/jb/Applications/Sileo.app');
  out.stat_zebra = st_exists('/var/jb/Applications/Zebra.app');
  out.stat_ellekit = st_exists('/var/jb/usr/lib/libellekit.dylib');
  // 列 cryptex 关键目录
  out.cryptex_usr = listdir(pre + '/usr');
  out.cryptex_usr_bin = listdir(pre + '/usr/bin');
  out.cryptex_usr_lib = listdir(pre + '/usr/lib');
  out.cryptex_lib = listdir(pre + '/Library');
  out.root_top = listdir('/');
  out.private_top = listdir('/private');
  console.log('DIAG7 ' + JSON.stringify(out, null, 2));
}
run();

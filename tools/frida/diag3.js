// 探出 relaxin「隐根」的真实越狱根前缀：逐路径探测已知标志/目录
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
  const cand = [
    '/var/jb','/var/sileo','/private/preboot','/','/usr/lib/TweakInject',
    '/Library/MobileSubstrate/DynamicLibraries','/var/jb/Library/MobileSubstrate/DynamicLibraries',
    '/var/jb/usr/lib/TweakInject','/var/jb/Library/PreferenceLoader','/var/jb/Library/PreferenceBundles',
    '/Library/PreferenceLoader/Preferences','/Library/PreferenceBundles',
    '/Applications/Sileo.app','/var/jb/Applications/Sileo.app',
    '/Applications/Zebra.app','/var/jb/Applications/Zebra.app'
  ];
  out.exists = {};
  for (const c of cand) out.exists[c] = exist(c);

  // 越狱标志文件(各 JB 不同)
  out.markers = {};
  for (const m of ['.bootstrapped','.installed_dopamine','.installed_ellekit','/.relaxin',
                   '/var/jb/.installed_dopamine','/var/jb/.bootstrapped','private/var/jb',
                   '/var/lib/dpkg/info','/var/jb/var/lib/dpkg/info','/var/lib/dpkg/status']) {
    out.markers[m] = exist(m);
  }

  // dpkg 数据库在哪?
  out.dpkg_info_var = listdir('/var/lib/dpkg/info');
  out.dpkg_info_jb  = listdir('/var/jb/var/lib/dpkg/info');

  // TweakInject 真实位置(哪个前缀下有 dylib)
  out.ti_varjb   = listdir('/var/jb/usr/lib/TweakInject');
  out.ti_usr     = listdir('/usr/lib/TweakInject');
  out.ti_varjb2  = listdir('/var/jb/Library/TweakInject');

  // PreferenceLoader / Cephei 真实位置(多种前缀)
  out.pl_varjb   = listdir('/var/jb/Library/PreferenceLoader/Preferences');
  out.pl_usr     = listdir('/Library/PreferenceLoader/Preferences');
  out.pl_preboot = listdir('/private/preboot/Library/PreferenceLoader/Preferences');

  console.log('DIAG3 ' + JSON.stringify(out, null, 2));
}
run();

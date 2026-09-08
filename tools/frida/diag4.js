// 进入 /private/preboot 找真实 JB 根，并定位 TweakInject / PreferenceLoader / dpkg
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
  out.preboot = listdir('/private/preboot');
  // 对 preboot 下每个子目录探 JB 标志
  const roots = [];
  if (out.preboot) {
    for (const sub of out.preboot) {
      const base = '/private/preboot/' + sub;
      const cand = [
        base + '/jb',
        base + '/procursus',
        base,
      ];
      for (const c of cand) {
        if (exist(c + '/usr/lib/TweakInject') || exist(c + '/Library/PreferenceLoader') || exist(c + '/var/lib/dpkg/info')) {
          roots.push(c);
        }
      }
    }
  }
  out.possible_roots = roots;
  // 对找到的根，列关键目录
  out.details = {};
  for (const r of roots) {
    out.details[r] = {
      tweakinject: listdir(r + '/usr/lib/TweakInject'),
      pl_prefs: listdir(r + '/Library/PreferenceLoader/Preferences'),
      pl_bundles: listdir(r + '/Library/PreferenceBundles'),
      dpkg_info: listdir(r + '/var/lib/dpkg/info'),
      msub: listdir(r + '/Library/MobileSubstrate/DynamicLibraries'),
    };
  }
  // 顺便直接确认 /var/jb 是不是某个根的软链(列 /var 看 jb)
  out.var_top = listdir('/var');
  console.log('DIAG4 ' + JSON.stringify(out, null, 2));
}
run();

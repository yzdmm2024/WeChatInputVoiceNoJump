// 进入 preboot UUID 目录，定位真实 TweakInject / PreferenceLoader / dpkg 根
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
  const root = '/private/preboot/41A3D48C1AD4F83F1189A8BF097F0AE11FA8E3ACFCB3605DA3F61B137AFEAA7E38AC0602FD209A79F03C2C5CB5D6AFD3';
  out.root_top = listdir(root);
  // 常见子目录
  const subs = ['jb','procursus','.','/'];
  const bases = [root, root+'/jb', root+'/procursus'];
  out.found = {};
  for (const b of bases) {
    out.found[b] = {
      tweakinject: listdir(b+'/usr/lib/TweakInject'),
      pl_prefs: listdir(b+'/Library/PreferenceLoader/Preferences'),
      pl_bundles: listdir(b+'/Library/PreferenceBundles'),
      dpkg_info: listdir(b+'/var/lib/dpkg/info'),
      msub: listdir(b+'/Library/MobileSubstrate/DynamicLibraries'),
      lib_top: listdir(b+'/Library'),
    };
  }
  // 直接验证我们未来要写的目标路径(若根=root 本身)
  out.our_target_exists = {
    tweak: exist(root+'/usr/lib/TweakInject/WxKeyboardNoJump.dylib'),
    entry: exist(root+'/Library/PreferenceLoader/Preferences/WxKeyboardNoJump.plist'),
    bundle: exist(root+'/Library/PreferenceBundles/WxKeyboardNoJumpPrefs.bundle'),
  };
  console.log('DIAG5 ' + JSON.stringify(out, null, 2));
}
run();

// 诊断「设置面板不出现」：从 SpringBoard 读设备文件系统，确认文件落地与 PreferenceLoader 状态
'use strict';
function run() {
  const fm = ObjC.classes.NSFileManager.defaultManager();
  const out = {};
  function exist(p){ const u = ObjC.classes.NSString.stringWithString_(p); return fm.fileExistsAtPath_(u); }
  function read(p){
    const u = ObjC.classes.NSString.stringWithString_(p);
    if(!fm.fileExistsAtPath_(u)) return null;
    const d = ObjC.classes.NSData.dataWithContentsOfFile_(u);
    if(!d) return null;
    const b = d.bytes(); const n = d.length();
    const a = [];
    for(let i=0;i<n;i++) a.push(b.add(i).readU8());
    return Buffer.from(a).toString('latin1');
  }
  function listdir(p){
    const u = ObjC.classes.NSString.stringWithString_(p);
    const e = Memory.alloc(8);
    const arr = fm.contentsOfDirectoryAtPath_error_(u, e);
    if(!arr) return null;
    const r = [];
    const cnt = arr.count();
    for(let i=0;i<cnt;i++){ r.push(arr.objectAtIndex_(i).toString()); }
    return r;
  }

  // 1) 我们的文件是否落地
  out.entry_plist_exists = exist('/var/jb/Library/PreferenceLoader/Preferences/WxKeyboardNoJump.plist');
  out.bundle_dir_exists  = exist('/var/jb/Library/PreferenceBundles/WxKeyboardNoJumpPrefs.bundle');
  out.bundle_listing     = listdir('/var/jb/Library/PreferenceBundles/WxKeyboardNoJumpPrefs.bundle');
  out.tweak_dylib_exists = exist('/var/jb/usr/lib/TweakInject/WxKeyboardNoJump.dylib');
  out.tweak_plist_exists = exist('/var/jb/usr/lib/TweakInject/WxKeyboardNoJump.plist');

  // 2) PreferenceLoader 是否存在(多种可能位置)
  out.pl_prefs_dir = listdir('/var/jb/Library/PreferenceLoader/Preferences');
  out.pl_bundles_dir = listdir('/var/jb/Library/PreferenceBundles');
  out.pl_dylib_msub  = exist('/var/jb/Library/MobileSubstrate/DynamicLibraries/PreferenceLoader.dylib');
  out.pl_dylib_inject= exist('/var/jb/usr/lib/TweakInject/PreferenceLoader.dylib');
  out.pl_dylib_elle  = exist('/var/jb/usr/lib/TweakInject/libpreferenceloader.dylib');

  // 3) dpkg 是否已登记 preferenceloader 包(判断依赖是否满足)
  out.dpkg_pl_msub = exist('/var/jb/var/lib/dpkg/info/preferenceloader.list');
  out.dpkg_pl_root = exist('/var/lib/dpkg/info/preferenceloader.list');

  // 4) 读我们自己的 entry / Info / Root 内容(确认设备上确实是正确版本)
  out.our_entry   = read('/var/jb/Library/PreferenceLoader/Preferences/WxKeyboardNoJump.plist');
  out.our_info    = read('/var/jb/Library/PreferenceBundles/WxKeyboardNoJumpPrefs.bundle/Info.plist');
  out.our_root    = read('/var/jb/Library/PreferenceBundles/WxKeyboardNoJumpPrefs.bundle/Root.plist');
  out.our_exec    = exist('/var/jb/Library/PreferenceBundles/WxKeyboardNoJumpPrefs.bundle/WxKeyboardNoJumpPrefs');

  console.log('DIAG ' + JSON.stringify(out, null, 2));
}
run();

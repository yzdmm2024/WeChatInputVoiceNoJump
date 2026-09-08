// 测绘设备偏好子系统：确认 tweak 注入是否正常、是否有任何 pref loader、bundle 实际位置
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
  // 注入目录(确认其它 tweak 是否在此、我们的 dylib 路径对不对)
  out.tweakinject_list = listdir('/var/jb/usr/lib/TweakInject');
  // /var/jb/Library 顶层，看有没有 PreferenceLoader / PreferenceBundles / Cephei 等
  out.jb_library_top = listdir('/var/jb/Library');
  // 非 jb 传统路径(某些 rootless 会 symlink)
  out.nonjb_pl_prefs = listdir('/Library/PreferenceLoader/Preferences');
  out.nonjb_pl_bundles = listdir('/Library/PreferenceBundles');
  // Cephei(常作 pref loader 替代/依赖)
  out.cephei_prefs = exist('/var/jb/Library/PreferenceLoader/Preferences/WSPreferences.plist');
  out.cephei_bundle = exist('/var/jb/Library/PreferenceBundles/WSPhotosPreferences.bundle'); // 随便一个已知 ceph 包不存在则 null
  out.cephei_framework = exist('/var/jb/Library/Frameworks/Cephei.framework');
  // 系统自带 PreferenceBundles(若有第三方 loader 用此目录)
  out.sys_pref_bundles = listdir('/System/Library/PreferenceBundles');
  // 是否有 Sileo/Zebra(用户可装包的来源)
  out.sileo = exist('/var/jb/Applications/Sileo.app');
  out.zebra = exist('/var/jb/Applications/Zebra.app');
  out.sileo_root = exist('/Applications/Sileo.app');
  out.zebra_root = exist('/Applications/Zebra.app');
  console.log('DIAG2 ' + JSON.stringify(out, null, 2));
}
run();

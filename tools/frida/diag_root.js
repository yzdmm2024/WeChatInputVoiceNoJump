// 从 root 进程(launchd)读文件系统，排除 SpringBoard 沙盒误报；定位真实 JB 根
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
  out.pid = Process.id;
  out.uid = new NativeFunction(Module.findExportByName(null,'getuid'),'int',[]);
  const probes = [
    '/var/jb','/var/jb/usr/lib/TweakInject','/var/jb/Library/PreferenceLoader/Preferences',
    '/var/jb/Library/PreferenceBundles','/var/jb/var/lib/dpkg/info',
    '/Library/MobileSubstrate/DynamicLibraries','/Library/PreferenceLoader/Preferences',
    '/Library/PreferenceBundles','/var/lib/dpkg/info','/var/lib/dpkg/status',
    '/usr/lib/TweakInject','/private/preboot/41A3D48C1AD4F83F1189A8BF097F0AE11FA8E3ACFCB3605DA3F61B137AFEAA7E38AC0602FD209A79F03C2C5CB5D6AFD3/usr/lib/TweakInject'
  ];
  out.exist = {};
  for (const p of probes) out.exist[p] = exist(p);
  out.ti = listdir('/var/jb/usr/lib/TweakInject');
  out.pl = listdir('/var/jb/Library/PreferenceLoader/Preferences');
  out.bundles = listdir('/var/jb/Library/PreferenceBundles');
  out.dpkg = listdir('/var/jb/var/lib/dpkg/info');
  console.log('DIAGROOT ' + JSON.stringify(out, null, 2));
}
run();

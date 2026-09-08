// 用 stat() 系统调用交叉验证关键路径(绕过 NSFileManager 可能的封装)
'use strict';
function run() {
  const stat = new NativeFunction(Module.findExportByName(null, 'stat'), 'int', ['pointer','pointer']);
  const stat64 = Module.findExportByName(null, 'stat64');
  const st = stat64 ? new NativeFunction(stat64, 'int', ['pointer','pointer']) : stat;
  function st_exists(p){
    const ps = Memory.allocUtf8String(p);
    const buf = Memory.alloc(128);
    const r = st(ps, buf);
    return r === 0;
  }
  const paths = [
    '/var/jb','/var/jb/usr/lib/TweakInject','/var/jb/usr/lib/TweakInject/WxKeyboardNoJump.dylib',
    '/var/jb/Library/PreferenceLoader/Preferences','/var/jb/Library/PreferenceBundles',
    '/usr/bin/dpkg','/usr/bin/apt','/usr/bin/sudo',
    '/var/jb/Applications/Sileo.app','/Applications/Sileo.app','/Applications/Zebra.app',
    '/private/preboot/41A3D48C1AD4F83F1189A8BF097F0AE11FA8E3ACFCB3605DA3F61B137AFEAA7E38AC0602FD209A79F03C2C5CB5D6AFD3/jb'
  ];
  const out = {};
  for (const p of paths) out[p] = st_exists(p);
  console.log('STAT ' + JSON.stringify(out, null, 2));
}
run();

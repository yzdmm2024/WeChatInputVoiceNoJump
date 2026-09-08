// verify_panel.js — 在设备上直接 dlopen 设置面板 bundle，复刻 PreferenceLoader 的加载行为，
// 报告：能否加载 / 报错 / 控制器类是否存在 / cpusubtype 是否为 arm64e / 已链接的框架。
// 由 verify_panel.py(frida) 注入到 SpringBoard 进程执行。
var BUNDLE = "/var/jb/Library/PreferenceBundles/WxKbNoJumpPrefs.bundle/WxKbNoJumpPrefs";

var dlopen = new NativeFunction(Module.findExportByName(null, 'dlopen'), 'pointer', ['pointer', 'int']);
var dlerror = new NativeFunction(Module.findExportByName(null, 'dlerror'), 'pointer', []);

console.log("[VERIFY] 目标: " + BUNDLE);

// 1) 解析二进制头：cpusubtype + LC_LOAD_DYLIB
var data = ObjC.classes.NSData.dataWithContentsOfFile_(BUNDLE);
if (!data) {
  console.log("[VERIFY] 文件不存在！先确认 deb 已安装到 /var/jb/...");
} else {
  var bytes = data.bytes();
  var ncmds = bytes.add(16).readU32();
  var cs = bytes.add(4).readU32();
  console.log("[CPUSUBTYPE] 0x" + cs.toString(16) + (cs === 0x2 ? " (arm64e ✓)" : " (非 arm64e ✗)"));
  var off = 32;
  for (var i = 0; i < ncmds; i++) {
    var cmd = bytes.add(off).readU32();
    var sz = bytes.add(off + 4).readU32();
    if (cmd === 0x1c) {
      var nmoff = bytes.add(off + 8).readU32();
      console.log("[LC_LOAD_DYLIB] " + bytes.add(off + nmoff).readUtf8String());
    }
    off += sz;
  }
  // 2) 实际 dlopen（与 PreferenceLoader 等价）
  var p = Memory.allocUtf8String(BUNDLE);
  var h = dlopen(p, 1); // RTLD_LAZY，和 PreferenceLoader 默认行为一致
  if (h.isNull()) {
    console.log("[DLOPEN] FAILED: " + dlerror().readUtf8String());
    console.log("[VERIFY] 结论: 面板仍会报『已损坏或丢失必要的资源』");
  } else {
    console.log("[DLOPEN] OK (handle=" + h + ")");
    var cls = ObjC.classes.WxKbNoJumpSettingsController;
    console.log("[OBJC] WxKbNoJumpSettingsController = " + (cls ? "present ✓" : "absent ✗"));
    console.log("[VERIFY] 结论: 二进制可加载，设置-设置里应能正常进面板");
  }
}

'use strict';
function main() {
  console.log("[INJ] start");
  try {
    const base = "/private/var/containers/Bundle/Application/";
    const fm = ObjC.classes.NSFileManager.defaultManager();
    const uuids = fm.contentsOfDirectoryAtPath_error_(base, ptr(0));
    if (!uuids) { console.log("[INJ] 列 UUID 目录失败（无权限？）"); return; }
    let appexPath = null, mainPath = null;
    for (let i = 0; i < uuids.count(); i++) {
      const u = uuids.objectAtIndex_(i).toString();
      const d = base + u + "/wxkb.app";
      if (fm.fileExistsAtPath_(d + "/PlugIns/wxkb_plugin.appex/wxkb_plugin"))
        appexPath = d + "/PlugIns/wxkb_plugin.appex/wxkb_plugin";
      if (fm.fileExistsAtPath_(d + "/wxkb"))
        mainPath = d + "/wxkb";
      if (appexPath && mainPath) break;
    }
    console.log("[INJ] appex=" + appexPath);
    console.log("[INJ] main =" + mainPath);

    function hasDylib(path) {
      if (!path) return null;
      const data = ObjC.classes.NSData.dataWithContentsOfFile_(path);
      if (!data) return null;
      let found = false;
      try {
        Memory.scan(data.bytes(), data.length(), "WxKeyboardNoJump", {
          onMatch: function () { found = true; return "STOP"; }
        });
      } catch (e) {}
      return found;
    }

    const a = hasDylib(appexPath);
    const m = hasDylib(mainPath);
    console.log("[INJ] 键盘扩展 wxkb_plugin.appex 注入 WxKeyboardNoJump: " +
                (a === null ? "(无法读取)" : (a ? "YES (已注入)" : "NO (未注入键盘扩展)")));
    console.log("[INJ] 主程序 wxkb.app 注入 WxKeyboardNoJump: " +
                (m === null ? "(无法读取)" : (m ? "YES (已注入)" : "NO (未注入主程序)")));
  } catch (e) {
    console.log("[INJ] EXC: " + e);
  }
  console.log("[INJ] end");
}
main();

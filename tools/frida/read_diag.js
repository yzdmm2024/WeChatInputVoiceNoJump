'use strict';
console.log("[DIAG] script start");
try {
  const path = "/var/mobile/wxkbd_diag.log";
  const fm = ObjC.classes.NSFileManager.defaultManager();
  const exists = fm.fileExistsAtPath_(path);
  console.log("[DIAG] fileExists=" + exists);
  if (exists) {
    const str = ObjC.classes.NSString.stringWithContentsOfFile_encoding_error_(path, 4, ptr(0));
    const s = str ? str.toString() : "(null)";
    console.log("[DIAG] ===== content =====");
    console.log(s);
    console.log("[DIAG] ===== END =====");
    if (s.indexOf("LOADED in com.tencent.wetype.keyboard") >= 0) console.log("[DIAG] ✅ 键盘扩展已加载 dylib");
    else console.log("[DIAG] ⚠️ 无 'LOADED in ...keyboard' —— 键盘扩展可能未注入");
    if (s.indexOf("BLOCK") >= 0) console.log("[DIAG] ✅ 检测到 BLOCK —— 跳转拦截已生效");
    else console.log("[DIAG] ⚠️ 无 BLOCK —— 没走 openURL 拦截（或还没点语音）");
  } else {
    console.log("[DIAG] 文件不存在: " + path);
    console.log("[DIAG] 需先注入新 dylib 到 wxkb.app + wxkb_plugin.appex 并点一次语音");
  }
} catch (e) {
  console.log("[DIAG] EXCEPTION: " + e);
}
console.log("[DIAG] script end");

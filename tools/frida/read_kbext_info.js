'use strict';
// 从 SpringBoard 读 wxkb_plugin.appex(键盘扩展) 的 Info.plist：principal class + 可执行 + 扩展属性
const fm = ObjC.classes.NSFileManager.defaultManager();
const appPath="/var/containers/Bundle/Application/FBBCCDD2-C435-413A-852D-0823B8018D97/wxkb.app";
const ip=appPath+"/PlugIns/wxkb_plugin.appex/Info.plist";
const d=ObjC.classes.NSDictionary.dictionaryWithContentsOfFile_(ip);
if(!d){ console.log("cannot read "+ip); }
else{
  console.log("CFBundleExecutable = "+d.objectForKey_("CFBundleExecutable"));
  const ext=d.objectForKey_("NSExtension");
  if(ext){
    console.log("NSExtensionPointIdentifier = "+ext.objectForKey_("NSExtensionPointIdentifier"));
    console.log("NSExtensionPrincipalClass  = "+ext.objectForKey_("NSExtensionPrincipalClass"));
    const attr=ext.objectForKey_("NSExtensionAttributes");
    if(attr){ console.log("NSExtensionAttributes = "+attr); }
  }
  // 也打印主 app 的键盘相关：看有无 RequestsOpenAccess
  const main=ObjC.classes.NSDictionary.dictionaryWithContentsOfFile_(appPath+"/Info.plist");
  if(main){ console.log("MAIN CFBundleVersion = "+main.objectForKey_("CFBundleVersion")); }
}
console.log("[DONE read_kbext_info]");

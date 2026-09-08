'use strict';
function main() {
  console.log("[FIND] start");
  try {
    var fm = ObjC.classes.NSFileManager.defaultManager();
    var base = "/private/var/containers/Bundle/Application/";
    var uuids = fm.contentsOfDirectoryAtPath_error_(base, ptr(0));
    if (!uuids) { console.log("[FIND] 列 Application 目录失败"); return; }
    console.log("[FIND] uuid count=" + uuids.count());
    var target = "com.weizhi.Newxiandai123456";
    for (var i = 0; i < uuids.count(); i++) {
      var u = uuids.objectAtIndex_(i).toString();
      var appDir = base + u + "/";
      var inner = fm.contentsOfDirectoryAtPath_error_(appDir, ptr(0));
      if (!inner) continue;
      for (var j = 0; j < inner.count(); j++) {
        var name = inner.objectAtIndex_(j).toString();
        if (!name.endsWith(".app")) continue;
        var infoPath = appDir + name + "/Info.plist";
        if (!fm.fileExistsAtPath_(infoPath)) continue;
        var d = ObjC.classes.NSDictionary.dictionaryWithContentsOfFile_(infoPath);
        if (!d) continue;
        var bid = d.objectForKey_("CFBundleIdentifier");
        if (!bid) continue;
        var bidStr = bid.toString();
        if (bidStr === target || bidStr.indexOf("Newxiandai") >= 0 || bidStr.indexOf("wetype") >= 0) {
          console.log("[FIND] MATCH bid=" + bidStr + " app=" + name + " uuid=" + u);
          console.log("[FIND]   path=" + appDir + name);
          console.log("[FIND]   display=" + d.objectForKey_("CFBundleDisplayName") + " name=" + d.objectForKey_("CFBundleName"));
          console.log("[FIND]   ver=" + d.objectForKey_("CFBundleShortVersionString") + " exec=" + d.objectForKey_("CFBundleExecutable"));
          var plugDir = appDir + name + "/PlugIns";
          if (fm.fileExistsAtPath_(plugDir)) {
            var plugs = fm.contentsOfDirectoryAtPath_error_(plugDir, ptr(0));
            console.log("[FIND]   PlugIns=" + (plugs ? plugs.count() : "?"));
            if (plugs) {
              for (var k = 0; k < plugs.count(); k++) {
                var pe = plugs.objectAtIndex_(k).toString();
                if (!pe.endsWith(".appex")) continue;
                var peInfo = plugDir + "/" + pe + "/Info.plist";
                if (!fm.fileExistsAtPath_(peInfo)) continue;
                var pd = ObjC.classes.NSDictionary.dictionaryWithContentsOfFile_(peInfo);
                if (!pd) continue;
                var ext = pd.objectForKey_("NSExtension");
                var pt = ext ? (ext.objectForKey_("NSExtensionPointIdentifier") || "(none)") : "(none)";
                var pcls = ext ? (ext.objectForKey_("NSExtensionPrincipalClass") || "(none)") : "(none)";
                console.log("[FIND]     appex=" + pe + " pt=" + pt + " principal=" + pcls);
              }
            }
          } else {
            console.log("[FIND]   no PlugIns dir");
          }
        }
      }
    }
    console.log("[FIND] DONE");
  } catch (e) {
    console.log("[FIND] EXC: " + e);
  }
}
main();

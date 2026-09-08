// 以 root(launchd) 身份实测 /private/var/containers/Bundle/Application/ 结构
// 目标：确认 WeType 安装路径、是否有注入 dylib、relaxin 真实根
function jb(str){ try { return JSON.stringify(str); } catch(e){ return String(str); } }

function statPath(p){
  var fm = ObjC.classes.NSFileManager.defaultManager();
  var err = Memory.alloc(8);
  var ok = fm.fileExistsAtPath_isDirectory_(p, err);
  return ok;
}

function listDir(p){
  var fm = ObjC.classes.NSFileManager.defaultManager();
  var e = Memory.alloc(Process.pageSize);
  var items = fm.contentsOfDirectoryAtPath_error_(p, e);
  if (!items) return [];
  var out = [];
  var n = items.count();
  for (var i=0;i<n;i++){ out.push(items.objectAtIndex_(i).toString()); }
  return out;
}

function main(){
  var lines = [];
  lines.push("DIAG8 root=" + (ObjC.classes.NSProcessInfo.processInfo().processIdentifier()));

  var base = "/private/var/containers/Bundle/Application/";
  lines.push("base exists=" + statPath(base));
  if (statPath(base)) {
    var uuids = listDir(base);
    lines.push("app-uuids count=" + uuids.length);
    for (var i=0;i<uuids.length;i++){
      var u = uuids[i];
      var udir = base + u;
      var apps = listDir(udir);
      for (var j=0;j<apps.length;j++){
        var app = apps[j];
        if (app.indexOf(".app") >= 0) {
          var isWetype = (app.toLowerCase().indexOf("wxkb")>=0 || app.toLowerCase().indexOf("wetype")>=0);
          lines.push("  APP " + u + "/" + app + (isWetype ? "  <<<WETYPE?" : ""));
          if (isWetype) {
            var appdir = udir + "/" + app;
            lines.push("    Frameworks=" + jb(listDir(appdir + "/Frameworks").filter(function(x){return x.indexOf("wxkb")>=0 || x.indexOf("Tweak")>=0 || x.indexOf("NoJump")>=0 || x.indexOf("ellekit")>=0 || x.indexOf("substrate")>=0;})));
            lines.push("    PlugIns=" + jb(listDir(appdir + "/PlugIns")));
            // 列出 PlugIns 里每个 appex 的 Frameworks
            var plugs = listDir(appdir + "/PlugIns");
            for (var k=0;k<plugs.length;k++){
              var pe = plugs[k];
              if (pe.indexOf(".appex")>=0){
                var pedir = appdir + "/PlugIns/" + pe;
                lines.push("      " + pe + " Frameworks=" + jb(listDir(pedir + "/Frameworks").filter(function(x){return x.indexOf("wxkb")>=0||x.indexOf("Tweak")>=0||x.indexOf("NoJump")>=0||x.indexOf("ellekit")>=0||x.indexOf("substrate")>=0;})));
              }
            }
          }
        }
      }
    }
  }

  // 常见注入/包管理根
  var candidates = [
    "/var/jb",
    "/var/jb/usr/lib/TweakInject",
    "/var/lib/dpkg",
    "/Library/MobileSubstrate/DynamicLibraries",
    "/var/containers/Bundle/tweak",
    "/var/containers/Bundle/com.sileo",
    "/var/containers/Bundle/Application/tweak",
    "/private/var/containers/Bundle/Application/TweakInject",
    "/private/var/containers/Bundle/dylibs",
    "/usr/lib/TweakInject",
    "/usr/lib/substrate",
    "/usr/lib/libsubstrate.dylib",
    "/usr/lib/libellekit.dylib",
    "/Library/PreferenceLoader",
    "/var/jb/Library/PreferenceLoader"
  ];
  lines.push("--- candidate roots ---");
  for (var c=0;c<candidates.length;c++){
    lines.push("  " + candidates[c] + " exists=" + statPath(candidates[c]));
  }

  send({type:"DIAG8", lines:lines});
}

main();

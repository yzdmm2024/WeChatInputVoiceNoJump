'use strict';
// 从 SpringBoard 进程读设备文件系统，定位 wxkb.app 及其所有 PlugIns（拿键盘扩展 bundle id + 扩展点）
const fm = ObjC.classes.NSFileManager.defaultManager();
function walk(root){
  const apps = fm.contentsOfDirectoryAtPath_error_(root, NULL);
  if(!apps) return false;
  for(let i=0;i<apps.count();i++){
    const uuid=apps.objectAtIndex_(i).toString();
    const base=root+"/"+uuid;
    const inner=fm.contentsOfDirectoryAtPath_error_(base,NULL);
    if(!inner) continue;
    for(let j=0;j<inner.count();j++){
      const n=inner.objectAtIndex_(j).toString();
      if(n.toLowerCase().indexOf("wxkb.app")>=0 || n.toLowerCase().indexOf("wetype")>=0){
        console.log("FOUND container: "+base+"/"+n);
        const pp=base+"/"+n+"/PlugIns";
        const pl=fm.contentsOfDirectoryAtPath_error_(pp,NULL);
        if(pl){ for(let k=0;k<pl.count();k++){ const pn=pl.objectAtIndex_(k).toString();
          const d=ObjC.classes.NSDictionary.dictionaryWithContentsOfFile_(pp+"/"+pn+"/Info.plist");
          if(d){ const ext=d.objectForKey_("NSExtension"); const pt=ext?ext.objectForKey_("NSExtensionPointIdentifier"):null;
            const bid=d.objectForKey_("CFBundleIdentifier");
            console.log("  PLUGIN "+pn+"  id="+(bid?bid.toString():"?")+"  ext="+(pt?pt.toString():"(none)"));
          } else console.log("  PLUGIN "+pn+" (no Info.plist)");
        }} else console.log("  (no PlugIns dir)");
        return true;
      }
    }
  }
  return false;
}
console.log("=== search /var/containers/Bundle/Application ===");
const found = walk("/var/containers/Bundle/Application");
if(!found) console.log("wxkb.app not found there");
console.log("[DONE find_kbext]");

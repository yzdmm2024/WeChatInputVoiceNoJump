'use strict';
// 轻量版：先打 App 插件 + 偏好(免跳转键)，再只枚举 WeType 专属类
function Wetype(name){
  const l = name.toLowerCase();
  return l.indexOf("wxkb.")>=0 || l.indexOf("wbvoice")>=0 || l.indexOf("wtapp")>=0 ||
         l.indexOf("liveactivity")>=0 || l.indexOf("wet")>=0 || l.indexOf("wxkb")>=0 ||
         l.indexOf("wetype")>=0 || l.indexOf("voiceinput")>=0;
}
function dumpUD(suite){
  try{
    const ud = suite? ObjC.classes.NSUserDefaults.alloc().initWithSuiteName_(suite) : ObjC.classes.NSUserDefaults.standardUserDefaults();
    if(!ud) return;
    const dic = ud.dictionaryRepresentation(); const keys = dic.allKeys();
    console.log("  -- suite "+(suite||"standard")+" --");
    for(let i=0;i<keys.count();i++){
      const key = keys.objectAtIndex_(i).toString();
      if(/voice|redirect|nojump|keyboard|wetype|wxkb|asr|mic|theme|color|appearance|corner|float|transp|bgcolor|background/i.test(key)){
        let v="?"; try{ v=dic.objectForKey_(keys.objectAtIndex_(i)).toString(); }catch(e){}
        console.log("     "+key+" = "+v);
      }
    }
  }catch(e){ console.log("  UD err "+e); }
}
// 1) App 插件
try{
  const b = ObjC.classes.NSBundle.mainBundle();
  console.log("APP id="+b.bundleIdentifier().toString()+" path="+b.bundlePath().toString());
  const pp = b.builtInPlugInsPath(); console.log("PLUGINS path="+pp);
  const fm = ObjC.classes.NSFileManager.defaultManager();
  const arr = fm.contentsOfDirectoryAtPath_error_(pp, NULL);
  if(arr){ for(let i=0;i<arr.count();i++){
    const name=arr.objectAtIndex_(i).toString();
    const d=ObjC.classes.NSDictionary.dictionaryWithContentsOfFile_(pp+"/"+name+"/Info.plist");
    if(d){ const ext=d.objectForKey_("NSExtension"); const pt=ext?ext.objectForKey_("NSExtensionPointIdentifier"):null;
      const bid=d.objectForKey_("CFBundleIdentifier");
      console.log("  PLUGIN "+name+" id="+(bid?bid.toString():"?")+" ext="+(pt?pt.toString():"(none)"));
    } else console.log("  PLUGIN "+name);
  }}
}catch(e){ console.log("appinfo err "+e); }

// 2) 偏好
console.log("\n== NSUserDefaults ==");
dumpUD(null);
dumpUD("com.tencent.wetype");
dumpUD("group.com.tencent.wetype");
dumpUD("com.tencent.wetype.liveActivity");

// 3) WeType 专属类(只列名字)
console.log("\n== WeType classes (name only) ==");
const names = Object.keys(ObjC.classes).filter(Wetype).sort();
console.log("  count="+names.length);
names.forEach(n=>console.log("  "+n));

// 4) 针对关键类打方法
const need = ["WBVoiceInputLiveActivityManager","WBVoiceInputLiveActivityManager","WtAppActionOpenVoiceNoRedirectionWechat"];
console.log("\n== methods of key classes ==");
for(const c of names){
  if(/voiceinput|liveactivity|voicenoredirect|redirect|keyboardview|keyboardcontroller|rootcontroller|settingscontroller|voiceinputmanager/i.test(c)){
    const cls = ObjC.classes[c];
    if(!cls) continue;
    try{
      const ms = (cls.$ownMethods||[]).concat(cls.$classmethods||[]).map(x=>x.toString());
      console.log("\n  ["+c+"] ("+ms.length+" methods)");
      ms.slice(0,50).forEach(m=>console.log("    "+m));
    }catch(e){ console.log("  ["+c+"] err "+e); }
  }
}
console.log("\n[DONE enum2]");

'use strict';
// 枚举微信输入法(com.tencent.wetype)运行进程内的类/方法/插件/偏好
// 用法: frida -U -n wxkb -l enum_wetype.js
const KW = ["Voice","WBVoice","WtApp","NoRedirect","Redirect","LiveActivity","Keyboard","WXKB",
            "Recogniz","AudioSession","Prefs","Setting","Manager","Extension","Input","Theme",
            "Appearance","Color","CornerRadius","Background","RootController","SettingsController"];

function kwClasses(){
  const res = {};
  for (const name of Object.keys(ObjC.classes)){
    const l = name.toLowerCase();
    for (const k of KW){ if (l.indexOf(k.toLowerCase())>=0){ (res[k]=res[k]||[]).push(name); break; } }
  }
  return res;
}
const m = kwClasses();
for (const k of KW){
  if (m[k]){
    console.log("\n===== ["+k+"] ("+m[k].length+") =====");
    m[k].slice(0,90).forEach(n=>console.log("  "+n));
  }
}

// App 基本信息 + 内置扩展(找键盘扩展/语音扩展的 bundle/扩展点)
try{
  const b = ObjC.classes.NSBundle.mainBundle();
  console.log("\n===== App Bundle =====");
  console.log("  id   = "+b.bundleIdentifier().toString());
  console.log("  path = "+b.bundlePath().toString());
  const pp = b.builtInPlugInsPath();
  console.log("  pluginsPath = "+pp);
  const fm = ObjC.classes.NSFileManager.defaultManager();
  const arr = fm.contentsOfDirectoryAtPath_error_(pp, NULL);
  if (arr){ for(let i=0;i<arr.count();i++){
    const name = arr.objectAtIndex_(i).toString();
    const pn = pp+"/"+name;
    const ip = pn+"/Info.plist";
    const d = ObjC.classes.NSDictionary.dictionaryWithContentsOfFile_(ip);
    if(d){ const ext=d.objectForKey_("NSExtension"); const pt=ext?ext.objectForKey_("NSExtensionPointIdentifier"):null;
      const bid = d.objectForKey_("CFBundleIdentifier");
      console.log("  "+name+"  id="+ (bid?bid.toString():"?") +"  ext="+(pt?pt.toString():"(none)"));
    } else { console.log("  "+name); }
  }}
}catch(e){ console.log("appinfo err: "+e); }

// NSUserDefaults(standard)
try{
  const ud = ObjC.classes.NSUserDefaults.standardUserDefaults();
  const dic = ud.dictionaryRepresentation();
  const keys = dic.allKeys();
  console.log("\n===== NSUserDefaults(standard) 命中 voice/redirect/keyboard/nojump/wetype/wxkb/asr/mic/theme/color =====");
  for(let i=0;i<keys.count();i++){
    const key = keys.objectAtIndex_(i).toString();
    if (/voice|redirect|nojump|keyboard|wetype|wxkb|asr|mic|theme|color|appearance|corner/i.test(key)){
      let v="?"; try{ v = dic.objectForKey_(keys.objectAtIndex_(i)).toString(); }catch(e){}
      console.log("  "+key+" = "+v);
    }
  }
}catch(e){ console.log("ud err: "+e); }

// 专属 suite
try{
  const ud2 = ObjC.classes.NSUserDefaults.alloc().initWithSuiteName_("com.tencent.wetype");
  if (ud2){ const dic2=ud2.dictionaryRepresentation(); const keys2=dic2.allKeys();
    console.log("\n===== NSUserDefaults suite 'com.tencent.wetype' 命中 =====");
    for(let i=0;i<keys2.count();i++){ const key=keys2.objectAtIndex_(i).toString();
      if(/voice|redirect|nojump|keyboard|asr|mic|theme|color|appearance|voice|setting/i.test(key)){
        let v="?"; try{ v=dic2.objectForKey_(keys2.objectAtIndex_(i)).toString(); }catch(e){}
        console.log("  "+key+" = "+v);
      }
    }
  }
}catch(e){ console.log("suite err: "+e); }
console.log("\n[DONE enum]");

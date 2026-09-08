'use strict';
function log(s){ console.log("[TRACE] " + s); }

// 保持进程
setInterval(function(){}, 1000);

setTimeout(function(){
  // ---- 0) 模块检查：我们的 dylib 是否注入到键盘扩展进程 ----
  try {
    const mods = Process.enumerateModules();
    let hit = null;
    for (const m of mods) {
      if (m.name.indexOf("WxKeyboardNoJump") >= 0 || (m.path && m.path.indexOf("WxKeyboardNoJump") >= 0)) { hit = m; break; }
    }
    log("=== MODULE CHECK ===");
    log("bundle=" + ObjC.classes.NSBundle.mainBundle().bundleIdentifier().toString());
    log("total modules=" + mods.length);
    log("our dylib=" + (hit ? hit.path : "NOT LOADED (扩展进程里没有我们的 dylib!)"));
  } catch(e){ log("module check err: " + e); }

  // ---- 1) openURL 家族（重点：UIInputViewController 是扩展里拉起主 app 的 API）----
  function hookOpenURL(clsName, sel, nargs){
    const cls = ObjC.classes[clsName];
    if (!cls) { log("MISS class " + clsName); return; }
    let m; try { m = cls['- ' + sel]; } catch(e){ log("MISS sel " + clsName + " " + sel); return; }
    if (!m) { log("MISS sel " + clsName + " " + sel); return; }
    const old = m.implementation;
    m.implementation = ObjC.implement(m, function(self, selector, a, b, c){
      try {
        let desc = "(n/a)";
        if (a) {
          const u = new ObjC.Object(a);
          if (u.absoluteString) desc = u.absoluteString().toString();
          else if (u.toString) desc = u.toString();
        }
        log("OPENURL " + clsName + " / " + sel + " => " + desc);
      } catch(e){ log("OPENURL " + clsName + " / " + sel + " => (decode err " + e + ")"); }
      if (nargs === 1) return old(self, selector, a);
      if (nargs === 3) return old(self, selector, a, b, c);
      return old(self, selector, a);
    });
    log("HOOKED " + clsName + " " + sel);
  }
  hookOpenURL("UIApplication", "openURL:", 1);
  hookOpenURL("UIApplication", "openURL:options:completionHandler:", 3);
  hookOpenURL("UIInputViewController", "openURL:", 1);
  hookOpenURL("UIInputViewController", "openURL:options:completionHandler:", 3);
  hookOpenURL("NSExtensionContext", "openURL:", 1);
  hookOpenURL("NSExtensionContext", "openURL:completionHandler:", 2);

  // ---- 2) NSUserDefaults 读键（过滤语音/跳转/重定向相关）----
  function hookUD(sel){
    const cls = ObjC.classes.NSUserDefaults;
    if (!cls) return;
    let m; try { m = cls['- ' + sel]; } catch(e){ return; }
    if (!m) return;
    const old = m.implementation;
    m.implementation = ObjC.implement(m, function(self, selector, key){
      try {
        const k = new ObjC.Object(key).toString();
        const low = k.toLowerCase();
        if (low.indexOf("voice")>=0 || low.indexOf("jump")>=0 || low.indexOf("redirect")>=0 ||
            low.indexOf("nojump")>=0 || low.indexOf("wetype")>=0 || low.indexOf("record")>=0 ||
            low.indexOf("asr")>=0 || low.indexOf("recogni")>=0 || low.indexOf("wcvoice")>=0) {
          log("UD." + sel + " key=" + k);
        }
      } catch(e){}
      return old(self, selector, key);
    });
    log("HOOKED NSUserDefaults " + sel);
  }
  hookUD("objectForKey:");
  hookUD("boolForKey:");
  hookUD("stringForKey:");
  hookUD("dictionaryForKey:");

  log("=== READY: 去微信里呼出微信输入法，点语音按钮（让它跳转），日志会捕获真实路径 ===");
}, 800);

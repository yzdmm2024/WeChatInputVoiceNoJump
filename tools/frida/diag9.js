// 核实 wxkb.app 当前注入态 + 签名 + 键盘扩展真实路径
function statPath(p){ return ObjC.classes.NSFileManager.defaultManager().fileExistsAtPath_(p); }
function listDir(p){
  var fm=ObjC.classes.NSFileManager.defaultManager();
  var e=Memory.alloc(Process.pageSize);
  var items=fm.contentsOfDirectoryAtPath_error_(p,e);
  if(!items) return [];
  var out=[]; for(var i=0;i<items.count();i++) out.push(items.objectAtIndex_(i).toString());
  return out;
}
function main(){
  var L=[];
  var wxkb="/private/var/containers/Bundle/Application/FBBCCDD2-C435-413A-852D-0823B8018D97/wxkb.app";
  L.push("wxkb.app exists="+statPath(wxkb));
  // 全量 Frameworks（不过滤）
  L.push("Frameworks(all)="+JSON.stringify(listDir(wxkb+"/Frameworks")));
  // 是否有注入痕迹：任意非 apple dylib / TweakInject / .dylib
  var fw=listDir(wxkb+"/Frameworks");
  var injected=fw.filter(function(x){return /\.dylib$/.test(x)||/Tweak|NoJump|ellekit|substrate|hook/i.test(x);});
  L.push("possible-injected-in-Frameworks="+JSON.stringify(injected));
  // 签名相关
  L.push("embedded.mobileprovision exists="+statPath(wxkb+"/embedded.mobileprovision"));
  L.push("_CodeSignature exists="+statPath(wxkb+"/_CodeSignature"));
  // 键盘扩展精确路径
  var plugs=listDir(wxkb+"/PlugIns");
  L.push("PlugIns="+JSON.stringify(plugs));
  for(var i=0;i<plugs.length;i++){
    var pe=plugs[i];
    if(pe.indexOf(".appex")>=0){
      var ped=wxkb+"/PlugIns/"+pe;
      var pf=ped+"/Info.plist";
      if(statPath(pf)){
        var d=ObjC.classes.NSDictionary.dictionaryWithContentsOfFile_(pf);
        var bid=d.objectForKey_("CFBundleIdentifier");
        var pt="";
        var ext=d.objectForKey_("NSExtension");
        if(ext){ pt=ext.objectForKey_("NSExtensionPointIdentifier").toString(); }
        L.push("  "+pe+" bid="+bid+" point="+pt);
      }
      L.push("    "+pe+"/Frameworks="+JSON.stringify(listDir(ped+"/Frameworks")));
      L.push("    "+pe+"/embedded.mobileprovision="+statPath(ped+"/embedded.mobileprovision"));
    }
  }
  // dylib插件库.app / TrollFools.app 是什么
  var base="/private/var/containers/Bundle/Application/";
  var uu=listDir(base);
  for(var j=0;j<uu.length;j++){
    var ud=base+uu[j];
    var apps=listDir(ud);
    for(var k=0;k<apps.length;k++){
      var a=apps[k];
      if(a==="dylib插件库.app"||a==="TrollFools.app"||a==="Relaxin.app"){
        var ip=ud+"/"+a+"/Info.plist";
        if(statPath(ip)){
          var di=ObjC.classes.NSDictionary.dictionaryWithContentsOfFile_(ip);
          L.push(a+" bid="+di.objectForKey_("CFBundleIdentifier")+" ver="+di.objectForKey_("CFBundleVersion")+" exec="+di.objectForKey_("CFBundleExecutable"));
        }
      }
    }
  }
  send({type:"DIAG9", lines:L});
}
main();

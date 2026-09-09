//
//  Tweak.xm — 微信键盘免跳转 + 键盘外观定制 (rootless deb / ElleKit TweakInject) v1.1.14
//
//  目标进程（见 WxKbNoJump.plist Filter）：
//    com.tencent.wetype.keyboard  —— 键盘扩展（语音按钮与键盘 UI 都在这里）
//    com.tencent.wetype           —— 主 app（设置/管理壳）
//
//  1.1.12 改动要点：
//  【免跳转】彻底重写。根因（见 微信输入法免跳转分析.md）：WeType 内建「免跳」路径是
//    键盘扩展内直接录音→腾讯 ASR→textDocumentProxy.insertText，由判定方法
//    canUseWcVoice / prefersJumpToMainAppForRecording / isUsingWcVoice /
//    requireJumpToMainAppForRecording 决定是否走这条路；第三方 App 里它判定宿主不是微信，
//    改走 jumpToPageWithToolBarFunc: → openURL 拉起 wxkb.app 主程序（即“跳一下”）。
//    修复：强制这 4 个判定方法返回“走内建路径”，让任意 App 都走和微信一样的
//    扩展内录音→回填，不拉主程序。不再拦截语音面板/不再瞎调私有方法。
//
//  【外观定制】彻底重写。真实类名（从 IPA 二进制静态提取）：
//    每个字母/数字/符号小键 = WBKeyView（子类 WBNewlineKeyView / WBReturnKeyView /
//      WBSecKeyboardKeyView / WBRuleKeyView / WBRecoverKey）
//    键盘整体背景容器 = WBKeyboardView
//    候选栏 = WBCandidateView / WBSplitCandidateView
//    功能栏 = WBFunctionToolBar / WBToolBarAuxiliary
//    完全对齐用户 HTML 原型参数：按键圆角 / 按键间距 / 按键高度 / 字体大小 /
//    字母键底色 / 功能键底色 / 键盘背景色 / 候选栏背景色。
//    圆角只作用在 WBKeyView（不是整块键盘）；底色作用在可见的键与背景视图。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <AVFoundation/AVFoundation.h>

#pragma mark - 配置

static NSString *const kWxSuite        = @"com.wxkbd.nojump";
static NSString *const kWxNoJumpKey    = @"WBAppSettingsBool_VoiceInput_WcVoiceNoJump";

// 免跳转
static NSString *const kNoJumpEnabled  = @"wxkbdNoJumpEnabled";
// 外观总开关
static NSString *const kStyleEnabled   = @"wxkbdStyleEnabled";
// 外观参数（对齐 HTML 原型默认值）
static NSString *const kKeyRadius      = @"wxkbdKeyRadius";   // 按键圆角 0..24
static NSString *const kKeyGap        = @"wxkbdKeyGap";      // 按键间距 0..16
static NSString *const kKeyHeight      = @"wxkbdKeyHeight";   // 按键高度 30..80
static NSString *const kKeyFont        = @"wxkbdKeyFont";     // 字体大小 12..32
static NSString *const kLetterR = @"wxkbdLetterR", *const kLetterG = @"wxkbdLetterG",
                      *const kLetterB = @"wxkbdLetterB", *const kLetterA = @"wxkbdLetterA"; // 字母键底色
static NSString *const kFuncR = @"wxkbdFuncR", *const kFuncG = @"wxkbdFuncG",
                      *const kFuncB = @"wxkbdFuncB", *const kFuncA = @"wxkbdFuncA";          // 功能键底色
static NSString *const kKbR = @"wxkbdKbR", *const kKbG = @"wxkbdKbG",
                      *const kKbB = @"wxkbdKbB", *const kKbA = @"wxkbdKbA";                  // 键盘背景
static NSString *const kCandR = @"wxkbdCandR", *const kCandG = @"wxkbdCandG",
                      *const kCandB = @"wxkbdCandB", *const kCandA = @"wxkbdCandA";          // 候选栏背景

// 偏好读取：必须走 CFPreferences（经 cfprefsd）。键盘扩展是沙盒进程，直接读
// /var/mobile/Library/Preferences/*.plist 会被沙盒拒绝。cfprefsd RPC 沙盒放行。
static id wx_cpValue(NSString *k) {
    CFTypeRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)k, (__bridge CFStringRef)kWxSuite);
    return v ? CFBridgingRelease(v) : nil;
}
static BOOL wx_bool(NSString *k, BOOL def) {
    id v = wx_cpValue(k);
    if ([v respondsToSelector:@selector(boolValue)]) return [v boolValue];
    return def;
}
static CGFloat wx_float(NSString *k, CGFloat def) {
    id v = wx_cpValue(k);
    if ([v respondsToSelector:@selector(floatValue)]) return [v floatValue];
    return def;
}

#pragma mark - 进程识别

static BOOL wx_isKbExtension(void) { return (NSClassFromString(@"WBInputViewController") != nil); }
static BOOL wx_isMainApp(void) {
    NSString *b = [[NSBundle mainBundle] bundleIdentifier];
    return (b && [b isEqualToString:@"com.tencent.wetype"]);
}

#pragma mark - 外观应用（精确命中真实类）

static const void *kWxOrigBg   = &kWxOrigBg;
static const void *kWxOrigFrame= &kWxOrigFrame;

// 真实按键类：WBKeyView 及其子类
static Class wx_KeyViewCls(void)  { return NSClassFromString(@"WBKeyView"); }
static Class wx_KbdViewCls(void)  { return NSClassFromString(@"WBKeyboardView"); }
static Class wx_CandViewCls(void) {
    Class c = NSClassFromString(@"WBCandidateView");
    if (!c) c = NSClassFromString(@"WBSplitCandidateView");
    return c;
}

// 取按键显示文字（用于区分字母键/功能键）
static NSString *wx_keyText(UIView *k) {
    NSArray *keys = @[@"text", @"key", @"displayText", @"title", @"labelText", @"inputText"];
    for (NSString *kk in keys) {
        @try {
            id v = [k valueForKey:kk];
            if (v && [v isKindOfClass:[NSString class]] && [(NSString *)v length]) return v;
        } @catch (NSException *e) {}
    }
    // 退而求其次：找 UILabel 子视图
    for (UIView *s in k.subviews) {
        if ([s isKindOfClass:[UILabel class]]) {
            NSString *t = [(UILabel *)s text];
            if (t.length) return t;
        }
    }
    return nil;
}

// 是否功能键（非单字母/数字）
static BOOL wx_isFuncKey(UIView *k) {
    NSString *t = wx_keyText(k);
    if (!t || t.length != 1) return YES;            // 空 / 多字（空格/123/返回…）按功能键
    unichar ch = [t characterAtIndex:0];
    BOOL isLetter = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z');
    BOOL isDigit  = (ch >= '0' && ch <= '9');
    return !(isLetter || isDigit);                  // 单字母/数字 = 字母键，其余 = 功能键
}

static UIColor *wx_rgba(CGFloat r,CGFloat g,CGFloat b,CGFloat a){
    return [UIColor colorWithRed:MIN(MAX(r,0),1) green:MIN(MAX(g,0),1)
                             blue:MIN(MAX(b,0),1) alpha:MIN(MAX(a,0),1)];
}

static void wx_setKeyFont(UIView *k, CGFloat fs) {
    for (UIView *s in k.subviews) {
        if ([s isKindOfClass:[UILabel class]]) {
            UILabel *l = (UILabel *)s;
            l.font = [UIFont systemFontOfSize:fs];
        }
    }
}

static void wx_applyStyle(UIView *root) {
    if (!root) return;
    Class keyCls = wx_KeyViewCls();
    Class kbdCls = wx_KbdViewCls();
    Class candCls = wx_CandViewCls();

    if (!wx_bool(kStyleEnabled, NO)) {
        // 关闭：还原（遍历所有 WBKeyView / 背景 / 候选，恢复原色与圆角、原 frame）
        void (^restore)(UIView *) = ^(UIView *v){
            if (keyCls && [v isKindOfClass:keyCls]) {
                NSValue *of = objc_getAssociatedObject(v, kWxOrigFrame);
                if (of) v.frame = of.CGRectValue;
                if (v.layer.cornerRadius != 0) v.layer.cornerRadius = 0;
                if (v.layer.masksToBounds) v.layer.masksToBounds = NO;
            }
            UIColor *ob = objc_getAssociatedObject(v, kWxOrigBg);
            if (ob) v.backgroundColor = ob;
        };
        // 递归还原
        void (^walk)(UIView *) = nil;
        walk = ^(UIView *v){
            if (!v) return;
            restore(v);
            for (UIView *s in v.subviews) walk(s);
        };
        walk(root);
        return;
    }

    CGFloat radius  = MIN(MAX(wx_float(kKeyRadius, 10), 0), 24);
    CGFloat gap     = MIN(MAX(wx_float(kKeyGap, 6), 0), 16);
    CGFloat kheight = MIN(MAX(wx_float(kKeyHeight, 56), 30), 80);
    CGFloat fs      = MIN(MAX(wx_float(kKeyFont, 22), 12), 32);

    UIColor *letterBg = wx_rgba(wx_float(kLetterR,1), wx_float(kLetterG,1), wx_float(kLetterB,1), wx_float(kLetterA,1));
    UIColor *funcBg   = wx_rgba(wx_float(kFuncR,0.827), wx_float(kFuncG,0.839), wx_float(kFuncB,0.859), wx_float(kFuncA,1));
    UIColor *kbBg     = wx_rgba(wx_float(kKbR,0.914), wx_float(kKbG,0.914), wx_float(kKbB,0.922), wx_float(kKbA,1));
    UIColor *candBg   = wx_rgba(wx_float(kCandR,0.914), wx_float(kCandG,0.914), wx_float(kCandB,0.922), wx_float(kCandA,1));

    void (^styleOne)(UIView *) = ^(UIView *v){
        if (!v) return;
        // —— 键盘背景容器 ——
        if (kbdCls && [v isKindOfClass:kbdCls]) {
            if (!objc_getAssociatedObject(v, kWxOrigBg))
                objc_setAssociatedObject(v, kWxOrigBg, (v.backgroundColor?:[UIColor clearColor]), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            v.backgroundColor = kbBg;
        }
        // —— 候选栏 ——
        if (candCls && [v isKindOfClass:candCls]) {
            if (!objc_getAssociatedObject(v, kWxOrigBg))
                objc_setAssociatedObject(v, kWxOrigBg, (v.backgroundColor?:[UIColor clearColor]), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            v.backgroundColor = candBg;
        }
        // —— 每个按键 WBKeyView ——
        if (keyCls && [v isKindOfClass:keyCls]) {
            // 圆角只作用在按键
            v.layer.cornerRadius = radius;
            v.layer.masksToBounds = (radius > 0);
            // 底色：字母键 / 功能键
            UIColor *bg = wx_isFuncKey(v) ? funcBg : letterBg;
            if (!objc_getAssociatedObject(v, kWxOrigBg))
                objc_setAssociatedObject(v, kWxOrigBg, (v.backgroundColor?:[UIColor clearColor]), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            v.backgroundColor = bg;
            // 字体大小
            wx_setKeyFont(v, fs);
            // 间距 / 高度（best-effort）：记录原 frame，按参数内缩/改高
            CGRect f = v.frame;
            NSValue *of = objc_getAssociatedObject(v, kWxOrigFrame);
            if (!of) {
                of = [NSValue valueWithCGRect:f];
                objc_setAssociatedObject(v, kWxOrigFrame, of, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            CGRect o = [(NSValue *)of CGRectValue];
            CGFloat dx = gap / 2.0f;
            CGFloat dh = (kheight - o.size.height) / 2.0f;
            v.frame = CGRectMake(o.origin.x + dx, o.origin.y + dh,
                                 o.size.width - gap, kheight);
        }
    };

    void (^walk)(UIView *) = nil;
    walk = ^(UIView *v){
        if (!v) return;
        styleOne(v);
        for (UIView *s in v.subviews) walk(s);
    };
    walk(root);
}

#pragma mark - Swizzle 辅助

static void wx_swizzle(Class cls, SEL orig, SEL repl) {
    if (!cls) return;
    Method m1 = class_getInstanceMethod(cls, orig);
    Method m2 = class_getInstanceMethod(cls, repl);
    if (!m1 || !m2) return;
    if (class_addMethod(cls, orig, method_getImplementation(m2), method_getTypeEncoding(m2))) {
        class_replaceMethod(cls, repl, method_getImplementation(m1), method_getTypeEncoding(m1));
    } else {
        method_exchangeImplementations(m1, m2);
    }
}

#pragma mark - NSUserDefaults：微信自带免跳标志恒真（锦上添花，不依赖私有方法名）

@interface NSUserDefaults (WxKbNoJump)
- (id)wx_objectForKey:(NSString *)key;
- (BOOL)wx_boolForKey:(NSString *)key;
@end
@implementation NSUserDefaults (WxKbNoJump)
- (id)wx_objectForKey:(NSString *)key {
    if ([key isEqualToString:kWxNoJumpKey] && wx_bool(kNoJumpEnabled, YES)) return @YES;
    return [self wx_objectForKey:key];
}
- (BOOL)wx_boolForKey:(NSString *)key {
    if ([key isEqualToString:kWxNoJumpKey] && wx_bool(kNoJumpEnabled, YES)) return YES;
    return [self wx_boolForKey:key];
}
@end

#pragma mark - 免跳转核心（三层防跳，覆盖所有判定入口）

// 关键修正：WBRootViewManager / WBVoiceInputService 是 WeType 运行时类，没有公开头文件，
// 不能在它们上面写 @interface X (Cat) 分类。改用运行期 method_setImplementation 直接替换
// 方法 IMP，替身用 block 实现，无需任何 @interface / 前向声明。
//
// 根因（frida 实抓扩展 + IPA 静态）：扩展通过 hostBundleID 记录宿主 App；仅当宿主是微信
// （wormhole 通道建立）时 canUseWcVoice* 返回 YES → 走“扩展内录音→回填”；第三方宿主没有
// wormhole → canUseWcVoiceByWormhole / canUseWcVoiceByConfig 返回 NO → 调
// jumpToPageWithToolBarFunc: 拉起 wxkb.app 主程序（即“跳一下”）。
// 1.1.12 只改了 canUseWcVoice，漏了 wormhole/config 两个变体，所以第三方 App 仍跳。
//
// 1.1.13 三层防跳：
//  ① 强制全部 canUseWcVoice* = YES、prefers/requireJump = NO → 走扩展内录音路径；
//  ② 把 jumpToPageWithToolBarFunc: / preJumpToPageWithToolBarFunc: 变空操作（兜底）；
//  ③ 拦截 LSApplicationWorkspace 拉起 wxkb.app / WXKBURL_STARTVOICERECORD（最后保险）。
// 这样无论哪个判定被触发，都不可能再跳。
//
// 1.1.14 双保险（兜底录音）：真机 trace 显示，若 WeType 仍走 jump 分支（即没走 nativeMode
//   内录），扩展会调 openURL(WXKBURL_STARTVOICERECORD) 拉主程序。拦截到该 URL 时，除了
//   吞掉 openURL（防跳），再【主动】调 WBVoiceInputService 的 nativeMode_launchWithContext:
//   启动扩展内录音——因为“走到 openURL”本身就证明 WeType 没起内录，此时补一刀不会重复启动。
//   全部用 respondsToSelector + @try/@catch 包裹，且每次扩展启动只试一次，即使猜测的
//   单例取不到/方法签名不符也只会打日志、不会崩键盘。日志统一前缀 [WxKbNoJump] native trigger。

static void wx_overrideReturnBool(Class cls, SEL sel, BOOL forceVal) {
    if (!cls || !sel) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP origImp = method_getImplementation(m);
    const char *enc = method_getTypeEncoding(m);
    if (!origImp || !enc) return;
    // block 捕获原 IMP 与强制返回值；免跳关闭时回退到原实现，行为完全还原
    __block IMP oImp = origImp;
    __block BOOL fVal = forceVal;
    id block = ^BOOL(id self, SEL _cmd) {
        if (wx_bool(kNoJumpEnabled, YES)) return fVal;
        BOOL (*orig)(id, SEL) = (BOOL(*)(id, SEL))oImp;
        return orig(self, _cmd);
    };
    IMP newImp = imp_implementationWithBlock(block);   // 接收 id（block 对象），不能桥转 void*
    if (!newImp) return;
    method_setImplementation(m, newImp);   // 原地替换，保留原 IMP 在 block 内供回退
}

// 把某方法替换为“空操作”（仅在免跳开启时安装；免跳关闭则保留原实现，不触碰参数类型）
static void wx_neutralizeVoid(Class cls, SEL sel) {
    if (!cls || !sel) return;
    if (!wx_bool(kNoJumpEnabled, YES)) return;   // 免跳关闭时不安装，原行为完全保留
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    id block = ^void(id self, SEL _cmd) { /* no-op：阻止跳转发起 */ };
    IMP newImp = imp_implementationWithBlock(block);
    if (!newImp) return;
    method_setImplementation(m, newImp);
}

// 拦截 LSApplicationWorkspace 拉起主程序 / 语音跳转 scheme（最后保险）
static void wx_blockJumpURLScheme(void) {
    Class ls = NSClassFromString(@"LSApplicationWorkspace");
    if (!ls) return;
    SEL s1 = @selector(openURL:);
    if (class_getInstanceMethod(ls, s1)) {
        Method m = class_getInstanceMethod(ls, s1);
        IMP o = method_getImplementation(m); __block IMP oImp = o;
        id block = ^id(id self, SEL _cmd, NSURL *url) {
            if (wx_bool(kNoJumpEnabled, YES) && url &&
                [[url absoluteString] rangeOfString:@"WXKBURL_STARTVOICERECORD"].location != NSNotFound) {
                NSLog(@"[WxKbNoJump] blocked LSApplicationWorkspace openURL (jump scheme)");
                return nil;
            }
            id (*orig)(id, SEL, id) = (id(*)(id, SEL, id))oImp;
            return orig(self, _cmd, url);
        };
        IMP ni = imp_implementationWithBlock(block);
        if (ni) method_setImplementation(m, ni);
    }
    SEL s2 = @selector(openApplicationWithBundleID:);
    if (class_getInstanceMethod(ls, s2)) {
        Method m = class_getInstanceMethod(ls, s2);
        IMP o = method_getImplementation(m); __block IMP oImp = o;
        id block = ^id(id self, SEL _cmd, NSString *bid) {
            if (wx_bool(kNoJumpEnabled, YES) && bid &&
                [bid isEqualToString:@"com.tencent.wetype"]) {
                NSLog(@"[WxKbNoJump] blocked LSApplicationWorkspace openApp (jump to main app)");
                return nil;
            }
            id (*orig)(id, SEL, id) = (id(*)(id, SEL, id))oImp;
            return orig(self, _cmd, bid);
        };
        IMP ni = imp_implementationWithBlock(block);
        if (ni) method_setImplementation(m, ni);
    }
}

// 双保险：拦截到跳转 scheme 时，主动拉起扩展内录音（仅当 WeType 没走 nativeMode 时才走到
// 这里，故不会重复启动）。全程 @try/@catch + respondsToSelector 包裹，取不到单例/方法不符
// 只打日志不崩。每次扩展启动最多触发一次。
static void wx_tryStartNativeVoice(NSExtensionContext *ctx) {
    static BOOL s_tried = NO;
    if (s_tried) return;                 // 整个扩展生命周期只试一次，避免重复触发录音
    s_tried = YES;
    if (!wx_bool(kNoJumpEnabled, YES)) return;
    @try {
        Class vis = NSClassFromString(@"WBVoiceInputService");
        if (!vis) { NSLog(@"[WxKbNoJump] native trigger: WBVoiceInputService class not found"); return; }
        // 尝试各常见单例取方法，拿到服务实例
        id svc = nil;
        NSArray<NSString *> *singletons = @[@"sharedInstance", @"sharedService", @"defaultService",
                                            @"service", @"currentService", @"sharedVoiceService",
                                            @"voiceService"];
        for (NSString *sm in singletons) {
            SEL s = NSSelectorFromString(sm);
            if ([vis respondsToSelector:s]) {
                id (*get)(id, SEL) = (id(*)(id, SEL))objc_msgSend;
                svc = get(vis, s);
                if (svc) { NSLog(@"[WxKbNoJump] native trigger: got service via +%@", sm); break; }
            }
        }
        if (!svc) {
            // 退路：看 WBInputViewController / WBRootViewManager 是否持有 voiceService 属性
            NSLog(@"[WxKbNoJump] native trigger: no singleton instance, will try property fallback");
        }
        if (!ctx) { NSLog(@"[WxKbNoJump] native trigger: extensionContext is nil, abort"); return; }

        // 优先 nativeMode_launchWithContext:finishedBlock:（2 对象参数，用 NSInvocation 安全传）
        SEL s1 = @selector(nativeMode_launchWithContext:finishedBlock:);
        if (svc && [svc respondsToSelector:s1]) {
            void (^fb)(BOOL) = ^(BOOL ok){ NSLog(@"[WxKbNoJump] native trigger finished ok=%d", ok); };
            NSMethodSignature *sig = [svc methodSignatureForSelector:s1];
            if (sig) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:svc]; [inv setSelector:s1];
                [inv setArgument:&ctx atIndex:2];
                [inv setArgument:&fb  atIndex:3];
                [inv invoke];
                NSLog(@"[WxKbNoJump] native trigger: called nativeMode_launchWithContext:finishedBlock:");
                return;
            }
        }
        // 退而求其次：nativeMode_launchWithContext:
        SEL s2 = @selector(nativeMode_launchWithContext:);
        if (svc && [svc respondsToSelector:s2]) {
            ((void(*)(id,SEL,id))objc_msgSend)(svc, s2, ctx);
            NSLog(@"[WxKbNoJump] native trigger: called nativeMode_launchWithContext:");
            return;
        }
        // 再退：beginRecord（0 参）
        SEL s3 = @selector(beginRecord);
        if (svc && [svc respondsToSelector:s3]) {
            ((void(*)(id,SEL))objc_msgSend)(svc, s3);
            NSLog(@"[WxKbNoJump] native trigger: called beginRecord");
            return;
        }
        NSLog(@"[WxKbNoJump] native trigger: service found but no suitable launch selector");
    } @catch (NSException *e) {
        NSLog(@"[WxKbNoJump] native trigger EXCEPTION: %@", e);
    }
}

// 拦截键盘扩展进程内的 openURL（真机 trace 证明跳转正是通过扩展的
// NSExtensionContext/UIApplication openURL(wetype://WXKBURL_STARTVOICERECORD…) 发起，
// 而不是 LSApplicationWorkspace）。命中跳转 scheme 时直接吞掉、不真正打开，
// 同时假装成功回调，让 WeType 以为“已处理”，从而不闪跳、也不拉起 wxkb.app 主程序。
static void wx_interceptExtOpenURL(void) {
    if (!wx_bool(kNoJumpEnabled, YES)) return;
    NSString *const kJmp = @"WXKBURL_STARTVOICERECORD";

    // NSExtensionContext openURL:completionHandler:  （扩展拉起主程序的标准方式）
    Class ec = NSClassFromString(@"NSExtensionContext");
    if (ec) {
        SEL s = @selector(openURL:completionHandler:);
        Method m = class_getInstanceMethod(ec, s);
        if (m) {
            IMP o = method_getImplementation(m); __block IMP oImp = o;
            id block = ^void(id self, SEL _cmd, NSURL *url, void (^cb)(BOOL)) {
                NSString *u = [url absoluteString];
                if (u && [u rangeOfString:kJmp].location != NSNotFound) {
                    NSLog(@"[WxKbNoJump] BLOCK extension openURL (jump scheme): %@", u);
                    wx_tryStartNativeVoice((NSExtensionContext *)self);   // 双保险：主动起内录
                    if (cb) cb(YES);
                    return;
                }
                void (*orig)(id, SEL, id, void(^)(BOOL)) = (void(*)(id,SEL,id,void(^)(BOOL)))oImp;
                orig(self, _cmd, url, cb);
            };
            IMP ni = imp_implementationWithBlock(block);
            if (ni) method_setImplementation(m, ni);
        }
    }
    // UIApplication openURL: / openURL:options:completionHandler:
    Class ua = NSClassFromString(@"UIApplication");
    if (ua) {
        SEL s1 = @selector(openURL:);
        Method m1 = class_getInstanceMethod(ua, s1);
        if (m1) {
            IMP o = method_getImplementation(m1); __block IMP oImp = o;
            id block = ^BOOL(id self, SEL _cmd, NSURL *url) {
                NSString *u = [url absoluteString];
                if (u && [u rangeOfString:kJmp].location != NSNotFound) {
                    NSLog(@"[WxKbNoJump] BLOCK UIApplication openURL (jump scheme): %@", u);
                    return YES;
                }
                BOOL (*orig)(id, SEL, id) = (BOOL(*)(id,SEL,id))oImp;
                return orig(self, _cmd, url);
            };
            IMP ni = imp_implementationWithBlock(block);
            if (ni) method_setImplementation(m1, ni);
        }
        SEL s2 = @selector(openURL:options:completionHandler:);
        Method m2 = class_getInstanceMethod(ua, s2);
        if (m2) {
            IMP o = method_getImplementation(m2); __block IMP oImp = o;
            id block = ^void(id self, SEL _cmd, NSURL *url, id opts, void (^cb)(BOOL)) {
                NSString *u = [url absoluteString];
                if (u && [u rangeOfString:kJmp].location != NSNotFound) {
                    NSLog(@"[WxKbNoJump] BLOCK UIApplication openURL:options: (jump scheme): %@", u);
                    if (cb) cb(YES);
                    return;
                }
                void (*orig)(id, SEL, id, id, void(^)(BOOL)) = (void(*)(id,SEL,id,id,void(^)(BOOL)))oImp;
                orig(self, _cmd, url, opts, cb);
            };
            IMP ni = imp_implementationWithBlock(block);
            if (ni) method_setImplementation(m2, ni);
        }
    }
    // UIInputViewController openURL:completionHandler:
    Class ivc = NSClassFromString(@"UIInputViewController");
    if (ivc) {
        SEL s = @selector(openURL:completionHandler:);
        Method m = class_getInstanceMethod(ivc, s);
        if (m) {
            IMP o = method_getImplementation(m); __block IMP oImp = o;
            id block = ^void(id self, SEL _cmd, NSURL *url, void (^cb)(BOOL)) {
                NSString *u = [url absoluteString];
                if (u && [u rangeOfString:kJmp].location != NSNotFound) {
                    NSLog(@"[WxKbNoJump] BLOCK UIInputViewController openURL (jump scheme): %@", u);
                    NSExtensionContext *ectx = nil;
                    @try { if ([self respondsToSelector:@selector(extensionContext)]) ectx = [self extensionContext]; } @catch (NSException *e) {}
                    wx_tryStartNativeVoice(ectx);   // 双保险：主动起内录
                    if (cb) cb(YES);
                    return;
                }
                void (*orig)(id, SEL, id, void(^)(BOOL)) = (void(*)(id,SEL,id,void(^)(BOOL)))oImp;
                orig(self, _cmd, url, cb);
            };
            IMP ni = imp_implementationWithBlock(block);
            if (ni) method_setImplementation(m, ni);
        }
    }
}

static BOOL wx_voiceOverridden = NO;
static void wx_applyVoiceNoJump(void) {
    if (wx_voiceOverridden) return;
    // ③-bis 扩展内 openURL 真拦截（真机 trace 证明跳转正是通过扩展的
    //     NSExtensionContext/UIApplication openURL(wetype://WXKBURL_STARTVOICERECORD) 发起，
    //     而不是 LSApplicationWorkspace）。这一层是“任何判定被触发都不可能跳”的硬保险。
    static BOOL s_urlHooked = NO;
    if (!s_urlHooked) { wx_interceptExtOpenURL(); s_urlHooked = YES; }
    Class rvm = NSClassFromString(@"WBRootViewManager");
    Class vis = NSClassFromString(@"WBVoiceInputService");
    if (!rvm || !vis) {
        // 类尚未注册（扩展刚启动 / 懒加载），0.3s 后自重试，最多 ~6s
        static int s_retries = 0;
        if (s_retries < 20) {
            s_retries++;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ wx_applyVoiceNoJump(); });
        }
        return;
    }
    // ① 强制全部 canUseWcVoice* = YES（走扩展内录音路径）
    wx_overrideReturnBool(rvm, @selector(canUseWcVoice), YES);
    wx_overrideReturnBool(rvm, @selector(canUseWcVoiceByWormhole), YES);
    wx_overrideReturnBool(rvm, @selector(canUseWcVoiceByConfig), YES);
    wx_overrideReturnBool(vis, @selector(isUsingWcVoice), YES);
    // ① 真正总开关（frida dump 出的 nativeMode_* 路径入口）：强制“走扩展内录音”
    wx_overrideReturnBool(vis, @selector(shouldUseNativeVoiceForCurrentLaunch), YES);
    wx_overrideReturnBool(vis, @selector(checkCanOpenRecorderDirectly), YES);
    // ① 强制 prefers/requireJump = NO
    wx_overrideReturnBool(rvm, @selector(prefersJumpToMainAppForRecording), NO);
    wx_overrideReturnBool(vis, @selector(requireJumpToMainAppForRecording), NO);
    // ② 兜底：jump 发起方法变空操作
    wx_neutralizeVoid(rvm, @selector(jumpToPageWithToolBarFunc:));
    wx_neutralizeVoid(rvm, @selector(preJumpToPageWithToolBarFunc:));
    // ③ 保险：拦截 LSApplicationWorkspace 拉起主程序
    wx_blockJumpURLScheme();
    wx_voiceOverridden = YES;
    NSLog(@"[WxKbNoJump] voice no-jump (3-layer + native trigger) applied v1.1.14");
}

#pragma mark - WBInputViewController 外观 hook

@interface NSObject (WxKbStyle)
- (void)wx_kb_viewDidLayoutSubviews;
@end
@implementation NSObject (WxKbStyle)
- (void)wx_kb_viewDidLayoutSubviews {
    [self wx_kb_viewDidLayoutSubviews];
    if (![self isKindOfClass:objc_getClass("WBInputViewController")]) return;
    // 键盘视图已存在，WeType 语音类必然已注册 → 保证免跳生效（即使启动早期类未就绪）
    if (!wx_voiceOverridden) wx_applyVoiceNoJump();
    UIView *root = nil;
    if ([self respondsToSelector:@selector(view)]) root = [(UIViewController *)self view];
    if (!root) return;
    wx_applyStyle(root);
}
@end

#pragma mark - 入口

__attribute__((constructor))
static void wx_entry(void) {
    @autoreleasepool {
        BOOL kb = wx_isKbExtension();
        BOOL main = wx_isMainApp();
        NSLog(@"[WxKbNoJump] LOADED pid=%d kbExt=%d mainApp=%d noJump=%d style=%d v=1.1.14",
              getpid(), kb, main, wx_bool(kNoJumpEnabled, YES), wx_bool(kStyleEnabled, NO));

        // 1) 微信自带免跳标志恒真（锦上添花）
        wx_swizzle([NSUserDefaults class], @selector(objectForKey:),    @selector(wx_objectForKey:));
        wx_swizzle([NSUserDefaults class], @selector(boolForKey:),      @selector(wx_boolForKey:));

        // 2) 强制判定方法走内建路径（免跳核心，运行期 IMP 替换）
        wx_applyVoiceNoJump();   // 类已注册则立即生效；否则下面延后重试

        // 3) 外观 hook（延后挂，WBInputViewController 在首帧后才存在）
        static BOOL didHookStyle = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (didHookStyle) return;
            Class c = objc_getClass("WBInputViewController");
            if (c) {
                wx_swizzle(c, @selector(viewDidLayoutSubviews), @selector(wx_kb_viewDidLayoutSubviews));
                didHookStyle = YES;
            }
            // 延后重试免跳 IMP 替换（扩展启动早期 WBRootViewManager 等可能尚未注册）
            if (!wx_voiceOverridden) wx_applyVoiceNoJump();
        });

        NSLog(@"[WxKbNoJump] INIT DONE v1.1.14 (kbExt=%d mainApp=%d)", kb, main);
    }
}

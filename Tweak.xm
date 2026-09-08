//
//  Tweak.xm — 微信键盘免跳转 + 键盘外观定制 (rootless deb / ElleKit TweakInject)
//
//  目标进程（见 WxKbNoJump.plist Filter）：
//    com.tencent.wetype.keyboard  —— 键盘扩展（全局跑的进程，语音按钮与键盘 UI 都在这里）
//    com.tencent.wetype           —— 主 app（设置/管理壳）
//    com.apple.Preferences        —— 系统设置（加载本 tweak / PreferenceBundle）
//
//  免跳转三层保险：
//   1) NSUserDefaults hook：对微信自带键 WBAppSettingsBool_VoiceInput_WcVoiceNoJump
//      恒返回 YES，让 App 原生「微信语音免跳转」逻辑生效（最稳，不依赖私有方法名）。
//   2) WBFunctionToolBar 语音按钮拦截：直接激活键盘内建语音输入，不触发跳转。
//   3) openURL 拦截：UIInputViewController / NSExtensionContext / UIApplication 三处，
//      凡是从扩展发出的 wetype:// 语音跳转一律吞掉；并拦掉语音/麦克风/权限设置页弹出。
//
//  外观定制：hook WBInputViewController -viewDidLayoutSubviews，把圆角/大小/颜色/透明度
//  应用到键盘根视图（WBRootInputView 或 self.view）。
//
//  设置来源：系统-设置面板(PreferenceLoader)写入
//    /var/mobile/Library/Preferences/com.wxkbd.nojump.plist
//  tweak 直接读该文件（每次都重新读，跨进程改动即时生效，无需缓存）。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - 配置

static NSString *const kWxSuite        = @"com.wxkbd.nojump";
static NSString *const kWxNoJumpKey    = @"WBAppSettingsBool_VoiceInput_WcVoiceNoJump";

static NSString *const kNoJumpEnabled  = @"wxkbdNoJumpEnabled";
static NSString *const kStyleEnabled   = @"wxkbdStyleEnabled";
static NSString *const kCornerRadius   = @"wxkbdCornerRadius";
static NSString *const kBgR            = @"wxkbdBgR";
static NSString *const kBgG            = @"wxkbdBgG";
static NSString *const kBgB            = @"wxkbdBgB";
static NSString *const kBgAlpha        = @"wxkbdBgAlpha";
static NSString *const kScale          = @"wxkbdScale";

static NSString *wx_prefPath(void) {
    return [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist", kWxSuite];
}
static BOOL wx_bool(NSString *k, BOOL def) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:wx_prefPath()];
    id v = d[k];
    if (v && [v respondsToSelector:@selector(boolValue)]) return [v boolValue];
    return def;
}
static CGFloat wx_float(NSString *k, CGFloat def) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:wx_prefPath()];
    id v = d[k];
    if (v && [v respondsToSelector:@selector(floatValue)]) return [v floatValue];
    return def;
}

#pragma mark - 进程识别

// 键盘扩展被宿主 app 托管，mainBundle 返回宿主 id；只能靠「微信输入法特有类」判断。
static BOOL wx_isKbExtension(void) { return (NSClassFromString(@"WBInputViewController") != nil); }
static BOOL wx_isMainApp(void) {
    NSString *b = [[NSBundle mainBundle] bundleIdentifier];
    return (b && [b isEqualToString:@"com.tencent.wetype"]);
}

#pragma mark - 免跳转 URL 判定

static BOOL wx_blockURL(NSURL *url) {
    if (!wx_bool(kNoJumpEnabled, YES)) return NO;
    if (!url) return NO;
    NSString *s = url.absoluteString.lowercaseString;
    if ([s hasPrefix:@"wetype://"] || [s hasPrefix:@"wxkb://"] || [s hasPrefix:@"wetypetest://"]) {
        if ([s containsString:@"voice"]  || [s containsString:@"record"]  ||
            [s containsString:@"wtactionopen"] || [s containsString:@"asr"] ||
            [s containsString:@"recogni"] || [s containsString:@"speech"] ||
            [s containsString:@"dictate"] || [s containsString:@"wtaction"] ||
            [s containsString:@"jump"]   || [s containsString:@"redirect"]) {
            return YES;
        }
        return NO;
    }
    return NO;
}

#pragma mark - 外观应用

static void wx_applyStyle(UIView *root) {
    if (!root) return;
    if (!wx_bool(kStyleEnabled, NO)) return;

    CGFloat cr = MIN(MAX(wx_float(kCornerRadius, 10.0), 0), 40);
    CGFloat r  = MIN(MAX(wx_float(kBgR, 0.15), 0), 1);
    CGFloat g  = MIN(MAX(wx_float(kBgG, 0.16), 0), 1);
    CGFloat b  = MIN(MAX(wx_float(kBgB, 0.20), 0), 1);
    CGFloat a  = MIN(MAX(wx_float(kBgAlpha, 1.0), 0.2), 1);
    CGFloat sc = MIN(MAX(wx_float(kScale, 1.0), 0.6), 1.4);

    root.backgroundColor = [UIColor colorWithRed:r green:g blue:b alpha:1.0];
    root.layer.cornerRadius = cr;
    root.layer.masksToBounds = (cr > 0);
    root.alpha = a;
    root.transform = CGAffineTransformMakeScale(sc, sc);
}

#pragma mark - 在键盘扩展里直接激活内建语音输入（第三方 app 免跳转核心）

static UIView *wx_findFirstResponder(UIView *v) {
    if (!v) return nil;
    if ([v isFirstResponder]) return v;
    for (UIView *sub in v.subviews) {
        UIView *r = wx_findFirstResponder(sub);
        if (r) return r;
    }
    return nil;
}

static void wx_tryActivateVoiceInKeyboard(UIInputViewController *ivc) {
    // 1) 找到当前键盘的 inputViewController
    if (!ivc) {
        // 兜底：从 first responder 链向上找（扩展中 UIApplication.sharedApplication 常为 nil）
        UIApplication *app = [UIApplication sharedApplication];
        UIResponder *first = nil;
        if (app && app.keyWindow && app.keyWindow.rootViewController) {
            first = wx_findFirstResponder(app.keyWindow.rootViewController.view);
        }
        if (!first && app) {
            for (UIWindow *w in app.windows) {
                first = wx_findFirstResponder(w);
                if (first) break;
            }
        }
        UIResponder *r = first;
        while (r) {
            if ([r isKindOfClass:[UIInputViewController class]]) { ivc = (UIInputViewController *)r; break; }
            r = [r nextResponder];
        }
    }
    if (!ivc) {
        NSLog(@"[WxKbNoJump] activateVoice: no UIInputViewController");
        return;
    }

    // 2) 从 inputViewController.view 里找 WBRootInputView
    Class rvCls = NSClassFromString(@"WBRootInputView");
    UIView *target = ivc.view;
    if (rvCls) {
        for (UIView *sub in ivc.view.subviews) {
            if ([sub isKindOfClass:rvCls]) { target = sub; break; }
        }
    }
    if (!target) {
        NSLog(@"[WxKbNoJump] activateVoice: no WBRootInputView");
        return;
    }

    // 3) 激活语音输入视图
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    SEL initSel = @selector(initVoiceInputInteractionViewIfNeeded);
    SEL actSel  = @selector(setVoiceInputInteractionViewActive:);
    if ([target respondsToSelector:initSel]) {
        [target performSelector:initSel];
        NSLog(@"[WxKbNoJump] activated voice view on %@", target);
    }
    if ([target respondsToSelector:actSel]) {
        [target performSelector:actSel withObject:@YES];
    }
    #pragma clang diagnostic pop
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

#pragma mark - NSUserDefaults 免跳转键恒真

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

#pragma mark - WBFunctionToolBar 语音按钮拦截（直接激活键盘内建语音）

@interface NSObject (WxKbToolBar)
- (void)wx_handleItemClickEvent:(id)event func:(int)func controlEvent:(UIControlEvents)ctrl;
@end
@implementation NSObject (WxKbToolBar)
- (void)wx_handleItemClickEvent:(id)event func:(int)func controlEvent:(UIControlEvents)ctrl {
    if (func == 0x1 && wx_bool(kNoJumpEnabled, YES) && NSClassFromString(@"WBFunctionToolBar")) {
        Class rvCls = NSClassFromString(@"WBRootInputView");
        if (rvCls) {
            UIView *v = [(UIView *)self superview];
            while (v) {
                if ([v isKindOfClass:rvCls]) {
                    typedef void (*V)(id, SEL);
                    typedef void (*VB)(id, SEL, BOOL);
                    ((V)objc_msgSend)(v, @selector(initVoiceInputInteractionViewIfNeeded));
                    ((VB)objc_msgSend)(v, @selector(setVoiceInputInteractionViewActive:), YES);
                    ((VB)objc_msgSend)((id)self, @selector(setHidden:), YES);
                    return;
                }
                v = [v superview];
            }
        }
        [self wx_handleItemClickEvent:event func:func controlEvent:ctrl];
        return;
    }
    [self wx_handleItemClickEvent:event func:func controlEvent:ctrl];
}
@end

#pragma mark - UIInputViewController openURL 拦截（扩展拉起主 app 的专用 API）

@interface UIInputViewController (WxKbNoJump)
- (BOOL)wx_ii_openURL:(NSURL *)url;
- (void)wx_ii_openURL:(NSURL *)url options:(NSDictionary *)opts completionHandler:(void(^)(BOOL))h;
@end
@implementation UIInputViewController (WxKbNoJump)
- (BOOL)wx_ii_openURL:(NSURL *)url {
    if (wx_blockURL(url)) {
        NSLog(@"[WxKbNoJump] UIInputViewController openURL blocked: %@", url);
        wx_tryActivateVoiceInKeyboard(self);
        return NO;
    }
    return [self wx_ii_openURL:url];
}
- (void)wx_ii_openURL:(NSURL *)url options:(NSDictionary *)opts completionHandler:(void(^)(BOOL))h {
    if (wx_blockURL(url)) {
        NSLog(@"[WxKbNoJump] UIInputViewController openURL(blocked) options: %@", url);
        wx_tryActivateVoiceInKeyboard(self);
        if (h) h(NO);
        return;
    }
    [self wx_ii_openURL:url options:opts completionHandler:h];
}
@end

#pragma mark - NSExtensionContext openURL 拦截（兜底）

@interface NSExtensionContext (WxKbNoJump)
- (BOOL)wx_ec_openURL:(NSURL *)url;
- (void)wx_ec_openURL:(NSURL *)url completionHandler:(void(^)(BOOL))h;
@end
@implementation NSExtensionContext (WxKbNoJump)
- (BOOL)wx_ec_openURL:(NSURL *)url {
    if (wx_blockURL(url)) {
        NSLog(@"[WxKbNoJump] NSExtensionContext openURL blocked: %@", url);
        wx_tryActivateVoiceInKeyboard(nil);
        return NO;
    }
    return [self wx_ec_openURL:url];
}
- (void)wx_ec_openURL:(NSURL *)url completionHandler:(void(^)(BOOL))h {
    if (wx_blockURL(url)) {
        NSLog(@"[WxKbNoJump] NSExtensionContext openURL(blocked) completion: %@", url);
        wx_tryActivateVoiceInKeyboard(nil);
        if (h) h(NO);
        return;
    }
    [self wx_ec_openURL:url completionHandler:h];
}
@end

#pragma mark - UIApplication openURL 拦截（主 app 兜底）

@interface UIApplication (WxKbNoJump)
- (void)wx_app_openURL:(NSURL *)url options:(NSDictionary *)opts completionHandler:(void(^)(BOOL))h;
@end
@implementation UIApplication (WxKbNoJump)
- (void)wx_app_openURL:(NSURL *)url options:(NSDictionary *)opts completionHandler:(void(^)(BOOL))h {
    if (wx_blockURL(url)) { if (h) h(NO); return; }
    [self wx_app_openURL:url options:opts completionHandler:h];
}
@end

#pragma mark - UIViewController 拦掉语音/麦克风/权限设置页弹出

@interface UIViewController (WxKbNoJump)
- (void)wx_present:(UIViewController *)vc animated:(BOOL)flag completion:(void(^)(void))completion;
@end
@implementation UIViewController (WxKbNoJump)
- (void)wx_present:(UIViewController *)vc animated:(BOOL)flag completion:(void(^)(void))completion {
    const char *cn = class_getName([vc class]);
    // 微信键盘自己的 VC（WB*/WZ*）放行，不要误拦内部语音界面
    if (cn && (strncmp(cn, "WB", 2) == 0 || strncmp(cn, "WZ", 2) == 0)) {
        [self wx_present:vc animated:flag completion:completion];
        return;
    }
    // 只拦明显的权限/设置/授权类弹窗，避免跳到系统设置或反复要麦克风权限
    if (cn && (strstr(cn, "Permission") || strstr(cn, "permission") ||
               strstr(cn, "Setting")   || strstr(cn, "setting") ||
               strstr(cn, "Auth")      || strstr(cn, "auth") ||
               strstr(cn, "Privacy")   || strstr(cn, "privacy"))) {
        NSLog(@"[WxKbNoJump] blocked presented VC: %s", cn);
        return;
    }
    [self wx_present:vc animated:flag completion:completion];
}
@end

#pragma mark - WBInputViewController 外观 hook

@interface NSObject (WxKbStyle)
- (void)wx_kb_viewDidLayoutSubviews;
@end
@implementation NSObject (WxKbStyle)
- (void)wx_kb_viewDidLayoutSubviews {
    [self wx_kb_viewDidLayoutSubviews];
    if (![self isKindOfClass:objc_getClass("WBInputViewController")]) return;
    if (!wx_bool(kStyleEnabled, NO)) return;
    UIView *root = nil;
    if ([self respondsToSelector:@selector(view)]) root = [(UIViewController *)self view];
    if (!root) return;
    Class rv = NSClassFromString(@"WBRootInputView");
    UIView *target = root;
    if (rv) {
        for (UIView *sub in root.subviews) {
            if ([sub isKindOfClass:rv]) { target = sub; break; }
        }
    }
    wx_applyStyle(target);
}
@end

#pragma mark - 入口

__attribute__((constructor))
static void wx_entry(void) {
    @autoreleasepool {
        BOOL kb = wx_isKbExtension();
        BOOL main = wx_isMainApp();
        NSLog(@"[WxKbNoJump] LOADED pid=%d kbExt=%d mainApp=%d noJump=%d style=%d",
              getpid(), kb, main, wx_bool(kNoJumpEnabled, YES), wx_bool(kStyleEnabled, NO));

        wx_swizzle([NSUserDefaults class], @selector(objectForKey:),    @selector(wx_objectForKey:));
        wx_swizzle([NSUserDefaults class], @selector(boolForKey:),      @selector(wx_boolForKey:));

        Class tb = NSClassFromString(@"WBFunctionToolBar");
        if (tb) wx_swizzle(tb, @selector(handleItemClickEvent:func:controlEvent:),
                              @selector(wx_handleItemClickEvent:func:controlEvent:));

        wx_swizzle([UIInputViewController class], @selector(openURL:), @selector(wx_ii_openURL:));
        wx_swizzle([UIInputViewController class],
                   @selector(openURL:options:completionHandler:),
                   @selector(wx_ii_openURL:options:completionHandler:));
        if (NSClassFromString(@"NSExtensionContext")) {
            wx_swizzle(NSClassFromString(@"NSExtensionContext"), @selector(openURL:), @selector(wx_ec_openURL:));
            wx_swizzle(NSClassFromString(@"NSExtensionContext"),
                       @selector(openURL:completionHandler:), @selector(wx_ec_openURL:completionHandler:));
        }
        wx_swizzle([UIApplication class],
                   @selector(openURL:options:completionHandler:),
                   @selector(wx_app_openURL:options:completionHandler:));

        wx_swizzle([UIViewController class],
                   @selector(presentViewController:animated:completion:),
                   @selector(wx_present:animated:completion:));

        Class kbVC = objc_getClass("WBInputViewController");
        if (kbVC) {
            wx_swizzle(kbVC, @selector(viewDidLayoutSubviews), @selector(wx_kb_viewDidLayoutSubviews));
        } else {
            for (int i = 0; i < 6; i++) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((i+1)*0.4*NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    Class c = objc_getClass("WBInputViewController");
                    if (c) wx_swizzle(c, @selector(viewDidLayoutSubviews), @selector(wx_kb_viewDidLayoutSubviews));
                });
            }
        }
        NSLog(@"[WxKbNoJump] INIT DONE (kbExt=%d mainApp=%d)", kb, main);
    }
}

//
//  WxKeyboardNoJump.m
//  微信键盘免跳转 + 键盘外观定制  (TrollStore / TrollFools 注入式 dylib)
//
//  设计要点：
//   - 纯 Objective-C，手动 method swizzling，不依赖 CydiaSubstrate / ElleKit。
//     可被任意注入工具加载（TrollFools / relaxin / dylib插件库）。
//   - 核心注入目标：wxkb_plugin.appex（键盘扩展，com.tencent.wetype.keyboard）。
//     它是被各宿主 app（微信/其他 app）托管的全局扩展进程，键盘 UI 与语音按钮都跑在这里。
//     微信输入法主 app（wxkb.app）只是设置/管理壳，其进程里没有键盘 UI，语音跳转也不走它。
//     只注主 app 无效——必须注键盘扩展。
//   - 主程序 wxkb.app 可顺带注入，用于把 系统-设置(Settings.bundle 写入 com.tencent.wetype)
//     的值镜像到全局 plist；但免跳转默认即开启，仅注键盘扩展也已生效。
//   - 关键认知：键盘扩展进程里 [NSBundle mainBundle] 返回的是宿主 app 的 bundle id
//     （如微信的 com.tencent.xin），NOT com.tencent.wetype.keyboard。因此本 dylib 用
//     「微信输入法特有类 WBInputViewController 是否存在」来判断当前是否键盘扩展进程，
//     而不是用 mainBundle.bundleIdentifier 比较。
//
//  免跳转原理（双保险 + 覆盖扩展专用 API）：
//   1) hook NSUserDefaults -objectForKey:/-boolForKey: 对
//      WBAppSettingsBool_VoiceInput_WcVoiceNoJump 永远返回 YES（开启时）。
//   2) hook 跳转入口。键盘扩展是独立进程，拉起主 app 用的是扩展专用 API
//      -[UIInputViewController openURL:]/openURL:options:completionHandler:（以及
//      -[NSExtensionContext openURL:]），不是 UIApplication.openURL:。三个都 hook。
//      凡是从扩展发出的 wetype:// / wxkb:// 语音跳转 URL 一律吞掉。
//
//  诊断：所有加载/拦截/命中键事件写入 /var/mobile/wxkbd_diag.log
//        （因为本机 frida 无法 attach 微信输入法进程，落盘日志用于确认生效）。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#pragma mark - 常量

// 微信输入法自带的「微信语音免跳转」偏好键
static NSString *const kWxNoJumpKey = @"WBAppSettingsBool_VoiceInput_WcVoiceNoJump";

// 我们的设置写入的域（Settings.bundle 在 wxkb.app 内，原生写入 com.tencent.wetype）
static NSString *const kAppDomain = @"com.tencent.wetype";

// 主程序与键盘扩展共享的全局 plist（/var/mobile 为 mobile 用户家目录，二者都可访问）
static NSString *const kGlobalPrefPath = @"/var/mobile/Library/Preferences/com.user.wxkbdnojump.plist";
static NSString *const kReloadNotify = @"com.user.wxkbdnojump/changed";

// 我们的设置键
static NSString *const kNoJumpEnabled = @"wxkbdNoJumpEnabled";   // bool 1/0
static NSString *const kStyleEnabled  = @"wxkbdStyleEnabled";    // bool 1/0
static NSString *const kCornerRadius  = @"wxkbdCornerRadius";    // float
static NSString *const kBgR          = @"wxkbdBgR";              // float 0-1
static NSString *const kBgG          = @"wxkbdBgG";              // float 0-1
static NSString *const kBgB          = @"wxkbdBgB";              // float 0-1
static NSString *const kBgAlpha      = @"wxkbdBgAlpha";          // float 0-1
static NSString *const kScale        = @"wxkbdScale";            // float 0.5-1.5

static NSString *const kDiagPath = @"/var/mobile/wxkbd_diag.log";

#pragma mark - 诊断落盘

static void wxkbd_diag(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    @try {
        NSString *prev = [NSString stringWithContentsOfFile:kDiagPath
                                                    encoding:NSUTF8StringEncoding error:nil];
        NSDate *now = [NSDate date];
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", now, msg];
        NSString *out = prev ? [prev stringByAppendingString:line] : line;
        [out writeToFile:kDiagPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
    } @catch (...) {}
    NSLog(@"[WxKeyboardNoJump] %@", msg);
}

#pragma mark - 全局偏好读写（共享文件）

static NSDictionary *wxkbd_readGlobal(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kGlobalPrefPath];
    return d ?: @{};
}

static void wxkbd_writeGlobal(NSDictionary *d) {
    if (!d) return;
    NSString *dir = [kGlobalPrefPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                               withIntermediateDirectories:YES
                                                attributes:nil
                                                     error:nil];
    [d writeToFile:kGlobalPrefPath atomically:YES];
}

// 主程序进程：把 com.tencent.wetype 里我们写入的键镜像到全局文件
static void wxkbd_mirrorFromAppDomain(void) {
    @try {
        NSUserDefaults *app = [NSUserDefaults standardUserDefaults]; // 主程序域 = com.tencent.wetype
        NSMutableDictionary *g = [wxkbd_readGlobal() mutableCopy] ?: [NSMutableDictionary dictionary];
        NSArray *keys = @[kNoJumpEnabled, kStyleEnabled, kCornerRadius, kBgR, kBgG, kBgB, kBgAlpha, kScale];
        for (NSString *k in keys) {
            id v = [app objectForKey:k];
            if (v) g[k] = v;
        }
        wxkbd_writeGlobal(g);
        wxkbd_diag(@"mirrorFromApp: %@", g);
    } @catch (...) {}
}

static BOOL wxkbd_bool(NSString *key, BOOL def) {
    id v = wxkbd_readGlobal()[key];
    if (v && [v respondsToSelector:@selector(boolValue)]) return [v boolValue];
    return def;
}
static CGFloat wxkbd_float(NSString *key, CGFloat def) {
    id v = wxkbd_readGlobal()[key];
    if (v && [v respondsToSelector:@selector(floatValue)]) return [v floatValue];
    return def;
}

// 键盘扩展进程：WBInputViewController 是微信输入法键盘专属类（由 wxkb_plugin.appex 提供）。
// 重要：键盘扩展被宿主 app（如微信）托管，进程内 [NSBundle mainBundle] 返回宿主 app 的
// bundle id（例如 com.tencent.xin），NOT com.tencent.wetype.keyboard。因此不能靠 mainBundle
// 判断本进程是不是键盘扩展，只能靠「微信输入法特有类是否存在」。
static BOOL wxkbd_isKbExtension(void) {
    return (NSClassFromString(@"WBInputViewController") != nil);
}
static BOOL wxkbd_isMainApp(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    return [bid isEqualToString:@"com.tencent.wetype"];
}
// 只有微信输入法相关进程才 hook（键盘扩展 / 主程序）。注入到无关 app 时不动作，避免副作用，
// 并在日志留下 SKIP 提示，方便排查「注入错目标」的问题。
static BOOL wxkbd_shouldRun(void) {
    return wxkbd_isKbExtension() || wxkbd_isMainApp();
}

#pragma mark - 免跳转判定

// 是否拦截该 URL（扩展进程里发出的 wetype:// / wxkb:// 语音跳转）
static BOOL wxkbd_blockURL(NSURL *url) {
    if (!wxkbd_bool(kNoJumpEnabled, YES)) return NO;
    if (!url) return NO;
    NSString *s = url.absoluteString.lowercaseString;
    // 扩展里发出的拉起主 app 的 scheme
    if ([s hasPrefix:@"wetype://"] || [s hasPrefix:@"wxkb://"]) {
        // 只拦「语音/录音/识别」相关的跳转，避免误伤键盘里跳设置等合法链接。
        // 关键字依据 IPA 内符号：WtAppActionOpenVoiceNoRedirectionWechat / handleVoiceRecordOpenURL:
        if ([s containsString:@"voice"] || [s containsString:@"record"] ||
            [s containsString:@"wtactionopen"] || [s containsString:@"asr"] ||
            [s containsString:@"recogni"] || [s containsString:@"speech"] ||
            [s containsString:@"dictate"] || [s containsString:@"wtaction"]) {
            return YES;
        }
        // 其他 wetype:// 不拦（如设置链接）。若诊断日志显示语音跳转未命中，请把日志发我补关键字。
        return NO;
    }
    return NO;
}

#pragma mark - 应用外观到键盘视图

static void wxkbd_applyStyleToView(UIView *root) {
    if (!root) return;
    if (!wxkbd_bool(kStyleEnabled, NO)) return;

    CGFloat cr   = wxkbd_float(kCornerRadius, 10.0);
    CGFloat r    = wxkbd_float(kBgR, 0.15);
    CGFloat gg   = wxkbd_float(kBgG, 0.16);
    CGFloat b    = wxkbd_float(kBgB, 0.20);
    CGFloat alpha= wxkbd_float(kBgAlpha, 1.0);
    CGFloat scale= wxkbd_float(kScale, 1.0);

    cr = MIN(MAX(cr, 0), 40);
    alpha = MIN(MAX(alpha, 0.2), 1.0);
    scale = MIN(MAX(scale, 0.6), 1.4);

    root.backgroundColor = [UIColor colorWithRed:r green:gg blue:b alpha:alpha];
    root.layer.cornerRadius = cr;
    root.layer.masksToBounds = (cr > 0);
    root.alpha = alpha;
    root.transform = CGAffineTransformMakeScale(scale, scale);
}

static void wxkbd_applyStyleGlobally(void) {
    @try {
        NSArray *wins = [UIApplication sharedApplication].windows;
        for (UIWindow *w in wins) {
            if (w.windowLevel > UIWindowLevelNormal) continue;
            for (UIView *v in w.subviews) wxkbd_applyStyleToView(v);
        }
    } @catch (...) {}
}

#pragma mark - Swizzle 辅助

static void wxkbd_swizzle(Class cls, SEL orig, SEL repl) {
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

#pragma mark - WBInputViewController 外观 hook

@interface NSObject (WxKbdSwizzle)
- (void)wxkbd_viewDidLayoutSubviews;
- (void)wxkbd_viewDidLoad;
@end

@implementation NSObject (WxKbdSwizzle)
- (void)wxkbd_viewDidLayoutSubviews {
    [self wxkbd_viewDidLayoutSubviews];
    if ([self isKindOfClass:objc_getClass("WBInputViewController")]) {
        UIView *root = nil;
        if ([self respondsToSelector:@selector(view)]) root = [(UIViewController *)self view];
        if (root) wxkbd_applyStyleToView(root);
    }
}
- (void)wxkbd_viewDidLoad {
    [self wxkbd_viewDidLoad];
    if ([self isKindOfClass:objc_getClass("WBInputViewController")]) {
        UIView *root = nil;
        if ([self respondsToSelector:@selector(view)]) root = [(UIViewController *)self view];
        if (root) wxkbd_applyStyleToView(root);
    }
}
@end

#pragma mark - NSUserDefaults 免跳转 hook

@interface NSUserDefaults (WxKbdNoJump)
- (id)wxkbd_objectForKey:(NSString *)key;
- (BOOL)wxkbd_boolForKey:(NSString *)key;
@end

@implementation NSUserDefaults (WxKbdNoJump)
- (id)wxkbd_objectForKey:(NSString *)key {
    if ([key isEqualToString:kWxNoJumpKey] && wxkbd_bool(kNoJumpEnabled, YES)) {
        wxkbd_diag(@"UD.objectForKey HIT %@ -> YES", key);
        return @YES;
    }
    return [self wxkbd_objectForKey:key];
}
- (BOOL)wxkbd_boolForKey:(NSString *)key {
    if ([key isEqualToString:kWxNoJumpKey] && wxkbd_bool(kNoJumpEnabled, YES)) {
        wxkbd_diag(@"UD.boolForKey HIT %@ -> YES", key);
        return YES;
    }
    return [self wxkbd_boolForKey:key];
}
@end

#pragma mark - UIApplication openURL 拦截（主 app / host 进程兜底）

@interface UIApplication (WxKbdNoJump)
- (BOOL)wxkbd_app_openURL:(NSURL *)url;
- (void)wxkbd_app_openURL:(NSURL *)url options:(NSDictionary *)opts completionHandler:(void(^)(BOOL))h;
@end

@implementation UIApplication (WxKbdNoJump)
- (BOOL)wxkbd_app_openURL:(NSURL *)url {
    if (wxkbd_blockURL(url)) { wxkbd_diag(@"[UIApplication] BLOCK %@", url.absoluteString); return NO; }
    return [self wxkbd_app_openURL:url];
}
- (void)wxkbd_app_openURL:(NSURL *)url options:(NSDictionary *)opts completionHandler:(void(^)(BOOL))h {
    if (wxkbd_blockURL(url)) { wxkbd_diag(@"[UIApplication] BLOCK(options) %@", url.absoluteString); if (h) h(NO); return; }
    [self wxkbd_app_openURL:url options:opts completionHandler:h];
}
@end

#pragma mark - UIInputViewController openURL 拦截（键盘扩展拉起主 app 的专用 API —— 关键修复）

@interface UIInputViewController (WxKbdNoJump)
- (BOOL)wxkbd_ii_openURL:(NSURL *)url;
- (void)wxkbd_ii_openURL:(NSURL *)url options:(NSDictionary *)opts completionHandler:(void(^)(BOOL))h;
@end

@implementation UIInputViewController (WxKbdNoJump)
- (BOOL)wxkbd_ii_openURL:(NSURL *)url {
    if (wxkbd_blockURL(url)) { wxkbd_diag(@"[UIInputViewController] BLOCK %@", url.absoluteString); return NO; }
    return [self wxkbd_ii_openURL:url];
}
- (void)wxkbd_ii_openURL:(NSURL *)url options:(NSDictionary *)opts completionHandler:(void(^)(BOOL))h {
    if (wxkbd_blockURL(url)) { wxkbd_diag(@"[UIInputViewController] BLOCK(options) %@", url.absoluteString); if (h) h(NO); return; }
    [self wxkbd_ii_openURL:url options:opts completionHandler:h];
}
@end

#pragma mark - NSExtensionContext openURL 拦截（扩展上下文方式兜底）

@interface NSExtensionContext (WxKbdNoJump)
- (BOOL)wxkbd_ec_openURL:(NSURL *)url;
- (void)wxkbd_ec_openURL:(NSURL *)url completionHandler:(void(^)(BOOL))h;
@end

@implementation NSExtensionContext (WxKbdNoJump)
- (BOOL)wxkbd_ec_openURL:(NSURL *)url {
    if (wxkbd_blockURL(url)) { wxkbd_diag(@"[NSExtensionContext] BLOCK %@", url.absoluteString); return NO; }
    return [self wxkbd_ec_openURL:url];
}
- (void)wxkbd_ec_openURL:(NSURL *)url completionHandler:(void(^)(BOOL))h {
    if (wxkbd_blockURL(url)) { wxkbd_diag(@"[NSExtensionContext] BLOCK(comp) %@", url.absoluteString); if (h) h(NO); return; }
    [self wxkbd_ec_openURL:url completionHandler:h];
}
@end

#pragma mark - 通知回调

static void wxkbd_prefsChanged(CFNotificationCenterRef center, void *observer,
                               CFStringRef name, const void *object, CFDictionaryRef info) {
    wxkbd_mirrorFromAppDomain();
}

#pragma mark - 入口

__attribute__((constructor))
static void wxkbd_entry(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"(unknown)";
        BOOL kbExt   = wxkbd_isKbExtension();
        BOOL mainApp = wxkbd_isMainApp();
        wxkbd_diag(@"LOADED pid=%d mainBid=%@ isKbExt=%d isMainApp=%d noJump=%d",
                   getpid(), bid, kbExt, mainApp, wxkbd_bool(kNoJumpEnabled, YES));
        if (!wxkbd_shouldRun()) {
            wxkbd_diag(@"SKIP: not WeType context. This dylib must be injected into "
                       @"wxkb_plugin.appex (keyboard extension) or wxkb.app (main app), "
                       @"NOT into an unrelated app.");
            return;
        }

        // 1) NSUserDefaults hook（免跳转键恒为真）
        wxkbd_swizzle([NSUserDefaults class], @selector(objectForKey:), @selector(wxkbd_objectForKey:));
        wxkbd_swizzle([NSUserDefaults class], @selector(boolForKey:),   @selector(wxkbd_boolForKey:));

        // 2) openURL 拦截（三处覆盖）
        wxkbd_swizzle([UIApplication class], @selector(openURL:), @selector(wxkbd_app_openURL:));
        wxkbd_swizzle([UIApplication class],
                      @selector(openURL:options:completionHandler:),
                      @selector(wxkbd_app_openURL:options:completionHandler:));
        wxkbd_swizzle([UIInputViewController class], @selector(openURL:), @selector(wxkbd_ii_openURL:));
        wxkbd_swizzle([UIInputViewController class],
                      @selector(openURL:options:completionHandler:),
                      @selector(wxkbd_ii_openURL:options:completionHandler:));
        // NSExtensionContext 可能不存在 openURL:（iOS 版本相关），swizzle 内部已判空
        if (objc_getClass("NSExtensionContext")) {
            wxkbd_swizzle(objc_getClass("NSExtensionContext"), @selector(openURL:), @selector(wxkbd_ec_openURL:));
            wxkbd_swizzle(objc_getClass("NSExtensionContext"),
                          @selector(openURL:completionHandler:),
                          @selector(wxkbd_ec_openURL:completionHandler:));
        }

        // 3) 键盘外观 hook（仅键盘扩展里有 WBInputViewController）
        Class kbVC = objc_getClass("WBInputViewController");
        if (kbVC) {
            wxkbd_swizzle(kbVC, @selector(viewDidLayoutSubviews), @selector(wxkbd_viewDidLayoutSubviews));
            wxkbd_swizzle(kbVC, @selector(viewDidLoad), @selector(wxkbd_viewDidLoad));
        } else {
            for (int i = 0; i < 5; i++) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((i+1)*0.5*NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    Class c = objc_getClass("WBInputViewController");
                    if (c) {
                        wxkbd_swizzle(c, @selector(viewDidLayoutSubviews), @selector(wxkbd_viewDidLayoutSubviews));
                        wxkbd_swizzle(c, @selector(viewDidLoad), @selector(wxkbd_viewDidLoad));
                    }
                });
            }
        }

        // 4) 主程序负责把设置镜像到全局文件
        if (wxkbd_isMainApp()) {
            wxkbd_mirrorFromAppDomain();
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            NULL, wxkbd_prefsChanged,
                                            CFSTR("com.apple.Preferences/changed"),
                                            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            NULL, wxkbd_prefsChanged,
                                            (__bridge CFStringRef)kReloadNotify,
                                            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        }

        wxkbd_diag(@"INIT DONE in %@", bid);
    }
}

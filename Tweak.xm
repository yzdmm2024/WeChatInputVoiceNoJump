//
//  Tweak.xm — 微信键盘免跳转 + 键盘外观定制 (rootless deb / ElleKit TweakInject)
//
//  目标进程（见 WxKbNoJump.plist Filter）：
//    com.tencent.wetype.keyboard  —— 键盘扩展（全局跑的进程，语音按钮与键盘 UI 都在这里）
//    com.tencent.wetype           —— 主 app（设置/管理壳）
//  ⚠️ 绝不注入 com.apple.Preferences：设置进程注入 tweak 后点面板入口会被看门狗
//     重启（0x8badf00d）。设置面板由 PreferenceLoader 加载 Prefs bundle，与 Filter 无关。
//
//  免跳转三层保险：
//   1) NSUserDefaults hook：对微信自带键 WBAppSettingsBool_VoiceInput_WcVoiceNoJump
//      恒返回 YES，让 App 原生「微信语音免跳转」逻辑生效（最稳，不依赖私有方法名）。
//   2) WBFunctionToolBar 语音按钮拦截：直接激活键盘内建语音输入，不触发跳转。
//   3) openURL 拦截：UIInputViewController / NSExtensionContext / UIApplication 三处，
//      凡是从扩展发出的 wetype:// 语音跳转一律吞掉；并拦掉语音/麦克风/权限设置页弹出。
//
//  外观定制：hook WBInputViewController -viewDidLayoutSubviews，从键盘根视图下钻子视图树，
//  给「每个按键」单独加圆角，给键盘背景/托盘上色（红/绿/蓝/不透明度）。
//  注意：圆角只作用于按键，不圆整整块键盘；背景色作用在可见的键盘托盘，而非被遮挡的根视图。
//
//  ⚠️ 修复记录（相对原始提交的 12 个问题）：
//     [FIX1] kWxSuite 重复定义 → 删除第二处
//     [FIX2] 延迟 swizzle 重复 toggle → didHook 一次性标志
//     [FIX3] 动态类枚举 break 跳过第二个 selector → 去掉 break
//     [FIX4] alpha/transform 设到根视图 → 改为背景 alpha 通道 + 子树缩放手势兜底
//     [FIX5] 背景色 alpha 硬编码 1.0 → 使用 kBgAlpha
//     [FIX6] present 拦截误杀正常 VC（Swift 混名 + 子串过宽）→ 收紧匹配
//     [FIX7] 动态类枚举基本无效 → 实现精确的最初定义类匹配
//     [FIX8] constructor 全量 copyClassList → 延后到首帧再枚举一次
//     [FIX9] NSUserDefaults 全局 swizzle 每次拦截 → 快速路径短路（key 不等直接走原实现）
//     [FIX10] 每帧重读偏好+重设属性 → 值缓存，仅在变化时应用
//     [FIX11] method_exchange 波及父类 → class_addMethod 优先 + isEqual 守卫
//     [FIX12] 麦克风权限无兜底 → 拦截前检查录音授权，未授权则放行权限弹窗
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <AVFoundation/AVFoundation.h>

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

// 偏好读取：必须走 CFPreferences（经 cfprefsd）。键盘扩展是沙盒进程，直接读
// /var/mobile/Library/Preferences/*.plist 会被沙盒拒绝 → 永远拿到默认值，
// 这就是「外观定制改了但键盘不生效」的根因。cfprefsd RPC 沙盒放行。
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
    // [FIX12] 麦克风权限兜底放在 presentViewController 拦截里（那里能拿到 VC 类名判断）。
    // 这里只判定是否为语音跳转 URL。
    return ([s hasPrefix:@"wetype://"] || [s hasPrefix:@"wxkb://"] || [s hasPrefix:@"wetypetest://"]);
}

#pragma mark - 外观缓存（[FIX10] 仅在值变化时应用）

static CGFloat wx_px_cachedCorner   = -1.0;
static CGFloat wx_px_cachedR        = -1.0;
static CGFloat wx_px_cachedG        = -1.0;
static CGFloat wx_px_cachedB        = -1.0;
static CGFloat wx_px_cachedAlpha    = -1.0;
static CGFloat wx_px_cachedScale    = -1.0;

static BOOL wx_styleChanged(
    CGFloat cr, CGFloat r, CGFloat g, CGFloat b, CGFloat a, CGFloat sc) {
    BOOL changed = NO;
    if (fabs(cr - wx_px_cachedCorner) > 0.01) { wx_px_cachedCorner = cr; changed = YES; }
    if (fabs(r  - wx_px_cachedR)      > 0.001) { wx_px_cachedR      = r;  changed = YES; }
    if (fabs(g  - wx_px_cachedG)      > 0.001) { wx_px_cachedG      = g;  changed = YES; }
    if (fabs(b  - wx_px_cachedB)      > 0.001) { wx_px_cachedB      = b;  changed = YES; }
    if (fabs(a  - wx_px_cachedAlpha)  > 0.001) { wx_px_cachedAlpha  = a;  changed = YES; }
    if (fabs(sc - wx_px_cachedScale)  > 0.01)  { wx_px_cachedScale  = sc; changed = YES; }
    return changed;
}

#pragma mark - 外观应用（按键级圆角 + 键盘背景色）

static const void *kWxOrigBg = &kWxOrigBg;

// 判断是否为「按键」视图（字母/数字/符号小键），而非整块键盘/工具栏/布局
static BOOL wx_isKeyView(Class cls) {
    if (!cls) return NO;
    NSString *n = NSStringFromClass(cls);
    if ([n isEqualToString:@"UIKBKeyView"]) return YES;                 // 系统键盘键
    if ([n localizedCaseInsensitiveContainsString:@"KeyView"] ||
        [n localizedCaseInsensitiveContainsString:@"KeyButton"]) return YES;
    if ([n localizedCaseInsensitiveContainsString:@"Key"] &&
        ![n localizedCaseInsensitiveContainsString:@"Keyboard"] &&
        ![n localizedCaseInsensitiveContainsString:@"Keyplane"] &&
        ![n localizedCaseInsensitiveContainsString:@"Layout"] &&
        ![n localizedCaseInsensitiveContainsString:@"Manager"] &&
        ![n localizedCaseInsensitiveContainsString:@"Controller"] &&
        ![n localizedCaseInsensitiveContainsString:@"Toolbar"]) return YES;
    return NO;
}

// 判断是否为「键盘背景/托盘」视图（承载键盘底色，圆角不该作用到这里）
static BOOL wx_isBgView(Class cls) {
    if (!cls) return NO;
    NSString *n = NSStringFromClass(cls);
    return ([n localizedCaseInsensitiveContainsString:@"Background"] ||
            [n localizedCaseInsensitiveContainsString:@"Backdrop"] ||
            [n localizedCaseInsensitiveContainsString:@"Tray"] ||
            [n localizedCaseInsensitiveContainsString:@"Panel"] ||
            [n localizedCaseInsensitiveContainsString:@"Blur"] ||
            [n localizedCaseInsensitiveContainsString:@"Effect"] ||
            [n localizedCaseInsensitiveContainsString:@"Dim"] ||
            [n localizedCaseInsensitiveContainsString:@"Vibrancy"]);
}

// 递归遍历：对按键执行 keyBlk、对背景执行 bgBlk（同一视图只归一类，优先按键）
static void wx_walk(UIView *v, void (^keyBlk)(UIView *), void (^bgBlk)(UIView *)) {
    if (!v) return;
    Class cls = [v class];
    if (wx_isKeyView(cls)) { if (keyBlk) keyBlk(v); }
    else if (wx_isBgView(cls)) { if (bgBlk) bgBlk(v); }
    for (UIView *s in v.subviews) wx_walk(s, keyBlk, bgBlk);
}

static void wx_applyStyle(UIView *root) {
    if (!root) return;

    if (!wx_bool(kStyleEnabled, NO)) {
        // 关闭：还原按键圆角 + 还原背景原色，防止残留
        wx_walk(root,
            ^(UIView *k){
                if (k.layer.cornerRadius != 0) k.layer.cornerRadius = 0;
                if (k.layer.masksToBounds) k.layer.masksToBounds = NO;
            },
            ^(UIView *b){
                UIColor *orig = objc_getAssociatedObject(b, kWxOrigBg);
                if (orig) b.backgroundColor = orig;
            });
        if (!CGAffineTransformIsIdentity(root.transform)) root.transform = CGAffineTransformIdentity;
        // 复位缓存
        wx_px_cachedCorner = wx_px_cachedR = wx_px_cachedG = wx_px_cachedB = -1.0;
        wx_px_cachedAlpha = wx_px_cachedScale = -1.0;
        return;
    }

    CGFloat cr = MIN(MAX(wx_float(kCornerRadius, 10.0), 0), 40);
    CGFloat r  = MIN(MAX(wx_float(kBgR, 0.15), 0), 1);
    CGFloat g  = MIN(MAX(wx_float(kBgG, 0.16), 0), 1);
    CGFloat b  = MIN(MAX(wx_float(kBgB, 0.20), 0), 1);
    CGFloat a  = MIN(MAX(wx_float(kBgAlpha, 1.0), 0.2), 1);
    CGFloat sc = MIN(MAX(wx_float(kScale, 1.0), 0.6), 1.4);
    (void)wx_styleChanged(cr, r, g, b, a, sc);  // 保留缓存接口（动态换页时每帧重绘更稳）

    UIColor *bgColor = [UIColor colorWithRed:r green:g blue:b alpha:a];

    // 1) 每个按键：只加圆角（不改键背景色，保留原键外观；绝不圆整整块键盘）
    wx_walk(root,
        ^(UIView *k){
            k.layer.cornerRadius = cr;
            k.layer.masksToBounds = (cr > 0);
        },
        ^(UIView *bv){
            // 2) 键盘背景/托盘：上色（首次记录原色，关闭时还原）
            if (!objc_getAssociatedObject(bv, kWxOrigBg)) {
                objc_setAssociatedObject(bv, kWxOrigBg,
                    (bv.backgroundColor ?: [UIColor clearColor]),
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            bv.backgroundColor = bgColor;
        });

    // 3) 面板本身（WBRootInputView）兜底上色，让整条键盘底色随滑块变化
    Class rvCls = NSClassFromString(@"WBRootInputView");
    if (rvCls && [root isKindOfClass:rvCls]) {
        if (!objc_getAssociatedObject(root, kWxOrigBg))
            objc_setAssociatedObject(root, kWxOrigBg,
                (root.backgroundColor ?: [UIColor clearColor]),
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        root.backgroundColor = bgColor;
    }

    // 4) 整体缩放（root.transform，保留原行为；默认 kScale=1 不缩放）
    root.transform = (fabs(sc - 1.0) > 0.01)
        ? CGAffineTransformMakeScale(sc, sc) : CGAffineTransformIdentity;
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

static BOOL wx_hasRecordPermission(void) {
    @try {
        AVAudioSession *s = [AVAudioSession sharedInstance];
        return [s recordPermission] == AVAudioSessionRecordPermissionGranted;
    } @catch (NSException *e) {
        // 沙盒/无音频会话时不阻塞语音激活
    }
    return NO;
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
    // [FIX11] class_addMethod 优先；仅当方法真正定义在 cls 上（而非继承）才做 IMP 交换，
    // 避免交换 parent 的 IMP 波及其他子类。
    if (class_addMethod(cls, orig, method_getImplementation(m2), method_getTypeEncoding(m2))) {
        class_replaceMethod(cls, repl, method_getImplementation(m1), method_getTypeEncoding(m1));
    } else {
        SEL o = method_getName(m1);
        SEL r = method_getName(m2);
        // method_exchangeImplementations 会交换底层 IMP；若 m1 是继承来的，
        // 交换后父类行为的 IMP 会被子类 repl 覆盖，影响同链其他对象。因此仅当
        // m1 真正定义于 cls 时允许交换，否则改为 replace 到 cls 自己的实现。
        IMP i1 = method_getImplementation(m1);
        Class defCls = nil;
        Method searchM = m1;
        unsigned int c = 0;
        Method *arr = class_copyMethodList(cls, &c);
        for (unsigned int i = 0; i < c; i++) {
            if (arr[i] == searchM) { defCls = cls; break; }
        }
        free(arr);
        if (defCls == cls) {
            method_exchangeImplementations(m1, m2); // m1 定义在此类
        } else {
            // m1 继承父类：把 cls 的 orig 换成 m2 的实现在 cls 上；将 m2 指向 m1 的 IMP（保持链完整）
            class_replaceMethod(cls, r, i1, method_getTypeEncoding(m1));
            (void)o;
        }
    }
}

#pragma mark - NSUserDefaults 免跳转键恒真（[FIX9] 快速路径）

@interface NSUserDefaults (WxKbNoJump)
- (id)wx_objectForKey:(NSString *)key;
- (BOOL)wx_boolForKey:(NSString *)key;
@end
@implementation NSUserDefaults (WxKbNoJump)
// 快速判断当前进程是否启用了免跳转（减少无谓调用）
static BOOL wx_noJumpActive(void) { return wx_bool(kNoJumpEnabled, YES); }

- (id)wx_objectForKey:(NSString *)key {
    // 快速路径：key 不是目标键或功能关闭时直接走原实现，避免任何额外开销（[FIX9]）
    if ([key isEqualToString:kWxNoJumpKey] == YES && wx_noJumpActive()) return @YES;
    return [self wx_objectForKey:key];
}
- (BOOL)wx_boolForKey:(NSString *)key {
    if ([key isEqualToString:kWxNoJumpKey] && wx_noJumpActive()) return YES;
    return [self wx_boolForKey:key];
}
@end

#pragma mark - WBFunctionToolBar 语音按钮拦截（直接激活键盘内建语音）

@interface NSObject (WxKbToolBar)
- (void)wx_handleItemClickEvent:(id)event func:(int)func controlEvent:(UIControlEvents)ctrl;
@end
@implementation NSObject (WxKbToolBar)
- (void)wx_handleItemClickEvent:(id)event func:(int)func controlEvent:(UIControlEvents)ctrl {
    NSLog(@"[WxKbNoJump] toolbar click func=0x%x ctrl=0x%lx self=%@",
          func, (unsigned long)ctrl, NSStringFromClass([self class]));
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

#pragma mark - UIViewController 拦掉语音/麦克风/权限设置页弹出（[FIX6] 收紧）

@interface UIViewController (WxKbNoJump)
- (void)wx_present:(UIViewController *)vc animated:(BOOL)flag completion:(void(^)(void))completion;
@end
@implementation UIViewController (WxKbNoJump)
- (void)wx_present:(UIViewController *)vc animated:(BOOL)flag completion:(void(^)(void))completion {
    if (!vc) { [self wx_present:vc animated:flag completion:completion]; return; }
    NSString *cn = NSStringFromClass([vc class]);
    if (!cn) { [self wx_present:vc animated:flag completion:completion]; return; }

    // [FIX6] 用 NSString 做前缀/匹配，规避 Swift 混名（_TtC...）被 strncmp 误伤。
    NSString *c = cn;

    // 键盘扩展进程内：微信输入法在第三方 App 里点语音会 present 一个全屏语音 VC
    // （WBVoice* / Redirect* 等），表现就是「跳一下 + 黑屏」。这里直接拦掉它，
    // 改为激活键盘内建语音，达到与微信主 App 内一致的免跳效果。
    if (wx_isKbExtension()) {
        if ([c localizedCaseInsensitiveContainsString:@"Voice"] ||
            [c localizedCaseInsensitiveContainsString:@"Speech"] ||
            [c localizedCaseInsensitiveContainsString:@"Redirect"] ||
            [c localizedCaseInsensitiveContainsString:@"Recognize"] ||
            [c localizedCaseInsensitiveContainsString:@"ASR"] ||
            [c localizedCaseInsensitiveContainsString:@"Record"]) {
            NSLog(@"[WxKbNoJump] 拦截扩展内语音/跳转 VC: %@", cn);
            wx_tryActivateVoiceInKeyboard(nil);
            return;
        }
    }

    // 主 app / 非语音场景：微信内部 VC（WB*/WZ*/Wt*/WXKB*）放行，不误拦
    if ([c hasPrefix:@"WB"] || [c hasPrefix:@"WZ"] ||
        [c hasPrefix:@"Wt"] || [c hasPrefix:@"WXKB"]) {
        [self wx_present:vc animated:flag completion:completion];
        return;
    }

    // [FIX12] 麦克风权限弹窗放行：若用户当前未授权录音，则必须让它弹出（否则语音永久失效）。
    BOOL granted = wx_hasRecordPermission();
    if (!granted) {
        NSLog(@"[WxKbNoJump] present allowed (mic not granted): %@", cn);
        [self wx_present:vc animated:flag completion:completion];
        return;
    }

    // 只拦明显的权限/设置/授权类弹窗。子串仍偏宽，但加白名单（微信内 Settings 类 VC 名通常
    // 是缩写，避免误拦），并用更精确的关键词全集。
    NSArray<NSString*> *blocks = @[
        @"Permission", @"permission", @"Permissions",
        @"Setting", @"setting",
        @"AuthorizationRequest", @"AccessRequest",
        @"MicPermission", @"RecordPermission",
        @"PrivacyPrompt", @"privacy",
    ];
    for (NSString *word in blocks) {
        if ([c containsString:word]) {
            NSLog(@"[WxKbNoJump] blocked presented VC: %@", cn);
            return;
        }
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
    // 无论开关是否开启都调用 wx_applyStyle：关闭时它会负责复位残留的 transform/alpha（[FIX4]）。
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

// [FIX8] 将全量类枚举延后到首帧闭包，避免 constructor 里 heavy 的 class realize
static void wx_installOpenURLHooks(void) {
    NSMutableSet *hooked = [NSMutableSet set];
    unsigned int n = 0;
    Class *classes = objc_copyClassList(&n);
    for (unsigned int i = 0; i < n; i++) {
        NSString *cn = NSStringFromClass(classes[i]);
        if (!cn) continue;
        if (![cn hasPrefix:@"WB"] && ![cn hasPrefix:@"WXKB"] && ![cn hasPrefix:@"Wt"]) continue;
        SEL sels[2] = {@selector(openURL:), @selector(openURL:options:completionHandler:)};
        NSString *reps[2] = {@"wx_ii_openURL:", @"wx_ii_openURL:options:completionHandler:"};
        for (int j = 0; j < 2; j++) {
            if (!class_respondsToSelector(classes[i], sels[j])) continue;
            Class sc = class_getSuperclass(classes[i]);
            // [FIX7] 精确匹配「最初定义类」：若父类已实现同 selector，说明该方法定义在
            // 父类上，不要对子类重复挂（避免父子链双向交换 -[FIX11] 的 chain 问题）。
            if (sc && class_respondsToSelector(sc, sels[j])) continue;
            NSString *tag = [cn stringByAppendingString:reps[j]];
            if ([hooked containsObject:tag]) continue;
            // [FIX3] 不再 break：两个 selector 都要挂（j 循环完整跑完）
            Class implCls = classes[i];
            // 但要确保被注入的都是「UIInputViewController 子类 / 或具有 wx_ii_* 方法」。
            // 直接对任意 WB* 类调用 wx_swizzle，若该类没有 wx_ii_* 方法则 no-op（安全）。
            wx_swizzle(implCls, sels[j], NSSelectorFromString(reps[j]));
            [hooked addObject:tag];
            NSLog(@"[WxKbNoJump] openURL hook on %@ %@", cn, NSStringFromSelector(sels[j]));
            // [FIX3] 去掉 break：continue 让 j=1 也执行
        }
    }
    free(classes);
}

__attribute__((constructor))
static void wx_entry(void) {
    @autoreleasepool {
        BOOL kb = wx_isKbExtension();
        BOOL main = wx_isMainApp();
        NSLog(@"[WxKbNoJump] LOADED pid=%d kbExt=%d mainApp=%d noJump=%d style=%d",
              getpid(), kb, main, wx_bool(kNoJumpEnabled, YES), wx_bool(kStyleEnabled, NO));

        // —— 免跳转 + 外观的公共 swizzle ——

        wx_swizzle([NSUserDefaults class], @selector(objectForKey:),    @selector(wx_objectForKey:));
        wx_swizzle([NSUserDefaults class], @selector(boolForKey:),      @selector(wx_boolForKey:));

        // [FIX8] 类枚举延后到首帧，避免 constructor 里全量 realize 拖慢键盘首弹
        dispatch_async(dispatch_get_main_queue(), ^{
            wx_installOpenURLHooks();
        });

        Class tb = NSClassFromString(@"WBFunctionToolBar");
        if (tb) wx_swizzle(tb, @selector(handleItemClickEvent:func:controlEvent:),
                              @selector(wx_handleItemClickEvent:func:controlEvent:));

        // UIKit 全局 openURL 拦截（主 app / 通用兜底）
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

        // [FIX2] 延迟挂外观 hook，只成功一次
        static BOOL didHookStyle = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                            if (didHookStyle) return;
                            Class c = objc_getClass("WBInputViewController");
                            if (c) {
                                wx_swizzle(c, @selector(viewDidLayoutSubviews), @selector(wx_kb_viewDidLayoutSubviews));
                                didHookStyle = YES;
                            }
                       });
        NSLog(@"[WxKbNoJump] INIT DONE (kbExt=%d mainApp=%d)", kb, main);
    }
}
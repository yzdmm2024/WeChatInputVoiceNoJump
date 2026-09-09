//
//  Tweak.xm — 微信键盘免跳转 + 键盘外观定制 (rootless deb / ElleKit TweakInject) v1.1.12
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

#pragma mark - 免跳转核心：强制 4 个判定方法走“内建路径”（任意 App 都不拉主程序）

// WeType 运行时类无头文件，需前向声明，否则分类/方法编译器报 “cannot find interface declaration”
@class WBRootViewManager, WBVoiceInputService;

#define WX_OVERRIDE_BOOL(clsName, selOrig, selRepl, forceVal) \
@interface clsName (WxKbNoJump_##selRepl) \
- (BOOL)selRepl; \
@end \
@implementation clsName (WxKbNoJump_##selRepl) \
- (BOOL)selRepl { \
    if (wx_bool(kNoJumpEnabled, YES)) return forceVal; \
    return [self selRepl]; \
} \
@end

WX_OVERRIDE_BOOL(WBRootViewManager, canUseWcVoice, wx_canUseWcVoice, YES)
WX_OVERRIDE_BOOL(WBRootViewManager, prefersJumpToMainAppForRecording, wx_prefersJump, NO)
WX_OVERRIDE_BOOL(WBVoiceInputService, isUsingWcVoice, wx_isUsingWcVoice, YES)
WX_OVERRIDE_BOOL(WBVoiceInputService, requireJumpToMainAppForRecording, wx_requireJump, NO)

#pragma mark - WBInputViewController 外观 hook

@interface NSObject (WxKbStyle)
- (void)wx_kb_viewDidLayoutSubviews;
@end
@implementation NSObject (WxKbStyle)
- (void)wx_kb_viewDidLayoutSubviews {
    [self wx_kb_viewDidLayoutSubviews];
    if (![self isKindOfClass:objc_getClass("WBInputViewController")]) return;
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
        NSLog(@"[WxKbNoJump] LOADED pid=%d kbExt=%d mainApp=%d noJump=%d style=%d v=1.1.12",
              getpid(), kb, main, wx_bool(kNoJumpEnabled, YES), wx_bool(kStyleEnabled, NO));

        // 1) 微信自带免跳标志恒真（锦上添花）
        wx_swizzle([NSUserDefaults class], @selector(objectForKey:),    @selector(wx_objectForKey:));
        wx_swizzle([NSUserDefaults class], @selector(boolForKey:),      @selector(wx_boolForKey:));

        // 2) 强制判定方法走内建路径（免跳核心）
        Class rvm = NSClassFromString(@"WBRootViewManager");
        if (rvm) {
            wx_swizzle(rvm, @selector(canUseWcVoice), @selector(wx_canUseWcVoice));
            wx_swizzle(rvm, @selector(prefersJumpToMainAppForRecording), @selector(wx_prefersJump));
        }
        Class vis = NSClassFromString(@"WBVoiceInputService");
        if (vis) {
            wx_swizzle(vis, @selector(isUsingWcVoice), @selector(wx_isUsingWcVoice));
            wx_swizzle(vis, @selector(requireJumpToMainAppForRecording), @selector(wx_requireJump));
        }

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
        });

        NSLog(@"[WxKbNoJump] INIT DONE v1.1.12 (kbExt=%d mainApp=%d)", kb, main);
    }
}

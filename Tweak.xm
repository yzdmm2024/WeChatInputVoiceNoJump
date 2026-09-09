//
//  Tweak.xm — 微信键盘(WeType)语音免跳转 (rootless deb / ElleKit TweakInject) v1.1.17
//
//  原理（源自开源 WTVRBGLauncher，作者 Lessica / 82Flex，已改写为仅微信输入法并去掉外观定制）：
//  键盘扩展没有麦克风权限，语音必须在 wxkb.app 主程序里录。所谓「跳一下主程序」本质是
//  SpringBoard 执行一次工作区切换动画（从当前 App 切到 com.tencent.wetype）。
//  本 tweak 注入 SpringBoard，hook：
//    · SBWorkspaceTransitionContext -animationDisabled
//      当这次切换的触发 URL 是 wetype://WXKBURL_STARTVOICERECORD（去微信输入法录音）时返回 YES，
//      禁掉切换动画；录音结束从微信输入法切回时（SBActivationSettingFromBreadcrumb）同样禁动画。
//    · SBApplicationSceneView -layoutSubviews
//      用一帧快照遮罩消除切换残影，做到“看不出跳”。
//  结果：wxkb.app 照常在后台录音并把文字回填到输入框，但屏幕上体验即“免跳转”。
//
//  关键点：绝不拦截 openURL —— 拦了 wxkb.app 起不来，录音就废了（之前十几个版本都错在这）。
//  正确做法是“让跳发生、但把动画藏掉”。
//
//  注入目标：com.apple.springboard（见 WxKbNoJump.plist Filter）。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - 配置（读 CFPreferences 套件；SpringBoard 进程可正常读取）

static NSString *const kWxSuite       = @"com.wxkbd.nojump";
static NSString *const kNoJumpEnabled = @"wxkbdNoJumpEnabled";

static id wx_cpValue(NSString *k) {
    CFTypeRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)k, (__bridge CFStringRef)kWxSuite);
    return v ? CFBridgingRelease(v) : nil;
}
static BOOL wx_bool(NSString *k, BOOL def) {
    id v = wx_cpValue(k);
    if ([v respondsToSelector:@selector(boolValue)]) return [v boolValue];
    return def;
}

#pragma mark - SpringBoard 私有类前向声明（Theos SDK 不带这些头文件）

typedef NS_ENUM(unsigned, SBActivationSetting) {
    SBActivationSettingNotASetting = 0,
    SBActivationSettingNoAnimate = 1,
    SBActivationSettingSuspended = 3,
    SBActivationSettingURL = 5,
    SBActivationSettingSourceIdentifier = 14,
    SBActivationSettingFromBreadcrumb = 42,
};

@interface SBActivationSettings : NSObject
- (id)objectForActivationSetting:(SBActivationSetting)arg1;
- (long long)flagForActivationSetting:(SBActivationSetting)arg1;
- (void)setObject:(id)object forActivationSetting:(SBActivationSetting)activationSetting;
- (void)setFlag:(long long)flag forActivationSetting:(SBActivationSetting)activationSetting;
@end

@interface SBApplication : NSObject
@property (nonatomic, copy, readonly) NSString *bundleIdentifier;
@end

@interface SBApplicationSceneView : UIView
@property (nonatomic, readonly) SBApplication *application;
@end

@interface SBApplicationSceneEntity : NSObject
@property (nonatomic, readonly) SBApplication *application;
@property (nonatomic, readonly) SBActivationSettings *activationSettings;
@end

@interface SBWorkspaceTransitionContext : NSObject
@property (nonatomic, copy, readonly) NSSet<SBApplicationSceneEntity *> *entities;
@property (nonatomic, copy, readonly) NSSet<SBApplicationSceneEntity *> *previousEntities;
@property (nonatomic, weak) id request;
@end

#pragma mark - 状态

static NSString *gFrozenAppSceneIdentifier = nil;
static UIView    *gSnapshotView = nil;
static BOOL       gIsEnabled = YES;
static NSTimeInterval gAnimationInterval = 0.3;
static NSTimeInterval gAnimationDelay    = 0.3;

static void ReloadPrefs(void) {
    gIsEnabled = wx_bool(kNoJumpEnabled, YES);
    NSLog(@"[WxKbNoJump] prefs reloaded noJump=%d", gIsEnabled);
}

#pragma mark - 强制常开悬浮窗（1.1.17：探测 + 尽力强制，待用户日志确认键名后固化）

// 探测：列出 WBVoiceinputPreferences 的所有方法，定位“语音模式”的设置键/方法
static void WxKbProbeVoicePrefs(void) {
    Class cls = NSClassFromString(@"WBVoiceinputPreferences");
    if (!cls) { NSLog(@"[WxKbNoJump] PROBE WBVoiceinputPreferences NOT found"); return; }
    unsigned mc; Method *ms = class_copyMethodList(cls, &mc);
    NSMutableString *sb = [NSMutableString stringWithFormat:@"[WxKbNoJump] PROBE WBVoiceinputPreferences methods(%u):", mc];
    for (unsigned i=0;i<mc;i++) [sb appendFormat:@" %s", sel_getName(method_getName(ms[i]))];
    free(ms);
    NSLog(@"%@", sb);
}

// 记录微信输入法写出的偏好键（切换 悬浮窗/通知栏 时会写出“模式”键名+值）
%hookf(void, CFPreferencesSetValue, CFStringRef key, CFPropertyListRef value, CFStringRef applicationID, CFStringRef userName, CFStringRef hostName) {
    NSString *k = (__bridge NSString *)key;
    if (k && ([k rangeOfString:@"Voice"   options:NSCaseInsensitiveSearch].location != NSNotFound ||
              [k rangeOfString:@"voice"   options:NSCaseInsensitiveSearch].location != NSNotFound ||
              [k rangeOfString:@"Mode"    options:NSCaseInsensitiveSearch].location != NSNotFound ||
              [k rangeOfString:@"Float"   options:NSCaseInsensitiveSearch].location != NSNotFound ||
              [k rangeOfString:@"Redirect" options:NSCaseInsensitiveSearch].location != NSNotFound)) {
        NSLog(@"[WxKbNoJump] PREFS-WRITE key=%@ value=%@ app=%@", k, value, applicationID);
    }
    %orig(key, value, applicationID, userName, hostName);
}

// 尽力强制：若微信输入法用 setVoiceInputMode: 设置模式且 1=悬浮窗，则强制为 1
%hook WBVoiceinputPreferences
- (void)setVoiceInputMode:(NSInteger)m {
    NSLog(@"[WxKbNoJump] setVoiceInputMode orig=%ld -> force 1", (long)m);
    %orig(1);
}
%end

%hook SBWorkspaceTransitionContext

- (BOOL)animationDisabled {
    BOOL disabled = %orig;
    if (!gIsEnabled) return disabled;

    SBApplicationSceneEntity *prevEntity = self.previousEntities.anyObject;
    SBApplicationSceneEntity *nextEntity = self.entities.anyObject;
    Class eCls = %c(SBApplicationSceneEntity);
    if ([prevEntity isKindOfClass:eCls] && [nextEntity isKindOfClass:eCls]) {
        NSString *prevBundle = prevEntity.application.bundleIdentifier;
        NSString *nextBundle = nextEntity.application.bundleIdentifier;

        // 只要这次切换涉及微信输入法主程序（com.tencent.wetype），就禁掉切换动画。
        // 不依赖具体语音 URL/Host（各版本可能不同），只要“去微信输入法”或“从微信输入法回来”都禁。
        if ([prevBundle isEqualToString:@"com.tencent.wetype"] ||
            [nextBundle isEqualToString:@"com.tencent.wetype"]) {
            NSLog(@"[WxKbNoJump] disable animation: WeType transition prev=%@ next=%@", prevBundle, nextBundle);
            if (prevBundle.length) gFrozenAppSceneIdentifier = prevBundle;
            return YES;
        }
    }
    return disabled;
}

%end

%hook SBApplicationSceneView

- (void)layoutSubviews {
    %orig;
    if (!gIsEnabled) return;

    NSString *bid = self.application.bundleIdentifier;
    if (!bid) return;

    if ([gFrozenAppSceneIdentifier isEqualToString:bid]) {
        gFrozenAppSceneIdentifier = nil;
        if (!gSnapshotView) {
            UIWindow *window = self.window;
            if (window) {
                gSnapshotView = [window snapshotViewAfterScreenUpdates:NO];
                gSnapshotView.frame = window.bounds;
                gSnapshotView.userInteractionEnabled = NO;
                [window addSubview:gSnapshotView];
            }
            return;
        }
    }

    if (gSnapshotView) {
        UIView *viewToRemove = gSnapshotView;
        gSnapshotView = nil;
        [UIView animateWithDuration:gAnimationInterval
                              delay:gAnimationDelay
                            options:kNilOptions
                         animations:^{ viewToRemove.alpha = 0; }
                         completion:^(BOOL finished){ [viewToRemove removeFromSuperview]; }];
    }
}

%end

%ctor {
    ReloadPrefs();
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        (CFNotificationCallback)ReloadPrefs,
        CFSTR("com.wxkbd.nojump/saved"),
        NULL,
        CFNotificationSuspensionBehaviorCoalesce
    );
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if ([bid isEqualToString:@"com.tencent.wetype"]) {
        WxKbProbeVoicePrefs();   // 探测语音模式设置键（1.1.17）
    }
    NSLog(@"[WxKbNoJump] LOADED v1.1.17 noJump=%d (SpringBoard anim-disable + WeType probe), bundle=%@", gIsEnabled, bid);
}

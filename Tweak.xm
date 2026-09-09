//
//  Tweak.xm — 微信键盘(WeType)语音免跳转 (rootless deb / ElleKit TweakInject) v1.1.15
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
        NSURL *nextURL = [nextEntity.activationSettings objectForActivationSetting:SBActivationSettingURL];

        // 去微信输入法主程序、且触发是语音录音 URL → 禁掉切换动画（免跳转）
        if ([nextBundle isEqualToString:@"com.tencent.wetype"] &&
            [nextURL isKindOfClass:[NSURL class]] &&
            [nextURL.scheme isEqualToString:@"wetype"] &&
            [nextURL.host isEqualToString:@"WXKBURL_STARTVOICERECORD"]) {
            gFrozenAppSceneIdentifier = prevBundle;
            return YES;
        }

        // 从微信输入法主程序切回（录音结束、文字回填）→ 同样禁动画，做到双向无感
        BOOL isFromBreadcrumb = [nextEntity.activationSettings flagForActivationSetting:SBActivationSettingFromBreadcrumb];
        if (isFromBreadcrumb && [prevBundle isEqualToString:@"com.tencent.wetype"]) {
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
    NSLog(@"[WxKbNoJump] LOADED v1.1.15 noJump=%d (SpringBoard animation-disable mode, WeType only)", gIsEnabled);
}

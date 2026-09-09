//
//  Tweak.xm — 微信键盘(WeType)语音免跳转 (rootless deb / ElleKit TweakInject) v1.1.19
//
//  原理（源自开源 WTVRBGLauncher，作者 Lessica / 82Flex，已改写为仅微信输入法并去掉外观定制）：
//  键盘扩展没有麦克风权限，语音必须在 wxkb.app 主程序里录。所谓「跳一下主程序」本质是
//  SpringBoard 执行一次工作区切换动画（从当前 App 切到 com.tencent.wetype）。
//  本 tweak 注入 SpringBoard，hook：
//    · SBWorkspaceTransitionContext -animationDisabled
//      当这次切换涉及微信输入法主程序(com.tencent.wetype)时返回 YES，禁掉切换动画；
//    · SBApplicationSceneView -layoutSubviews
//      用一帧快照遮罩消除切换残影，做到“看不出跳”。
//  结果：wxkb.app 照常在后台录音并把文字回填到输入框，但屏幕上体验即“免跳转”。
//
//  强制常开悬浮窗（1.1.18 用 frida 真机确认键名；1.1.19 修正 dylib 安装路径为 /usr/lib/TweakInject，roothide 设备才能注入）：
//  微信输入法把“录音待机模式”存为类属性 WBVoiceinputPreferences.recordingStandbyMode
//  （@property(class) NSInteger），持久化在 App Group 的 WBVoiceinputPreferences.plist。
//  真机实测：悬浮窗模式 = 1，通知栏模式 = 0。
//  本 tweak 注入 com.tencent.wetype，hook +[WBVoiceinputPreferences recordingStandbyMode]
//  在开关开启时强制返回 1，使微信输入法始终按“悬浮窗”逻辑运行——注销/重启后也常开，
//  无需手动再开。关闭开关即恢复系统原值（可切回通知栏模式）。
//
//  关键点：绝不拦截 openURL —— 拦了 wxkb.app 起不来，录音就废了。
//  正确做法是“让跳发生(或按悬浮窗逻辑)、但把动画藏掉 + 强制悬浮窗模式”。
//
//  注入目标：com.apple.springboard + com.tencent.wetype（见 WxKbNoJump.plist Filter）。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - 配置（读 CFPreferences 套件；两个进程都可正常读取）

static NSString *const kWxSuite        = @"com.wxkbd.nojump";
static NSString *const kNoJumpEnabled  = @"wxkbdNoJumpEnabled";
static NSString *const kForceFloating  = @"wxkbdForceFloating";

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

#pragma mark - 微信输入法语音模式类（强制悬浮窗用）

@interface WBVoiceinputPreferences : NSObject
+ (long long)recordingStandbyMode;
@end

#pragma mark - 状态

static NSString *gFrozenAppSceneIdentifier = nil;
static UIView    *gSnapshotView = nil;
static BOOL       gIsEnabled     = YES;   // 免跳转（动画隐藏）
static BOOL       gForceFloating = YES;   // 强制悬浮窗模式（recordingStandbyMode=1）
static NSTimeInterval gAnimationInterval = 0.3;
static NSTimeInterval gAnimationDelay    = 0.3;

static void ReloadPrefs(void) {
    gIsEnabled     = wx_bool(kNoJumpEnabled, YES);
    gForceFloating = wx_bool(kForceFloating, YES);
    NSLog(@"[WxKbNoJump] prefs reloaded noJump=%d forceFloating=%d", gIsEnabled, gForceFloating);
}

#pragma mark - 强制常开悬浮窗（1.1.18）：hook 类属性 getter 返回 1

%hook WBVoiceinputPreferences
+ (long long)recordingStandbyMode {
    if (gForceFloating) {
        // 1 = 悬浮窗模式（真机 frida 实测：悬浮窗=1，通知栏=0）
        return 1;
    }
    return %orig;
}
%end

#pragma mark - SpringBoard 动画隐藏（免跳转视觉）

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
    NSLog(@"[WxKbNoJump] LOADED v1.1.19 noJump=%d forceFloating=%d (SpringBoard anim-disable + WeType floating), bundle=%@",
          gIsEnabled, gForceFloating, bid);
}

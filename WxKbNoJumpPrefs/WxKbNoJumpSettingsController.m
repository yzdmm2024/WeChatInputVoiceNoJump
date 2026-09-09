//
//  WxKbNoJumpSettingsController.m — 微信键盘免跳转设置面板（PSListController）
//
//  仅保留「免跳转」总开关；外观定制已在 1.1.15 移除。
//  写法严格对齐同机已验证可用的 KSSettingsController：
//   - specifiers 直接读写真实的 _specifiers 裸 ivar（PSListController 内部就读它）
//   - 任何偏好写入都先 [super setPreferenceValue:...]（走 cfprefsd，沙盒安全）
//   - 保存后发 Darwin 通知 com.wxkbd.nojump/saved，SpringBoard 端实时重载
//

#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kWxSuite = @"com.wxkbd.nojump";

#pragma mark - 面板控制器

@interface WxKbNoJumpSettingsController : PSListController
@end

@implementation WxKbNoJumpSettingsController

- (id)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"微信键盘免跳转";
}

- (id)readPreference:(NSString *)key {
    CFTypeRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                            (__bridge CFStringRef)kWxSuite);
    return v ? CFBridgingRelease(v) : nil;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    @try {
        [super setPreferenceValue:value specifier:specifier];
        // 通知 SpringBoard 端 tweak 实时重载（无需注销）
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                              CFSTR("com.wxkbd.nojump/saved"),
                                              NULL, NULL, TRUE);
    } @catch (NSException *e) {}
}

@end

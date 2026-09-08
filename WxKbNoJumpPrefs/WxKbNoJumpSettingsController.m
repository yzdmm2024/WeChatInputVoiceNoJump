//
//  WxKbNoJumpSettingsController.m — 系统-设置里的「微信键盘免跳转」面板控制器
//  编译为 WxKbNoJumpPrefs.bundle 内的可执行（MH_DYLIB），由 PreferenceLoader 载入。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <spawn.h>

// 仅前向声明需要用到的方法，避免依赖 Preferences.framework 私有头
@interface PSListController : UIViewController
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
@end
@interface PSSpecifier : NSObject
@end

@interface WxKbNoJumpSettingsController : PSListController
- (void)respring;
- (void)resetDefaults;
@end

@implementation WxKbNoJumpSettingsController

static const void *kWxSpecKey = &kWxSpecKey;

- (NSArray *)specifiers {
    NSArray *s = objc_getAssociatedObject(self, kWxSpecKey);
    if (!s) {
        s = [self loadSpecifiersFromPlistName:@"Root" target:self];
        objc_setAssociatedObject(self, kWxSpecKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return s;
}

- (void)respring {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"重启 SpringBoard"
                         message:@"免跳转与外观设置实时生效；重启仅确保注入刷新与设置入口稳定。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"重启"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) {
        pid_t pid;
        const char *args[] = {"killall", "-9", "SpringBoard", NULL};
        posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, (char **)args, NULL);
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)resetDefaults {
    NSString *p = @"/var/mobile/Library/Preferences/com.wxkbd.nojump.plist";
    [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
    [self respring];
}

@end

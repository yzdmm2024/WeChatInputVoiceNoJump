#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface WeChatVoiceSettingsController : PSListController
- (void)respring;
@end

@implementation WeChatVoiceSettingsController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)respring {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重启 SpringBoard"
                                                                   message:@"语音免跳转功能将在重启后生效"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"重启" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        system("killall -9 SpringBoard");
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
#import <UIKit/UIKit.h>
#import <objc/message.h>

// ============================================================
// 微信输入法自用 - 语音免跳转 v3
// 
// 多层拦截策略:
// 1. 拦截语音按钮点击 handleItemClickEvent
// 2. 拦截 setVoiceInputFocused 用 nil completion
// 3. 拦截 presentViewController 防止设置页弹出
// 4. 拦截 UIApplication openURL 防止外部跳转
// ============================================================

#pragma mark - WBFunctionToolBar

%hook WBFunctionToolBar

- (void)handleItemClickEvent:(id)event func:(int)func controlEvent:(UIControlEvents)ctrl {
    if (func == 0x1) {
        // 语音按钮 - 拦截所有跳转
        // 只调 setVoiceInputFocused 且传 nil completion
        %orig(event, func, ctrl);
        return;
    }
    %orig;
}

- (void)setVoiceInputFocused:(BOOL)focused animated:(BOOL)animated completion:(id)block {
    // 用 nil 替换 completion block，防止任何跳转
    %orig(focused, animated, nil);
}

%end


#pragma mark - UIViewController (防止设置页弹出)

%hook UIViewController

- (void)presentViewController:(UIViewController *)vc animated:(BOOL)flag completion:(void (^)(void))completion {
    // 获取当前类名
    const char *className = class_getName([vc class]);
    
    // 检查是否是语音设置相关页面
    if (strstr(className, "Voice") || strstr(className, "voice") ||
        strstr(className, "Speech") || strstr(className, "speech") ||
        strstr(className, "Microphone") || strstr(className, "microphone") ||
        strstr(className, "Permission") || strstr(className, "permission")) {
        // 拦截跳转
        return;
    }
    %orig;
}

%end


#pragma mark - UIApplication (防止 URL 跳转)

%hook UIApplication

- (void)openURL:(NSURL *)url options:(NSDictionary *)options completionHandler:(void (^)(BOOL))completion {
    // 拦截语音设置相关 URL
    NSString *urlStr = [url absoluteString];
    if ([urlStr containsString:@"voice"] || [urlStr containsString:@"Voice"] ||
        [urlStr containsString:@"speech"] || [urlStr containsString:@"Speech"] ||
        [urlStr containsString:@"microphone"] || [urlStr containsString:@"Microphone"] ||
        [urlStr containsString:@"setting"] || [urlStr containsString:@"Setting"] ||
        [urlStr containsString:@"prefs"] || [urlStr containsString:@"Prefs"] ||
        [urlStr containsString:@"App-Prefs"]) {
        if (completion) {
            completion(YES);
        }
        return;
    }
    %orig;
}

%end
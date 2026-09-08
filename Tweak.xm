#import <UIKit/UIKit.h>
#import <objc/message.h>

// ============================================================
// 微信输入法自用 - 语音免跳转 v5
// 
// 多层拦截策略:
// 1. 拦截语音按钮点击，直接调用WBRootInputView内建语音输入
// 2. 拦截 setVoiceInputFocused 用 nil completion
// 3. 拦截 presentViewController 防止设置页弹出
// 4. 拦截 UIApplication URL跳转
// 5. 支持设置开关控制是否开启
// ============================================================

#pragma mark - Settings Check

static BOOL isEnabled(void) {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.yzdmm.wechatvoicenojump"];
    return [defaults boolForKey:@"enabled"];
}

#pragma mark - WBFunctionToolBar

%hook WBFunctionToolBar

- (void)handleItemClickEvent:(id)event func:(int)func controlEvent:(UIControlEvents)ctrl {
    if (func == 0x1 && isEnabled()) {
        // 语音按钮 - 拦截并直接调用内建语音输入，不执行原始逻辑
        Class WBRootInputViewClass = objc_getClass("WBRootInputView");
        if (!WBRootInputViewClass) {
            // 找不到类，回退到原始逻辑
            %orig(event, func, ctrl);
            return;
        }
        
        // 向上遍历找到WBRootInputView（使用objc_msgSend避免forward declaration问题）
        UIView *v = ((UIView *(*)(id, SEL))objc_msgSend)(self, @selector(superview));
        BOOL found = NO;
        while (v) {
            if ([v isKindOfClass:WBRootInputViewClass]) {
                // 初始化语音输入视图
                ((void (*)(id, SEL))objc_msgSend)(v, @selector(initVoiceInputInteractionViewIfNeeded));
                // 激活语音输入交互视图
                ((void (*)(id, SEL, BOOL))objc_msgSend)(v, @selector(setVoiceInputInteractionViewActive:), YES);
                // 隐藏当前工具栏
                ((void (*)(id, SEL, BOOL))objc_msgSend)(self, @selector(setHidden:), YES);
                found = YES;
                break;
            }
            v = [v superview];
        }
        
        if (!found) {
            // 找不到，回退
            %orig(event, func, ctrl);
        }
        return;
    }
    %orig(event, func, ctrl);
}

- (void)setVoiceInputFocused:(BOOL)focused animated:(BOOL)animated completion:(id)block {
    // 用 nil 替换 completion block，防止任何跳转回调
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
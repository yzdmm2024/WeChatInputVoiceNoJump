#import <UIKit/UIKit.h>
#import <objc/message.h>

// ============================================================
// 微信输入法自用 - 语音免跳转
// 点击语音按钮直接开始录音，不跳转设置页
// Hook: WBFunctionToolBar.handleItemClickEvent:func:controlEvent:
// func:0x1 = 语音功能
// ============================================================

%hook WBFunctionToolBar

- (void)handleItemClickEvent:(id)event func:(int)func controlEvent:(UIControlEvents)ctrl {
    if (func == 0x1) {
        ((void (*)(id, SEL, BOOL, BOOL, id))objc_msgSend)(self, @selector(setVoiceInputFocused:animated:completion:), YES, NO, nil);
        return;
    }
    %orig;
}

%end
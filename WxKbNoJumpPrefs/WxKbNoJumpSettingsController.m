//
//  WxKbNoJumpSettingsController.m — 微信键盘免跳转设置面板（PSListController）
//
//  说明：面板由 PreferenceLoader 加载到 system Settings。
//  关键点（对应 README 坑 F）：
//   - 必须读写真实的 `_specifiers` ivar（不能只靠关联对象，否则框架读不到列表 → 面板空白）
//   - 必须在 Root.plist 里声明正确的 specifiers（含滑块 + 开关注册），
//     并在加载时把「用于预览的实时值」缓存下来。
//
//  实现要点：
//   - loadSpecifiersFromPlistName 读取 Root.plist 生成骨架
//   - 重写 cellForRowAtIndexPath 给 PSSliderCell 显示中文名 + 当前值
//   - 顶部 WxKbKeyboardPreviewView 实时预览键盘外观
//   - 用 class_getInstanceVariable + object_get/setIvar 读写 _specifiers
//

#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - 键盘外观预览视图

@interface WxKbKeyboardPreviewView : UIView
@property (nonatomic, assign) CGFloat radius;
@property (nonatomic, assign) CGFloat red, green, blue, alpha;
@end

@implementation WxKbKeyboardPreviewView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.radius = 10.0;
        self.red = 0.15; self.green = 0.16; self.blue = 0.20; self.alpha = 1.0;
    }
    return self;
}

// 画一个简化 QWERTY 键盘，方便实时预览
- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGFloat W = self.bounds.size.width;
    CGFloat H = self.bounds.size.height;

    // 键盘背景
    CGContextSetRGBFillColor(ctx, self.red, self.green, self.blue, self.alpha);
    UIBezierPath *bg = [UIBezierPath bezierPathWithRoundedRect:self.bounds
                                                  cornerRadius:self.radius];
    [bg fill];

    // 三排按键（简化布局）
    NSArray *rows = @[
        @[@"Q",@"W",@"E",@"R",@"T",@"Y",@"U",@"I",@"O",@"P"],
        @[@"A",@"S",@"D",@"F",@"G",@"H",@"J",@"K",@"L"],
        @[@"⇧",@"Z",@"X",@"C",@"V",@"B",@"N",@"M",@"⌫"]
    ];
    CGFloat margin = W * 0.01;
    CGFloat rowH = (H - margin * 4) / 3.0;
    for (int i = 0; i < rows.count; i++) {
        NSArray *keys = rows[i];
        CGFloat top = margin + i * (rowH + margin);
        CGFloat keyW = (W - margin * (keys.count + 1)) / keys.count;
        for (int j = 0; j < keys.count; j++) {
            CGFloat x = margin + j * (keyW + margin);
            CGRect krect = CGRectMake(x, top, keyW, rowH - margin);
            CGContextSetRGBFillColor(ctx, 0.9, 0.9, 0.92, 1.0);
            CGContextFillRect(ctx, krect);
            // 画文案
            UIColor *tc = [UIColor darkGrayColor];
            NSDictionary *attrs = @{ NSFontAttributeName: [UIFont systemFontOfSize:rowH * 0.35],
                                     NSForegroundColorAttributeName: tc };
            CGSize s = [keys[j] sizeWithAttributes:attrs];
            [keys[j] drawAtPoint:CGPointMake(CGRectGetMidX(krect) - s.width/2,
                                             CGRectGetMidY(krect) - s.height/2)
                  withAttributes:attrs];
        }
    }
}

@end

#pragma mark - 面板控制器

@interface WxKbNoJumpSettingsController : PSListController
@property (nonatomic, strong) WxKbKeyboardPreviewView *preview;
@end

@implementation WxKbNoJumpSettingsController

- (instancetype)init {
    self = [super init];
    if (self) {
        _preview = [[WxKbKeyboardPreviewView alloc] initWithFrame:CGRectZero];
    }
    return self;
}

- (id)specifiers {
    // 关键：读写真实的 _specifiers ivar（README 坑 F）
    Ivar iv = class_getInstanceVariable([PSListController class], "_specifiers");
    if (iv) {
        id v = object_getIvar(self, iv);
        if (v) return v;
    }

    return [self loadSpecifiersFromPlistName:@"Root" target:self];
}

- (void)loadView {
    [super loadView];

    // 顶部加入预览视图（当作 tableHeaderView）
    CGFloat headerH = 150;
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, headerH)];
    header.backgroundColor = [UIColor clearColor];
    self.preview.frame = CGRectMake(16, 8, header.bounds.size.width - 32, headerH - 16);
    [header addSubview:self.preview];
    self.table.tableHeaderView = header;

    // 从现有 specifiers 读当前值并刷新预览
    [self refreshPreviewFromSpecifiers];
}

- (void)refreshPreviewFromSpecifiers {
    NSArray *specs = [self specifiers];
    for (PSSpecifier *s in specs) {
        NSString *key = [s propertyForKey:@"key"];
        if ([key isEqualToString:@"wxkbdCornerRadius"]) {
            id v = [specs valueForKeyPath:@"wxkbdCornerRadius"];
            _preview.radius = [v respondsToSelector:@selector(floatValue)] ? [v floatValue] : 10;
        } else if ([key isEqualToString:@"wxkbdBgR"]) {
            id v = [self readPreference:key];
            _preview.red = [v respondsToSelector:@selector(floatValue)] ? [v floatValue] : 0.15;
        } else if ([key isEqualToString:@"wxkbdBgG"]) {
            id v = [self readPreference:key];
            _preview.green = [v respondsToSelector:@selector(floatValue)] ? [v floatValue] : 0.16;
        } else if ([key isEqualToString:@"wxkbdBgB"]) {
            id v = [self readPreference:key];
            _preview.blue = [v respondsToSelector:@selector(floatValue)] ? [v floatValue] : 0.20;
        } else if ([key isEqualToString:@"wxkbdBgAlpha"]) {
            id v = [self readPreference:key];
            _preview.alpha = [v respondsToSelector:@selector(floatValue)] ? [v floatValue] : 1.0;
        }
    }
    [_preview setNeedsDisplay];
}

- (id)readPreference:(NSString *)key {
    CFTypeRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                            CFSTR("com.wxkbd.nojump"));
    if (!v) return nil;
    return CFBridgingRelease(v);
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    // 用户在面板里改动滑块 → 实时刷新预览
    NSString *key = [specifier propertyForKey:@"key"];
    CGFloat f = [value respondsToSelector:@selector(floatValue)] ? [value floatValue] : 0;
    if ([key isEqualToString:@"wxkbdCornerRadius"]) _preview.radius = f;
    else if ([key isEqualToString:@"wxkbdBgR"])    _preview.red = f;
    else if ([key isEqualToString:@"wxkbdBgG"])    _preview.green = f;
    else if ([key isEqualToString:@"wxkbdBgB"])    _preview.blue = f;
    else if ([key isEqualToString:@"wxkbdBgAlpha"]) _preview.alpha = f;
}

@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
__attribute__((constructor))
static void WxKbNoJumpPrefsEntry(void) {
    // 空构造，确保分类/类被正确注册（Optional）
}
#pragma clang diagnostic pop
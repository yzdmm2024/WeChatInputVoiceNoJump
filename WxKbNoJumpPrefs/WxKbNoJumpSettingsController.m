//
//  WxKbNoJumpSettingsController.m — 微信键盘免跳转设置面板（PSListController）
//
//  关键：本控制器只在「设置」进程（arm64e）里被 NSBundle 加载。
//  写法严格对齐同机已验证可用的 键盘下方状态(KSSettingsController)：
//   - specifiers 直接读写真实的 _specifiers 裸 ivar（PSListController 内部就读它）
//   - 面板 UI 一律放 viewDidLoad，访问 self.table（本机框架）并兼容 self.tableView
//   - 任何偏好写入都先 [super setPreferenceValue:...]（走 cfprefsd，沙盒安全）
//

#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kWxSuite = @"com.wxkbd.nojump";

#pragma mark - 键盘外观预览视图（纯 UIView，drawRect 自绘，绝不涉及未实现选择器）

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

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGFloat W = self.bounds.size.width;
    CGFloat H = self.bounds.size.height;

    // 键盘背景
    CGContextSetRGBFillColor(ctx, self.red, self.green, self.blue, self.alpha);
    UIBezierPath *bg = [UIBezierPath bezierPathWithRoundedRect:self.bounds
                                                  cornerRadius:self.radius];
    [bg fill];

    // 三排按键（简化布局，仅用于预览外观）
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

// 关键：直接读写 PSListController 的 _specifiers 裸 ivar（第一次加载后缓存，避免每次重建）
- (id)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"微信键盘免跳转";

    // 顶部预览视图（tableHeaderView）。⚠️ 本机 Preferences 框架的 PSListController 用
    // -table 访问器（非 -tableView），两者都兼容：先试 table，再退 tableView。
    CGFloat W = self.view.bounds.size.width > 0 ? self.view.bounds.size.width : 320;
    CGFloat headerH = 150;
    self.preview = [[WxKbKeyboardPreviewView alloc] initWithFrame:CGRectMake(16, 8, W - 32, headerH - 16)];
    self.preview.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, headerH)];
    header.backgroundColor = [UIColor clearColor];
    [header addSubview:self.preview];
    UITableView *tv = nil;
    if ([self respondsToSelector:@selector(table)]) tv = [self table];
    else if ([self respondsToSelector:@selector(tableView)]) tv = [self tableView];
    tv.tableHeaderView = header;

    [self refreshPreview];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshPreview];
}

- (void)refreshPreview {
    NSArray *specs = [self specifiers];
    for (PSSpecifier *s in specs) {
        NSString *key = [s propertyForKey:@"key"];
        if (![key isKindOfClass:[NSString class]] || key.length == 0) continue;
        CGFloat f = 0;
        id v = [self readPreference:key];
        if ([v respondsToSelector:@selector(floatValue)]) f = [v floatValue];
        if      ([key isEqualToString:@"wxkbdCornerRadius"]) _preview.radius = f ?: 10.0;
        else if ([key isEqualToString:@"wxkbdBgR"])          _preview.red   = f ?: 0.15;
        else if ([key isEqualToString:@"wxkbdBgG"])          _preview.green = f ?: 0.16;
        else if ([key isEqualToString:@"wxkbdBgB"])          _preview.blue  = f ?: 0.20;
        else if ([key isEqualToString:@"wxkbdBgAlpha"])      _preview.alpha = f ?: 1.0;
    }
    [_preview setNeedsDisplay];
}

- (id)readPreference:(NSString *)key {
    CFTypeRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                            (__bridge CFStringRef)kWxSuite);
    return v ? CFBridgingRelease(v) : nil;
}

// 开关/滑块变动都走这里：先 [super ...] 走 cfprefsd 标准写回（沙盒放行），再实时刷新预览
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    @try {
        [super setPreferenceValue:value specifier:specifier];
        NSString *key = [specifier propertyForKey:@"key"];
        CGFloat f = [value respondsToSelector:@selector(floatValue)] ? [value floatValue] : 0;
        if      ([key isEqualToString:@"wxkbdCornerRadius"]) _preview.radius = f;
        else if ([key isEqualToString:@"wxkbdBgR"])          _preview.red   = f;
        else if ([key isEqualToString:@"wxkbdBgG"])          _preview.green = f;
        else if ([key isEqualToString:@"wxkbdBgB"])          _preview.blue  = f;
        else if ([key isEqualToString:@"wxkbdBgAlpha"])      _preview.alpha = f;
        [_preview setNeedsDisplay];
    } @catch (NSException *e) {}
}

@end

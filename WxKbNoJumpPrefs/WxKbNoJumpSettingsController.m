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
@property (nonatomic, assign) CGFloat radius, gap, keyHeight, font;
@property (nonatomic, assign) CGFloat lr, lg, lb, la;   // 字母键底色
@property (nonatomic, assign) CGFloat fr, fg, fb, fa;   // 功能键底色
@property (nonatomic, assign) CGFloat kr, kg, kb_, ka;  // 键盘背景
@property (nonatomic, assign) CGFloat cr, cg, cb, ca;   // 候选栏背景
@end

@implementation WxKbKeyboardPreviewView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        _radius = 10; _gap = 6; _keyHeight = 56; _font = 22;
        _lr = 1; _lg = 1; _lb = 1; _la = 1;
        _fr = 0.827; _fg = 0.839; _fb = 0.859; _fa = 1;
        _kr = 0.914; _kg = 0.914; _kb_ = 0.922; _ka = 1;
        _cr = 0.914; _cg = 0.914; _cb = 0.922; _ca = 1;
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGFloat W = self.bounds.size.width;
    CGFloat H = self.bounds.size.height;

    // 候选栏（顶部一条）
    CGContextSetRGBFillColor(ctx, _cr, _cg, _cb, _ca);
    CGRect candRect = CGRectMake(0, 0, W, H * 0.18);
    CGContextFillRect(ctx, candRect);

    // 键盘背景托盘
    CGContextSetRGBFillColor(ctx, _kr, _kg, _kb_, _ka);
    CGRect kbRect = CGRectMake(0, candRect.size.height, W, H - candRect.size.height);
    CGContextFillRect(ctx, kbRect);

    // 三排按键：字母键(白) / 功能键(灰)，圆角 + 间距 + 高度实时反映
    NSArray *rows = @[
        @[@"Q",@"W",@"E",@"R",@"T",@"Y",@"U",@"I",@"O",@"P"],
        @[@"A",@"S",@"D",@"F",@"G",@"H",@"J",@"K",@"L"],
        @[@"⇧",@"Z",@"X",@"C",@"V",@"B",@"N",@"M",@"⌫"]
    ];
    CGFloat top0 = candRect.size.height + 6;
    CGFloat areaH = H - top0 - 6;
    CGFloat rowH = areaH / 3.0;
    CGFloat rgap = MAX(_gap, 2);
    for (int i = 0; i < rows.count; i++) {
        NSArray *keys = rows[i];
        CGFloat rowTop = top0 + i * rowH;
        CGFloat keyW = (W - rgap * (keys.count + 1)) / keys.count;
        for (int j = 0; j < keys.count; j++) {
            CGFloat x = rgap + j * (keyW + rgap);
            CGRect krect = CGRectMake(x, rowTop + rgap/2, keyW, rowH - rgap);
            BOOL isFunc = (i == 2);  // 第三排为功能键（⇧/⌫）+ 字母，简化：⇧⌫视为功能
            if (i == 2 && (j == 0 || j == keys.count - 1)) isFunc = YES;
            CGFloat r = (isFunc ? _fr : _lr), g = (isFunc ? _fg : _lg),
                    b = (isFunc ? _fb : _lb), a = (isFunc ? _fa : _la);
            CGContextSetRGBFillColor(ctx, r, g, b, a);
            UIBezierPath *kr = [UIBezierPath bezierPathWithRoundedRect:krect cornerRadius:_radius];
            [kr fill];
            UIColor *tc = isFunc ? [UIColor darkGrayColor] : [UIColor blackColor];
            UIFont *uf = [UIFont systemFontOfSize:_font];
            NSDictionary *attrs = @{ NSFontAttributeName: uf, NSForegroundColorAttributeName: tc };
            NSString *t = keys[j];
            CGSize s = [t sizeWithAttributes:attrs];
            [t drawAtPoint:CGPointMake(CGRectGetMidX(krect) - s.width/2,
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

- (id)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"微信键盘免跳转";

    CGFloat W = self.view.bounds.size.width > 0 ? self.view.bounds.size.width : 320;
    CGFloat headerH = 170;
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
    for (PSSpecifier *s in [self specifiers]) {
        NSString *key = [s propertyForKey:@"key"];
        if (![key isKindOfClass:[NSString class]] || key.length == 0) continue;
        CGFloat f = 0;
        id v = [self readPreference:key];
        if ([v respondsToSelector:@selector(floatValue)]) f = [v floatValue];
        if      ([key isEqualToString:@"wxkbdKeyRadius"]) _preview.radius = f ?: 10;
        else if ([key isEqualToString:@"wxkbdKeyGap"])    _preview.gap = f ?: 6;
        else if ([key isEqualToString:@"wxkbdKeyHeight"])  _preview.keyHeight = f ?: 56;
        else if ([key isEqualToString:@"wxkbdKeyFont"])    _preview.font = f ?: 22;
        else if ([key isEqualToString:@"wxkbdLetterR"])    _preview.lr = f ?: 1;
        else if ([key isEqualToString:@"wxkbdLetterG"])    _preview.lg = f ?: 1;
        else if ([key isEqualToString:@"wxkbdLetterB"])    _preview.lb = f ?: 1;
        else if ([key isEqualToString:@"wxkbdLetterA"])    _preview.la = f ?: 1;
        else if ([key isEqualToString:@"wxkbdFuncR"])      _preview.fr = f ?: 0.827;
        else if ([key isEqualToString:@"wxkbdFuncG"])      _preview.fg = f ?: 0.839;
        else if ([key isEqualToString:@"wxkbdFuncB"])      _preview.fb = f ?: 0.859;
        else if ([key isEqualToString:@"wxkbdFuncA"])      _preview.fa = f ?: 1;
        else if ([key isEqualToString:@"wxkbdKbR"])        _preview.kr = f ?: 0.914;
        else if ([key isEqualToString:@"wxkbdKbG"])        _preview.kg = f ?: 0.914;
        else if ([key isEqualToString:@"wxkbdKbB"])        _preview.kb_ = f ?: 0.922;
        else if ([key isEqualToString:@"wxkbdKbA"])        _preview.ka = f ?: 1;
        else if ([key isEqualToString:@"wxkbdCandR"])      _preview.cr = f ?: 0.914;
        else if ([key isEqualToString:@"wxkbdCandG"])      _preview.cg = f ?: 0.914;
        else if ([key isEqualToString:@"wxkbdCandB"])      _preview.cb = f ?: 0.922;
        else if ([key isEqualToString:@"wxkbdCandA"])      _preview.ca = f ?: 1;
    }
    [_preview setNeedsDisplay];
}

- (id)readPreference:(NSString *)key {
    CFTypeRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                            (__bridge CFStringRef)kWxSuite);
    return v ? CFBridgingRelease(v) : nil;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    @try {
        [super setPreferenceValue:value specifier:specifier];
        NSString *key = [specifier propertyForKey:@"key"];
        CGFloat f = [value respondsToSelector:@selector(floatValue)] ? [value floatValue] : 0;
        if      ([key isEqualToString:@"wxkbdKeyRadius"]) _preview.radius = f;
        else if ([key isEqualToString:@"wxkbdKeyGap"])    _preview.gap = f;
        else if ([key isEqualToString:@"wxkbdKeyHeight"])  _preview.keyHeight = f;
        else if ([key isEqualToString:@"wxkbdKeyFont"])    _preview.font = f;
        else if ([key isEqualToString:@"wxkbdLetterR"])    _preview.lr = f;
        else if ([key isEqualToString:@"wxkbdLetterG"])    _preview.lg = f;
        else if ([key isEqualToString:@"wxkbdLetterB"])    _preview.lb = f;
        else if ([key isEqualToString:@"wxkbdLetterA"])    _preview.la = f;
        else if ([key isEqualToString:@"wxkbdFuncR"])      _preview.fr = f;
        else if ([key isEqualToString:@"wxkbdFuncG"])      _preview.fg = f;
        else if ([key isEqualToString:@"wxkbdFuncB"])      _preview.fb = f;
        else if ([key isEqualToString:@"wxkbdFuncA"])      _preview.fa = f;
        else if ([key isEqualToString:@"wxkbdKbR"])        _preview.kr = f;
        else if ([key isEqualToString:@"wxkbdKbG"])        _preview.kg = f;
        else if ([key isEqualToString:@"wxkbdKbB"])        _preview.kb_ = f;
        else if ([key isEqualToString:@"wxkbdKbA"])        _preview.ka = f;
        else if ([key isEqualToString:@"wxkbdCandR"])      _preview.cr = f;
        else if ([key isEqualToString:@"wxkbdCandG"])      _preview.cg = f;
        else if ([key isEqualToString:@"wxkbdCandB"])      _preview.cb = f;
        else if ([key isEqualToString:@"wxkbdCandA"])      _preview.ca = f;
        [_preview setNeedsDisplay];
    } @catch (NSException *e) {}
}

@end

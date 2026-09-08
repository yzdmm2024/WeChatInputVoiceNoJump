//
//  WxKbNoJumpSettingsController.m — 系统-设置里的「微信键盘免跳转」面板控制器
//  编译为 WxKbNoJumpPrefs.bundle 内的可执行（MH_DYLIB），由 PreferenceLoader 载入。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <spawn.h>

#pragma mark - 前向声明（不依赖 Preferences 私有头）

// 注意: PSListController 继承自 PSViewController→UIViewController，不是 UITableViewController！
// 实测 (iOS 16.6, frida): instancesRespondToSelector:@selector(tableView) == NO，
// 表视图访问器是 -table。误用 self.tableView 会 doesNotRecognizeSelector → 设置闪退。
@interface PSListController : UIViewController
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (id)specifierAtIndexPath:(NSIndexPath *)indexPath;
- (UITableView *)table;
@end

@interface PSSpecifier : NSObject
- (id)propertyForKey:(NSString *)key;
- (void)setProperty:(id)value forKey:(NSString *)key;
- (NSString *)identifier;
- (NSString *)name;
@end

#pragma mark - 键盘预览视图

@interface WxKbKeyboardPreviewView : UIView
@property (nonatomic, assign) CGFloat keyCornerRadius;
@property (nonatomic, assign) CGFloat keyboardScale;
@property (nonatomic, assign) CGFloat bgAlpha;
@property (nonatomic, strong) UIColor *kbBackgroundColor;
@property (nonatomic, assign) BOOL styleEnabled;
@end

@implementation WxKbKeyboardPreviewView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.contentMode = UIViewContentModeRedraw;
        _keyCornerRadius = 6.0;
        _keyboardScale = 1.0;
        _bgAlpha = 1.0;
        _kbBackgroundColor = [UIColor colorWithRed:0.92 green:0.93 blue:0.94 alpha:1.0];
        _styleEnabled = YES;
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGFloat W = rect.size.width;
    CGFloat H = rect.size.height;

    // 整体背景（应用用户设置：颜色 + 透明度 + 缩放 + 圆角）
    UIColor *bg = self.kbBackgroundColor ?: [UIColor colorWithWhite:0.9 alpha:1.0];
    CGFloat alpha = self.styleEnabled ? MAX(0.2f, MIN(1.0f, self.bgAlpha)) : 0.25f;
    CGRect boardRect = CGRectInset(rect, 8, 8);
    CGFloat cr = self.styleEnabled ? MAX(0, MIN(40, self.keyCornerRadius)) : 6.0;

    UIBezierPath *boardPath = [UIBezierPath bezierPathWithRoundedRect:boardRect cornerRadius:cr];
    UIColor *bgWithAlpha = [bg colorWithAlphaComponent:alpha];
    [bgWithAlpha setFill];
    [boardPath fill];

    // 缩放以中心为基准
    CGFloat sc = self.styleEnabled ? MAX(0.6f, MIN(1.4f, self.keyboardScale)) : 1.0f;
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, W / 2.0, H / 2.0);
    CGContextScaleCTM(ctx, sc, sc);
    CGContextTranslateCTM(ctx, -W / 2.0, -H / 2.0);

    // 文字颜色（用 blackColor 兼容性最好）
    UIColor *textColor = [UIColor blackColor];
    UIFont *font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];

    // 绘制一个简化 QWERTY 键盘
    // 工具栏
    CGFloat toolY = boardRect.origin.y + 10;
    NSUInteger toolCount = 6;
    CGFloat toolW = 28;
    CGFloat toolGap = (boardRect.size.width - toolCount * toolW) / (toolCount + 1);
    NSArray *toolIcons = @[@"P", @"😀", @"🎤", @"📎", @"中/A", @"⌄"];
    for (NSUInteger i = 0; i < toolCount; i++) {
        CGRect f = CGRectMake(boardRect.origin.x + toolGap + i * (toolW + toolGap),
                              toolY, toolW, toolW);
        UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:f cornerRadius:f.size.width/2.0];
        UIColor *keyFill = [[UIColor whiteColor] colorWithAlphaComponent:0.9f];
        [keyFill setFill];
        [p fill];
        [textColor set];
        NSString *icon = toolIcons[i];
        CGSize ts = [icon sizeWithAttributes:@{NSFontAttributeName: font}];
        [icon drawAtPoint:CGPointMake(CGRectGetMidX(f) - ts.width/2.0,
                                      CGRectGetMidY(f) - ts.height/2.0)
           withAttributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: textColor}];
    }

    // 按键区
    CGFloat startY = toolY + toolW + 14;
    CGFloat keyH = 26;
    CGFloat rowGap = 8;
    NSArray *rows = @[
        @[@"Q", @"W", @"E", @"R", @"T", @"Y", @"U", @"I", @"O", @"P"],
        @[@"A", @"S", @"D", @"F", @"G", @"H", @"J", @"K", @"L"],
        @[@"⇧", @"Z", @"X", @"C", @"V", @"B", @"N", @"M", @"⌫"],
        @[@"123", @"，", @"空格", @"中/英", @"发送"]
    ];

    CGFloat usableW = boardRect.size.width - 20;
    CGFloat leftX = boardRect.origin.x + 10;

    void (^drawKey)(CGRect, NSString *, BOOL) = ^(CGRect f, NSString *title, BOOL wide) {
        CGFloat keyCR = self.styleEnabled ? cr : 5.0;
        UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:f cornerRadius:keyCR];
        UIColor *kf = [[UIColor whiteColor] colorWithAlphaComponent:0.95f];
        [kf setFill];
        [p fill];
        [textColor set];
        UIFont *fnt = wide ? [UIFont systemFontOfSize:10 weight:UIFontWeightMedium] : font;
        CGSize ts = [title sizeWithAttributes:@{NSFontAttributeName: fnt}];
        [title drawAtPoint:CGPointMake(CGRectGetMidX(f) - ts.width/2.0,
                                       CGRectGetMidY(f) - ts.height/2.0)
            withAttributes:@{NSFontAttributeName: fnt, NSForegroundColorAttributeName: textColor}];
    };

    CGFloat y = startY;
    for (NSUInteger r = 0; r < rows.count; r++) {
        NSArray *row = rows[r];
        CGFloat gap = 5;
        if (r == 3) {
            // 底行：123 / 标点 / 空格 / 中英 / 发送
            NSArray *widths = @[@0.13, @0.10, @0.44, @0.13, @0.16];
            CGFloat x = leftX;
            for (NSUInteger c = 0; c < row.count; c++) {
                CGFloat w = usableW * [widths[c] doubleValue];
                drawKey(CGRectMake(x, y, w - gap, keyH), row[c], YES);
                x += w;
            }
        } else {
            CGFloat keyW = (usableW - (row.count + 1) * gap) / row.count;
            if (r == 2) {
                // shift / backspace 稍宽
                keyW = (usableW - (row.count - 1) * gap - 8) / (row.count - 1);
                CGFloat x = leftX;
                for (NSUInteger c = 0; c < row.count; c++) {
                    CGFloat w = keyW;
                    if (c == 0 || c == row.count - 1) w = keyW + 4;
                    drawKey(CGRectMake(x, y, w, keyH), row[c], NO);
                    x += w + gap;
                }
            } else {
                CGFloat x = leftX;
                for (NSUInteger c = 0; c < row.count; c++) {
                    drawKey(CGRectMake(x, y, keyW, keyH), row[c], NO);
                    x += keyW + gap;
                }
            }
        }
        y += keyH + rowGap;
    }

    CGContextRestoreGState(ctx);

    // 未启用外观时盖一层提示
    if (!self.styleEnabled) {
        UIColor *overlay = [UIColor colorWithWhite:1.0 alpha:0.55];
        [overlay setFill];
        CGContextFillRect(ctx, rect);
        NSString *hint = @"外观定制未启用";
        UIFont *hf = [UIFont boldSystemFontOfSize:16];
        CGSize hs = [hint sizeWithAttributes:@{NSFontAttributeName: hf}];
        [textColor set];
        [hint drawAtPoint:CGPointMake((W - hs.width)/2.0, (H - hs.height)/2.0)
           withAttributes:@{NSFontAttributeName: hf, NSForegroundColorAttributeName: textColor}];
    }
}

@end

#pragma mark - 设置控制器

@interface WxKbNoJumpSettingsController : PSListController
@property (nonatomic, strong) WxKbKeyboardPreviewView *previewView;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UILabel *> *valueLabels;
- (void)respring;
- (void)resetDefaults;
@end

@implementation WxKbNoJumpSettingsController

static NSString *wx_prefPath(void) {
    return @"/var/mobile/Library/Preferences/com.wxkbd.nojump.plist";
}

static NSDictionary *wx_prefs(void) {
    return [NSDictionary dictionaryWithContentsOfFile:wx_prefPath()] ?: @{};
}

static CGFloat wx_floatPref(NSString *k, CGFloat def) {
    id v = wx_prefs()[k];
    if ([v respondsToSelector:@selector(floatValue)]) return [v floatValue];
    if ([v respondsToSelector:@selector(doubleValue)]) return [v doubleValue];
    return def;
}

static BOOL wx_boolPref(NSString *k, BOOL def) {
    id v = wx_prefs()[k];
    if ([v respondsToSelector:@selector(boolValue)]) return [v boolValue];
    return def;
}

// 关键修复：PSListController 内部通过自己的 _specifiers 实例变量读取列表。
// 用关联对象会导致框架读到的 _specifiers 为 nil → 面板空白。
- (NSArray *)specifiers {
    Ivar iv = class_getInstanceVariable(object_getClass(self), "_specifiers");
    NSArray *s = iv ? (NSArray *)object_getIvar(self, iv) : nil;
    if (!s) {
        s = [self loadSpecifiersFromPlistName:@"Root" target:self];
        if (iv) object_setIvar(self, iv, s);
    }
    return s;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"微信键盘免跳转";
    self.valueLabels = [NSMutableDictionary dictionary];

    CGFloat W = self.view.bounds.size.width > 0 ? self.view.bounds.size.width : 320;
    CGFloat previewH = 220;
    self.previewView = [[WxKbKeyboardPreviewView alloc] initWithFrame:CGRectMake(0, 0, W, previewH)];
    self.previewView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    // PSListController 没有 -tableView，表视图要用 -table 拿；防御式判断避免再闪退
    UITableView *tv = [self respondsToSelector:@selector(table)] ? [self table] : nil;
    if (!tv && [self respondsToSelector:@selector(tableView)]) tv = [(id)self tableView];
    if (tv) tv.tableHeaderView = self.previewView;

    [self refreshPreviewAndLabels];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshPreviewAndLabels];
}

- (void)refreshPreviewAndLabels {
    BOOL styleOn = wx_boolPref(@"wxkbdStyleEnabled", NO);
    self.previewView.styleEnabled = styleOn;
    if (styleOn) {
        self.previewView.keyCornerRadius = wx_floatPref(@"wxkbdCornerRadius", 10.0);
        self.previewView.keyboardScale     = wx_floatPref(@"wxkbdScale", 1.0);
        self.previewView.bgAlpha           = wx_floatPref(@"wxkbdBgAlpha", 1.0);
        CGFloat r = wx_floatPref(@"wxkbdBgR", 0.92);
        CGFloat g = wx_floatPref(@"wxkbdBgG", 0.93);
        CGFloat b = wx_floatPref(@"wxkbdBgB", 0.94);
        self.previewView.kbBackgroundColor = [UIColor colorWithRed:r green:g blue:b alpha:1.0];
    } else {
        self.previewView.keyCornerRadius = 6.0;
        self.previewView.keyboardScale = 1.0;
        self.previewView.bgAlpha = 1.0;
        self.previewView.kbBackgroundColor = [UIColor colorWithWhite:0.9 alpha:1.0];
    }
    [self.previewView setNeedsDisplay];

    // 刷新所有已创建的 value label
    for (PSSpecifier *spec in [self specifiers]) {
        NSString *key = [spec identifier];
        if (!key) continue;
        UILabel *lab = self.valueLabels[key];
        if (!lab) continue;
        if ([key isEqualToString:@"wxkbdCornerRadius"]) {
            lab.text = [NSString stringWithFormat:@"%.1f", wx_floatPref(key, 10.0)];
        } else if ([key isEqualToString:@"wxkbdScale"]) {
            lab.text = [NSString stringWithFormat:@"%.2f", wx_floatPref(key, 1.0)];
        } else if ([key isEqualToString:@"wxkbdBgAlpha"]) {
            lab.text = [NSString stringWithFormat:@"%.2f", wx_floatPref(key, 1.0)];
        } else if ([key hasPrefix:@"wxkbdBg"]) {
            lab.text = [NSString stringWithFormat:@"%.2f", wx_floatPref(key, 0.0)];
        }
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    if (!spec) return cell;

    NSString *key = [spec identifier];
    NSString *cellType = [spec propertyForKey:@"cell"] ?: @"";

    // 给 slider cell 加上：左侧中文名 + 右侧当前数值
    if ([cellType isEqualToString:@"PSSliderCell"]) {
        UISlider *slider = nil;
        for (UIView *v in cell.contentView.subviews) {
            if ([v isKindOfClass:[UISlider class]]) { slider = (UISlider *)v; break; }
            for (UIView *vv in v.subviews) {
                if ([vv isKindOfClass:[UISlider class]]) { slider = (UISlider *)vv; break; }
            }
        }
        if (slider && key) {
            slider.accessibilityIdentifier = key;
            [slider removeTarget:self action:NULL forControlEvents:UIControlEventValueChanged];
            [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];

            UILabel *valLab = self.valueLabels[key];
            if (!valLab) {
                valLab = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 50, 22)];
                valLab.textAlignment = NSTextAlignmentRight;
                valLab.font = [UIFont systemFontOfSize:13];
                valLab.textColor = [UIColor grayColor];
                valLab.tag = 10001;
                self.valueLabels[key] = valLab;
            }
            // 放在 cell 右侧
            CGRect cf = cell.contentView.bounds;
            valLab.frame = CGRectMake(cf.size.width - 55, (cf.size.height - 22)/2.0, 50, 22);
            valLab.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
            if (valLab.superview != cell.contentView) [cell.contentView addSubview:valLab];

            // 初始值
            if ([key isEqualToString:@"wxkbdCornerRadius"])
                valLab.text = [NSString stringWithFormat:@"%.1f", slider.value];
            else
                valLab.text = [NSString stringWithFormat:@"%.2f", slider.value];
        }
    }

    // 外观开关变化时刷新预览
    if ([cellType isEqualToString:@"PSSwitchCell"] && [key isEqualToString:@"wxkbdStyleEnabled"]) {
        UISwitch *sw = nil;
        for (UIView *v in cell.contentView.subviews) {
            if ([v isKindOfClass:[UISwitch class]]) { sw = (UISwitch *)v; break; }
        }
        if (sw) {
            [sw removeTarget:self action:NULL forControlEvents:UIControlEventValueChanged];
            [sw addTarget:self action:@selector(styleSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        }
    }

    return cell;
}

- (void)sliderChanged:(UISlider *)slider {
    NSString *key = slider.accessibilityIdentifier;
    if (!key) return;

    // 同步数值标签
    UILabel *lab = self.valueLabels[key];
    if (lab) {
        if ([key isEqualToString:@"wxkbdCornerRadius"])
            lab.text = [NSString stringWithFormat:@"%.1f", slider.value];
        else
            lab.text = [NSString stringWithFormat:@"%.2f", slider.value];
    }

    // 写回 plist（PSListController 本身也会写，这里写一次确保实时预览时不出错）
    NSString *pp = wx_prefPath();
    NSMutableDictionary *p = [wx_prefs() mutableCopy] ?: [NSMutableDictionary dictionary];
    p[key] = @(slider.value);
    [p writeToFile:pp atomically:YES];

    // 实时更新预览
    [self refreshPreviewAndLabels];
}

- (void)styleSwitchChanged:(UISwitch *)sw {
    NSString *pp = wx_prefPath();
    NSMutableDictionary *p = [wx_prefs() mutableCopy] ?: [NSMutableDictionary dictionary];
    p[@"wxkbdStyleEnabled"] = @(sw.on);
    [p writeToFile:pp atomically:YES];
    [self refreshPreviewAndLabels];
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
    [[NSFileManager defaultManager] removeItemAtPath:wx_prefPath() error:nil];
    [self respring];
}

@end

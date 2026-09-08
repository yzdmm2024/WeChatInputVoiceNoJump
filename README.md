# 微信键盘免跳转 (WxKbNoJump)

微信输入法（WeType）**语音输入全局免跳转** + **键盘外观定制**（圆角 / 大小 / 颜色 / 透明度）。

- 目标设备：iPhone 12 Pro 等 A14（arm64e），iOS 16.6.1
- 越狱环境：relaxin rootless（/var/jb 前缀，ElleKit / TweakInject 注入）
- 构建方式：**Theos**（本仓库由 GitHub Actions 在 macOS runner 上自动编译，产出 rootless arm64e deb）

## 功能

1. **语音免跳转**：拦截微信键盘「语音」按钮触发的外跳，直接激活键盘内建语音输入，不再跳回主 App。
   - NSUserDefaults 对微信自带键 `WBAppSettingsBool_VoiceInput_WcVoiceNoJump` 恒返回 YES（最稳）
   - 语音按钮（`WBFunctionToolBar`）直接激活内建语音
   - `UIInputViewController` / `NSExtensionContext` / `UIApplication` 三处 `openURL` 拦截 `wetype://` 语音跳转
2. **键盘外观定制**：系统-设置面板调节圆角、缩放、不透明度、背景 RGB。

## 为什么不用手工编译的 deb（历史）

早期手工用 LLVM/clang + lld 编出的 bundle 在 iPhone 12 Pro（arm64e）上被 PreferenceLoader 报
「已损坏或丢失必要的资源」，根因有三（已在 Theos 工程中修正）：

- **坑F（arm64e 切片）**：A14 只认 arm64e，手工编出来是 arm64 → `ARCHS = arm64e`
- **坑E（Preferences 链接）**：面板 bundle 必须链接 Preferences / PreferencesUI 才能加载 PSListController
  → `WxKbNoJumpPrefs_FRAMEWORKS = UIKit Foundation Preferences` + `PRIVATE_FRAMEWORKS = PreferencesUI`
- **坑C（入口字段）**：PreferenceLoader 入口 `bundle` 必须等于 bundle 目录名、`detail` 必须等于 `NSPrincipalClass`
  → `WxKbNoJump.plist` 的 `bundle = WxKbNoJumpPrefs`，`Info.plist` 的 `NSPrincipalClass = WxKbNoJumpSettingsController`

- **坑D（rootless 布局路径）**：rootless 包 Theos 会自动给所有根路径加 `/var/jb` 前缀。
  布局文件**不能**再写 `layout/var/jb/...`，否则会变成 `/var/jb/var/jb/...`，PreferenceLoader 入口找不到、设置项不显示。
  → 布局用 `layout/Library/PreferenceLoader/Preferences/WxKbNoJump.plist`（不带 var/jb）

- **坑E2（面板空白：bundle 资源缺失）**：rootless 下 Theos 的 `XXX_RESOURCES` 不会把 `Root.plist`/`Info.plist` 打进 `.bundle`，
  导致 `PSListController` 加载不到 specifiers → 设置里**只有标题、下面全空白**。
  → 改用 `layout/Library/PreferenceBundles/WxKbNoJumpPrefs.bundle/` 直接把 `Root.plist`+`Info.plist` 打进 bundle（已验证有效）

- **坑F（面板空白：关联对象 vs `_specifiers` ivar）**：`PSListController` 内部用 `_specifiers` 实例变量读列表。
  若在 `-specifiers` 里用 `objc_get/setAssociatedObject` 存数组，框架读到的 `_specifiers` 永远是 nil → 标题在、内容全空。
  → 改用 `class_getInstanceVariable` + `object_get/setIvar` 直接读写真实的 `_specifiers` ivar（按名字取，无需私有头）

- **坑G（第三方 App 仍有 1 秒跳转/黑屏）**：微信里生效是因为 NSUserDefaults hook 让微信主 app 走内建语音；
  在备忘录/短信等第三方 App，微信键盘可能直接调 `openURL:` 想拉起主 app。只拦截 URL 会被内部等待动画卡住 1 秒黑屏。
  → 拦截 `openURL:` 后，立刻调用 `WBRootInputView` 的 `initVoiceInputInteractionViewIfNeeded` + `setVoiceInputInteractionViewActive:`，
    让键盘内部语音输入直接出现，绕过跳转。

- **坑H（面板滑块没文字/看不到效果）**：`PSSliderCell` 默认不显示当前数值，且纯文字列表看不出调了什么。
  → 重写 `tableView:cellForRowAtIndexPath:` 给每个滑块左侧强制显示中文名、右侧显示当前值；
    在面板顶部加一个 `WxKbKeyboardPreviewView` 绘制简化 QWERTY 键盘，滑动时实时刷新预览。

## 本地构建

```bash
export THEOS=/path/to/theos
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
# 产物： packages/com.wxkbd.nojump_1.1.4_iphoneos-arm64.deb
```

## CI 构建（推荐）

push 到 `master` 触发 GitHub Actions（`beerpiss/theos-action` + Theos），
自动产出 rootless arm64e deb，可在 **Actions → Build Deb → Artifacts** 下载。

## 目录结构

```
Makefile                          Theos 工程（tweak + preference bundle）
Tweak.xm                         免跳转 + 外观逻辑（ObjC，手工 swizzle）
WxKbNoJump.plist                 tweak Filter（注入进程）
WxKbNoJumpPrefs/                 设置面板 bundle 源码
  ├─ WxKbNoJumpSettingsController.m
  ├─ Info.plist  Root.plist
control                          deb 包元数据
layout/Library/PreferenceLoader/Preferences/WxKbNoJump.plist   面板入口（rootless 自动加 /var/jb 前缀）
.github/workflows/build.yml      CI 构建
archive/                         早期手工编译尝试 + 参考仓库（已废弃，仅供追溯）
docs/ logs/ tools/               分析文档 / 开发诊断日记 / frida 脚本
```

## 安装

用 Filza / Sileo / dpkg 安装 `packages/*.deb`（需 rootless 环境 + PreferenceLoader + ElleKit）。

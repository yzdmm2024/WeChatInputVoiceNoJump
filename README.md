# 微信键盘免跳转 (WxKbNoJump)

微信输入法（WeType）**语音输入全局免跳转** + **键盘外观定制**（圆角 / 大小 / 颜色 / 透明度）。

- 目标设备：iPhone 12 Pro 等 A14（arm64e），iOS 16.6.1
- 越狱环境：relaxin rootless（/var/jb 前缀，ElleKit / TweakInject 注入）
- 构建方式：**Theos**（本仓库由 GitHub Actions 在 macOS runner 上自动编译，产出 rootless arm64e deb）

## 功能

1. **语音免跳转（任意 App）**：从二进制提取真实判定方法，强制 `WBRootViewManager` / `WBVoiceInputService` 的 `canUseWcVoice` / `prefersJumpToMainAppForRecording` / `isUsingWcVoice` / `requireJumpToMainAppForRecording` 走「内建路径」。这样在备忘录/短信等任意 App 里点语音，都走和微信一样的「键盘扩展内录音→腾讯 ASR→`textDocumentProxy.insertText` 回填」，不再 `openURL` 拉起主程序（即不再跳一下/黑屏）。NSUserDefaults 对 `WBAppSettingsBool_VoiceInput_WcVoiceNoJump` 仍恒返回 YES（锦上添花）。
2. **键盘外观定制**：从二进制提取真实视图类 `WBKeyView`（每个字母/数字/符号小键）、`WBKeyboardView`（键盘背景）、`WBCandidateView`/`WBSplitCandidateView`（候选栏）。圆角只作用在 `WBKeyView`（不是整块键盘）；字母键/功能键/键盘背景/候选栏分别上色；支持按键圆角/间距/高度/字号，设置面板顶部有实时预览。

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

- **坑I（颜色/圆角不起效 + 第三方还跳，1.1.11 的尝试）**：1.1.10 把背景色/圆角设到了被遮挡的键盘根视图，所以「颜色压根不起效」、圆角也只在整块键盘上。
  且 `wx_present` 把**所有 `WB*` VC 一律放行**，第三方 App 里微信输入法 present 的全屏语音 VC（WBVoice*/Redirect*）正好被放过 → 跳一下/黑屏。
  → 1.1.11：`wx_applyStyle` 改为下钻子视图树，给每个按键（`UIKBKeyView`/含 Key 的 WB 类）单独加圆角，给键盘背景/托盘上色（首次记录原色、关闭还原）；
    `wx_present` 在键盘扩展进程内拦截 Voice/Speech/Redirect/Recognize/ASR/Record 类 VC 并改激活内建语音，其余 WB* 内部 VC 仍放行。

- **坑J（1.1.11 仍跳 + 美化仍不对，1.1.12 彻底重写）**：1.1.11 的免跳靠「拦截语音 VC + 瞎调 `WBRootInputView` 的 `initVoiceInputInteractionViewIfNeeded`/`setVoiceInputInteractionViewActive:`」——这两个是猜的私有方法，不产生录音界面；且它把整个 `wetype://` 都吞了、还拦截了扩展内真正的录音面板 VC（那恰恰是微信内建录音 UI），于是「录音界面没有」。美化靠猜 `UIKBKeyView` 也没命中 WeType 真实按键类。
  → 1.1.12 用 **frida 真机抓包 + IPA 二进制静态提取**拿到真实证据：① 第三方跳转是 `openURL("wetype://WXKBURL_STARTVOICERECORD?...&APN=<宿主>")`，而录音/ASR 实际在键盘扩展内完成（`WBVoiceInputService`/`WBVoiceInputResultReceiver`/`AVAudioSession`）；② 真实按键类 `WBKeyView`、背景 `WBKeyboardView`、候选栏 `WBCandidateView`。
  → 免跳：删掉瞎调私有方法/拦截录音面板，改为**强制 4 个判定方法走内建路径**（与微信一致），任意 App 点语音都不拉主程序。
  → 美化：精确命中 `WBKeyView`/`WBKeyboardView`/`WBCandidateView`，完全对齐用户的 HTML 原型（每键圆角 + 字母键/功能键/键盘背景/候选栏 4 套底色 + 间距/高度/字号）。

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

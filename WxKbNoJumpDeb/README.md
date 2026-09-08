# 微信键盘免跳转 (rootless deb)

> 目标设备：iPhone 12 Pro / iOS 16.6.1 / **Relaxin（rootless + ElleKit TweakInject）**
> 功能：微信输入法**语音免跳转**（点语音按钮不跳主 app）＋ **键盘外观定制**（圆角/大小/不透明度/RGB 颜色）
> 设置入口：**系统-设置 → 微信键盘免跳转**（PreferenceLoader 面板）

## 产物

```
out/WxKbNoJump_v1.0.3_iphoneos-arm64.deb   # 安装包（Sileo/Zebra/dpkg -i）
out/WxKbNoJump.dylib                        # 注入用 dylib（调试用）
```

deb 内部布局（rootless 加 `var/jb/` 前缀）：
- `usr/lib/TweakInject/WxKbNoJump.dylib` + `WxKbNoJump.plist`（注入过滤器）
- `Library/PreferenceBundles/WxKbNoJumpPrefs.bundle/`（设置面板：Info.plist / Root.plist / WxKbNoJumpPrefs）
- `Library/PreferenceLoader/Preferences/WxKbNoJump.plist`（设置入口）

## 构建

依赖本地工具链 `../本机制造插件的必备东西`（LLVM/clang + iOS SDK + 脚本）：

```bash
bash build.sh
# 或指定工具链： WXKIT=/path/to/本机制造插件的必备东西 bash build.sh
```

## 安装

```bash
# 方式一：Sileo / Zebra 直接装 .deb（推荐，自动处理依赖）
# 方式二：命令行（需设备已装 dpkg）
scp out/WxKbNoJump_v1.0.3_iphoneos-arm64.deb root@<设备IP>:/tmp/
ssh root@<设备IP> "dpkg -i /tmp/WxKbNoJump_v1.0.3_iphoneos-arm64.deb && killall -9 SpringBoard"
```

## 前置依赖（设备必须已装）

- **ElleKit / mobilesubstrate**：TweakInject 加载 dylib（relaxin 自带）
- **PreferenceLoader**：提供「系统-设置」里的面板入口（Sileo/Zebra 搜 preferenceloader 安装）
  没装 PreferenceLoader → 设置里看不到入口。

## 验证

1. 打开 **系统-设置**，应能看到「微信键盘免跳转」入口；点进去有开关/滑块。
2. 任意 App 切到微信输入法，点**语音按钮**：直接在当前键盘开始录音，不跳主 app。
3. 外观：在面板里开「启用外观定制」，调圆角/大小/颜色/不透明度，呼出键盘即时生效。
4. 真机日志（frida / 爱思）：搜 `[WxKbNoJump] LOADED` 与 `INIT DONE`，确认已注入键盘扩展
   （`kbExt=1`）。

## 实现要点（与 TrollStore 注入版的区别）

- 改为 **rootless deb**：dylib 由 ElleKit/TweakInject 按 `Filter.plist` 注入，
  `com.tencent.wetype.keyboard`（键盘扩展，全局跑的进程）是必注目标；注主 app 无效。
- 设置面板改用 **PreferenceLoader + PreferenceBundle**，入口 `entry.plist` 的 `bundle` 字段 =
  `WxKbNoJumpPrefs`，与 `WxKbNoJumpPrefs.bundle` 目录名严格一致（不一致会静默无入口，即"坑C"）。
  面板控制器 `NSPrincipalClass` = `entry.plist` 的 `detail` 字段 = `WxKbNoJumpSettingsController`。
- 参考 yzdmm2024/MyGestures 记录的两个面板加载坑位：
  - **坑C（设置里没有入口）**：`entry.plist` 的 `bundle` 字段必须 = bundle 目录名（已对齐）。
  - **坑F（点开报"已损坏或丢失必要的资源"）**：bundle 必须是 **arm64e 切片**。本工具链的 lld 链接时
    会把 arm64e 对象的 cpusubtype 抹回 0x0(arm64)，故链接后用 `tools/fixup_macho.py --arm64e`
    强制写回 0x2（iPhone 12 Pro = A14 = arm64e）。dylib 同样处理。
  - **坑E（同上"已损坏"）**：bundle 必须正确链接 **Preferences/PreferenceUI** 框架。lld 解析不了本 SDK 的
    `.tbd` 桩，故链接后 `tools/fixup_macho.py --add-dylib` 向 Mach-O 注入
    Foundation/UIKit/PreferencesUI 的 `LC_LOAD_DYLIB`。
- 安装后 `postinst` 用设备端 `ldid -S` 对 bundle/dylib 重新签名（确保 relaxin 的 amfid 信任；
  找不到 ldid 则沿用本地 adhoc 签名）。
- 设置值写入 `com.wxkbd.nojump` 域，tweak 直接读
  `/var/mobile/Library/Preferences/com.wxkbd.nojump.plist`（每次重新读，跨进程即时生效）。

## 免跳转三层保险

1. `NSUserDefaults` hook 强制 `WBAppSettingsBool_VoiceInput_WcVoiceNoJump = YES`（App 原生免跳转逻辑生效）。
2. `WBFunctionToolBar` 语音按钮拦截：直接激活键盘内建语音输入。
3. `UIInputViewController` / `NSExtensionContext` / `UIApplication` 三处 `openURL` 拦截 +
   `UIViewController presentViewController:` 拦掉语音/权限设置页。

# 微信键盘免跳转 + 键盘外观定制 (WxKeyboardNoJump)

为 **微信输入法 (com.tencent.wetype, v3.5.3)** 做的 TrollStore 注入式插件。

- **全局语音免跳转**：呼出微信键盘点语音按钮，直接在微信内录音识别，不跳转到微信输入法主程序。
- **键盘外观定制**：圆角、大小(缩放)、背景色(RGB)、透明度，全部在设置面板里调。
- **设置面板**：系统-设置 → 微信输入法 →「微信键盘免跳转」分组（原生 Settings.bundle，无需 PreferenceLoader）。

## ⚠️ 适用环境（重要）

本机实测你的设备是 **TrollStore 环境**（relaxin 越狱 app + TrollFools / dylib插件库 注入），
**不是**传统 `/var/jb` substrate 越狱：

| 检查项 | 实测 |
|---|---|
| `/var/jb`、dpkg、PreferenceLoader、ElleKit | 均不存在 |
| `wxkb.app` 位置 | `/private/var/containers/Bundle/Application/<UUID>/wxkb.app` |
| 签名 | TrollStore 伪签（`_CodeSignature` 在、`embedded.mobileprovision` 不在 → AMFI 豁免，可注入 dylib） |
| 键盘扩展 | `wxkb.app/PlugIns/wxkb_plugin.appex` → `com.tencent.wetype.keyboard` |

因此本插件**不再用 deb**（旧 `WxKeyboardNoJump_v1.0.0_*.deb` 是给传统越狱的，请勿用）。
交付物是一个**零依赖 dylib**（不依赖 CydiaSubstrate / ElleKit，任意注入工具可加载）+ 一个 `Settings.bundle`。

## 交付物

```
WxKeyboardNoJump/
├── out/
│   ├── WxKeyboardNoJump.dylib   ← 注入用 dylib（已 adhoc 签名）
│   └── Settings.bundle/         ← 放进 wxkb.app，系统-设置里出面板
├── src/WxKeyboardNoJump.m       ← 源码（纯 ObjC，手动 swizzle）
├── Settings.bundle/             ← 面板源（Root.plist + 中文）
├── build.sh                     ← 本地 clang 交叉编译
└── DEBIAN/  preflist…           ← 旧 substrate 版残留（弃用）
tools/frida/                     ← 真机探测脚本（diag8/diag9 等）
logs/                            ← frida 实测日志
docs/                            ← IPA 静态分析
```

## 安装到 iPhone 12 Pro (iOS 16.6.1, relaxin)

### 1) 注入 dylib（用 TrollFools 或 dylib插件库）
- 打开 **TrollFools**（或你的 dylib插件库 app），选择 **微信输入法 (wxkb.app)**；
- 添加 dylib：`out/WxKeyboardNoJump.dylib`；
- 若工具支持注入扩展，对 **`wxkb_plugin.appex`（键盘扩展）** 也加同一 dylib
  （免跳转开关在键盘扩展里生效，建议两个都注入；只注入主程序也通常够用）。
- 工具会自动加 `LC_LOAD_DYLIB` 并重签。

### 2) 放入设置面板（用 Filza）
- 把 `out/Settings.bundle` 整个文件夹复制到
  `/private/var/containers/Bundle/Application/<UUID>/wxkb.app/Settings.bundle`
  （UUID 即装 wxkb.app 的那个目录，路径见上方实测）。
- 改完不需重签（Settings.bundle 是资源，TrollStore 的 CoreTrust 绕过覆盖整包）。

### 3) 生效
- 杀掉微信输入法主程序与键盘：设置里「注销」或 `killall -9 wxkb` / 直接重启。
- 打开微信，切到微信输入法，点语音按钮 → **应在微信内直接录音，不跳转**。
- 进 **系统-设置 → 微信输入法**，底部出现「微信键盘免跳转」分组，调开关/滑块，
  回微信重新呼出键盘即生效（外观默认值关闭，需打开「启用外观定制」）。

## 工作原理

1. **免跳转（双保险）**
   - hook `NSUserDefaults -objectForKey:/-boolForKey:`，对微信自带键
     `WBAppSettingsBool_VoiceInput_WcVoiceNoJump` 永远返回 YES（开启时）。
     该键即微信输入法自身的「微信语音免跳转」开关（二进制里还有字面
     `WtAppActionOpenVoiceNoRedirectionWechat` 等佐证）。
   - 额外 hook `UIApplication -openURL:`，吞掉 `wetype://` 的语音跳转 URL，兜底。
2. **外观定制**
   - hook `WBInputViewController -viewDidLayoutSubviews`，按设置套用
     圆角 / 缩放 / 背景色 / 透明度。
3. **偏好共享（关键）**
   - 主程序与键盘扩展数据容器不同，普通 NSUserDefaults 跨不过去。
   - `Settings.bundle` 把设置写进 `com.tencent.wetype`；注入主程序的 dylib 监听
     `com.apple.Preferences/changed`，实时镜像到全局文件
     `/var/mobile/Library/Preferences/com.user.wxkbdnojump.plist`；
     键盘扩展的 dylib 直接读该全局文件。免跳转默认开、外观默认关。

## 重新编译（改代码后）

本机已配好工具链（LLVM18 + iOS16 SDK，无需 WSL）：

```bash
cd WxKeyboardNoJump
bash build.sh
# 产物：out/WxKeyboardNoJump.dylib + out/Settings.bundle
```

## 排错

- **面板不出现**：确认 `Settings.bundle` 真的进了 `wxkb.app` 根目录（不是子目录），且 wxkb.app 是 TrollStore 装的。
- **免跳转不生效**：确认 dylib 注入进了 `wxkb_plugin.appex`（键盘扩展）；用 `frida -U -f com.tencent.wetype -l tools/frida/diag_panel.js` 看 load 日志 `[WxKeyboardNoJump] loaded`。
- **外观不生效**：打开「启用外观定制」；若改完没反应，杀一次 wxkb.app 让它重新把设置镜像到全局文件。

## 已知限制

- 微信输入法若改了免跳转键名，搜 `WcVoiceNoJump` / `NoRedirection` 重抓即可。
- 面板嵌套在「微信输入法」设置内（原生 Settings.bundle 行为），非独立顶级条目。

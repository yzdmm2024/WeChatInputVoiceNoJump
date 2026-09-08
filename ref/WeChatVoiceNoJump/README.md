# 微信输入法自用

微信输入法语音免跳转 - 点击语音按钮直接开始录音，不跳转设置页

## 功能

点击微信输入法键盘上的语音按钮时，**不会跳转到新页面**，直接在当前位置激活语音输入，保持原来的输入上下文。

## 安装

1. 下载最新 release 中的 `*.deb`
2. 在手机上用 Filza/Zebra/Sileo 安装
3. 重启 SpringBoard
4. 测试语音按钮点击

## 工作原理

- 拦截 `WBFunctionToolBar.handleItemClickEvent:func:controlEvent:`
- 检测 `func == 0x1` (语音功能)
- 直接调用 `setVoiceInputFocused:YES animated:NO completion:nil`，不触发默认跳转
- 微信输入法自身会处理语音录制和转文字，我们只负责拦截跳转

## 编译

GitHub Actions 会自动编译：
- 推送 tag `v*` 触发编译
- 或手动点击 `workflow_dispatch` 触发

## 作者

- 源码: 基于 Frida trace 定位 + Logos Hook
- 项目结构: Theos 标准工程

## License

MIT

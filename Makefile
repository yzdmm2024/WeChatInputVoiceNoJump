# 微信键盘免跳转 — Theos 工程 (rootless / ElleKit TweakInject)
# 本地构建: make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
# CI: 见 .github/workflows/build.yml（推荐，产出 arm64e deb）

TARGET := iphone:clang:16.5
# ARCHS = arm64 arm64e：arm64e 给设置进程（A14 REACH arm64e），arm64 给键盘扩展/主app（arm64 进程）。
# 注意：A14 上系统仅执行 arm64e 切片；窄化到 arm64e 也能工作，但保持双切片更稳。
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

# ===== Tweak: 语音免跳转（SpringBoard 注入，动画移除术） =====
TWEAK_NAME = WxKbNoJump
WxKbNoJump_FILES = Tweak.xm
WxKbNoJump_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-undeclared-selector
WxKbNoJump_FRAMEWORKS = UIKit Foundation
WxKbNoJump_INSTALL_PATH = /Library/TweakInject

include $(THEOS_MAKE_PATH)/tweak.mk

# ===== 设置面板 PreferenceBundle =====
BUNDLE_NAME = WxKbNoJumpPrefs
WxKbNoJumpPrefs_FILES = WxKbNoJumpPrefs/WxKbNoJumpSettingsController.m
WxKbNoJumpPrefs_INFOPLIST_FILE = WxKbNoJumpPrefs/Info.plist
# 注: Root.plist/Info.plist 通过 layout/ 直接打进 bundle（rootless 下 RESOURCES 不起效，否则面板空白）
WxKbNoJumpPrefs_INSTALL_PATH = /Library/PreferenceBundles
WxKbNoJumpPrefs_FRAMEWORKS = UIKit Foundation Preferences
WxKbNoJumpPrefs_PRIVATE_FRAMEWORKS = PreferencesUI
WxKbNoJumpPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
WxKbNoJumpPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk
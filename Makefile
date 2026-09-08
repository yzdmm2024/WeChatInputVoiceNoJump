# 微信键盘免跳转 — Theos 工程 (rootless / ElleKit TweakInject)
# 本地构建: make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
# CI: GitHub Actions 自动构建 (见 .github/workflows/build.yml)

TARGET := iphone:clang:16.5
# ARCHS: arm64e 设备的「设置」进程跑 arm64e（面板需要 arm64e 切片），
#        而被注入的键盘扩展/主 app 是 arm64 进程（tweak 需要 arm64 切片）——缺一不可
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

# ===== Tweak: 语音免跳转 + 键盘外观定制 =====
TWEAK_NAME = WxKbNoJump
WxKbNoJump_FILES = Tweak.xm
WxKbNoJump_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
WxKbNoJump_FRAMEWORKS = UIKit Foundation
WxKbNoJump_INSTALL_PATH = /Library/TweakInject

include $(THEOS_MAKE_PATH)/tweak.mk

# ===== 设置面板 PreferenceBundle =====
BUNDLE_NAME = WxKbNoJumpPrefs
WxKbNoJumpPrefs_FILES = WxKbNoJumpPrefs/WxKbNoJumpSettingsController.m
WxKbNoJumpPrefs_INFOPLIST_FILE = WxKbNoJumpPrefs/Info.plist
# 注: Root.plist/Info.plist 通过 layout/ 直接打进 bundle（RESOURCES 在 rootless 下未生效，会导致面板空白）
WxKbNoJumpPrefs_INSTALL_PATH = /Library/PreferenceBundles
WxKbNoJumpPrefs_FRAMEWORKS = UIKit Foundation Preferences
WxKbNoJumpPrefs_PRIVATE_FRAMEWORKS = PreferencesUI
WxKbNoJumpPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
WxKbNoJumpPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk

# 微信输入法自用 - 语音免跳转
TARGET := iphone:clang:16.5
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WeChatVoiceNoJump
WeChatVoiceNoJump_FILES = Tweak.xm
WeChatVoiceNoJump_CFLAGS = -fobjc-arc
WeChatVoiceNoJump_LDFLAGS += -lsubstrate
WeChatVoiceNoJump_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk

# ===== 设置面板 PreferenceBundle =====
BUNDLE_NAME = WeChatVoiceNoJumpPrefs
WeChatVoiceNoJumpPrefs_FILES = src/WeChatVoiceSettingsController.m
WeChatVoiceNoJumpPrefs_INSTALL_PATH = /Library/PreferenceBundles
WeChatVoiceNoJumpPrefs_FRAMEWORKS = UIKit Foundation
WeChatVoiceNoJumpPrefs_CFLAGS = -fobjc-arc
WeChatVoiceNoJumpPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup
include $(THEOS_MAKE_PATH)/bundle.mk

after-install::
	install.exec "killall -9 SpringBoard"
# 微信输入法自用 - 语音免跳转
TARGET := iphone:clang:16.5
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WeChatVoiceNoJump
WeChatVoiceNoJump_FILES = Tweak.xm
WeChatVoiceNoJump_CFLAGS = -fobjc-arc
WeChatVoiceNoJump_LDFLAGS += -lsubstrate
WeChatVoiceNoJump_INSTALL_PATH = /var/jb/Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 WeChat; killall -9 wxkb; killall -9 wxkb_plugin"
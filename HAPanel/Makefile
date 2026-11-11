TARGET := iphone:clang:10.3:8.0
ARCHS = armv7
INSTALL_TARGET_PROCESSES = HAPanel

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = HAPanel

HAPanel_FILES = main.m AppDelegate.m HAClient.m Cards.m Cards2.m Cards3.m Cards4.m Presence.m PanelViewController.m
HAPanel_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore AVFoundation CoreMedia CoreVideo CoreImage AudioToolbox
HAPanel_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/application.mk

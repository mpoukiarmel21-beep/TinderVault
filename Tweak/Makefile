ARCHS = arm64
TARGET = iphone:clang:latest:13.0

include $(THEOS)/makefiles/common.mk

# LIBRARY target (plain dylib), NOT a TWEAK target — a tweak.mk target
# auto-links CydiaSubstrate, which is absent on non-jailbroken (sideloaded)
# devices, so dyld would silently fail to load the dylib. All hooks here are
# fishhook (C symbols) + ObjC method_setImplementation, so no Substrate is
# needed. See docs/decisions/001-substrate-free.md.
LIBRARY_NAME = TinderVault

TinderVault_FILES = \
	Source/Bootstrap.m \
	Source/Core/IVPaths.m \
	Source/Core/IVContainer.m \
	Source/Core/IVContainerStore.m \
	Source/Isolation/IVHomeRedirect.m \
	Source/Isolation/IVKeychainHook.m \
	Source/Isolation/IVPrefsHook.m \
	Source/Isolation/IVAntiTamper.m \
	Source/Spoof/IVDeviceSpoof.m \
	Source/Spoof/IVDeviceIdentity.m \
	Source/Spoof/IVLocaleSpoof.m \
	Source/Spoof/IVLocationSpoof.m \
	Source/UI/IVTheme.m \
	Source/UI/IVGlass.m \
	Source/UI/IVActionSheet.m \
	Source/UI/IVFloatingButton.m \
	Source/UI/IVListPickerVC.m \
	Source/UI/IVPanelVC.m \
	Source/UI/IVCreateVC.m \
	Source/UI/IVMapPickerVC.m \
	Source/Util/IVDiagnostics.m \
	Source/vendor/fishhook/fishhook.c

# Every subdir on the header search path so both root-relative and bare
# imports resolve regardless of the importing file's location.
TinderVault_CFLAGS = -fobjc-arc \
	-ISource -ISource/Core -ISource/Isolation -ISource/Spoof \
	-ISource/UI -ISource/Util -ISource/vendor \
	-Wno-deprecated-declarations -Wno-unused-variable \
	-Wno-error=unguarded-availability-new

TinderVault_FRAMEWORKS = UIKit CoreLocation MapKit Security

# Diagnostic: `make TV_INERT=1` builds an inert dylib (injected + loaded but no
# hooks) to isolate a launch crash. CI exposes this as the `inert` workflow
# input. See the TINDERVAULT_INERT guard in Source/Bootstrap.m.
ifeq ($(TV_INERT),1)
TinderVault_CFLAGS += -DTINDERVAULT_INERT=1
endif

include $(THEOS_MAKE_PATH)/library.mk

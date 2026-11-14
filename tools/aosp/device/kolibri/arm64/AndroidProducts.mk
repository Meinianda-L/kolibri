# Kolibri's Android image: AOSP 12L for the Android Emulator's arm64 virtual hardware.
PRODUCT_MAKEFILES := $(LOCAL_DIR)/kolibri_arm64.mk
# userdebug only: init/kolibri.rc runs in the su domain and kolibrictl relies on adb root.
COMMON_LUNCH_CHOICES := kolibri_arm64-userdebug

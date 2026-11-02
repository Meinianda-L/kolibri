# The 64-bit-only arm64 emulator product (device/generic/goldfish/64bitonly/product/
# sdk_phone64_arm64.mk), with Kolibri's slim product partition instead of aosp_product.mk
# and without the SDK add-on extras.
QEMU_USE_SYSTEM_EXT_PARTITIONS := true
PRODUCT_USE_DYNAMIC_PARTITIONS := true
PRODUCT_ENFORCE_ARTIFACT_PATH_REQUIREMENTS := relaxed

$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/generic_system.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/handheld_system_ext.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/telephony_system_ext.mk)
$(call inherit-product, device/kolibri/arm64/kolibri_product.mk)

PRODUCT_SDK_ADDON_SYS_IMG_SOURCE_PROP := \
    development/sys-img/images_arm64-v8a_source.prop_template
$(call inherit-product, device/generic/goldfish/arm64-vendor.mk)
$(call inherit-product, device/generic/goldfish/64bitonly/product/emulator64_vendor.mk)
$(call inherit-product, device/generic/goldfish/emulator64_arm64/device.mk)

PRODUCT_BRAND := Kolibri
PRODUCT_NAME := kolibri_arm64
PRODUCT_DEVICE := emulator64_arm64
PRODUCT_MODEL := Kolibri

# Product partition for a gaming phone: AOSP's handheld product minus the apps games never
# use (messaging, calendar, camera, contacts, clock, gallery, music, search, dialer, photo
# screensaver, wallpaper picker, soft keyboard: the Mac keyboard types directly).
$(call inherit-product, $(SRC_TARGET_DIR)/product/media_product.mk)

PRODUCT_PACKAGES += \
    Browser2 \
    SettingsIntelligence \
    frameworks-base-overlays \
    preinstalled-packages-platform-handheld-product.xml

PRODUCT_PACKAGES_DEBUG += \
    frameworks-base-overlays-debug

PRODUCT_PRODUCT_PROPERTIES += \
    ro.com.android.dataroaming?=true \
    qemu.hw.mainkeys=1 \
    ro.config.low_ram=false \
    persist.sys.locale=zh-CN \
    persist.sys.timezone=Asia/Shanghai

PRODUCT_COPY_FILES += \
    device/sample/etc/apns-full-conf.xml:$(TARGET_COPY_OUT_PRODUCT)/etc/apns-conf.xml

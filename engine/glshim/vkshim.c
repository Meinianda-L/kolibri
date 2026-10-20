// Kolibri Vulkan ICD shim in front of the engine's MoltenVK.
//
// Games pick quality and frame-rate tiers by GPU name. With GuestAngle the name a
// game sees (GL_RENDERER and Vulkan deviceName) comes from the host Vulkan device, so
// this ICD forwards everything to MoltenVK (libMoltenVK.dylib in the same directory)
// and only rewrites VkPhysicalDeviceProperties.deviceName to $KOLIBRI_GPU_RENDERER.
// Vendor/device IDs and driver info are left alone so no vendor workarounds kick in.

#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void (*PFN)(void);
typedef void* VkInstance;
typedef void* VkPhysicalDevice;
typedef int32_t VkResult;

// VkPhysicalDeviceProperties: apiVersion, driverVersion, vendorID, deviceID, deviceType, deviceName[256]...
#define DEVICE_NAME_OFFSET 20
#define DEVICE_NAME_SIZE 256
// VkPhysicalDeviceProperties2: sType, (pad), pNext, then VkPhysicalDeviceProperties.
#define PROPS2_PROPERTIES_OFFSET 16

static void* mvk(void) {
    static void* h;
    if (!h) {
        Dl_info info;
        dladdr((void*)mvk, &info);
        char path[4096];
        snprintf(path, sizeof path, "%s", info.dli_fname);
        char* slash = strrchr(path, '/');
        if (slash) snprintf(slash + 1, sizeof path - (size_t)(slash + 1 - path), "libMoltenVK.dylib");
        h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    }
    return h;
}

static void rename_device(char* name) {
    const char* r = getenv("KOLIBRI_GPU_RENDERER");
    if (r && *r) snprintf(name, DEVICE_NAME_SIZE, "%s", r);
}

static void (*real_props)(VkPhysicalDevice, void*);
static void (*real_props2)(VkPhysicalDevice, void*);
static void (*real_props2khr)(VkPhysicalDevice, void*);

static void kolibri_props(VkPhysicalDevice d, void* p) {
    real_props(d, p);
    rename_device((char*)p + DEVICE_NAME_OFFSET);
}

static void kolibri_props2(VkPhysicalDevice d, void* p) {
    real_props2(d, p);
    rename_device((char*)p + PROPS2_PROPERTIES_OFFSET + DEVICE_NAME_OFFSET);
}

static void kolibri_props2khr(VkPhysicalDevice d, void* p) {
    real_props2khr(d, p);
    rename_device((char*)p + PROPS2_PROPERTIES_OFFSET + DEVICE_NAME_OFFSET);
}

// Replace the three property queries; anything else is MoltenVK's own.
static PFN wrap(const char* name, PFN real) {
    if (!real || !name) return real;
    if (!strcmp(name, "vkGetPhysicalDeviceProperties")) {
        real_props = (void (*)(VkPhysicalDevice, void*))real;
        return (PFN)kolibri_props;
    }
    if (!strcmp(name, "vkGetPhysicalDeviceProperties2")) {
        real_props2 = (void (*)(VkPhysicalDevice, void*))real;
        return (PFN)kolibri_props2;
    }
    if (!strcmp(name, "vkGetPhysicalDeviceProperties2KHR")) {
        real_props2khr = (void (*)(VkPhysicalDevice, void*))real;
        return (PFN)kolibri_props2khr;
    }
    return real;
}

__attribute__((visibility("default"))) VkResult vk_icdNegotiateLoaderICDInterfaceVersion(uint32_t* version) {
    VkResult (*f)(uint32_t*) = (VkResult(*)(uint32_t*))dlsym(mvk(), "vk_icdNegotiateLoaderICDInterfaceVersion");
    return f ? f(version) : -3;  // VK_ERROR_INITIALIZATION_FAILED
}

__attribute__((visibility("default"))) PFN vk_icdGetInstanceProcAddr(VkInstance instance, const char* name) {
    static PFN (*f)(VkInstance, const char*);
    if (!f) f = (PFN(*)(VkInstance, const char*))dlsym(mvk(), "vk_icdGetInstanceProcAddr");
    return f ? wrap(name, f(instance, name)) : NULL;
}

__attribute__((visibility("default"))) PFN vk_icdGetPhysicalDeviceProcAddr(VkInstance instance, const char* name) {
    static PFN (*f)(VkInstance, const char*);
    if (!f) f = (PFN(*)(VkInstance, const char*))dlsym(mvk(), "vk_icdGetPhysicalDeviceProcAddr");
    return f ? wrap(name, f(instance, name)) : NULL;
}

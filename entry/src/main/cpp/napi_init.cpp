#include "screen_recorder_native.h"

#include <hilog/log.h>

#define LOG_DOMAIN 0x3200
#define LOG_TAG "NativeRecorder"

extern "C" __attribute__((constructor)) void OnNapiInitLibraryLoad()
{
    OH_LOG_INFO(LOG_APP, "[NativeRecorder]napi_init.cpp constructor invoked");
}

extern "C" NAPI_MODULE_EXPORT napi_value napi_register_module_v1(napi_env env, napi_value exports)
{
    OH_LOG_INFO(LOG_APP, "[NativeRecorder]napi_register_module_v1 invoked");
    return InitScreenRecorderModule(env, exports);
}

NAPI_MODULE(entry, napi_register_module_v1)

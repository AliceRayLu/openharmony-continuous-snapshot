#include "screen_recorder_native.h"

#include <hilog/log.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3200
#define LOG_TAG "NativeRecorder"

__attribute__((constructor)) void OnNapiInitLibraryLoad(void)
{
    OH_LOG_INFO(LOG_APP, "[NativeRecorder]napi_init.c constructor invoked");
}

NAPI_MODULE_EXPORT napi_value napi_register_module_v1(napi_env env, napi_value exports)
{
    OH_LOG_INFO(LOG_APP, "[NativeRecorder]napi_register_module_v1 invoked");
    return InitScreenRecorderModule(env, exports);
}

NAPI_MODULE(entry, napi_register_module_v1)

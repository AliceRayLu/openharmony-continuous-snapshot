#include "screen_recorder_native.h"

#include <hilog/log.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3200
#define LOG_TAG "NativeRecorder"

static napi_value GetVersion(napi_env env, napi_callback_info info)
{
    (void)info;
    OH_LOG_INFO(LOG_APP, "[NativeRecorder]GetVersion invoked");

    napi_value version = NULL;
    napi_create_string_utf8(env, "screen_recorder_native_minimal_v1", NAPI_AUTO_LENGTH, &version);
    return version;
}

napi_value InitScreenRecorderModule(napi_env env, napi_value exports)
{
    OH_LOG_INFO(LOG_APP, "[NativeRecorder]InitScreenRecorderModule invoked");

    napi_property_descriptor descriptors[] = {
        { "getVersion", NULL, GetVersion, NULL, NULL, NULL, napi_default, NULL },
    };

    napi_define_properties(env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors);
    return exports;
}

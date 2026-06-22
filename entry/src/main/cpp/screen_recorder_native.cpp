#include "screen_recorder_native.h"

#include <hilog/log.h>
#include <multimedia/player_framework/native_avscreen_capture.h>
#include <multimedia/player_framework/native_avscreen_capture_base.h>
#include <multimedia/player_framework/native_avscreen_capture_errors.h>

#include <cstring>
#include <inttypes.h>
#include <map>
#include <memory>
#include <string>
#include <time.h>
#include <utility>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3200
#define LOG_TAG "NativeRecorder"

namespace {

struct RecorderSession {
    uint32_t id = 0;
    std::string outputPath;
    int32_t width = 0;
    int32_t height = 0;
    int32_t frameRate = 0;
    int32_t videoBitrate = 0;
    std::string preset;
    bool micEnabled = false;
    bool started = false;
    bool released = false;
    bool hasVideo = false;
    int64_t startMonotonicMs = 0;
    int64_t stopMonotonicMs = 0;
    int32_t lastErrorCode = AV_SCREEN_CAPTURE_ERR_OK;
    std::string lastErrorMessage;
    std::unique_ptr<char[]> outputPathStorage;
    OH_AVScreenCapture *capture = nullptr;
};

std::map<uint32_t, RecorderSession> g_sessions;
uint32_t g_nextSessionId = 1;

int64_t GetMonotonicMs()
{
    struct timespec ts {};
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<int64_t>(ts.tv_sec) * 1000 + static_cast<int64_t>(ts.tv_nsec / 1000000);
}

napi_value CreateError(napi_env env, const char *code, const std::string &message)
{
    napi_value codeValue = nullptr;
    napi_value messageValue = nullptr;
    napi_create_string_utf8(env, code, NAPI_AUTO_LENGTH, &codeValue);
    napi_create_string_utf8(env, message.c_str(), NAPI_AUTO_LENGTH, &messageValue);

    napi_value error = nullptr;
    napi_create_error(env, codeValue, messageValue, &error);
    return error;
}

napi_value ResolveImmediatePromise(napi_env env, napi_value value)
{
    napi_deferred deferred = nullptr;
    napi_value promise = nullptr;
    napi_create_promise(env, &deferred, &promise);
    napi_resolve_deferred(env, deferred, value);
    return promise;
}

napi_value RejectImmediatePromise(napi_env env, napi_value error)
{
    napi_deferred deferred = nullptr;
    napi_value promise = nullptr;
    napi_create_promise(env, &deferred, &promise);
    napi_reject_deferred(env, deferred, error);
    return promise;
}

bool GetNamedString(napi_env env, napi_value object, const char *key, std::string &out)
{
    napi_value value = nullptr;
    bool hasProperty = false;
    napi_has_named_property(env, object, key, &hasProperty);
    if (!hasProperty) {
        return false;
    }
    napi_get_named_property(env, object, key, &value);

    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) {
        return false;
    }

    std::string result(length, '\0');
    if (napi_get_value_string_utf8(env, value, result.data(), length + 1, &length) != napi_ok) {
        return false;
    }

    out = result;
    return true;
}

bool GetNamedInt32(napi_env env, napi_value object, const char *key, int32_t &out)
{
    napi_value value = nullptr;
    bool hasProperty = false;
    napi_has_named_property(env, object, key, &hasProperty);
    if (!hasProperty) {
        return false;
    }
    napi_get_named_property(env, object, key, &value);
    return napi_get_value_int32(env, value, &out) == napi_ok;
}

bool GetNamedBool(napi_env env, napi_value object, const char *key, bool &out)
{
    napi_value value = nullptr;
    bool hasProperty = false;
    napi_has_named_property(env, object, key, &hasProperty);
    if (!hasProperty) {
        return false;
    }
    napi_get_named_property(env, object, key, &value);
    return napi_get_value_bool(env, value, &out) == napi_ok;
}

std::string ErrorCodeToName(int32_t code)
{
    switch (code) {
        case AV_SCREEN_CAPTURE_ERR_OK:
            return "AV_SCREEN_CAPTURE_ERR_OK";
        case AV_SCREEN_CAPTURE_ERR_NO_MEMORY:
            return "AV_SCREEN_CAPTURE_ERR_NO_MEMORY";
        case AV_SCREEN_CAPTURE_ERR_OPERATE_NOT_PERMIT:
            return "AV_SCREEN_CAPTURE_ERR_OPERATE_NOT_PERMIT";
        case AV_SCREEN_CAPTURE_ERR_INVALID_VAL:
            return "AV_SCREEN_CAPTURE_ERR_INVALID_VAL";
        case AV_SCREEN_CAPTURE_ERR_IO:
            return "AV_SCREEN_CAPTURE_ERR_IO";
        case AV_SCREEN_CAPTURE_ERR_TIMEOUT:
            return "AV_SCREEN_CAPTURE_ERR_TIMEOUT";
        case AV_SCREEN_CAPTURE_ERR_UNKNOWN:
            return "AV_SCREEN_CAPTURE_ERR_UNKNOWN";
        case AV_SCREEN_CAPTURE_ERR_SERVICE_DIED:
            return "AV_SCREEN_CAPTURE_ERR_SERVICE_DIED";
        case AV_SCREEN_CAPTURE_ERR_INVALID_STATE:
            return "AV_SCREEN_CAPTURE_ERR_INVALID_STATE";
        case AV_SCREEN_CAPTURE_ERR_UNSUPPORT:
            return "AV_SCREEN_CAPTURE_ERR_UNSUPPORT";
        default:
            return "AV_SCREEN_CAPTURE_ERR_UNRECOGNIZED";
    }
}

std::string FormatScreenCaptureError(const std::string &action, int32_t code)
{
    return action + " failed: code=" + std::to_string(code) + " (" + ErrorCodeToName(code) + ")";
}

void SetSessionError(RecorderSession &session, int32_t code, const std::string &message)
{
    session.lastErrorCode = code;
    session.lastErrorMessage = message;
}

void OnNativeStateChange(OH_AVScreenCapture *capture, OH_AVScreenCaptureStateCode stateCode, void *userData)
{
    (void)capture;
    auto *session = static_cast<RecorderSession *>(userData);
    if (!session) {
        return;
    }

    OH_LOG_INFO(LOG_APP, "[NativeRecorder]state changed session=%{public}u state=%{public}d",
        session->id, static_cast<int32_t>(stateCode));

    switch (stateCode) {
        case OH_SCREEN_CAPTURE_STATE_STARTED:
            session->started = true;
            break;
        case OH_SCREEN_CAPTURE_STATE_STOPPED_BY_USER:
        case OH_SCREEN_CAPTURE_STATE_CANCELED:
        case OH_SCREEN_CAPTURE_STATE_INTERRUPTED_BY_OTHER:
        case OH_SCREEN_CAPTURE_STATE_STOPPED_BY_CALL:
        case OH_SCREEN_CAPTURE_STATE_STOPPED_BY_USER_SWITCHES:
            if (session->stopMonotonicMs <= 0) {
                session->stopMonotonicMs = GetMonotonicMs();
            }
            break;
        default:
            break;
    }
}

void OnNativeError(OH_AVScreenCapture *capture, int32_t errorCode, void *userData)
{
    (void)capture;
    auto *session = static_cast<RecorderSession *>(userData);
    if (!session) {
        return;
    }

    const std::string message = FormatScreenCaptureError("screen capture runtime error", errorCode);
    SetSessionError(*session, errorCode, message);
    OH_LOG_ERROR(LOG_APP, "[NativeRecorder]%{public}s, session=%{public}u", message.c_str(), session->id);
}

OH_VideoCodecFormat ToVideoCodec(const std::string &preset)
{
    return preset == "H265" ? OH_H265 : OH_H264;
}

napi_value GetVersion(napi_env env, napi_callback_info info)
{
    (void)info;
    OH_LOG_INFO(LOG_APP, "[NativeRecorder]GetVersion invoked");

    napi_value version = nullptr;
    napi_create_string_utf8(env, "screen_recorder_native_avscreen_capture_v1", NAPI_AUTO_LENGTH, &version);
    return version;
}

napi_value CreateRecorder(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return RejectImmediatePromise(env, CreateError(env, "ERR_INVALID_ARG", "createRecorder requires an options object"));
    }

    RecorderSession session {};
    session.id = g_nextSessionId++;

    GetNamedString(env, args[0], "outputPath", session.outputPath);
    GetNamedInt32(env, args[0], "width", session.width);
    GetNamedInt32(env, args[0], "height", session.height);
    GetNamedInt32(env, args[0], "frameRate", session.frameRate);
    GetNamedInt32(env, args[0], "videoBitrate", session.videoBitrate);
    GetNamedString(env, args[0], "preset", session.preset);
    GetNamedBool(env, args[0], "micEnabled", session.micEnabled);

    if (session.outputPath.empty()) {
        return RejectImmediatePromise(env, CreateError(env, "ERR_INVALID_ARG", "createRecorder requires outputPath"));
    }

    if (session.width <= 0 || session.height <= 0) {
        return RejectImmediatePromise(env, CreateError(env, "ERR_INVALID_ARG", "createRecorder requires positive width and height"));
    }

    if (session.frameRate <= 0) {
        session.frameRate = 60;
    }
    if (session.videoBitrate <= 0) {
        session.videoBitrate = 8 * 1000 * 1000;
    }

    session.capture = OH_AVScreenCapture_Create();
    if (!session.capture) {
        const std::string message = "OH_AVScreenCapture_Create returned null";
        return RejectImmediatePromise(env, CreateError(env, "ERR_NATIVE_CREATE", message));
    }

    const auto pathLen = session.outputPath.size();
    session.outputPathStorage = std::make_unique<char[]>(pathLen + 1);
    std::memcpy(session.outputPathStorage.get(), session.outputPath.c_str(), pathLen + 1);

    OH_AVScreenCaptureConfig config {};
    config.captureMode = OH_CAPTURE_HOME_SCREEN;
    config.dataType = OH_CAPTURE_FILE;

    config.audioInfo.micCapInfo.audioSampleRate = 48000;
    config.audioInfo.micCapInfo.audioChannels = 2;
    config.audioInfo.micCapInfo.audioSource = OH_MIC;
    config.audioInfo.innerCapInfo.audioSampleRate = 48000;
    config.audioInfo.innerCapInfo.audioChannels = 2;
    config.audioInfo.innerCapInfo.audioSource = OH_ALL_PLAYBACK;
    config.audioInfo.audioEncInfo.audioBitrate = 128000;
    config.audioInfo.audioEncInfo.audioCodecformat = OH_AAC_LC;

    config.videoInfo.videoCapInfo.displayId = 0;
    config.videoInfo.videoCapInfo.missionIDs = nullptr;
    config.videoInfo.videoCapInfo.missionIDsLen = 0;
    config.videoInfo.videoCapInfo.videoFrameWidth = session.width;
    config.videoInfo.videoCapInfo.videoFrameHeight = session.height;
    config.videoInfo.videoCapInfo.videoSource = OH_VIDEO_SOURCE_SURFACE_YUV;
    config.videoInfo.videoEncInfo.videoCodec = ToVideoCodec(session.preset);
    config.videoInfo.videoEncInfo.videoBitrate = session.videoBitrate;
    config.videoInfo.videoEncInfo.videoFrameRate = session.frameRate;

    config.recorderInfo.url = session.outputPathStorage.get();
    config.recorderInfo.urlLen = static_cast<uint32_t>(pathLen);
    config.recorderInfo.fileFormat = CFT_MPEG_4;

    const auto initCode = OH_AVScreenCapture_Init(session.capture, config);
    if (initCode != AV_SCREEN_CAPTURE_ERR_OK) {
        const std::string message = FormatScreenCaptureError("OH_AVScreenCapture_Init", initCode);
        OH_AVScreenCapture_Release(session.capture);
        return RejectImmediatePromise(env, CreateError(env, "ERR_NATIVE_INIT", message));
    }

    const auto micCode = OH_AVScreenCapture_SetMicrophoneEnabled(session.capture, session.micEnabled);
    if (micCode != AV_SCREEN_CAPTURE_ERR_OK) {
        const std::string message = FormatScreenCaptureError("OH_AVScreenCapture_SetMicrophoneEnabled", micCode);
        OH_AVScreenCapture_Release(session.capture);
        return RejectImmediatePromise(env, CreateError(env, "ERR_NATIVE_INIT", message));
    }

    SetSessionError(session, AV_SCREEN_CAPTURE_ERR_OK, "");
    auto insertResult = g_sessions.emplace(session.id, std::move(session));
    RecorderSession &stored = insertResult.first->second;

    const auto stateCode = OH_AVScreenCapture_SetStateCallback(stored.capture, OnNativeStateChange, &stored);
    if (stateCode != AV_SCREEN_CAPTURE_ERR_OK) {
        const std::string message = FormatScreenCaptureError("OH_AVScreenCapture_SetStateCallback", stateCode);
        OH_AVScreenCapture_Release(stored.capture);
        g_sessions.erase(stored.id);
        return RejectImmediatePromise(env, CreateError(env, "ERR_NATIVE_INIT", message));
    }

    const auto errorCode = OH_AVScreenCapture_SetErrorCallback(stored.capture, OnNativeError, &stored);
    if (errorCode != AV_SCREEN_CAPTURE_ERR_OK) {
        const std::string message = FormatScreenCaptureError("OH_AVScreenCapture_SetErrorCallback", errorCode);
        OH_AVScreenCapture_Release(stored.capture);
        g_sessions.erase(stored.id);
        return RejectImmediatePromise(env, CreateError(env, "ERR_NATIVE_INIT", message));
    }

    OH_LOG_INFO(LOG_APP,
        "[NativeRecorder]createRecorder session=%{public}u width=%{public}d height=%{public}d fps=%{public}d bitrate=%{public}d preset=%{public}s mic=%{public}d path=%{public}s",
        stored.id, stored.width, stored.height, stored.frameRate, stored.videoBitrate,
        stored.preset.c_str(), stored.micEnabled ? 1 : 0, stored.outputPath.c_str());

    napi_value result = nullptr;
    napi_create_object(env, &result);

    napi_value idValue = nullptr;
    napi_create_uint32(env, stored.id, &idValue);
    napi_set_named_property(env, result, "recorderId", idValue);

    return ResolveImmediatePromise(env, result);
}

napi_value StartRecorder(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    uint32_t recorderId = 0;
    if (argc < 1 || napi_get_value_uint32(env, args[0], &recorderId) != napi_ok) {
        return RejectImmediatePromise(env, CreateError(env, "ERR_INVALID_ARG", "startRecorder requires a recorder id"));
    }

    auto it = g_sessions.find(recorderId);
    if (it == g_sessions.end()) {
        return RejectImmediatePromise(env, CreateError(env, "ERR_NOT_FOUND", "Recorder session was not found"));
    }

    RecorderSession &session = it->second;
    const auto startCode = OH_AVScreenCapture_StartScreenRecording(session.capture);
    if (startCode != AV_SCREEN_CAPTURE_ERR_OK) {
        const std::string message = FormatScreenCaptureError("OH_AVScreenCapture_StartScreenRecording", startCode);
        SetSessionError(session, startCode, message);
        return RejectImmediatePromise(env, CreateError(env, "ERR_NATIVE_START", message));
    }

    session.started = true;
    session.startMonotonicMs = GetMonotonicMs();
    session.stopMonotonicMs = 0;
    SetSessionError(session, AV_SCREEN_CAPTURE_ERR_OK, "");

    OH_LOG_INFO(LOG_APP, "[NativeRecorder]startRecorder session=%{public}u", recorderId);

    napi_value result = nullptr;
    napi_get_undefined(env, &result);
    return ResolveImmediatePromise(env, result);
}

napi_value StopRecorder(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    uint32_t recorderId = 0;
    if (argc < 1 || napi_get_value_uint32(env, args[0], &recorderId) != napi_ok) {
        return RejectImmediatePromise(env, CreateError(env, "ERR_INVALID_ARG", "stopRecorder requires a recorder id"));
    }

    auto it = g_sessions.find(recorderId);
    if (it == g_sessions.end()) {
        return RejectImmediatePromise(env, CreateError(env, "ERR_NOT_FOUND", "Recorder session was not found"));
    }

    RecorderSession &session = it->second;
    if (session.started) {
        const auto stopCode = OH_AVScreenCapture_StopScreenRecording(session.capture);
        if (stopCode != AV_SCREEN_CAPTURE_ERR_OK) {
            const std::string message = FormatScreenCaptureError("OH_AVScreenCapture_StopScreenRecording", stopCode);
            SetSessionError(session, stopCode, message);
            return RejectImmediatePromise(env, CreateError(env, "ERR_NATIVE_STOP", message));
        }
    }

    session.stopMonotonicMs = GetMonotonicMs();
    session.started = false;
    session.hasVideo = true;

    const int64_t durationMs = session.startMonotonicMs > 0 && session.stopMonotonicMs >= session.startMonotonicMs
        ? session.stopMonotonicMs - session.startMonotonicMs
        : 0;

    napi_value result = nullptr;
    napi_create_object(env, &result);

    napi_value pathValue = nullptr;
    napi_create_string_utf8(env, session.outputPath.c_str(), NAPI_AUTO_LENGTH, &pathValue);
    napi_set_named_property(env, result, "outputPath", pathValue);

    napi_value durationValue = nullptr;
    napi_create_int64(env, durationMs, &durationValue);
    napi_set_named_property(env, result, "durationMs", durationValue);

    napi_value hasVideoValue = nullptr;
    napi_get_boolean(env, session.hasVideo, &hasVideoValue);
    napi_set_named_property(env, result, "hasVideo", hasVideoValue);

    napi_value widthValue = nullptr;
    napi_create_int32(env, session.width, &widthValue);
    napi_set_named_property(env, result, "frameWidth", widthValue);

    napi_value heightValue = nullptr;
    napi_create_int32(env, session.height, &heightValue);
    napi_set_named_property(env, result, "frameHeight", heightValue);

    napi_value errorValue = nullptr;
    napi_create_string_utf8(env, session.lastErrorMessage.c_str(), NAPI_AUTO_LENGTH, &errorValue);
    napi_set_named_property(env, result, "errorMessage", errorValue);

    OH_LOG_INFO(LOG_APP, "[NativeRecorder]stopRecorder session=%{public}u durationMs=%{public}" PRId64,
        recorderId, durationMs);
    return ResolveImmediatePromise(env, result);
}

napi_value ReleaseRecorder(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    uint32_t recorderId = 0;
    if (argc >= 1 && napi_get_value_uint32(env, args[0], &recorderId) == napi_ok) {
        auto it = g_sessions.find(recorderId);
        if (it != g_sessions.end()) {
            if (it->second.capture) {
                const auto releaseCode = OH_AVScreenCapture_Release(it->second.capture);
                if (releaseCode != AV_SCREEN_CAPTURE_ERR_OK) {
                    OH_LOG_WARN(LOG_APP, "[NativeRecorder]OH_AVScreenCapture_Release failed session=%{public}u code=%{public}d",
                        recorderId, static_cast<int32_t>(releaseCode));
                }
                it->second.capture = nullptr;
            }
            g_sessions.erase(it);
            OH_LOG_INFO(LOG_APP, "[NativeRecorder]releaseRecorder session=%{public}u", recorderId);
        }
    }

    napi_value result = nullptr;
    napi_get_undefined(env, &result);
    return result;
}

} // namespace

napi_value InitScreenRecorderModule(napi_env env, napi_value exports)
{
    OH_LOG_INFO(LOG_APP, "[NativeRecorder]InitScreenRecorderModule invoked");

    napi_property_descriptor descriptors[] = {
        { "getVersion", nullptr, GetVersion, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "createRecorder", nullptr, CreateRecorder, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "startRecorder", nullptr, StartRecorder, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "stopRecorder", nullptr, StopRecorder, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "releaseRecorder", nullptr, ReleaseRecorder, nullptr, nullptr, nullptr, napi_default, nullptr },
    };

    napi_define_properties(env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors);
    return exports;
}

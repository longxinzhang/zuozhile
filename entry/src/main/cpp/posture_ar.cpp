#include <napi/native_api.h>
#include <ar/ar_engine_core.h>
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#include "yuv_image.h"
#include "lip_gap.h"

namespace {
std::mutex sessionMutex;
AREngine_ARSession* session = nullptr;
int64_t lastTimestamp = 0;
bool capturing = false;
EGLDisplay glDisplay = EGL_NO_DISPLAY;
EGLContext glContext = EGL_NO_CONTEXT;
EGLSurface glSurface = EGL_NO_SURFACE;
GLuint cameraTexture = 0;

void DestroyGL() {
    // The default display is shared with ArkUI; do not terminate it.
    if (glContext != EGL_NO_CONTEXT) eglDestroyContext(glDisplay, glContext);
    if (glSurface != EGL_NO_SURFACE) eglDestroySurface(glDisplay, glSurface);
    glContext = EGL_NO_CONTEXT;
    glSurface = EGL_NO_SURFACE;
    cameraTexture = 0;
}

class ScopedGL {
    EGLDisplay previousDisplay = eglGetCurrentDisplay();
    EGLContext previousContext = eglGetCurrentContext();
    EGLSurface previousDraw = eglGetCurrentSurface(EGL_DRAW);
    EGLSurface previousRead = eglGetCurrentSurface(EGL_READ);
public:
    ScopedGL() {
        if (glContext == EGL_NO_CONTEXT) {
            glDisplay = eglGetDisplay(EGL_DEFAULT_DISPLAY);
            EGLint major, minor, count;
            EGLConfig config;
            const EGLint attributes[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
                EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
                EGL_BLUE_SIZE, 8, EGL_NONE};
            const EGLint contextAttrs[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
            const EGLint surfaceAttrs[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
            if (glDisplay == EGL_NO_DISPLAY || !eglInitialize(glDisplay, &major, &minor) ||
                !eglChooseConfig(glDisplay, attributes, &config, 1, &count) || count < 1)
                throw std::runtime_error("Cannot initialize camera GL bridge");
            glContext = eglCreateContext(glDisplay, config, EGL_NO_CONTEXT, contextAttrs);
            glSurface = eglCreatePbufferSurface(glDisplay, config, surfaceAttrs);
            if (glContext == EGL_NO_CONTEXT || glSurface == EGL_NO_SURFACE) {
                DestroyGL();
                throw std::runtime_error("Cannot create camera GL bridge");
            }
        }
        if (!eglMakeCurrent(glDisplay, glSurface, glSurface, glContext))
            throw std::runtime_error("Cannot bind camera GL bridge");
        if (!cameraTexture) {
            glGenTextures(1, &cameraTexture);
            glBindTexture(GL_TEXTURE_EXTERNAL_OES, cameraTexture);
            glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        }
    }
    ~ScopedGL() {
        if (previousDisplay != EGL_NO_DISPLAY) {
            eglMakeCurrent(previousDisplay, previousDraw, previousRead, previousContext);
        } else {
            eglMakeCurrent(glDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        }
    }
};

void Check(AREngine_ARStatus code, const char* operation) {
    if (code != ARENGINE_SUCCESS) {
        throw std::runtime_error(std::string(operation) + ": " + std::to_string(code));
    }
}

void Close() {
    if (session) {
        HMS_AREngine_ARSession_Stop(session);
        HMS_AREngine_ARSession_Destroy(session);
        session = nullptr;
    }
    lastTimestamp = 0;
    DestroyGL();
}

napi_value Undefined(napi_env env) {
    napi_value value;
    napi_get_undefined(env, &value);
    return value;
}

napi_value Start(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc != 1) {
        napi_throw_error(env, nullptr, "Application context required");
        return nullptr;
    }
    std::lock_guard<std::mutex> lock(sessionMutex);
    if (session || capturing) {
        napi_throw_error(env, nullptr, "AR session already started");
        return nullptr;
    }
    try {
        Check(HMS_AREngine_ARSession_Create_Human_Perception(env, args[0], &session), "create face session");
        AREngine_ARConfig* raw = nullptr;
        Check(HMS_AREngine_ARConfig_Create(session, &raw), "create config");
        std::unique_ptr<AREngine_ARConfig, decltype(&HMS_AREngine_ARConfig_Destroy)>
            config(raw, HMS_AREngine_ARConfig_Destroy);
        Check(HMS_AREngine_ARConfig_SetARType(session, raw, ARENGINE_TYPE_FACE), "face mode");
        Check(HMS_AREngine_ARConfig_SetCameraLensFacing(session, raw, ARENGINE_CAMERA_FACING_FRONT), "front camera");
        Check(HMS_AREngine_ARConfig_SetCameraPreviewMode(session, raw, ARENGINE_PREVIEW_MODE_ENABLED), "image stream");
        Check(HMS_AREngine_ARConfig_SetUpdateMode(session, raw, ARENGINE_UPDATE_MODE_LATEST), "latest frame");
        Check(HMS_AREngine_ARConfig_SetMultiFaceMode(session, raw, ARENGINE_MULTIFACE_ENABLE), "face association");
        Check(HMS_AREngine_ARSession_Configure(session, raw), "configure");
        Check(HMS_AREngine_ARSession_Resume(session), "resume");
    } catch (const std::exception& error) {
        Close();
        napi_throw_error(env, nullptr, error.what());
        return nullptr;
    }
    return Undefined(env);
}

struct CaptureWork {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::vector<uint8_t> rgba;
    int32_t width = 0;
    int32_t height = 0;
    int32_t faceCount = 0;
    float jawOpen = -1;
    float lipGapRatio = -1;
    double timestampMs = 0;
    int64_t timestampNs = 0;
    std::string error;
};

float ReadLipGap(AREngine_ARFace* face) {
    AREngine_ARFaceGeometry* raw = nullptr;
    Check(HMS_AREngine_ARFace_AcquireGeometry(session, face, &raw), "lip geometry");
    std::unique_ptr<AREngine_ARFaceGeometry, decltype(&HMS_AREngine_ARFaceGeometry_Release)>
        geometry(raw, HMS_AREngine_ARFaceGeometry_Release);
    int32_t vertexSize = 0, indexSize = 0, labelSize = 0;
    const float* vertices = nullptr;
    const int32_t* indices = nullptr;
    const AREngine_ARAnimojiTriangleLabel* labels = nullptr;
    Check(HMS_AREngine_ARFaceGeometry_GetVerticesSize(session, raw, &vertexSize), "lip vertex count");
    Check(HMS_AREngine_ARFaceGeometry_GetIndicesSize(session, raw, &indexSize), "lip index count");
    Check(HMS_AREngine_ARFaceGeometry_GetTriangleLabelsSize(session, raw, &labelSize), "lip label count");
    Check(HMS_AREngine_ARFaceGeometry_AcquireVertices(session, raw, &vertices), "lip vertices");
    Check(HMS_AREngine_ARFaceGeometry_AcquireIndices(session, raw, &indices), "lip indices");
    Check(HMS_AREngine_ARFaceGeometry_AcquireTriangleLabels(session, raw, &labels), "lip labels");
    return posture::LipGap(vertices, vertexSize, indices, indexSize,
        labels, labelSize,
        ARENGINE_TRIANGLE_LABEL_LOWER_LIP, ARENGINE_TRIANGLE_LABEL_UPPER_LIP);
}

void ReadExpression(CaptureWork& work) {
    AREngine_ARTrackableList* raw = nullptr;
    Check(HMS_AREngine_ARTrackableList_Create(session, &raw), "create face list");
    std::unique_ptr<AREngine_ARTrackableList, decltype(&HMS_AREngine_ARTrackableList_Destroy)>
        list(raw, HMS_AREngine_ARTrackableList_Destroy);
    Check(HMS_AREngine_ARSession_GetAllTrackables(session, ARENGINE_TRACKABLE_FACE, raw), "faces");
    int32_t count = 0;
    Check(HMS_AREngine_ARTrackableList_GetSize(session, raw, &count), "face count");
    for (int32_t i = 0; i < count; ++i) {
        AREngine_ARTrackable* item = nullptr;
        Check(HMS_AREngine_ARTrackableList_AcquireItem(session, raw, i, &item), "face item");
        std::unique_ptr<AREngine_ARTrackable, decltype(&HMS_AREngine_ARTrackable_Release)>
            face(item, HMS_AREngine_ARTrackable_Release);
        AREngine_ARTrackingState state;
        Check(HMS_AREngine_ARTrackable_GetTrackingState(session, item, &state), "face state");
        if (state != ARENGINE_TRACKING_STATE_TRACKING) continue;
        ++work.faceCount;
        try {
            work.lipGapRatio = ReadLipGap(reinterpret_cast<AREngine_ARFace*>(item));
        } catch (const std::exception&) {
            work.lipGapRatio = -1;
        }
        AREngine_ARFaceBlendShapes* data = nullptr;
        Check(HMS_AREngine_ARFace_AcquireBlendShapes(session,
            reinterpret_cast<AREngine_ARFace*>(item), &data), "expressions");
        std::unique_ptr<AREngine_ARFaceBlendShapes, decltype(&HMS_AREngine_ARFaceBlendShapes_Release)>
            shapes(data, HMS_AREngine_ARFaceBlendShapes_Release);
        int32_t size = 0;
        const float* values = nullptr;
        const AREngine_ARAnimojiBlendShape* types = nullptr;
        Check(HMS_AREngine_ARFaceBlendShapes_GetCount(session, data, &size), "expression count");
        Check(HMS_AREngine_ARFaceBlendShapes_AcquireData(session, data, &values), "expression values");
        Check(HMS_AREngine_ARFaceBlendShapes_AcquireTypes(session, data, &types), "expression types");
        if (!values || !types || size < 0 || size > 64) continue;
        for (int32_t j = 0; j < size; ++j) {
            if (types[j] == ARENGINE_ARANIMOJI_JAW_OPEN && std::isfinite(values[j]) &&
                values[j] >= 0 && values[j] <= 1) work.jawOpen = values[j];
        }
    }
    if (work.faceCount != 1) {
        work.jawOpen = -1;
        work.lipGapRatio = -1;
    }
}

void ReadImage(AREngine_ARFrame* frame, CaptureWork& work) {
    AREngine_ARImage* raw = nullptr;
    Check(HMS_AREngine_ARFrame_AcquireCameraImage(session, frame, &raw), "camera image");
    std::unique_ptr<AREngine_ARImage, decltype(&HMS_AREngine_ARImage_Release)>
        image(raw, HMS_AREngine_ARImage_Release);
    int64_t timestamp = 0;
    Check(HMS_AREngine_ARImage_GetTimestamp(session, raw, &timestamp), "image timestamp");
    if (timestamp <= lastTimestamp) throw std::runtime_error("AR image is not fresh");
    work.timestampMs = timestamp / 1000000.0;
    work.timestampNs = timestamp;
    AREngine_ARImageFormat format;
    int32_t width = 0, height = 0, count = 0;
    Check(HMS_AREngine_ARImage_GetFormat(session, raw, &format), "image format");
    Check(HMS_AREngine_ARImage_GetWidth(session, raw, &width), "image width");
    Check(HMS_AREngine_ARImage_GetHeight(session, raw, &height), "image height");
    Check(HMS_AREngine_ARImage_GetPlaneCount(session, raw, &count), "image planes");
    if (format != ARENGINE_IMAGE_YUV_420_888 || count != 3 || width <= 0 || height <= 0 ||
        width > 8192 || height > 8192) throw std::runtime_error("Unsupported AR camera image");
    std::array<posture::Plane, 3> planes;
    for (int i = 0; i < 3; ++i) {
        auto& p = planes[i];
        Check(HMS_AREngine_ARImage_GetPlaneData(session, raw, i, &p.data, &p.length), "plane data");
        Check(HMS_AREngine_ARImage_GetPlaneRowStride(session, raw, i, &p.row), "row stride");
        Check(HMS_AREngine_ARImage_GetPlanePixelStride(session, raw, i, &p.pixel), "pixel stride");
    }
    auto converted = posture::ConvertYuv420(width, height, planes);
    work.width = converted.width;
    work.height = converted.height;
    work.rgba = std::move(converted.bytes);
}

void ExecuteCapture(napi_env, void* data) {
    auto& work = *static_cast<CaptureWork*>(data);
    std::lock_guard<std::mutex> lock(sessionMutex);
    try {
        if (!session) throw std::runtime_error("AR session closed");
        ScopedGL graphics;
        Check(HMS_AREngine_ARSession_SetCameraGLTexture(session, cameraTexture), "camera texture");
        AREngine_ARFrame* raw = nullptr;
        Check(HMS_AREngine_ARFrame_Create(session, &raw), "create frame");
        std::unique_ptr<AREngine_ARFrame, decltype(&HMS_AREngine_ARFrame_Destroy)>
            frame(raw, HMS_AREngine_ARFrame_Destroy);
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
        bool received = false;
        std::string frameError = "AR frame timed out";
        do {
            Check(HMS_AREngine_ARSession_Update(session, raw), "update");
            try {
                ReadImage(raw, work);
                received = true;
                break;
            } catch (const std::exception& error) {
                frameError = error.what();
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(30));
        } while (std::chrono::steady_clock::now() < deadline);
        if (!received) throw std::runtime_error(frameError);
        ReadExpression(work);
        lastTimestamp = work.timestampNs;
    } catch (const std::exception& error) {
        work.error = error.what();
    }
}

void Number(napi_env env, napi_value object, const char* key, double number) {
    napi_value value;
    napi_create_double(env, number, &value);
    napi_set_named_property(env, object, key, value);
}

void CompleteCapture(napi_env env, napi_status status, void* data) {
    std::unique_ptr<CaptureWork> work(static_cast<CaptureWork*>(data));
    capturing = false;
    if (status != napi_ok && work->error.empty()) work->error = "AR capture cancelled";
    if (!work->error.empty()) {
        napi_value message, error;
        napi_create_string_utf8(env, work->error.c_str(), NAPI_AUTO_LENGTH, &message);
        napi_create_error(env, nullptr, message, &error);
        napi_reject_deferred(env, work->deferred, error);
    } else {
        napi_value result, buffer;
        void* bytes = nullptr;
        napi_create_object(env, &result);
        if (napi_create_arraybuffer(env, work->rgba.size(), &bytes, &buffer) != napi_ok || !bytes) {
            napi_value message, error;
            napi_create_string_utf8(env, "AR image allocation failed", NAPI_AUTO_LENGTH, &message);
            napi_create_error(env, nullptr, message, &error);
            napi_reject_deferred(env, work->deferred, error);
        } else {
            std::memcpy(bytes, work->rgba.data(), work->rgba.size());
            napi_set_named_property(env, result, "rgba", buffer);
            Number(env, result, "width", work->width);
            Number(env, result, "height", work->height);
            Number(env, result, "jawOpen", work->jawOpen);
            Number(env, result, "lipGapRatio", work->lipGapRatio);
            Number(env, result, "faceCount", work->faceCount);
            Number(env, result, "timestampMs", work->timestampMs);
            napi_resolve_deferred(env, work->deferred, result);
        }
    }
    napi_delete_async_work(env, work->work);
}

napi_value Capture(napi_env env, napi_callback_info) {
    if (capturing) {
        napi_throw_error(env, nullptr, "AR capture already pending");
        return nullptr;
    }
    auto work = std::make_unique<CaptureWork>();
    napi_value promise, name;
    napi_create_promise(env, &work->deferred, &promise);
    napi_create_string_utf8(env, "PostureARCapture", NAPI_AUTO_LENGTH, &name);
    napi_status status = napi_create_async_work(env, nullptr, name, ExecuteCapture, CompleteCapture,
        work.get(), &work->work);
    if (status == napi_ok) status = napi_queue_async_work(env, work->work);
    if (status != napi_ok) {
        if (work->work) napi_delete_async_work(env, work->work);
        napi_value message, error;
        napi_create_string_utf8(env, "Cannot queue AR capture", NAPI_AUTO_LENGTH, &message);
        napi_create_error(env, nullptr, message, &error);
        napi_reject_deferred(env, work->deferred, error);
        return promise;
    }
    capturing = true;
    work.release();
    return promise;
}

napi_value Stop(napi_env env, napi_callback_info) {
    std::lock_guard<std::mutex> lock(sessionMutex);
    Close();
    return Undefined(env);
}

void Cleanup(void*) {
    std::lock_guard<std::mutex> lock(sessionMutex);
    Close();
}

napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor properties[] = {
        {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"capture", nullptr, Capture, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, 3, properties);
    napi_add_env_cleanup_hook(env, Cleanup, nullptr);
    return exports;
}
}

static napi_module module = {1, 0, nullptr, Init, "posture_ar", nullptr, {0}};
extern "C" __attribute__((constructor)) void RegisterPostureAR() { napi_module_register(&module); }

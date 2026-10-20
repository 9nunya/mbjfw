#ifndef MBJFW_NATIVE_SESSION_H
#define MBJFW_NATIVE_SESSION_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct MBJFWNativeSessionOpaque* MBJFWNativeSession;
enum MBJFWNativeState {
    MBJFWNativeStarting = 0,
    MBJFWNativeRendererReady = 1,
    MBJFWNativeWindowReady = 2,
    MBJFWNativeClosed = 3,
    MBJFWNativeFailed = 4,
    MBJFWNativeInputReady = 5
};
enum MBJFWNativeCommand {
    MBJFWNativeShow = 1,
    MBJFWNativeReleaseInput = 2,
    MBJFWNativeStop = 4,
    MBJFWNativePrepareInput = 8,
    MBJFWNativeRefreshLayout = 16
};
enum MBJFWNativeNoticeKind {
    MBJFWNativeNoticeInformation = 0,
    MBJFWNativeNoticeSuccess = 1,
    MBJFWNativeNoticeError = 2
};
typedef struct MBJFWNativeStatus {
    uint32_t state;
    uint32_t processID;
    uint32_t windowID;
    uint32_t errorCode;
    uint32_t desiredWidth;
    uint32_t desiredHeight;
    uint32_t guestWidth;
    uint32_t guestHeight;
    uint32_t captured;
    uint32_t stopRequested;
    uint64_t geometryGeneration;
    uint64_t keyEvents;
    uint64_t mouseEvents;
    uint64_t launcherRequests;
} MBJFWNativeStatus;

MBJFWNativeSession mbjfw_native_session_create(const char* name, uint32_t width, uint32_t height);
const char* mbjfw_native_host_library_path(void);
MBJFWNativeSession mbjfw_native_session_open(const char* name);
void mbjfw_native_session_close(MBJFWNativeSession session);
void mbjfw_native_session_destroy(MBJFWNativeSession session, const char* name);
int mbjfw_native_session_read(MBJFWNativeSession session, MBJFWNativeStatus* status);
void mbjfw_native_session_command(MBJFWNativeSession session, uint32_t commands);
void mbjfw_native_session_geometry(MBJFWNativeSession session, uint32_t width, uint32_t height);
void mbjfw_native_session_capture_request(MBJFWNativeSession session, int requested);
void mbjfw_native_session_display_follows_window(MBJFWNativeSession session, int followsWindow);
void mbjfw_native_session_notice(MBJFWNativeSession session, const char* text, uint32_t kind, uint32_t durationMilliseconds);
int mbjfw_native_session_read_notice(MBJFWNativeSession session, uint64_t* previousGeneration, uint32_t* kind, uint32_t* durationMilliseconds, char* text, uint32_t capacity);

#ifdef __cplusplus
}
#endif
#endif

#include "NativeSessionInternal.h"
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <algorithm>
#include <cstring>
#include <string>

namespace {
constexpr uint32_t magic = 0x4d424e53;
constexpr uint32_t version = 4;
struct SharedSession {
    uint32_t magic;
    uint32_t version;
    uint64_t sequence;
    MBJFWNativeStatus status;
    uint32_t commands;
    uint64_t geometry;
    uint32_t captureRequested;
    uint32_t displayFollowsWindow;
    uint64_t noticeSequence;
    uint64_t noticeGeneration;
    uint32_t noticeKind;
    uint32_t noticeDurationMilliseconds;
    char noticeText[512];
};
std::string sharedName(const char* name) {
    return name[0] == '/' ? std::string(name) : "/" + std::string(name);
}
}
struct MBJFWNativeSessionOpaque { int descriptor; SharedSession* shared; };

MBJFWNativeSession mbjfw_native_session_create(const char* name, uint32_t width, uint32_t height) {
    if (!name || !*name || width == 0 || height == 0) return nullptr;
    auto path = sharedName(name);
    int fd = shm_open(path.c_str(), O_CREAT | O_EXCL | O_RDWR, 0600);
    if (fd < 0) return nullptr;
    if (ftruncate(fd, sizeof(SharedSession)) != 0) { close(fd); shm_unlink(path.c_str()); return nullptr; }
    auto* shared = static_cast<SharedSession*>(mmap(nullptr, sizeof(SharedSession), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0));
    if (shared == MAP_FAILED) { close(fd); shm_unlink(path.c_str()); return nullptr; }
    std::memset(shared, 0, sizeof(*shared));
    shared->version = version;
    shared->geometry = (static_cast<uint64_t>(height) << 32) | width;
    shared->displayFollowsWindow = 1;
    shared->status.guestWidth = width;
    shared->status.guestHeight = height;
    __atomic_store_n(&shared->magic, magic, __ATOMIC_RELEASE);
    return new MBJFWNativeSessionOpaque{fd, shared};
}
MBJFWNativeSession mbjfw_native_session_open(const char* name) {
    if (!name || !*name) return nullptr;
    int fd = shm_open(sharedName(name).c_str(), O_RDWR, 0600);
    if (fd < 0) return nullptr;
    auto* shared = static_cast<SharedSession*>(mmap(nullptr, sizeof(SharedSession), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0));
    if (shared == MAP_FAILED) { close(fd); return nullptr; }
    if (__atomic_load_n(&shared->magic, __ATOMIC_ACQUIRE) != magic || shared->version != version) {
        munmap(shared, sizeof(*shared)); close(fd); return nullptr;
    }
    return new MBJFWNativeSessionOpaque{fd, shared};
}
void mbjfw_native_session_close(MBJFWNativeSession session) {
    if (!session) return;
    munmap(session->shared, sizeof(SharedSession)); close(session->descriptor); delete session;
}
void mbjfw_native_session_destroy(MBJFWNativeSession session, const char* name) {
    if (name && *name) shm_unlink(sharedName(name).c_str());
    mbjfw_native_session_close(session);
}
int mbjfw_native_session_read(MBJFWNativeSession session, MBJFWNativeStatus* status) {
    if (!session || !status) return 0;
    auto* shared = session->shared;
    for (int attempt = 0; attempt < 3; ++attempt) {
        uint64_t before = __atomic_load_n(&shared->sequence, __ATOMIC_ACQUIRE);
        if (before & 1) continue;
        MBJFWNativeStatus snapshot = shared->status;
        if (before == __atomic_load_n(&shared->sequence, __ATOMIC_ACQUIRE)) { *status = snapshot; return 1; }
    }
    return 0;
}
void mbjfw_native_session_publish(MBJFWNativeSession session, const MBJFWNativeStatus& status) {
    auto* shared = session->shared;
    uint64_t before = __atomic_load_n(&shared->sequence, __ATOMIC_RELAXED);
    __atomic_store_n(&shared->sequence, before + 1, __ATOMIC_SEQ_CST);
    shared->status = status;
    __atomic_store_n(&shared->sequence, before + 2, __ATOMIC_RELEASE);
}
void mbjfw_native_session_command(MBJFWNativeSession session, uint32_t commands) {
    if (session) __atomic_fetch_or(&session->shared->commands, commands, __ATOMIC_RELEASE);
}
uint32_t mbjfw_native_session_take_commands(MBJFWNativeSession session) {
    return __atomic_exchange_n(&session->shared->commands, 0, __ATOMIC_ACQ_REL);
}
void mbjfw_native_session_geometry(MBJFWNativeSession session, uint32_t width, uint32_t height) {
    if (!session || width < 320 || height < 240 || width > 4096 || height > 4096) return;
    uint64_t packed = (static_cast<uint64_t>(height) << 32) | width;
    __atomic_store_n(&session->shared->geometry, packed, __ATOMIC_RELEASE);
}
void mbjfw_native_session_get_geometry(MBJFWNativeSession session, uint32_t* width, uint32_t* height) {
    uint64_t packed = __atomic_load_n(&session->shared->geometry, __ATOMIC_ACQUIRE);
    *width = static_cast<uint32_t>(packed); *height = static_cast<uint32_t>(packed >> 32);
}
void mbjfw_native_session_capture_request(MBJFWNativeSession session, int requested) {
    if (session) __atomic_store_n(&session->shared->captureRequested, requested != 0, __ATOMIC_RELEASE);
}
bool mbjfw_native_session_capture_requested(MBJFWNativeSession session) {
    return __atomic_load_n(&session->shared->captureRequested, __ATOMIC_ACQUIRE) != 0;
}
void mbjfw_native_session_display_follows_window(MBJFWNativeSession session, int followsWindow) {
    if (session) {
        __atomic_store_n(&session->shared->displayFollowsWindow, followsWindow != 0, __ATOMIC_RELEASE);
        mbjfw_native_session_command(session, MBJFWNativeRefreshLayout);
    }
}
void mbjfw_native_session_notice(MBJFWNativeSession session, const char* text, uint32_t kind, uint32_t durationMilliseconds) {
    if (!session || !text) return;
    auto* shared = session->shared;
    uint64_t before = __atomic_load_n(&shared->noticeSequence, __ATOMIC_RELAXED);
    __atomic_store_n(&shared->noticeSequence, before + 1, __ATOMIC_SEQ_CST);
    std::strncpy(shared->noticeText, text, sizeof(shared->noticeText) - 1);
    shared->noticeText[sizeof(shared->noticeText) - 1] = '\0';
    shared->noticeKind = kind;
    shared->noticeDurationMilliseconds = std::clamp(durationMilliseconds, 1000u, 15000u);
    ++shared->noticeGeneration;
    __atomic_store_n(&shared->noticeSequence, before + 2, __ATOMIC_RELEASE);
}
int mbjfw_native_session_read_notice(MBJFWNativeSession session, uint64_t* previousGeneration, uint32_t* kind, uint32_t* durationMilliseconds, char* text, uint32_t capacity) {
    if (!session || !previousGeneration || !kind || !durationMilliseconds || !text || capacity == 0) return 0;
    auto* shared = session->shared;
    for (int attempt = 0; attempt < 3; ++attempt) {
        uint64_t before = __atomic_load_n(&shared->noticeSequence, __ATOMIC_ACQUIRE);
        if (before & 1) continue;
        uint64_t generation = shared->noticeGeneration;
        uint32_t nextKind = shared->noticeKind;
        uint32_t duration = shared->noticeDurationMilliseconds;
        char message[sizeof(shared->noticeText)];
        std::memcpy(message, shared->noticeText, sizeof(message));
        if (before != __atomic_load_n(&shared->noticeSequence, __ATOMIC_ACQUIRE)) continue;
        if (generation == *previousGeneration) return 0;
        *previousGeneration = generation;
        *kind = nextKind;
        *durationMilliseconds = duration;
        std::strncpy(text, message, capacity - 1);
        text[capacity - 1] = '\0';
        return 1;
    }
    return 0;
}
bool mbjfw_native_session_get_display_follows_window(MBJFWNativeSession session) {
    return session && __atomic_load_n(&session->shared->displayFollowsWindow, __ATOMIC_ACQUIRE) != 0;
}

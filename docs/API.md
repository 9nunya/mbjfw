# Native bridge API

`NativeGameHost/FrameBridge/include/NativeSession.h` is the C ABI shared by the Swift launcher and the Objective-C++ code injected into the Android Emulator process. The current shared-memory layout is protocol version **4**. The launcher and injected bridge are built and packaged together; version 4 is not a stable third-party ABI.

## Session ownership

```c
typedef struct MBJFWNativeSessionOpaque *MBJFWNativeSession;

MBJFWNativeSession mbjfw_native_session_create(const char *name, uint32_t width, uint32_t height);
MBJFWNativeSession mbjfw_native_session_open(const char *name);
void mbjfw_native_session_close(MBJFWNativeSession session);
void mbjfw_native_session_destroy(MBJFWNativeSession session, const char *name);
```

`create` creates an exclusive POSIX shared-memory object and initializes the protocol. `open` maps an existing object only when its magic and version match. `close` releases the local mapping; `destroy` unlinks the name and closes the mapping. Each emulator profile uses a cryptographically random name passed in `MBJFW_NATIVE_SESSION`.

## Status and control

`MBJFWNativeStatus` is a snapshot containing native-window state, QEMU/window IDs, error code, requested and effective guest geometry, pointer-capture state, stop request, geometry generation, input counters, and launcher request generation.

The state enum is:

| Value | State |
| --- | --- |
| 0 | Starting |
| 1 | Renderer ready |
| 2 | Native window ready |
| 3 | Closed |
| 4 | Failed |
| 5 | HID input ready |

`mbjfw_native_session_read` returns a coherent status snapshot or 0 if a concurrent write prevented a stable read. Writers use a sequence counter around status updates.

| Function | Purpose |
| --- | --- |
| `mbjfw_native_session_command(session, commands)` | Queue one or more OR-combinable commands |
| `mbjfw_native_session_geometry(session, width, height)` | Request display geometry; valid range is 320–4096 by 240–4096 |
| `mbjfw_native_session_capture_request(session, requested)` | Update the guest pointer-capture request |
| `mbjfw_native_session_display_follows_window(session, follows)` | Enable or disable display-mode changes as the host window resizes |
| `mbjfw_native_host_library_path()` | Return the path of the packaged native host library |

Command bit values are `Show=1`, `ReleaseInput=2`, `Stop=4`, `PrepareInput=8`, and `RefreshLayout=16`.

## In-window notices

```c
void mbjfw_native_session_notice(
    MBJFWNativeSession session,
    const char *text,
    uint32_t kind,
    uint32_t durationMilliseconds
);

int mbjfw_native_session_read_notice(
    MBJFWNativeSession session,
    uint64_t *previousGeneration,
    uint32_t *kind,
    uint32_t *durationMilliseconds,
    char *text,
    uint32_t capacity
);
```

Notice kinds are information (0), success (1), and error (2). Text is UTF-8, NUL-terminated, and bounded to 511 bytes plus the terminator. Display time is clamped to 1–15 seconds. The reader returns 1 only when a stable record with a new generation is available; it updates `previousGeneration` on success. A 50 ms native control poll consumes notices and presents them in the game window.

## Swift ownership surface

The app's internal API is deliberately profile-scoped:

- `GameLibrary.runtime(for:)` resolves the manager for a profile UUID.
- `GameLibrary.launch(for:)` resolves that profile's APK and Android data directory.
- `GameLibrary.updateSettings(_:for:)` persists typed settings and refreshes live display behavior.
- `AndroidRuntimeManager.stopGame()` / `stopGameAndWait()` stop only that profile.
- `GameLibrary.stopAllInstancesAndWait()` is reserved for app shutdown.

The API never accepts an implicit active ADB device. Commands use the exact profile's emulator serial. Logs are scoped per profile after launch.

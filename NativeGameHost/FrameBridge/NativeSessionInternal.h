#pragma once
#include "include/NativeSession.h"
#include <stdint.h>
uint32_t mbjfw_native_session_take_commands(MBJFWNativeSession session);
void mbjfw_native_session_publish(MBJFWNativeSession session, const MBJFWNativeStatus& status);
void mbjfw_native_session_get_geometry(MBJFWNativeSession session, uint32_t* width, uint32_t* height);
bool mbjfw_native_session_capture_requested(MBJFWNativeSession session);
bool mbjfw_native_session_get_display_follows_window(MBJFWNativeSession session);

#pragma once
#import <Foundation/Foundation.h>
// All calls belong to the AppKit main thread. No frames pass through this pipe.
void mbjfw_hid_start(void (^ready)(void), void (^failed)(void));
bool mbjfw_hid_ready();
void mbjfw_hid_key(unsigned short macCode, bool down);
void mbjfw_hid_mouse(int x, int y, unsigned buttons, int wheelX=0, int wheelY=0);
void mbjfw_hid_pointer(int x, int y, int extent, unsigned buttons, bool inRange=true, int wheelX=0, int wheelY=0);
void mbjfw_hid_release();
void mbjfw_hid_poll();

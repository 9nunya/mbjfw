#import <AppKit/AppKit.h>
#include <dlfcn.h>
#include <pthread.h>
#include <unistd.h>
#include <mach-o/dyld.h>
#include <cstdio>
#include <cstring>
#include <cstdlib>

using HasFrame = bool (*)();
using ShowWindow = int (*)(void*, int, int, int, int, int, int, float, float, bool, bool);
static NSWindow* gameWindow;
static void* runProbe(void*) {
    auto hasFrame = reinterpret_cast<HasFrame>(dlsym(RTLD_DEFAULT, "android_hasGuestPostedAFrame"));
    auto show = reinterpret_cast<ShowWindow>(dlsym(RTLD_DEFAULT, "android_showOpenglesWindow"));
    if (!hasFrame || !show) return nullptr;
    std::fprintf(stderr, "MBJFW native probe: renderer entrypoints found pid=%d\n", getpid());
    for (int i=0; i<600; ++i) {
        if (hasFrame()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                @autoreleasepool {
                    gameWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1280,720)
                        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable
                        backing:NSBackingStoreBuffered defer:NO];
                    gameWindow.title = @"Bedrock — Native Render Probe";
                    [gameWindow center];
                    int result=show((__bridge void*)gameWindow,0,0,1280,720,1280,720,1.0f,0.0f,false,false);
                    std::fprintf(stderr, "MBJFW native probe: show result=%d window=%ld\n",result,(long)gameWindow.windowNumber);
                    [gameWindow makeKeyAndOrderFront:nil];
                }
            });
            return nullptr;
        }
        usleep(200000);
    }
    std::fprintf(stderr,"MBJFW native probe: guest never posted a frame\n");
    return nullptr;
}
__attribute__((constructor)) static void startProbe() {
    if (!std::getenv("MBJFW_NATIVE_PROBE")) return;
    char executable[4096]; uint32_t size=sizeof(executable);
    if (_NSGetExecutablePath(executable,&size)!=0 ||
        (!strstr(executable,"qemu-system-aarch64") && !strstr(executable,"qemu-system-x86_64"))) return;
    pthread_t thread;
    if (pthread_create(&thread,nullptr,runProbe,nullptr)==0) pthread_detach(thread);
}

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <string>
#include "NativeSession.h"

const char* mbjfw_native_host_library_path(void) {
    static std::string path;
    @autoreleasepool {
        NSString* bundlePath = [[NSBundle mainBundle] bundlePath];
        NSArray<NSString*>* candidates = @[
            [bundlePath stringByAppendingPathComponent:@"Contents/Frameworks/libMBJFWFrameBridge.dylib"],
            [bundlePath stringByAppendingPathComponent:@"libMBJFWFrameBridge.dylib"],
            [bundlePath stringByAppendingPathComponent:@"PackageFrameworks/libMBJFWFrameBridge.dylib"]
        ];
        for (NSString* candidate in candidates) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
                path = candidate.fileSystemRepresentation;
                return path.c_str();
            }
        }
    }
    Dl_info image{};
    if (dladdr(reinterpret_cast<const void*>(&mbjfw_native_host_library_path), &image) && image.dli_fname && std::string(image.dli_fname).find(".dylib") != std::string::npos) {
        path = image.dli_fname;
    }
    return path.empty() ? nullptr : path.c_str();
}

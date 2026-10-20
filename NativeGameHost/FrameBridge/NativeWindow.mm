#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <IOKit/hidsystem/IOLLEvent.h>
#include "NativeSessionInternal.h"
#include "UHIDTransport.h"
#include <dlfcn.h>
#include <pthread.h>
#include <unistd.h>
#include <cstdio>
#include <cstdlib>
#include <array>
#include <set>
#include <cmath>
#include <algorithm>
#include <signal.h>

namespace {
using ShowWindow = int (*)(void*, int, int, int, int, int, int, float, float, bool, bool);
using HasFrame = bool (*)();
struct GuestDisplayMode { uint32_t width, height; };
constexpr GuestDisplayMode guestDisplayModes[] = {{1280,720},{1600,900},{1920,1080}};
int closestDisplayMode(double width, double height) {
    int best = 0;
    double bestScore = INFINITY;
    for (int index=0; index<3; ++index) {
        const auto& mode=guestDisplayModes[index];
        const double score=std::abs(std::log(static_cast<double>(mode.width)/width))+
                           std::abs(std::log(static_cast<double>(mode.height)/height));
        if (score<bestScore) { best=index; bestScore=score; }
    }
    return best;
}
MBJFWNativeSession session;
MBJFWNativeStatus status{};
ShowWindow showWindow;
using SetResizableDisplayMode = void (*)(int);
SetResizableDisplayMode setResizableDisplayMode;
NSWindow* gameWindow;
id eventMonitor;
NSTimer* controlTimer;
id sessionActivity;
std::set<unsigned> heldKeys;
int heldButtons = 0;
bool captured = false;
bool cursorHidden = false;
bool nativeResizeGesture = false;
bool suppressCapture = false;
bool guestCapture = false;
double residualX = 0, residualY = 0;
double scrollResidualX = 0, scrollResidualY = 0, lastScrollTime = 0;
bool lastScrollWasPrecise = false;
bool rendererLayoutInProgress = false;
uint64_t seenNoticeGeneration = 0;
NSVisualEffectView* noticeView;
NSTextField* noticeLabel;
NSImageView* noticeIcon;
NSRect viewport;
uint32_t guestWidth = 1280, guestHeight = 720;
pid_t launcherPID = 0;
int activeDisplayMode = 0, attemptedDisplayMode = -1;

void hideMacCursor(bool hidden) {
    if (cursorHidden == hidden) return;
    cursorHidden = hidden;
    if (hidden) [NSCursor hide]; else [NSCursor unhide];
}

void publish() {
    status.captured = captured;
    status.guestWidth = guestWidth; status.guestHeight = guestHeight;
    mbjfw_native_session_publish(session, status);
}
void releaseCapture() {
    if (!captured) return;
    captured = false;
    CGAssociateMouseAndMouseCursorPosition(true);
    residualX = residualY = 0;
}
void resetScroll() {
    scrollResidualX = scrollResidualY = 0;
    lastScrollTime = 0;
}
void scroll(NSEvent* event) {
    // AppKit reports precise trackpad motion in points, while a mouse wheel
    // reports discrete wheel steps. Android's HID wheel is also step based;
    // forwarding trackpad points as steps made one swipe advance many items.
    // A 120-point precise scroll maps to one Android wheel notch (the HID
    // high-resolution wheel convention). macOS applies the user's scroll
    // preference to these point deltas before they reach this handler.
    constexpr double pointsPerWheelStep = 120.0;
    const double now = event.timestamp;
    if ((lastScrollTime && now - lastScrollTime > 0.75) ||
        (lastScrollTime && lastScrollWasPrecise != event.hasPreciseScrollingDeltas)) {
        resetScroll();
    }
    lastScrollTime = now;
    lastScrollWasPrecise = event.hasPreciseScrollingDeltas;
    const double scale = event.hasPreciseScrollingDeltas ? 1.0 / pointsPerWheelStep : 1.0;
    scrollResidualX += event.scrollingDeltaX * scale;
    scrollResidualY += event.scrollingDeltaY * scale;
    const int wheelX = static_cast<int>(std::trunc(scrollResidualX));
    const int wheelY = static_cast<int>(std::trunc(scrollResidualY));
    scrollResidualX -= wheelX;
    scrollResidualY -= wheelY;
    if (captured) {
        if (wheelX || wheelY) mbjfw_hid_mouse(0, 0, heldButtons, wheelX, wheelY);
    } else {
        NSPoint point = [gameWindow.contentView convertPoint:event.locationInWindow fromView:nil];
        point.y = gameWindow.contentView.bounds.size.height - point.y;
        int x = std::clamp(static_cast<int>((point.x-viewport.origin.x)*guestWidth/viewport.size.width), 0, static_cast<int>(guestWidth)-1);
        int y = std::clamp(static_cast<int>((point.y-viewport.origin.y)*guestHeight/viewport.size.height), 0, static_cast<int>(guestHeight)-1);
        mbjfw_hid_pointer(x, y, std::max(guestWidth,guestHeight), heldButtons, true, wheelX, wheelY);
    }
}
void releaseAll() {
    releaseCapture();
    resetScroll();
    mbjfw_hid_release();
    heldKeys.clear(); heldButtons = 0;
    hideMacCursor(false);
    publish();
}
void capture() {
    if (captured || !gameWindow.isKeyWindow || suppressCapture) return;
    if (CGAssociateMouseAndMouseCursorPosition(false) != kCGErrorSuccess) return;
    mbjfw_hid_pointer(0,0,1,0,false);
    captured = true;
    hideMacCursor(true);
    publish();
}
void requestStop() {
    releaseAll();
    if (sessionActivity) { [NSProcessInfo.processInfo endActivity:sessionActivity]; sessionActivity=nil; }
    status.stopRequested = 1;
    status.state = MBJFWNativeClosed;
    [gameWindow orderOut:nil];
    publish();
}
void layoutRenderer() {
    if (!gameWindow || !showWindow || rendererLayoutInProgress) return;
    NSSize size = gameWindow.contentView.bounds.size;
    if (size.width < 1 || size.height < 1) return;
    rendererLayoutInProgress = true;
    double width = size.width, height = size.height;
    viewport = NSMakeRect(0, 0, width, height);
    std::fprintf(stderr, "MBJFW native binding begin: %ux%u\n", guestWidth, guestHeight);
    int result = showWindow((__bridge void*)gameWindow, static_cast<int>(viewport.origin.x),
        static_cast<int>(viewport.origin.y), static_cast<int>(width), static_cast<int>(height),
        guestWidth, guestHeight, gameWindow.backingScaleFactor, 0, false, false);
    rendererLayoutInProgress = false;
    std::fprintf(stderr, "MBJFW native binding returned: %d\n", result);
    if (result != 0) { status.errorCode = 2; status.state = MBJFWNativeFailed; }
    const int requestedMode = closestDisplayMode(width * gameWindow.backingScaleFactor,
                                                  height * gameWindow.backingScaleFactor);
    const uint32_t desiredWidth = mbjfw_native_session_get_display_follows_window(session)
        ? guestDisplayModes[requestedMode].width : guestWidth;
    const uint32_t desiredHeight = mbjfw_native_session_get_display_follows_window(session)
        ? guestDisplayModes[requestedMode].height : guestHeight;
    if (desiredWidth != status.desiredWidth || desiredHeight != status.desiredHeight) {
        status.desiredWidth = desiredWidth; status.desiredHeight = desiredHeight;
        ++status.geometryGeneration;
    }
    publish();
}
void syncModifiers(NSEvent* event) {
    struct Modifier { unsigned left,right; NSEventModifierFlags aggregate,leftFlag,rightFlag; };
    const Modifier modifiers[] = {
        {56,60,NSEventModifierFlagShift,NX_DEVICELSHIFTKEYMASK,NX_DEVICERSHIFTKEYMASK},
        {59,62,NSEventModifierFlagControl,NX_DEVICELCTLKEYMASK,NX_DEVICERCTLKEYMASK},
        {58,61,NSEventModifierFlagOption,NX_DEVICELALTKEYMASK,NX_DEVICERALTKEYMASK}
    };
    for (const auto& modifier : modifiers) {
        bool active=(event.modifierFlags & modifier.aggregate)!=0;
        bool specific=(event.modifierFlags & (modifier.leftFlag|modifier.rightFlag))!=0;
        bool left=active && (specific ? (event.modifierFlags & modifier.leftFlag)!=0 : !heldKeys.count(modifier.right));
        bool right=active && (specific ? (event.modifierFlags & modifier.rightFlag)!=0 : heldKeys.count(modifier.right));
        for (auto pair : {std::pair<unsigned,bool>{modifier.left,left},{modifier.right,right}}) {
            if (heldKeys.count(pair.first) == pair.second) continue;
            if (pair.second) heldKeys.insert(pair.first); else heldKeys.erase(pair.first);
            mbjfw_hid_key(pair.first,pair.second);
        }
    }
}
void key(NSEvent* event, bool down) {
    if (event.isARepeat) return;
    unsigned code = event.keyCode;
    if (down) heldKeys.insert(code); else heldKeys.erase(code);
    mbjfw_hid_key(event.keyCode, down);
    ++status.keyEvents;
    if (down && event.keyCode == 53) { suppressCapture = true; releaseCapture(); }
}
void mouse(NSEvent* event) {
    bool buttonEvent = false;
    switch (event.type) {
        case NSEventTypeLeftMouseDown: heldButtons |= 1; buttonEvent = true; break;
        case NSEventTypeLeftMouseUp: heldButtons &= ~1; buttonEvent = true; break;
        case NSEventTypeRightMouseDown: heldButtons |= 2; buttonEvent = true; break;
        case NSEventTypeRightMouseUp: heldButtons &= ~2; buttonEvent = true; break;
        case NSEventTypeOtherMouseDown: heldButtons |= 4; buttonEvent = true; break;
        case NSEventTypeOtherMouseUp: heldButtons &= ~4; buttonEvent = true; break;
        default: break;
    }
    if (event.type == NSEventTypeLeftMouseDown) {
        [gameWindow makeFirstResponder:gameWindow.contentView];
        suppressCapture = false;
        if (guestCapture) capture();
    }
    if (captured) {
        residualX += event.deltaX; residualY += event.deltaY;
        int dx = static_cast<int>(std::trunc(residualX)), dy = static_cast<int>(std::trunc(residualY));
        residualX -= dx; residualY -= dy;
        if (dx || dy || buttonEvent) mbjfw_hid_mouse(dx, dy, heldButtons);
    } else {
        NSPoint point = [gameWindow.contentView convertPoint:event.locationInWindow fromView:nil];
        point.y = gameWindow.contentView.bounds.size.height - point.y;
        if (!NSPointInRect(point, viewport) && !buttonEvent) return;
        int x = std::clamp(static_cast<int>((point.x-viewport.origin.x)*guestWidth/viewport.size.width), 0, static_cast<int>(guestWidth)-1);
        int y = std::clamp(static_cast<int>((point.y-viewport.origin.y)*guestHeight/viewport.size.height), 0, static_cast<int>(guestHeight)-1);
        mbjfw_hid_pointer(x, y, std::max(guestWidth,guestHeight), heldButtons);
    }
    ++status.mouseEvents;
}
}

@interface MBJFWNativeInputView : NSView
@property(nonatomic, strong) NSTrackingArea* pointerTracking;
@end
@implementation MBJFWNativeInputView
- (BOOL)acceptsFirstResponder { return YES; }
- (void)updateTrackingAreas {
    if (self.pointerTracking) [self removeTrackingArea:self.pointerTracking];
    self.pointerTracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:self.pointerTracking];
    [super updateTrackingAreas];
}
- (void)mouseEntered:(NSEvent*)event { if (gameWindow.isKeyWindow) hideMacCursor(true); }
- (void)mouseExited:(NSEvent*)event { if (!captured) hideMacCursor(false); }
@end

@interface MBJFWPassThroughNoticeView : NSVisualEffectView
@end
@implementation MBJFWPassThroughNoticeView
- (NSView*)hitTest:(NSPoint)point { return nil; }
@end

@interface MBJFWNativeWindowDelegate : NSObject <NSWindowDelegate>
@end
@implementation MBJFWNativeWindowDelegate
- (void)windowDidResize:(NSNotification*)note { layoutRenderer(); }
- (void)windowDidDeminiaturize:(NSNotification*)note { layoutRenderer(); }
- (void)windowDidChangeBackingProperties:(NSNotification*)note { layoutRenderer(); }
- (void)windowDidResignKey:(NSNotification*)note { suppressCapture = true; releaseAll(); }
- (void)windowDidMiniaturize:(NSNotification*)note { suppressCapture = true; releaseAll(); }
- (BOOL)windowShouldClose:(NSWindow*)sender { requestStop(); return NO; }
@end

namespace {
MBJFWNativeWindowDelegate* windowDelegate;

void createNoticeView(NSView* content) {
    auto* panel = [[MBJFWPassThroughNoticeView alloc] initWithFrame:NSZeroRect];
    panel.material = NSVisualEffectMaterialHUDWindow;
    panel.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    panel.state = NSVisualEffectStateActive;
    panel.wantsLayer = YES;
    panel.layer.cornerRadius = 11;
    panel.layer.masksToBounds = YES;
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.hidden = YES;

    NSImageView* icon = [[NSImageView alloc] initWithFrame:NSZeroRect];
    icon.image = [NSImage imageWithSystemSymbolName:@"info.circle" accessibilityDescription:nil];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField* label = [NSTextField wrappingLabelWithString:@""];
    label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    label.textColor = NSColor.labelColor;
    label.maximumNumberOfLines = 3;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    NSStackView* row = [NSStackView new];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 9;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row addArrangedSubview:icon];
    [row addArrangedSubview:label];
    [panel addSubview:row];
    [content addSubview:panel];
    [NSLayoutConstraint activateConstraints:@[
        [panel.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [panel.topAnchor constraintEqualToAnchor:content.topAnchor constant:14],
        [panel.leadingAnchor constraintGreaterThanOrEqualToAnchor:content.leadingAnchor constant:20],
        [panel.trailingAnchor constraintLessThanOrEqualToAnchor:content.trailingAnchor constant:-20],
        [panel.widthAnchor constraintLessThanOrEqualToConstant:620],
        [row.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:13],
        [row.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-13],
        [row.topAnchor constraintEqualToAnchor:panel.topAnchor constant:10],
        [row.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor constant:-10],
        [icon.widthAnchor constraintEqualToConstant:18],
        [icon.heightAnchor constraintEqualToConstant:18]
    ]];
    noticeView = panel;
    noticeLabel = label;
    noticeIcon = icon;
}

void presentNotice(const char* message, uint32_t kind, uint32_t durationMilliseconds, uint64_t generation) {
    if (!noticeView || !noticeLabel || !message) return;
    NSString* text = [NSString stringWithUTF8String:message];
    if (!text.length) return;
    NSString* symbol = kind == 2 ? @"exclamationmark.triangle.fill" : (kind == 1 ? @"checkmark.circle.fill" : @"info.circle.fill");
    noticeIcon.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    noticeIcon.contentTintColor = kind == 2 ? NSColor.systemRedColor : NSColor.secondaryLabelColor;
    noticeLabel.stringValue = text;
    noticeView.hidden = NO;
    noticeView.alphaValue = 1;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(durationMilliseconds) * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (seenNoticeGeneration != generation || !noticeView) return;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext* context) {
            context.duration = 0.18;
            noticeView.animator.alphaValue = 0;
        } completionHandler:^{
            if (seenNoticeGeneration == generation) noticeView.hidden = YES;
        }];
    });
}

void createWindow() {
    if (gameWindow) {
        [gameWindow deminiaturize:nil];
        [gameWindow makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        return;
    }
    mbjfw_native_session_get_geometry(session, &guestWidth, &guestHeight);
    NSSize size = NSMakeSize(960, 960.0 * guestHeight / guestWidth);
    gameWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,size.width,size.height)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    gameWindow.title = @"Minecraft";
    gameWindow.contentMinSize = NSMakeSize(640,360);
    gameWindow.contentAspectRatio = NSMakeSize(16,9);
    gameWindow.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary|NSWindowCollectionBehaviorMoveToActiveSpace;
    gameWindow.acceptsMouseMovedEvents = YES;
    MBJFWNativeInputView* content = [[MBJFWNativeInputView alloc] initWithFrame:NSMakeRect(0,0,size.width,size.height)];
    content.wantsLayer = YES;
    content.layer.backgroundColor = NSColor.blackColor.CGColor;
    gameWindow.contentView = content;
    windowDelegate = [MBJFWNativeWindowDelegate new];
    gameWindow.delegate = windowDelegate;
    [gameWindow center];
    layoutRenderer();
    if (status.state == MBJFWNativeFailed) return;
    createNoticeView(content);
    status.windowID = static_cast<uint32_t>(gameWindow.windowNumber);
    status.state = MBJFWNativeWindowReady;
    [gameWindow makeFirstResponder:content];
    [gameWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    NSEventMask mask = NSEventMaskKeyDown|NSEventMaskKeyUp|NSEventMaskFlagsChanged|
        NSEventMaskMouseMoved|NSEventMaskLeftMouseDown|NSEventMaskLeftMouseUp|NSEventMaskLeftMouseDragged|
        NSEventMaskRightMouseDown|NSEventMaskRightMouseUp|NSEventMaskRightMouseDragged|
        NSEventMaskOtherMouseDown|NSEventMaskOtherMouseUp|NSEventMaskOtherMouseDragged|NSEventMaskScrollWheel;
    eventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask handler:^NSEvent*(NSEvent* event) {
        bool mouseEvent = event.type != NSEventTypeKeyDown && event.type != NSEventTypeKeyUp && event.type != NSEventTypeFlagsChanged;
        // Modifier changes may arrive without an associated NSWindow.
        if (event.window != gameWindow && (mouseEvent || !gameWindow.isKeyWindow)) return event;
        if (mouseEvent && !captured) {
            NSPoint point = [gameWindow.contentView convertPoint:event.locationInWindow fromView:nil];
            NSRect bounds = gameWindow.contentView.bounds;
            bool edge = point.x < 7 || point.x > bounds.size.width-7 || point.y < 7 || point.y > bounds.size.height-7;
            if (event.type == NSEventTypeLeftMouseDown && edge) { nativeResizeGesture=true; releaseAll(); }
            if (nativeResizeGesture || edge) {
                hideMacCursor(false);
                if (event.type == NSEventTypeLeftMouseUp) nativeResizeGesture=false;
                return event;
            }
            if (gameWindow.isKeyWindow && NSPointInRect(point,bounds)) hideMacCursor(true);
        }
        if (event.type != NSEventTypeKeyDown && event.type != NSEventTypeKeyUp && event.type != NSEventTypeFlagsChanged && !captured && heldButtons == 0) {
            NSPoint point = [gameWindow.contentView convertPoint:event.locationInWindow fromView:nil];
            if (!NSPointInRect(point, gameWindow.contentView.bounds)) return event;
        }
        if (event.type == NSEventTypeKeyDown && (event.modifierFlags & NSEventModifierFlagCommand)) {
            if (event.keyCode == 12 || event.keyCode == 13) { requestStop(); return nil; }
            if (event.keyCode == 3 && (event.modifierFlags & NSEventModifierFlagControl)) { [gameWindow toggleFullScreen:nil]; return nil; }
            if (event.keyCode == 18 || event.keyCode == 50) { suppressCapture=true; releaseAll(); ++status.launcherRequests; publish(); return nil; }
            return event;
        }
        if (event.type == NSEventTypeFlagsChanged && (event.modifierFlags & NSEventModifierFlagCommand)) {
            suppressCapture=true; releaseAll(); return event;
        }
        if (!mouseEvent) syncModifiers(event);
        switch (event.type) {
            case NSEventTypeKeyDown: key(event, true); break;
            case NSEventTypeKeyUp: key(event, false); break;
            case NSEventTypeFlagsChanged: {
                if (event.keyCode == 57) { mbjfw_hid_key(57,true); mbjfw_hid_key(57,false); break; }
                break;
            }
            case NSEventTypeScrollWheel:
                scroll(event);
                break;
            default: mouse(event); break;
        }
        return nil;
    }];
    std::fprintf(stderr, "MBJFW native game window ready: pid=%d window=%u guest=%ux%u\n", getpid(), status.windowID, guestWidth, guestHeight);
    publish();
}
void pollControl() {
    if (launcherPID > 1 && kill(launcherPID, 0) != 0) {
        releaseAll();
        kill(getpid(), SIGTERM);
        return;
    }
    uint32_t commands = mbjfw_native_session_take_commands(session);
    if (commands & MBJFWNativeStop) { requestStop(); return; }
    if (commands & MBJFWNativeReleaseInput) { suppressCapture = true; releaseAll(); }
    if (commands & MBJFWNativePrepareInput) {
        mbjfw_hid_start(^{ status.state=MBJFWNativeInputReady; publish(); }, ^{ releaseAll(); status.state=MBJFWNativeFailed; status.errorCode=4; publish(); });
    }
    if (commands & MBJFWNativeShow) {
        std::fprintf(stderr, "MBJFW native Show: hidReady=%d\n", mbjfw_hid_ready());
        dispatch_async(dispatch_get_main_queue(), ^{
            mbjfw_hid_start(^{ createWindow(); }, ^{ releaseAll(); status.state=MBJFWNativeFailed; status.errorCode=4; publish(); });
        });
    }
    if (commands & MBJFWNativeRefreshLayout) layoutRenderer();
    uint32_t noticeKind = 0, noticeDuration = 0;
    std::array<char, 512> noticeText{};
    if (mbjfw_native_session_read_notice(session, &seenNoticeGeneration, &noticeKind, &noticeDuration, noticeText.data(), static_cast<uint32_t>(noticeText.size()))) {
        presentNotice(noticeText.data(), noticeKind, noticeDuration, seenNoticeGeneration);
    }
    mbjfw_hid_poll();
    uint32_t width, height;
    mbjfw_native_session_get_geometry(session, &width, &height);
    const int requestedMode=closestDisplayMode(width,height);
    if (requestedMode != activeDisplayMode && requestedMode != attemptedDisplayMode) {
        attemptedDisplayMode=requestedMode;
        releaseAll();
        if (setResizableDisplayMode) setResizableDisplayMode(requestedMode);
        activeDisplayMode=requestedMode;
        guestWidth=guestDisplayModes[requestedMode].width;
        guestHeight=guestDisplayModes[requestedMode].height;
        status.errorCode=0;
        std::fprintf(stderr,"MBJFW guest display mode request: %ux%u id=%d native-config=%s\n",guestWidth,guestHeight,requestedMode,setResizableDisplayMode ? "available" : "logical-override");
        layoutRenderer();
    }
    bool requested = mbjfw_native_session_capture_requested(session);
    if (requested != guestCapture) {
        guestCapture = requested;
        if (guestCapture) capture(); else releaseCapture();
    }
    publish();
}
void* startNativeThread(void*) {
    const char* name = std::getenv("MBJFW_NATIVE_SESSION");
    if (!name || !*name) return nullptr;
    showWindow = reinterpret_cast<ShowWindow>(dlsym(RTLD_DEFAULT,"android_showOpenglesWindow"));
    auto hasFrame = reinterpret_cast<HasFrame>(dlsym(RTLD_DEFAULT,"android_hasGuestPostedAFrame"));
    if (!showWindow || !hasFrame) return nullptr; // launcher/crashpad, not QEMU
    setResizableDisplayMode=reinterpret_cast<SetResizableDisplayMode>(dlsym(RTLD_DEFAULT,"setResizableActiveConfigId"));
    session = mbjfw_native_session_open(name);
    if (!session) return nullptr;
    {
        uint32_t width=1280,height=720;
        mbjfw_native_session_get_geometry(session,&width,&height);
        activeDisplayMode=closestDisplayMode(width,height);
        guestWidth=guestDisplayModes[activeDisplayMode].width;
        guestHeight=guestDisplayModes[activeDisplayMode].height;
    }
    status.processID = getpid();
    const char* parent = std::getenv("MBJFW_PARENT_PID");
    launcherPID = parent ? static_cast<pid_t>(std::strtol(parent,nullptr,10)) : getppid();
    std::fprintf(stderr, "MBJFW native host attached to QEMU pid=%d\n",getpid());
    for (int attempt=0; attempt<600; ++attempt) {
        if (launcherPID > 1 && kill(launcherPID, 0) != 0) { kill(getpid(), SIGTERM); return nullptr; }
        if (hasFrame()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                status.state = MBJFWNativeRendererReady;
                sessionActivity = [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep reason:@"Running the Minecraft virtual machine"];
                publish();
                controlTimer = [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer*){ pollControl(); }];
                [[NSRunLoop mainRunLoop] addTimer:controlTimer forMode:NSRunLoopCommonModes];
            });
            return nullptr;
        }
        usleep(200000);
    }
    status.state = MBJFWNativeFailed; status.errorCode = 1; publish();
    return nullptr;
}
__attribute__((constructor)) void initializeNativeHost() {
    if (!std::getenv("MBJFW_NATIVE_SESSION")) return;
    pthread_t thread;
    if (pthread_create(&thread,nullptr,startNativeThread,nullptr)==0) pthread_detach(thread);
}
}

#import "UHIDTransport.h"
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <algorithm>
#include <cstring>

namespace {
NSTask* task;
NSPipe* commands;
NSPipe* replies;
NSMutableData* replyBuffer;
void (^onReady)(void);
void (^onFailure)(void);
bool ready=false, failed=false;
uint8_t keys[29]{};
double lastReply=0, lastPing=0, lastPoll=0;
unsigned usage(unsigned short code) {
    static const uint8_t map[128]={
        4,22,7,9,11,10,29,27,6,25,100,5,20,26,8,21,
        28,23,30,31,32,33,35,34,46,38,36,45,37,39,48,18,
        24,47,12,19,40,15,13,52,14,51,49,54,56,17,16,55,
        43,44,53,42,0,41,231,227,225,57,226,224,229,230,228,0,
        0,99,0,85,0,87,0,83,0,0,0,84,88,0,86,0,
        0,103,98,89,90,91,92,93,94,95,0,96,97,0,0,0,
        62,63,64,60,65,66,0,68,0,104,107,105,0,67,0,69,
        0,106,73,74,75,76,61,77,59,78,58,80,79,81,82,0
    };
    return code<128?map[code]:0;
}
void fail() {
    if (failed) return;
    failed=true; ready=false;
    @try { [commands.fileHandleForWriting closeFile]; } @catch (NSException*) {}
    if (task.running) [task terminate];
    if (onFailure) onFailure();
}
void send(const uint8_t (&packet)[32]) {
    if (!ready || failed) return;
    ssize_t written;
    do { written=write(commands.fileHandleForWriting.fileDescriptor,packet,sizeof(packet)); } while (written<0 && errno==EINTR);
    // Never retain an unbounded event queue or block AppKit behind a dead device.
    if (written!=sizeof(packet)) fail();
}
void receive(NSData* data) {
    if (failed) return;
    [replyBuffer appendData:data];
    const uint8_t* bytes=(const uint8_t*)replyBuffer.bytes;
    NSUInteger consumed=0;
    for (NSUInteger i=0;i<replyBuffer.length;++i) {
        if (bytes[i]!='\n') continue;
        NSString* line=[[NSString alloc] initWithBytes:bytes+consumed length:i-consumed encoding:NSUTF8StringEncoding];
        consumed=i+1;
        if ([line isEqualToString:@"MBJFW_UHID_READY"]) {
            ready=true; lastReply=NSDate.timeIntervalSinceReferenceDate;
            if (onReady) onReady();
        } else if ([line isEqualToString:@"MBJFW_UHID_PONG"]) lastReply=NSDate.timeIntervalSinceReferenceDate;
        else fail();
    }
    if (consumed) [replyBuffer replaceBytesInRange:NSMakeRange(0,consumed) withBytes:nullptr length:0];
    if (replyBuffer.length>1024) fail();
}
}
bool mbjfw_hid_ready() { return ready && !failed; }
void mbjfw_hid_start(void (^success)(void),void (^failure)(void)) {
    if (task) { if (ready) success(); return; }
    onReady=[success copy]; onFailure=[failure copy];
    const char* adb=getenv("MBJFW_ADB_PATH");
    const char* serial=getenv("MBJFW_DEVICE_SERIAL");
    if (!adb || !serial) { fail(); return; }
    commands=[NSPipe pipe]; replies=[NSPipe pipe]; replyBuffer=[NSMutableData data];
    task=[NSTask new];
    task.executableURL=[NSURL fileURLWithPath:@(adb)];
    task.arguments=@[@"-s",@(serial),@"shell",@"-T",@"/data/local/tmp/mbjfw-hid"];
    // The QEMU-injected library must not be injected into adb or its children.
    NSMutableDictionary* environment=[NSProcessInfo.processInfo.environment mutableCopy];
    [environment removeObjectForKey:@"DYLD_INSERT_LIBRARIES"];
    task.environment=environment;
    task.standardInput=commands; task.standardOutput=replies;
    task.standardError=NSFileHandle.fileHandleWithStandardError;
    replies.fileHandleForReading.readabilityHandler=^(NSFileHandle* handle) {
        NSData* data=handle.availableData;
        if (!data.length) handle.readabilityHandler=nil;
        dispatch_async(dispatch_get_main_queue(),^{ if (data.length) receive(data); else fail(); });
    };
    task.terminationHandler=^(NSTask*){ dispatch_async(dispatch_get_main_queue(),^{ fail(); }); };
    NSError* error=nil;
    if (![task launchAndReturnError:&error]) { fail(); return; }
    int descriptor=commands.fileHandleForWriting.fileDescriptor;
    fcntl(descriptor,F_SETFL,fcntl(descriptor,F_GETFL)|O_NONBLOCK);
    int noSignal=1; fcntl(descriptor,F_SETNOSIGPIPE,noSignal);
    lastReply=NSDate.timeIntervalSinceReferenceDate;
}
void mbjfw_hid_key(unsigned short code,bool down) {
    unsigned id=usage(code); if (!id || id>=232) return;
    uint8_t mask=1u<<(id%8);
    if (down) keys[id/8]|=mask; else keys[id/8]&=~mask;
    uint8_t packet[32]{}; memcpy(packet+2,keys,sizeof(keys)); send(packet);
}
void mbjfw_hid_mouse(int x,int y,unsigned buttons,int wheelX,int wheelY) {
    do {
        int dx=std::clamp(x,-32767,32767),dy=std::clamp(y,-32767,32767);
        int wx=std::clamp(wheelX,-127,127),wy=std::clamp(wheelY,-127,127);
        uint8_t packet[32]{}; packet[0]=1; packet[2]=buttons&31;
        packet[3]=dx; packet[4]=dx>>8; packet[5]=dy; packet[6]=dy>>8;
        packet[7]=wy; packet[8]=wx; send(packet);
        x-=dx; y-=dy; wheelX-=wx; wheelY-=wy;
    } while (x || y || wheelX || wheelY);
}
void mbjfw_hid_pointer(int x,int y,int extent,unsigned buttons,bool inRange,int wheelX,int wheelY) {
    // Android's absolute mouse viewport uses the larger display dimension for
    // both axes. Keep the reports square, matching InputReader's calibration.
    x=std::clamp(x,0,extent-1)*32767/std::max(1,extent-1);
    y=std::clamp(y,0,extent-1)*32767/std::max(1,extent-1);
    uint8_t packet[32]{}; packet[0]=3; packet[2]=(buttons&31)|(inRange?128:0);
    packet[3]=x; packet[4]=x>>8; packet[5]=y; packet[6]=y>>8;
    packet[7]=std::clamp(wheelY,-127,127); packet[8]=std::clamp(wheelX,-127,127); send(packet);
}
void mbjfw_hid_release() {
    memset(keys,0,sizeof(keys)); uint8_t packet[32]{}; send(packet); mbjfw_hid_mouse(0,0,0); mbjfw_hid_pointer(0,0,1,0,false);
}
void mbjfw_hid_poll() {
    if (!task || failed) return;
    double now=NSDate.timeIntervalSinceReferenceDate;
    // A Mac wake or debugger pause must not be mistaken for a broken input pipe.
    if (lastPoll && now-lastPoll>2) lastReply=now;
    lastPoll=now;
    if (now-lastReply>5) { fail(); return; }
    if (ready && now-lastPing>1) { uint8_t packet[32]{}; packet[0]=2; send(packet); lastPing=now; }
}

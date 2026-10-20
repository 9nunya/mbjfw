// ARM64 Android UHID endpoint. No Android framework, root, JNI or libc required.
// stdin carries atomic 32-byte reports; EOF destroys all kernel HID devices.
typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;
typedef long i64;
void* memset(void* memory, int value, unsigned long count) {
    volatile u8* bytes=(volatile u8*)memory;
    for (unsigned long i=0;i<count;++i) bytes[i]=(u8)value;
    return memory;
}
static i64 call(i64 n, i64 a, i64 b, i64 c, i64 d) {
    register i64 x8 __asm__("x8") = n;
    register i64 x0 __asm__("x0") = a;
    register i64 x1 __asm__("x1") = b;
    register i64 x2 __asm__("x2") = c;
    register i64 x3 __asm__("x3") = d;
    __asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3) : "memory", "cc");
    return x0;
}
static void copy(u8* dst, const u8* src, u32 count) { for (u32 i=0;i<count;++i) dst[i]=src[i]; }
static void little16(u8* p, u16 v) { p[0]=v; p[1]=v>>8; }
static void little32(u8* p, u32 v) { little16(p,v); little16(p+2,v>>16); }
static void message(const char* text, u32 length) { call(64,1,(i64)text,length,0); }
static const u8 keyboard[] = {
    0x05,0x01,0x09,0x06,0xa1,0x01, // Generic Desktop / Keyboard
    0x05,0x07,0x19,0x00,0x29,0xe7, // Keyboard usages 0..231, including modifiers
    0x15,0x00,0x25,0x01,0x75,0x01,0x95,0xe8,0x81,0x02,0xc0
};
static const u8 mouse[] = {
    0x05,0x01,0x09,0x02,0xa1,0x01,0x09,0x01,0xa1,0x00,
    0x05,0x09,0x19,0x01,0x29,0x05,0x15,0x00,0x25,0x01,0x95,0x05,0x75,0x01,0x81,0x02,
    0x95,0x01,0x75,0x03,0x81,0x03,
    0x05,0x01,0x09,0x30,0x09,0x31,0x16,0x01,0x80,0x26,0xff,0x7f,0x75,0x10,0x95,0x02,0x81,0x06,
    0x09,0x38,0x15,0x81,0x25,0x7f,0x75,0x08,0x95,0x01,0x81,0x06,
    0x05,0x0c,0x0a,0x38,0x02,0x95,0x01,0x81,0x06,0xc0,0xc0
};
// Absolute USB puck: BTN_TOOL_MOUSE + ABS_X/Y gives Android a real mouse
// hover stream, unlike the emulator dual-mode device's touchpad coordinates.
static const u8 menuMouse[] = {
    0x05,0x0d,0x09,0x01,0xa1,0x01, // Digitizer -> INPUT_PROP_POINTER
    0x05,0x01,0x09,0x02,0xa1,0x00, // Mouse physical collection for BTN_LEFT..EXTRA
    0x05,0x09,0x19,0x01,0x29,0x05,0x15,0x00,0x25,0x01,0x75,0x01,0x95,0x05,0x81,0x02,
    0x75,0x01,0x95,0x01,0x81,0x03,0xc0,
    0x05,0x0d,0x09,0x21,0xa1,0x00, // Puck -> BTN_TOOL_MOUSE
    0x09,0x42,0x75,0x01,0x95,0x01,0x81,0x02, // Tip Switch capability lets EventHub identify ABS input
    0x09,0x32,0x81,0x02, // In Range (bit 7)
    0x05,0x01,0x09,0x30,0x09,0x31,0x15,0x00,0x26,0xff,0x7f,0x75,0x10,0x95,0x02,0x81,0x02,
    0x09,0x38,0x15,0x81,0x25,0x7f,0x75,0x08,0x95,0x01,0x81,0x06,
    0x05,0x0c,0x0a,0x38,0x02,0x95,0x01,0x81,0x06,0xc0,0xc0
};
static int create(const char* name, u32 nameLength, const u8* descriptor, u16 length, u32 product) {
    int fd=(int)call(56,-100,(i64)"/dev/uhid",2|02000000,0);
    if (fd<0) return fd;
    u8 event[4376]={0};
    little32(event,11); // UHID_CREATE2
    copy(event+4,(const u8*)name,nameLength);
    copy(event+132,(const u8*)"mbjfw/desktop",13);
    little16(event+260,length);
    little16(event+262,0x03); // BUS_USB: the kernel HID subsystem owns input parsing
    little32(event+264,0x1209); little32(event+268,product); little32(event+272,1);
    copy(event+280,descriptor,length);
    if (call(64,fd,(i64)event,sizeof(event),0)!=(i64)sizeof(event)) { call(57,fd,0,0,0); return -1; }
    // CREATE2 is asynchronous. Wait for UHID_START before acknowledging readiness.
    do {
        i64 count=call(63,fd,(i64)event,sizeof(event),0);
        if (count<4) { call(57,fd,0,0,0); return -1; }
        if (event[0]==2) break;
    } while (1);
    return fd;
}
static int input(int fd, const u8* report, u16 length) {
    u8 event[38]={0}; little32(event,12); little16(event+4,length); copy(event+6,report,length);
    return call(64,fd,(i64)event,6+length,0)==6+length;
}
void _start(void) {
    // Parent death and a closed stdin both remove the devices, releasing all keys.
    call(167,1,15,0,0); // PR_SET_PDEATHSIG SIGTERM
    int keys=create("Mac Keyboard",12,keyboard,sizeof(keyboard),0x4d01);
    int pointer=create("Mac Mouse",9,mouse,sizeof(mouse),0x4d02);
    int menu=create("Mac Menu Mouse",14,menuMouse,sizeof(menuMouse),0x4d03);
    if (keys<0 || pointer<0 || menu<0) { message("MBJFW_UHID_ERROR\n",17); call(94,1,0,0,0); }
    message("MBJFW_UHID_READY\n",17);
    u8 packet[32]; int failed=0;
    for (;;) {
        u32 offset=0;
        while (offset<sizeof(packet)) {
            i64 count=call(63,0,(i64)(packet+offset),sizeof(packet)-offset,0);
            if (count==-4) continue; // EINTR
            if (count<=0) goto finished;
            offset+=(u32)count;
        }
        if (packet[0]==0) failed=!input(keys,packet+2,29);
        else if (packet[0]==1) failed=!input(pointer,packet+2,7);
        else if (packet[0]==3) failed=!input(menu,packet+2,7);
        else if (packet[0]==2) message("MBJFW_UHID_PONG\n",16);
        else failed=1;
        if (failed) break;
    }
finished:
    call(57,keys,0,0,0); call(57,pointer,0,0,0); call(57,menu,0,0,0);
    call(94,failed,0,0,0);
}

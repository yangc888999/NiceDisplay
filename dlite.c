// dlite.c — 轻量显示器控制工具（自研，零第三方依赖）
// 能力: DDC 亮度/音量读写 + 显示器启用/禁用(真·断开/连接) + 主屏查询
//
// 用法:
//   dlite list                            列出显示器(ID/UUID/主屏/DDC 通道)
//   dlite ddc get <id|uuid> <vcp>         读 VCP（0x10 亮度 / 0x62 音量）
//   dlite ddc set <id|uuid> <vcp> <值>    写 VCP
//   dlite disable <id|uuid> [--revert N]  真·断开显示器；--revert N 表示 N 秒后自动连回
//   dlite enable  <id|uuid>               连回显示器
//   dlite restore                         连回所有在线显示器（应急恢复）
//
// 编译: clang -O2 -o dlite dlite.c -framework CoreGraphics -framework IOKit -framework Foundation
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <ctype.h>
#include <unistd.h>
#include <dlfcn.h>
#include <signal.h>
#include <spawn.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/graphics/IOGraphicsLib.h>
#include <sys/stat.h>

extern char **environ;

// ============================ 私有符号绑定 ============================
typedef CFDictionaryRef (*CDInfo_t)(CGDirectDisplayID);
typedef CFTypeRef (*IOAVCreateSvc_t)(CFAllocatorRef, io_service_t);
typedef IOReturn (*IOAVRead_t)(CFTypeRef, uint32_t, uint32_t, void *, uint32_t);
typedef IOReturn (*IOAVWrite_t)(CFTypeRef, uint32_t, uint32_t, void *, uint32_t);
typedef CGError (*CGSConfigureDisplayEnabled_t)(CGDisplayConfigRef, CGDirectDisplayID, bool);

static CDInfo_t        p_CDInfo;
static IOAVCreateSvc_t p_Create;
static IOAVRead_t      p_Read;
static IOAVWrite_t     p_Write;
static CGSConfigureDisplayEnabled_t p_CfgEnabled;

static void load_symbols(void) {
    dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY);
    dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    p_CDInfo    = (CDInfo_t)dlsym(RTLD_DEFAULT, "CoreDisplay_DisplayCreateInfoDictionary");
    p_Create    = (IOAVCreateSvc_t)dlsym(RTLD_DEFAULT, "IOAVServiceCreateWithService");
    p_Read      = (IOAVRead_t)dlsym(RTLD_DEFAULT, "IOAVServiceReadI2C");
    p_Write     = (IOAVWrite_t)dlsym(RTLD_DEFAULT, "IOAVServiceWriteI2C");
    p_CfgEnabled = (CGSConfigureDisplayEnabled_t)dlsym(RTLD_DEFAULT, "CGSConfigureDisplayEnabled");
}

// ============================ DDC 层 ============================
#define DDC_CHIP_ADDR   0x37
#define DDC_INPUT_ADDR  0x51
#define DDC_BUF         256
#define DDC_WAIT_US     10000
#define DDC_ITER        3

static int dispext_index(const char *path) {
    const char *p = path;
    while ((p = strstr(p, "dispext")) != NULL) {
        if (isdigit((unsigned char)p[7])) return p[7] - '0';
        p += 7;
    }
    return -1;
}

static CFTypeRef service_for_display(CGDirectDisplayID did, int *outIdx) {
    if (outIdx) *outIdx = -1;
    CFDictionaryRef info = p_CDInfo(did);
    if (!info) return NULL;
    CFTypeRef locRef = CFDictionaryGetValue(info, CFSTR("IODisplayLocation"));
    if (!locRef || CFGetTypeID(locRef) != CFStringGetTypeID()) return NULL;
    char loc[512] = {0};
    CFStringGetCString(locRef, loc, sizeof loc, kCFStringEncodingUTF8);
    int want = dispext_index(loc);
    if (outIdx) *outIdx = want;

    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &it) != KERN_SUCCESS)
        return NULL;
    io_service_t s; CFTypeRef found = NULL;
    while ((s = IOIteratorNext(it))) {
        io_string_t path;
        IORegistryEntryGetPath(s, kIOServicePlane, path);
        if (dispext_index(path) == want) found = p_Create(kCFAllocatorDefault, s);
        IOObjectRelease(s);
        if (found) break;
    }
    IOObjectRelease(it);
    return found;
}

// 显示器名在 Apple Silicon 上位于 USB-C 端口传输节点（IOPortTransportStateDisplayPort），
// 可通过 ProductID + SerialNumber 与显示器的 model/serial 对上。
typedef struct { unsigned pid, serial; char name[128]; } PortNameEnt;

static int collect_port_names(PortNameEnt *out, int max) {
    int n = 0;
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                     IOServiceMatching("IOPortTransportStateDisplayPort"), &it) != KERN_SUCCESS)
        return 0;
    io_registry_entry_t s;
    while ((s = IOIteratorNext(it))) {
        if (n >= max) { IOObjectRelease(s); continue; }
        CFTypeRef pnRef = IORegistryEntryCreateCFProperty(s, CFSTR("ProductName"), kCFAllocatorDefault, 0);
        if (pnRef && CFGetTypeID(pnRef) == CFStringGetTypeID()) {
            CFStringGetCString(pnRef, out[n].name, (CFIndex)sizeof out[n].name, kCFStringEncodingUTF8);
            unsigned pid = 0, ser = 0;
            CFTypeRef a = IORegistryEntryCreateCFProperty(s, CFSTR("ProductID"), kCFAllocatorDefault, 0);
            CFTypeRef b = IORegistryEntryCreateCFProperty(s, CFSTR("SerialNumber"), kCFAllocatorDefault, 0);
            if (a && CFGetTypeID(a) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)a, kCFNumberIntType, &pid);
            if (b && CFGetTypeID(b) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)b, kCFNumberIntType, &ser);
            if (a) CFRelease(a);
            if (b) CFRelease(b);
            out[n].pid = pid;
            out[n].serial = ser;
            n++;
        }
        if (pnRef) CFRelease(pnRef);
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
    return n;
}

// 取显示器产品名：优先端口传输节点（按 model+serial 匹配），退回 IOKit 本地化名 / EDID 描述符
static void display_name(CGDirectDisplayID did, char *buf, size_t n) {
    buf[0] = 0;

    PortNameEnt ports[16];
    int pc = collect_port_names(ports, 16);
    unsigned model = (unsigned)CGDisplayModelNumber(did);
    unsigned serial = (unsigned)CGDisplaySerialNumber(did);
    for (int i = 0; i < pc; i++) {
        if (ports[i].name[0] && ports[i].pid == model && ports[i].serial == serial) {
            snprintf(buf, n, "%s", ports[i].name);
            return;
        }
    }

    CFDictionaryRef info = p_CDInfo(did);
    if (!info) return;
    CFTypeRef locRef = CFDictionaryGetValue(info, CFSTR("IODisplayLocation"));
    if (!locRef || CFGetTypeID(locRef) != CFStringGetTypeID()) return;
    char l[512] = {0};
    CFStringGetCString(locRef, l, sizeof l, kCFStringEncodingUTF8);
    io_service_t fb = IORegistryEntryFromPath(kIOMainPortDefault, l);
    if (!fb) return;

    CFDictionaryRef dinfo = IODisplayCreateInfoDictionary(fb, kIODisplayOnlyPreferredName);
    if (dinfo) {
        CFDictionaryRef names = CFDictionaryGetValue(dinfo, CFSTR(kDisplayProductName));
        if (names && CFGetTypeID(names) == CFDictionaryGetTypeID() && CFDictionaryGetCount(names) > 0) {
            const void *keys[1], *vals[1];
            CFDictionaryGetKeysAndValues(names, keys, vals);
            if (CFGetTypeID(vals[0]) == CFStringGetTypeID())
                CFStringGetCString(vals[0], buf, (CFIndex)n, kCFStringEncodingUTF8);
        }
        CFRelease(dinfo);
    }

    // 兜底：EDID 的 0xFC 描述符
    if (buf[0] == 0) {
        CFTypeRef edid = IORegistryEntryCreateCFProperty(fb, CFSTR("EDID"), kCFAllocatorDefault, 0);
        if (edid && CFGetTypeID(edid) == CFDataGetTypeID()) {
            CFDataRef d = (CFDataRef)edid;
            const uint8_t *b = CFDataGetBytePtr(d);
            CFIndex len = CFDataGetLength(d);
            for (int off = 54; off + 18 <= len; off += 18) {
                if (b[off] == 0 && b[off + 1] == 0 && b[off + 2] == 0 && b[off + 3] == 0xFC) {
                    char tmp[14]; int k = 0;
                    for (int j = 5; j < 18 && k < 13; j++) {
                        uint8_t c = b[off + j];
                        if (c == 0x0A || c == 0x00) break;
                        tmp[k++] = (char)c;
                    }
                    while (k > 0 && tmp[k - 1] == ' ') k--;
                    tmp[k] = 0;
                    snprintf(buf, n, "%s", tmp);
                    break;
                }
            }
        }
        if (edid) CFRelease(edid);
    }
    IOObjectRelease(fb);
}

static int bytes_used(const uint8_t *d, int n) {
    int used = 0;
    for (int i = 0; i < n; i++) if (d[i] != 0) used = i + 1;
    return used;
}
static int ddc_get(CFTypeRef svc, uint8_t vcp, uint16_t *cur, uint16_t *max) {
    uint8_t buf[DDC_BUF];
    memset(buf, 0, sizeof buf);
    buf[0] = 0x82; buf[1] = 0x01; buf[2] = vcp;
    buf[3] = (uint8_t)(0x6E ^ buf[0] ^ buf[1] ^ buf[2] ^ buf[3]);
    IOReturn ret = kIOReturnSuccess;
    for (int i = 0; i < DDC_ITER; i++) {
        usleep(DDC_WAIT_US);
        ret = p_Write(svc, DDC_CHIP_ADDR, DDC_INPUT_ADDR, buf, (uint32_t)bytes_used(buf, 8));
        if (ret == kIOReturnSuccess) break;
    }
    if (ret != kIOReturnSuccess) return -1;
    memset(buf, 0, sizeof buf);
    usleep(DDC_WAIT_US);
    ret = p_Read(svc, DDC_CHIP_ADDR, DDC_INPUT_ADDR, buf, 12);
    if (ret != kIOReturnSuccess) return -2;
    if (buf[0] == 0) return -3;
    if (buf[3] != 0x00) return -4;
    if (max) *max = (uint16_t)((buf[6] << 8) | buf[7]);
    if (cur) *cur = (uint16_t)((buf[8] << 8) | buf[9]);
    return 0;
}

// 只读探测私有/多字节 VCP：把给定 hex 字节作为 VCP 字段（支持 1~3 字节）发读请求，打印原始回包。
static int ddc_probe_ext(CFTypeRef svc, const char *hex) {
    uint8_t vcp[3]; int vcpn = 0;
    for (const char *p = hex; *p && vcpn < 3; ) {
        if (!isxdigit((unsigned char)*p)) { p++; continue; }
        if (!isxdigit((unsigned char)p[1])) { printf("  非法 hex: %s\n", hex); return -1; }
        char two[3] = { p[0], p[1], 0 };
        vcp[vcpn++] = (uint8_t)strtol(two, NULL, 16); p += 2;
    }
    if (vcpn == 0) { printf("  请提供 hex\n"); return -1; }
    int plen = 1 + vcpn;          // opcode(0x01) + vcp 字节
    uint8_t buf[DDC_BUF]; memset(buf, 0, sizeof buf);
    buf[0] = (uint8_t)(0x80 | plen);
    buf[1] = 0x01;                // VCP Read Request
    for (int i = 0; i < vcpn; i++) buf[2 + i] = vcp[i];
    uint8_t sum = 0x6E;
    for (int i = 0; i < 2 + vcpn; i++) sum ^= buf[i];
    buf[2 + vcpn] = sum;

    printf("  请求 vcp字节数=%d 内容=", vcpn);
    for (int i = 0; i < vcpn; i++) printf("%02X ", vcp[i]);
    printf("\n");

    IOReturn ret = kIOReturnSuccess;
    for (int i = 0; i < DDC_ITER; i++) {
        usleep(DDC_WAIT_US);
        ret = p_Write(svc, DDC_CHIP_ADDR, DDC_INPUT_ADDR, buf, (uint32_t)bytes_used(buf, 8));
        if (ret == kIOReturnSuccess) break;
    }
    if (ret != kIOReturnSuccess) { printf("  写失败\n"); return -1; }
    usleep(DDC_WAIT_US);
    uint8_t rep[20]; memset(rep, 0, sizeof rep);
    ret = p_Read(svc, DDC_CHIP_ADDR, DDC_INPUT_ADDR, rep, 16);
    if (ret != kIOReturnSuccess) { printf("  读失败\n"); return -2; }
    printf("  回包原始: ");
    for (int i = 0; i < 16; i++) printf("%02X ", rep[i]);
    printf("\n");
    // 尝试按标准回包解析（[3]=result [4]=vcp ... [6..7]=max [8..9]=cur）
    if (rep[2] == 0x02) {
        printf("  回包 opcode=0x02(VCP回读) result=0x%02X  VCP回显=%02X  max=%u  cur=%u\n",
               rep[3], rep[4], (rep[6] << 8) | rep[7], (rep[8] << 8) | rep[9]);
    }
    return 0;
}

static int ddc_set(CFTypeRef svc, uint8_t vcp, uint16_t value) {
    uint8_t buf[DDC_BUF];
    memset(buf, 0, sizeof buf);
    buf[0] = 0x84; buf[1] = 0x03; buf[2] = vcp;
    buf[3] = (uint8_t)(value >> 8);
    buf[4] = (uint8_t)(value & 0xFF);
    buf[5] = (uint8_t)(0x6E ^ DDC_INPUT_ADDR ^ buf[0] ^ buf[1] ^ buf[2] ^ buf[3] ^ buf[4]);
    IOReturn ret = kIOReturnSuccess;
    for (int i = 0; i < DDC_ITER; i++) {
        usleep(DDC_WAIT_US);
        ret = p_Write(svc, DDC_CHIP_ADDR, DDC_INPUT_ADDR, buf, (uint32_t)bytes_used(buf, 8));
        if (ret == kIOReturnSuccess) return 0;
    }
    return -1;
}

// ============================ 显示器工具 ============================
typedef struct {
    CGDirectDisplayID id;
    char uuid[64];
    uint32_t vendor, model;
    int main, active, online, dispext;
} DispInfo;

static void fill_info(CGDirectDisplayID did, DispInfo *out) {
    memset(out, 0, sizeof *out);
    out->id = did;
    out->main = CGDisplayIsMain(did);
    out->active = CGDisplayIsActive(did);
    out->online = CGDisplayIsOnline(did);
    out->vendor = CGDisplayVendorNumber(did);
    out->model = CGDisplayModelNumber(did);
    out->dispext = -1;
    CFDictionaryRef info = p_CDInfo(did);
    if (info) {
        CFTypeRef u = CFDictionaryGetValue(info, CFSTR("kCGDisplayUUID"));
        if (u && CFGetTypeID(u) == CFStringGetTypeID())
            CFStringGetCString(u, out->uuid, sizeof out->uuid, kCFStringEncodingUTF8);
        CFTypeRef loc = CFDictionaryGetValue(info, CFSTR("IODisplayLocation"));
        if (loc && CFGetTypeID(loc) == CFStringGetTypeID()) {
            char l[512] = {0};
            CFStringGetCString(loc, l, sizeof l, kCFStringEncodingUTF8);
            out->dispext = dispext_index(l);
        }
    }
}

// 按 ID 或 UUID 找显示器。
// 注意：纯数字一律按 CGDirectDisplayID 解释——断开后的屏会从在线列表消失，但 ID 仍然可用；
// 若让数字fall through 到 UUID 前缀匹配，短数字会误撞别的屏 UUID（曾因此操作错屏）。
static int resolve_target(const char *arg, CGDirectDisplayID *out) {
    if (!arg || !*arg) return -1;
    int all_digits = 1;
    for (const char *p = arg; *p; p++)
        if (!isdigit((unsigned char)*p)) { all_digits = 0; break; }
    if (all_digits) { *out = (CGDirectDisplayID)strtoul(arg, NULL, 10); return 0; }

    if (strlen(arg) < 8) return -1;   // UUID 前缀过短易误撞，直接拒绝
    CGDirectDisplayID online[16]; uint32_t n = 0;
    CGGetOnlineDisplayList(16, online, &n);
    for (uint32_t i = 0; i < n; i++) {
        DispInfo di; fill_info(online[i], &di);
        if (di.uuid[0] && !strncasecmp(di.uuid, arg, strlen(arg))) { *out = online[i]; return 0; }
    }
    return -1;
}

// ---- 被断开显示器的状态记录（让 restore 在屏幕已消失时也能找回目标）----
static const char *state_path(void) {
    static char p[512];
    const char *h = getenv("HOME");
    snprintf(p, sizeof p, "%s/.dlite-disabled", h ? h : "/tmp");
    return p;
}
static int state_load(CGDirectDisplayID *ids, int max) {
    FILE *f = fopen(state_path(), "r");
    if (!f) return 0;
    int n = 0; unsigned v;
    while (n < max && fscanf(f, "%u", &v) == 1) {
        int dup = 0;
        for (int i = 0; i < n; i++) if (ids[i] == (CGDirectDisplayID)v) dup = 1;
        if (!dup) ids[n++] = (CGDirectDisplayID)v;
    }
    fclose(f);
    return n;
}
static void state_save(CGDirectDisplayID *ids, int n) {
    FILE *f = fopen(state_path(), "w");
    if (!f) return;
    for (int i = 0; i < n; i++) fprintf(f, "%u\n", ids[i]);
    fclose(f);
}
static void state_add(CGDirectDisplayID did) {
    CGDirectDisplayID ids[32]; int n = state_load(ids, 32);
    for (int i = 0; i < n; i++) if (ids[i] == did) return;
    if (n < 32) ids[n++] = did;
    state_save(ids, n);
}
static void state_remove(CGDirectDisplayID did) {
    CGDirectDisplayID ids[32]; int n = state_load(ids, 32);
    int m = 0;
    for (int i = 0; i < n; i++) if (ids[i] != did) ids[m++] = ids[i];
    state_save(ids, m);
}

static long parse_num(const char *s) { return strtol(s, NULL, 0); }

static uint32_t active_count(void) {
    CGDirectDisplayID a[16]; uint32_t n = 0;
    CGGetActiveDisplayList(16, a, &n);
    return n;
}

// 启用/禁用显示器：必须在显示器重配置事务里调用私有 CGSConfigureDisplayEnabled
static int set_display_enabled(CGDirectDisplayID did, int enable) {
    if (!p_CfgEnabled) { fprintf(stderr, "本机不提供 CGSConfigureDisplayEnabled\n"); return -1; }
    CGDisplayConfigRef cfg = NULL;
    CGError e = CGBeginDisplayConfiguration(&cfg);
    if (e != kCGErrorSuccess || !cfg) { fprintf(stderr, "CGBeginDisplayConfiguration 失败 e=%d\n", (int)e); return -1; }
    e = p_CfgEnabled(cfg, did, enable ? true : false);
    if (e != kCGErrorSuccess) {
        fprintf(stderr, "CGSConfigureDisplayEnabled 失败 e=%d，已回滚\n", (int)e);
        CGCancelDisplayConfiguration(cfg);
        return -1;
    }
    // 仅限本次会话，重启/注销自动恢复，避免留下持久坏状态
    e = CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
    if (e != kCGErrorSuccess) { fprintf(stderr, "CGCompleteDisplayConfiguration 失败 e=%d\n", (int)e); return -1; }
    return 0;
}

// ============================ 显示模式 / 主屏 ============================
static int mode_is_hidpi(CGDisplayModeRef m) {
    size_t w = CGDisplayModeGetWidth(m), h = CGDisplayModeGetHeight(m);
    size_t pw = CGDisplayModeGetPixelWidth(m), ph = CGDisplayModeGetPixelHeight(m);
    return (w > 0 && h > 0 && pw >= 2 * w && ph >= 2 * h);
}

static int mode_same(CGDisplayModeRef a, CGDisplayModeRef b) {
    if (!a || !b) return 0;
    double ra = CGDisplayModeGetRefreshRate(a), rb = CGDisplayModeGetRefreshRate(b);
    return CGDisplayModeGetWidth(a) == CGDisplayModeGetWidth(b)
        && CGDisplayModeGetHeight(a) == CGDisplayModeGetHeight(b)
        && CGDisplayModeGetPixelWidth(a) == CGDisplayModeGetPixelWidth(b)
        && CGDisplayModeGetPixelHeight(a) == CGDisplayModeGetPixelHeight(b)
        && (ra > rb ? ra - rb : rb - ra) < 0.5;
}

// 规格串: 1920x1080 | 1920x1080@60 | 1920x1080@60:hidpi | 1920x1080:lodpi
typedef struct { int w, h; double hz; int hidpi; } ModeSpec;

static int parse_mode_spec(const char *s, ModeSpec *sp) {
    memset(sp, 0, sizeof *sp);
    sp->hz = -1; sp->hidpi = -1;
    char tmp[128];
    snprintf(tmp, sizeof tmp, "%s", s);
    char *colon = strchr(tmp, ':');
    if (colon) {
        *colon = 0;
        if (!strcasecmp(colon + 1, "hidpi")) sp->hidpi = 1;
        else if (!strcasecmp(colon + 1, "lodpi")) sp->hidpi = 0;
        else return -1;
    }
    char *at = strchr(tmp, '@');
    if (at) { *at = 0; sp->hz = atof(at + 1); }
    if (sscanf(tmp, "%dx%d", &sp->w, &sp->h) != 2) return -1;
    return 0;
}

// 在可用模式里找最佳匹配；未指定刷新率时取最高刷新率。返回 CFRetain 过的 mode。
static CGDisplayModeRef find_mode(CGDirectDisplayID did, const ModeSpec *sp, int *outCount) {
    // 必须带 kCGDisplayShowDuplicateLowResolutionModes，否则列表里没有 LoDPI 变体
    const void *keys[1] = { kCGDisplayShowDuplicateLowResolutionModes };
    const void *vals[1] = { kCFBooleanTrue };
    CFDictionaryRef opts = CFDictionaryCreate(NULL, keys, vals, 1,
                                              &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFArrayRef arr = CGDisplayCopyAllDisplayModes(did, opts);
    if (opts) CFRelease(opts);
    if (!arr) { if (outCount) *outCount = 0; return NULL; }
    CGDisplayModeRef found = NULL;
    CFIndex n = CFArrayGetCount(arr);
    int matched = 0;
    for (CFIndex i = 0; i < n; i++) {
        CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(arr, i);
        if ((int)CGDisplayModeGetWidth(m) != sp->w || (int)CGDisplayModeGetHeight(m) != sp->h) continue;
        if (sp->hidpi >= 0 && mode_is_hidpi(m) != sp->hidpi) continue;
        if (sp->hz > 0) {
            double r = CGDisplayModeGetRefreshRate(m);
            if (r < sp->hz - 0.6 || r > sp->hz + 0.6) continue;
        }
        matched++;
        if (!found) found = (CGDisplayModeRef)CFRetain(m);
        else {
            // 未指定刷新率时优先：刷新率更高者；同刷新率时优先 HiDPI
            double r = CGDisplayModeGetRefreshRate(m), rf = CGDisplayModeGetRefreshRate(found);
            if (r > rf + 0.5 || (r > rf - 0.5 && mode_is_hidpi(m) && !mode_is_hidpi(found))) {
                CFRelease(found);
                found = (CGDisplayModeRef)CFRetain(m);
            }
        }
    }
    CFRelease(arr);
    if (outCount) *outCount = matched;
    return found;
}

static int apply_mode(CGDirectDisplayID did, CGDisplayModeRef m) {
    CGDisplayConfigRef cfg = NULL;
    CGError e = CGBeginDisplayConfiguration(&cfg);
    if (e != kCGErrorSuccess || !cfg) return -1;
    e = CGConfigureDisplayWithDisplayMode(cfg, did, m, NULL);
    if (e != kCGErrorSuccess) { CGCancelDisplayConfiguration(cfg); return -2; }
    e = CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
    return e == kCGErrorSuccess ? 0 : -3;
}

static int set_main_display(CGDirectDisplayID did) {
    // 主显示器 = 原点落在 (0,0) 的那块屏。
    // 不能只把目标设到 (0,0)：若已有屏占据原点就会重叠，CGComplete 会静默不生效。
    // 正确做法是把整个桌面等比平移，使目标落到 (0,0)，相对布局保持不变。
    CGRect tb = CGDisplayBounds(did);
    int dx = -(int)tb.origin.x, dy = -(int)tb.origin.y;
    if (dx == 0 && dy == 0) return 0;   // 已经是主显示器

    CGDirectDisplayID all[16]; uint32_t n = 0;
    CGGetActiveDisplayList(16, all, &n);
    if (n == 0) return -1;

    CGDisplayConfigRef cfg = NULL;
    CGError e = CGBeginDisplayConfiguration(&cfg);
    if (e != kCGErrorSuccess || !cfg) return -1;
    for (uint32_t i = 0; i < n; i++) {
        CGRect b = CGDisplayBounds(all[i]);
        e = CGConfigureDisplayOrigin(cfg, all[i],
                                     (int32_t)(b.origin.x + dx), (int32_t)(b.origin.y + dy));
        if (e != kCGErrorSuccess) { CGCancelDisplayConfiguration(cfg); return -2; }
    }
    e = CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
    return e == kCGErrorSuccess ? 0 : -3;
}

static void cmd_modes(CGDirectDisplayID did, int showAll) {
    // 必须带 kCGDisplayShowDuplicateLowResolutionModes：否则列表里没有 LoDPI 变体，
    // 且 pixelWidth 会被归一化成等于 width，导致无法区分 HiDPI（实测 539 条里只能认出 1 条）
    const void *keys[1] = { kCGDisplayShowDuplicateLowResolutionModes };
    const void *vals[1] = { kCFBooleanTrue };
    CFDictionaryRef opts = CFDictionaryCreate(NULL, keys, vals, 1,
                                              &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFArrayRef arr = CGDisplayCopyAllDisplayModes(did, opts);
    if (opts) CFRelease(opts);
    if (!arr) { printf("无法获取 id=%u 的模式列表\n", did); return; }
    CGDisplayModeRef cur = CGDisplayCopyDisplayMode(did);
    CFIndex n = CFArrayGetCount(arr);
    char cdesc[96] = "(未知)";
    if (cur) snprintf(cdesc, sizeof cdesc, "%zux%zu px=%zux%zu %s @%.0fHz",
                      CGDisplayModeGetWidth(cur), CGDisplayModeGetHeight(cur),
                      CGDisplayModeGetPixelWidth(cur), CGDisplayModeGetPixelHeight(cur),
                      mode_is_hidpi(cur) ? "HiDPI" : "LoDPI", CGDisplayModeGetRefreshRate(cur));
    printf("id=%u 共 %ld 个模式，当前: %s\n", did, (long)n, cdesc);

    if (cur) CFRelease(cur);
    if (showAll) {
        for (CFIndex i = 0; i < n; i++) {
            CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(arr, i);
            printf("  [%3ld] %zux%zu px=%zux%zu %s @%.0fHz\n",
                   (long)i, CGDisplayModeGetWidth(m), CGDisplayModeGetHeight(m),
                   CGDisplayModeGetPixelWidth(m), CGDisplayModeGetPixelHeight(m),
                   mode_is_hidpi(m) ? "HiDPI" : "LoDPI",
                   CGDisplayModeGetRefreshRate(m));
        }
    } else {
        // 去重：同 逻辑分辨率+HiDPI 只保留最高刷新率
        int *uniq = calloc((size_t)n * 3, sizeof(int));
        double *hz = calloc((size_t)n, sizeof(double));
        int un = 0;
        for (CFIndex i = 0; i < n; i++) {
            CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(arr, i);
            int w = (int)CGDisplayModeGetWidth(m), h = (int)CGDisplayModeGetHeight(m), hd = mode_is_hidpi(m);
            int idx = -1;
            for (int k = 0; k < un; k++)
                if (uniq[k*3] == w && uniq[k*3+1] == h && uniq[k*3+2] == hd) { idx = k; break; }
            double r = CGDisplayModeGetRefreshRate(m);
            if (idx < 0) { uniq[un*3] = w; uniq[un*3+1] = h; uniq[un*3+2] = hd; hz[un] = r; un++; }
            else if (r > hz[idx]) hz[idx] = r;
        }
        // 按像素面积降序（大分辨率在前）
        for (int i = 0; i < un; i++)
            for (int j = i + 1; j < un; j++) {
                long ai = (long)uniq[i*3] * uniq[i*3+1], aj = (long)uniq[j*3] * uniq[j*3+1];
                if (aj > ai) {
                    for (int t = 0; t < 3; t++) { int tmp = uniq[i*3+t]; uniq[i*3+t] = uniq[j*3+t]; uniq[j*3+t] = tmp; }
                    double th = hz[i]; hz[i] = hz[j]; hz[j] = th;
                }
            }
        for (int i = 0; i < un; i++)
            printf("  %dx%d %s @%.0fHz\n", uniq[i*3], uniq[i*3+1],
                   uniq[i*3+2] ? "HiDPI" : "LoDPI", hz[i]);
        free(uniq); free(hz);
    }
    CFRelease(arr);
}

// 兜底回收：必须用 posix_spawn 重新 exec 一个全新进程。
// 不能用 fork()——macOS 上 fork 出的子进程再调用 CoreFoundation/ObjC 会被直接杀掉
// （"+[NSNumber initialize] may have been in progress in another thread when fork() was called"）。
// 通用：posix_spawn 一个脱离会话的自身副本，执行隐藏子命令
static void spawn_self(char *const args[], const char *hint) {
    char self[1024]; uint32_t sz = sizeof self;
    if (_NSGetExecutablePath(self, &sz) != 0) {
        fprintf(stderr, "[警告] 取自身路径失败，请手动执行: %s\n", hint);
        return;
    }
    char *argv[8];
    int i = 0;
    argv[i++] = self;
    for (int k = 0; args[k] && i < 7; k++) argv[i++] = args[k];
    argv[i] = NULL;

    posix_spawn_file_actions_t acts;
    posix_spawn_file_actions_init(&acts);
    posix_spawn_file_actions_addopen(&acts, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&acts, 1, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&acts, 2, "/dev/null", O_WRONLY, 0);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);   // 完全脱离父进程会话

    pid_t pid = 0;
    int e = posix_spawn(&pid, self, &acts, &attr, argv, environ);
    if (e == 0) printf("[安全] 兜底任务已挂起 (pid %d)：%s\n", pid, hint);
    else fprintf(stderr, "[警告] 兜底任务启动失败(e=%d)，请手动执行: %s\n", e, hint);

    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&acts);
}

static void spawn_revert(CGDirectDisplayID did, int secs) {
    char idbuf[16], secbuf[16], hint[128];
    snprintf(idbuf, sizeof idbuf, "%u", did);
    snprintf(secbuf, sizeof secbuf, "%d", secs);
    snprintf(hint, sizeof hint, "%d 秒后自动连回 id=%u（或执行 dlite restore）", secs, did);
    char *args[] = { "__revert", idbuf, secbuf, NULL };
    spawn_self(args, hint);
}

static void spawn_revert_mode(CGDirectDisplayID did, const char *spec, int secs) {
    char idbuf[16], secbuf[16], hint[160];
    snprintf(idbuf, sizeof idbuf, "%u", did);
    snprintf(secbuf, sizeof secbuf, "%d", secs);
    snprintf(hint, sizeof hint, "%d 秒后自动切回模式 %s (id=%u)", secs, spec, did);
    char *args[] = { "__revertmode", idbuf, (char *)spec, secbuf, NULL };
    spawn_self(args, hint);
}

// ============================ 私有 CGS 模式 API ============================
// 公开 API 的致命缺陷实测：显示器处于 LoDPI 时，其"原生逻辑分辨率"的 HiDPI 变体会从
// CGDisplayCopyAllDisplayModes 列表里消失（1440x2560 的 HiDPI 条目在有/无之间切换），
// 导致永远切不回 HiDPI。私有 CGS 模式列表不受此限制，且 modeNumber 是稳定标识。
typedef struct {
    uint32_t modeNumber;
    uint32_t flags;
    uint32_t width;
    uint32_t height;
    uint32_t depth;
    uint8_t  unknown[170];
    uint16_t freq;
    uint8_t  more_unknown[16];
    float    density;
} CGSDisplayMode;

typedef void (*CGSGetCurrentDisplayMode_t)(CGDirectDisplayID, int *);
typedef void (*CGSGetNumberOfDisplayModes_t)(CGDirectDisplayID, int *);
typedef void (*CGSGetDisplayModeDescriptionOfLength_t)(CGDirectDisplayID, int, CGSDisplayMode *, int);
typedef void (*CGSConfigureDisplayMode_t)(CGDisplayConfigRef, CGDirectDisplayID, int);

static CGSGetCurrentDisplayMode_t p_CGSGetCur;
static CGSGetNumberOfDisplayModes_t p_CGSGetNum;
static CGSGetDisplayModeDescriptionOfLength_t p_CGSGetDesc;
static CGSConfigureDisplayMode_t p_CGSConfigure;
// 屏幕旋转（私有 API，公开层只有 CGDisplayRotation 读角度，没有设置角度）
typedef CGError (*CGSConfigureDisplayRotation_t)(CGDisplayConfigRef, CGDirectDisplayID, double);
static CGSConfigureDisplayRotation_t p_CGSRotate;

static void load_cgs(void) {
    p_CGSGetCur    = (CGSGetCurrentDisplayMode_t)dlsym(RTLD_DEFAULT, "CGSGetCurrentDisplayMode");
    p_CGSGetNum    = (CGSGetNumberOfDisplayModes_t)dlsym(RTLD_DEFAULT, "CGSGetNumberOfDisplayModes");
    p_CGSGetDesc   = (CGSGetDisplayModeDescriptionOfLength_t)dlsym(RTLD_DEFAULT, "CGSGetDisplayModeDescriptionOfLength");
    p_CGSConfigure = (CGSConfigureDisplayMode_t)dlsym(RTLD_DEFAULT, "CGSConfigureDisplayMode");
    p_CGSRotate    = (CGSConfigureDisplayRotation_t)dlsym(RTLD_DEFAULT, "CGSConfigureDisplayRotation");
}

// HiDPI 判别：首选 density（实测 HiDPI=2.00 / LoDPI=1.00，可靠）；
// flags 位作兜底（实测 HiDPI 条目带 0x00200000，LoDPI 条目带 0x02000000）
#define CGS_FLAG_HIDPI 0x00200000

static int cgs_mode_is_hidpi(const CGSDisplayMode *m) {
    if (m->density > 1.5f) return 1;
    return (m->flags & CGS_FLAG_HIDPI) ? 1 : 0;
}

static int cgs_mode_count(CGDirectDisplayID did) {
    if (!p_CGSGetNum) return -1;
    int n = 0;
    p_CGSGetNum(did, &n);
    return n;
}

static int cgs_read_mode(CGDirectDisplayID did, int idx, CGSDisplayMode *out) {
    if (!p_CGSGetDesc) return -1;
    memset(out, 0, sizeof *out);
    p_CGSGetDesc(did, idx, out, (int)sizeof(CGSDisplayMode));
    return 0;
}

static void cmd_cgs(CGDirectDisplayID did, const char *filter) {
    if (!p_CGSGetNum || !p_CGSGetDesc) { printf("本机不提供 CGS 模式 API\n"); return; }
    int cur = -1;
    if (p_CGSGetCur) p_CGSGetCur(did, &cur);
    int n = cgs_mode_count(did);
    printf("id=%u 私有模式列表共 %d 条，当前 modeNumber=%d\n", did, n, cur);
    int shown = 0;
    for (int i = 0; i < n && shown < 400; i++) {
        CGSDisplayMode m;
        if (cgs_read_mode(did, i, &m) != 0) continue;
        char line[160];
        snprintf(line, sizeof line, "  [%3d] num=%-6u %ux%u %s %uHz flags=0x%08X density=%.2f",
                 i, m.modeNumber, m.width, m.height, cgs_mode_is_hidpi(&m) ? "HiDPI" : "LoDPI",
                 m.freq, m.flags, m.density);
        if (filter && *filter && !strstr(line, filter)) continue;
        printf("%s%s\n", line, ((int)m.modeNumber == cur) ? "  <= 当前" : "");
        shown++;
    }
}

static int cgs_apply_mode(CGDirectDisplayID did, int modeNumber) {
    if (!p_CGSConfigure) { fprintf(stderr, "本机不提供 CGSConfigureDisplayMode\n"); return -1; }
    CGDisplayConfigRef cfg = NULL;
    CGError e = CGBeginDisplayConfiguration(&cfg);
    if (e != kCGErrorSuccess || !cfg) return -1;
    p_CGSConfigure(cfg, did, modeNumber);
    e = CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
    return e == kCGErrorSuccess ? 0 : -3;
}

// 用私有 API 找同分辨率/刷新率的 HiDPI 或 LoDPI 变体
static int cgs_find_variant(CGDirectDisplayID did, int w, int h, unsigned hz, int wantHidpi, int *outNum) {
    int n = cgs_mode_count(did);
    if (n < 0) return -1;
    for (int i = 0; i < n; i++) {
        CGSDisplayMode m;
        if (cgs_read_mode(did, i, &m) != 0) continue;
        if ((int)m.width != w || (int)m.height != h) continue;
        if (cgs_mode_is_hidpi(&m) != wantHidpi) continue;
        if (hz > 0 && (m.freq + 1 < hz || m.freq > hz + 1)) continue;
        *outNum = (int)m.modeNumber;
        return 0;
    }
    return -1;
}

// 供 UI 一次性读取所有状态（key=value 行，便于解析）
static void cmd_info(void) {
    CGDirectDisplayID online[16]; uint32_t n = 0;
    CGGetOnlineDisplayList(16, online, &n);
    for (uint32_t i = 0; i < n; i++) {
        DispInfo d; fill_info(online[i], &d);
        int idx = -1;
        CFTypeRef svc = service_for_display(d.id, &idx);
        char nm[128]; display_name(d.id, nm, sizeof nm);
        printf("display id=%u main=%d active=%d ddc=%d uuid=%s name=%s\n",
               d.id, d.main, d.active, svc ? 1 : 0, d.uuid[0] ? d.uuid : "-", nm[0] ? nm : "(未知)");
        if (svc) {
            uint16_t cur = 0, max = 0;
            if (ddc_get(svc, 0x10, &cur, &max) == 0) printf("brightness cur=%u max=%u\n", cur, max);
            if (ddc_get(svc, 0x62, &cur, &max) == 0) printf("volume cur=%u max=%u\n", cur, max);
            CFRelease(svc);
        }
        CGDisplayModeRef m = CGDisplayCopyDisplayMode(d.id);
        if (m) {
            printf("mode w=%zu h=%zu hidpi=%d hz=%.0f\n",
                   CGDisplayModeGetWidth(m), CGDisplayModeGetHeight(m),
                   mode_is_hidpi(m), CGDisplayModeGetRefreshRate(m));
            CFRelease(m);
        }
        printf("rot=%.0f\n", CGDisplayRotation(d.id));
        int cnum = -1;
        if (p_CGSGetCur) {
            p_CGSGetCur(d.id, &cnum);
            printf("cgsnum=%d\n", cnum);
        }
        printf("enddisplay\n");
    }
}

// 分辨率档位改为「动态探测面板原生像素」（见 cmd_presets），不再使用硬编码白名单

typedef struct { int w, h, hidpi; unsigned hz; } PresetEnt;

// 面向菜单的"常用分辨率"档位（覆盖常见面板：16:9 / 16:10 / 3:2 / 21:9 / 32:9 / 5K 等）。
// 注意：这只是"精选"，不是唯一来源 —— cmd_presets 命中不足时会**动态兜底**，
// 按该显示器自身的宽高比筛选实际档位，所以超宽屏 / 5K / 竖屏旋转等其他设备也能正常列出。
static const char *kPresets[] = {
    "5120x2880", "5120x2160", "5120x1440", "4096x2304", "3840x2160", "3840x1600", "3840x1080",
    "3440x1440", "3200x1800", "3008x1692", "2880x1800", "2880x1620", "2560x1600", "2560x1440",
    "2560x1080", "2304x1440", "2304x1296", "2048x1152", "1920x1200", "1920x1080", "1680x1050",
    "1600x900", "1440x900", "1440x810", "1280x800", "1280x720", "1152x864", "1024x768", "800x600",
    NULL
};

static void cmd_presets(CGDirectDisplayID did) {
    int n = cgs_mode_count(did);
    if (n < 0) { printf("本机不提供 CGS 模式 API\n"); return; }
    PresetEnt *ent = calloc((size_t)n, sizeof(PresetEnt));
    int en = 0;
    int curNum = -1;
    if (p_CGSGetCur) p_CGSGetCur(did, &curNum);
    PresetEnt current = {0, 0, 0, 0};
    int haveCurrent = 0;

    // —— 动态探测（不依赖任何硬编码白名单，任何显示器都适用）——
    // 第一遍先找到"当前模式"，以其宽高比 + 尺寸作为基准；第二遍据此筛选档位。
    // 这样超宽屏(21:9/32:9)、5K、竖屏旋转都能自然适配，且不会混入反方向的档位。
    CGSDisplayMode curM; int haveCurM = 0;
    for (int i = 0; i < n; i++) {
        CGSDisplayMode m;
        if (cgs_read_mode(did, i, &m) != 0) continue;
        if ((int)m.modeNumber == curNum) { curM = m; haveCurM = 1; break; }
    }
    double arRef = (haveCurM && curM.height) ? (double)curM.width / (double)curM.height : 0.0;
    int minAxis = haveCurM ? (int)(curM.width * 4 / 10) : 0;   // 太小的档位没意义，滤掉

    // 两遍收集：第一遍用"常用档位"精选（列表干净）；若一个都没命中（少见面板，
    // 例如 21:9 超宽屏、5K、方形屏），第二遍按该屏自身宽高比动态兜底，保证不空。
    for (int pass = 0; pass < 2 && en == 0; pass++) {
        for (int i = 0; i < n; i++) {
            CGSDisplayMode m;
            if (cgs_read_mode(did, i, &m) != 0) continue;
            int hd = cgs_mode_is_hidpi(&m);
            // 记录当前模式
            if ((int)m.modeNumber == curNum) { current.w = m.width; current.h = m.height; current.hidpi = hd; current.hz = m.freq; haveCurrent = 1; }

            int ok = 0;
            if (pass == 0) {
                // 常用档位白名单（竖屏时同时接受转置匹配）
                char key[32], tkey[32];
                snprintf(key, sizeof key, "%ux%u", m.width, m.height);
                snprintf(tkey, sizeof tkey, "%ux%u", m.height, m.width);
                for (int k = 0; kPresets[k]; k++)
                    if (!strcmp(kPresets[k], key) || !strcmp(kPresets[k], tkey)) { ok = 1; break; }
            } else {
                // 兜底：与当前模式同宽高比、尺寸不太小的档位
                ok = 1;
                if (arRef > 0) {
                    double ar = (double)m.width / (double)m.height;
                    if (fabs(ar - arRef) / arRef > 0.02) ok = 0;
                    if ((int)m.width < minAxis) ok = 0;
                }
            }
            if (!ok) continue;

            int idx = -1;
            for (int k = 0; k < en; k++)
                if (ent[k].w == (int)m.width && ent[k].h == (int)m.height && ent[k].hidpi == hd) { idx = k; break; }
            if (idx < 0) {
                ent[en].w = m.width; ent[en].h = m.height; ent[en].hidpi = hd; ent[en].hz = m.freq; en++;
            } else if (m.freq > ent[idx].hz) ent[idx].hz = m.freq;
        }
    }

    // 保证当前模式一定在列表里（否则切到当前档会"找不到"）
    if (haveCurrent) {
        int idx = -1;
        for (int k = 0; k < en; k++)
            if (ent[k].w == current.w && ent[k].h == current.h && ent[k].hidpi == current.hidpi) { idx = k; break; }
        if (idx < 0) {
            ent[en].w = current.w; ent[en].h = current.h; ent[en].hidpi = current.hidpi; ent[en].hz = current.hz;
            en++;
        } else if (current.hz > ent[idx].hz) ent[idx].hz = current.hz;
    }

    if (haveCurrent)
        printf("current %dx%d %s %uHz\n", current.w, current.h, current.hidpi ? "HiDPI" : "LoDPI", current.hz);

    // 按面积降序输出
    for (int i = 0; i < en; i++)
        for (int j = i + 1; j < en; j++)
            if ((long)ent[j].w * ent[j].h > (long)ent[i].w * ent[i].h) {
                PresetEnt t = ent[i]; ent[i] = ent[j]; ent[j] = t;
            }

    // 兜底模式可能命中上百个 32px 阶梯档位 → 只保留尺寸最大的若干个，保持菜单清爽
    if (en > 12) en = 12;

    for (int i = 0; i < en; i++)
        printf("%dx%d %s %uHz\n", ent[i].w, ent[i].h, ent[i].hidpi ? "HiDPI" : "LoDPI", ent[i].hz);

    free(ent);
}

// 静音状态文件（本屏 DDC 不支持 mute，用"记住原音量→归零"实现）
static const char *volstate_path(void) {
    static char p[512];
    const char *h = getenv("HOME");
    snprintf(p, sizeof p, "%s/.dlite-volume", h ? h : "/tmp");
    return p;
}

// 转储 framebuffer 节点的 IORegistry 属性（用于找可写的色彩模式属性）
static void cmd_fbprops(CGDirectDisplayID did, const char *filter, int verbose) {
    CFDictionaryRef info = p_CDInfo(did);
    if (!info) { printf("取不到显示器信息\n"); return; }
    CFTypeRef locRef = CFDictionaryGetValue(info, CFSTR("IODisplayLocation"));
    if (!locRef || CFGetTypeID(locRef) != CFStringGetTypeID()) { printf("取不到 IODisplayLocation\n"); return; }
    char l[512] = {0};
    CFStringGetCString(locRef, l, sizeof l, kCFStringEncodingUTF8);
    io_service_t fb = IORegistryEntryFromPath(kIOMainPortDefault, l);
    if (!fb) { printf("取不到 framebuffer 节点\n"); return; }

    CFMutableDictionaryRef props = NULL;
    if (IORegistryEntryCreateCFProperties(fb, &props, kCFAllocatorDefault, 0) != KERN_SUCCESS || !props) {
        printf("读不到属性\n");
        IOObjectRelease(fb);
        return;
    }
    CFIndex n = CFDictionaryGetCount(props);
    const void *keys[512], *vals[512];
    if (n > 512) n = 512;
    CFDictionaryGetKeysAndValues(props, keys, vals);
    printf("id=%u framebuffer 属性共 %ld 项\n", did, (long)CFDictionaryGetCount(props));
    int shown = 0;
    for (CFIndex i = 0; i < n; i++) {
        char kn[256] = {0};
        CFStringGetCString(keys[i], kn, sizeof kn, kCFStringEncodingUTF8);
        if (filter && *filter) {
            if (!strcasestr(kn, filter)) continue;
        }
        CFStringRef tn = CFCopyTypeIDDescription(CFGetTypeID(vals[i]));
        char tnb[64] = {0};
        if (tn) { CFStringGetCString(tn, tnb, sizeof tnb, kCFStringEncodingUTF8); CFRelease(tn); }
        if (verbose) {
            CFStringRef d = CFCopyDescription(vals[i]);
            char db[400] = {0};
            if (d) { CFStringGetCString(d, db, sizeof db, kCFStringEncodingUTF8); CFRelease(d); }
            printf("  %-42s [%s] %s\n", kn, tnb, db);
        } else {
            printf("  %-42s [%s]\n", kn, tnb);
        }
        shown++;
    }
    printf("  …共显示 %d 项\n", shown);
    CFRelease(props);
    IOObjectRelease(fb);
}

// VESA MCCS 标准色彩预设（VCP 0x14）名称表
static const char *color_preset_name(int v) {
    switch (v) {
        case 0x01: return "sRGB";
        case 0x02: return "原生 (Display Native)";
        case 0x03: return "色温 4000K";
        case 0x04: return "色温 5000K";
        case 0x05: return "色温 6500K";
        case 0x06: return "色温 7500K";
        case 0x07: return "色温 8200K";
        case 0x08: return "色温 9300K";
        case 0x09: return "色温 10000K";
        case 0x0A: return "用户 1";
        case 0x0B: return "用户 2";
        case 0x0C: return "用户 3";
        default:   return "未知";
    }
}

// 前向声明：read_caps / caps_allowed_values 定义在文件后面
static int read_caps(CFTypeRef svc, char *out, size_t outsz, int verbose);
static int caps_allowed_values(const char *caps, int vcp, int *out, int maxn);

static void cmd_colormode(CGDirectDisplayID did, const char *setArg) {
    CFTypeRef svc = service_for_display(did, NULL);
    if (!svc) { fprintf(stderr, "id=%u 无可用 DDC 通道\n", did); return; }
    uint16_t cur = 0, max = 0;
    if (ddc_get(svc, 0x14, &cur, &max) != 0) {
        fprintf(stderr, "id=%u 不支持色彩预设 (VCP 0x14)\n", did);
        CFRelease(svc);
        return;
    }
    // 以显示器能力串为准取"实际支持的取值"（MCCS 标准表并不适用，实测本屏只有 4 个）
    char caps[2048];
    int allowed[32];
    int an = 0;
    if (read_caps(svc, caps, sizeof caps, 0) > 0)
        an = caps_allowed_values(caps, 0x14, allowed, 32);

    if (setArg) {
        int want = (int)strtol(setArg, NULL, 0);
        if (an > 0) {
            int ok = 0;
            for (int i = 0; i < an; i++) if (allowed[i] == want) ok = 1;
            if (!ok) {
                fprintf(stderr, "id=%u 不支持该取值 %d（显示器声明只支持:", did, want);
                for (int i = 0; i < an; i++) fprintf(stderr, " %d", allowed[i]);
                fprintf(stderr, "）\n");
                CFRelease(svc);
                return;
            }
        } else if (want < 1 || want > (int)max) {
            fprintf(stderr, "取值必须在 1..%u 之间\n", max);
            CFRelease(svc);
            return;
        }
        if (ddc_set(svc, 0x14, (uint16_t)want) == 0) {
            usleep(150000);
            uint16_t c2 = 0, m2 = 0;
            if (ddc_get(svc, 0x14, &c2, &m2) == 0)
                printf("id=%u 色彩模式已设为 %d %s（回读 %u）\n", did, want, color_preset_name(want), c2);
            else printf("id=%u 色彩模式已设为 %d\n", did, want);
        } else fprintf(stderr, "写入失败\n");
    } else {
        printf("id=%u 色彩预设: 当前 = %u (%s)\n", did, cur, color_preset_name(cur));
        if (an > 0) {
            printf("  显示器声明的可用取值（能力串 14(...)）：\n");
            for (int i = 0; i < an; i++)
                printf("    %2d  %-22s %s\n", allowed[i], color_preset_name(allowed[i]),
                       allowed[i] == (int)cur ? "  <= 当前" : "");
        } else {
            printf("  （未取到能力串，按 1..%u 显示）\n", max);
            for (int v = 1; v <= (int)max; v++)
                printf("    %2d  %-22s %s\n", v, color_preset_name(v), v == (int)cur ? "  <= 当前" : "");
        }
        printf("  提示：色温可用 `dlite ddc get/set <id> 0x0C <值>` 连续调节\n");
    }
    CFRelease(svc);
}

// DDC/CI Capabilities Request (opcode 0xF3)：拿显示器对自身 VCP 的权威说明（只读）
// 实测回包布局：[0]=0x6E 源地址 [1]=len|0x80 [2]=0xE3 [3..4]=offset 回显 [5..]=数据
// 注意：此回包没有"总长"字段，必须靠循环推进 offset 直到取不到新数据
static int ddc_caps_dump(CFTypeRef svc) {
    char out[2048];
    int n = read_caps(svc, out, sizeof out, 1);
    if (n <= 0) { printf("  能力串读取失败 (%d)\n", n); return -1; }
    printf("能力串取到 %d 字节\n", n);
    for (int i = 0; i < n; i++) {
        char c = out[i];
        if (c == '\r') continue;
        putchar(c == '\n' ? '\n' : (c >= 32 && c < 127 ? c : '.'));
    }
    printf("\n");
    return 0;
}

// 只读：转储 DCP 层 TimingElements 里每个时序的色彩模式（判断是否真的存在 HDR/P3 模式）
static int cf_int(CFDictionaryRef d, CFStringRef key) {
    CFTypeRef v = CFDictionaryGetValue(d, key);
    int out = 0;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &out);
    return out;
}

static const char *eotf_name(int e) {
    switch (e) {
        case 0: return "SDR(传统gamma)";
        case 1: return "HDR(传统gamma)";
        case 2: return "PQ/HDR10";
        case 3: return "HLG";
        default: return "?";
    }
}

static void dump_timing_colors(CFTypeRef arr, const char *tag) {
    if (!arr || CFGetTypeID(arr) != CFArrayGetTypeID()) { printf("  %s: 无\n", tag); return; }
    CFArrayRef a = (CFArrayRef)arr;
    CFIndex n = CFArrayGetCount(a);
    printf("  %s: %ld 个时序\n", tag, (long)n);
    int hdrFound = 0;
    for (CFIndex i = 0; i < n && i < 10; i++) {
        CFTypeRef el = CFArrayGetValueAtIndex(a, i);
        if (!el || CFGetTypeID(el) != CFDictionaryGetTypeID()) continue;
        CFDictionaryRef d = (CFDictionaryRef)el;
        int aw = 0, ah = 0;
        CFTypeRef ha = CFDictionaryGetValue(d, CFSTR("HorizontalAttributes"));
        CFTypeRef va = CFDictionaryGetValue(d, CFSTR("VerticalAttributes"));
        if (ha && CFGetTypeID(ha) == CFDictionaryGetTypeID()) aw = cf_int((CFDictionaryRef)ha, CFSTR("Active"));
        if (va && CFGetTypeID(va) == CFDictionaryGetTypeID()) ah = cf_int((CFDictionaryRef)va, CFSTR("Active"));
        CFTypeRef cms = CFDictionaryGetValue(d, CFSTR("ColorModes"));
        long ccount = (cms && CFGetTypeID(cms) == CFArrayGetTypeID()) ? CFArrayGetCount((CFArrayRef)cms) : 0;
        printf("    [%ld] %dx%d  色彩模式 %ld 个\n", (long)i, aw, ah, ccount);
        if (!cms || CFGetTypeID(cms) != CFArrayGetTypeID()) continue;
        for (CFIndex k = 0; k < ccount && k < 24; k++) {
            CFTypeRef cm = CFArrayGetValueAtIndex((CFArrayRef)cms, k);
            if (!cm || CFGetTypeID(cm) != CFDictionaryGetTypeID()) continue;
            CFDictionaryRef c = (CFDictionaryRef)cm;
            int id = cf_int(c, CFSTR("ID"));
            int eotf = cf_int(c, CFSTR("EOTF"));
            int col = cf_int(c, CFSTR("Colorimetry"));
            int dyn = cf_int(c, CFSTR("DynamicRange"));
            int depth = cf_int(c, CFSTR("Depth"));
            if (eotf >= 2) hdrFound = 1;
            printf("        ID=%-5d EOTF=%d(%s) Colorimetry=%-3d DynamicRange=%d Depth=%d\n",
                   id, eotf, eotf_name(eotf), col, dyn, depth);
        }
    }
    printf("  → %s 里%s HDR(EOTF>=2) 模式\n", tag, hdrFound ? "存在" : "不存在");
}

static void cmd_dcpcolors(CGDirectDisplayID did) {
    CFDictionaryRef info = p_CDInfo(did);
    if (!info) { printf("取不到显示器信息\n"); return; }
    CFTypeRef locRef = CFDictionaryGetValue(info, CFSTR("IODisplayLocation"));
    if (!locRef || CFGetTypeID(locRef) != CFStringGetTypeID()) { printf("取不到定位\n"); return; }
    char l[512] = {0};
    CFStringGetCString(locRef, l, sizeof l, kCFStringEncodingUTF8);
    io_service_t fb = IORegistryEntryFromPath(kIOMainPortDefault, l);
    if (!fb) { printf("取不到 framebuffer 节点\n"); return; }
    printf("id=%u  %s\n", did, l);
    CFTypeRef te = IORegistryEntryCreateCFProperty(fb, CFSTR("TimingElements"), kCFAllocatorDefault, 0);
    CFTypeRef pe = IORegistryEntryCreateCFProperty(fb, CFSTR("PreferredTimingElements"), kCFAllocatorDefault, 0);
    dump_timing_colors(te, "TimingElements");
    dump_timing_colors(pe, "PreferredTimingElements");
    if (te) CFRelease(te);
    if (pe) CFRelease(pe);
    IOObjectRelease(fb);
}

// 读能力串到缓冲区（供 ddc caps 与"某 VCP 支持哪些取值"共用）
static int read_caps(CFTypeRef svc, char *out, size_t outsz, int verbose) {
    int outn = 0, off = 0, first = 1;
    out[0] = 0;
    while (off < 1500 && outn < (int)outsz - 1) {
        uint8_t req[8];
        memset(req, 0, sizeof req);
        req[0] = 0x83;
        req[1] = 0xF3;
        req[2] = (uint8_t)((off >> 8) & 0xFF);
        req[3] = (uint8_t)(off & 0xFF);
        req[4] = (uint8_t)(0x6E ^ req[0] ^ req[1] ^ req[2] ^ req[3]);
        IOReturn ret = kIOReturnSuccess;
        for (int i = 0; i < DDC_ITER; i++) {
            usleep(DDC_WAIT_US);
            ret = p_Write(svc, DDC_CHIP_ADDR, DDC_INPUT_ADDR, req, 5);
            if (ret == kIOReturnSuccess) break;
        }
        if (ret != kIOReturnSuccess) return outn > 0 ? outn : -1;
        usleep(60000);
        uint8_t rep[40];
        memset(rep, 0, sizeof rep);
        ret = p_Read(svc, DDC_CHIP_ADDR, DDC_INPUT_ADDR, rep, 32);
        if (ret != kIOReturnSuccess) return outn > 0 ? outn : -2;
        if (verbose && first) {
            printf("  首次回包(前 16 字节): ");
            for (int i = 0; i < 16; i++) printf("%02X ", rep[i]);
            printf("\n  长度字节=0x%02X   offset 回显=%d\n", rep[1], (rep[3] << 8) | rep[4]);
            first = 0;
        }
        if (rep[0] != 0x6E || rep[2] != 0xE3) break;
        int dataLen = (int)rep[1] - 0x80 - 3;
        int got = 0;
        for (int i = 5; i < 5 + dataLen && i < 40; i++) {
            if (rep[i] == 0) break;
            out[outn++] = (char)rep[i];
            got++;
            if (outn >= (int)outsz - 1) break;
        }
        if (got == 0) break;
        off += got;
    }
    out[outn] = 0;
    return outn;
}

// 从能力串里抽出某个 VCP 支持的取值，如 "14(05 06 08 0B)" -> {5,6,8,11}
static int caps_allowed_values(const char *caps, int vcp, int *out, int maxn) {
    char pat[8];
    snprintf(pat, sizeof pat, "%02X(", vcp);
    const char *p = strstr(caps, pat);
    if (!p) return 0;
    p += strlen(pat);
    int n = 0;
    while (*p && *p != ')') {
        while (*p == ' ') p++;
        if (!isxdigit((unsigned char)*p)) break;
        char *end = NULL;
        long v = strtol(p, &end, 16);
        if (end == p) break;
        if (n < maxn) out[n++] = (int)v;
        p = end;
    }
    return n;
}

// 全 VCP 快照：把能力串里声明的每个（单字节）VCP 都读一遍并落盘，便于前后 diff 定位
static void cmd_survey(CGDirectDisplayID did, const char *outPath) {
    CFTypeRef svc = service_for_display(did, NULL);
    if (!svc) { fprintf(stderr, "id=%u 无可用 DDC 通道\n", did); return; }
    char caps[2048];
    if (read_caps(svc, caps, sizeof caps, 0) <= 0) {
        fprintf(stderr, "能力串读取失败\n");
        CFRelease(svc);
        return;
    }
    const char *p = strstr(caps, "vcp(");
    if (!p) { fprintf(stderr, "能力串里没有 vcp 段\n"); CFRelease(svc); return; }
    p += 4;

    // 复制 vcp(...) 内部内容，剔除圆括号内的取值列表
    char section[1024];
    int sn = 0;
    for (const char *q = p; *q && *q != ')' && sn < (int)sizeof(section) - 1; ) {
        if (*q == '(') { while (*q && *q != ')') q++; if (*q) q++; continue; }
        section[sn++] = *q++;
    }
    section[sn] = 0;

    FILE *f = outPath ? fopen(outPath, "w") : NULL;
    printf("VCP 普查 (id=%u)%s\n", did, outPath ? outPath : "");
    char *save = NULL;
    for (char *tok = strtok_r(section, " ", &save); tok; tok = strtok_r(NULL, " ", &save)) {
        if (strlen(tok) != 2 || !isxdigit((unsigned char)tok[0]) || !isxdigit((unsigned char)tok[1])) continue;
        int vcp = (int)strtol(tok, NULL, 16);
        // 抗噪：同一 VCP 连读 3 次取多数（实测 DDC 偶尔会返回上一次的残留值）
        uint16_t cvals[3], mvals[3];
        int oks[3];
        for (int r = 0; r < 3; r++) {
            if (r > 0) usleep(30000);   // 让 DDC 总线在两次读取间稳定
            cvals[r] = 0; mvals[r] = 0;
            oks[r] = (ddc_get(svc, (uint8_t)vcp, &cvals[r], &mvals[r]) == 0);
        }
        int best = -1, bestCount = 0;
        for (int r = 0; r < 3; r++) {
            if (!oks[r]) continue;
            int cnt = 0;
            for (int s = 0; s < 3; s++) if (oks[s] && cvals[s] == cvals[r]) cnt++;
            if (cnt > bestCount) { bestCount = cnt; best = r; }
        }
        if (best < 0) {
            printf("  vcp=0x%02X 读取失败\n", vcp);
            if (f) fprintf(f, "0x%02X -1 -1\n", vcp);
        } else {
            const char *flag = (bestCount == 3) ? "" : "  (读数不稳)";
            printf("  vcp=0x%02X cur=%-8u max=%u%s\n", vcp, cvals[best], mvals[best], flag);
            if (f) fprintf(f, "0x%02X %u %u\n", vcp, cvals[best], mvals[best]);
        }
    }
    if (f) fclose(f);
    CFRelease(svc);
}

// ============================ 命令 ============================
static void cmd_list(void) {
    CGDirectDisplayID online[16]; uint32_t n = 0;
    CGGetOnlineDisplayList(16, online, &n);
    printf("在线显示器 %u 块，活动 %u 块\n", n, active_count());
    for (uint32_t i = 0; i < n; i++) {
        DispInfo d; fill_info(online[i], &d);
        int idx = -1;
        CFTypeRef svc = service_for_display(d.id, &idx);
        CGRect b = CGDisplayBounds(d.id);
        char nm[128]; display_name(d.id, nm, sizeof nm);
        printf("  id=%-3u %-16s uuid=%-38s vendor=%-6u model=%-6u main=%d active=%d online=%d dispext=%d origin=%dx%d size=%dx%d DDC=%s\n",
               d.id, nm[0] ? nm : "(未知)", d.uuid[0] ? d.uuid : "(未知)", d.vendor, d.model,
               d.main, d.active, d.online, d.dispext,
               (int)b.origin.x, (int)b.origin.y, (int)b.size.width, (int)b.size.height,
               svc ? "OK" : "--");
        if (svc) CFRelease(svc);
    }
}

static void cmd_restore(void) {
    int done = 0;
    // 1) 先恢复记录在案的已断开显示器——它们已从在线列表消失，只能靠记录找回
    CGDirectDisplayID rec[32]; int rn = state_load(rec, 32);
    for (int i = 0; i < rn; i++) {
        printf("连回记录中的 id=%u ... ", rec[i]);
        fflush(stdout);
        if (set_display_enabled(rec[i], 1) == 0) { printf("OK\n"); state_remove(rec[i]); done++; }
        else printf("失败\n");
    }
    // 2) 再扫在线列表里处于未启用状态的
    CGDirectDisplayID online[16]; uint32_t n = 0;
    CGGetOnlineDisplayList(16, online, &n);
    for (uint32_t i = 0; i < n; i++) {
        if (!CGDisplayIsActive(online[i])) {
            printf("连回 id=%u ... ", online[i]);
            fflush(stdout);
            if (set_display_enabled(online[i], 1) == 0) { printf("OK\n"); done++; }
            else printf("失败\n");
        }
    }
    if (!done) printf("无需恢复（所有在线显示器均已启用）\n");
}

static int cmd_hidpi(CGDirectDisplayID did, const char *how, int revertSecs) {
    CGDisplayModeRef cur = CGDisplayCopyDisplayMode(did);
    if (!cur) { fprintf(stderr, "无法读取 id=%u 的当前模式\n", did); return 1; }
    int nowH = mode_is_hidpi(cur);
    int want = nowH;
    if (!strcmp(how, "on")) want = 1;
    else if (!strcmp(how, "off")) want = 0;
    else if (!strcmp(how, "toggle")) want = !nowH;
    else { CFRelease(cur); fprintf(stderr, "参数应为 on|off|toggle\n"); return 2; }

    if (want == nowH) {
        printf("id=%u 当前已是 %s，无需切换\n", did, nowH ? "HiDPI" : "LoDPI");
        CFRelease(cur);
        return 0;
    }
    // 保持同一逻辑分辨率与刷新率，只翻转 HiDPI（等同于菜单里的「高分辨率 (HiDPI)」勾选）
    ModeSpec sp;
    sp.w = (int)CGDisplayModeGetWidth(cur);
    sp.h = (int)CGDisplayModeGetHeight(cur);
    sp.hz = CGDisplayModeGetRefreshRate(cur);
    sp.hidpi = want;

    char curSpec[80];
    snprintf(curSpec, sizeof curSpec, "%dx%d@%.0f%s", sp.w, sp.h, sp.hz, nowH ? ":hidpi" : ":lodpi");
    CFRelease(cur);
    if (revertSecs > 0) spawn_revert_mode(did, curSpec, revertSecs);

    // 优先走私有 CGS 列表：公开列表在当前为 LoDPI 时不含 HiDPI 变体，会切不回去
    int rc = -1;
    int num = -1;
    if (cgs_find_variant(did, sp.w, sp.h, (unsigned)(sp.hz + 0.5), want, &num) == 0) {
        rc = cgs_apply_mode(did, num);
    } else {
        int cnt = 0;
        CGDisplayModeRef m = find_mode(did, &sp, &cnt);
        if (!m) {
            fprintf(stderr, "id=%u 在 %dx%d@%.0fHz 上没有 %s 变体，无法切换\n",
                    did, sp.w, sp.h, sp.hz, want ? "HiDPI" : "LoDPI");
            return 1;
        }
        rc = apply_mode(did, m);
        CFRelease(m);
    }
    usleep(500000);
    CGDisplayModeRef now = CGDisplayCopyDisplayMode(did);
    if (now) {
        printf("id=%u HiDPI → %s，当前 %zux%zu %s @%.0fHz\n", did,
               rc == 0 ? "已提交" : "失败",
               CGDisplayModeGetWidth(now), CGDisplayModeGetHeight(now),
               mode_is_hidpi(now) ? "HiDPI" : "LoDPI", CGDisplayModeGetRefreshRate(now));
        CFRelease(now);
    }
    return rc == 0 ? 0 : 1;
}

// ---- 列出"当前分辨率 + HiDPI 组合"下可选的刷新率（降序，当前项带 current 前缀）----
// 用 CGS 完整模式列表（CGDisplayCopyAllDisplayModes 在部分屏幕上拿不到全部模式）
static void cmd_rates(CGDirectDisplayID did) {
    int n = cgs_mode_count(did);
    if (n < 0) { printf("本机不提供 CGS 模式 API\n"); return; }
    int curNum = -1;
    if (p_CGSGetCur) p_CGSGetCur(did, &curNum);

    CGSDisplayMode cur; int haveCur = 0;
    for (int i = 0; i < n; i++) {
        CGSDisplayMode m;
        if (cgs_read_mode(did, i, &m) != 0) continue;
        if ((int)m.modeNumber == curNum) { cur = m; haveCur = 1; break; }
    }
    if (!haveCur) {
        CGDisplayModeRef c = CGDisplayCopyDisplayMode(did);
        if (!c) { printf("无法确定当前模式\n"); return; }
        memset(&cur, 0, sizeof cur);
        cur.width = (unsigned)CGDisplayModeGetWidth(c);
        cur.height = (unsigned)CGDisplayModeGetHeight(c);
        cur.freq = (unsigned)CGDisplayModeGetRefreshRate(c);
        CFRelease(c);
    }
    int hd = cgs_mode_is_hidpi(&cur);

    double rates[64]; int rn = 0;
    for (int i = 0; i < n; i++) {
        CGSDisplayMode m;
        if (cgs_read_mode(did, i, &m) != 0) continue;
        if (m.width != cur.width || m.height != cur.height) continue;
        if (cgs_mode_is_hidpi(&m) != hd) continue;
        double hz = m.freq;
        if (hz <= 0) continue;
        int dup = 0;
        for (int k = 0; k < rn; k++) if (fabs(rates[k] - hz) < 0.5) { dup = 1; break; }
        if (!dup && rn < 64) rates[rn++] = hz;
    }
    for (int i = 0; i < rn; i++)
        for (int j = i + 1; j < rn; j++)
            if (rates[j] > rates[i]) { double t = rates[i]; rates[i] = rates[j]; rates[j] = t; }

    printf("mode %ux%u %s current=%.0fHz\n", cur.width, cur.height,
           hd ? "HiDPI" : "LoDPI", (double)cur.freq);
    for (int i = 0; i < rn; i++)
        printf("%s%.0fHz\n", fabs(rates[i] - cur.freq) < 0.5 ? "current " : "", rates[i]);
}

static int cmd_mode(CGDirectDisplayID did, const char *spec, int revertSecs) {
    ModeSpec sp;
    if (parse_mode_spec(spec, &sp) != 0) { fprintf(stderr, "模式规格无法解析: %s\n", spec); return 2; }

    char curSpec[80] = {0};
    CGDisplayModeRef cur = CGDisplayCopyDisplayMode(did);
    if (cur) {
        snprintf(curSpec, sizeof curSpec, "%zux%zu@%.0f%s",
                 CGDisplayModeGetWidth(cur), CGDisplayModeGetHeight(cur),
                 CGDisplayModeGetRefreshRate(cur), mode_is_hidpi(cur) ? ":hidpi" : ":lodpi");
    }
    int cnt = 0;
    CGDisplayModeRef m = find_mode(did, &sp, &cnt);
    if (!m) {
        fprintf(stderr, "id=%u 找不到匹配 %s 的模式。用 `dlite modes %u` 查看可用模式\n", did, spec, did);
        if (cur) CFRelease(cur);
        return 1;
    }
    printf("id=%u 目标: %zux%zu %s @%.0fHz（%d 个候选）\n", did,
           CGDisplayModeGetWidth(m), CGDisplayModeGetHeight(m),
           mode_is_hidpi(m) ? "HiDPI" : "LoDPI", CGDisplayModeGetRefreshRate(m), cnt);

    if (revertSecs > 0 && curSpec[0]) spawn_revert_mode(did, curSpec, revertSecs);
    int rc = apply_mode(did, m);
    CFRelease(m);
    if (cur) CFRelease(cur);
    usleep(500000);

    CGDisplayModeRef now = CGDisplayCopyDisplayMode(did);
    if (now) {
        printf("  %s，当前: %zux%zu %s @%.0fHz\n", rc == 0 ? "已提交" : "失败",
               CGDisplayModeGetWidth(now), CGDisplayModeGetHeight(now),
               mode_is_hidpi(now) ? "HiDPI" : "LoDPI", CGDisplayModeGetRefreshRate(now));
        CFRelease(now);
    }
    return rc == 0 ? 0 : 1;
}

static int cmd_main(CGDirectDisplayID did) {
    if (CGDisplayIsMain(did)) { printf("id=%u 已是主显示器，无需操作\n", did); return 0; }
    int rc = set_main_display(did);
    usleep(500000);
    printf("id=%u 设为主显示器 → %s（当前主屏 id=%u）\n", did,
           rc == 0 ? "OK" : "失败", (unsigned)CGMainDisplayID());
    return rc == 0 ? 0 : 1;
}

// ---- 直接设置某块屏在全局坐标系里的原点 ----
static int cmd_origin(CGDirectDisplayID did, int x, int y) {
    CGDisplayConfigRef cfg = NULL;
    CGError e = CGBeginDisplayConfiguration(&cfg);
    if (e != kCGErrorSuccess || !cfg) return -1;
    e = CGConfigureDisplayOrigin(cfg, did, (int32_t)x, (int32_t)y);
    if (e != kCGErrorSuccess) { CGCancelDisplayConfiguration(cfg); return -2; }
    e = CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
    usleep(400000);
    CGRect b = CGDisplayBounds(did);
    printf("id=%u 原点设为 (%d,%d) → %s，当前 origin=%dx%d main=%d\n",
           did, x, y, e == kCGErrorSuccess ? "OK" : "失败",
           (int)b.origin.x, (int)b.origin.y, CGDisplayIsMain(did));
    return e == kCGErrorSuccess ? 0 : 3;
}

// ---- 在配置事务里设置某块屏原点（供 arrange 复用）----
static int set_origin_tx(CGDirectDisplayID did, int x, int y) {
    CGDisplayConfigRef cfg = NULL;
    CGError e = CGBeginDisplayConfiguration(&cfg);
    if (e != kCGErrorSuccess || !cfg) return -1;
    e = CGConfigureDisplayOrigin(cfg, did, (int32_t)x, (int32_t)y);
    if (e != kCGErrorSuccess) { CGCancelDisplayConfiguration(cfg); return -2; }
    e = CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
    return e == kCGErrorSuccess ? 0 : -3;
}

// ---- 显示器排序：把指定屏设为主屏，并把另一块放到其左或右 ----
// side: 1 = 主屏在左（副屏在其右，鼠标右滑进副屏）；0 = 主屏在右（副屏在其左，鼠标左滑进副屏）
// ---- 显示器排序：把指定屏设为主屏，并把其他屏摆到主屏的指定方向 ----
// side: "left" / "right" / "top" / "bottom"
static int cmd_arrange(CGDirectDisplayID mainDid, const char *side) {
    int goRight = !strcmp(side, "right");
    int goLeft  = !strcmp(side, "left");
    int goTop   = !strcmp(side, "top");
    int goBot   = !strcmp(side, "bottom");
    if (!goRight && !goLeft && !goTop && !goBot) {
        fprintf(stderr, "side 必须是 left / right / top / bottom\n");
        return 2;
    }
    int rc = set_main_display(mainDid);
    if (rc != 0) { fprintf(stderr, "设主屏失败 rc=%d\n", rc); return rc; }

    CGDirectDisplayID active[16]; uint32_t n = 0;
    CGGetActiveDisplayList(16, active, &n);
    CGRect mb = CGDisplayBounds(mainDid);
    int applied = 0;
    for (uint32_t i = 0; i < n; i++) {
        if (active[i] == mainDid) continue;
        CGRect b = CGDisplayBounds(active[i]);
        int x = 0, y = 0;
        if (goRight)      { x = (int)(mb.origin.x + mb.size.width); y = 0; }
        else if (goLeft)  { x = (int)(mb.origin.x - b.size.width); y = 0; }
        else if (goTop)   { x = 0; y = (int)(mb.origin.y + mb.size.height); }
        else if (goBot)   { x = 0; y = (int)(mb.origin.y - b.size.height); }
        if (set_origin_tx(active[i], x, y) == 0) applied++;
    }
    usleep(500000);
    const char *zh = goRight ? "右侧" : goLeft ? "左侧" : goTop ? "上方" : "下方";
    printf("已将主屏设为 id=%u，副屏置于主屏%s（共 %d 块副屏摆放）\n",
           mainDid, zh, applied);
    return 0;
}

// ---- 屏幕旋转（私有 CGS API；公开层只提供读角度 CGDisplayRotation）----
static int cmd_rotate(CGDirectDisplayID did, int deg) {
    if (deg != 0 && deg != 90 && deg != 180 && deg != 270) {
        fprintf(stderr, "旋转角度只支持 0 / 90 / 180 / 270\n");
        return 2;
    }
    if (!p_CGSRotate) {
        fprintf(stderr,
            "本机未导出 CGSConfigureDisplayRotation（Apple Silicon 较新系统常见），\n"
            "无法用本工具旋转；请到 系统设置 → 显示器 → 旋转 里调整。\n");
        return -1;
    }
    CGDisplayConfigRef cfg = NULL;
    CGError e = CGBeginDisplayConfiguration(&cfg);
    if (e != kCGErrorSuccess || !cfg) { fprintf(stderr, "无法开启显示配置事务 e=%d\n", (int)e); return -2; }
    e = p_CGSRotate(cfg, did, (double)deg);
    if (e != kCGErrorSuccess) { CGCancelDisplayConfiguration(cfg); fprintf(stderr, "CGSConfigureDisplayRotation 失败 e=%d\n", (int)e); return -2; }
    e = CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
    if (e != kCGErrorSuccess) { fprintf(stderr, "提交旋转失败 e=%d（可能该显示器不允许旋转）\n", (int)e); return -3; }
    usleep(600000);
    double now = CGDisplayRotation(did);
    printf("id=%u 旋转已设为 %d°，当前实际 %.0f°\n", did, deg, now);
    return 0;
}

// ---- 布局快照 / 还原（按 UUID 记录，防止显示器 ID 变动导致对不上）----
static const char *layout_path(void) {
    static char p[512];
    const char *h = getenv("HOME");
    snprintf(p, sizeof p, "%s/.dlite-layout", h ? h : "/tmp");
    return p;
}

static int cmd_layout_save(void) {
    CGDirectDisplayID all[16]; uint32_t n = 0;
    CGGetActiveDisplayList(16, all, &n);
    FILE *f = fopen(layout_path(), "w");
    if (!f) { fprintf(stderr, "无法写入 %s\n", layout_path()); return 1; }
    for (uint32_t i = 0; i < n; i++) {
        DispInfo d; fill_info(all[i], &d);
        CGRect b = CGDisplayBounds(all[i]);
        fprintf(f, "%s %d %d %d %d\n", d.uuid[0] ? d.uuid : "-",
                (int)b.origin.x, (int)b.origin.y, (int)b.size.width, (int)b.size.height);
    }
    fclose(f);
    printf("已保存 %u 块屏的布局到 %s\n", n, layout_path());
    return 0;
}

static int cmd_layout_show(void) {
    FILE *f = fopen(layout_path(), "r");
    if (!f) { printf("尚无布局快照（%s）\n", layout_path()); return 0; }
    char uuid[64]; int x, y, w, h;
    printf("布局快照 %s:\n", layout_path());
    while (fscanf(f, "%63s %d %d %d %d", uuid, &x, &y, &w, &h) == 5)
        printf("  %s @ %dx%d 尺寸 %dx%d\n", uuid, x, y, w, h);
    fclose(f);
    return 0;
}

static int cmd_layout_restore(void) {
    FILE *f = fopen(layout_path(), "r");
    if (!f) { fprintf(stderr, "尚无布局快照，先执行 dlite layout save\n"); return 1; }

    // 先把快照读进内存
    char uuids[16][64]; int xs[16], ys[16]; int n = 0;
    while (n < 16 && fscanf(f, "%63s %d %d %*d %*d", uuids[n], &xs[n], &ys[n]) == 3) n++;
    fclose(f);
    if (n == 0) { fprintf(stderr, "快照为空\n"); return 1; }

    CGDirectDisplayID active[16]; uint32_t na = 0;
    CGGetActiveDisplayList(16, active, &na);

    CGDisplayConfigRef cfg = NULL;
    CGError e = CGBeginDisplayConfiguration(&cfg);
    if (e != kCGErrorSuccess || !cfg) return 1;
    int applied = 0;
    for (int i = 0; i < n; i++) {
        for (uint32_t k = 0; k < na; k++) {
            DispInfo d; fill_info(active[k], &d);
            if (d.uuid[0] && !strcasecmp(d.uuid, uuids[i])) {
                if (CGConfigureDisplayOrigin(cfg, active[k], (int32_t)xs[i], (int32_t)ys[i]) == kCGErrorSuccess) applied++;
                break;
            }
        }
    }
    if (applied == 0) { CGCancelDisplayConfiguration(cfg); printf("快照里没有匹配到当前活动显示器\n"); return 1; }
    e = CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
    usleep(500000);
    printf("已按快照还原 %d 块屏的布局 → %s\n", applied, e == kCGErrorSuccess ? "OK" : "失败");
    return e == kCGErrorSuccess ? 0 : 3;
}

int main(int argc, char **argv) {
    load_symbols();
    load_cgs();
    if (argc < 2) {
        fprintf(stderr,
            "用法:\n"
            "  dlite list\n"
            "  dlite ddc get <id|uuid> <vcp>\n"
            "  dlite ddc set <id|uuid> <vcp> <值>\n"
            "  dlite disable <id|uuid> [--revert N]\n"
            "  dlite enable  <id|uuid>\n"
            "  dlite restore\n"
            "  dlite modes <id|uuid> [--all]\n"
            "  dlite rates <id|uuid>            # 当前分辨率+HiDPI 下可选的刷新率（降序）\n"
            "  dlite mode  <id|uuid> <1920x1080[@60][:hidpi|:lodpi]> [--revert N]\n"
            "  dlite hidpi <id|uuid> on|off|toggle\n"
            "  dlite main  <id|uuid>\n"
            "  dlite arrange <id|uuid> <left|right|top|bottom>\n"
            "  dlite rotate <id|uuid> <0|90|180|270>\n"
            "  dlite origin <id|uuid> <x> <y>\n"
            "  dlite layout [save|restore|show]\n"
            "  dlite cgs <id|uuid> [过滤串] / dlite cgsset <id|uuid> <modeNumber>\n"
            "VCP: 0x10 亮度 / 0x62 音量 / 0x12 对比度 / 0x8D 静音 / 0xD6 待机\n");
        return 2;
    }

    // 隐藏子命令：由 dlite disable --revert N 派生的独立进程调用
    if (!strcmp(argv[1], "__revert") && argc >= 4) {
        CGDirectDisplayID did = (CGDirectDisplayID)parse_num(argv[2]);
        int secs = atoi(argv[3]);
        sleep((unsigned)secs);
        if (set_display_enabled(did, 1) == 0) state_remove(did);
        return 0;
    }

    // 隐藏子命令：__revertmode <id> <模式规格> <秒>
    if (!strcmp(argv[1], "__revertmode") && argc >= 5) {
        CGDirectDisplayID did = (CGDirectDisplayID)parse_num(argv[2]);
        int secs = atoi(argv[4]);
        sleep((unsigned)secs);
        ModeSpec sp;
        if (parse_mode_spec(argv[3], &sp) == 0) {
            int c = 0;
            CGDisplayModeRef m = find_mode(did, &sp, &c);
            if (m) { apply_mode(did, m); CFRelease(m); }
        }
        return 0;
    }

    if (!strcmp(argv[1], "list")) { cmd_list(); return 0; }
    if (!strcmp(argv[1], "info")) { cmd_info(); return 0; }
    if (!strcmp(argv[1], "disabled")) {
        CGDirectDisplayID rec[32];
        int rn = state_load(rec, 32);
        for (int i = 0; i < rn; i++) printf("disabled id=%u\n", rec[i]);
        return 0;
    }
    if (!strcmp(argv[1], "presets")) {
        if (argc < 3) { fprintf(stderr, "用法: dlite presets <id|uuid>\n"); return 2; }
        CGDirectDisplayID did;
        if (resolve_target(argv[2], &did) != 0) { fprintf(stderr, "找不到显示器 %s\n", argv[2]); return 1; }
        cmd_presets(did);
        return 0;
    }
    if (!strcmp(argv[1], "restore")) { cmd_restore(); return 0; }

    // 私有 CGS 模式列表 / 按 modeNumber 切换（用于处理公开列表缺失 HiDPI 变体的情形）
    if (!strcmp(argv[1], "cgs")) {
        if (argc < 3) { fprintf(stderr, "用法: dlite cgs <id|uuid> [过滤串]\n"); return 2; }
        CGDirectDisplayID did;
        if (resolve_target(argv[2], &did) != 0) { fprintf(stderr, "找不到显示器 %s\n", argv[2]); return 1; }
        cmd_cgs(did, argc >= 4 ? argv[3] : NULL);
        return 0;
    }
    if (!strcmp(argv[1], "cgsset")) {
        if (argc < 4) { fprintf(stderr, "用法: dlite cgsset <id|uuid> <modeNumber>\n"); return 2; }
        CGDirectDisplayID did;
        if (resolve_target(argv[2], &did) != 0) { fprintf(stderr, "找不到显示器 %s\n", argv[2]); return 1; }
        int rc = cgs_apply_mode(did, (int)parse_num(argv[3]));
        usleep(500000);
        CGSDisplayMode m;
        char desc[64] = "(未知)";
        if (p_CGSGetCur) {
            int cn = -1;
            p_CGSGetCur(did, &cn);
            int n = cgs_mode_count(did);
            for (int i = 0; i < n; i++) {
                if (cgs_read_mode(did, i, &m) == 0 && (int)m.modeNumber == cn) {
                    snprintf(desc, sizeof desc, "%ux%u %s %uHz", m.width, m.height,
                             cgs_mode_is_hidpi(&m) ? "HiDPI" : "LoDPI", m.freq);
                    break;
                }
            }
        }
        printf("id=%u 应用 modeNumber=%s → %s，当前: %s\n", did, argv[3], rc == 0 ? "已提交" : "失败", desc);
        return rc == 0 ? 0 : 1;
    }

    if (!strcmp(argv[1], "mute")) {
        // 切换静音：DDC 0x62 归零 / 恢复上次音量（本屏不支持真正的 DDC mute）
        if (argc < 3) { fprintf(stderr, "用法: dlite mute <id|uuid>\n"); return 2; }
        CGDirectDisplayID did;
        if (resolve_target(argv[2], &did) != 0) { fprintf(stderr, "找不到显示器 %s\n", argv[2]); return 1; }
        CFTypeRef svc = service_for_display(did, NULL);
        if (!svc) { fprintf(stderr, "id=%u 无可用 DDC 通道\n", did); return 1; }
        uint16_t cur = 0, max = 0;
        if (ddc_get(svc, 0x62, &cur, &max) != 0) { fprintf(stderr, "读取音量失败\n"); CFRelease(svc); return 1; }
        int rc = 0;
        if (cur > 0) {
            FILE *f = fopen(volstate_path(), "w");
            if (f) { fprintf(f, "%u\n", cur); fclose(f); }
            rc = ddc_set(svc, 0x62, 0);
            printf("已静音（原音量 %u 已记住）\n", cur);
        } else {
            uint16_t restore = 0;
            FILE *f = fopen(volstate_path(), "r");
            if (f) { if (fscanf(f, "%hu", &restore) != 1) restore = 0; fclose(f); }
            if (restore == 0) restore = (max > 0) ? (uint16_t)(max / 2) : 50;
            rc = ddc_set(svc, 0x62, restore);
            printf("已取消静音（恢复到 %u）\n", restore);
        }
        CFRelease(svc);
        return rc == 0 ? 0 : 1;
    }

    if (!strcmp(argv[1], "survey")) {
        if (argc < 3) { fprintf(stderr, "用法: dlite survey <id|uuid> [输出文件]\n"); return 2; }
        CGDirectDisplayID did;
        if (resolve_target(argv[2], &did) != 0) { fprintf(stderr, "找不到显示器 %s\n", argv[2]); return 1; }
        cmd_survey(did, argc >= 4 ? argv[3] : NULL);
        return 0;
    }

    if (!strcmp(argv[1], "dcpcolors")) {
        if (argc < 3) { fprintf(stderr, "用法: dlite dcpcolors <id|uuid>\n"); return 2; }
        CGDirectDisplayID did;
        if (resolve_target(argv[2], &did) != 0) { fprintf(stderr, "找不到显示器 %s\n", argv[2]); return 1; }
        cmd_dcpcolors(did);
        return 0;
    }

    if (!strcmp(argv[1], "colormode")) {
        if (argc < 3) { fprintf(stderr, "用法: dlite colormode <id|uuid> [1..N]\n"); return 2; }
        CGDirectDisplayID did;
        if (resolve_target(argv[2], &did) != 0) { fprintf(stderr, "找不到显示器 %s\n", argv[2]); return 1; }
        cmd_colormode(did, argc >= 4 ? argv[3] : NULL);
        return 0;
    }

    if (!strcmp(argv[1], "fbprops")) {
        if (argc < 3) { fprintf(stderr, "用法: dlite fbprops <id|uuid> [过滤串] [v]\n"); return 2; }
        CGDirectDisplayID did;
        if (resolve_target(argv[2], &did) != 0) { fprintf(stderr, "找不到显示器 %s\n", argv[2]); return 1; }
        const char *f = (argc >= 4 && strcmp(argv[3], "v")) ? argv[3] : NULL;
        cmd_fbprops(did, f, (argc >= 5 && !strcmp(argv[4], "v")) || (argc >= 4 && !strcmp(argv[3], "v")));
        return 0;
    }

    if (!strcmp(argv[1], "privcp")) {
        if (argc < 4) { fprintf(stderr, "用法: dlite privcp <id|uuid> <hex多字节VCP>\n"); return 2; }
        CGDirectDisplayID did;
        if (resolve_target(argv[2], &did) != 0) { fprintf(stderr, "找不到显示器 %s\n", argv[2]); return 1; }
        CFTypeRef svc = service_for_display(did, NULL);
        if (!svc) { fprintf(stderr, "id=%u 无可用 DDC 通道\n", did); return 1; }
        ddc_probe_ext(svc, argv[3]);
        CFRelease(svc);
        return 0;
    }

    if (!strcmp(argv[1], "modes")) {
        if (argc < 3) { fprintf(stderr, "缺少目标显示器\n"); return 2; }
        CGDirectDisplayID did;
        if (resolve_target(argv[2], &did) != 0) { fprintf(stderr, "找不到显示器 %s\n", argv[2]); return 1; }
        int mAll = 0;
        for (int i = 3; i < argc; i++) if (!strcmp(argv[i], "--all")) mAll = 1;
        cmd_modes(did, mAll);
        return 0;
    }

    if (!strcmp(argv[1], "rates")) {
        if (argc < 3) { fprintf(stderr, "用法: dlite rates <id|uuid>\n"); return 2; }
        CGDirectDisplayID did;
        if (resolve_target(argv[2], &did) != 0) { fprintf(stderr, "找不到显示器 %s\n", argv[2]); return 1; }
        cmd_rates(did);
        return 0;
    }

    if (!strcmp(argv[1], "mode")) {
        if (argc < 4) {
            fprintf(stderr, "用法: dlite mode <id|uuid> <1920x1080[@60][:hidpi|:lodpi]> [--revert N]\n");
            return 2;
        }
        CGDirectDisplayID did;
        if (resolve_target(argv[2], &did) != 0) { fprintf(stderr, "找不到显示器 %s\n", argv[2]); return 1; }
        int rev = 0;
        for (int i = 4; i < argc - 1; i++) if (!strcmp(argv[i], "--revert")) rev = atoi(argv[i + 1]);
        return cmd_mode(did, argv[3], rev);
    }

    if (!strcmp(argv[1], "hidpi")) {
        if (argc < 4) { fprintf(stderr, "用法: dlite hidpi <id|uuid> on|off|toggle [--revert N]\n"); return 2; }
        CGDirectDisplayID did;
        if (resolve_target(argv[2], &did) != 0) { fprintf(stderr, "找不到显示器 %s\n", argv[2]); return 1; }
        int hrev = 0;
        for (int i = 4; i < argc - 1; i++) if (!strcmp(argv[i], "--revert")) hrev = atoi(argv[i + 1]);
        return cmd_hidpi(did, argv[3], hrev);
    }

    if (!strcmp(argv[1], "main")) {
        if (argc < 3) { fprintf(stderr, "缺少目标显示器\n"); return 2; }
        CGDirectDisplayID did;
        if (resolve_target(argv[2], &did) != 0) { fprintf(stderr, "找不到显示器 %s\n", argv[2]); return 1; }
        return cmd_main(did);
    }

    if (!strcmp(argv[1], "arrange")) {
        if (argc < 4) { fprintf(stderr, "用法: dlite arrange <id|uuid> <left|right|top|bottom>\n"); return 2; }
        CGDirectDisplayID did;
        if (resolve_target(argv[2], &did) != 0) { fprintf(stderr, "找不到显示器 %s\n", argv[2]); return 1; }
        return cmd_arrange(did, argv[3]);
    }

    if (!strcmp(argv[1], "rotate")) {
        if (argc < 4) { fprintf(stderr, "用法: dlite rotate <id|uuid> <0|90|180|270>\n"); return 2; }
        CGDirectDisplayID did;
        if (resolve_target(argv[2], &did) != 0) { fprintf(stderr, "找不到显示器 %s\n", argv[2]); return 1; }
        return cmd_rotate(did, (int)parse_num(argv[3]));
    }

    if (!strcmp(argv[1], "origin")) {
        if (argc < 5) { fprintf(stderr, "用法: dlite origin <id|uuid> <x> <y>\n"); return 2; }
        CGDirectDisplayID did;
        if (resolve_target(argv[2], &did) != 0) { fprintf(stderr, "找不到显示器 %s\n", argv[2]); return 1; }
        return cmd_origin(did, (int)parse_num(argv[3]), (int)parse_num(argv[4]));
    }

    if (!strcmp(argv[1], "layout")) {
        const char *sub = argc >= 3 ? argv[2] : "show";
        if (!strcmp(sub, "save")) return cmd_layout_save();
        if (!strcmp(sub, "restore")) return cmd_layout_restore();
        return cmd_layout_show();
    }

    if (!strcmp(argv[1], "ddc")) {
        // caps 只需要一个显示器参数，提前处理
        if (argc >= 4 && !strcmp(argv[2], "caps")) {
            CGDirectDisplayID did;
            if (resolve_target(argv[3], &did) != 0) { fprintf(stderr, "找不到显示器 %s\n", argv[3]); return 1; }
            CFTypeRef svc = service_for_display(did, NULL);
            if (!svc) { fprintf(stderr, "id=%u 无可用 DDC 通道\n", did); return 1; }
            int rcc = ddc_caps_dump(svc);
            CFRelease(svc);
            return rcc == 0 ? 0 : 1;
        }
        if (argc < 5) { fprintf(stderr, "ddc 参数不足\n"); return 2; }
        const char *sub = argv[2], *tgt = argv[3];
        CGDirectDisplayID did;
        if (resolve_target(tgt, &did) != 0) { fprintf(stderr, "找不到显示器 %s\n", tgt); return 1; }
        uint8_t vcp = (uint8_t)parse_num(argv[4]);
        CFTypeRef svc = service_for_display(did, NULL);
        if (!svc) { fprintf(stderr, "id=%u 无可用 DDC 通道\n", did); return 1; }
        int rc = 0;
        if (!strcmp(sub, "get")) {
            uint16_t cur = 0, max = 0;
            rc = ddc_get(svc, vcp, &cur, &max);
            if (rc == 0) printf("id=%u vcp=0x%02X cur=%u max=%u\n", did, vcp, cur, max);
            else fprintf(stderr, "读取失败 rc=%d\n", rc);
        } else if (!strcmp(sub, "bump")) {
            // 相对增减：一次调用内完成读+写，供快捷键连发使用（避免两次进程开销）
            if (argc < 6) { fprintf(stderr, "用法: dlite ddc bump <id|uuid> <vcp> <±N>\n"); rc = 2; }
            else {
                uint16_t cur = 0, max = 0;
                if (ddc_get(svc, vcp, &cur, &max) != 0) { fprintf(stderr, "读取失败\n"); rc = 1; }
                else {
                    long nv = (long)cur + parse_num(argv[5]);
                    if (nv < 0) nv = 0;
                    if (max > 0 && nv > (long)max) nv = (long)max;
                    rc = ddc_set(svc, vcp, (uint16_t)nv);
                    if (rc == 0) printf("id=%u vcp=0x%02X %u → %ld\n", did, vcp, cur, nv);
                    else fprintf(stderr, "写入失败 rc=%d\n", rc);
                }
            }
        } else if (!strcmp(sub, "caps")) {
            rc = ddc_caps_dump(svc);
        } else if (!strcmp(sub, "set")) {
            if (argc < 6) { fprintf(stderr, "缺少值\n"); rc = 2; }
            else {
                uint16_t v = (uint16_t)parse_num(argv[5]);
                rc = ddc_set(svc, vcp, v);
                if (rc == 0) {
                    usleep(80000);
                    uint16_t cur = 0, max = 0;
                    if (ddc_get(svc, vcp, &cur, &max) == 0)
                        printf("id=%u vcp=0x%02X 已写入 %u，回读 cur=%u max=%u\n", did, vcp, v, cur, max);
                    else printf("id=%u vcp=0x%02X 已写入 %u（回读失败）\n", did, vcp, v);
                } else fprintf(stderr, "写入失败 rc=%d\n", rc);
            }
        } else { fprintf(stderr, "未知 ddc 子命令 %s\n", sub); rc = 2; }
        CFRelease(svc);
        return rc;
    }

    if (!strcmp(argv[1], "disable") || !strcmp(argv[1], "enable")) {
        if (argc < 3) { fprintf(stderr, "缺少目标显示器\n"); return 2; }
        CGDirectDisplayID did;
        if (resolve_target(argv[2], &did) != 0) { fprintf(stderr, "找不到显示器 %s\n", argv[2]); return 1; }
        int enable = !strcmp(argv[1], "enable");

        if (!enable) {
            // 安全闸：绝不能把最后一块活动屏断开，否则用户将失去操作界面
            uint32_t ac = active_count();
            if (ac <= 1) {
                fprintf(stderr, "拒绝：当前只有 %u 块活动显示器，断开后将无屏可用\n", ac);
                return 3;
            }
            if (!CGDisplayIsActive(did)) { printf("id=%u 本就未启用，无需操作\n", did); return 0; }
        }

        // --revert N：交给独立子进程兜底回收，主进程即使被杀也能恢复
        int revert = 0;
        for (int i = 3; i < argc - 1; i++)
            if (!strcmp(argv[i], "--revert")) revert = atoi(argv[i + 1]);

        if (revert > 0 && !enable) spawn_revert(did, revert);

        int rc = set_display_enabled(did, enable);
        usleep(400000);
        if (rc == 0) {
            if (enable) state_remove(did); else state_add(did);
            CGDirectDisplayID a[16]; uint32_t n = 0;
            CGGetActiveDisplayList(16, a, &n);
            int stillActive = 0;
            for (uint32_t i = 0; i < n; i++) if (a[i] == did) stillActive = 1;
            printf("id=%u 已%s，当前活动显示器 %u 块，目标 active=%d\n",
                   did, enable ? "连回" : "断开", n, stillActive);
        }
        return rc == 0 ? 0 : 1;
    }

    fprintf(stderr, "未知命令 %s\n", argv[1]);
    return 2;
}

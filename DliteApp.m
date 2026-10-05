// DliteApp.m — dlite 菜单栏应用（AppKit + Carbon 全局热键），引擎为同目录下的 dlite 命令行工具
// 编译: clang -O2 -fobjc-arc -o DliteApp DliteApp.m -framework Cocoa -framework Carbon
#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreFoundation/CFMachPort.h>
#import <ApplicationServices/ApplicationServices.h>
#include <dlfcn.h>          // HDR 开关要走 CoreDisplay 私有接口（运行时 dlsym）

@class OSDBar;
@class DlDisp;

// macOS 26 SDK 已从公开头文件移除了事件 tap 的全部常量（运行时符号仍在），这里手动补齐。
// kCGEventSystemDefined / 各 kCG* 的枚举值在所有 macOS 版本里是冻结不变的。
#if !defined(kCGEventSystemDefined)
#define kCGEventSystemDefined        ((CGEventType)14)
#endif
#if !defined(kCGEventTapDisabledByTimeout)
#define kCGEventTapDisabledByTimeout ((CGEventType)0xFFFFFFFDUL)
#endif
#define kCGEventTapLocHID           ((CGEventTapLocation)0)   // kCGHIDEventTap，在 HID 层最早拿到按键
#define kCGEventTapPlaceHIDHead     ((CGEventTapPlacement)0)  // kCGHeadInsertEventTap
#define kCGEventTapLocSession       ((CGEventTapLocation)1)   // kCGSessionEventTap
#define kCGEventTapPlaceSession     ((CGEventTapPlacement)1)   // kCGSessionEventTap
#define kCGEventTapOptDefault       ((CGEventTapOptions)0)     // kCGEventTapOptionDefault
#define kCGEventMaskSysDefined      ((CGEventMask)1 << 14)     // 1 << kCGEventSystemDefined
#define kCGEventMaskKeyDownUp       ((CGEventMask)((1 << 10) | (1 << 11)))   // kCGEventKeyDown | kCGEventKeyUp

// ============================ 配置 ============================
static NSString *ConfPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@".nicedisplay.conf"];
}

static NSMutableDictionary *gConf = nil;

static NSDictionary *DefaultConf(void) {
    return @{
        // 媒体键（Fn+F1/F2 亮度、F10/F11/F12 音量）已覆盖日常使用；
        // 这些组合键默认留空 = 不注册、不显示。需要时可自己填。
        @"brightnessUp": @"",
        @"brightnessDown": @"",
        @"volumeUp": @"",
        @"volumeDown": @"",
        @"hidpi": @"",
        @"main": @"",
        @"connect": @"",
        @"mode1": @"",
        @"mode2": @"",
        @"stepBrightness": @"2",
        @"stepVolume": @"2",
        @"mode1Spec": @"3840x2160",
        @"mode2Spec": @"1920x1080",
        // 菜单只显示亮度与音量，其余控制项默认隐藏
        @"showBrightness": @"1",
        @"showVolume": @"1",
        @"showResolution": @"1",
        @"showRate": @"1",
        @"showHiDPI": @"0",
        @"showMain": @"0",
        @"showConnected": @"0",
        // 调节时弹出的 OSD 浮层。默认关闭：它在 tap 回调里建窗口/跑动画会拖慢回调导致 tap 被系统 disable
        @"showOSD": @"0",
        @"launchAtLogin": @"0",
        @"lastSecondaryID": @"0",
        // 接管妙控键盘原生亮度/音量键
        @"mediaKeys": @"1",
        // F7/F8/F9 直按控制播放（在 tap 里把标准键码转发成系统媒体事件）；关闭则原样放行
        @"fnPlaybackKeys": @"1",
        // 音量键智能分流：当前音频输出不是显示器（蓝牙耳机/音箱、内置扬声器等）时，
        // 把 F10/F11/F12 转发成系统音量媒体键，而不是去改显示器 DDC 音量。
        @"volKeySmartRoute": @"1",
        @"mediaVolumeTarget": @"audio",
        // 亮度键作用屏：main=主屏（默认，与旧版行为一致） mouse=鼠标所在屏 或直接填显示器 id
        @"brightnessTarget": @"main",
    };
}

static NSArray *HotkeyKeys(void) {
    return @[@"brightnessUp", @"brightnessDown", @"volumeUp", @"volumeDown", @"hidpi", @"main", @"connect", @"mode1", @"mode2"];
}
static NSArray *HotkeyTitles(void) {
    return @[@"亮度 +", @"亮度 −", @"音量 +", @"音量 −", @"高分辨率 (HiDPI)", @"切换主屏", @"副屏连接/断开", @"分辨率 1", @"分辨率 2"];
}

static void LoadConf(void) {
    gConf = [DefaultConf() mutableCopy];
    // 从旧配置文件名（.dlite-app.conf）一次性迁移到新名（.nicedisplay.conf）
    NSString *oldPath = [NSHomeDirectory() stringByAppendingPathComponent:@".dlite-app.conf"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:ConfPath()] &&
        [[NSFileManager defaultManager] fileExistsAtPath:oldPath]) {
        [[NSFileManager defaultManager] copyItemAtPath:oldPath toPath:ConfPath() error:NULL];
    }
    NSString *txt = [NSString stringWithContentsOfFile:ConfPath() encoding:NSUTF8StringEncoding error:NULL];
    if (!txt) return;
    for (NSString *raw in [txt componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (line.length == 0 || [line hasPrefix:@"#"]) continue;
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *k = [[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *v = [[line substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (k.length) gConf[k] = v;
    }
}

static void SaveConf(void) {
    NSMutableString *s = [NSMutableString string];
    [s appendString:@"# NiceDisplay 配置文件\n"];
    [s appendString:@"# 改完执行：菜单 → 设置… → 快捷键 → 保存并重新加载\n"];
    [s appendString:@"# 快捷键写法：ctrl/alt/shift/cmd 用 + 连接，最后一段是键名\n"];
    [s appendString:@"#   键名可用：up down left right space tab return escape delete\n"];
    [s appendString:@"#             0-9 a-z f1-f12  - = [ ] ; ' , . / \\ `\n\n"];
    [s appendString:@"# ---- 快捷键 ----\n"];
    NSArray *hk = HotkeyKeys();
    for (NSUInteger i = 0; i < hk.count; i++)
        [s appendFormat:@"%@=%@\n", hk[i], gConf[hk[i]]];
    [s appendString:@"\n# ---- 增减步长（百分比）----\n"];
    [s appendFormat:@"stepBrightness=%@\n", gConf[@"stepBrightness"]];
    [s appendFormat:@"stepVolume=%@\n", gConf[@"stepVolume"]];
    [s appendString:@"\n# ---- 快捷键 1 / 2 对应的分辨率（写法：宽x高[@刷新率][:hidpi|:lodpi]）----\n"];
    [s appendFormat:@"mode1Spec=%@\n", gConf[@"mode1Spec"]];
    [s appendFormat:@"mode2Spec=%@\n", gConf[@"mode2Spec"]];
    [s appendString:@"\n# ---- 菜单里显示哪些项（1 显示 / 0 隐藏）----\n"];
    for (NSString *k in @[@"showBrightness", @"showVolume", @"showResolution", @"showRate", @"showHiDPI", @"showMain", @"showConnected", @"showOSD", @"fnPlaybackKeys"])
        [s appendFormat:@"%@=%@\n", k, gConf[k]];
    [s appendString:@"\n# ---- 原生键盘亮度/音量键（妙控键盘 Fn+F1/F2/F10/F11/F12）----\n"];
    [s appendString:@"# mediaKeys=1 接管；0 不接管（交给系统）\n"];
    [s appendFormat:@"mediaKeys=%@\n", gConf[@"mediaKeys"]];
    [s appendString:@"# mediaVolumeTarget: audio=自动跟随当前音频输出设备  main=主屏  或直接填显示器 id\n"];
    [s appendFormat:@"mediaVolumeTarget=%@\n", gConf[@"mediaVolumeTarget"]];
    [s appendString:@"# brightnessTarget: main=只调主屏（默认）  mouse=调鼠标所在屏  或直接填显示器 id\n"];
    [s appendFormat:@"brightnessTarget=%@\n", gConf[@"brightnessTarget"]];
    [s appendString:@"\n# ---- 开机自启 ----\n"];
    [s appendFormat:@"launchAtLogin=%@\n", gConf[@"launchAtLogin"]];
    [s writeToFile:ConfPath() atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

// ============================ 引擎调用 ============================
static NSString *CLIPath(void) {
    static NSString *p = nil;
    if (p) return p;
    NSString *exe = [[NSBundle mainBundle] executablePath];
    if (exe) p = [[exe stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"dlite"];
    if (!p || ![[NSFileManager defaultManager] isExecutableFileAtPath:p])
        p = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:@"dlite"];
    return p;
}

static NSString *RunCLI(NSArray *args) {
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = CLIPath();
    t.arguments = args;
    NSPipe *pipe = [NSPipe pipe];
    t.standardOutput = pipe;
    t.standardError = pipe;
    @try { [t launch]; } @catch (NSException *e) { return @""; }
    NSData *d = [[pipe fileHandleForReading] readDataToEndOfFile];
    [t waitUntilExit];
    NSString *out = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    return out ?: @"";
}

static void RunCLIAsync(NSArray *args, void (^done)(NSString *)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *o = RunCLI(args);
        if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(o); });
    });
}

// 从 "id=3 vcp=0x10 cur=76 max=100" 里取出 cur 数值
static int ReadDDCValue(int did, int vcp) {
    NSString *out = RunCLI(@[@"ddc", @"get", [NSString stringWithFormat:@"%d", did],
                             vcp == 0x10 ? @"0x10" : @"0x62"]);
    NSRange r = [out rangeOfString:@"cur="];
    if (r.location == NSNotFound) return -1;
    NSString *rest = [out substringFromIndex:r.location + 4];
    NSMutableString *num = [NSMutableString string];
    for (NSUInteger i = 0; i < rest.length; i++) {
        unichar ch = [rest characterAtIndex:i];
        if (ch >= '0' && ch <= '9') [num appendFormat:@"%C", ch];
        else break;
    }
    return num.intValue;
}

// ============================ 热键解析 ============================
static int KeyCodeForName(NSString *name) {
    static NSDictionary *m = nil;
    if (!m) {
        m = @{
            @"up": @(kVK_UpArrow), @"down": @(kVK_DownArrow), @"left": @(kVK_LeftArrow), @"right": @(kVK_RightArrow),
            @"space": @(kVK_Space), @"tab": @(kVK_Tab), @"return": @(kVK_Return), @"enter": @(kVK_Return),
            @"escape": @(kVK_Escape), @"esc": @(kVK_Escape), @"delete": @(kVK_Delete),
            @"a": @(kVK_ANSI_A), @"b": @(kVK_ANSI_B), @"c": @(kVK_ANSI_C), @"d": @(kVK_ANSI_D),
            @"e": @(kVK_ANSI_E), @"f": @(kVK_ANSI_F), @"g": @(kVK_ANSI_G), @"h": @(kVK_ANSI_H),
            @"i": @(kVK_ANSI_I), @"j": @(kVK_ANSI_J), @"k": @(kVK_ANSI_K), @"l": @(kVK_ANSI_L),
            @"m": @(kVK_ANSI_M), @"n": @(kVK_ANSI_N), @"o": @(kVK_ANSI_O), @"p": @(kVK_ANSI_P),
            @"q": @(kVK_ANSI_Q), @"r": @(kVK_ANSI_R), @"s": @(kVK_ANSI_S), @"t": @(kVK_ANSI_T),
            @"u": @(kVK_ANSI_U), @"v": @(kVK_ANSI_V), @"w": @(kVK_ANSI_W), @"x": @(kVK_ANSI_X),
            @"y": @(kVK_ANSI_Y), @"z": @(kVK_ANSI_Z),
            @"0": @(kVK_ANSI_0), @"1": @(kVK_ANSI_1), @"2": @(kVK_ANSI_2), @"3": @(kVK_ANSI_3),
            @"4": @(kVK_ANSI_4), @"5": @(kVK_ANSI_5), @"6": @(kVK_ANSI_6), @"7": @(kVK_ANSI_7),
            @"8": @(kVK_ANSI_8), @"9": @(kVK_ANSI_9),
            @"f1": @(kVK_F1), @"f2": @(kVK_F2), @"f3": @(kVK_F3), @"f4": @(kVK_F4),
            @"f5": @(kVK_F5), @"f6": @(kVK_F6), @"f7": @(kVK_F7), @"f8": @(kVK_F8),
            @"f9": @(kVK_F9), @"f10": @(kVK_F10), @"f11": @(kVK_F11), @"f12": @(kVK_F12),
            @"-": @(kVK_ANSI_Minus), @"=": @(kVK_ANSI_Equal),
            @"[": @(kVK_ANSI_LeftBracket), @"]": @(kVK_ANSI_RightBracket),
            @";": @(kVK_ANSI_Semicolon), @"'": @(kVK_ANSI_Quote),
            @",": @(kVK_ANSI_Comma), @".": @(kVK_ANSI_Period),
            @"/": @(kVK_ANSI_Slash), @"\\": @(kVK_ANSI_Backslash), @"`": @(kVK_ANSI_Grave),
        };
    }
    NSNumber *n = m[[name lowercaseString]];
    return n ? [n intValue] : -1;
}

static BOOL ParseHotkey(NSString *s, UInt32 *outKey, UInt32 *outMods) {
    if (s.length == 0) return NO;
    NSArray *parts = [s componentsSeparatedByString:@"+"];
    UInt32 mods = 0;
    for (NSUInteger i = 0; i + 1 < parts.count; i++) {
        NSString *p = [[parts[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lowercaseString];
        if ([p isEqualToString:@"ctrl"] || [p isEqualToString:@"control"]) mods |= controlKey;
        else if ([p isEqualToString:@"alt"] || [p isEqualToString:@"option"] || [p isEqualToString:@"opt"]) mods |= optionKey;
        else if ([p isEqualToString:@"shift"]) mods |= shiftKey;
        else if ([p isEqualToString:@"cmd"] || [p isEqualToString:@"command"]) mods |= cmdKey;
        else return NO;
    }
    NSString *last = [[parts.lastObject stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lowercaseString];
    int kc = KeyCodeForName(last);
    if (kc < 0) return NO;
    *outKey = (UInt32)kc;
    *outMods = mods;
    return YES;
}

// 手绘状态栏图标（Metro 风格：极简显示器轮廓）。
// 不用 SF Symbols —— 符号名缺失时 imageWithSystemSymbolName 会返回 nil，图标就没了。
static NSImage *StatusBarIcon(void) {
    NSSize sz = NSMakeSize(19, 16);
    NSImage *img = [NSImage imageWithSize:sz flipped:NO drawingHandler:^BOOL(NSRect r) {
        [[NSColor blackColor] set];
        // 整体下移 1pt：原来内容重心偏上，菜单栏里看着"吊"着，往下挪才居中
        NSBezierPath *screen = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(1.3, 4.2, 16.4, 9.6)
                                                              xRadius:1.6 yRadius:1.6];
        screen.lineWidth = 1.7;
        [screen stroke];
        NSBezierPath *stand = [NSBezierPath bezierPath];
        [stand moveToPoint:NSMakePoint(6.2, 1.3)];
        [stand lineToPoint:NSMakePoint(12.8, 1.3)];
        stand.lineWidth = 1.7;
        stand.lineCapStyle = NSLineCapStyleRound;
        [stand stroke];
        return YES;
    }];
    img.template = YES;   // 模板图：菜单栏明暗主题自动适配
    return img;
}

// ============================ 原生媒体键 ============================
// 妙控键盘：Fn+F1 亮度−  Fn+F2 亮度+  Fn+F10 静音  Fn+F11 音量−  Fn+F12 音量+
enum {
    NX_KEYTYPE_SOUND_UP = 0,
    NX_KEYTYPE_SOUND_DOWN = 1,
    NX_KEYTYPE_BRIGHTNESS_UP = 2,
    NX_KEYTYPE_BRIGHTNESS_DOWN = 3,
    NX_KEYTYPE_MUTE = 7,
    // 播放控制（F7/F8/F9 转发用；这三种事件我们不接管，直接交给系统）
    NX_KEYTYPE_PLAY = 16,
    NX_KEYTYPE_NEXT = 17,
    NX_KEYTYPE_PREVIOUS = 18,
};
#define NX_SUBTYPE_AUX_CONTROL_BUTTONS 8

// ============================ HDR 探测 & 软件调暗 ============================
// 【根因】显示器开启"高动态范围"(HDR) 后，会按像素在内部管理亮度，**多数显示器直接停止接受
// DDC/CI 亮度命令**（VCP 0x10）。实测：QSN-CBB 开 HDR 后写 0x10=45，回读立刻仍是 100 ——
// 写入被显示器丢弃。同样的写入在未开 HDR 的 AOC 上正常保持。
// 业界共识（BetterDisplay 官方文档亦如此）：HDR 模式下第三方屏的 DDC 亮度不可靠，
// 主流做法是改用**软件调暗**。故：HDR 屏走软件调暗，关掉 HDR 自动切回 DDC 真亮度。
//
// HDR 判定用公开 API NSScreen.maxExtendedDynamicRangeColorComponentValue：
//   > 1.0 表示该屏支持/已进入扩展动态范围（实测 HDR 开的屏 = 1.2，未开的 = 1.0）。

// 该屏是否处于 HDR / 扩展动态范围状态
static BOOL DisplayIsEDR(CGDirectDisplayID did) {
    for (NSScreen *s in [NSScreen screens]) {
        NSNumber *n = s.deviceDescription[@"NSScreenNumber"];
        if (!n || (int)n.unsignedIntValue != (int)did) continue;
        // 私有 KVC：公开头文件里没有该属性，但 AppKit 运行时确实提供
        @try {
            double v = [[s valueForKey:@"maximumExtendedDynamicRangeColorComponentValue"] doubleValue];
            if (v > 1.02) return YES;
        } @catch (NSException *e) { /* 该系统没这个属性 → 视为非 HDR */ }
        return NO;
    }
    return NO;
}

// —— 软件调暗：给指定屏幕挂一个黑色叠加层，用"压暗程度"模拟亮度 ——
// 这是 HDR 下唯一能让画面变暗、又不碰显示器背光的方式（与 BetterDisplay"叠加调暗"同思路）。
// 同一块屏只保留一个 overlay：重复调用只改不透明度，不叠加。
//
// ⚠️⚠️ 语义坑（曾把用户屏幕搞成全黑）：这里存的是**亮度**（0~100，100=最亮），
// 而叠加层要的是**黑度**，两者是**反向**的：
//     黑度 = (1 - 亮度/100) × 0.9
// 一开始直接把"亮度值"当黑度用（亮度 90 → 盖 90% 黑），结果一按亮度键屏幕就全黑了。
// 另加 MAX=0.9 上限：即使亮度调到 0 也保留一点点可见度，避免用户把自己"调瞎"没法恢复。
#define ND_SW_DIM_MAX 0.9
static void NDLog(NSString *fmt, ...);      // 前置声明（定义在文件后部）

// ⚠️ 状态一律按**显示器 UUID** 存，不能按 CGDirectDisplayID：
// 实测这台机器的显示器 ID 会漂移（QSN-CBB 曾 2→1、AOC 曾 1→3）。按 ID 存会出现
// "旧遮罩窗口残留、新 ID 查不到亮度值" → 屏幕仍被压暗但滑条显示 100%（看起来就是"乱跳"）。
static NSMutableDictionary *ndSwBright = nil;        // uuid -> NSNumber(软件亮度 0~100)
static NSMutableDictionary *ndOverlayWindows = nil;  // uuid -> NSWindow(遮罩窗口)
static NSMutableDictionary *ndOverlayViews = nil;    // uuid -> NSView(黑色内容视图)

static void ndOverlayInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ndSwBright = [NSMutableDictionary dictionary];
        ndOverlayWindows = [NSMutableDictionary dictionary];
        ndOverlayViews = [NSMutableDictionary dictionary];
    });
}
static NSString *ndUUIDForDisplay(CGDirectDisplayID did) {
    CFUUIDRef u = CGDisplayCreateUUIDFromDisplayID(did);
    if (!u) return nil;
    CFStringRef s = CFUUIDCreateString(kCFAllocatorDefault, u);
    CFRelease(u);
    if (!s) return nil;
    return (__bridge_transfer NSString *)s;
}
static NSScreen *ndScreenForDisplay(CGDirectDisplayID did) {
    for (NSScreen *s in [NSScreen screens]) {
        NSNumber *n = s.deviceDescription[@"NSScreenNumber"];
        if (n && (int)n.unsignedIntValue == (int)did) return s;
    }
    return nil;
}

// 确保某块屏的遮罩窗口已存在（没有就建）。必须在主线程调用。
static BOOL ndEnsureOverlay(NSString *uuid, NSScreen *screen) {
    ndOverlayInit();
    if (!uuid.length || !screen) return NO;
    if (ndOverlayWindows[uuid]) return YES;

    // 覆盖整块屏幕的置顶层窗口。
    // ⚠️⚠️ 两个坑都踩过，缺一不可：
    //  1) 背景色必须显式设成 clearColor。NSWindow 默认背景是**不透明的** windowBackgroundColor，
    //     一旦漏设，这个全屏窗口一显示就把整块屏盖成一块不透明灰/黑 → 用户看到"一调就黑屏"。
    //  2) 必须带**黑色内容视图**。用 opaque=NO + clearColor 的"空窗口"时，AppKit 判定它无内容
    //     直接不合成，怎么改 alpha 屏幕都没反应（用户看到"调了没效果"）。
    // 正确组合：窗口 clearColor + contentView 是黑色视图，用后者的 opacity 控制压暗程度。
    NSRect f = screen.frame;
    NSWindow *w = [[NSWindow alloc] initWithContentRect:f
                                              styleMask:NSWindowStyleMaskBorderless
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    w.level = NSStatusWindowLevel;      // 高于普通窗口，菜单栏也会被盖上（调暗就该如此）
    w.opaque = NO;
    w.backgroundColor = [NSColor clearColor];   // ← 关键：不设就会把整屏盖成不透明色
    w.hasShadow = NO;
    w.ignoresMouseEvents = YES;         // 不挡鼠标
    w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
                         | NSWindowCollectionBehaviorStationary
                         | NSWindowCollectionBehaviorIgnoresCycle
                         | NSWindowCollectionBehaviorFullScreenAuxiliary;
    w.releasedWhenClosed = NO;
    w.alphaValue = 1.0;                 // 窗口自身全不透明，由内容视图的不透明度控制压暗强度

    // 真正的调暗载体：一块纯黑视图，用其 opacity 表示"压暗多少"
    NSView *black = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, f.size.width, f.size.height)];
    black.wantsLayer = YES;
    black.layer.backgroundColor = [NSColor blackColor].CGColor;
    black.layer.opacity = 0.0;          // 初始不压暗
    black.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    w.contentView = black;
    [w orderFrontRegardless];

    ndOverlayWindows[uuid] = w;
    ndOverlayViews[uuid] = black;
    return YES;
}

// 设置软件"亮度"：bright 0~100（100 = 不压暗 = 最亮）
// ⚠️ 存的是**亮度**、遮罩要的是**黑度**，两者反向：黑度 = (1 - 亮度/100)^0.7 × 0.9。
// 曾把"亮度值"直接当黑度用（亮度 90 → 盖 90% 黑）→ 一按亮度键屏幕全黑。
// 上限 0.9：即使亮度调到 0 也留一点可见度，避免用户把自己"调瞎"没法恢复。
// 曲线 pow(0.7) 而非线性：HDR 屏硬件亮度锁死 100，软件遮罩是唯一手段，
// 线性时头几次按键的黑度只有 1~2%，肉眼看不出（会被当成"调了没反应"）。
static void ndSetSoftwareBrightness(CGDirectDisplayID did, int bright) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ ndSetSoftwareBrightness(did, bright); });
        return;
    }
    if (bright < 0) bright = 0;
    if (bright > 100) bright = 100;
    NSString *uuid = ndUUIDForDisplay(did);
    if (!uuid.length) return;
    NSScreen *screen = ndScreenForDisplay(did);
    if (!ndEnsureOverlay(uuid, screen)) return;

    ndSwBright[uuid] = @(bright);
    double dim = ND_SW_DIM_MAX * pow(1.0 - bright / 100.0, 0.7);
    NDLog(@"[hdr] display %d 软件亮度=%d%% → 黑度=%.1f%%", did, bright, dim * 100);
    NSWindow *w = ndOverlayWindows[uuid];
    [w setFrame:screen.frame display:YES];
    NSView *v = ndOverlayViews[uuid];
    v.layer.opacity = (float)dim;      // 强度作用在内容视图（窗口自身保持背景全透明）
    [v setNeedsDisplay:YES];
}

// 读回软件"亮度" 0~100；从未设置过返回 100（= 硬件最亮，没压暗）
static int ndGetSoftwareBrightness(CGDirectDisplayID did) {
    ndOverlayInit();
    NSString *uuid = ndUUIDForDisplay(did);
    if (!uuid.length) return 100;
    NSNumber *v = ndSwBright[uuid];
    if (!v) return 100;
    return (int)lround(v.doubleValue);
}

// 该屏当前是否挂着软件调暗层
static BOOL ndHasSoftwareDim(CGDirectDisplayID did) {
    ndOverlayInit();
    NSString *uuid = ndUUIDForDisplay(did);
    return uuid.length && ndSwBright[uuid] != nil;
}

// 移除某块屏的软件调暗层（关掉 HDR 后调用，恢复纯 DDC 控制）
static void ndClearSoftwareDim(CGDirectDisplayID did) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ ndClearSoftwareDim(did); });
        return;
    }
    ndOverlayInit();
    NSString *uuid = ndUUIDForDisplay(did);
    if (!uuid.length) return;
    NSView *v = ndOverlayViews[uuid];
    if (v) v.layer.opacity = 0;        // 先把黑视图调全透明，再撤窗
    NSWindow *w = ndOverlayWindows[uuid];
    if (w) [w orderOut:nil];
    [ndSwBright removeObjectForKey:uuid];
    [ndOverlayWindows removeObjectForKey:uuid];
    [ndOverlayViews removeObjectForKey:uuid];
}

// 对账：显示器热插拔 / ID 变化后，把已不存在屏幕的遮罩窗口收掉，
// 避免残留窗口一直压暗屏幕而用户又调不动（"黑屏 + 滑条乱跳"的成因之一）。
static void ndReconcileOverlays(NSArray<NSString *> *liveUUIDs) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ ndReconcileOverlays(liveUUIDs); });
        return;
    }
    ndOverlayInit();
    NSMutableArray *dead = [NSMutableArray array];
    for (NSString *uuid in ndOverlayWindows.allKeys)
        if (![liveUUIDs containsObject:uuid]) [dead addObject:uuid];
    for (NSString *uuid in dead) {
        NSView *v = ndOverlayViews[uuid];
        if (v) v.layer.opacity = 0;
        NSWindow *w = ndOverlayWindows[uuid];
        if (w) [w orderOut:nil];
        [ndSwBright removeObjectForKey:uuid];
        [ndOverlayWindows removeObjectForKey:uuid];
        [ndOverlayViews removeObjectForKey:uuid];
        NDLog(@"[hdr] 对账：收掉已消失显示器的遮罩 %@", uuid);
    }
}

// ============================ HDR（高动态范围）开关 ============================
// macOS 系统设置里的"高动态范围"开关由 CoreDisplay 私有接口承载：
//   CoreDisplay_Display_SupportsHDRMode(id)      能力查询 → 决定菜单里是否显示该项
//   CoreDisplay_Display_IsHDRModeEnabled(id)     当前是否开启
//   CoreDisplay_Display_SetHDRModeEnabled(id,on) 开关
// 实测：QSN-CBB 支持=1、AOC 支持=0；开关后 EDR 值在 1.0 / 1.2 之间变化，可作效果判据。
typedef Boolean (*NdHdrSupportsFn)(CGDirectDisplayID);
typedef Boolean (*NdHdrEnabledFn)(CGDirectDisplayID);
typedef void    (*NdHdrSetFn)(CGDirectDisplayID, Boolean);
static NdHdrSupportsFn ndHdrSupportsFn = NULL;
static NdHdrEnabledFn  ndHdrEnabledFn  = NULL;
static NdHdrSetFn      ndHdrSetFn      = NULL;

static void ndHDRLoad(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *cd = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY);
        if (!cd) return;
        ndHdrSupportsFn = (NdHdrSupportsFn)dlsym(cd, "CoreDisplay_Display_SupportsHDRMode");
        ndHdrEnabledFn  = (NdHdrEnabledFn)dlsym(cd, "CoreDisplay_Display_IsHDRModeEnabled");
        ndHdrSetFn      = (NdHdrSetFn)dlsym(cd, "CoreDisplay_Display_SetHDRModeEnabled");
    });
}
static BOOL ndHDRSupported(CGDirectDisplayID did) {
    ndHDRLoad();
    return ndHdrSupportsFn ? (BOOL)ndHdrSupportsFn(did) : NO;
}
static BOOL ndHDREnabled(CGDirectDisplayID did) {
    ndHDRLoad();
    return ndHdrEnabledFn ? (BOOL)ndHdrEnabledFn(did) : NO;
}
// 写入后**必须回读复核**：这个开关在部分第三方屏上会自己弹回去（用户就遇到过），
// 不复核的话菜单会显示成一个假状态。
static BOOL ndSetHDREnabled(CGDirectDisplayID did, BOOL on) {
    ndHDRLoad();
    if (!ndHdrSetFn) return NO;
    ndHdrSetFn(did, on ? 1 : 0);
    usleep(900000);
    return ndHDREnabled(did) == on;
}

// ============================ 声音输出设备（CoreAudio） ============================
// 【关键坑】蓝牙耳机在 CoreAudio 里是**两个同名设备**，靠 UID 区分：
//   「Misiom-Scorpio」UID=...:input  → 麦克风端点，出流=0
//   「Misiom-Scorpio」UID=...:output → 扬声器端点，出流=1 ← 这才是要的
// 按名字取"第一个匹配"会选中 input 端点，AudioObjectSetPropertyData 照样返回 noErr，
// 但读回默认设备根本没变 → 表现为"切到蓝牙没反应/没声音"。所以一律用 UID 定位。
// 另外 AudioDeviceID 在蓝牙重连后会变（实测 108 → 114），UID 才是稳定标识。

// 取设备的稳定 UID（取不到返回 nil）
static NSString *ndDeviceUID(AudioDeviceID d) {
    CFStringRef uid = NULL;
    UInt32 us = sizeof uid;
    AudioObjectPropertyAddress ua = {
        kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    if (AudioObjectGetPropertyData(d, &ua, 0, NULL, &us, &uid) != noErr || !uid) return nil;
    return (__bridge_transfer NSString *)uid;
}
static NSString *ndDeviceName(AudioDeviceID d) {
    CFStringRef nm = NULL;
    UInt32 nsz = sizeof nm;
    AudioObjectPropertyAddress na = {
        kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    if (AudioObjectGetPropertyData(d, &na, 0, NULL, &nsz, &nm) != noErr || !nm) return nil;
    return (__bridge_transfer NSString *)nm;
}
static int ndOutStreams(AudioDeviceID d) {
    AudioObjectPropertyAddress sc = {
        kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain
    };
    UInt32 ss = 0;
    if (AudioObjectGetPropertyDataSize(d, &sc, 0, NULL, &ss) != noErr || ss == 0) return 0;
    AudioBufferList *bl = calloc(1, ss);
    int n = 0;
    if (AudioObjectGetPropertyData(d, &sc, 0, NULL, &ss, bl) == noErr) n = bl->mNumberBuffers;
    free(bl);
    return n;
}
static BOOL ndDeviceAlive(AudioDeviceID d) {
    UInt32 a = 0, as = sizeof a;
    AudioObjectPropertyAddress aa = {
        kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    return AudioObjectGetPropertyData(d, &aa, 0, NULL, &as, &a) == noErr && a;
}

// 枚举"可用的输出设备"：返回 UID 数组（顺序稳定：显示器 → 耳机 → 音箱 → 内建，按 UID 字典序）
static NSArray<NSString *> *ndAudioOutputUIDs(void) {
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &size) != noErr) return @[];
    UInt32 n = size / sizeof(AudioDeviceID);
    if (!n) return @[];
    AudioDeviceID *devs = calloc(n, sizeof(AudioDeviceID));
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, devs) != noErr) {
        free(devs); return @[];
    }
    NSMutableArray *uids = [NSMutableArray array];
    for (UInt32 i = 0; i < n; i++) {
        if (ndOutStreams(devs[i]) <= 0) continue;      // 必须真有输出流（挡掉 :input 端点）
        if (!ndDeviceAlive(devs[i])) continue;          // 离线设备不列
        NSString *u = ndDeviceUID(devs[i]);
        if (u.length) [uids addObject:u];
    }
    free(devs);
    [uids sortUsingSelector:@selector(compare:)];
    return uids;
}

// 按 UID 找显示名（菜单展示用）
static NSString *ndNameForUID(NSString *uid) {
    if (!uid.length) return nil;
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &size) != noErr) return nil;
    UInt32 n = size / sizeof(AudioDeviceID);
    AudioDeviceID *devs = calloc(n, sizeof(AudioDeviceID));
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, devs) != noErr) {
        free(devs); return nil;
    }
    NSString *ret = nil;
    for (UInt32 i = 0; i < n && !ret; i++) {
        NSString *u = ndDeviceUID(devs[i]);
        if ([u isEqualToString:uid] && ndOutStreams(devs[i]) > 0) ret = ndDeviceName(devs[i]);
    }
    free(devs);
    return ret;
}

// 当前默认输出设备的 UID（比较菜单勾选状态用）
static NSString *ndCurrentOutputUID(void) {
    AudioObjectPropertyAddress da = {
        kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    AudioDeviceID dev = kAudioObjectUnknown;
    UInt32 cs = sizeof dev;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &da, 0, NULL, &cs, &dev) != noErr) return nil;
    if (dev == kAudioObjectUnknown) return nil;
    return ndDeviceUID(dev);
}

// 按 UID 切换默认输出设备。成功返回 YES。
static BOOL ndSetDefaultOutputByUID(NSString *wantUID) {
    if (!wantUID.length) return NO;
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &size) != noErr) return NO;
    UInt32 n = size / sizeof(AudioDeviceID);
    AudioDeviceID *devs = calloc(n, sizeof(AudioDeviceID));
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, devs) != noErr) {
        free(devs); return NO;
    }
    AudioDeviceID target = kAudioObjectUnknown;
    for (UInt32 i = 0; i < n; i++) {
        NSString *u = ndDeviceUID(devs[i]);
        if ([u isEqualToString:wantUID] && ndOutStreams(devs[i]) > 0) { target = devs[i]; break; }
    }
    free(devs);
    if (target == kAudioObjectUnknown) return NO;

    // 蓝牙耳机常是 44100、系统其他设备是 48000：切过去之前先把采样率对齐，
    // 否则音频流起不来（表现为切过去"没声音"）。
    Float64 cur = 0; UInt32 cs2 = sizeof cur;
    AudioObjectPropertyAddress sra = {
        kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain
    };
    if (AudioObjectGetPropertyData(target, &sra, 0, NULL, &cs2, &cur) == noErr && cur > 0 && cur < 48000) {
        Float64 want2 = 48000; UInt32 ts = sizeof want2;
        AudioObjectSetPropertyData(target, &sra, 0, NULL, ts, &want2);
    }

    AudioObjectPropertyAddress da = {
        kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    if (AudioObjectSetPropertyData(kAudioObjectSystemObject, &da, 0, NULL, sizeof target, &target) != noErr) return NO;

    // 复核：读回默认设备，确认真的切过去了（这一步能挡住"rc=0 但没生效"的假成功）
    usleep(400000);
    AudioDeviceID now = kAudioObjectUnknown; UInt32 ns = sizeof now;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &da, 0, NULL, &ns, &now) != noErr) return NO;
    return now == target;
}

// 当前默认输出设备名（复用上面已有实现）
static NSString *DefaultOutputDeviceName(void) {
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioDeviceID dev = kAudioObjectUnknown;
    UInt32 size = sizeof dev;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, &dev) != noErr) return nil;
    if (dev == kAudioObjectUnknown) return nil;

    CFStringRef nm = NULL;
    size = sizeof nm;
    AudioObjectPropertyAddress na = {
        kAudioObjectPropertyName,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    if (AudioObjectGetPropertyData(dev, &na, 0, NULL, &size, &nm) != noErr || !nm) return nil;
    return (__bridge_transfer NSString *)nm;
}

// ============================ 显示器模型 ============================
@interface DlDisp : NSObject
@property (nonatomic) int did;
@property (nonatomic, copy) NSString *uuid;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) BOOL isMain, isActive, hasDDC;
@property (nonatomic) int bright, bmax, vol, vmax;
@property (nonatomic) BOOL brightKnown, volKnown;   // 回读是否成功（失败时不能把 0 当真实值！）
@property (nonatomic) int modeW, modeH, modeHiDPI;
@property (nonatomic) double hz;
@property (nonatomic) int rot;
@end
@implementation DlDisp
- (NSString *)displayName {
    return self.name.length ? self.name : [NSString stringWithFormat:@"显示器 %d", self.did];
}
- (NSString *)summary {
    return [NSString stringWithFormat:@"%dx%d %@", self.modeW, self.modeH, self.modeHiDPI ? @"HiDPI" : @"LoDPI"];
}
@end

static NSArray *FetchDisplays(void) {
    NSString *out = RunCLI(@[@"info"]);
    NSMutableArray *arr = [NSMutableArray array];
    DlDisp *cur = nil;
    for (NSString *raw in [out componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (line.length == 0) continue;
        if ([line hasPrefix:@"display "]) {
            cur = [[DlDisp alloc] init];
            cur.bmax = 100; cur.vmax = 100;
            NSString *rest = [line substringFromIndex:8];
            // name= 放在行尾（名称可能含空格），单独取出后再解析其余键值
            NSRange nr = [rest rangeOfString:@"name="];
            if (nr.location != NSNotFound) {
                cur.name = [[rest substringFromIndex:nr.location + 5]
                            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                rest = [rest substringToIndex:nr.location];
            }
            for (NSString *kv in [rest componentsSeparatedByString:@" "]) {
                NSArray *p = [kv componentsSeparatedByString:@"="];
                if (p.count != 2) continue;
                if ([p[0] isEqualToString:@"id"]) cur.did = [p[1] intValue];
                else if ([p[0] isEqualToString:@"uuid"]) cur.uuid = p[1];
                else if ([p[0] isEqualToString:@"main"]) cur.isMain = [p[1] intValue] != 0;
                else if ([p[0] isEqualToString:@"active"]) cur.isActive = [p[1] intValue] != 0;
                else if ([p[0] isEqualToString:@"ddc"]) cur.hasDDC = [p[1] intValue] != 0;
            }
            [arr addObject:cur];
        } else if ([line isEqualToString:@"enddisplay"]) {
            cur = nil;
        } else if (cur) {
            NSArray *toks = [line componentsSeparatedByString:@" "];
            NSString *key = toks.count ? toks[0] : @"";
            if ([key isEqualToString:@"brightness"] || [key isEqualToString:@"volume"]) {
                int a = 0, b = 0;
                for (NSString *kv in toks) {
                    NSArray *p = [kv componentsSeparatedByString:@"="];
                    if (p.count != 2) continue;
                    if ([p[0] isEqualToString:@"cur"]) a = [p[1] intValue];
                    else if ([p[0] isEqualToString:@"max"]) b = [p[1] intValue];
                }
                if ([key isEqualToString:@"brightness"]) { cur.bright = a; if (b > 0) cur.bmax = b; cur.brightKnown = YES; }
                else { cur.vol = a; if (b > 0) cur.vmax = b; cur.volKnown = YES; }
            } else if ([key isEqualToString:@"mode"]) {
                for (NSString *kv in toks) {
                    NSArray *p = [kv componentsSeparatedByString:@"="];
                    if (p.count != 2) continue;
                    if ([p[0] isEqualToString:@"w"]) cur.modeW = [p[1] intValue];
                    else if ([p[0] isEqualToString:@"h"]) cur.modeH = [p[1] intValue];
                    else if ([p[0] isEqualToString:@"hidpi"]) cur.modeHiDPI = [p[1] intValue];
                    else if ([p[0] isEqualToString:@"hz"]) cur.hz = [p[1] doubleValue];
                }
            } else if ([key isEqualToString:@"rot"]) {
                if (toks.count >= 2) cur.rot = [toks[1] intValue];
            }
        }
    }
    return arr;
}

static NSArray *FetchDisabledIDs(void) {
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *raw in [RunCLI(@[@"disabled"]) componentsSeparatedByString:@"\n"]) {
        NSString *l = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        // 每行格式: disabled <uuid>[<TAB>显示器名]  |  软熄屏(27+): softoff <uuid>[<TAB>显示器名]
        if ([l hasPrefix:@"disabled "]) [a addObject:[[l substringFromIndex:9] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
        else if ([l hasPrefix:@"softoff "]) [a addObject:[[l substringFromIndex:8] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];   // 注意 "softoff " 是 8 字符，少裁一位会带前导空格导致 uuid 匹配不上
    }
    return a;
}

// ============================ 热键动作 ============================
typedef NS_ENUM(int, DlAction) {
    ActBrightUp = 0, ActBrightDown, ActVolUp, ActVolDown,
    ActHiDPI, ActMain, ActConnect, ActMode1, ActMode2, ActCount
};

static OSStatus HotkeyHandler(EventHandlerCallRef nextRef, EventRef ev, void *ctx);

// ============================ OSD 进度条（扁平 Metro 风） ============================
@interface OSDBar : NSView
@property (nonatomic) double pct;
@end
@implementation OSDBar
- (void)drawRect:(NSRect)r {
    [super drawRect:r];
    NSRect b = self.bounds;
    // 轨道（系统 OSD 样式：半透明白）
    NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:b xRadius:b.size.height/2 yRadius:b.size.height/2];
    [[NSColor colorWithWhite:1.0 alpha:0.22] set];
    [track fill];
    // 填充（白色实心，跟随 HUD 毛玻璃）
    double pct = MIN(MAX(self.pct, 0), 100) / 100.0;
    if (pct > 0.001) {
        NSRect fb = b; fb.size.width = b.size.width * pct;
        NSBezierPath *fill = [NSBezierPath bezierPathWithRoundedRect:fb xRadius:b.size.height/2 yRadius:b.size.height/2];
        [[NSColor colorWithWhite:1.0 alpha:0.92] set];
        [fill fill];
    }
}
@end

// OSD 浮层窗口：borderless + 永不作为 key/main 窗口，避免抢走键盘焦点导致快捷键失灵
@interface OSDWindow : NSWindow
@end
@implementation OSDWindow
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

// ============================ 主控制器 ============================
@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate>
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMutableArray *hotKeyRefs;
@property (nonatomic, strong) NSMutableArray *hotkeyActions;
@property (nonatomic, strong) NSTimer *repeatTimer;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, strong) NSTimer *healthTimer;   // 权限 / 监听器自愈
@property (nonatomic) BOOL engineBusy;
@property (nonatomic, strong) NSArray *displays;
@property (nonatomic, strong) NSDate *lastRefresh;   // 上次刷新时间（菜单打开加速用）
@property (nonatomic, strong) NSArray *disabledIDs;
@property (nonatomic, strong) NSWindow *settingsWindow;
@property (nonatomic, strong) NSTabView *tabView;
@property (nonatomic, strong) NSMutableDictionary *hkFields;
@property (nonatomic, strong) NSMutableDictionary *optFields;
@property (nonatomic, strong) NSMutableDictionary *showChecks;
@property (nonatomic, strong) NSButton *loginCheck;
@property (nonatomic, strong) NSButton *brightMouseCheck;
@property (nonatomic, strong) NSMutableDictionary *dispNameCache;
// 显示器 UUID → 名字（关闭显示器后系统会重新分配 display id，只有 UUID 能查出真实名字）
@property (nonatomic, strong) NSMutableDictionary *dispNameByUUID;   // did字符串 → 显示器名（断开后灰显用）
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic) CFMachPortRef mediaTap;
@property (nonatomic) BOOL mediaUnauthorized;
@property (nonatomic, strong) NSButton *mediaKeyCheck;
@property (nonatomic) BOOL betterDisplayRunning;
@property (nonatomic, copy) NSString *audioDeviceName;
// OSD 浮层（媒体键/滑块反馈）—— 长条状，左上角菜单栏下方
@property (nonatomic, strong) NSWindow *osdWindow;
@property (nonatomic, strong) NSImageView *osdIcon;
@property (nonatomic, strong) NSTextField *osdPct;
@property (nonatomic, strong) OSDBar *osdBar;
@property (nonatomic, strong) NSTimer *osdHideTimer;
// DDC 写入：应用侧绝对目标值 + 串行合并（避免 dlite 相对步进的"读-改-写"竞态导致亮度跳变）
@property (nonatomic, strong) NSMutableDictionary *ddcTarget;    // "did:vcp" → 目标值
@property (nonatomic, strong) NSMutableDictionary *ddcLastAct;   // "did:vcp" → 最后操作时间
@property (nonatomic, strong) NSMutableDictionary *ddcLatest;    // "did:vcp" → 待写入的最新值
@property (nonatomic, strong) NSMutableSet *ddcInFlight;         // 正在写入的 key
// 滑块节流
@property (nonatomic) BOOL sliderBusy;
@property (nonatomic) BOOL sliderDragging;
@property (nonatomic) int sliderPending;
@property (nonatomic, copy) NSString *sliderPendingIdent;
// 菜单是否展开（用于媒体键后同步菜单内滑块）
@property (nonatomic) BOOL menuIsOpen;
@property (nonatomic) BOOL menuBuilding;   // 菜单构建中（防重入：被打断会渲染出残缺菜单）
@end

@implementation AppDelegate

- (DlDisp *)mainDisp {
    for (DlDisp *d in self.displays) if (d.isMain) return d;
    return self.displays.count ? self.displays.firstObject : nil;
}

- (DlDisp *)secondaryDisp {
    for (DlDisp *d in self.displays) if (!d.isMain) return d;
    return nil;
}

- (int)secondaryID {
    DlDisp *s = [self secondaryDisp];
    if (s) {
        if ([gConf[@"lastSecondaryID"] intValue] != s.did) {
            gConf[@"lastSecondaryID"] = [NSString stringWithFormat:@"%d", s.did];
            SaveConf();
        }
        return s.did;
    }
    return [gConf[@"lastSecondaryID"] intValue];
}

// 音量键 / 静音键该作用在哪块屏
// 前向声明：系统音量辅助函数（具体定义见 ndPostMediaKey 之前）
static AudioDeviceID ndDefaultOutput(void);
static float ndSystemVolume(void);
static void ndSetSystemVolume(float v);
static BOOL ndSystemMuted(void);
static void ndSetSystemMute(BOOL on);
static BOOL ndDefaultOutputIsDisplay(void);

// 当前默认音频输出是不是"我们管理的某块显示器"。
// 主判据是传输类型（dprt/hdmi=显示器音频），比"名字匹配"稳得多 ——
// 显示器名(QSN-CBB)和音频设备全名(HUAWEI MateView GT)经常对不上，名字匹配是坑。
// 名字匹配仅作兜底。
- (BOOL)audioOutputIsDisplay {
    if (ndDefaultOutputIsDisplay()) return YES;          // DisplayPort/HDMI → 一定是显示器
    NSString *dev = self.audioDeviceName.length ? self.audioDeviceName : DefaultOutputDeviceName();
    if (!dev.length) return NO;
    for (DlDisp *d in self.displays) {
        NSString *nm = [d displayName];
        if (!nm.length) continue;
        if ([nm isEqualToString:dev]
            || [dev rangeOfString:nm].location != NSNotFound
            || [nm rangeOfString:dev].location != NSNotFound) return YES;
    }
    return NO;
}

// 音量/静音键分流：
//   音频输出 = 显示器（DP/HDMI）→ 走 DDC（原行为，显示器自带喇叭）
//   音频输出 ≠ 显示器（蓝牙耳机/音箱/内置扬声器）→ 直接调系统主音量（CoreAudio 直写，不合成媒体键）
// 返回 YES 表示已在本方法内处理完毕（performAction 不再走 DDC）。
- (BOOL)routeVolumeKeyToSystem:(int)act {
    if (![gConf[@"volKeySmartRoute"] boolValue]) return NO;   // 关掉智能分流则始终走 DDC
    if ([self audioOutputIsDisplay]) return NO;               // 输出是显示器 → 交给 DDC 处理

    // 非显示器输出：直接改系统主音量。
    // 注意：绝不能再 ndPostMediaKey 合成媒体键 —— 它投递到 HID 层会被本程序自己的 tap 回收，
    // dispatchMediaKey 又调回 performAction → 再 ndPostMediaKey → 死循环且系统永远收不到（表现为按键没反应）。
    if (act == -1) {                                          // 静音切换（F10）
        ndSetSystemMute(!ndSystemMuted());
        int mpct = ndSystemMuted() ? 0 : (int)(ndSystemVolume() * 100 + 0.5);
        [self showOSD:@"音量" pct:mpct screen:nil];           // 弹音量条（静音时显示 0%）
        NDLog(@"[vol] 非显示器输出 → 系统静音切换 muted=%d", ndSystemMuted());
        return YES;
    }
    float cur = ndSystemVolume();
    if (cur < 0) {
        // 读不到 CoreAudio 音量 = 当前设备不暴露音量属性（蓝牙耳机就是这种情况：
        // A2DP 设备走 AVRCP 绝对音量，CoreAudio 上没有 VolumeScalar / VirtualMasterVolume）。
        // 这种设备没法用软件直写，如实告诉用户，别假装调动了。
        NDLog(@"[vol] 当前输出设备无 CoreAudio 音量属性（多为蓝牙耳机）→ 音量键不生效");
        [self alert:@"该设备不支持音量调节" text:
                @"蓝牙耳机的音量由耳机自身和 AVRCP 控制，macOS 不把它暴露给软件。\n\n音量键对蓝牙耳机无效，请用耳机上的按键或「系统设置 → 声音」调节。"];
        return YES;
    }
    int stepPct = [gConf[@"stepVolume"] intValue]; if (stepPct <= 0) stepPct = 2;
    float step = stepPct / 100.0f;
    float tgt = MIN(MAX(cur + (act == ActVolUp ? step : -step), 0.0f), 1.0f);
    ndSetSystemVolume(tgt);
    [self showOSD:@"音量" pct:(int)(tgt * 100 + 0.5) screen:nil];   // 弹音量条，让用户看到当前音量
    NDLog(@"[vol] 非显示器输出 → 系统音量 %d%%→%d%%", (int)(cur*100+0.5), (int)(tgt*100+0.5));
    return YES;
}

- (DlDisp *)volumeTargetDisp {
    NSString *t = gConf[@"mediaVolumeTarget"];
    if (t.length == 0 || [t isEqualToString:@"main"]) return [self mainDisp];
    if ([t isEqualToString:@"audio"]) {
        NSString *dev = DefaultOutputDeviceName();
        if (dev.length) {
            for (DlDisp *d in self.displays)
                if ([d displayName].length && [[d displayName] isEqualToString:dev]) return d;
        }
        return [self mainDisp];   // 匹配不上就退回主屏
    }
    int want = t.intValue;
    for (DlDisp *d in self.displays) if (d.did == want) return d;
    return [self mainDisp];
}

// 亮度键该作用在哪块屏：main=主屏（默认） mouse=鼠标所在屏 或直接填显示器 id
- (DlDisp *)brightnessTargetDisp {
    NSString *t = gConf[@"brightnessTarget"];
    if ([t isEqualToString:@"mouse"]) {
        // NSEvent.mouseLocation 与 NSScreen.frame 同为「主屏左下角为原点」的全局坐标系，可直接判定
        NSPoint pt = [NSEvent mouseLocation];
        for (NSScreen *s in [NSScreen screens]) {
            if (!NSPointInRect(pt, s.frame)) continue;
            NSNumber *n = [s deviceDescription][@"NSScreenNumber"];
            if (!n) continue;
            CGDirectDisplayID did = (CGDirectDisplayID)[n unsignedIntValue];
            for (DlDisp *d in self.displays)
                if ((CGDirectDisplayID)d.did == did) return d;
        }
        return [self mainDisp];   // 定位不到就退回主屏
    }
    if (t.length && ![t isEqualToString:@"main"]) {
        int want = t.intValue;
        for (DlDisp *d in self.displays) if (d.did == want) return d;
    }
    return [self mainDisp];
}

#pragma mark - 原生媒体键接管

// 调试日志：只从主线程/后台队列调用，绝不在 tap 回调里做文件 I/O
static void NDLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], s];
    NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (![[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/nd_debug.log"])
        [[NSFileManager defaultManager] createFileAtPath:@"/tmp/nd_debug.log" contents:nil attributes:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/nd_debug.log"];
    [fh seekToEndOfFile]; [fh writeData:d]; [fh closeFile];
}

// ---- 系统主音量（CoreAudio 直读直写）----
// 用于"音频输出不是显示器"（蓝牙耳机/音箱/内置扬声器）时的 F11/F12 音量调节。
// 直接改系统输出音量，不合成媒体键 —— 否则事件会被本程序自己的 HID tap 回收 → 死循环、系统也收不到。
#ifndef kAudioHardwareServiceDeviceProperty_VirtualMasterVolume
#define kAudioHardwareServiceDeviceProperty_VirtualMasterVolume 'vmvc'
#endif
#ifndef kAudioObjectUnknown
#define kAudioObjectUnknown 0xFFFFFFFF
#endif
static AudioDeviceID ndDefaultOutput(void) {
    AudioDeviceID dev = kAudioObjectUnknown; UInt32 sz = sizeof(dev);
    AudioObjectPropertyAddress a = { kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, &dev)) return kAudioObjectUnknown;
    return dev;
}
static float ndSystemVolume(void) {
    AudioDeviceID dev = ndDefaultOutput(); if (dev == kAudioObjectUnknown) return -1;
    Float32 v = 0; UInt32 sz = sizeof(v);
    AudioObjectPropertyAddress vol = { kAudioHardwareServiceDeviceProperty_VirtualMasterVolume, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain };
    if (AudioObjectGetPropertyData(dev, &vol, 0, NULL, &sz, &v)) return -1;
    return v;
}
static void ndSetSystemVolume(float v) {
    v = MIN(MAX(v, 0.0f), 1.0f);
    AudioDeviceID dev = ndDefaultOutput(); if (dev == kAudioObjectUnknown) return;
    Float32 fv = v; UInt32 sz = sizeof(fv);
    AudioObjectPropertyAddress vol = { kAudioHardwareServiceDeviceProperty_VirtualMasterVolume, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain };
    AudioObjectSetPropertyData(dev, &vol, 0, NULL, sz, &fv);
}
static BOOL ndSystemMuted(void) {
    AudioDeviceID dev = ndDefaultOutput(); if (dev == kAudioObjectUnknown) return NO;
    UInt32 m = 0; UInt32 sz = sizeof(m);
    AudioObjectPropertyAddress mut = { kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain };
    if (AudioObjectGetPropertyData(dev, &mut, 0, NULL, &sz, &m)) return NO;
    return m ? YES : NO;
}
static void ndSetSystemMute(BOOL on) {
    AudioDeviceID dev = ndDefaultOutput(); if (dev == kAudioObjectUnknown) return;
    UInt32 m = on ? 1 : 0; UInt32 sz = sizeof(m);
    AudioObjectPropertyAddress mut = { kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain };
    AudioObjectSetPropertyData(dev, &mut, 0, NULL, sz, &m);
}
// 默认输出设备的传输类型：dprt=DisplayPort(0x64707274) / hdmi=HDMI(0x68646d69) → 显示器音频
static BOOL ndDefaultOutputIsDisplay(void) {
    AudioDeviceID dev = ndDefaultOutput(); if (dev == kAudioObjectUnknown) return NO;
    UInt32 tt = 0; UInt32 sz = sizeof(tt);
    AudioObjectPropertyAddress t = { kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    if (AudioObjectGetPropertyData(dev, &t, 0, NULL, &sz, &tt)) return NO;
    return (tt == 0x64707274 || tt == 0x68646d69);
}

// 合成一个系统媒体键事件并投递到 HID 层（让系统/播放器当作真按了媒体键处理）
// 用途：把 F7/F8/F9 的标准键码转发成"上一曲 / 播放暂停 / 下一曲"，
// 这样即使用户把 F 键设成了标准功能键，播放控制也不必按 Fn。
static void ndPostMediaKey(int nxKey, BOOL down) {
    long data1 = ((long)nxKey << 16) | (down ? 0x0A00 : 0x0B00);
    NSEvent *e = [NSEvent otherEventWithType:NSEventTypeSystemDefined
                                    location:NSZeroPoint
                               modifierFlags:0
                                   timestamp:0
                                windowNumber:0
                                     context:nil
                                     subtype:NX_SUBTYPE_AUX_CONTROL_BUTTONS
                                       data1:data1
                                       data2:-1];
    CGEventRef cg = e.CGEvent;
    if (cg) CGEventPost(kCGHIDEventTap, cg);
}

// CGEventTap 回调：在系统层捕获媒体键（NSEvent addGlobalMonitor 收不到硬件媒体键，必须用 tap）
// 同时兼收"普通 F1/F2 按键"——妙控键盘在"F 键当标准功能键"模式下直接按 F1/F2
// 既不发媒体事件、Carbon 热键也收不到，只能在这里抓普通 keycode。
static CGEventRef mediaTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *info) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        AppDelegate *ad = (__bridge AppDelegate *)info;
        if (ad.mediaTap) CGEventTapEnable(ad.mediaTap, true);
        return event;
    }
    AppDelegate *ad = (__bridge AppDelegate *)info;

    // ---- 普通 F 键 ----
    // F1/F2 亮度、F10 静音、F11/F12 音量：由本工具接管（走 DDC）
    // F7/F8/F9（上一曲 / 播放暂停 / 下一曲）：**转发成系统媒体事件**，让系统去控制播放器。
    //   为什么需要：切到"F 键当标准功能键"后，直按 F7~F9 不再发媒体事件，播放控制会失效；
    //   在这里重新合成媒体事件投递出去，等于"替键盘补发"，用户就不必按 Fn 了。
    if (type == kCGEventKeyDown || type == kCGEventKeyUp) {
        int64_t kc = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        CGEventFlags fl = CGEventGetFlags(event);
        CGEventFlags bad = kCGEventFlagMaskCommand | kCGEventFlagMaskControl | kCGEventFlagMaskAlternate;
        BOOL plain = !(fl & bad);
        BOOL down = (type == kCGEventKeyDown);

        // F7=上一曲 / F8=播放暂停 / F9=下一曲 → 合成媒体键事件
        int mediaKey = -1;
        if (plain) {
            if (kc == 98)       mediaKey = NX_KEYTYPE_PREVIOUS;   // F7
            else if (kc == 100) mediaKey = NX_KEYTYPE_PLAY;       // F8
            else if (kc == 101) mediaKey = NX_KEYTYPE_NEXT;       // F9
        }
        if (mediaKey != -1) {
            if (![gConf[@"fnPlaybackKeys"] boolValue]) return event;   // 选项关闭：原样放行给前端应用
            ndPostMediaKey(mediaKey, down);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
                NDLog(@"[tap] F%lld → 转发媒体键 code=%d down=%d", (long long)(kc == 98 ? 7 : kc == 100 ? 8 : 9),
                      mediaKey, down);
            });
            return NULL;   // 消费原始按键，避免 App 收到 F7~F9
        }

        int act = -1;
        switch (kc) {
            case 122: act = ActBrightDown; break;   // F1
            case 120: act = ActBrightUp;   break;   // F2
            case 109: act = -2;            break;   // F10 静音
            case 103: act = ActVolDown;    break;   // F11
            case 111: act = ActVolUp;      break;   // F12
            default: act = -1;
        }
        if (act != -1) {
            if (plain) {
                if (down) {
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
                        NDLog(@"[tap] F 键 keycode=%lld → act=%d", kc, act);
                    });
                    [ad handleFunctionKeyPress:act];
                } else {
                    [ad stopRepeat];
                }
                return NULL;   // 消费掉，避免系统/其他应用重复处理
            }
        }
        return event;
    }

    if (type != kCGEventSystemDefined) return event;
    @autoreleasepool {
        NSEvent *e = [NSEvent eventWithCGEvent:event];
        if (e.subtype != NX_SUBTYPE_AUX_CONTROL_BUTTONS) return event;
        long data1 = (long)e.data1;
        int keyCode = (int)((data1 & 0xFFFF0000) >> 16);
        int keyFlags = (int)(data1 & 0x0000FFFF);
        BOOL isDown = ((keyFlags & 0xFF00) >> 8) == 0x0A;
        // 注意：tap 回调里严禁做文件 I/O，只做一次轻量派发（日志在后台队列写）
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
            NDLog(@"[tap] 收到媒体事件 code=%d down=%d", keyCode, isDown);
        });
        // 我们处理的键直接消费掉（return NULL），阻止系统原生处理 —— 避免"系统+我们"双重写 DDC
        if ([ad dispatchMediaKey:keyCode isDown:isDown]) return NULL;
    }
    return event;
}

// 返回 YES 表示已处理（并已消费事件）
//
// 【关键】本方法在 CGEventTap 回调里同步执行，系统要求它必须"立刻返回"。
// 绝不能在这里建窗口 / 跑动画（showOSD）——回调变慢会被系统判定为 tap 超时并 disable，
// 之后所有物理媒体键（F1/F2 亮度、F11/F12 音量）全部收不到，
// 表现正是"加了动画之后快捷键全都不能用"。
//
// 【注意】不能 dispatch_async(主队列) 再执行动作：菜单展开期间主线程在菜单
// tracking 循环里，GCD 主队列不排空 → 动作永远不执行（音量走 Carbon 热键同步
// 路径所以没事，亮度走这里所以"菜单打开时亮度键失灵"）。
// 这里直接同步调 performAction：DDC 写入在 RunCLIAsync/bumpDDC 的后台线程，
// showOSD 内部自己跳主线程，回调仍立刻返回。
- (BOOL)dispatchMediaKey:(int)keyCode isDown:(BOOL)isDown {
    if (!isDown) return NO;
    if (self.engineBusy) return NO;   // 上一次还没写完就丢帧，避免进程堆积
    int act = -1;
    switch (keyCode) {
        case NX_KEYTYPE_BRIGHTNESS_UP:   act = ActBrightUp;   break;
        case NX_KEYTYPE_BRIGHTNESS_DOWN: act = ActBrightDown; break;
        case NX_KEYTYPE_SOUND_UP:        act = ActVolUp;      break;
        case NX_KEYTYPE_SOUND_DOWN:      act = ActVolDown;    break;
        case NX_KEYTYPE_MUTE:            act = -2;            break;  // 静音
        default: return NO;
    }
    NDLog(@"[dispatch] 派发 act=%d（tap 线程同步执行）", act);
    if (act == -2) { [self doMute]; return YES; }

    // 亮度/音量：写入由 writeLevel 串行合并（同 VCP 只跑一个写进程 + 保留最新值），
    // 不需要 engineBusy 占位 —— 占位了没人清就会把后续按键全挡掉（踩过这个坑）。
    if (act == ActBrightUp || act == ActBrightDown || act == ActVolUp || act == ActVolDown) {
        [self performAction:act];
        return YES;
    }
    self.engineBusy = YES;
    [self performAction:act];
    return YES;
}

// 权限 / 监听器自愈（每 3 秒）
- (void)healthTick {
    if (![gConf[@"mediaKeys"] boolValue]) return;
    if (!AXIsProcessTrusted()) return;          // 还没授权：等用户在系统设置里勾（首次引导已提示）
    if (!self.mediaTap) {                       // 授权是刚获得的 → 立即补建监听器，无需重启程序
        NDLog(@"[health] 检测到已授权，自动建立媒体键监听器");
        [self installMediaKeyMonitor];
        return;
    }
    if (!CGEventTapIsEnabled(self.mediaTap)) {  // 被系统静默禁用 → 自动重新启用
        CGEventTapEnable(self.mediaTap, true);
        NDLog(@"[health] 监听器曾被禁用，已自动重新启用");
    }
}

// 首次启动引导：说明为什么需要「辅助功能」权限，并一键跳到设置页
- (void)showFirstRunGuideIfNeeded {
    if (AXIsProcessTrusted()) return;
    if ([gConf[@"permPrompted"] boolValue]) return;   // 只提示一次
    gConf[@"permPrompted"] = @"1";
    SaveConf();

    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"需要一项系统权限才能接管键盘功能键";
    a.informativeText = @"NiceDisplay 用 F1/F2 调外接显示器亮度、F10~F12 调音量，"
                        @"这需要「辅助功能」权限来监听这些按键。\n\n"
                        @"macOS 不允许程序自行授权，请点下面按钮，"
                        @"在打开的「隐私与安全性 → 辅助功能」里把 NiceDisplay 打开。\n\n"
                        @"授权后无需重启，程序会自动生效。";
    [a addButtonWithTitle:@"打开系统设置并授权"];
    [a addButtonWithTitle:@"稍后再说"];
    NSModalResponse r = [a runModal];

    // 无论选哪个都触发一次系统授权提示（系统据此把这台 App 列进列表）
    NSDictionary *opts = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
    if (r == NSAlertFirstButtonReturn) {
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:
            @"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
    }
}

- (void)installMediaKeyMonitor {
    if (self.mediaTap) {
        CGEventTapEnable(self.mediaTap, false);
        CFRelease(self.mediaTap);
        self.mediaTap = nil;
    }
    self.mediaUnauthorized = NO;
    if (![gConf[@"mediaKeys"] boolValue]) return;

    // 辅助功能权限是 CGEventTap 全局抓键的前提；没有就提示用户授权
    NDLog(@"[install] AXIsProcessTrusted=%d mediaKeys=%@", AXIsProcessTrusted(), gConf[@"mediaKeys"]);
    if (!AXIsProcessTrusted()) {
        self.mediaUnauthorized = YES;
        NDLog(@"[install] 未授权，已弹系统提示并 return（tap 不会建立）");
        NSDictionary *opts = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
        NSLog(@"[nicedisplay] 媒体键需要辅助功能权限，已弹出系统授权提示");
        return;
    }

    // 【关键】必须挂在 HID 层而不是 session 层：
    // 不带 Fn 直接按 F1/F2 时，键盘发的是"亮度"媒体事件，而系统亮度服务（CoreBrightness）
    // 会在 session 层之前就把它消费掉 —— session tap 完全看不到（日志里只有音量 code=0/1，
    // 从来没有亮度 code=2/3 就是这个原因），于是"不用 Fn 调不了亮度"。
    // 挂 HID 层能在系统消费之前拿到事件，处理完直接吞掉（不干扰系统）。
    self.mediaTap = CGEventTapCreate(kCGEventTapLocHID, kCGEventTapPlaceHIDHead,
                                    kCGEventTapOptDefault,
                                    kCGEventMaskSysDefined | kCGEventMaskKeyDownUp,
                                    mediaTapCallback, (__bridge void *)self);
    if (!self.mediaTap) {
        self.mediaUnauthorized = YES;
        NDLog(@"[install] CGEventTapCreate 失败");
        NSLog(@"[nicedisplay] CGEventTapCreate 失败（可能需要辅助功能权限）");
        return;
    }
    NDLog(@"[install] CGEventTapCreate 成功");
    CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, self.mediaTap, 0);
    if (src) CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopCommonModes);
    CGEventTapEnable(self.mediaTap, true);
}

- (void)handleSystemDefined:(NSEvent *)e {
    if (e.subtype != NX_SUBTYPE_AUX_CONTROL_BUTTONS) return;
    long data1 = (long)e.data1;
    int keyCode = (int)((data1 & 0xFFFF0000) >> 16);
    int keyFlags = (int)(data1 & 0x0000FFFF);
    BOOL isDown = ((keyFlags & 0xFF00) >> 8) == 0x0A;
    [self dispatchMediaKey:keyCode isDown:isDown];
}

- (void)doMute {
    if ([self routeVolumeKeyToSystem:-1]) return;            // 输出不是显示器 → 转发系统静音键
    DlDisp *d = [self volumeTargetDisp];
    if (!d) return;
    RunCLIAsync(@[@"mute", [NSString stringWithFormat:@"%d", d.did]], ^(NSString *o) { [self refreshNow]; });
}

- (BOOL)detectBetterDisplay {
    // 用 NSWorkspace 按 bundle id 判定最可靠（pgrep -x 匹配不到这个进程名）
    for (NSRunningApplication *a in [[NSWorkspace sharedWorkspace] runningApplications]) {
        if ([a.bundleIdentifier isEqualToString:@"pro.betterdisplay.BetterDisplay"]) return YES;
    }
    return NO;
}

// 自检用：跑主循环 N 秒（不能用 sleep —— 会把异步回调堵死，engineBusy 卡住）
static void pumpRunLoop(NSTimeInterval secs) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:secs];
    while ([end timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
}

// 构造一个合成的系统定义媒体键事件（用于自检，不依赖真的按键）
static NSEvent *FakeMediaKey(int keyCode, BOOL isDown) {
    long data1 = ((long)keyCode << 16) | (isDown ? 0x0A00 : 0x0B00);
    return [NSEvent otherEventWithType:NSEventTypeSystemDefined
                              location:NSZeroPoint
                         modifierFlags:0
                             timestamp:0
                          windowNumber:0
                               context:nil
                              subtype:NX_SUBTYPE_AUX_CONTROL_BUTTONS
                                data1:(NSInteger)data1
                                data2:-1];
}

- (void)refresh {
    NSArray *d = FetchDisplays();
    NSArray *dis = FetchDisabledIDs();
    BOOL bd = [self detectBetterDisplay];
    NSString *audio = DefaultOutputDeviceName();
    dispatch_async(dispatch_get_main_queue(), ^{
        self.displays = d;
        self.disabledIDs = [self splitDisabled:dis];
        self.betterDisplayRunning = bd;
        self.audioDeviceName = audio;
        self.lastRefresh = [NSDate date];
        if (!self.dispNameCache) self.dispNameCache = [NSMutableDictionary dictionary];
        for (DlDisp *x in d)
            self.dispNameCache[[NSString stringWithFormat:@"%d", x.did]] = [x displayName];
        [self rememberDisplayNames:d];
        // 遮罩对账：把已经不存在的显示器的遮罩窗口收掉（ID 漂移/拔线后避免残留窗口一直压暗屏幕）
        {
            NSMutableArray *liveUUIDs = [NSMutableArray array];
            for (DlDisp *x in d) if (x.uuid.length) [liveUUIDs addObject:x.uuid];
            ndReconcileOverlays(liveUUIDs);
        }
        [self updateStatusLabel];
        [self syncOpenMenuSliders];
    });
}

// 记住"显示器 UUID → 名字"并写进配置：关闭显示器后 did 会变，靠它显示真实名字
- (void)rememberDisplayNames:(NSArray *)disp {
    if (!self.dispNameByUUID) self.dispNameByUUID = [NSMutableDictionary dictionary];
    BOOL dirty = NO;
    for (DlDisp *x in disp) {
        if (!x.uuid.length) continue;
        NSString *nm = [x displayName];
        if (nm.length && ![nm isEqualToString:self.dispNameByUUID[x.uuid]]) {
            self.dispNameByUUID[x.uuid] = nm;
            dirty = YES;
        }
    }
    if (dirty) {
        NSMutableArray *pairs = [NSMutableArray array];
        for (NSString *k in self.dispNameByUUID)
            [pairs addObject:[NSString stringWithFormat:@"%@=%@", k, self.dispNameByUUID[k]]];
        gConf[@"dispNames"] = [pairs componentsJoinedByString:@";"];
        SaveConf();
    }
}

// dlite disabled 每行是 "uuid<TAB>名字"，拆开并把名字记进 UUID→名字表
- (NSArray *)splitDisabled:(NSArray *)raw {
    NSMutableArray *ids = [NSMutableArray array];
    if (!self.dispNameByUUID) self.dispNameByUUID = [NSMutableDictionary dictionary];
    for (NSString *line in raw) {
        NSArray *parts = [line componentsSeparatedByString:@"\t"];
        NSString *u = parts.firstObject ?: @"";
        if (!u.length) continue;
        if (parts.count > 1 && [(NSString *)parts[1] length]) self.dispNameByUUID[u] = parts[1];
        [ids addObject:u];
    }
    return ids;
}

- (void)loadDisplayNames {
    self.dispNameByUUID = [NSMutableDictionary dictionary];
    for (NSString *pair in [gConf[@"dispNames"] componentsSeparatedByString:@";"]) {
        NSArray *kv = [pair componentsSeparatedByString:@"="];
        if (kv.count == 2 && [kv[0] length]) self.dispNameByUUID[kv[0]] = kv[1];
    }
}

- (void)refreshAsync {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [self refresh]; });
}

// 同步刷新：打开菜单时先取一次最新状态，避免旋转角度/连接状态显示旧值
- (void)refreshNow {
    NSArray *d = FetchDisplays();
    NSArray *dis = FetchDisabledIDs();
    BOOL bd = [self detectBetterDisplay];
    NSString *audio = DefaultOutputDeviceName();
    if (!self.dispNameCache) self.dispNameCache = [NSMutableDictionary dictionary];
    for (DlDisp *x in d)
        self.dispNameCache[[NSString stringWithFormat:@"%d", x.did]] = [x displayName];
    [self rememberDisplayNames:d];
    self.displays = d;
    self.disabledIDs = [self splitDisabled:dis];
    self.betterDisplayRunning = bd;
    self.audioDeviceName = audio;
    self.lastRefresh = [NSDate date];
}

- (void)updateStatusLabel {
    if (!self.statusLabel) return;
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"检测到 %lu 块活动显示器", (unsigned long)self.displays.count];
    for (DlDisp *d in self.displays)
        [s appendFormat:@"\n  %@  (id=%d)  %@%@%@", [d displayName], d.did, [d summary],
              d.isMain ? @"  主屏" : @"", d.hasDDC ? @"" : @"  (无 DDC)"];
    [s appendFormat:@"\n\n默认音频输出: %@", self.audioDeviceName.length ? self.audioDeviceName : @"(未知)"];
    DlDisp *vd = [self volumeTargetDisp];
    [s appendFormat:@"\n音量键作用屏幕: %@", vd ? [vd displayName] : @"(未确定)"];
    [s appendFormat:@"\n媒体键接管: %@", [gConf[@"mediaKeys"] boolValue] ? @"已开启" : @"已关闭"];
    if (self.betterDisplayRunning)
        [s appendString:@"\n\n⚠︎ BetterDisplay 正在运行 —— 它也会接管亮度媒体键，\n   建议退出它以免按一下变两档。"];
    if (self.disabledIDs.count)
        [s appendFormat:@"\n已断开: %@", [self.disabledIDs componentsJoinedByString:@", "]];
    self.statusLabel.stringValue = s;
}

// 按 id 找显示器
- (DlDisp *)dispByID:(int)did {
    for (DlDisp *d in self.displays) if (d.did == did) return d;
    return nil;
}

#pragma mark - OSD 浮层（媒体键 / 滑块反馈）
// ============================ DDC 绝对写入（应用侧目标值 + 串行合并） ============================
// 【务必懒加载初始化】这四个容器忘了 init 的话，pumpWriteForKey 取到的待写值是 nil 就会
// 直接 return —— 表现就是"亮度/音量完全调不动"（已踩过）。
- (NSMutableDictionary *)ddcTarget {
    @synchronized (self) { if (!_ddcTarget) _ddcTarget = [NSMutableDictionary dictionary]; return _ddcTarget; }
}
- (NSMutableDictionary *)ddcLastAct {
    @synchronized (self) { if (!_ddcLastAct) _ddcLastAct = [NSMutableDictionary dictionary]; return _ddcLastAct; }
}
- (NSMutableDictionary *)ddcLatest {
    @synchronized (self) { if (!_ddcLatest) _ddcLatest = [NSMutableDictionary dictionary]; return _ddcLatest; }
}
- (NSMutableSet *)ddcInFlight {
    @synchronized (self) { if (!_ddcInFlight) _ddcInFlight = [NSMutableSet set]; return _ddcInFlight; }
}

// 为什么不用 dlite 的相对 bump：bump 是"读显示器当前值 → 加减 → 写回"，
// 而这两块屏（尤其华为）的 DDC 回读有明显滞后，连按时会读到旧值，
// 于是写回一个基于旧值算出的结果 —— 表现就是"调到 10% 突然跳回 76%"。
// 改为：App 侧维护目标值，只做绝对值写入；同一 VCP 同时只跑一个写入进程，
// 期间新目标只覆盖 pending 值，写完自动补写最新值（既平滑又不丢步）。
- (NSString *)ddcKey:(int)did vcp:(int)vcp {
    return [NSString stringWithFormat:@"%d:%d", did, vcp];
}

// 当前"真值"：以 App 侧目标值为准（显示器回读既滞后又可能失败，不能当基准）
// 返回 -1 表示完全没有可信基准 —— 调用方应跳过本次调节，绝不能拿 0 去加减
- (int)currentLevelForDisp:(DlDisp *)d vcp:(int)vcp max:(int *)outMax {
    // HDR 屏：亮度基准取"软件亮度"（DDC 回读在 HDR 下恒为 100，不能用）
    if (vcp == 0x10 && DisplayIsEDR(d.did)) {
        if (outMax) *outMax = 100;
        // 挂过软件调暗层 → 用它记录的值；没挂过 = 硬件最亮 = 100
        return ndGetSoftwareBrightness(d.did);
    }
    int mon = (vcp == 0x10) ? d.bright : d.vol;
    BOOL monKnown = (vcp == 0x10) ? d.brightKnown : d.volKnown;
    int mx  = (vcp == 0x10) ? d.bmax   : d.vmax;
    if (mx <= 0) mx = 100;
    if (outMax) *outMax = mx;

    NSString *key = [self ddcKey:d.did vcp:vcp];
    NSNumber *t = nil; NSDate *last = nil;
    @synchronized (self) { t = self.ddcTarget[key]; last = self.ddcLastAct[key]; }

    // 1) 30 秒内操作过 → 全信 App 侧目标（连按期间绝不被延迟/失败的回读带偏）
    if (t && last && -[last timeIntervalSinceNow] < 30.0)
        return MIN(MAX(t.intValue, 0), mx);
    // 2) 回读失败但历史上有过目标 → 继续用历史目标
    if (!monKnown && t)
        return MIN(MAX(t.intValue, 0), mx);
    // 3) 回读成功 → 用它校正（例如用户用别的工具改过）
    if (monKnown)
        return MIN(MAX(mon, 0), mx);
    // 4) 什么都不可信 → 交给调用方跳过
    return -1;
}

- (void)noteLevel:(int)value did:(int)did vcp:(int)vcp {
    NSString *key = [self ddcKey:did vcp:vcp];
    @synchronized (self) {
        self.ddcTarget[key] = @(value);
        self.ddcLastAct[key] = [NSDate date];
    }
}

// 绝对写入（自动合并连发产生的中间值）
- (void)writeLevel:(int)value did:(int)did vcp:(int)vcp {
    // HDR 屏：DDC 亮度被显示器丢弃 → 改走软件调暗（叠加层）
    if (vcp == 0x10 && DisplayIsEDR(did)) {
        int bright = MIN(MAX(value, 0), 100);
        ndSetSoftwareBrightness(did, bright);
        NDLog(@"[hdr] display %d 软件亮度 → %d%%（DDC 被 HDR 屏蔽，改写叠加层）", did, bright);
        [self noteLevel:bright did:did vcp:vcp];
        [self refreshAsync];
        return;
    }
    // 之前挂过软件调暗层、现在关掉了 HDR → 清掉叠加层，回到 DDC 真亮度
    if (vcp == 0x10 && ndHasSoftwareDim(did) && !DisplayIsEDR(did)) {
        ndClearSoftwareDim(did);
        NDLog(@"[hdr] display %d HDR 已关 → 清除软件调暗层，回到 DDC", did);
    }
    NSString *key = [self ddcKey:did vcp:vcp];
    BOOL busy = NO;
    @synchronized (self) {
        self.ddcLatest[key] = @(value);
        busy = [self.ddcInFlight containsObject:key];
    }
    if (busy) return;          // 正在写 → 只留最新值，收尾时自动补写
    [self pumpWriteForKey:key did:did vcp:vcp];
}

- (void)pumpWriteForKey:(NSString *)key did:(int)did vcp:(int)vcp {
    NSNumber *v = nil;
    @synchronized (self) {
        v = self.ddcLatest[key];
        if (!v) return;
        [self.ddcLatest removeObjectForKey:key];
        [self.ddcInFlight addObject:key];
    }
    NSString *vpcs = (vcp == 0x10) ? @"0x10" : @"0x62";
    NDLog(@"[write] 开始写 id=%@ vcp=%@ 值=%@", [NSString stringWithFormat:@"%d", did], vpcs, v);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *o = RunCLI(@[@"ddc", @"set", [NSString stringWithFormat:@"%d", did], vpcs,
                 [NSString stringWithFormat:@"%d", v.intValue]]);
        NDLog(@"[write] 完成 id=%d 值=%@ 输出=%@", did, v,
              [o stringByReplacingOccurrencesOfString:@"\n" withString:@" "]);
        BOOL more = NO;
        @synchronized (self) {
            [self.ddcInFlight removeObject:key];
            more = (self.ddcLatest[key] != nil);
        }
        if (more) [self pumpWriteForKey:key did:did vcp:vcp];   // 有新目标 → 紧接着写最新值
        else      [self refreshAsync];
    });
}

// 某块显示器对应的 NSScreen（OSD 定位用）
- (NSScreen *)screenForDisp:(DlDisp *)d {
    if (d) {
        for (NSScreen *s in [NSScreen screens]) {
            NSNumber *n = [s deviceDescription][@"NSScreenNumber"];
            if (n && (CGDirectDisplayID)[n unsignedIntValue] == (CGDirectDisplayID)d.did) return s;
        }
    }
    return [NSScreen mainScreen];
}

// OSD：长条状，模仿系统原生样式（左图标 + 细长进度条 + 右侧百分比）
static const CGFloat kOSD_W = 250;
static const CGFloat kOSD_H = 44;

- (void)ensureOSD {
    if (self.osdWindow) return;
    CGFloat W = kOSD_W, H = kOSD_H;
    NSRect f = NSMakeRect(0, 0, W, H);
    OSDWindow *w = [[OSDWindow alloc] initWithContentRect:f
                                               styleMask:NSWindowStyleMaskBorderless
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
    w.backgroundColor = [NSColor clearColor];
    w.opaque = NO;
    w.hasShadow = YES;
    w.level = NSFloatingWindowLevel + 2;
    w.ignoresMouseEvents = YES;
    w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary;

    // 用系统 HUD 毛玻璃材质：跟随明暗外观，观感与原生 OSD 一致
    NSVisualEffectView *cv = [[NSVisualEffectView alloc] initWithFrame:f];
    cv.material = NSVisualEffectMaterialHUDWindow;
    cv.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    cv.state = NSVisualEffectStateActive;
    cv.wantsLayer = YES;
    cv.layer.cornerRadius = 12;
    cv.layer.masksToBounds = YES;
    w.contentView = cv;

    // 左侧图标（亮度=太阳 / 音量=喇叭）
    NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(14, (H - 18) / 2.0, 18, 18)];
    icon.imageScaling = NSImageScaleProportionallyUpOrDown;
    icon.contentTintColor = [NSColor whiteColor];   // HUD 浮层上固定白色
    [cv addSubview:icon];
    self.osdIcon = icon;

    // 细长进度条（官方样式：圆角胶囊，填充为白色）
    OSDBar *bar = [[OSDBar alloc] initWithFrame:NSMakeRect(42, (H - 6) / 2.0, W - 42 - 56, 6)];
    [cv addSubview:bar];
    self.osdBar = bar;

    // 右侧百分比
    NSTextField *pct = [[NSTextField alloc] initWithFrame:NSMakeRect(W - 52, (H - 16) / 2.0, 40, 16)];
    pct.bezeled = NO; pct.editable = NO; pct.drawsBackground = NO; pct.alignment = NSTextAlignmentRight;
    pct.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium];
    pct.textColor = [NSColor secondaryLabelColor];
    [cv addSubview:pct];
    self.osdPct = pct;

    self.osdWindow = w;
}

- (void)showOSD:(NSString *)kind pct:(int)pct screen:(NSScreen *)scr {
    // 【必须无条件异步】HID tap 回调运行在主线程上，若在这里同步建窗口/跑动画，
    // 会把 tap 回调拖到超时并被系统 disable（就是"加了动画快捷键全废"的老病根）。
    // 一律先返回、让主循环下一轮再画。菜单展开期暂不显示无妨，DDC 写入照常。
    dispatch_async(dispatch_get_main_queue(), ^{
        [self showOSDNow:kind pct:pct screen:scr];
    });
}

- (void)showOSDNow:(NSString *)kind pct:(int)pct screen:(NSScreen *)scr {
    // 浮层可整体关闭（showOSD=0）；关闭后只是不弹提示，亮度/音量写入照常进行
    if (gConf[@"showOSD"] && ![gConf[@"showOSD"] boolValue]) return;
    [self ensureOSD];
    self.osdIcon.image = [self symImage:[kind isEqualToString:@"亮度"] ? @"sun.max.fill" : @"speaker.wave.2.fill"];
    self.osdBar.pct = pct;
    [self.osdBar setNeedsDisplay:YES];
    self.osdPct.stringValue = [NSString stringWithFormat:@"%d%%", pct];

    NSWindow *w = self.osdWindow;
    NSScreen *s = scr ?: [NSScreen mainScreen];
    NSRect sf = s.frame;
    // 菜单栏高度 = 顶边到 visibleFrame 顶边的距离；窗口放右上角、状态栏正下方
    CGFloat menuH = (sf.origin.y + sf.size.height) - (s.visibleFrame.origin.y + s.visibleFrame.size.height);
    if (menuH < 0 || menuH > 80) menuH = 24;
    CGFloat x = sf.origin.x + sf.size.width - kOSD_W - 12;
    CGFloat y = sf.origin.y + sf.size.height - menuH - kOSD_H - 8;
    // 位置没变就不重设，避免连按时窗口抖动
    if (!NSEqualPoints(w.frame.origin, NSMakePoint(x, y)))
        [w setFrameOrigin:NSMakePoint(x, y)];

    // 【不闪烁】窗口已经可见时只更新进度条内容，绝不重置 alpha 重播淡入——
    // 否则连按时每次都闪一下。只有从隐藏→显示时才做一次淡入。
    BOOL wasVisible = (w.isVisible && w.alphaValue > 0.05);
    if (wasVisible) {
        w.alphaValue = 1.0;
        [w orderFrontRegardless];
    } else {
        w.alphaValue = 0;
        [w orderFrontRegardless];
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *c) {
            c.duration = 0.08;
            w.animator.alphaValue = 1.0;
        } completionHandler:nil];
    }
    if (self.osdHideTimer) [self.osdHideTimer invalidate];
    self.osdHideTimer = [NSTimer scheduledTimerWithTimeInterval:1.4 target:self selector:@selector(hideOSD) userInfo:nil repeats:NO];
}

- (void)hideOSD {
    if (!self.osdWindow) return;
    NSWindow *w = self.osdWindow;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *c) {
        c.duration = 0.30;
        w.animator.alphaValue = 0.0;
    } completionHandler:^{
        [w orderOut:nil];
    }];
}

// 菜单展开时，媒体键改变值后同步刷新菜单内滑块
- (void)syncOpenMenuSliders {
    if (!self.menuIsOpen || self.sliderDragging) return;
    for (NSMenuItem *it in self.statusItem.menu.itemArray) {
        if (!it.view) continue;
        for (NSView *sub in it.view.subviews) {
            if (![sub isKindOfClass:[NSSlider class]]) continue;
            NSSlider *sl = (NSSlider *)sub;
            NSArray *p = [sl.identifier componentsSeparatedByString:@":"];
            if (p.count != 2) continue;
            DlDisp *d = [self dispByID:[p[0] intValue]];
            if (!d) continue;
            int vcp = [p[1] intValue];
            int val;
            // ⚠️ 必须与 sliderItem: 用同一套取值逻辑，否则菜单开着时滑条会来回跳：
            // 亮度在 HDR 屏要走"软件亮度"（DDC 在 HDR 下恒为 100，拿它同步会把滑条拽回 100）。
            if (vcp == 0x10 && DisplayIsEDR(d.did)) {
                val = ndGetSoftwareBrightness(d.did);
            } else if (vcp == 0x10) {
                if (!d.brightKnown) continue;      // 回读失败 → 不拿无效值去改滑条
                val = d.bright;
            } else {
                if (!d.volKnown) continue;
                val = d.vol;
            }
            if (val < 0) continue;
            sl.doubleValue = val;
            for (NSView *s2 in it.view.subviews)
                if (s2.tag == 99 && [s2 isKindOfClass:[NSTextField class]])
                    ((NSTextField *)s2).stringValue = [NSString stringWithFormat:@"%d%%", val];
        }
    }
}

#pragma mark - 生命周期

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    LoadConf();
    [self loadDisplayNames];
    self.hotKeyRefs = [NSMutableArray array];
    self.displays = @[];
    self.disabledIDs = @[];
    self.engineBusy = NO;

    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.image = StatusBarIcon();
    self.statusItem.button.imagePosition = NSImageOnly;
    self.statusItem.button.toolTip = @"NiceDisplay — 显示器控制";
    NSMenu *menu = [[NSMenu alloc] init];
    menu.delegate = self;
    self.statusItem.menu = menu;

    EventTypeSpec specs[2] = {
        { kEventClassKeyboard, kEventHotKeyPressed },
        { kEventClassKeyboard, kEventHotKeyReleased },
    };
    InstallEventHandler(GetApplicationEventTarget(), HotkeyHandler, 2, specs, (__bridge void *)self, NULL);
    [self registerHotkeys];
    [self installMediaKeyMonitor];

    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:6.0 target:self selector:@selector(refreshAsync) userInfo:nil repeats:YES];
    [self refreshAsync];

    // 权限/监听器自愈：每 3 秒检查一次
    //  · 用户在系统设置里刚勾上辅助功能 → 立即建立监听器（无需重启本程序）
    //  · 监听器被系统静默禁用（disable-by-timeout）→ 自动重新启用
    self.healthTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self selector:@selector(healthTick) userInfo:nil repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:self.healthTimer forMode:NSRunLoopCommonModes];

    // 首次启动引导（未授权时一次性提示怎么授权）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self showFirstRunGuideIfNeeded];
    });

    // 媒体键链路自检：合成媒体键事件走完整链路（解析 → 动作 → DDC → 还原）
    if ([[NSProcessInfo processInfo].arguments containsObject:@"--mediatest"]) {
        self.displays = FetchDisplays();
        self.audioDeviceName = DefaultOutputDeviceName();
        [self refreshAsync];          // 走正常刷新路径再取一次（DDC 回读偶发失败，多试一次）
        pumpRunLoop(1.5);             // 等它回来，让自检基准与真实运行一致
        DlDisp *vd = [self volumeTargetDisp];
        // 【注意】亮度要用"实际作用屏"（可能跟随鼠标），否则自检会读错屏而误报"无变化"
        DlDisp *md = [self brightnessTargetDisp] ?: [self mainDisp];
        printf("媒体键链路自检（注意：本自检用合成事件只验证\"动作逻辑\"，不验证真实抓取）\n");
        printf("  默认音频输出设备 = %s\n", self.audioDeviceName.UTF8String ?: "(空)");
        printf("  亮度键作用屏幕   = %s (id=%d)\n", md ? [md displayName].UTF8String : "(无)", md ? md.did : -1);
        printf("  音量键作用屏幕   = %s (id=%d)\n", vd ? [vd displayName].UTF8String : "(无)", vd ? vd.did : -1);
        printf("  当前音频输出是否显示器 = %s → 音量键%s\n",
               [self audioOutputIsDisplay] ? "是" : "否（耳机/音箱等）",
               [self audioOutputIsDisplay] ? "写显示器 DDC" : "转发系统音量键");
        printf("  CGEventTap=%s%s （真实抓取依赖它 + 辅助功能权限，需真实按键验证）\n",
               self.mediaTap ? "已安装" : "未安装",
               self.mediaUnauthorized ? "（缺辅助功能权限）" : "");

        int b0 = md ? ReadDDCValue(md.did, 0x10) : -1;
        int w0 = vd ? ReadDDCValue(vd.did, 0x62) : -1;
        NSString *mdName = md ? [md displayName] : @"未知屏";
        int savedBrightDim = -1;    // 测试前该屏的软件调暗值（HDR 屏），结束要原样恢复
        printf("  测试前: 亮度=%d  音量=%d\n", b0, w0);

        NSArray *cases = @[
            @[@(NX_KEYTYPE_BRIGHTNESS_UP),   @"亮度+", @(0x10), @(md ? md.did : -1)],
            @[@(NX_KEYTYPE_BRIGHTNESS_DOWN), @"亮度-", @(0x10), @(md ? md.did : -1)],
            @[@(NX_KEYTYPE_SOUND_UP),        @"音量+", @(0x62), @(vd ? vd.did : -1)],
            @[@(NX_KEYTYPE_SOUND_DOWN),      @"音量-", @(0x62), @(vd ? vd.did : -1)],
        ];
        for (NSArray *c in cases) {
            int code = [c[0] intValue];
            int vcp = [c[2] intValue];
            int did = [c[3] intValue];
            // HDR 屏亮度走软件调暗（DDC 恒为 100），自检必须读软件亮度值，否则一律误报"无变化"
            BOOL hdrBright = (vcp == 0x10 && did > 0 && DisplayIsEDR(did));
            // 记录测试前的软件亮度：自检结束要原样恢复，不能破坏用户平时的观感
            // （-1 = 测试前没挂过调暗层，收尾时应清除而不是写某个值）
            int savedDim = (hdrBright && ndHasSoftwareDim(did)) ? ndGetSoftwareBrightness(did) : -1;
            if (hdrBright && savedDim >= 0 && savedBrightDim < 0) savedBrightDim = savedDim;
            // HDR 屏先落到 60 这个确定中间值再测：100 是顶格（+2 看不出）、
            // 且只有让 before 反映真实状态，报告的数值才诚实
            if (hdrBright) { ndSetSoftwareBrightness(did, 60); pumpRunLoop(0.2); }
            int before = hdrBright ? ndGetSoftwareBrightness(did) : ReadDDCValue(did, vcp);
            [self handleSystemDefined:FakeMediaKey(code, YES)];
            pumpRunLoop(1.4);                       // 跑主循环，让异步回调有机会执行
            int after = hdrBright ? ndGetSoftwareBrightness(did) : ReadDDCValue(did, vcp);
            printf("  %s 键: %d → %d   %s%s\n", [c[1] UTF8String], before, after,
                   after != before ? "✓ 已响应" : "✗ 无变化",
                   hdrBright ? "（HDR·软件调暗）" : "");
        }
        // 静音键两次（应回到原音量）
        int v1 = -1, v2 = -1;
        if (vd) {
            [self handleSystemDefined:FakeMediaKey(NX_KEYTYPE_MUTE, YES)];
            pumpRunLoop(1.4);
            v1 = ReadDDCValue(vd.did, 0x62);
            [self handleSystemDefined:FakeMediaKey(NX_KEYTYPE_MUTE, YES)];
            pumpRunLoop(1.4);
            v2 = ReadDDCValue(vd.did, 0x62);
            printf("  静音键: %d →(静音) %d →(恢复) %d\n", w0, v1, v2);
        }

        // 收尾还原：写回测试前的值，确保自检零副作用
        if (md && b0 >= 0) {
            if (DisplayIsEDR(md.did)) {
                // HDR 屏：原样恢复测试前的软件亮度（而不是一律清零，
                // 否则会把用户平时"开着 HDR 且已调暗"的观感改掉）
                if (savedBrightDim >= 0) ndSetSoftwareBrightness(md.did, savedBrightDim);
                else ndClearSoftwareDim(md.did);
                printf("  已还原 %s 的软件亮度 → %s\n", mdName.UTF8String,
                       (savedBrightDim >= 0 && savedBrightDim < 100)
                           ? [NSString stringWithFormat:@"%d%%", savedBrightDim].UTF8String
                           : "最亮（无压暗）");
            } else {
                RunCLI(@[@"ddc", @"set", [NSString stringWithFormat:@"%d", md.did], @"0x10",
                         [NSString stringWithFormat:@"%d", b0]]);
                printf("  已还原亮度到 %d（现值 %d）\n", b0, ReadDDCValue(md.did, 0x10));
            }
        }
        if (vd && w0 >= 0) {
            RunCLI(@[@"ddc", @"set", [NSString stringWithFormat:@"%d", vd.did], @"0x62",
                     [NSString stringWithFormat:@"%d", w0]]);
            printf("  已还原音量到 %d（现值 %d）\n", w0, ReadDDCValue(vd.did, 0x62));
        }
        printf("  媒体键监听器 = %s%s\n", self.mediaTap ? "CGEventTap 已安装" : "未安装",
               self.mediaUnauthorized ? "（缺辅助功能权限）" : "");
        printf("BetterDisplay 运行中 = %s\n", self.betterDisplayRunning ? "是" : "否");
        {
            // F7~F9 转发链路自检：验证能否成功合成系统媒体事件（不实际投递，避免干扰播放）
            NSEvent *probe = [NSEvent otherEventWithType:NSEventTypeSystemDefined
                                                location:NSZeroPoint modifierFlags:0 timestamp:0
                                            windowNumber:0 context:nil
                                                 subtype:NX_SUBTYPE_AUX_CONTROL_BUTTONS
                                                   data1:((long)NX_KEYTYPE_PLAY << 16) | 0x0A00
                                                   data2:-1];
            printf("  F7~F9 播放控制转发：媒体事件合成 %s\n", probe.CGEvent ? "成功" : "失败");
        }
        fflush(stdout);
        exit(0);
    }

    // HDR 开关自测：NiceDisplay --hdrtest on|off|toggle  （不传参数则只报告状态）
    if ([[NSProcessInfo processInfo].arguments containsObject:@"--hdrtest"]) {
        NSArray *a = [NSProcessInfo processInfo].arguments;
        NSString *act = @"";
        NSUInteger idx = [a indexOfObject:@"--hdrtest"];
        if (idx != NSNotFound && idx + 1 < a.count) act = a[idx + 1];
        printf("=== HDR 能力与状态 ===\n");
        CGDirectDisplayID hdrDid = 0;
        self.displays = FetchDisplays();
        for (DlDisp *dd in self.displays) {
            BOOL sup = ndHDRSupported(dd.did), en = ndHDREnabled(dd.did);
            printf("  %-14s id=%-3d 支持HDR=%d 已开启=%d%s\n",
                   [dd displayName].UTF8String, dd.did, (int)sup, (int)en,
                   sup ? "" : "   (菜单里不显示 HDR 项)");
            if (sup) hdrDid = dd.did;
        }
        if (!hdrDid) { printf("没有支持 HDR 的显示器\n"); exit(0); }
        if (!act.length) exit(0);
        BOOL want = [act isEqualToString:@"on"] ? YES
                  : [act isEqualToString:@"off"] ? NO : !ndHDREnabled(hdrDid);
        printf("执行 %s → %s ...\n", act.UTF8String, want ? "开启" : "关闭");
        BOOL ok = ndSetHDREnabled(hdrDid, want);
        printf("  结果: 已开启=%d  %s\n", (int)ndHDREnabled(hdrDid), ok ? "✓ 已生效" : "✗ 未生效（被弹回）");
        if (ok && !want) ndClearSoftwareDim(hdrDid);
        exit(ok ? 0 : 1);
    }

    // 自检模式：把"点开菜单"和"注册热键"这两条平时难以验证的路径提前跑一遍
    if ([[NSProcessInfo processInfo].arguments containsObject:@"--selftest"]) {
        self.displays = FetchDisplays();        // 同步取值，确保菜单拿到真实数据
        self.disabledIDs = FetchDisabledIDs();
        [self menuNeedsUpdate:self.statusItem.menu];     // 构建菜单（点击时才会走这条路）
        NSMenu *m = self.statusItem.menu;
        printf("显示器数=%lu  已断开=%lu\n",
               (unsigned long)self.displays.count, (unsigned long)self.disabledIDs.count);
        printf("菜单项数=%lu\n", (unsigned long)m.numberOfItems);
        for (NSMenuItem *it in m.itemArray) {
            const char *t = it.title.length ? it.title.UTF8String : "(分隔线)";
            if (it.submenu) {
                NSInteger usable = 0;
                for (NSMenuItem *si in it.submenu.itemArray) if (si.enabled) usable++;
                printf("  - %s  ▸ (共 %lu 项，可用 %ld)\n", t,
                       (unsigned long)it.submenu.numberOfItems, (long)usable);
            } else {
                printf("  - %s%s%s\n", t,
                       it.submenu ? "  ▸" : "",
                       it.view ? "  [自定义视图]" : "");
                if (it.view) {
                    printf("       itemView.frame=%s  hidden=%d  subviews=%lu\n",
                           NSStringFromRect(it.view.frame).UTF8String,
                           it.hidden ? 1 : 0, (unsigned long)it.view.subviews.count);
                    for (NSView *sv in it.view.subviews) {
                        NSString *txt = [sv isKindOfClass:[NSTextField class]]
                                        ? [(NSTextField *)sv stringValue] : @"";
                        NSColor *col = [sv isKindOfClass:[NSTextField class]]
                                       ? [(NSTextField *)sv textColor] : nil;
                        printf("         %-14s frame=%-22s text=%-14s color=%s\n",
                               NSStringFromClass([sv class]).UTF8String,
                               NSStringFromRect(sv.frame).UTF8String,
                               txt.UTF8String ?: "",
                               col ? [[col description] UTF8String] : "-");
                    }
                }
            }
        }
        // 【回归】HDR 滑条同步：菜单开着时每 6 秒会跑一次 syncOpenMenuSliders，
        // 它必须用"软件亮度"而不是 DDC 值（DDC 在 HDR 下恒为 100），否则滑条会被拽回 100 = 用户看到的"乱跳"。
        {
            for (DlDisp *dd in self.displays) {
                if (!DisplayIsEDR(dd.did)) continue;
                ndSetSoftwareBrightness(dd.did, 60);
                BOOL oldOpen = self.menuIsOpen;
                self.menuIsOpen = YES;
                [self syncOpenMenuSliders];
                self.menuIsOpen = oldOpen;
                for (NSMenuItem *it2 in m.itemArray) {
                    for (NSView *sv in it2.view.subviews) {
                        if (![sv isKindOfClass:[NSSlider class]]) continue;
                        NSSlider *sl = (NSSlider *)sv;
                        NSArray *p = [sl.identifier componentsSeparatedByString:@":"];
                        if (p.count != 2 || [p[0] intValue] != dd.did || [p[1] intValue] != 0x10) continue;
                        printf("  HDR 滑条同步回归: %.0f%%（期望 60，若是 100 说明又被 DDC 值拽回去了）\n",
                               sl.doubleValue);
                    }
                }
                ndClearSoftwareDim(dd.did);
                break;
            }
        }
        printf("已注册全局热键=%lu / 配置项=%lu\n",
               (unsigned long)self.hotKeyRefs.count, (unsigned long)HotkeyKeys().count);
        printf("状态栏按钮存在=%s\n", self.statusItem.button ? "是" : "否");
        printf("状态栏图标=%s\n", self.statusItem.button.image ? "已设置" : "缺失");
        printf("媒体键接管=%s  CGEventTap=%s%s\n",
               [gConf[@"mediaKeys"] boolValue] ? "开" : "关",
               self.mediaTap ? "已安装" : "未安装",
               self.mediaUnauthorized ? "（缺辅助功能权限）" : "");
        printf("默认音频输出设备=%s\n", DefaultOutputDeviceName().UTF8String ?: "(null)");
        DlDisp *vt = [self volumeTargetDisp];
        printf("音量键作用屏幕=%s (id=%d)\n", vt ? [vt displayName].UTF8String : "(无)", vt ? vt.did : -1);
        printf("BetterDisplay 运行中=%s\n", self.betterDisplayRunning ? "是" : "否");

        // 设置窗口同样是"点了才走"的路径，提前构建一次验证
        [self buildSettingsWindow];
        printf("设置窗口=%s  标签页=%lu\n",
               self.settingsWindow ? "构建成功" : "失败",
               (unsigned long)self.tabView.numberOfTabViewItems);
        for (NSTabViewItem *t in self.tabView.tabViewItems)
            printf("  - 标签: %s  子视图=%lu\n", t.label.UTF8String,
                   (unsigned long)t.view.subviews.count);
        printf("系统设置读取: 标准功能键=%s\n",
               [self systemStandardFnKeysEnabled] ? "开" : "关");
        printf("快捷键输入框=%lu  步长/分辨率输入框=%lu  显示项勾选框=%lu\n",
               (unsigned long)self.hkFields.count,
               (unsigned long)self.optFields.count,
               (unsigned long)self.showChecks.count);
        fflush(stdout);
        exit(0);
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return NO; }

#pragma mark - 热键注册

- (void)registerHotkeys {
    for (NSValue *v in self.hotKeyRefs) { EventHotKeyRef r = (EventHotKeyRef)[v pointerValue]; if (r) UnregisterEventHotKey(r); }
    [self.hotKeyRefs removeAllObjects];
    self.hotkeyActions = [NSMutableArray array];

    NSArray *keys = HotkeyKeys();
    for (NSUInteger i = 0; i < keys.count; i++) {
        UInt32 kc = 0, mods = 0;
        if (!ParseHotkey(gConf[keys[i]], &kc, &mods)) continue;
        EventHotKeyID hid;
        hid.signature = 'dltE';
        hid.id = (UInt32)(i + 1);
        EventHotKeyRef ref = NULL;
        if (RegisterEventHotKey(kc, mods, hid, GetApplicationEventTarget(), 0, &ref) == noErr)
            [self.hotKeyRefs addObject:[NSValue valueWithPointer:ref]];
    }

    // 媒体键兜底：把 F1/F2/F11/F12 注册为「无修饰键」全局热键。
    // 覆盖用户按字面 F 键（Fn+F1/F2/F11/F12）时——这种情形不生成媒体事件，
    // 到不了会话级 tap，所以媒体键完全失灵。与媒体事件按 Fn 状态互斥，不会重复触发；
    // 且 Carbon 热键无需辅助功能权限，等于给亮度/音量上了双保险。
    if ([gConf[@"mediaKeys"] boolValue]) {
        struct { int kc; UInt32 hid; } fk[] = {
            { kVK_F2, 101 }, { kVK_F1, 102 }, { kVK_F12, 103 }, { kVK_F11, 104 }, { kVK_F10, 105 }
        };
        for (int i = 0; i < 5; i++) {
            EventHotKeyID fh;
            fh.signature = 'dltF';
            fh.id = fk[i].hid;
            EventHotKeyRef ref = NULL;
            if (RegisterEventHotKey(fk[i].kc, 0, fh, GetApplicationEventTarget(), 0, &ref) == noErr && ref)
                [self.hotKeyRefs addObject:[NSValue valueWithPointer:ref]];
        }
    }
}

// 普通 F 键（F1/F2/F10/F11/F12 标准键码）触发动作并启动连发
- (void)handleFunctionKeyPress:(int)act {
    if (act == -2) { [self doMute]; return; }   // 静音
    [self performAction:act];
    [self.repeatTimer invalidate];
    self.repeatTimer = [NSTimer timerWithTimeInterval:0.1 target:self selector:@selector(repeatTick:) userInfo:@(act) repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:self.repeatTimer forMode:NSRunLoopCommonModes];
}

- (void)stopRepeat {
    [self.repeatTimer invalidate];
    self.repeatTimer = nil;
}

- (void)handleHotkeyID:(UInt32)hid pressed:(BOOL)pressed {
    int act;
    if (hid >= 101 && hid <= 105) {
        // 101=F2亮度+ 102=F1亮度- 103=F12音量+ 104=F11音量- 105=F10静音
        act = (hid == 101) ? ActBrightUp : (hid == 102) ? ActBrightDown
            : (hid == 103) ? ActVolUp : (hid == 104) ? ActVolDown : -2;
    } else {
        act = (int)hid - 1;
        if (act < 0 || act >= ActCount) return;
    }
    if (pressed) {
        if (act == -2) { [self doMute]; return; }   // F10 静音（无连发）
        [self performAction:act];
        if (act == ActBrightUp || act == ActBrightDown || act == ActVolUp || act == ActVolDown) {
            [self.repeatTimer invalidate];
            // 0.1s 连发：长按 F1/F2/F10/F11/F12 持续步进（每步 1，实际节奏受 DDC 写入耗时限制）
            self.repeatTimer = [NSTimer timerWithTimeInterval:0.1 target:self selector:@selector(repeatTick:) userInfo:@(act) repeats:YES];
            [[NSRunLoop currentRunLoop] addTimer:self.repeatTimer forMode:NSRunLoopCommonModes];
        }
    } else {
        [self.repeatTimer invalidate];
        self.repeatTimer = nil;
    }
}

- (void)repeatTick:(NSTimer *)t {
    int act = [t.userInfo intValue];
    // 边界保护：值已到 0 / 最大值就停掉连发。
    // 否则 keyUp 一旦丢失，这个定时器会永久往下拖，把亮度拖到 0 还一直卡着。
    // 用 App 侧目标值判断（显示器回读滞后，不能用来判断"到没到边界"）。
    DlDisp *d = nil; int cur = 0, mx = 0; BOOL down = NO;
    if (act == ActBrightUp || act == ActBrightDown) {
        d = [self brightnessTargetDisp];
        if (d) { cur = [self currentLevelForDisp:d vcp:0x10 max:&mx]; down = (act == ActBrightDown); }
    } else if (act == ActVolUp || act == ActVolDown) {
        d = [self volumeTargetDisp];
        if (d) { cur = [self currentLevelForDisp:d vcp:0x62 max:&mx]; down = (act == ActVolDown); }
    } else {
        [t invalidate]; self.repeatTimer = nil;
        return;
    }
    if (d && ((down && cur <= 0) || (!down && cur >= mx))) {
        [t invalidate]; self.repeatTimer = nil;
        return;
    }
    [self performAction:act];
}

- (void)performAction:(int)act {
    NSString *mainID = nil, *secID = nil, *volID = nil;
    DlDisp *m = [self mainDisp];
    if (m) mainID = [NSString stringWithFormat:@"%d", m.did];
    DlDisp *vd = [self volumeTargetDisp];
    if (vd) volID = [NSString stringWithFormat:@"%d", vd.did];
    // 亮度目标屏：可跟随鼠标所在屏（brightnessTarget=mouse）
    DlDisp *bt = [self brightnessTargetDisp];
    NSString *brightID = bt ? [NSString stringWithFormat:@"%d", bt.did] : nil;
    int sid = [self secondaryID];
    if (sid > 0) secID = [NSString stringWithFormat:@"%d", sid];

    switch (act) {
        case ActBrightUp:
        case ActBrightDown: {
            DlDisp *bd = bt;
            if (!bd) return;
            int mx = 0;
            int cur = [self currentLevelForDisp:bd vcp:0x10 max:&mx];
            if (cur < 0) {                    // 无可信基准：跳过 + 立刻刷新，下次按键就正常
                NDLog(@"[perf] 亮度无基准值，跳过本次（避免跳到错误值）");
                [self refreshAsync];
                return;
            }
            int step = [gConf[@"stepBrightness"] intValue]; if (step <= 0) step = 2;
            int tgt = MIN(MAX(cur + (act == ActBrightUp ? step : -step), 0), mx);
            [self noteLevel:tgt did:bd.did vcp:0x10];
            [self showOSD:@"亮度" pct:tgt screen:[self screenForDisp:bd]];
            NDLog(@"[perf] 亮度 act=%d 屏=%@(id=%d) %d→%d 步进=%d", act, [bd displayName], bd.did, cur, tgt, step);
            [self writeLevel:tgt did:bd.did vcp:0x10];   // 绝对值写入 + 自动合并连发
            break;
        }
        case ActVolUp:
        case ActVolDown: {
            if ([self routeVolumeKeyToSystem:act]) return;   // 输出不是显示器 → 转发系统音量键
            DlDisp *vd2 = [self volumeTargetDisp];
            if (!vd2) return;
            int mx = 0;
            int cur = [self currentLevelForDisp:vd2 vcp:0x62 max:&mx];
            if (cur < 0) {
                // 显示器 DDC 音量读不到（不支持 DDC 音量 / 临时读失败）→ 退回系统主音量直写，
                // 保证"经显示器透传的音箱"等场景快捷键仍可用，不会被卡死。
                float sc = ndSystemVolume();
                if (sc >= 0) {
                    int stepPct = [gConf[@"stepVolume"] intValue]; if (stepPct <= 0) stepPct = 2;
                    float step = stepPct / 100.0f;
                    float st = MIN(MAX(sc + (act == ActVolUp ? step : -step), 0.0f), 1.0f);
                    ndSetSystemVolume(st);
                    [self showOSD:@"音量" pct:(int)(st * 100 + 0.5) screen:nil];
                    NDLog(@"[perf] 显示器 DDC 音量不可用 → 退回系统音量 %d%%→%d%%", (int)(sc*100+0.5), (int)(st*100+0.5));
                    return;
                }
                NDLog(@"[perf] 音量无基准值且系统音量读不到，跳过本次"
                      @"（当前输出设备可能是不暴露音量的蓝牙耳机）");
                [self refreshAsync];
                return;
            }
            int step = [gConf[@"stepVolume"] intValue]; if (step <= 0) step = 2;
            int tgt = MIN(MAX(cur + (act == ActVolUp ? step : -step), 0), mx);
            [self noteLevel:tgt did:vd2.did vcp:0x62];
            [self showOSD:@"音量" pct:tgt screen:[self screenForDisp:vd2]];
            NDLog(@"[perf] 音量 act=%d 屏=%@(id=%d) %d→%d 步进=%d", act, [vd2 displayName], vd2.did, cur, tgt, step);
            [self writeLevel:tgt did:vd2.did vcp:0x62];
            break;
        }
        case ActHiDPI:
            if (mainID) RunCLIAsync(@[@"hidpi", mainID, @"toggle"], ^(NSString *o) { [self refreshNow]; });
            break;
        case ActMain:
            if (secID) RunCLIAsync(@[@"main", secID], ^(NSString *o) { [self refreshNow]; });
            break;
        case ActConnect: {
            if (!secID) return;
            DlDisp *s = [self secondaryDisp];
            BOOL active = s ? s.isActive : NO;
            RunCLIAsync(@[active ? @"disable" : @"enable", secID], ^(NSString *o) { [self refreshNow]; });
            break;
        }
        case ActMode1:
        case ActMode2:
            if (mainID)
                RunCLIAsync(@[@"mode", mainID, gConf[act == ActMode1 ? @"mode1Spec" : @"mode2Spec"]], ^(NSString *o) { [self refreshNow]; });
            break;
        default:
            break;
    }
}

#pragma mark - 菜单

// 版本号（与 Info.plist 的 CFBundleShortVersionString 保持一致）
#define APP_VERSION   @"1.4.0"
#define APP_AUTHOR    @"@yangc8899"

- (void)menuWillOpen:(NSMenu *)menu { self.menuIsOpen = YES; }
- (void)menuDidClose:(NSMenu *)menu { self.menuIsOpen = NO; }

- (void)menuNeedsUpdate:(NSMenu *)menu {
    // 【防重入】构建过程中若又被触发一次（例如异步刷新回来引起），removeAllItems 会打断上一次构建，
    // 结果就是"某块显示器只剩内容、没有标题行"这种残缺菜单 —— 这里直接挡掉重入。
    if (self.menuBuilding) return;
    self.menuBuilding = YES;
    [self buildMenu:menu];
    self.menuBuilding = NO;
}

// 实际构建菜单内容（由 menuNeedsUpdate 调用）
- (void)buildMenu:(NSMenu *)menu {
    // 【打开加速】不再每次同步刷新（info 要跑多次 DDC 读取，华为屏很慢，菜单会卡 1~3 秒）。
    // 首次或缓存超过 6 秒才同步刷一次，其余情况直接用缓存渲染、后台异步刷新供下次使用。
    NSTimeInterval age = self.lastRefresh ? -[self.lastRefresh timeIntervalSinceNow] : 999;
    if (self.displays.count == 0 || age > 1.5) [self refreshNow];   // 阈值收紧：状态变更后菜单要立即反映
    else [self refreshAsync];
    [menu removeAllItems];

    // 冲突预警：BetterDisplay 若也在接管媒体键，亮度键会一次变两档
    if (self.betterDisplayRunning && [gConf[@"mediaKeys"] boolValue]) {
        NSMenuItem *w = [[NSMenuItem alloc] initWithTitle:@"⚠︎ BetterDisplay 在运行，可能双重响应媒体键"
                                                  action:@selector(onShowConflictHelp:) keyEquivalent:@""];
        w.target = self;
        [menu addItem:w];
        [menu addItem:[NSMenuItem separatorItem]];
    }

    // 媒体键接管已开启但 tap 没建起来（几乎都是缺辅助功能权限）→ 顶部告警 + 一键跳转授权
    if ([gConf[@"mediaKeys"] boolValue] && !self.mediaTap) {
        NSMenuItem *w = [[NSMenuItem alloc] initWithTitle:@"⚠︎ 媒体键未生效：点此授权辅助功能…"
                                                  action:@selector(onGrantAccess:) keyEquivalent:@""];
        w.target = self;
        [menu addItem:w];
        [menu addItem:[NSMenuItem separatorItem]];
    }

    if (self.displays.count == 0) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:@"（正在读取显示器…）" action:nil keyEquivalent:@""];
        it.enabled = NO;
        [menu addItem:it];
    }
    for (DlDisp *d in self.displays) {
        // 已关闭（断开）或已安全熄屏(27+)的屏不在"活动"区渲染：只保留下面 disabledIDs 段的一行标题+开关
        // —— 用户要求"关闭后配置收起，重新打开才展开"
        if (!d.isActive) continue;
        if ([self.disabledIDs containsObject:d.uuid]) continue;   // 软熄屏/真·断开统一在下方段显示，避免重复
        {
            NSString *sm = [d summary];
            if (d.isMain) sm = [sm stringByAppendingString:@" · 主屏"];
            [menu addItem:[self headerSwitchItemForID:[NSString stringWithFormat:@"%d", d.did]
                                                 name:[d displayName] summary:sm active:YES]];
        }
        if ([gConf[@"showBrightness"] boolValue]) [menu addItem:[self sliderItem:d vcp:0x10 title:@"亮度" value:d.bright max:d.bmax]];
        if ([gConf[@"showVolume"] boolValue])     [menu addItem:[self sliderItem:d vcp:0x62 title:@"音量" value:d.vol max:d.vmax]];
        if ([gConf[@"showResolution"] boolValue]) {
            NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:@"分辨率" action:nil keyEquivalent:@""];
            it.image = [self symImage:@"arrow.down.right.and.arrow.up.left"];
            it.submenu = [self resolutionMenuFor:d];
            [menu addItem:it];
        }
        if ([gConf[@"showRate"] boolValue]) {
            NSMenuItem *rt = [[NSMenuItem alloc] initWithTitle:@"刷新率" action:nil keyEquivalent:@""];
            rt.image = [self symImage:@"speedometer"];
            rt.submenu = [self ratesMenuFor:d];
            [menu addItem:rt];
        }
        if ([gConf[@"showHiDPI"] boolValue]) {
            NSMenuItem *hi = [self checkItem:@"高分辨率 (HiDPI)" on:d.modeHiDPI action:@selector(onToggleHiDPI:) obj:@(d.did)];
            hi.image = [self symImage:@"textformat.size"];
            [menu addItem:hi];
        }

        // —— 常驻于每块显示器下的控制项 ——
        // "高动态范围 (HDR)"：**只对该屏支持 HDR 时显示**（不支持的屏不展示这一项）
        if (ndHDRSupported(d.did)) {
            BOOL hdrOn = ndHDREnabled(d.did);
            NSMenuItem *hdrIt = [[NSMenuItem alloc] initWithTitle:@"高动态范围 (HDR)"
                                                          action:@selector(onToggleHDR:)
                                                   keyEquivalent:@""];
            hdrIt.target = self;
            hdrIt.representedObject = @(d.did);
            hdrIt.state = hdrOn ? NSControlStateValueOn : NSControlStateValueOff;
            hdrIt.image = [self symImage:@"sparkles"];
            [menu addItem:hdrIt];
        }

        // "设为主屏幕"：所有屏都显示；主屏打勾置灰（已是主屏），副屏可点
        NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:@"设为主屏幕" action:@selector(onSetMain:) keyEquivalent:@""];
        mi.image = [self symImage:@"star"];
        mi.target = self; mi.representedObject = @(d.did);
        mi.state = d.isMain ? NSControlStateValueOn : NSControlStateValueOff;
        mi.enabled = !d.isMain;
        [menu addItem:mi];

        // （屏幕旋转… / 显示器排序 / 快捷键一览 已按用户要求移除——2026-09-14）

        [menu addItem:[NSMenuItem separatorItem]];
    }

    for (NSString *sid in self.disabledIDs) {
        NSString *nm = self.dispNameByUUID[sid] ?: self.dispNameCache[sid]
                       ?: [NSString stringWithFormat:@"显示器 %.8s", sid.UTF8String];
        [menu addItem:[self headerSwitchItemForID:sid name:nm summary:@"已关闭（拨动右侧开关可点亮）" active:NO]];
        [menu addItem:[NSMenuItem separatorItem]];
    }

    // 布局快照 / 应急恢复 已挪到设置窗口"高级"页，主菜单不再显示
    // （"快捷键一览" 已按用户要求移除——2026-09-14；键位说明见设置窗口）

    // 声音输出方式（CoreAudio）：列出所有输出设备，当前默认打勾，点击即切换
    // 一律用 UID 定位设备（蓝牙耳机有同名 input/output 两个端点，且 ID 重连后会变）
    {
        NSString *curUID = ndCurrentOutputUID();
        NSArray<NSString *> *uids = ndAudioOutputUIDs();
        NSMenu *sub = [[NSMenu alloc] init];
        sub.autoenablesItems = NO;
        if (!uids.count) {
            NSMenuItem *none = [self plainItem:@"（未检测到输出设备）" action:nil];
            none.enabled = NO;
            [sub addItem:none];
        } else {
            for (NSString *u in uids) {
                NSString *name = ndNameForUID(u) ?: u;
                BOOL isCur = (curUID && [u isEqualToString:curUID]);
                NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:name
                                                          action:@selector(onPickAudioOutput:)
                                                   keyEquivalent:@""];
                mi.target = self;
                mi.representedObject = u;          // 存 UID，不存名字
                // 当前设备打勾即可，**不要置灰**（置灰很难看，用户明确要求）
                mi.state = isCur ? NSControlStateValueOn : NSControlStateValueOff;
                mi.enabled = YES;
                mi.indentationLevel = 0;
                [sub addItem:mi];
            }
        }
        NSMenuItem *snd = [[NSMenuItem alloc] initWithTitle:@"声音输出方式" action:nil keyEquivalent:@""];
        snd.submenu = sub;
        snd.image = [self symImage:@"speaker.wave.2"];
        [menu addItem:snd];
        [menu addItem:[NSMenuItem separatorItem]];
    }

    NSMenuItem *setIt = [self plainItem:@"设置…" action:@selector(onOpenSettings:)];
    setIt.image = [self symImage:@"gearshape"];
    [menu addItem:setIt];
    [menu addItem:[NSMenuItem separatorItem]];
    // 版本信息只在「设置 → 常规」页显示，菜单里不显示（用户要求：菜单保持干净）
    NSMenuItem *quitIt = [self plainItem:@"退出" action:@selector(onQuit:)];
    quitIt.image = [self symImage:@"power"];
    [menu addItem:quitIt];

    // 【现场诊断】把真实菜单结构写文件（只在"运行时"才出现的渲染怪问题，靠它定位）
    {
        NSMutableString *dbg = [NSMutableString string];
        [dbg appendFormat:@"displays=%lu disabled=%lu\n", (unsigned long)self.displays.count,
                          (unsigned long)self.disabledIDs.count];
        for (DlDisp *x in self.displays)
            [dbg appendFormat:@"  disp id=%d active=%d name='%@' summary='%@'\n",
                              x.did, x.isActive, [x displayName], [x summary]];
        for (NSMenuItem *it in menu.itemArray) {
            [dbg appendFormat:@"item '%@' view=%@ subviews=%lu\n", it.title,
                              it.view ? @"Y" : @"N", (unsigned long)it.view.subviews.count];
            for (NSView *sv in it.view.subviews)
                [dbg appendFormat:@"   %@ frame=%@ text='%@'\n", NSStringFromClass([sv class]),
                                  NSStringFromRect(sv.frame),
                                  [sv isKindOfClass:[NSTextField class]] ? [(NSTextField *)sv stringValue] : @""];
        }
        [dbg writeToFile:@"/tmp/nd_menu.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

// 自定义菜单视图里的文字/图标必须**显式按当前系统外观取色**：
// 动态色（labelColor 等）是按视图自身的 appearance 解析的，而这里是自己 new 出来的视图，
// 默认 appearance 可能是浅色 → 在深色菜单里就变成"黑字画在黑底上"→ 整块标题行看起来消失了。
- (BOOL)darkUI {
    NSAppearanceName n = [[NSApp effectiveAppearance]
        bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
    return [n isEqualToString:NSAppearanceNameDarkAqua];
}

- (NSColor *)uiPrimary { return [self darkUI] ? [NSColor whiteColor] : [NSColor blackColor]; }
- (NSColor *)uiSecondary {
    return [self darkUI] ? [NSColor colorWithWhite:1.0 alpha:0.62] : [NSColor colorWithWhite:0.0 alpha:0.55];
}

- (NSMenuItem *)plainItem:(NSString *)title action:(SEL)sel {
    NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:title action:sel keyEquivalent:@""];
    it.target = self;
    return it;
}

- (NSMenuItem *)checkItem:(NSString *)title on:(BOOL)on action:(SEL)sel obj:(id)obj {
    NSMenuItem *it = [self plainItem:title action:sel];
    it.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    it.representedObject = obj;
    return it;
}

// SF Symbol 图标（名字写错就返回 nil，菜单自然无图标，安全）
// 【关键】必须设 template = YES：否则系统按 SF Symbol 原色（近乎黑）绘制，
// 在深色菜单里就是"一团黑"，看起来像禁用状态。
- (NSImage *)symImage:(NSString *)name {
    NSImage *img = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    if (!img) return nil;
    NSImageSymbolConfiguration *cfg =
        [NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightRegular];
    NSImage *styled = [img imageWithSymbolConfiguration:cfg] ?: img;
    NSImage *sz = [[NSImage alloc] initWithSize:NSMakeSize(14, 14)];
    [sz lockFocus];
    [styled drawInRect:NSMakeRect(0, 0, 14, 14) fromRect:NSZeroRect
             operation:NSCompositingOperationSourceOver fraction:1.0];
    [sz unlockFocus];
    sz.template = YES;      // ← 跟随菜单前景色（深色菜单里显白）
    return sz;
}

// 显示器标题行：图标 + 名字(加粗) + 摘要(小灰字) + 右侧开关 —— BetterDisplay 风格
// 显示器标题行 + 连接开关 —— 用**系统标准菜单项**渲染
// （原来用自定义 NSView + NSSwitch，实测在菜单里会出现"整行不可见"的渲染问题，
//   改用系统渲染后标题/图标/勾选一定正常。）
- (void)onNoop:(id)sender { }

// 显示器行：**显示器名 + 摘要 + 连接状态合并成一项**（系统勾选行渲染，颜色一定正常）
// 勾 = 已连接，点击即断开/连回。不再使用"名字行 + 摘要副标题"那种写法——
// macOS 会把不带点击动作的项一律渲染成灰色，绕不过去。
// 显示器标题行：图标 + 名字（加粗）+ 摘要（小字）+ **右侧拨杆开关** —— BetterDisplay 风格
// 着色一律显式指定（按系统外观），不依赖动态色，避免在深色菜单里被算成黑字而看不见。
- (NSMenuItem *)headerSwitchItemForID:(NSString *)did name:(NSString *)name summary:(NSString *)sum active:(BOOL)active {
    // 防御：名字/摘要为空时用占位文本，绝不把 nil 塞给 NSTextField；任何异常都退回系统纯文本行。
    NSString *nmSafe = name.length ? name : [NSString stringWithFormat:@"显示器 %@", did];
    NSString *sumSafe = sum.length ? sum : @"";
    @try {
    NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    NSView *box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 46)];   // 标题行加高，和下方滑块拉开距离

    NSImageView *ic = [[NSImageView alloc] initWithFrame:NSMakeRect(10, 15, 16, 16)];
    ic.image = [self symImage:active ? @"display" : @"rectangle.dashed"];
    ic.contentTintColor = [NSColor labelColor];   // 自定义视图里的模板图需显式着色，否则可能显黑
    if (ic.image) [box addSubview:ic];

    NSTextField *lab = [[NSTextField alloc] initWithFrame:NSMakeRect(34, 21, 208, 18)];
    lab.stringValue = nmSafe;
    lab.bezeled = NO; lab.editable = NO; lab.drawsBackground = NO;
    lab.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    if (!active) lab.textColor = [NSColor secondaryLabelColor];
    [box addSubview:lab];

    NSTextField *sub = [[NSTextField alloc] initWithFrame:NSMakeRect(34, 6, 208, 15)];
    sub.stringValue = sumSafe;
    sub.bezeled = NO; sub.editable = NO; sub.drawsBackground = NO;
    sub.font = [NSFont systemFontOfSize:10];
    sub.textColor = [NSColor secondaryLabelColor];
    [box addSubview:sub];

    NSSwitch *sw = [[NSSwitch alloc] initWithFrame:NSMakeRect(252, 14, 40, 20)];
    sw.state = active ? NSControlStateValueOn : NSControlStateValueOff;
    sw.identifier = did;
    sw.target = self; sw.action = @selector(onSwitchConnect:);
    [box addSubview:sw];

    it.view = box;
    return it;
    } @catch (NSException *e) {
        NDLog(@"[menu] 标题行构建异常: %@ — 退回纯文本行", e.reason);
        NSMenuItem *fb = [[NSMenuItem alloc] initWithTitle:nmSafe action:nil keyEquivalent:@""];
        fb.image = [self symImage:active ? @"display" : @"rectangle.dashed"];
        return fb;
    }
}

- (NSMenuItem *)displayRowFor:(DlDisp *)d {
    NSString *name = [d displayName];
    if (d.isMain) name = [name stringByAppendingString:@"（主屏）"];
    NSString *title = [NSString stringWithFormat:@"%@  %@", name, [d summary]];
    NSMenuItem *it = [self checkItem:title on:YES
                              action:@selector(onToggleConnectMenu:)
                                 obj:[NSString stringWithFormat:@"%d", d.did]];
    it.image = [self symImage:@"display"];
    return it;
}   // 空动作：只为让系统用正常文字色渲染标题行

// 标题行文本：显示器名（正常色、加粗）+ 摘要（次要色、小字），用 attributed 强制指定颜色，
// 不依赖系统对"无动作菜单项"的灰色渲染。
- (NSAttributedString *)headerTextForName:(NSString *)name info:(NSString *)info {
    NSMutableAttributedString *as = [[NSMutableAttributedString alloc] init];
    if (name.length) {
        [as appendAttributedString:[[NSAttributedString alloc] initWithString:name
            attributes:@{NSForegroundColorAttributeName: [self uiPrimary],
                         NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]}]];
    }
    if (info.length) {
        [as appendAttributedString:[[NSAttributedString alloc] initWithString:
            (name.length ? [@"  " stringByAppendingString:info] : info)
            attributes:@{NSForegroundColorAttributeName: [self uiSecondary],
                         NSFontAttributeName: [NSFont systemFontOfSize:11]}]];
    }
    return as;
}

- (NSMenuItem *)headerItemFor:(DlDisp *)d {
    NSString *title = [d displayName];
    if (d.isMain) title = [title stringByAppendingString:@"（主屏）"];
    NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:title action:@selector(onNoop:) keyEquivalent:@""];
    it.target = self;                 // 有 target/action 才不会被系统按"灰色信息行"渲染
    it.image = [self symImage:@"display"];
    it.attributedTitle = [self headerTextForName:title info:[d summary]];   // 显式颜色，双保险
    return it;
}

// 连接开关：勾 = 已连接，点击切换（关 = 熄屏断开）
- (NSMenuItem *)connectItemFor:(NSString *)did active:(BOOL)active {
    NSMenuItem *it = [self checkItem:(active ? @"已连接" : @"已断开") on:active
                              action:@selector(onToggleConnectMenu:) obj:did];
    it.image = [self symImage:active ? @"checkmark.circle" : @"circle.slash"];
    return it;
}

- (void)onToggleConnectMenu:(NSMenuItem *)it {
    NSString *did = [it.representedObject stringValue];
    BOOL nowOn = (it.state == NSControlStateValueOn);
    [self.statusItem.menu cancelTracking];   // 同上：先收起菜单再改显示器配置
    RunCLIAsync(@[nowOn ? @"disable" : @"enable", did], ^(NSString *o) {
        if ([o rangeOfString:@"拒绝"].location != NSNotFound)
            [self alert:@"不能断开最后一块显示器" text:@"系统要求至少保留一块活动显示器，操作已取消。"];
        [self refreshNow];
    });
}


// 标题行的开关：开 = 连接，关 = 熄屏断开
- (void)onSwitchConnect:(NSSwitch *)sw {
    NSString *did = sw.identifier ?: [NSString stringWithFormat:@"%ld", (long)sw.tag];
    BOOL wantOn = (sw.state == NSControlStateValueOn);

    // 【关键】先收起菜单再操作显示器。
    // 关闭/开启显示器会让系统重排菜单栏，如果菜单还开着，整个菜单会被挪位置（用户看到"菜单上移、
    // 第一行被挤出屏幕、看不到显示器名称"）。收起来操作就完全没有这个问题。
    [self.statusItem.menu cancelTracking];
    RunCLIAsync(@[wantOn ? @"enable" : @"disable", did], ^(NSString *o) {
        if ([o rangeOfString:@"拒绝"].location != NSNotFound)
            [self alert:@"不能断开最后一块显示器" text:@"系统要求至少保留一块活动显示器，操作已取消。"];
        else if (wantOn && [o rangeOfString:@"电源键"].location != NSNotFound)
            [self alert:@"该显示器处于硬待机" text:@"链路已断，软件无法点亮：请按一下显示器电源键。"];
        [self refreshNow];   // 同步刷新：保证下次打开菜单就是最新状态
    });
}

- (NSMenuItem *)sliderItem:(DlDisp *)d vcp:(int)vcp title:(NSString *)title value:(int)value max:(int)mx {
    // HDR 屏：DDC 亮度被屏蔽 → 滑块反映并控制"软件调暗"
    BOOL hdrDim = (vcp == 0x10) && DisplayIsEDR(d.did);
    if (hdrDim) {
        // 显示软件亮度（没挂过调暗层就是硬件最亮 100）
        value = ndGetSoftwareBrightness(d.did);
        mx = 100;
    } else {
        // DDC 回读失败时**别拿无效值渲染**（默认 0）——菜单每次重建滑条都会跳到 0，
        // 看起来就是"滑条乱跳"。回读不到就沿用本屏上次已知的目标值。
        BOOL known = (vcp == 0x10) ? d.brightKnown : d.volKnown;
        if (!known) {
            NSNumber *t = nil;
            @synchronized (self) { t = self.ddcTarget[[self ddcKey:d.did vcp:vcp]]; }
            if (t) value = t.intValue;
        }
    }
    NSString *dispTitle = hdrDim ? @"亮度(软件)" : title;
    NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    NSView *box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 38)];   // 行高 32→38，加大行距

    // 左侧小图标：亮度=太阳，音量=喇叭（图标缺失时退回文字标签）
    NSString *sym = (vcp == 0x10) ? @"sun.max" : @"speaker.wave.2";
    NSImageView *iv = [[NSImageView alloc] initWithFrame:NSMakeRect(14, 12, 14, 14)];
    iv.image = [self symImage:sym];
    iv.contentTintColor = [NSColor labelColor];
    if (iv.image) [box addSubview:iv];

    CGFloat labX = iv.image ? 34 : 14;
    NSTextField *lab = [[NSTextField alloc] initWithFrame:NSMakeRect(labX, 8, hdrDim ? 74 : 32, 18)];
    lab.stringValue = dispTitle;
    lab.bezeled = NO; lab.editable = NO; lab.drawsBackground = NO;
    lab.font = [NSFont menuFontOfSize:12];
    if (hdrDim) lab.textColor = [NSColor secondaryLabelColor];
    [box addSubview:lab];

    CGFloat slX = hdrDim ? 110 : 68;
    NSSlider *sl = [[NSSlider alloc] initWithFrame:NSMakeRect(slX, 8, 240 - slX, 22)];
    sl.minValue = 0;
    sl.maxValue = mx > 0 ? mx : 100;
    sl.doubleValue = value;
    sl.continuous = YES;   // 拖动时实时随动（每帧触发 onSlider，由节流逻辑限制 DDC 写入频率）
    sl.target = self;
    sl.action = @selector(onSlider:);
    sl.identifier = [NSString stringWithFormat:@"%d:%d", d.did, vcp];
    [box addSubview:sl];

    NSTextField *val = [[NSTextField alloc] initWithFrame:NSMakeRect(248, 9, 44, 18)];
    val.stringValue = [NSString stringWithFormat:@"%d%%", value];
    val.bezeled = NO; val.editable = NO; val.drawsBackground = NO;
    val.font = [NSFont menuFontOfSize:11];
    val.textColor = [NSColor secondaryLabelColor];
    val.alignment = NSTextAlignmentRight;
    val.tag = 99;
    [box addSubview:val];

    it.view = box;
    return it;
}

// 刷新率子菜单：列出"当前分辨率 + HiDPI"下该屏支持的所有刷新率（降序，最高在最上面，当前项打勾）
- (NSMenu *)ratesMenuFor:(DlDisp *)d {
    NSMenu *m = [[NSMenu alloc] init];
    NSString *out = RunCLI(@[@"rates", [NSString stringWithFormat:@"%d", d.did]]);
    for (NSString *raw in [out componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (line.length == 0) continue;
        if ([line hasPrefix:@"mode "]) continue;          // 首行是当前模式描述，跳过
        BOOL isCur = [line hasPrefix:@"current "];
        NSString *hzStr = isCur ? [line substringFromIndex:8] : line;   // "144Hz"
        NSString *hzNum = [hzStr stringByReplacingOccurrencesOfString:@"Hz" withString:@""];
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:hzStr action:@selector(onPickRate:) keyEquivalent:@""];
        it.target = self;
        it.representedObject = @[[NSString stringWithFormat:@"%d", d.did], hzNum];
        it.state = isCur ? NSControlStateValueOn : NSControlStateValueOff;
        [m addItem:it];
    }
    if (m.numberOfItems == 0) {
        NSMenuItem *e = [[NSMenuItem alloc] initWithTitle:@"（该分辨率下只有一种刷新率）" action:nil keyEquivalent:@""];
        e.enabled = NO;
        [m addItem:e];
    }
    return m;
}

- (NSMenu *)resolutionMenuFor:(DlDisp *)d {
    NSMenu *m = [[NSMenu alloc] init];
    NSString *out = RunCLI(@[@"presets", [NSString stringWithFormat:@"%d", d.did]]);
    for (NSString *raw in [out componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (line.length == 0) continue;
        BOOL isCur = [line hasPrefix:@"current "];
        NSString *spec = isCur ? [line substringFromIndex:8] : line;
        NSArray *t = [spec componentsSeparatedByString:@" "];
        if (t.count < 3) continue;
        NSString *res = t[0];
        BOOL hidpi = [t[1] isEqualToString:@"HiDPI"];
        NSString *hz = [t[2] stringByReplacingOccurrencesOfString:@"Hz" withString:@""];
        NSString *title = hidpi ? [NSString stringWithFormat:@"%@   HiDPI (锐利)", res] : res;
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:title action:@selector(onPickMode:) keyEquivalent:@""];
        it.target = self;
        it.representedObject = @[[NSString stringWithFormat:@"%d", d.did],
                                 [NSString stringWithFormat:@"%@@%@:%@", res, hz, hidpi ? @"hidpi" : @"lodpi"]];
        it.state = isCur ? NSControlStateValueOn : NSControlStateValueOff;
        [m addItem:it];
    }
    if (m.numberOfItems == 0) {
        NSMenuItem *e = [[NSMenuItem alloc] initWithTitle:@"（无可用预设分辨率）" action:nil keyEquivalent:@""];
        e.enabled = NO;
        [m addItem:e];
    }
    return m;
}

#pragma mark - 菜单动作

- (void)onSlider:(NSSlider *)sl {
    NSArray *p = [sl.identifier componentsSeparatedByString:@":"];
    if (p.count != 2) return;
    NSString *did = p[0];
    int vcp = [p[1] intValue];
    int v = (int)lround(sl.doubleValue);
    NSView *box = sl.superview;
    for (NSView *sub in box.subviews)
        if (sub.tag == 99 && [sub isKindOfClass:[NSTextField class]])
            ((NSTextField *)sub).stringValue = [NSString stringWithFormat:@"%d%%", v];
    // OSD 反馈（显示在该显示器所在屏的左上角）
    DlDisp *sd = [self dispByID:did.intValue];
    if (sd) [self noteLevel:v did:sd.did vcp:vcp];   // 与快捷键通路共用同一份目标值
    [self showOSD:(vcp == 0x10 ? @"亮度" : @"音量") pct:v screen:[self screenForDisp:sd]];
    self.sliderDragging = YES;
    // 节流：上一个写入还在飞就只记最新值，避免进程堆积
    if (self.sliderBusy) { self.sliderPending = v; self.sliderPendingIdent = sl.identifier; return; }
    self.sliderBusy = YES;
    [self sliderWriteDid:did vcp:vcp value:v ident:sl.identifier];
}

- (void)sliderWriteDid:(NSString *)did vcp:(int)vcp value:(int)v ident:(NSString *)ident {
    // HDR 屏：DDC 亮度被显示器屏蔽 → 走软件调暗，不写硬件
    if (vcp == 0x10 && did.intValue > 0 && DisplayIsEDR(did.intValue)) {
        ndSetSoftwareBrightness(did.intValue, MIN(MAX(v, 0), 100));
        NDLog(@"[hdr] display %d 滑块软件亮度 → %d%%", did.intValue, v);
        if (self.sliderPending && [self.sliderPendingIdent isEqualToString:ident] && self.sliderPending != v) {
            int pv = self.sliderPending; self.sliderPending = 0; self.sliderBusy = NO;
            [self sliderWriteDid:did vcp:vcp value:pv ident:ident];
        } else {
            self.sliderBusy = NO;
        }
        return;
    }
    RunCLIAsync(@[@"ddc", @"set", did, vcp == 0x10 ? @"0x10" : @"0x62", [NSString stringWithFormat:@"%d", v]],
                ^(NSString *o) {
        if (self.sliderPending && [self.sliderPendingIdent isEqualToString:ident] && self.sliderPending != v) {
            int pv = self.sliderPending;
            self.sliderPending = 0;
            [self sliderWriteDid:did vcp:vcp value:pv ident:ident];  // 继续写最新值
        } else {
            self.sliderBusy = NO;
            self.sliderPending = 0;
            self.sliderDragging = NO;
            [self refreshAsync];
        }
    });
}

// 在预设列表里挑一个模式：wantHiDPI=YES 取"面积最大的 HiDPI 模式"，NO 取"面积最大的普通模式"
- (NSString *)bestModeSpecFor:(int)did hidpi:(BOOL)wantHiDPI {
    NSString *out = RunCLI(@[@"presets", [NSString stringWithFormat:@"%d", did]]);
    for (NSString *raw in [out componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (line.length == 0) continue;
        NSString *spec = [line hasPrefix:@"current "] ? [line substringFromIndex:8] : line;
        NSArray *t = [spec componentsSeparatedByString:@" "];
        if (t.count < 3) continue;
        BOOL hidpi = [t[1] isEqualToString:@"HiDPI"];
        if (hidpi != wantHiDPI) continue;
        NSString *hz = [t[2] stringByReplacingOccurrencesOfString:@"Hz" withString:@""];
        return [NSString stringWithFormat:@"%@@%@:%@", t[0], hz, hidpi ? @"hidpi" : @"lodpi"];
    }
    return nil;
}

// 勾选 HiDPI → 直接切到该屏支持的最高 HiDPI 分辨率；取消勾选 → 切回最高的普通分辨率
- (void)onToggleHiDPI:(NSMenuItem *)it {
    int did = [it.representedObject intValue];
    DlDisp *d = [self dispByID:did];
    BOOL wantHiDPI = !(d ? d.modeHiDPI : NO);
    NSString *spec = [self bestModeSpecFor:did hidpi:wantHiDPI];
    if (!spec) {
        [self alert:wantHiDPI ? @"没有可用的 HiDPI 模式" : @"没有可用的普通模式"
               text:@"该显示器没有可切换的对应模式。"];
        return;
    }
    NDLog(@"[mode] 切换 id=%d HiDPI=%d → %@", did, wantHiDPI, spec);
    RunCLIAsync(@[@"mode", [NSString stringWithFormat:@"%d", did], spec], ^(NSString *o) { [self refreshNow]; });
}

// 切换刷新率：保持当前分辨率与 HiDPI 组合，只改刷新率
- (void)onPickRate:(NSMenuItem *)it {
    NSArray *a = it.representedObject;
    if (a.count < 2) return;
    NSString *did = a[0];
    NSString *hz  = a[1];
    DlDisp *d = [self dispByID:did.intValue];
    if (!d) return;
    NSString *spec = [NSString stringWithFormat:@"%dx%d@%@:%@",
                      d.modeW, d.modeH, hz, d.modeHiDPI ? @"hidpi" : @"lodpi"];
    NDLog(@"[rate] 切换 id=%@ → %@", did, spec);
    RunCLIAsync(@[@"mode", did, spec], ^(NSString *o) { [self refreshNow]; });
}

- (void)onSetMain:(NSMenuItem *)it {
    RunCLIAsync(@[@"main", [it.representedObject stringValue]], ^(NSString *o) { [self refreshNow]; });
}

// 屏幕旋转：直达系统设置 → 显示器，并尝试用辅助功能接口自动选中目标屏的缩略图
- (void)onOpenRotationSettings:(NSMenuItem *)it {
    DlDisp *d = [self dispByID:[it.representedObject intValue]];
    NSString *name = [d displayName];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.Display-Settings.extension"]];
    // 等系统设置窗口起来后，AX 自动点击目标显示器缩略图（失败则静默放弃，用户手点即可）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self axSelectDisplayNamed:name];
    });
}

// 在 System Settings 里找 label 含显示器名的可点元素并 AXPress
- (void)axSelectDisplayNamed:(NSString *)name {
    if (name.length == 0) return;
    NSArray *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.systempreferences"];
    if (apps.count == 0) return;
    NSRunningApplication *sa = apps.firstObject;
    AXUIElementRef app = AXUIElementCreateApplication(sa.processIdentifier);
    @autoreleasepool {
        CFArrayRef windows = NULL;
        if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, (CFTypeRef *)&windows) != kAXErrorSuccess || !windows) {
            CFRelease(app); return;
        }
        __block BOOL done = NO;
        __block void (^walk)(AXUIElementRef, int);
        walk = ^(AXUIElementRef el, int depth) {
            if (done || depth > 14) return;
            CFStringRef role = NULL, title = NULL, desc = NULL;
            CFTypeRef val = NULL;
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute, (CFTypeRef *)&role);
            AXUIElementCopyAttributeValue(el, kAXTitleAttribute, (CFTypeRef *)&title);
            AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute, (CFTypeRef *)&desc);
            AXUIElementCopyAttributeValue(el, kAXValueAttribute, (CFTypeRef *)&val);
            NSMutableString *txt = [NSMutableString string];
            if (title) [txt appendString:(__bridge NSString *)title];
            if (desc)  [txt appendString:(__bridge NSString *)desc];
            if (val && CFGetTypeID(val) == CFStringGetTypeID()) [txt appendString:(__bridge NSString *)val];
            // 显示器缩略图：可 press 的按钮，label 里带显示器名（如 "Q27U2G5R4-"）
            if (role && CFStringCompare(role, kAXButtonRole, 0) == kCFCompareEqualTo &&
                [txt rangeOfString:name].location != NSNotFound) {
                if (AXUIElementPerformAction(el, kAXPressAction) == kAXErrorSuccess) done = YES;
            }
            if (role) CFRelease(role);
            if (title) CFRelease(title);
            if (desc) CFRelease(desc);
            if (val) CFRelease(val);
            if (done) return;
            CFArrayRef kids = NULL;
            if (AXUIElementCopyAttributeValue(el, kAXChildrenAttribute, (CFTypeRef *)&kids) == kAXErrorSuccess && kids) {
                for (CFIndex i = 0; i < CFArrayGetCount(kids); i++) {
                    AXUIElementRef k = (AXUIElementRef)CFArrayGetValueAtIndex(kids, i);
                    if (k) walk(k, depth + 1);
                    if (done) break;
                }
                CFRelease(kids);
            }
        };
        for (CFIndex i = 0; i < CFArrayGetCount(windows) && !done; i++) {
            AXUIElementRef w = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
            if (w) walk(w, 0);
        }
        walk = nil;   // 释放递归 block，避免保留环
        CFRelease(windows);
    }
    CFRelease(app);
}

- (void)onArrange:(NSMenuItem *)it {
    NSArray *a = it.representedObject;
    if (a.count < 2) return;
    NSString *did = [a[0] stringValue];
    NSString *side = a[1];   // @"right" 主屏在左 / @"left" 主屏在右
    RunCLIAsync(@[@"arrange", did, side], ^(NSString *o) {
        [self refreshNow];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self alert:@"显示器排序" text:o.length ? o : @"已重排"];
        });
    });
}

- (void)onRotate:(NSMenuItem *)it {
    NSArray *a = it.representedObject;
    if (a.count < 2) return;
    NSString *did = [a[0] stringValue];
    NSString *deg = [a[1] stringValue];
    RunCLIAsync(@[@"rotate", did, deg], ^(NSString *o) {
        [self refreshNow];
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([o rangeOfString:@"无法"].location != NSNotFound ||
                [o rangeOfString:@"失败"].location != NSNotFound) {
                NSAlert *al = [[NSAlert alloc] init];
                al.messageText = @"本机无法用 NiceDisplay 旋转";
                al.informativeText = [NSString stringWithFormat:@"%@\n\n可改为在「系统设置 → 显示器 → 旋转」中调整。", o];
                [al addButtonWithTitle:@"打开系统设置"];
                [al addButtonWithTitle:@"好"];
                if ([al runModal] == NSAlertFirstButtonReturn)
                    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.Displays-Settings.extension"]];
            } else if (o.length) {
                [self alert:@"屏幕旋转" text:o];
            }
        });
    });
}

- (void)onToggleConnect:(NSMenuItem *)it {
    NSString *did = [it.representedObject stringValue];
    BOOL active = (it.state == NSControlStateValueOn);
    RunCLIAsync(@[active ? @"disable" : @"enable", did], ^(NSString *o) {
        if ([o rangeOfString:@"拒绝"].location != NSNotFound)
            [self alert:@"不能断开最后一块显示器" text:@"系统要求至少保留一块活动显示器，操作已取消。"];
        [self refreshNow];   // 同步刷新：保证下次打开菜单就是最新状态
    });
}

// 「关闭显示器」按钮：熄掉这块屏（系统级断开，恢复走菜单里的「打开显示器」）
- (void)onTurnOffDisplay:(NSMenuItem *)it {
    NSString *did = [it.representedObject stringValue];
    RunCLIAsync(@[@"disable", did], ^(NSString *o) {
        if ([o rangeOfString:@"拒绝"].location != NSNotFound)
            [self alert:@"不能关闭这块显示器" text:@"系统要求至少保留一块活动显示器，操作已取消。"];
        [self refreshNow];
    });
}

- (void)onEnableID:(NSMenuItem *)it {
    RunCLIAsync(@[@"enable", [it.representedObject description]], ^(NSString *o) { [self refreshNow]; });
}

- (void)onPickMode:(NSMenuItem *)it {
    NSArray *a = it.representedObject;
    RunCLIAsync(@[@"mode", a[0], a[1]], ^(NSString *o) { [self refreshNow]; });
}

- (void)onLayoutSave:(id)sender {
    RunCLIAsync(@[@"layout", @"save"], ^(NSString *o) { [self alert:@"布局快照" text:o.length ? o : @"已保存"]; });
}

- (void)onLayoutRestore:(id)sender {
    RunCLIAsync(@[@"layout", @"restore"], ^(NSString *o) { [self alert:@"还原布局" text:o.length ? o : @"已还原"]; [self refreshAsync]; });
}

- (void)onLayoutShow:(id)sender {
    RunCLIAsync(@[@"layout", @"show"], ^(NSString *o) { [self alert:@"已保存的布局快照" text:o.length ? o : @"（空）"]; });
}

- (void)onRestoreAll:(id)sender {
    RunCLIAsync(@[@"restore"], ^(NSString *o) { [self alert:@"应急恢复" text:o.length ? o : @"已执行"]; [self refreshAsync]; });
}

- (void)onQuit:(id)sender { [NSApp terminate:nil]; }

- (void)onShowConflictHelp:(id)sender {
    NSString *t = @"检测到 BetterDisplay 正在运行，而它默认也会接管键盘的亮度媒体键。\n\n"
                  @"两个程序同时接管时，按一下亮度键会连续变两档。\n\n"
                  @"建议二选一：\n"
                  @"· 退出 BetterDisplay（菜单栏它的图标 → 退出），或\n"
                  @"· 关掉 BetterDisplay 里的键盘/媒体键接管功能\n\n"
                  @"退出 BetterDisplay 后，本工具的亮度与音量功能不受影响。";
    [self alert:@"媒体键冲突" text:t];
}

// 跳转到「系统设置 → 隐私与安全性 → 辅助功能」，媒体键 tap 必须靠这个权限
- (void)onGrantAccess:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:
        [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
    // 顺带再触发一次系统授权弹窗；勾上后需重启本 App 才真正生效
    NSDictionary *opts = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
}

- (void)alert:(NSString *)title text:(NSString *)text {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = title;
    a.informativeText = text;
    [a addButtonWithTitle:@"好"];
    [a runModal];
}

#pragma mark - 设置窗口

- (NSTextField *)label:(NSString *)s frame:(NSRect)f bold:(BOOL)bold {
    NSTextField *t = [[NSTextField alloc] initWithFrame:f];
    t.stringValue = s;
    t.bezeled = NO; t.editable = NO; t.drawsBackground = NO;
    t.font = bold ? [NSFont boldSystemFontOfSize:13] : [NSFont systemFontOfSize:12];
    return t;
}

- (void)onPickAudioOutput:(NSMenuItem *)it {
    NSString *uid = it.representedObject;      // UID（稳定标识）
    if (!uid.length) return;
    NSString *name = ndNameForUID(uid) ?: uid;
    [self.statusItem.menu cancelTracking];   // 先收起菜单，避免切换输出时菜单被系统抢焦点
    if (ndSetDefaultOutputByUID(uid)) {
        NDLog(@"[audio] 默认输出已切换 → %@ (uid=%@)", name, uid);
        // 通知系统"输出设备变了"，让控制中心/音量 HUD 同步刷新
        AudioObjectPropertyAddress np = {
            kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
        };
        AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &np, dispatch_get_main_queue(),
                                            ^(UInt32 n, const AudioObjectPropertyAddress *a) { (void)n; (void)a; });
        // 切换后音量目标屏可能变了（显示器 vs 耳机/音箱）→ 立刻刷新菜单
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self refreshNow]; });
    } else {
        NDLog(@"[audio] 切换默认输出失败: %@ (uid=%@)", name, uid);
        [self alert:@"切换声音输出失败" text:[NSString stringWithFormat:@"无法把“%@”设为默认输出设备。\n\n该设备可能已断开，或系统拒绝切换（蓝牙耳机请先确保已连接）。", name]];
    }
}

// 切换某块屏的高动态范围（HDR）
- (void)onToggleHDR:(NSMenuItem *)it {
    int did = [it.representedObject intValue];
    BOOL want = !ndHDREnabled(did);
    [self.statusItem.menu cancelTracking];      // 先收菜单再切（HDR 切换会重配显示器）
    BOOL ok = ndSetHDREnabled(did, want);
    NDLog(@"[hdr] display %d 开关高动态范围 → %d  %s", did, (int)want, ok ? "已生效" : "未生效（被弹回）");
    if (!ok) {
        [self alert:@"切换高动态范围失败"
                text:@"系统没有接受这次切换 —— 部分第三方显示器在 macOS 上会自己弹回去。\n\n"
                     @"可以试试：拔插一次 DP 线，或直接改显示器自己 OSD 菜单里的 HDR 模式。"];
    } else if (!want) {
        // 关掉 HDR 后：撤掉软件调暗层，亮度控制交回 DDC 硬件通路
        ndClearSoftwareDim(did);
    }
    [self refreshNow];
}

- (void)onOpenSettings:(id)sender {
    if (!self.settingsWindow) [self buildSettingsWindow];
    [self updateStatusLabel];
    [self.settingsWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)buildSettingsWindow {
    NSRect frame = NSMakeRect(0, 0, 580, 520);
    NSWindow *w = [[NSWindow alloc] initWithContentRect:frame
                                             styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    w.title = @"NiceDisplay 设置";
    w.delegate = self;
    // 【必须】关掉"关闭即释放"：否则用户关闭设置窗口后对象被释放，
    // 但 self.settingsWindow 仍指向它 → 再点"设置…"就发消息给野指针，
    // 表现正是"设置偶尔打不开"。
    w.releasedWhenClosed = NO;
    [w center];
    self.settingsWindow = w;

    NSTabView *tv = [[NSTabView alloc] initWithFrame:NSMakeRect(12, 12, 556, 496)];
    self.tabView = tv;
    [w.contentView addSubview:tv];

    self.hkFields = [NSMutableDictionary dictionary];
    self.optFields = [NSMutableDictionary dictionary];
    self.showChecks = [NSMutableDictionary dictionary];

    // ---- 常规 ----
    NSTabViewItem *t1 = [[NSTabViewItem alloc] initWithIdentifier:@"general"];
    t1.label = @"常规";
    NSView *v1 = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 540, 460)];
    [v1 addSubview:[self label:@"状态" frame:NSMakeRect(20, 424, 200, 18) bold:YES]];
    self.statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 280, 500, 138)];
    self.statusLabel.bezeled = NO; self.statusLabel.editable = NO; self.statusLabel.drawsBackground = NO;
    self.statusLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.statusLabel.stringValue = @"读取中…";
    [v1 addSubview:self.statusLabel];

    self.mediaKeyCheck = [NSButton checkboxWithTitle:@"接管妙控键盘原生亮度 / 音量键（推荐开启）"
                                              target:self action:@selector(onToggleMediaKeys:)];
    self.mediaKeyCheck.frame = NSMakeRect(20, 248, 400, 22);
    self.mediaKeyCheck.state = [gConf[@"mediaKeys"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    [v1 addSubview:self.mediaKeyCheck];

    self.loginCheck = [NSButton checkboxWithTitle:@"开机自动启动" target:self action:@selector(onToggleLogin:)];
    self.loginCheck.frame = NSMakeRect(20, 222, 160, 22);
    self.loginCheck.state = [gConf[@"launchAtLogin"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    [v1 addSubview:self.loginCheck];

    self.brightMouseCheck = [NSButton checkboxWithTitle:@"亮度跟随鼠标所在屏幕（不勾则只调主屏）"
                                                 target:self action:@selector(onToggleBrightMouse:)];
    self.brightMouseCheck.frame = NSMakeRect(200, 222, 330, 22);
    self.brightMouseCheck.state = [gConf[@"brightnessTarget"] isEqualToString:@"mouse"] ? NSControlStateValueOn : NSControlStateValueOff;
    [v1 addSubview:self.brightMouseCheck];

    // 布局快照 / 应急恢复 已移到「高级」页（用户要求常规页保持简洁）
    [v1 addSubview:[self label:@"更多设置见「高级」页；菜单显示项可在「菜单显示项」页调整。"
                        frame:NSMakeRect(20, 180, 500, 18) bold:NO]];
    [v1 addSubview:[self label:[NSString stringWithFormat:@"当前版本 v%@ · 开发者 %@", APP_VERSION, APP_AUTHOR]
                        frame:NSMakeRect(20, 118, 500, 18) bold:NO]];
    t1.view = v1;
    [tv addTabViewItem:t1];

    // ---- 菜单显示项 ----
    NSTabViewItem *t2 = [[NSTabViewItem alloc] initWithIdentifier:@"menu"];
    t2.label = @"菜单显示项";
    NSView *v2 = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 540, 460)];
    [v2 addSubview:[self label:@"勾选要在菜单里出现的控制项" frame:NSMakeRect(20, 416, 300, 18) bold:YES]];
    NSArray *showKeys = @[@"showBrightness", @"showVolume", @"showResolution", @"showRate", @"showHiDPI", @"showOSD"];
    NSArray *showTitles = @[@"亮度滑块", @"音量滑块", @"分辨率子菜单", @"刷新率子菜单", @"高分辨率 (HiDPI)", @"调节动画 OSD 浮层（异常可关）"];
    for (NSUInteger i = 0; i < showKeys.count; i++) {
        NSButton *c = [NSButton checkboxWithTitle:showTitles[i] target:nil action:nil];
        c.frame = NSMakeRect(20, 378 - (NSInteger)i * 30, 300, 22);
        c.state = [gConf[showKeys[i]] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
        [v2 addSubview:c];
        self.showChecks[showKeys[i]] = c;
    }
    t2.view = v2;
    [tv addTabViewItem:t2];

    // ---- 高级：步长 / 配置文件 / 屏幕旋转说明 ----
    // （"快捷键"页已按用户要求移除——那些全局热键用不上，键位也不再需要配置）
    NSTabViewItem *t4 = [[NSTabViewItem alloc] initWithIdentifier:@"advanced"];
    t4.label = @"高级";
    NSView *v4 = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 540, 460)];

    [v4 addSubview:[self label:@"每次按键的增减幅度" frame:NSMakeRect(20, 432, 300, 18) bold:YES]];
    [v4 addSubview:[self label:@"亮度" frame:NSMakeRect(20, 404, 60, 18) bold:NO]];
    NSTextField *sb = [[NSTextField alloc] initWithFrame:NSMakeRect(80, 401, 60, 22)];
    sb.stringValue = gConf[@"stepBrightness"];
    [v4 addSubview:sb];
    self.optFields[@"stepBrightness"] = sb;
    [v4 addSubview:[self label:@"%(亮度)" frame:NSMakeRect(146, 404, 80, 18) bold:NO]];
    [v4 addSubview:[self label:@"音量" frame:NSMakeRect(240, 404, 60, 18) bold:NO]];
    NSTextField *sv = [[NSTextField alloc] initWithFrame:NSMakeRect(300, 401, 60, 22)];
    sv.stringValue = gConf[@"stepVolume"];
    [v4 addSubview:sv];
    self.optFields[@"stepVolume"] = sv;
    [v4 addSubview:[self label:@"%(音量)" frame:NSMakeRect(366, 404, 80, 18) bold:NO]];

    NSButton *save = [NSButton buttonWithTitle:@"保存并重新加载" target:self action:@selector(onSaveSettings:)];
    save.frame = NSMakeRect(20, 366, 160, 26);
    [v4 addSubview:save];
    NSButton *open = [NSButton buttonWithTitle:@"打开配置文件" target:self action:@selector(onOpenConf:)];
    open.frame = NSMakeRect(190, 366, 140, 26);
    [v4 addSubview:open];

    // ---- 键盘与功能键（直接写入系统设置，用户无需手动打开系统设置）----
    [v4 addSubview:[self label:@"键盘与功能键" frame:NSMakeRect(20, 326, 300, 18) bold:YES]];

    NSButton *stdFn = [NSButton checkboxWithTitle:@"将 F1/F2 作为标准功能键（可直接调节亮度，蓝牙键盘需开关重连）"
                                           target:self action:@selector(onToggleStandardFnKeys:)];
    stdFn.frame = NSMakeRect(20, 296, 480, 22);
    stdFn.state = [self systemStandardFnKeysEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    [v4 addSubview:stdFn];

    NSButton *playKeys = [NSButton checkboxWithTitle:@"F7 / F8 / F9 直按控制播放（上一曲 / 播放暂停 / 下一曲）"
                                              target:self action:@selector(onToggleFnPlayback:)];
    playKeys.frame = NSMakeRect(20, 266, 480, 22);
    playKeys.state = [gConf[@"fnPlaybackKeys"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    [v4 addSubview:playKeys];



    // ---- 布局快照 / 应急恢复（从「常规」页移过来，用户要求常规页保持简洁）----
    [v4 addSubview:[self label:@"布局快照" frame:NSMakeRect(20, 226, 200, 18) bold:YES]];
    NSButton *bSnap = [NSButton buttonWithTitle:@"保存当前布局快照" target:self action:@selector(onLayoutSave:)];
    bSnap.frame = NSMakeRect(20, 192, 170, 26);
    [v4 addSubview:bSnap];
    NSButton *bRestore = [NSButton buttonWithTitle:@"按快照还原布局" target:self action:@selector(onLayoutRestore:)];
    bRestore.frame = NSMakeRect(200, 192, 170, 26);
    [v4 addSubview:bRestore];

    [v4 addSubview:[self label:@"应急恢复" frame:NSMakeRect(20, 152, 200, 18) bold:YES]];
    NSButton *bAll = [NSButton buttonWithTitle:@"连回所有显示器" target:self action:@selector(onRestoreAll:)];
    bAll.frame = NSMakeRect(20, 118, 160, 26);
    [v4 addSubview:bAll];

    t4.view = v4;
    [tv addTabViewItem:t4];
}

- (void)onToggleMediaKeys:(NSButton *)sender {
    gConf[@"mediaKeys"] = sender.state == NSControlStateValueOn ? @"1" : @"0";
    SaveConf();
    [self installMediaKeyMonitor];
}

// 亮度是否跟随鼠标所在屏
- (void)onToggleBrightMouse:(NSButton *)sender {
    gConf[@"brightnessTarget"] = (sender.state == NSControlStateValueOn) ? @"mouse" : @"main";
    SaveConf();
}

- (void)onToggleLogin:(NSButton *)sender {
    gConf[@"launchAtLogin"] = sender.state == NSControlStateValueOn ? @"1" : @"0";
    SaveConf();
    [self applyLaunchAgent];
}

- (void)applyLaunchAgent {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    // 清掉旧的 LaunchAgent（pro.dlite.app.plist），避免重复自启
    NSString *oldPlist = [dir stringByAppendingPathComponent:@"pro.dlite.app.plist"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:oldPlist]) {
        NSTask *ut = [[NSTask alloc] init];
        ut.launchPath = @"/bin/launchctl";
        ut.arguments = @[@"unload", oldPlist];
        @try { [ut launch]; [ut waitUntilExit]; } @catch (NSException *e) {}
        [[NSFileManager defaultManager] removeItemAtPath:oldPlist error:NULL];
    }
    NSString *plist = [dir stringByAppendingPathComponent:@"pro.dlite.app.plist"];
    if ([gConf[@"launchAtLogin"] boolValue]) {
        NSString *exe = [[NSBundle mainBundle] executablePath];
        NSString *xml = [NSString stringWithFormat:
            @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
            "<plist version=\"1.0\"><dict>\n"
            "<key>Label</key><string>pro.dlite.app</string>\n"
            "<key>ProgramArguments</key><array><string>%@</string></array>\n"
            "<key>RunAtLoad</key><true/>\n"
            "<key>KeepAlive</key><false/>\n"
            "</dict></plist>\n", exe ? exe : @""];
        [xml writeToFile:plist atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        RunCLI(@[@"noop"]);
        NSTask *t = [[NSTask alloc] init];
        t.launchPath = @"/bin/launchctl";
        t.arguments = @[@"load", plist];
        @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) {}
    } else {
        NSTask *t = [[NSTask alloc] init];
        t.launchPath = @"/bin/launchctl";
        t.arguments = @[@"unload", plist];
        @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) {}
        [[NSFileManager defaultManager] removeItemAtPath:plist error:NULL];
    }
}

- (void)onOpenConf:(id)sender {
    if (![[NSFileManager defaultManager] fileExistsAtPath:ConfPath()]) SaveConf();
    [[NSWorkspace sharedWorkspace] openFile:ConfPath() withApplication:@"TextEdit"];
}

// F7/F8/F9 直按控制播放（转发为系统媒体事件）；关闭后这几个键原样交给前端应用
- (void)onToggleFnPlayback:(NSButton *)sender {
    gConf[@"fnPlaybackKeys"] = (sender.state == NSControlStateValueOn) ? @"1" : @"0";
    SaveConf();
    NDLog(@"[conf] F7~F9 播放控制转发 = %@", gConf[@"fnPlaybackKeys"]);
}

#pragma mark - 直接读写系统键盘设置（免去用户手动去系统设置）
// 【重要】用 CFPreferences API 直接读写，不要调 /usr/bin/defaults 子进程、更不要 killall cfprefsd：
// 前者会阻塞主线程（界面点击后卡住/转圈），后者会让全系统偏好读写短暂失效。

static id NDReadPref(NSString *domain, NSString *key) {
    CFStringRef k = (__bridge CFStringRef)key;
    CFPropertyListRef v = NULL;
    if ([domain isEqualToString:@"-g"])
        v = CFPreferencesCopyValue(k, kCFPreferencesAnyApplication,
                                   kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    else
        v = CFPreferencesCopyValue(k, (__bridge CFStringRef)domain,
                                   kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    return v ? (__bridge_transfer id)v : nil;
}

static void NDWritePref(NSString *domain, NSString *key, id value) {
    CFStringRef k = (__bridge CFStringRef)key;
    CFStringRef d = [domain isEqualToString:@"-g"] ? kCFPreferencesAnyApplication
                                                   : (__bridge CFStringRef)domain;
    CFPreferencesSetValue(k, (__bridge CFPropertyListRef)value, d,
                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesAppSynchronize(d);
}

// 系统当前是否已开启"将 F1、F2 等键用作标准功能键"（该键在全局域）
- (BOOL)systemStandardFnKeysEnabled {
    id v = NDReadPref(@"-g", @"com.apple.keyboard.fnState");
    if (!v) v = NDReadPref(@"com.apple.HIToolbox", @"com.apple.keyboard.fnState");
    return v ? ([v intValue] != 0) : NO;
}

// 勾选/取消"将 F1、F2 等键用作标准功能键"（两个域都写，确保系统与设置界面都同步）
- (void)onToggleStandardFnKeys:(NSButton *)sender {
    BOOL on = (sender.state == NSControlStateValueOn);
    NDWritePref(@"-g", @"com.apple.keyboard.fnState", @(on));
    NDWritePref(@"com.apple.HIToolbox", @"com.apple.keyboard.fnState", @(on));
    NDLog(@"[syspref] 标准功能键 = %d（已写入全局域 + HIToolbox 域）", on);
}


- (void)onSaveSettings:(id)sender {
    for (NSString *k in self.hkFields) gConf[k] = ((NSTextField *)self.hkFields[k]).stringValue;
    for (NSString *k in self.optFields) gConf[k] = ((NSTextField *)self.optFields[k]).stringValue;
    for (NSString *k in self.showChecks) gConf[k] = (((NSButton *)self.showChecks[k]).state == NSControlStateValueOn) ? @"1" : @"0";
    SaveConf();
    [self registerHotkeys];
    for (NSValue *v in self.hotKeyRefs) { (void)v; }
    [self alert:@"已保存" text:[NSString stringWithFormat:@"配置已写入\n%@\n\n快捷键已重新注册（共 %lu 个生效）。", ConfPath(), (unsigned long)self.hotKeyRefs.count]];
    [self refreshAsync];
}

- (void)onResetHotkeys:(id)sender {
    NSDictionary *def = DefaultConf();
    NSArray *keys = HotkeyKeys();
    for (NSString *k in keys) {
        ((NSTextField *)self.hkFields[k]).stringValue = def[k];
    }
}

@end

// ============================ 入口 ============================
static OSStatus HotkeyHandler(EventHandlerCallRef nextRef, EventRef ev, void *ctx) {
    AppDelegate *self = (__bridge AppDelegate *)ctx;
    EventHotKeyID hid;
    if (GetEventParameter(ev, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof hid, NULL, &hid) != noErr)
        return noErr;
    BOOL pressed = (GetEventKind(ev) == kEventHotKeyPressed);
    [self handleHotkeyID:hid.id pressed:pressed];
    return noErr;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *d = [[AppDelegate alloc] init];
        app.delegate = d;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}

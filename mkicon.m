// mkicon.m — 生成 Metro 风格显示器图标（扁平、纯色几何），输出 10 个 PNG 到 iconset 目录
// 设计：微软蓝 (#0078D4) 圆角方块 tile + 白色显示器 + 屏内蓝色太阳（暗示亮度控制）
// 编译: clang -O2 -fobjc-arc -o mkicon mkicon.m -framework ApplicationServices
#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>

static void drawIcon(CGContextRef c, CGFloat S) {
    // 背景圆角 tile
    CGFloat r = S * 0.18;
    CGPathRef bg = CGPathCreateWithRoundedRect(CGRectMake(0, 0, S, S), r, r, NULL);
    CGContextSetRGBFillColor(c, 0.0, 0.47, 0.83, 1.0);   // #0078D4 微软蓝
    CGContextAddPath(c, bg);
    CGContextFillPath(c);
    CGPathRelease(bg);

    // 白色显示器：屏幕（整体下移 8%，使"屏幕+支架"这一组在画布内垂直居中）
    CGFloat oy = S * 0.08;   // 垂直居中偏移（原来重心偏上）
    CGFloat mx = S * 0.20, my = S * 0.16 + oy, mw = S * 0.60, mh = S * 0.42, mr = S * 0.05;
    CGPathRef scr = CGPathCreateWithRoundedRect(CGRectMake(mx, my, mw, mh), mr, mr, NULL);
    CGContextSetRGBFillColor(c, 1, 1, 1, 1);
    CGContextAddPath(c, scr);
    CGContextFillPath(c);
    CGPathRelease(scr);

    // 支架颈
    CGContextFillRect(c, CGRectMake(S * 0.45, S * 0.56 + oy, S * 0.10, S * 0.10));
    // 底座
    CGFloat bw = S * 0.30, bh = S * 0.04;
    CGPathRef base = CGPathCreateWithRoundedRect(CGRectMake(S * 0.35, S * 0.64 + oy, bw, bh), bh / 2, bh / 2, NULL);
    CGContextAddPath(c, base);
    CGContextFillPath(c);
    CGPathRelease(base);

    // 屏内太阳（蓝色圆 + 8 条光线）提示亮度控制
    CGFloat cx = S * 0.42, cy = S * 0.37 + oy, cr = S * 0.08;
    CGContextSetRGBFillColor(c, 0.0, 0.47, 0.83, 1.0);
    CGContextFillEllipseInRect(c, CGRectMake(cx - cr, cy - cr, cr * 2, cr * 2));
    CGContextSetLineWidth(c, S * 0.022);
    CGContextSetRGBStrokeColor(c, 0.0, 0.47, 0.83, 1.0);
    for (int i = 0; i < 8; i++) {
        CGFloat a = i * M_PI / 4;
        CGFloat r1 = cr * 1.35, r2 = cr * 1.9;
        CGContextMoveToPoint(c, cx + cos(a) * r1, cy + sin(a) * r1);
        CGContextAddLineToPoint(c, cx + cos(a) * r2, cy + sin(a) * r2);
    }
    CGContextStrokePath(c);
}

static CGContextRef createCtx(int S) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(NULL, S, S, 8, S * 4, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    CGContextTranslateCTM(c, 0, S);   // 翻转 Y，使坐标以左上角为原点
    CGContextScaleCTM(c, 1, -1);
    return c;
}

static void savePNG(CGImageRef im, NSString *path) {
    NSURL *u = [NSURL fileURLWithPath:path];
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)u, kUTTypePNG, 1, NULL);
    if (dst) {
        CGImageDestinationAddImage(dst, im, NULL);
        CGImageDestinationFinalize(dst);
        CFRelease(dst);
    }
}

static void makeAtSize(int S, NSString *path) {
    CGContextRef c = createCtx(S);
    drawIcon(c, S);
    CGImageRef im = CGBitmapContextCreateImage(c);
    savePNG(im, path);
    CGImageRelease(im);
    CGContextRelease(c);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: mkicon <iconset_dir>\n"); return 2; }
        NSString *dir = [NSString stringWithUTF8String:argv[1]];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        // 标准 iconset 命名（iconutil 需要）
        makeAtSize(16,  [dir stringByAppendingPathComponent:@"icon_16x16.png"]);
        makeAtSize(32,  [dir stringByAppendingPathComponent:@"icon_16x16@2x.png"]);
        makeAtSize(32,  [dir stringByAppendingPathComponent:@"icon_32x32.png"]);
        makeAtSize(64,  [dir stringByAppendingPathComponent:@"icon_32x32@2x.png"]);
        makeAtSize(128, [dir stringByAppendingPathComponent:@"icon_128x128.png"]);
        makeAtSize(256, [dir stringByAppendingPathComponent:@"icon_128x128@2x.png"]);
        makeAtSize(256, [dir stringByAppendingPathComponent:@"icon_256x256.png"]);
        makeAtSize(512, [dir stringByAppendingPathComponent:@"icon_256x256@2x.png"]);
        makeAtSize(512, [dir stringByAppendingPathComponent:@"icon_512x512.png"]);
        makeAtSize(1024,[dir stringByAppendingPathComponent:@"icon_512x512@2x.png"]);
        printf("iconset 已生成: %s\n", dir.UTF8String);
    }
    return 0;
}

// Renders the app icon into an .iconset directory (see `make icon`): a question mark whose curve
// is a usage meter, partly filled, on a softly lit tile.

#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>

#include <cmath>
#include <cstdio>
#include <string>

namespace {

struct RGB {
    double r, g, b;
};

constexpr RGB hex(int rgb) {
    return {((rgb >> 16) & 255) / 255.0, ((rgb >> 8) & 255) / 255.0, (rgb & 255) / 255.0};
}

// Night blue tile; the meter's filled part runs from cyan to the system blue.
constexpr RGB kTileTop = hex(0x2B3A57), kTileBottom = hex(0x111827);
constexpr RGB kUsedStart = hex(0x64D2FF), kUsedEnd = hex(0x0A84FF);
constexpr RGB kWhite = hex(0xFFFFFF);

CGColorRef color(RGB c, double alpha = 1) {
    return CGColorCreateSRGB(c.r, c.g, c.b, alpha);
}

void fillPath(CGContextRef g, CGPathRef path, RGB c, double alpha = 1) {
    CGColorRef fill = color(c, alpha);
    CGContextAddPath(g, path);
    CGContextSetFillColorWithColor(g, fill);
    CGContextFillPath(g);
    CGColorRelease(fill);
}

void gradientIn(CGContextRef g, CGColorSpaceRef space, CGPathRef clip, RGB a, RGB b, CGPoint from, CGPoint to,
                double alphaA = 1, double alphaB = 1) {
    CGContextSaveGState(g);
    CGContextAddPath(g, clip);
    CGContextClip(g);
    const CGFloat stops[] = {CGFloat(a.r), CGFloat(a.g), CGFloat(a.b), CGFloat(alphaA),
                             CGFloat(b.r), CGFloat(b.g), CGFloat(b.b), CGFloat(alphaB)};
    CGGradientRef gradient = CGGradientCreateWithColorComponents(space, stops, nullptr, 2);
    CGContextDrawLinearGradient(g, gradient, from, to, kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(gradient);
    CGContextRestoreGState(g);
}

CGPathRef stroked(CGPathRef path, double width) {
    return CGPathCreateCopyByStrokingPath(path, nullptr, width, kCGLineCapRound, kCGLineJoinRound, 0);
}

double rad(double degrees) {
    return degrees * M_PI / 180;
}

void render(int pixels, const std::string& file) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef g = CGBitmapContextCreate(nullptr, pixels, pixels, 8, 0, space, kCGImageAlphaPremultipliedLast);
    CGContextScaleCTM(g, pixels / 1024.0, pixels / 1024.0);

    // macOS icon grid: an 824pt rounded square centred in a 1024pt canvas, lit from above, with a
    // faint glass rim along its upper edge.
    CGPathRef tile = CGPathCreateWithRoundedRect(CGRectMake(100, 100, 824, 824), 185, 185, nullptr);
    gradientIn(g, space, tile, kTileTop, kTileBottom, CGPointMake(0, 924), CGPointMake(0, 100));
    CGPathRef rimPath = CGPathCreateWithRoundedRect(CGRectMake(103, 103, 818, 818), 182, 182, nullptr);
    CGPathRef rim = CGPathCreateCopyByStrokingPath(rimPath, nullptr, 6, kCGLineCapRound, kCGLineJoinRound, 0);
    gradientIn(g, space, rim, kWhite, kWhite, CGPointMake(0, 924), CGPointMake(0, 520), 0.22, 0);

    // The question mark: a hook (the meter), a short stem and a dot. y grows upwards here.
    const double cx = 512, cy = 598, r = 150, width = 100;
    const double usedTo = 8;  // the filled part runs from the hook's start over the top to here
    CGMutablePathRef whole = CGPathCreateMutable();
    CGPathAddArc(whole, nullptr, cx, cy, r, rad(198), rad(-38), true);
    const CGPoint end = CGPathGetCurrentPoint(whole);
    CGPathAddQuadCurveToPoint(whole, nullptr, cx + 6, end.y - 40, cx, 430);
    CGPathAddLineToPoint(whole, nullptr, cx, 410);
    CGPathRef track = stroked(whole, width);
    CGContextSaveGState(g);  // a soft shadow lifts the whole mark off the tile
    CGColorRef shadow = CGColorCreateSRGB(0, 0, 0, 0.35);
    CGContextSetShadowWithColor(g, CGSizeMake(0, -10), 22, shadow);
    CGColorRelease(shadow);
    CGContextBeginTransparencyLayer(g, nullptr);
    fillPath(g, track, kWhite, 0.16);

    CGMutablePathRef used = CGPathCreateMutable();
    CGPathAddArc(used, nullptr, cx, cy, r, rad(198), rad(usedTo), true);
    CGPathRef usedStroke = stroked(used, width);
    gradientIn(g, space, usedStroke, kUsedStart, kUsedEnd, CGPointMake(cx - r, cy - r / 2), CGPointMake(cx + r, cy + r));

    CGPathRef dot = CGPathCreateWithEllipseInRect(CGRectMake(cx - 56, 246, 112, 112), nullptr);
    fillPath(g, dot, kWhite);
    CGContextEndTransparencyLayer(g);
    CGContextRestoreGState(g);

    CGImageRef image = CGBitmapContextCreateImage(g);
    CFStringRef path = CFStringCreateWithCString(nullptr, file.c_str(), kCFStringEncodingUTF8);
    CFURLRef url = CFURLCreateWithFileSystemPath(nullptr, path, kCFURLPOSIXPathStyle, false);
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, nullptr);
    CGImageDestinationAddImage(dest, image, nullptr);
    CGImageDestinationFinalize(dest);

    CFRelease(dest);
    CFRelease(url);
    CFRelease(path);
    CGImageRelease(image);
    CGPathRelease(dot);
    CGPathRelease(usedStroke);
    CGPathRelease(used);
    CGPathRelease(track);
    CGPathRelease(whole);
    CGPathRelease(rim);
    CGPathRelease(rimPath);
    CGPathRelease(tile);
    CGContextRelease(g);
    CGColorSpaceRelease(space);
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: icon <dir.iconset>\n");
        return 1;
    }
    const std::string dir = argv[1];
    // Up to 256pt@2x: Finder scales larger sizes, and the app stays small. macOS picks images by
    // pixel size, so 16pt@2x and 256pt@1x come from 32pt@1x and 128pt@2x.
    const struct { int points, scale; } sizes[] = {{16, 1}, {32, 1}, {32, 2}, {128, 1}, {128, 2}, {256, 2}};
    for (const auto& size : sizes) {
        char name[64];
        snprintf(name, sizeof(name), "/icon_%dx%d%s.png", size.points, size.points, size.scale == 2 ? "@2x" : "");
        render(size.points * size.scale, dir + name);
    }
    return 0;
}

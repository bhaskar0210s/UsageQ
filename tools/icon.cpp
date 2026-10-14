// Renders the app icon into an .iconset directory (see `make icon`): two of the card's
// meters, session above weekly, each with its even-pace tick. Flat colours keep it tiny.

#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>

#include <cstdio>
#include <string>

namespace {

void fill(CGContextRef g, CGPathRef path, int rgb) {
    CGColorRef c = CGColorCreateSRGB(((rgb >> 16) & 255) / 255.0, ((rgb >> 8) & 255) / 255.0, (rgb & 255) / 255.0, 1);
    CGContextAddPath(g, path);
    CGContextSetFillColorWithColor(g, c);
    CGContextFillPath(g);
    CGColorRelease(c);
}

void rounded(CGContextRef g, CGRect r, double radius, int rgb) {
    CGPathRef path = CGPathCreateWithRoundedRect(r, radius, radius, nullptr);
    fill(g, path, rgb);
    CGPathRelease(path);
}

// A meter: grey track, blue used part, dark even-pace tick standing above and below it.
void meter(CGContextRef g, double y, double used, double pace) {
    const double left = 222, width = 580, height = 132;
    rounded(g, CGRectMake(left, y, width, height), height / 2, 0xDCDFE5);
    rounded(g, CGRectMake(left, y, width * used, height), height / 2, 0x0A84FF);
    rounded(g, CGRectMake(left + width * pace - 9, y - 26, 18, height + 52), 9, 0x1C1C1E);
}

void render(int pixels, const std::string& file) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef g = CGBitmapContextCreate(nullptr, pixels, pixels, 8, 0, space, kCGImageAlphaPremultipliedLast);
    CGContextScaleCTM(g, pixels / 1024.0, pixels / 1024.0);

    // macOS icon grid: an 824pt rounded square centred in a 1024pt canvas, with a fine edge so it
    // holds its shape on white.
    rounded(g, CGRectMake(100, 100, 824, 824), 185, 0xD5D8DE);
    rounded(g, CGRectMake(104, 104, 816, 816), 181, 0xF6F7F9);
    meter(g, 548, 0.64, 0.50);  // session
    meter(g, 344, 0.38, 0.56);  // weekly

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

// TokenTank: how much Claude is left in the tank, in the menu bar.
// The data layer is plain C++ (src/core); this file is the thin AppKit shell around it.
#import <AppKit/AppKit.h>
#import <ServiceManagement/ServiceManagement.h>

#include <malloc/malloc.h>

#include <algorithm>
#include <cmath>
#include <vector>

#include "../core/engine.hpp"
#include "../core/format.hpp"
#include "../core/util.hpp"

#ifdef TT_DEV
#include <mach/mach.h>
static double FootprintMB() {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, task_info_t(&info), &count) != KERN_SUCCESS) return 0;
    return double(info.phys_footprint) / (1024.0 * 1024.0);
}
#endif

static const CGFloat kCardWidth = 320;
static const CGFloat kPad = 14;
static const CGFloat kChartHeight = 46;
static NSString* const kRefreshMinutesKey = @"refreshMinutes";
static NSString* const kLoginConfiguredKey = @"loginItemConfigured";

// MARK: - Drawing helpers

static NSString* NS(const std::string& s) {
    return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @"";
}

static NSColor* SRGB(uint32_t rgb, CGFloat alpha = 1) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xFF) / 255.0
                               green:((rgb >> 8) & 0xFF) / 255.0
                                blue:(rgb & 0xFF) / 255.0
                               alpha:alpha];
}

// Light/dark pair resolved at draw time (validated categorical slots 1 and 2).
static NSColor* DynamicColor(uint32_t light, uint32_t dark, CGFloat alpha = 1) {
    return [NSColor colorWithName:nil
                  dynamicProvider:^NSColor*(NSAppearance* appearance) {
                      NSAppearanceName match = [appearance
                          bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];
                      return SRGB([match isEqualToString:NSAppearanceNameDarkAqua] ? dark : light, alpha);
                  }];
}

static NSDictionary* TextStyle(NSFont* font, NSColor* color, CGFloat kern = 0) {
    if (kern == 0) return @{NSFontAttributeName : font, NSForegroundColorAttributeName : color};
    return @{NSFontAttributeName : font, NSForegroundColorAttributeName : color, NSKernAttributeName : @(kern)};
}

static CGFloat TextWidth(NSString* s, NSDictionary* style) {
    return ceil([s sizeWithAttributes:style].width);
}

// Draws `s` left-aligned, truncating at `maxWidth`. Returns the width used.
static CGFloat DrawLeft(NSString* s, CGFloat x, CGFloat y, NSDictionary* style, CGFloat maxWidth) {
    if (maxWidth <= 4 || s.length == 0) return 0;
    const NSSize size = [s sizeWithAttributes:style];
    if (size.width <= maxWidth) {
        [s drawAtPoint:NSMakePoint(x, y) withAttributes:style];
        return size.width;
    }
    NSMutableParagraphStyle* p = [NSMutableParagraphStyle new];
    p.lineBreakMode = NSLineBreakByTruncatingTail;
    NSMutableDictionary* truncating = [style mutableCopy];
    truncating[NSParagraphStyleAttributeName] = p;
    [s drawInRect:NSMakeRect(x, y, maxWidth, size.height) withAttributes:truncating];
    return maxWidth;
}

static void DrawRight(NSString* s, CGFloat right, CGFloat y, NSDictionary* style, CGFloat maxWidth) {
    if (maxWidth <= 4 || s.length == 0) return;
    const NSSize size = [s sizeWithAttributes:style];
    if (size.width <= maxWidth) {
        [s drawAtPoint:NSMakePoint(right - size.width, y) withAttributes:style];
        return;
    }
    NSMutableParagraphStyle* p = [NSMutableParagraphStyle new];
    p.lineBreakMode = NSLineBreakByTruncatingMiddle;
    p.alignment = NSTextAlignmentRight;
    NSMutableDictionary* truncating = [style mutableCopy];
    truncating[NSParagraphStyleAttributeName] = p;
    [s drawInRect:NSMakeRect(right - maxWidth, y, maxWidth, size.height) withAttributes:truncating];
}

// Draws the first candidate that fits `maxWidth`, centered on `cx` (truncating the last one).
static void DrawCentered(NSArray<NSString*>* candidates, CGFloat cx, CGFloat y, NSDictionary* style, CGFloat maxWidth) {
    for (NSString* s in candidates) {
        const CGFloat w = TextWidth(s, style);
        if (w <= maxWidth || s == candidates.lastObject) {
            const CGFloat drawn = MIN(w, maxWidth);
            DrawLeft(s, round(cx - drawn / 2), y, style, maxWidth);
            return;
        }
    }
}

// Upward bar: rounded at the data end, square on the baseline.
static void FillBar(NSRect r, CGFloat radius) {
    if (r.size.height <= 0 || r.size.width <= 0) return;
    radius = MIN(radius, r.size.width / 2);
    NSRect extended = r;
    extended.size.height += radius;  // past the baseline, then clipped off
    [NSGraphicsContext saveGraphicsState];
    NSRectClip(r);
    [[NSBezierPath bezierPathWithRoundedRect:extended xRadius:radius yRadius:radius] fill];
    [NSGraphicsContext restoreGraphicsState];
}

// Clock time in the user's locale and 12/24-hour setting: "5:30 PM" today, "Fri 5:30 PM" later.
static NSString* ClockTime(int64_t t, int64_t now) {
    static NSDateFormatter *time, *dayAndTime;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        time = [NSDateFormatter new];
        [time setLocalizedDateFormatFromTemplate:@"jmm"];
        dayAndTime = [NSDateFormatter new];
        [dayAndTime setLocalizedDateFormatFromTemplate:@"EEEjmm"];
    });
    NSDate* date = [NSDate dateWithTimeIntervalSince1970:double(t)];
    return [(tt::localMidnight(t) == tt::localMidnight(now) ? time : dayAndTime) stringFromDate:date];
}

// MARK: - Limit state

// Fixed status palette. Every use is paired with a glyph and words, never color alone.
enum class Level { Good, Warning, Critical, Neutral };

static NSColor* LevelColor(Level level) {
    switch (level) {
        case Level::Good: return SRGB(0x0ca30c);
        case Level::Warning: return SRGB(0xfab219);
        case Level::Critical: return SRGB(0xd03b3b);
        case Level::Neutral: return NSColor.secondaryLabelColor;
    }
    return NSColor.secondaryLabelColor;
}

static int Severity(Level level) {
    return level == Level::Critical ? 2 : level == Level::Warning ? 1 : 0;
}

// Check, exclamation, cross or "i" on a filled shape.
static void DrawGlyph(Level level, NSRect r) {
    NSColor* color = LevelColor(level);
    [color set];
    if (level == Level::Warning) {
        NSBezierPath* t = [NSBezierPath bezierPath];
        [t moveToPoint:NSMakePoint(NSMidX(r), NSMinY(r) + r.size.height * 0.06)];
        [t lineToPoint:NSMakePoint(NSMaxX(r) - r.size.width * 0.04, NSMaxY(r) - r.size.height * 0.08)];
        [t lineToPoint:NSMakePoint(NSMinX(r) + r.size.width * 0.04, NSMaxY(r) - r.size.height * 0.08)];
        [t closePath];
        t.lineJoinStyle = NSLineJoinStyleRound;
        t.lineWidth = r.size.width * 0.16;
        [t fill];
        [t stroke];
    } else {
        [[NSBezierPath bezierPathWithOvalInRect:r] fill];
    }
    const CGFloat x = r.origin.x, y = r.origin.y, w = r.size.width, h = r.size.height;
    NSColor* mark = level == Level::Warning ? [NSColor colorWithWhite:0 alpha:0.78] : NSColor.whiteColor;
    [mark set];
    NSBezierPath* m = [NSBezierPath bezierPath];
    m.lineWidth = MAX(1.1, w * 0.13);
    m.lineCapStyle = NSLineCapStyleRound;
    m.lineJoinStyle = NSLineJoinStyleRound;
    const CGFloat dot = MAX(0.7, w * 0.075);
    switch (level) {
        case Level::Good:
            [m moveToPoint:NSMakePoint(x + 0.28 * w, y + 0.53 * h)];
            [m lineToPoint:NSMakePoint(x + 0.44 * w, y + 0.68 * h)];
            [m lineToPoint:NSMakePoint(x + 0.73 * w, y + 0.36 * h)];
            [m stroke];
            break;
        case Level::Critical:
            [m moveToPoint:NSMakePoint(x + 0.34 * w, y + 0.34 * h)];
            [m lineToPoint:NSMakePoint(x + 0.66 * w, y + 0.66 * h)];
            [m moveToPoint:NSMakePoint(x + 0.66 * w, y + 0.34 * h)];
            [m lineToPoint:NSMakePoint(x + 0.34 * w, y + 0.66 * h)];
            [m stroke];
            break;
        case Level::Warning:
            [m moveToPoint:NSMakePoint(x + 0.5 * w, y + 0.40 * h)];
            [m lineToPoint:NSMakePoint(x + 0.5 * w, y + 0.62 * h)];
            [m stroke];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x + 0.5 * w - dot, y + 0.76 * h - dot, 2 * dot, 2 * dot)] fill];
            break;
        case Level::Neutral:
            [m moveToPoint:NSMakePoint(x + 0.5 * w, y + 0.46 * h)];
            [m lineToPoint:NSMakePoint(x + 0.5 * w, y + 0.72 * h)];
            [m stroke];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x + 0.5 * w - dot, y + 0.28 * h - dot, 2 * dot, 2 * dot)] fill];
            break;
    }
}

// One limit, ready to show: what is left, how urgent it is, and what to say about it.
struct LimitView {
    tt::LimitWindow window;
    tt::Pace pace;
    double left = 0;  // percent
    Level level = Level::Good;
    NSString* name;                  // "Session", "Fable weekly"
    NSArray<NSString*>* verdicts;    // longest first, e.g. "Dry by Fri 4:10 PM", "Dry Fri 4:10 PM"
    int64_t dryAt = 0;               // when it runs out at the current pace (0 = not before refill)
};

static LimitView MakeLimitView(const tt::LimitWindow& raw, int64_t now) {
    LimitView v;
    v.window = tt::effectiveWindow(raw, now);
    v.pace = tt::computePace(v.window, now);
    v.left = std::clamp(100.0 - v.window.usedPercent, 0.0, 100.0);
    v.name = NS(v.window.title);
    const bool runsDry = v.pace.valid && v.pace.hasEta && !v.pace.lastsToReset;
    if (v.left < 0.5) {
        v.level = Level::Critical;
        v.verdicts = @[ @"Empty" ];
    } else if (runsDry) {
        v.dryAt = now + int64_t(v.pace.etaSeconds);
        v.level = (v.pace.etaSeconds < 1800 || v.left <= 5) ? Level::Critical : Level::Warning;
        NSString* when = ClockTime(v.dryAt, now);
        v.verdicts = @[ [@"Dry by " stringByAppendingString:when], [@"Dry " stringByAppendingString:when], @"Runs dry" ];
    } else if (v.left <= 5) {
        v.level = Level::Critical;
        v.verdicts = @[ @"Almost empty" ];
    } else {
        v.level = Level::Good;
        v.verdicts = v.pace.lastsToReset ? @[ @"Lasts to refill", @"Lasts" ] : @[ @"On track" ];
    }
    return v;
}

// Gauge arc. In this flipped view, 180°..360° runs left (E) over the top to right (F).
static void StrokeArc(NSPoint c, CGFloat r, CGFloat lineWidth, double fromDeg, double toDeg) {
    NSBezierPath* p = [NSBezierPath bezierPath];
    p.lineWidth = lineWidth;
    p.lineCapStyle = NSLineCapStyleRound;
    p.lineJoinStyle = NSLineJoinStyleRound;
    const int steps = std::max(2, int((toDeg - fromDeg) / 3));
    for (int i = 0; i <= steps; ++i) {
        const double a = (fromDeg + (toDeg - fromDeg) * i / steps) * M_PI / 180;
        const NSPoint pt = NSMakePoint(c.x + r * cos(a), c.y + r * sin(a));
        if (i == 0)
            [p moveToPoint:pt];
        else
            [p lineToPoint:pt];
    }
    [p stroke];
}

// Menu bar glyph: a small fuel gauge reading the session's remaining share.
static NSImage* GaugeIcon(double leftFraction) {
    NSImage* image = [NSImage imageWithSize:NSMakeSize(18, 16)
                                    flipped:NO
                             drawingHandler:^BOOL(NSRect) {
                                 const NSPoint c = NSMakePoint(9, 4.5);
                                 const CGFloat r = 6.5;
                                 NSBezierPath* track = [NSBezierPath bezierPath];
                                 [track appendBezierPathWithArcWithCenter:c radius:r startAngle:180 endAngle:0 clockwise:YES];
                                 track.lineWidth = 2.2;
                                 track.lineCapStyle = NSLineCapStyleRound;
                                 [[NSColor colorWithWhite:0 alpha:0.35] setStroke];
                                 [track stroke];
                                 const double f = std::clamp(leftFraction, 0.0, 1.0);
                                 [NSColor.blackColor set];
                                 if (leftFraction >= 0 && f > 0.01) {
                                     NSBezierPath* level = [NSBezierPath bezierPath];
                                     [level appendBezierPathWithArcWithCenter:c
                                                                       radius:r
                                                                   startAngle:180
                                                                     endAngle:180 - 180 * f
                                                                    clockwise:YES];
                                     level.lineWidth = 2.2;
                                     level.lineCapStyle = NSLineCapStyleRound;
                                     [level stroke];
                                 }
                                 const double a = (180 - 180 * (leftFraction >= 0 ? f : 0.5)) * M_PI / 180;
                                 NSBezierPath* needle = [NSBezierPath bezierPath];
                                 [needle moveToPoint:c];
                                 [needle lineToPoint:NSMakePoint(c.x + (r - 2.4) * cos(a), c.y + (r - 2.4) * sin(a))];
                                 needle.lineWidth = 1.5;
                                 needle.lineCapStyle = NSLineCapStyleRound;
                                 [needle stroke];
                                 [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x - 1.4, c.y - 1.4, 2.8, 2.8)] fill];
                                 return YES;
                             }];
    [image setTemplate:YES];  // `template` is a C++ keyword
    return image;
}

// MARK: - Card

@interface TTCardView : NSView
- (void)showSnapshot:(const tt::Snapshot&)snapshot;
- (CGFloat)preferredHeight;
- (void)setHoverDay:(NSInteger)day;
- (void)clearHover;
@end

@implementation TTCardView {
    tt::Snapshot _snap;
    BOOL _hasData;
    NSRect _chartRect;
    NSInteger _hoverDay;
    NSTrackingArea* _tracking;
    NSDictionary *_title, *_body, *_secondary, *_caption, *_head, *_tiny, *_big;
    NSColor *_cost, *_costDim, *_tokens, *_tokensDim;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _hoverDay = -1;
        // Four fonts on purpose: every size/weight pair carries its own glyph caches.
        NSFont* small = [NSFont systemFontOfSize:9.5 weight:NSFontWeightSemibold];
        NSFont* body = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
        NSFont* strong = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold];
        NSFont* big = [NSFont monospacedDigitSystemFontOfSize:16 weight:NSFontWeightSemibold];
        _title = TextStyle(strong, NSColor.labelColor);
        _body = TextStyle(body, NSColor.labelColor);
        _secondary = TextStyle(body, NSColor.secondaryLabelColor);
        _caption = TextStyle(small, NSColor.secondaryLabelColor, 0.5);
        _head = TextStyle(small, NSColor.secondaryLabelColor);
        _tiny = TextStyle(small, NSColor.tertiaryLabelColor);
        _big = TextStyle(big, NSColor.labelColor);
        _cost = DynamicColor(0x2a78d6, 0x3987e5);
        _tokens = DynamicColor(0xeb6834, 0xd95926);
        _costDim = DynamicColor(0x2a78d6, 0x3987e5, 0.35);
        _tokensDim = DynamicColor(0xeb6834, 0xd95926, 0.35);
    }
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

- (void)showSnapshot:(const tt::Snapshot&)snapshot {
    _snap = snapshot;
    _hasData = YES;
    [self setNeedsDisplay:YES];
}

- (CGFloat)preferredHeight {
    return [self layout:NO];
}

- (void)drawRect:(NSRect)dirtyRect {
    [self layout:YES];
}

- (void)divider:(CGFloat)y {
    [NSColor.separatorColor setFill];
    NSRectFillUsingOperation(NSMakeRect(kPad, y, kCardWidth - 2 * kPad, 1), NSCompositingOperationSourceOver);
}

- (int64_t)dayStart:(NSInteger)index {
    return tt::localMidnight(_snap.cost.firstDay + int64_t(index) * 86400 + 43200);
}

// The one-line answer at the top: can I keep going?
- (NSString*)headline:(const std::vector<LimitView>&)limits level:(Level*)level now:(int64_t)now {
    const tt::Snapshot& s = _snap;
    *level = Level::Neutral;
    if (!_hasData) return @"Checking your limits…";
    const bool fresh = s.updatedAt > 0 && now - s.updatedAt < 900;
    if (!s.notice.empty() && (!fresh || limits.empty())) return NS(s.notice);
    if (limits.empty()) return @"Usage limits unavailable";
    const LimitView* worst = nullptr;
    for (const LimitView& v : limits) {
        if (Severity(v.level) == 0) continue;
        if (!worst || Severity(v.level) > Severity(worst->level) ||
            (Severity(v.level) == Severity(worst->level) && v.dryAt && (!worst->dryAt || v.dryAt < worst->dryAt)))
            worst = &v;
    }
    if (!worst) {
        *level = Level::Good;
        return @"All good · nothing runs dry before it refills";
    }
    *level = worst->level;
    if (worst->left < 0.5)
        return worst->window.resetsAt
                   ? [NSString stringWithFormat:@"%@ is empty · refills %@", worst->name,
                                                ClockTime(worst->window.resetsAt, now)]
                   : [NSString stringWithFormat:@"%@ is empty", worst->name];
    if (worst->dryAt)
        return [NSString stringWithFormat:@"%@ runs dry ~%@ at this pace", worst->name, ClockTime(worst->dryAt, now)];
    return [NSString stringWithFormat:@"%@ is almost empty", worst->name];
}

// One limit as a fuel gauge tile. Returns its height.
- (CGFloat)tank:(const LimitView&)v in:(NSRect)tile draw:(BOOL)draw now:(int64_t)now {
    const CGFloat cx = NSMidX(tile), w = tile.size.width;
    CGFloat y = tile.origin.y;
    if (draw) DrawCentered(@[ v.name.uppercaseString ], cx, y, _caption, w);
    y += 16;
    const CGFloat r = MIN(w / 2 - 12, 32), stroke = 7;
    const CGFloat cy = y + r + stroke / 2;
    if (draw) {
        const NSPoint c = NSMakePoint(cx, cy);
        [NSColor.quaternaryLabelColor setStroke];
        StrokeArc(c, r, stroke, 180, 360);
        if (v.left >= 0.5) {
            [LevelColor(v.level) setStroke];
            StrokeArc(c, r, stroke, 180, 180 + 180 * v.left / 100.0);
        }
        DrawCentered(@[ NS(tt::formatPercent(v.left)) ], cx, cy - 20, _big, 2 * r - stroke);
        DrawCentered(@[ @"LEFT" ], cx, cy + 1, _caption, w);
        DrawCentered(@[ @"E" ], cx - r, cy + stroke / 2 + 1, _tiny, 14);
        DrawCentered(@[ @"F" ], cx + r, cy + stroke / 2 + 1, _tiny, 14);
    }
    y = cy + 17;
    if (draw) {
        if (v.window.resetsAt) {
            NSString* when = ClockTime(v.window.resetsAt, now);
            DrawCentered(@[ [@"Refills " stringByAppendingString:when], when ], cx, y, _secondary, w);
        } else {
            DrawCentered(@[ @"Starts with your next prompt", @"Not started" ], cx, y, _secondary, w);
        }
    }
    y += 16;
    if (draw) {  // glyph + verdict, centered together
        NSString* text = v.verdicts.lastObject;
        for (NSString* candidate in v.verdicts)
            if (TextWidth(candidate, _secondary) + 13 <= w) {
                text = candidate;
                break;
            }
        const CGFloat textWidth = MIN(TextWidth(text, _secondary), w - 13);
        const CGFloat x0 = round(cx - (textWidth + 13) / 2);
        DrawGlyph(v.level, NSMakeRect(x0, y + 2.5, 9, 9));
        DrawLeft(text, x0 + 13, y, _secondary, w - 13);
    }
    y += 16;
    return y - tile.origin.y;
}

// Each day gets a cost bar and a token bar side by side, both growing up from one baseline.
// The two series have different units, so each is scaled to its own 30-day peak; the day
// details under the chart carry the actual values.
- (void)drawBars {
    const tt::CostSummary& c = _snap.cost;
    double maxCost = 0;
    uint64_t maxTokens = 0;
    for (const auto& d : c.days) {
        maxCost = MAX(maxCost, d.cost);
        maxTokens = MAX(maxTokens, d.tokens);
    }
    const NSRect r = _chartRect;
    const CGFloat baseline = NSMaxY(r);
    const CGFloat slot = r.size.width / c.days.size();
    const CGFloat barWidth = MAX(1, floor(slot - 3) / 2);  // 1pt inside a pair, >= 2pt between days
    const CGFloat pairWidth = barWidth * 2 + 1;

    [NSColor.quaternaryLabelColor setFill];
    NSRectFillUsingOperation(NSMakeRect(r.origin.x, baseline - 0.5, r.size.width, 0.5), NSCompositingOperationSourceOver);

    for (size_t i = 0; i < c.days.size(); ++i) {
        const CGFloat x = round((r.origin.x + i * slot + (slot - pairWidth) / 2) * 2) / 2;
        const BOOL dim = _hoverDay >= 0 && _hoverDay != NSInteger(i);
        if (maxCost > 0 && c.days[i].cost > 0) {
            const CGFloat h = MAX(1, round(r.size.height * c.days[i].cost / maxCost));
            [(dim ? _costDim : _cost) setFill];
            FillBar(NSMakeRect(x, baseline - h, barWidth, h), 1.5);
        }
        if (maxTokens > 0 && c.days[i].tokens > 0) {
            const CGFloat h = MAX(1, round(r.size.height * double(c.days[i].tokens) / double(maxTokens)));
            [(dim ? _tokensDim : _tokens) setFill];
            FillBar(NSMakeRect(x + barWidth + 1, baseline - h, barWidth, h), 1.5);
        }
    }
}

- (CGFloat)legend:(NSString*)label color:(NSColor*)color right:(CGFloat)right y:(CGFloat)y {
    const CGFloat w = TextWidth(label, _tiny);
    DrawLeft(label, right - w, y, _tiny, w + 1);
    [color setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(right - w - 11, y + 2.5, 7, 7) xRadius:1.5 yRadius:1.5] fill];
    return right - w - 11;
}

// One pass that either measures or draws, so layout and drawing never disagree.
- (CGFloat)layout:(BOOL)draw {
    const CGFloat left = kPad, right = kCardWidth - kPad, width = right - left;
    const int64_t now = tt::nowSeconds();
    const tt::Snapshot& s = _snap;
    CGFloat y = 10;

    // Header: app, plan, account, freshness.
    if (draw) {
        const CGFloat used = DrawLeft(@"TokenTank", left, y, _title, width);
        DrawRight(NS(s.account.plan), right, y + 1.5, _secondary, width - used - 12);
    }
    y += 19;
    if (draw) {
        NSString* updated = !_hasData        ? @""
                            : s.updatedAt ? [@"Updated " stringByAppendingString:NS(tt::formatAgo(now - s.updatedAt))]
                                          : @"Not updated yet";
        const CGFloat w = TextWidth(updated, _secondary);
        DrawRight(updated, right, y, _secondary, width);
        DrawLeft(NS(s.account.email), left, y, _secondary, width - w - 12);
    }
    y += 23;

    // Verdict banner.
    std::vector<LimitView> limits;
    limits.reserve(s.windows.size());
    for (const tt::LimitWindow& w : s.windows) limits.push_back(MakeLimitView(w, now));
    Level level;
    NSString* headline = [self headline:limits level:&level now:now];
    if (draw) {
        const NSRect banner = NSMakeRect(left, y, width, 28);
        [(level == Level::Neutral ? NSColor.quaternaryLabelColor : [LevelColor(level) colorWithAlphaComponent:0.16]) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:banner xRadius:7 yRadius:7] fill];
        DrawGlyph(level, NSMakeRect(left + 8, y + 7, 14, 14));
        DrawLeft(headline, left + 29, y + 6.5, _body, width - 37);
    }
    y += 28 + 14;

    // Tanks: one fuel gauge per limit, up to three in a row.
    if (!limits.empty()) {
        const size_t columns = limits.size() <= 3 ? limits.size() : 2;
        const CGFloat gap = 10;
        const CGFloat tileWidth = floor((width - gap * (columns - 1)) / columns);
        CGFloat rowTop = y, rowHeight = 0;
        for (size_t i = 0; i < limits.size(); ++i) {
            const size_t column = i % columns;
            if (i > 0 && column == 0) {
                rowTop += rowHeight + 12;
                rowHeight = 0;
            }
            const NSRect tile = NSMakeRect(left + column * (tileWidth + gap), rowTop, tileWidth, 0);
            rowHeight = MAX(rowHeight, [self tank:limits[i] in:tile draw:draw now:now]);
        }
        y = rowTop + rowHeight + 8;
    }

    const tt::CostSummary& c = s.cost;
    if (c.valid) {
        // Spend: a row per measure, a column per period.
        if (draw) [self divider:y];
        y += 11;
        const CGFloat labelWidth = 42, columnWidth = (width - labelWidth) / 4;
        NSString* const heads[4] = {@"TODAY", @"THIS WEEK", @"LAST WEEK", @"30 DAYS"};
        const tt::DayUsage periods[4] = {c.today, c.window, c.previousWindow, c.last30};
        const bool known[4] = {true, c.hasWindow, c.hasWindow, true};
        auto columnRight = [&](int i) { return left + labelWidth + columnWidth * (i + 1); };
        if (draw)
            for (int i = 0; i < 4; ++i) DrawRight(heads[i], columnRight(i), y, _head, columnWidth - 2);
        y += 15;
        if (draw) {
            DrawLeft(@"Cost", left, y + 1.5, _secondary, labelWidth);
            for (int i = 0; i < 4; ++i)
                DrawRight(known[i] ? NS(tt::formatUSDShort(periods[i].cost)) : @"—", columnRight(i), y, _title,
                          columnWidth - 4);
        }
        y += 19;
        if (draw) {
            DrawLeft(@"Tokens", left, y, _secondary, labelWidth);
            for (int i = 0; i < 4; ++i)
                DrawRight(known[i] ? NS(tt::formatTokens(double(periods[i].tokens))) : @"—", columnRight(i), y, _body,
                          columnWidth - 4);
        }
        y += 24;

        // History.
        if (draw) {
            DrawLeft(@"LAST 30 DAYS", left, y, _caption, width / 2);
            const CGFloat x = [self legend:@"Tokens" color:_tokens right:right y:y];
            [self legend:@"Cost" color:_cost right:x - 9 y:y];
        }
        y += 17;
        _chartRect = NSMakeRect(left, y, width, kChartHeight);
        if (draw) [self drawBars];
        y += kChartHeight + 3;
        if (draw) {
            DrawLeft(NS(tt::formatShortDate(c.firstDay)), left, y, _tiny, width / 2);
            DrawRight(@"Today", right, y, _tiny, width / 2);
        }
        y += 16;

        // The hovered day (today by default): totals, then its top two models. Fixed height,
        // so hovering never resizes the menu.
        const NSInteger day = _hoverDay >= 0 ? _hoverDay : NSInteger(c.days.size()) - 1;
        const tt::DayUsage& u = c.days[size_t(day)];
        if (draw) {
            NSString* when = day == NSInteger(c.days.size()) - 1 ? @"Today" : NS(tt::formatShortDate([self dayStart:day]));
            const CGFloat used = DrawLeft(when, left, y, _body, width / 2);
            DrawRight([NSString stringWithFormat:@"%@ · %@ tokens", NS(tt::formatUSD(u.cost)),
                                                 NS(tt::formatTokens(double(u.tokens)))],
                      right, y, _body, width - used - 10);
        }
        y += 17;
        const auto& models = c.dayModels[size_t(day)];
        for (size_t k = 0; k < models.size(); ++k) {
            if (draw && !models[k].model.empty()) {
                const CGFloat used = DrawLeft(NS(tt::modelDisplayName(models[k].model)), left + 10, y, _secondary, width / 2);
                DrawRight([NSString stringWithFormat:@"%@ · %@", NS(tt::formatUSD(models[k].cost)),
                                                     NS(tt::formatTokens(double(models[k].tokens)))],
                          right, y, _secondary, width - used - 20);
            } else if (draw && k == 0) {
                DrawLeft(@"No usage this day", left + 10, y, _secondary, width - 10);
            }
            y += 15;
        }
        y += 7;
        if (draw) {
            const CGFloat used = DrawLeft(@"Estimated at API prices from local logs", left, y, _tiny, width);
            if (!c.topModel.empty())
                DrawRight([@"Top: " stringByAppendingString:NS(tt::modelDisplayName(c.topModel))], right, y, _tiny,
                          width - used - 10);
        }
        y += 13;
    }
    return ceil(y + 8);
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
               owner:self
            userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)setHoverDay:(NSInteger)day {
    if (day == _hoverDay) return;
    _hoverDay = day;
    [self setNeedsDisplay:YES];
}

- (void)mouseMoved:(NSEvent*)event {
    if (!_snap.cost.valid) return;
    const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];  // flipped: y grows down
    if (p.y > NSMaxY(_chartRect) + 10) return;  // below the bars: keep the day so its details can be read
    NSInteger day = -1;
    if (NSPointInRect(p, NSInsetRect(_chartRect, -2, -10))) {
        const CGFloat slot = _chartRect.size.width / _snap.cost.days.size();
        day = std::clamp<NSInteger>(NSInteger(floor((p.x - _chartRect.origin.x) / slot)), 0,
                                    NSInteger(_snap.cost.days.size()) - 1);
    }
    [self setHoverDay:day];
}

- (void)mouseExited:(NSEvent*)event {
    [self setHoverDay:-1];
}

- (void)clearHover {
    _hoverDay = -1;
}

@end

// MARK: - App

@interface TTAppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@end

@implementation TTAppDelegate {
    NSStatusItem* _statusItem;
    NSMenu* _menu;
    NSMenuItem* _cardItem;
    TTCardView* _card;
    NSMenuItem* _storageItem;
    NSMenuItem* _loginItem;
    NSMutableArray<NSMenuItem*>* _intervalItems;
    NSTimer* _refreshTimer;
    NSTimer* _clockTimer;
    dispatch_queue_t _queue;
    tt::Engine* _engine;
    tt::Snapshot _snapshot;
    double _iconLevel;  // remaining fraction the menu bar glyph shows; -1 = unknown
    BOOL _refreshing, _pending, _pendingStorage;
    BOOL _menuOpen;
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    NSString* bundleID = NSBundle.mainBundle.bundleIdentifier;
    if (bundleID && [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID].count > 1) {
        [NSApp terminate:nil];  // already running
        return;
    }
    _engine = new tt::Engine();
    _queue = dispatch_queue_create("tokentank.refresh",
                                   dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    _intervalItems = [NSMutableArray array];

    _statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    _iconLevel = -2;  // forces the first glyph
    _statusItem.button.imagePosition = NSImageLeading;
    _statusItem.button.font = [NSFont monospacedDigitSystemFontOfSize:0 weight:NSFontWeightRegular];
    _statusItem.button.title = @"–";
    [self updateStatusItem];
    [self buildMenu];
    _statusItem.menu = _menu;

    [self configureLoginItemOnFirstRun];
    [self scheduleRefreshTimer];
    __weak TTAppDelegate* weakSelf = self;
    [NSWorkspace.sharedWorkspace.notificationCenter
        addObserverForName:NSWorkspaceDidWakeNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification*) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                        [weakSelf refreshMeasuringStorage:NO];
                    });
                }];
    [self refreshMeasuringStorage:NO];
#ifdef TT_DEV
    NSArray<NSString*>* args = NSProcessInfo.processInfo.arguments;
    const NSUInteger soak = [args indexOfObject:@"--soak"];
    if (soak != NSNotFound && soak + 1 < args.count)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [weakSelf runSoak:args[soak + 1].intValue];
        });
#endif
}

// MARK: Menu

- (void)buildMenu {
    _menu = [[NSMenu alloc] initWithTitle:@"TokenTank"];
    _menu.delegate = self;
    _menu.autoenablesItems = NO;

    _card = [[TTCardView alloc] initWithFrame:NSMakeRect(0, 0, kCardWidth, 80)];
    [_card setFrameSize:NSMakeSize(kCardWidth, [_card preferredHeight])];
    _cardItem = [NSMenuItem new];
    _cardItem.view = _card;
    [_menu addItem:_cardItem];
    [_menu addItem:NSMenuItem.separatorItem];

    _storageItem = [[NSMenuItem alloc] initWithTitle:@"Storage" action:@selector(revealClaudeFolder:) keyEquivalent:@""];
    _storageItem.target = self;
    _storageItem.toolTip = @"Disk used by Claude Code. Click to show ~/.claude in Finder.";
    [_menu addItem:_storageItem];
    [self updateStorageItem];
    [_menu addItem:NSMenuItem.separatorItem];

    NSMenuItem* settings = [[NSMenuItem alloc] initWithTitle:@"Settings" action:nil keyEquivalent:@""];
    settings.submenu = [self buildSettingsMenu];
    [_menu addItem:settings];
    NSMenuItem* quit = [[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(quit:) keyEquivalent:@"q"];
    quit.target = self;
    [_menu addItem:quit];
}

- (NSMenu*)buildSettingsMenu {
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Settings"];
    menu.autoenablesItems = NO;
    NSMenuItem* header = [[NSMenuItem alloc] initWithTitle:@"Refresh Every" action:nil keyEquivalent:@""];
    header.enabled = NO;
    [menu addItem:header];
    for (NSInteger minutes : {1, 2, 5, 15}) {
        NSString* title = minutes == 1 ? @"1 minute" : [NSString stringWithFormat:@"%ld minutes", long(minutes)];
        NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title action:@selector(setRefreshInterval:) keyEquivalent:@""];
        item.target = self;
        item.tag = minutes;
        item.indentationLevel = 1;
        [menu addItem:item];
        [_intervalItems addObject:item];
    }
    [menu addItem:NSMenuItem.separatorItem];
    _loginItem = [[NSMenuItem alloc] initWithTitle:@"Launch at Login" action:@selector(toggleLaunchAtLogin:) keyEquivalent:@""];
    _loginItem.target = self;
    [menu addItem:_loginItem];
    return menu;
}

- (void)updateSettingsState {
    const NSInteger minutes = [self refreshMinutes];
    for (NSMenuItem* item in _intervalItems) item.state = item.tag == minutes ? NSControlStateValueOn : NSControlStateValueOff;
    _loginItem.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled ? NSControlStateValueOn
                                                                                       : NSControlStateValueOff;
}

- (void)updateStorageItem {
    NSFont* font = [NSFont menuFontOfSize:0];
    NSMutableAttributedString* title =
        [[NSMutableAttributedString alloc] initWithString:@"Storage" attributes:@{NSFontAttributeName : font}];
    NSString* size = _snapshot.storage.valid ? NS(tt::formatBytes(_snapshot.storage.total)) : @"…";
    [title appendAttributedString:[[NSAttributedString alloc] initWithString:[@"  " stringByAppendingString:size]
                                                                  attributes:TextStyle(font, NSColor.secondaryLabelColor)]];
    _storageItem.attributedTitle = title;
}

// Menu bar: a small fuel gauge and the session's remaining share.
- (void)updateStatusItem {
    const int64_t now = tt::nowSeconds();
    const tt::LimitWindow* w = tt::primaryWindow(_snapshot.windows);
    double left = -1;
    NSString* tip = @"TokenTank: Claude usage";
    if (w) {
        const tt::LimitWindow e = tt::effectiveWindow(*w, now);
        left = std::clamp(100.0 - e.usedPercent, 0.0, 100.0);
        tip = e.resetsAt ? [NSString stringWithFormat:@"%@: %@ left · refills %@", NS(e.title),
                                                      NS(tt::formatPercent(left)), ClockTime(e.resetsAt, now)]
                         : [NSString stringWithFormat:@"%@: %@ left", NS(e.title), NS(tt::formatPercent(left))];
    }
    const double level = left < 0 ? -1 : std::round(left) / 100.0;
    if (level != _iconLevel) {
        _iconLevel = level;
        _statusItem.button.image = GaugeIcon(level);
    }
    NSString* title = left < 0 ? @"–" : NS(tt::formatPercent(left));
    if (![_statusItem.button.title isEqualToString:title]) _statusItem.button.title = title;
    _statusItem.button.toolTip = tip;
}

- (void)resizeCard {
    const CGFloat height = [_card preferredHeight];
    if (fabs(height - _card.frame.size.height) > 0.5) {
        [_card setFrameSize:NSMakeSize(kCardWidth, height)];
        if (_menuOpen) [_menu itemChanged:_cardItem];
    }
}

- (void)menuNeedsUpdate:(NSMenu*)menu {
    if (menu != _menu) return;
    [self updateSettingsState];
    [self resizeCard];
    [_card setNeedsDisplay:YES];
}

- (void)menuWillOpen:(NSMenu*)menu {
    if (menu != _menu) return;
    _menuOpen = YES;
    // Every click checks for fresh numbers (the engine spaces out API calls) and measures storage.
    [self refreshMeasuringStorage:YES];
    __weak TTCardView* card = _card;
    _clockTimer = [NSTimer timerWithTimeInterval:15
                                         repeats:YES
                                           block:^(NSTimer*) {
                                               [card setNeedsDisplay:YES];
                                           }];
    [NSRunLoop.currentRunLoop addTimer:_clockTimer forMode:NSRunLoopCommonModes];
}

- (void)menuDidClose:(NSMenu*)menu {
    if (menu != _menu) return;
    _menuOpen = NO;
    [_clockTimer invalidate];
    _clockTimer = nil;
    [_card clearHover];
}

// MARK: Refresh

- (void)refreshMeasuringStorage:(BOOL)storage {
    if (_refreshing) {  // run once more when the current refresh lands
        _pending = YES;
        _pendingStorage = _pendingStorage || storage;
        return;
    }
    _refreshing = YES;
    tt::Engine* engine = _engine;
    __weak TTAppDelegate* weakSelf = self;
    dispatch_async(_queue, ^{
        engine->refresh(tt::nowSeconds(), storage);
        const tt::Snapshot snapshot = engine->snapshot();
        malloc_zone_pressure_relief(nullptr, 0);  // hand scan buffers back to the system
        dispatch_async(dispatch_get_main_queue(), ^{
            TTAppDelegate* strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_refreshing = NO;
            [strongSelf apply:snapshot];
            if (strongSelf->_pending) {
                const BOOL again = strongSelf->_pendingStorage;
                strongSelf->_pending = strongSelf->_pendingStorage = NO;
                [strongSelf refreshMeasuringStorage:again];
            }
        });
    });
}

- (void)apply:(const tt::Snapshot&)snapshot {
    _snapshot = snapshot;
    [_card showSnapshot:snapshot];
    [self resizeCard];
    [self updateStatusItem];
    [self updateStorageItem];
}

- (NSInteger)refreshMinutes {
    const NSInteger minutes = [NSUserDefaults.standardUserDefaults integerForKey:kRefreshMinutesKey];
    return minutes > 0 ? minutes : 5;
}

- (void)scheduleRefreshTimer {
    [_refreshTimer invalidate];
    const NSTimeInterval interval = [self refreshMinutes] * 60.0;
    __weak TTAppDelegate* weakSelf = self;
    _refreshTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                    repeats:YES
                                                      block:^(NSTimer*) {
                                                          [weakSelf refreshMeasuringStorage:NO];
                                                      }];
    _refreshTimer.tolerance = interval / 10;
}

// MARK: Actions

- (void)setRefreshInterval:(NSMenuItem*)sender {
    [NSUserDefaults.standardUserDefaults setInteger:sender.tag forKey:kRefreshMinutesKey];
    [self scheduleRefreshTimer];
    [self updateSettingsState];
}

- (void)toggleLaunchAtLogin:(NSMenuItem*)sender {
    SMAppService* service = SMAppService.mainAppService;
    NSError* error = nil;
    if (service.status == SMAppServiceStatusEnabled)
        [service unregisterAndReturnError:&error];
    else
        [service registerAndReturnError:&error];
    if (error) NSLog(@"TokenTank: launch at login: %@", error.localizedDescription);
    [self updateSettingsState];
}

- (void)configureLoginItemOnFirstRun {
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:kLoginConfiguredKey] || ![NSBundle.mainBundle.bundlePath hasPrefix:@"/Applications/"]) return;
    NSError* error = nil;
    if (SMAppService.mainAppService.status != SMAppServiceStatusEnabled)
        [SMAppService.mainAppService registerAndReturnError:&error];
    if (error) NSLog(@"TokenTank: launch at login: %@", error.localizedDescription);
    [defaults setBool:YES forKey:kLoginConfiguredKey];
}

- (void)revealClaudeFolder:(id)sender {
    NSString* path = [NSHomeDirectory() stringByAppendingPathComponent:@".claude"];
    [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[ [NSURL fileURLWithPath:path] ]];
}

- (void)quit:(id)sender {
    [NSApp terminate:nil];
}

#ifdef TT_DEV
// Soak test for leaks and growth: each cycle runs a full refresh (log scan, storage, limits;
// the engine still spaces out API calls), opens and closes the menu, then lets the run loop idle
// briefly, like real use.
- (void)runSoak:(int)cycles {
    printf("soak start: %.1f MB\n", FootprintMB());
    [self soakStep:1 of:cycles];
}

- (void)soakStep:(int)i of:(int)cycles {
    if (i > cycles) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            printf("soak end (settled): %.1f MB\n", FootprintMB());
            fflush(stdout);
            exit(0);
        });
        return;
    }
    @autoreleasepool {
        tt::Engine* engine = _engine;
        __block tt::Snapshot snapshot;
        dispatch_sync(_queue, ^{
            engine->refresh(tt::nowSeconds(), true);
            snapshot = engine->snapshot();
            malloc_zone_pressure_relief(nullptr, 0);
        });
        [self apply:snapshot];
        __weak NSMenu* menu = _menu;
        NSTimer* closer = [NSTimer timerWithTimeInterval:0.3
                                                 repeats:NO
                                                   block:^(NSTimer*) {
                                                       [menu cancelTracking];
                                                   }];
        [NSRunLoop.currentRunLoop addTimer:closer forMode:NSRunLoopCommonModes];
        [_menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, 0) inView:_statusItem.button];
    }
    if (i % 10 == 0) printf("cycle %3d: %.1f MB\n", i, FootprintMB());
    __weak TTAppDelegate* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), ^{
        [weakSelf soakStep:i + 1 of:cycles];
    });
}
#endif

@end

// MARK: - Entry

#ifdef TT_DEV
// Made-up numbers for screenshots, so no real account data ever lands in docs.
static tt::Snapshot DemoSnapshot(int64_t now, int tiles) {
    tt::Snapshot s;
    s.updatedAt = now - 20;
    s.account = {"you@example.com", "Max 20x"};
    s.windows = {
        {"Session", 38, (now + 2 * 3600 + 41 * 60) / 60 * 60, 300, true},
        {"Weekly", 47, (now + 4 * 86400 + 3 * 3600) / 3600 * 3600, 10080, false},
        {"Opus weekly", 96, (now + 4 * 86400 + 3 * 3600) / 3600 * 3600, 10080, false},
        {"Sonnet weekly", 12, (now + 4 * 86400 + 3 * 3600) / 3600 * 3600, 10080, false},
    };
    s.windows.resize(size_t(std::clamp(tiles, 1, 4)));
    tt::CostSummary& c = s.cost;
    c.valid = true;
    c.firstDay = tt::localMidnight(now, -29);
    for (int i = 0; i < 30; ++i) {
        const int64_t day = tt::localMidnight(c.firstDay + int64_t(i) * 86400 + 43200);
        time_t t = time_t(day);
        struct tm tm;
        localtime_r(&t, &tm);
        const bool weekend = tm.tm_wday == 0 || tm.tm_wday == 6;
        const double wave = 0.75 + 0.25 * sin(i * 0.9) + 0.15 * cos(i * 2.3);
        const double cost = i < 3 ? 0 : (weekend ? 18 : 64) * wave * (i == 29 ? 0.55 : 1);
        const uint64_t tokens = uint64_t(cost * (2.7e6 + 0.4e6 * cos(i * 1.7)));
        c.days[size_t(i)] = {cost, tokens};
        if (cost > 0) {
            c.dayModels[size_t(i)][0] = {"claude-opus-5-5", cost * 0.78, uint64_t(tokens * 0.74)};
            c.dayModels[size_t(i)][1] = i % 3 ? tt::ModelUsage{"claude-sonnet-5-5", cost * 0.17, uint64_t(tokens * 0.21)}
                                              : tt::ModelUsage{"claude-fable-5-1", cost * 0.19, uint64_t(tokens * 0.06)};
        }
        c.last30 += c.days[size_t(i)];
        if (i >= 25) c.window += c.days[size_t(i)];
        if (i >= 18 && i < 25) c.previousWindow += c.days[size_t(i)];
    }
    c.today = c.days[29];
    c.hasWindow = true;
    c.windowEnd = s.windows[1].resetsAt;
    c.windowStart = c.windowEnd - 7 * 86400;
    c.topModel = "claude-opus-5-5";
    s.storage = {true, 1'420'000'000};
    return s;
}

// `TokenTank --render out.png [--dark] [--day N] [--demo | --tiles 1-4]` draws the menu with live
// (or made-up demo) data to a PNG, optionally with day N (0-29, 29 = today) hovered.
static int RenderMenu(NSString* path, BOOL dark, NSInteger hoverDay, int demoTiles) {
    tt::Snapshot snapshot;
    if (demoTiles > 0) {
        snapshot = DemoSnapshot(tt::nowSeconds(), demoTiles);
    } else {
        tt::Engine engine;
        engine.refresh(tt::nowSeconds(), true);
        snapshot = engine.snapshot();
    }
    TTCardView* view = [[TTCardView alloc] initWithFrame:NSMakeRect(0, 0, kCardWidth, 80)];
    [view showSnapshot:snapshot];
    [view setHoverDay:hoverDay];
    const CGFloat cardHeight = [view preferredHeight];
    [view setFrameSize:NSMakeSize(kCardWidth, cardHeight)];
    NSAppearance* appearance = [NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
    view.appearance = appearance;

    // The card plus the menu items under it, on a menu-like rounded panel.
    const CGFloat rows = 3 * 22 + 2 * 11 + 10, height = cardHeight + rows, inset = 6;
    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr
                                                                    pixelsWide:NSInteger(kCardWidth * 2)
                                                                    pixelsHigh:NSInteger(height * 2)
                                                                 bitsPerSample:8
                                                               samplesPerPixel:4
                                                                      hasAlpha:YES
                                                                      isPlanar:NO
                                                                colorSpaceName:NSCalibratedRGBColorSpace
                                                                   bytesPerRow:0
                                                                  bitsPerPixel:0];
    rep.size = NSMakeSize(kCardWidth, height);
    NSGraphicsContext* bitmap = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    CGContextRef cg = bitmap.CGContext;
    CGContextTranslateCTM(cg, 0, height);
    CGContextScaleCTM(cg, 1, -1);
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:cg flipped:YES];
    [appearance performAsCurrentDrawingAppearance:^{
        [(dark ? SRGB(0x2b2b2b) : SRGB(0xececec)) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, 0, kCardWidth, height) xRadius:12 yRadius:12] fill];
        [view drawRect:view.bounds];
        NSFont* font = [NSFont menuFontOfSize:0];
        NSDictionary* item = TextStyle(font, NSColor.labelColor);
        NSDictionary* dim = TextStyle(font, NSColor.secondaryLabelColor);
        CGFloat y = cardHeight + 5;
        auto separator = [&] {
            [NSColor.separatorColor setFill];
            NSRectFill(NSMakeRect(kPad, y, kCardWidth - 2 * kPad, 1));
            y += 6;
        };
        separator();
        const CGFloat used = DrawLeft(@"Storage", kPad, y + 2, item, 200);
        DrawLeft(NS(tt::formatBytes(snapshot.storage.total)), kPad + used + 8, y + 2, dim, 120);
        y += 22 + 5;
        separator();
        DrawLeft(@"Settings", kPad, y + 2, item, 200);
        DrawRight(@"›", kCardWidth - kPad - inset, y + 1, item, 20);
        y += 22;
        DrawLeft(@"Quit", kPad, y + 2, item, 200);
        DrawRight(@"⌘Q", kCardWidth - kPad - inset, y + 2, dim, 60);
    }];
    [NSGraphicsContext restoreGraphicsState];
    NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [png writeToFile:path atomically:YES] ? 0 : 1;
}

// `TokenTank --render-bar out.png [--dark]`: the menu bar item (gauge + remaining share) on a
// menu-bar-like strip, with demo values.
static int RenderBar(NSString* path, BOOL dark) {
    const CGFloat w = 92, h = 26;
    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr
                                                                    pixelsWide:NSInteger(w * 4)
                                                                    pixelsHigh:NSInteger(h * 4)
                                                                 bitsPerSample:8
                                                               samplesPerPixel:4
                                                                      hasAlpha:YES
                                                                      isPlanar:NO
                                                                colorSpaceName:NSCalibratedRGBColorSpace
                                                                   bytesPerRow:0
                                                                  bitsPerPixel:0];
    rep.size = NSMakeSize(w, h);
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    NSColor* ink = dark ? NSColor.whiteColor : NSColor.blackColor;
    [(dark ? SRGB(0x1e1e1e) : SRGB(0xf0f0f0)) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, 0, w, h) xRadius:7 yRadius:7] fill];
    NSImage* glyph = GaugeIcon(0.62);
    NSImage* tinted = [NSImage imageWithSize:glyph.size
                                     flipped:NO
                              drawingHandler:^BOOL(NSRect r) {
                                  [glyph drawInRect:r];
                                  [ink set];
                                  NSRectFillUsingOperation(r, NSCompositingOperationSourceAtop);
                                  return YES;
                              }];
    NSDictionary* text = TextStyle([NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular], ink);
    const CGFloat textWidth = TextWidth(@"62%", text);
    const CGFloat x = round((w - (18 + 4 + textWidth)) / 2);
    [tinted drawInRect:NSMakeRect(x, (h - 16) / 2, 18, 16)];
    [@"62%" drawAtPoint:NSMakePoint(x + 22, (h - 16) / 2 - 0.5) withAttributes:text];
    [NSGraphicsContext restoreGraphicsState];
    NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [png writeToFile:path atomically:YES] ? 0 : 1;
}
#endif

int main(int argc, const char* argv[]) {
    @autoreleasepool {
#ifdef TT_DEV
        if (argc >= 3 && !strcmp(argv[1], "--render-bar")) return RenderBar(@(argv[2]), argc >= 4 && !strcmp(argv[3], "--dark"));
        if (argc >= 3 && !strcmp(argv[1], "--render")) {
            BOOL dark = NO;
            int demoTiles = 0;
            NSInteger day = -1;
            for (int i = 3; i < argc; ++i) {
                if (!strcmp(argv[i], "--dark")) dark = YES;
                if (!strcmp(argv[i], "--demo")) demoTiles = 2;
                if (!strcmp(argv[i], "--tiles") && i + 1 < argc) demoTiles = atoi(argv[++i]);
                if (!strcmp(argv[i], "--day") && i + 1 < argc) day = atoi(argv[++i]);
            }
            return RenderMenu(@(argv[2]), dark, day, demoTiles);
        }
#endif
        NSApplication* app = NSApplication.sharedApplication;
        TTAppDelegate* delegate = [TTAppDelegate new];
        app.delegate = delegate;
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        [app run];
    }
    return 0;
}

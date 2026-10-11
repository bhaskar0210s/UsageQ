// Usage?: Claude usage in the menu bar.
// The data layer is plain C++ (src/core); this file is the thin AppKit shell around it.
#import <AppKit/AppKit.h>
#import <ServiceManagement/ServiceManagement.h>

#include <malloc/malloc.h>

#include <algorithm>
#include <cmath>
#include <utility>
#include <vector>

#include "../core/engine.hpp"
#include "../core/format.hpp"
#include "../core/util.hpp"

#ifdef UQ_DEV
#include <mach/mach.h>
static double FootprintMB() {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, task_info_t(&info), &count) != KERN_SUCCESS) return 0;
    return double(info.phys_footprint) / (1024.0 * 1024.0);
}
#endif

static NSString* const kAppName = @"Usage?";
static const CGFloat kCardWidth = 320;
static const CGFloat kPad = 16;
static const CGFloat kChartHeight = 52;
static const CGFloat kBoxHeight = 10 + 17 + 2 * 16 + 8;
// Spending and Settings share one slot below the meters, so switching never resizes the menu.
static const CGFloat kSectionHeight = 24 + 16 + 18 + 28 + kChartHeight + 5 + 22 + kBoxHeight;
static NSString* const kRefreshMinutesKey = @"refreshMinutes";
static NSString* const kLoginConfiguredKey = @"loginItemConfigured";

// MARK: - Drawing helpers

static NSString* NS(const std::string& s) {
    return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @"";
}

static NSDictionary* TextStyle(NSFont* font, NSColor* color) {
    return @{NSFontAttributeName : font, NSForegroundColorAttributeName : color};
}

static NSDictionary* Recolored(NSDictionary* style, NSColor* color) {
    NSMutableDictionary* copy = [style mutableCopy];
    copy[NSForegroundColorAttributeName] = color;
    return copy;
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

static void DrawCentered(NSString* s, CGFloat cx, CGFloat y, NSDictionary* style) {
    [s drawAtPoint:NSMakePoint(round(cx - TextWidth(s, style) / 2), y) withAttributes:style];
}

static void FillRounded(NSRect r, CGFloat radius, NSColor* color) {
    if (r.size.width <= 0 || r.size.height <= 0) return;
    [color setFill];
    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:radius yRadius:radius] fill];
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

static BOOL IsDark(NSAppearance* appearance) {
    return [[appearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]]
        isEqualToString:NSAppearanceNameDarkAqua];
}

// A neutral tint that follows the menu's light/dark appearance.
static NSColor* Tint(CGFloat alpha) {
    return [NSColor colorWithName:nil
                  dynamicProvider:^NSColor*(NSAppearance* appearance) {
                      return [NSColor colorWithWhite:IsDark(appearance) ? 1 : 0 alpha:alpha];
                  }];
}

// The raised "thumb" of a segmented control: white in light mode, a lifted gray in dark.
static NSColor* Thumb() {
    return [NSColor colorWithName:nil
                  dynamicProvider:^NSColor*(NSAppearance* appearance) {
                      return IsDark(appearance) ? [NSColor colorWithWhite:1 alpha:0.22] : NSColor.whiteColor;
                  }];
}

static NSImage* Symbol(NSString* name, CGFloat size, NSFontWeight weight, NSColor* color) {
    NSImage* image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    NSImageSymbolConfiguration* config = [NSImageSymbolConfiguration configurationWithPointSize:size weight:weight];
    config = [config configurationByApplyingConfiguration:[NSImageSymbolConfiguration
                                                              configurationWithHierarchicalColor:color]];
    return [image imageWithSymbolConfiguration:config];
}

static void DrawSymbol(NSImage* image, NSPoint center) {
    if (!image) return;
    const NSSize s = image.size;
    [image drawInRect:NSMakeRect(round(center.x - s.width / 2), round(center.y - s.height / 2), s.width, s.height)
             fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver
             fraction:1
       respectFlipped:YES
                hints:nil];
}

// Clock time in the user's locale and 12/24-hour setting: "5:30 PM" today, "Thu 5:30 PM" later.
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
    NSString* s = [(uq::localMidnight(t) == uq::localMidnight(now) ? time : dayAndTime) stringFromDate:date];
    return [s stringByReplacingOccurrencesOfString:@", " withString:@" "];
}

// Menu bar glyph: two small capsules, session (top) and weekly, filled to how much is used.
static NSImage* MeterGlyph(double session, double weekly) {
    NSImage* image = [NSImage imageWithSize:NSMakeSize(15, 13)
                                    flipped:NO
                             drawingHandler:^BOOL(NSRect) {
                                 auto capsule = [](CGFloat y, double fraction) {
                                     const NSRect track = NSMakeRect(0.75, y, 13.5, 3.75);
                                     NSBezierPath* outline = [NSBezierPath bezierPathWithRoundedRect:track
                                                                                             xRadius:1.875
                                                                                             yRadius:1.875];
                                     outline.lineWidth = 1;
                                     [[NSColor colorWithWhite:0 alpha:0.45] setStroke];
                                     [outline stroke];
                                     if (fraction > 0.01) {
                                         NSRect filled = track;
                                         filled.size.width = MAX(track.size.height, track.size.width * std::min(1.0, fraction));
                                         [NSColor.blackColor setFill];
                                         [[NSBezierPath bezierPathWithRoundedRect:filled xRadius:1.875 yRadius:1.875] fill];
                                     }
                                 };
                                 capsule(7.75, session);
                                 capsule(1.5, weekly);
                                 return YES;
                             }];
    [image setTemplate:YES];  // `template` is a C++ keyword
    return image;
}

// MARK: - Limits

// One limit, worded the way it is shown.
struct LimitRow {
    uq::LimitWindow window;
    uq::Pace pace;
    double used = 0;
    NSString* name;
    NSString* usedText;  // "38%"
    NSString* status;    // "12% in reserve", "10% over pace", "Limit reached"...
    NSColor* statusColor;
    NSString* resets;    // "Resets 6:15 PM · in 2h 29m"
    NSString* outlook;   // "lasts until reset", "100% by Wed 8:40 AM"; nil = no line
    NSColor* outlookColor;
};

static LimitRow MakeLimitRow(const uq::LimitWindow& raw, int64_t now) {
    LimitRow r;
    r.window = uq::effectiveWindow(raw, now);
    r.pace = uq::computePace(r.window, now);
    r.used = std::clamp(r.window.usedPercent, 0.0, 100.0);
    r.name = NS(r.window.title);
    r.usedText = NS(uq::formatPercent(r.used));
    r.statusColor = NSColor.secondaryLabelColor;
    r.outlookColor = NSColor.secondaryLabelColor;
    if (!r.window.resetsAt) {
        r.status = @"Not started";
        r.resets = @"Starts with your next prompt";
        return r;
    }
    r.resets = [NSString stringWithFormat:@"Resets %@ · in %@", ClockTime(r.window.resetsAt, now),
                                          NS(uq::formatCountdown(r.window.resetsAt - now))];
    if (r.used >= 100) {
        r.status = @"Limit reached";
        r.statusColor = NSColor.systemRedColor;
        return r;
    }
    if (!r.pace.valid) {
        r.status = @"Just started";
        return r;
    }
    const long delta = std::lround(std::fabs(r.pace.delta));
    if (delta == 0) {
        r.status = @"On pace";
    } else if (r.pace.delta < 0) {
        r.status = [NSString stringWithFormat:@"%ld%% in reserve", delta];
        r.statusColor = NSColor.systemGreenColor;
    } else {
        r.status = [NSString stringWithFormat:@"%ld%% over pace", delta];
        r.statusColor = NSColor.systemOrangeColor;
    }
    if (r.pace.lastsToReset) {
        r.outlook = @"lasts until reset";
        r.outlookColor = NSColor.systemGreenColor;
    } else if (r.pace.hasEta) {
        r.outlook = [@"100% by " stringByAppendingString:ClockTime(now + int64_t(r.pace.etaSeconds), now)];
        r.outlookColor = NSColor.systemOrangeColor;
    }
    return r;
}

// MARK: - Card

@protocol UQCardActions <NSObject>
- (NSInteger)cardRefreshMinutes;
- (void)cardSetRefreshMinutes:(NSInteger)minutes;
- (BOOL)cardLaunchesAtLogin;
- (void)cardToggleLaunchAtLogin;
- (void)cardRevealData;
- (void)cardQuit;
- (void)cardNeedsResize;
@end

@interface UQCardView : NSView
@property(nonatomic, weak) id<UQCardActions> actions;
- (void)showSnapshot:(const uq::Snapshot&)snapshot;
- (CGFloat)preferredHeight;
- (void)setHoverDay:(NSInteger)day;
- (void)toggleSettings;
- (void)reset;
#ifdef UQ_DEV
@property(nonatomic, readonly) BOOL showingSettings;
@property(nonatomic, readonly) NSInteger hoverDay;
@property(nonatomic, readonly) NSRect chartRect, boxRect;
- (NSRect)rectForTarget:(NSInteger)target;
#endif
@end

// Things on the card that react to clicks.
enum : NSInteger {
    kTargetNone = 0,
    kTargetSettings,  // gear in the footer
    kTargetQuit,      // power in the footer
    kTargetDone,      // back from Settings
    kTargetLogin,
    kTargetReveal,
    kTargetInterval = 100,  // + minutes
};

@implementation UQCardView {
    uq::Snapshot _snap;
    BOOL _hasData;
    BOOL _settings;
    BOOL _launchAtLogin;
    NSRect _chartRect, _boxRect;
    NSRect _dirty;  // what the current pass redraws
    NSInteger _hoverDay, _hoverTarget, _pressedTarget;
    std::vector<std::pair<NSRect, NSInteger>> _targets;
    NSTrackingArea* _tracking;
    NSDictionary *_name, *_big, *_body, *_bodyStrong, *_secondary, *_small, *_footnote, *_label;
    NSImage *_gear, *_gearHot, *_power, *_powerHot, *_warning, *_chevron;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _hoverDay = -1;
        NSFont* rounded = [NSFont monospacedDigitSystemFontOfSize:20 weight:NSFontWeightSemibold];
        NSFontDescriptor* roundedDesc = [rounded.fontDescriptor fontDescriptorWithDesign:NSFontDescriptorSystemDesignRounded];
        if (roundedDesc) rounded = [NSFont fontWithDescriptor:roundedDesc size:20] ?: rounded;
        _name = TextStyle([NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], NSColor.labelColor);
        _label = TextStyle([NSFont systemFontOfSize:13 weight:NSFontWeightRegular], NSColor.labelColor);
        _big = TextStyle(rounded, NSColor.labelColor);
        _body = TextStyle([NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular], NSColor.labelColor);
        _bodyStrong = TextStyle([NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightSemibold], NSColor.labelColor);
        _secondary = TextStyle([NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular], NSColor.secondaryLabelColor);
        _small = TextStyle([NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightRegular], NSColor.secondaryLabelColor);
        _footnote = TextStyle([NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightRegular], NSColor.tertiaryLabelColor);
        _gear = Symbol(@"gearshape", 13, NSFontWeightRegular, NSColor.secondaryLabelColor);
        _gearHot = Symbol(@"gearshape.fill", 13, NSFontWeightRegular, NSColor.labelColor);
        _power = Symbol(@"power", 13, NSFontWeightRegular, NSColor.secondaryLabelColor);
        _powerHot = Symbol(@"power", 13, NSFontWeightRegular, NSColor.labelColor);
        _warning = Symbol(@"exclamationmark.triangle.fill", 11, NSFontWeightRegular, NSColor.systemOrangeColor);
        _chevron = Symbol(@"chevron.right", 9, NSFontWeightSemibold, NSColor.controlAccentColor);
    }
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

- (void)showSnapshot:(const uq::Snapshot&)snapshot {
    _snap = snapshot;
    _hasData = YES;
    [self setNeedsDisplay:YES];
}

- (CGFloat)preferredHeight {
    return [self layout:NO];
}

- (void)drawRect:(NSRect)dirtyRect {
    _dirty = dirtyRect;
    [self layout:YES];
}

// Whether this pass draws `r`. Hover and press redraw only the part of the card they change,
// which keeps drawing (and the memory it churns through) small while the menu is open.
- (BOOL)paints:(NSRect)r draw:(BOOL)draw {
    return draw && NSIntersectsRect(r, _dirty);
}

- (NSRect)rectForTarget:(NSInteger)target {
    for (const auto& [rect, t] : _targets)
        if (t == target) return rect;
    return NSZeroRect;
}

- (void)redrawTarget:(NSInteger)target {
    if (target != kTargetNone) [self setNeedsDisplayInRect:NSInsetRect([self rectForTarget:target], -3, -3)];
}

- (void)separator:(CGFloat)y {
    [NSColor.separatorColor setFill];
    NSRectFillUsingOperation(NSMakeRect(kPad, y, kCardWidth - 2 * kPad, 1), NSCompositingOperationSourceOver);
}

- (int64_t)dayStart:(NSInteger)index {
    return uq::localMidnight(_snap.cost.firstDay + int64_t(index) * 86400 + 43200);
}

- (void)addTarget:(NSInteger)target rect:(NSRect)rect {
    _targets.emplace_back(rect, target);
}

// Hover and pressed feedback for a button-like area.
- (void)buttonBackground:(NSRect)rect target:(NSInteger)target radius:(CGFloat)radius {
    if (_pressedTarget == target)
        FillRounded(rect, radius, Tint(0.16));
    else if (_hoverTarget == target)
        FillRounded(rect, radius, Tint(0.09));
}

// What the card warns about, if anything: offline, signed out, rate limited.
- (NSString*)noticeText:(int64_t)now {
    const uq::Snapshot& s = _snap;
    if (!_hasData || s.notice.empty()) return nil;
    NSString* notice = NS(s.notice);
    if (s.updatedAt > 0 && (s.notice == "Offline" || s.notice == "Claude is rate limiting checks"))
        notice = [notice stringByAppendingFormat:@" · showing numbers from %@", NS(uq::formatAgo(now - s.updatedAt))];
    return notice;
}

// The bullet meter: 0-50 / 50-75 / 75-100 bands, the used bar, the even-pace marker and the
// reserve (green) or over-pace (orange) stretch between them.
- (void)meter:(NSRect)m row:(const LimitRow&)row {
    const CGFloat x = m.origin.x, y = m.origin.y, w = m.size.width;
    const NSRect track = NSMakeRect(x, y + 3, w, 12);
    [NSGraphicsContext saveGraphicsState];
    [[NSBezierPath bezierPathWithRoundedRect:track xRadius:6 yRadius:6] addClip];
    [Tint(0.07) setFill];
    NSRectFillUsingOperation(NSMakeRect(x, track.origin.y, w * 0.5, 12), NSCompositingOperationSourceOver);
    [Tint(0.11) setFill];
    NSRectFillUsingOperation(NSMakeRect(x + w * 0.5, track.origin.y, w * 0.25, 12), NSCompositingOperationSourceOver);
    [Tint(0.16) setFill];
    NSRectFillUsingOperation(NSMakeRect(x + w * 0.75, track.origin.y, w * 0.25, 12), NSCompositingOperationSourceOver);
    [NSGraphicsContext restoreGraphicsState];

    const CGFloat usedX = w * row.used / 100;
    if (row.used > 0) FillRounded(NSMakeRect(x, y + 6, MAX(6, usedX), 6), 3, NSColor.systemBlueColor);
    if (row.pace.valid) {
        const CGFloat paceX = w * std::clamp(row.pace.expected, 0.0, 100.0) / 100;
        if (paceX > usedX + 0.5)
            FillRounded(NSMakeRect(x + usedX, y + 7, paceX - usedX, 4), 2, NSColor.systemGreenColor);
        else if (usedX > paceX + 0.5)
            FillRounded(NSMakeRect(x + paceX, y + 6, usedX - paceX, 6), 3, NSColor.systemOrangeColor);
        FillRounded(NSMakeRect(round(x + paceX) - 1, y, 2, 18), 1, NSColor.labelColor);
    }
}

// Each day gets a cost bar and a token bar side by side, both growing up from one baseline.
// Units differ, so each series is scaled to its own 30-day peak; the box below has the values.
- (void)drawBars {
    const uq::CostSummary& c = _snap.cost;
    double maxCost = 0;
    uint64_t maxTokens = 0;
    for (const auto& d : c.days) {
        maxCost = MAX(maxCost, d.cost);
        maxTokens = MAX(maxTokens, d.tokens);
    }
    const NSRect r = _chartRect;
    const CGFloat baseline = NSMaxY(r);
    const CGFloat slot = r.size.width / c.days.size();
    const CGFloat barWidth = MAX(1, floor(slot - 3) / 2);
    const CGFloat pairWidth = barWidth * 2 + 1;
    [NSColor.separatorColor setFill];
    NSRectFillUsingOperation(NSMakeRect(r.origin.x, baseline - 1, r.size.width, 1), NSCompositingOperationSourceOver);
    CGContextRef cg = NSGraphicsContext.currentContext.CGContext;
    for (size_t i = 0; i < c.days.size(); ++i) {
        const CGFloat x = round((r.origin.x + i * slot + (slot - pairWidth) / 2) * 2) / 2;
        CGContextSaveGState(cg);
        if (_hoverDay >= 0 && _hoverDay != NSInteger(i)) CGContextSetAlpha(cg, 0.35);
        if (maxCost > 0 && c.days[i].cost > 0) {
            const CGFloat h = MAX(2, round((r.size.height - 1) * c.days[i].cost / maxCost));
            [NSColor.systemBlueColor setFill];
            FillBar(NSMakeRect(x, baseline - 1 - h, barWidth, h), 1.5);
        }
        if (maxTokens > 0 && c.days[i].tokens > 0) {
            const CGFloat h = MAX(2, round((r.size.height - 1) * double(c.days[i].tokens) / double(maxTokens)));
            [NSColor.systemOrangeColor setFill];
            FillBar(NSMakeRect(x + barWidth + 1, baseline - 1 - h, barWidth, h), 1.5);
        }
        CGContextRestoreGState(cg);
    }
}

- (CGFloat)legend:(NSString*)label color:(NSColor*)color x:(CGFloat)x y:(CGFloat)y {
    FillRounded(NSMakeRect(x, y + 4, 7, 7), 2, color);
    return x + 11 + DrawLeft(label, x + 11, y, _small, 80);
}

// Spending: the period table, 30 days of bars, and the box for the hovered day (the whole
// 30 days when nothing is hovered).
- (void)spendingAt:(CGFloat)y draw:(BOOL)draw {
    const CGFloat left = kPad, right = kCardWidth - kPad, width = right - left;
    const uq::CostSummary& c = _snap.cost;
    const BOOL paintTable = [self paints:NSMakeRect(0, y, kCardWidth, 24 + 16 + 18 + 20) draw:draw];
    if (paintTable) DrawLeft(@"Spending", left, y, _name, width);
    y += 24;
    const CGFloat labelWidth = 50, column = (width - labelWidth) / 4;
    NSString* const heads[4] = {@"Today", @"This week", @"Last week", @"30 days"};
    const uq::DayUsage periods[4] = {c.today, c.window, c.previousWindow, c.last30};
    const bool known[4] = {true, c.hasWindow, c.hasWindow, true};
    auto columnRight = [&](int i) { return left + labelWidth + column * (i + 1); };
    if (paintTable)
        for (int i = 0; i < 4; ++i) DrawRight(heads[i], columnRight(i), y, _small, column - 4);
    y += 16;
    if (paintTable) {
        DrawLeft(@"Cost", left, y, _secondary, labelWidth);
        for (int i = 0; i < 4; ++i)
            DrawRight(known[i] ? NS(uq::formatUSDShort(periods[i].cost)) : @"—", columnRight(i), y, _bodyStrong,
                      column - 4);
    }
    y += 18;
    if (paintTable) {
        DrawLeft(@"Tokens", left, y, _secondary, labelWidth);
        for (int i = 0; i < 4; ++i)
            DrawRight(known[i] ? NS(uq::formatTokens(double(periods[i].tokens))) : @"—", columnRight(i), y,
                      _secondary, column - 4);
    }
    y += 28;

    _chartRect = NSMakeRect(left, y, width, kChartHeight);
    if ([self paints:NSInsetRect(_chartRect, 0, -2) draw:draw]) [self drawBars];
    y += kChartHeight + 5;
    if ([self paints:NSMakeRect(0, y, kCardWidth, 16) draw:draw]) {
        DrawLeft(NS(uq::formatShortDate(c.firstDay)), left, y, _footnote, 60);
        const CGFloat legendWidth = 11 + TextWidth(@"Cost", _small) + 12 + 11 + TextWidth(@"Tokens", _small);
        const CGFloat x = [self legend:@"Cost" color:NSColor.systemBlueColor x:round(left + (width - legendWidth) / 2) y:y];
        [self legend:@"Tokens" color:NSColor.systemOrangeColor x:x + 12 y:y];
        DrawRight(@"Today", right, y, _footnote, 60);
    }
    y += 22;

    _boxRect = NSMakeRect(left, y, width, kBoxHeight);
    if (![self paints:_boxRect draw:draw]) return;
    const BOOL day = _hoverDay >= 0;
    NSString* title = !day                                            ? @"Last 30 days"
                      : _hoverDay == NSInteger(c.days.size()) - 1 ? @"Today"
                                                                     : NS(uq::formatShortDate([self dayStart:_hoverDay]));
    const uq::DayUsage& total = day ? c.days[size_t(_hoverDay)] : c.last30;
    const auto& models = day ? c.dayModels[size_t(_hoverDay)] : c.topModels;
    FillRounded(_boxRect, 8, Tint(0.05));
    const CGFloat used = DrawLeft(title, left + 10, y + 10, _bodyStrong, width / 2);
    DrawRight([NSString stringWithFormat:@"%@ · %@ tokens", NS(uq::formatUSD(total.cost)),
                                         NS(uq::formatTokens(double(total.tokens)))],
              right - 10, y + 10, _body, width - used - 30);
    CGFloat my = y + 10 + 18;
    for (size_t k = 0; k < models.size(); ++k, my += 16) {
        if (!models[k].model.empty()) {
            const CGFloat w = DrawLeft(NS(uq::modelDisplayName(models[k].model)), left + 10, my, _secondary, width / 2);
            DrawRight([NSString stringWithFormat:@"%@ · %@", NS(uq::formatUSD(models[k].cost)),
                                                 NS(uq::formatTokens(double(models[k].tokens)))],
                      right - 10, my, _secondary, width - w - 30);
        } else if (k == 0) {
            DrawLeft(day ? @"No usage this day" : @"No usage yet", left + 10, my, _secondary, width - 20);
        }
    }
}

// A row's hover and pressed feedback, kept inside its group's rounded corners.
- (void)rowBackground:(NSRect)rect target:(NSInteger)target clip:(NSBezierPath*)shape {
    if (_pressedTarget != target && _hoverTarget != target) return;
    [NSGraphicsContext saveGraphicsState];
    [shape addClip];
    [(_pressedTarget == target ? Tint(0.10) : Tint(0.05)) setFill];
    NSRectFillUsingOperation(rect, NSCompositingOperationSourceOver);
    [NSGraphicsContext restoreGraphicsState];
}

// Settings, in place of Spending and grouped like System Settings: refresh interval, launch at
// login, and Claude Code's data folder.
- (void)settingsAt:(CGFloat)top draw:(BOOL)draw {
    const CGFloat left = kPad, right = kCardWidth - kPad, width = right - left;
    const CGFloat inset = 12, refreshHeight = 76, rowHeight = 44;
    CGFloat y = top;
    draw = [self paints:NSMakeRect(0, top - 4, kCardWidth, kSectionHeight + 4) draw:draw];

    NSDictionary* doneStyle = Recolored(_bodyStrong, NSColor.controlAccentColor);
    const CGFloat doneWidth = TextWidth(@"Done", doneStyle) + 16;
    const NSRect done = NSMakeRect(right + 8 - doneWidth, y - 3, doneWidth, 22);
    [self addTarget:kTargetDone rect:done];
    if (draw) {
        DrawLeft(@"Settings", left, y, _name, width / 2);
        [self buttonBackground:done target:kTargetDone radius:6];
        DrawLeft(@"Done", done.origin.x + 8, y, doneStyle, doneWidth);
    }
    y += 30;

    NSBezierPath* group = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(left, y, width, refreshHeight + 2 * rowHeight + 2)
                                                          xRadius:10
                                                          yRadius:10];
    if (draw) {
        [Tint(0.05) setFill];
        [group fill];
    }
    auto hairline = [&](CGFloat at) {
        if (!draw) return;
        [NSColor.separatorColor setFill];
        NSRectFillUsingOperation(NSMakeRect(left + inset, at, width - inset, 1), NSCompositingOperationSourceOver);
    };

    // Refresh interval: a segmented control.
    if (draw) DrawLeft(@"Refresh every", left + inset, y + 12, _label, width - 2 * inset);
    const NSRect track = NSMakeRect(left + inset, y + 36, width - 2 * inset, 28);
    const NSInteger choices[4] = {1, 2, 5, 15};
    const NSInteger current = [self.actions cardRefreshMinutes];
    if (draw) FillRounded(track, 7, Tint(0.06));
    const CGFloat segment = track.size.width / 4;
    for (int i = 0; i < 4; ++i) {
        const NSRect cell = NSMakeRect(track.origin.x + i * segment, track.origin.y, segment, track.size.height);
        [self addTarget:kTargetInterval + choices[i] rect:cell];
        if (!draw) continue;
        const BOOL selected = choices[i] == current;
        const NSRect thumb = NSInsetRect(cell, 2, 2);
        if (selected) {
            [NSGraphicsContext saveGraphicsState];
            NSShadow* shadow = [NSShadow new];
            shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.18];
            shadow.shadowOffset = NSMakeSize(0, -0.5);
            shadow.shadowBlurRadius = 1.5;
            [shadow set];
            FillRounded(thumb, 5, Thumb());
            [NSGraphicsContext restoreGraphicsState];
        } else {
            [self buttonBackground:thumb target:kTargetInterval + choices[i] radius:5];
        }
        NSString* text = [NSString stringWithFormat:@"%ld min", long(choices[i])];
        DrawCentered(text, NSMidX(cell), cell.origin.y + 6.5, selected ? _bodyStrong : _secondary);
    }
    y += refreshHeight;
    hairline(y);
    y += 1;

    // Launch at login: a switch. The whole row is the target.
    const NSRect loginRow = NSMakeRect(left, y, width, rowHeight);
    [self addTarget:kTargetLogin rect:loginRow];
    if (draw) {
        [self rowBackground:loginRow target:kTargetLogin clip:group];
        DrawLeft(@"Launch at login", left + inset, y + 13, _label, width - 80);
        const NSRect knobTrack = NSMakeRect(right - inset - 34, y + 12, 34, 20);
        FillRounded(knobTrack, 10, _launchAtLogin ? NSColor.controlAccentColor : Tint(0.16));
        const NSRect knob = NSMakeRect(_launchAtLogin ? NSMaxX(knobTrack) - 18 : knobTrack.origin.x + 2, knobTrack.origin.y + 2, 16, 16);
        [NSGraphicsContext saveGraphicsState];
        NSShadow* shadow = [NSShadow new];
        shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.25];
        shadow.shadowOffset = NSMakeSize(0, -0.5);
        shadow.shadowBlurRadius = 1.5;
        [shadow set];
        [NSColor.whiteColor setFill];
        [[NSBezierPath bezierPathWithOvalInRect:knob] fill];
        [NSGraphicsContext restoreGraphicsState];
    }
    y += rowHeight;
    hairline(y);
    y += 1;

    // Claude Code's data folder.
    const NSRect revealRow = NSMakeRect(left, y, width, rowHeight);
    [self addTarget:kTargetReveal rect:revealRow];
    if (draw) {
        [self rowBackground:revealRow target:kTargetReveal clip:group];
        DrawLeft(@"Claude Code data", left + inset, y + 13, _label, width / 2);
        NSDictionary* link = Recolored(_body, NSColor.controlAccentColor);
        const CGFloat w = TextWidth(@"Show in Finder", link);
        DrawLeft(@"Show in Finder", right - inset - 12 - w, y + 14, link, w + 1);
        DrawSymbol(_chevron, NSMakePoint(right - inset - 3, y + 22));
    }
    y += rowHeight;

    if (draw) DrawLeft(@"Numbers also refresh every time you open this menu.", left + inset, y + 8, _footnote, width - inset);
}

// One pass that either measures or draws, so layout and drawing never disagree.
- (CGFloat)layout:(BOOL)draw {
    const CGFloat left = kPad, right = kCardWidth - kPad, width = right - left;
    const int64_t now = uq::nowSeconds();
    const uq::Snapshot& s = _snap;
    _targets.clear();
    CGFloat y = 14;

    if (NSString* notice = [self noticeText:now]) {
        if ([self paints:NSMakeRect(0, y, kCardWidth, 28) draw:draw]) {
            FillRounded(NSMakeRect(left, y, width, 28), 8, [NSColor.systemOrangeColor colorWithAlphaComponent:0.14]);
            DrawSymbol(_warning, NSMakePoint(left + 15, y + 14));
            DrawLeft(notice, left + 28, y + 6.5, _body, width - 36);
        }
        y += 28 + 14;
    }

    // Limits: one meter each, session first.
    if (!_hasData || s.windows.empty()) {
        if ([self paints:NSMakeRect(0, y, kCardWidth, 24) draw:draw])
            DrawLeft(_hasData ? @"Usage limits unavailable" : @"Checking your limits…", left, y, _secondary, width);
        y += 24;
    }
    for (size_t i = 0; i < s.windows.size(); ++i) {
        const LimitRow row = MakeLimitRow(s.windows[i], now);
        if (i > 0) y += 18;
        const BOOL paintRow = [self paints:NSMakeRect(0, y, kCardWidth, 82 + (row.outlook ? 17 : 0)) draw:draw];
        if (paintRow) {
            const CGFloat usedWidth = TextWidth(@" used", _secondary);
            const CGFloat bigWidth = TextWidth(row.usedText, _big);
            DrawLeft(row.name, left, y + 5, _name, width - bigWidth - usedWidth - 10);
            DrawLeft(@" used", right - usedWidth, y + 8, _secondary, usedWidth + 1);
            DrawLeft(row.usedText, right - usedWidth - bigWidth, y, _big, bigWidth + 1);
        }
        y += 28;
        if (paintRow) [self meter:NSMakeRect(left, y, width, 18) row:row];
        y += 20;
        if (paintRow) {
            DrawLeft(@"0", left, y, _footnote, 20);
            DrawCentered(@"50%", left + width * 0.5, y, _footnote);
            DrawCentered(@"75%", left + width * 0.75, y, _footnote);
            DrawRight(@"100%", right, y, _footnote, 40);
        }
        y += 17;
        if (paintRow) {
            const CGFloat used = DrawLeft(row.status, left, y, Recolored(_bodyStrong, row.statusColor), width / 2);
            DrawRight(row.resets, right, y, _secondary, width - used - 12);
        }
        y += 17;
        if (row.outlook) {
            if (paintRow) {
                const CGFloat used = DrawLeft(@"At this pace: ", left, y, _secondary, width);
                DrawLeft(row.outlook, left + used, y, Recolored(_body, row.outlookColor), width - used);
            }
            y += 17;
        }
    }
    if (!s.windows.empty()) {
        y += 8;
        if ([self paints:NSMakeRect(0, y, kCardWidth, 15) draw:draw]) {
            FillRounded(NSMakeRect(left, y + 2, 2, 11), 1, NSColor.labelColor);
            DrawLeft(@"Even pace: where you'd be with steady use", left + 8, y, _footnote, width - 8);
        }
        y += 15;
    }

    // Spending, or Settings in its place.
    if (_settings || s.cost.valid) {
        y += 12;
        if ([self paints:NSMakeRect(0, y, kCardWidth, 1) draw:draw]) [self separator:y];
        y += 13;
        if (_settings)
            [self settingsAt:y draw:draw];
        else
            [self spendingAt:y draw:draw];
        y += kSectionHeight;
    }

    // Footer: name, plan and disk use, then Settings and Quit.
    y += 14;
    if ([self paints:NSMakeRect(0, y, kCardWidth, 1) draw:draw]) [self separator:y];
    y += 9;
    const NSRect quit = NSMakeRect(right - 26, y, 26, 26);
    const NSRect settings = NSMakeRect(right - 56, y, 26, 26);
    [self addTarget:kTargetSettings rect:settings];
    [self addTarget:kTargetQuit rect:quit];
    if ([self paints:NSMakeRect(0, y, kCardWidth, 26) draw:draw]) {
        NSMutableArray<NSString*>* facts = [NSMutableArray array];
        if (!s.account.plan.empty()) [facts addObject:NS(s.account.plan)];
        if (s.storage.valid) [facts addObject:[NS(uq::formatBytes(s.storage.total)) stringByAppendingString:@" on disk"]];
        const CGFloat used = DrawLeft(kAppName, left, y + 5, _name, 80);
        DrawLeft([@"  " stringByAppendingString:[facts componentsJoinedByString:@" · "]], left + used, y + 6, _secondary,
                 NSMinX(settings) - left - used - 6);
        if (_settings && _pressedTarget != kTargetSettings)
            FillRounded(settings, 6, Tint(0.12));
        else
            [self buttonBackground:settings target:kTargetSettings radius:6];
        [self buttonBackground:quit target:kTargetQuit radius:6];
        const BOOL gearHot = _settings || _hoverTarget == kTargetSettings;
        DrawSymbol(gearHot ? _gearHot : _gear, NSMakePoint(NSMidX(settings), NSMidY(settings)));
        DrawSymbol(_hoverTarget == kTargetQuit ? _powerHot : _power, NSMakePoint(NSMidX(quit), NSMidY(quit)));
    }
    y += 26;
    return ceil(y + 10);
}

- (NSInteger)targetAt:(NSPoint)p {
    for (const auto& [rect, target] : _targets)
        if (NSPointInRect(p, rect)) return target;
    return kTargetNone;
}

- (void)perform:(NSInteger)target {
    switch (target) {
        case kTargetSettings:
            [self toggleSettings];
            return;
        case kTargetDone:
            _settings = NO;
            break;
        case kTargetQuit:
            [self.actions cardQuit];
            return;
        case kTargetReveal:
            [self.actions cardRevealData];
            return;
        case kTargetLogin:
            [self.actions cardToggleLaunchAtLogin];
            _launchAtLogin = [self.actions cardLaunchesAtLogin];
            break;
        default:
            if (target > kTargetInterval) [self.actions cardSetRefreshMinutes:target - kTargetInterval];
            break;
    }
    [self.actions cardNeedsResize];
    [self setNeedsDisplay:YES];
}

- (void)toggleSettings {
    _settings = !_settings;
    if (_settings) _launchAtLogin = [self.actions cardLaunchesAtLogin];
    _hoverDay = -1;
    [self.actions cardNeedsResize];
    [self setNeedsDisplay:YES];
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
    if (NSIsEmptyRect(_boxRect))
        [self setNeedsDisplay:YES];
    else  // the bars dim around the day, and the box below shows it
        [self setNeedsDisplayInRect:NSUnionRect(NSInsetRect(_chartRect, -2, -2), _boxRect)];
}

- (void)mouseMoved:(NSEvent*)event {
    const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];  // flipped: y grows down
    const NSInteger target = [self targetAt:p];
    if (target != _hoverTarget) {
        [self redrawTarget:_hoverTarget];
        [self redrawTarget:target];
        _hoverTarget = target;
    }
    if (_settings || !_snap.cost.valid) return;
    NSInteger day = -1;
    if (NSPointInRect(p, NSInsetRect(_chartRect, -2, -10))) {
        const CGFloat slot = _chartRect.size.width / _snap.cost.days.size();
        day = std::clamp<NSInteger>(NSInteger(floor((p.x - _chartRect.origin.x) / slot)), 0,
                                    NSInteger(_snap.cost.days.size()) - 1);
    } else if (p.y > NSMaxY(_chartRect) && p.y < NSMaxY(_boxRect)) {
        return;  // on the way down to the box: keep the day so its details can be read
    }
    [self setHoverDay:day];
}

- (void)mouseExited:(NSEvent*)event {
    [self redrawTarget:_hoverTarget];
    _hoverTarget = kTargetNone;
    [self setHoverDay:-1];
}

// Buttons act on release, like standard controls. The menu is still tracking, so follow the
// mouse here until the button comes up.
- (void)mouseDown:(NSEvent*)event {
    const NSInteger target = [self targetAt:[self convertPoint:event.locationInWindow fromView:nil]];
    if (target == kTargetNone) return;
    _pressedTarget = target;
    [self redrawTarget:target];
    [self displayIfNeeded];
    while (NSEvent* next = [self.window nextEventMatchingMask:NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged]) {
        const NSInteger over = [self targetAt:[self convertPoint:next.locationInWindow fromView:nil]];
        if (next.type == NSEventTypeLeftMouseUp) {
            _pressedTarget = kTargetNone;
            [self redrawTarget:target];
            if (over == target) [self perform:target];
            break;
        }
        const NSInteger pressed = over == target ? target : kTargetNone;
        if (pressed != _pressedTarget) {
            _pressedTarget = pressed;
            [self redrawTarget:target];
            [self displayIfNeeded];
        }
    }
}

- (void)reset {
    _hoverDay = -1;
    _hoverTarget = kTargetNone;
    _pressedTarget = kTargetNone;
    _settings = NO;
}

#ifdef UQ_DEV
- (BOOL)showingSettings {
    return _settings;
}

- (NSInteger)hoverDay {
    return _hoverDay;
}

- (NSRect)chartRect {
    return _chartRect;
}

- (NSRect)boxRect {
    return _boxRect;
}
#endif

@end

// MARK: - App

#ifdef UQ_DEV
static uq::Snapshot DemoSnapshot(int64_t now);
static int WritePNG(NSBitmapImageRep* rep, NSString* path);
#endif

@interface UQAppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate, UQCardActions>
@end

@implementation UQAppDelegate {
    NSStatusItem* _statusItem;
    NSMenu* _menu;
    NSMenuItem* _cardItem;
    UQCardView* _card;
    NSTimer* _refreshTimer;
    NSTimer* _clockTimer;
    dispatch_queue_t _queue;
    uq::Engine* _engine;
    uq::Snapshot _snapshot;
    NSString* _glyphKey;
    BOOL _refreshing, _pending, _pendingForMenu;
    BOOL _menuOpen;
#ifdef UQ_DEV
    BOOL _demo;  // click test: keep the demo numbers, never fetch
#endif
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    NSString* bundleID = NSBundle.mainBundle.bundleIdentifier;
    if (bundleID && [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID].count > 1) {
        [NSApp terminate:nil];  // already running
        return;
    }
    _engine = new uq::Engine();
    // Background QoS keeps routine refreshes on the efficiency cores; see -refreshForMenu:.
    _queue = dispatch_queue_create("usageq.refresh",
                                   dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_BACKGROUND, 0));

    _statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    _statusItem.button.imagePosition = NSImageLeading;
    _statusItem.button.font = [NSFont monospacedDigitSystemFontOfSize:0 weight:NSFontWeightRegular];
    _statusItem.button.title = @"–";
    [self updateStatusItem];
    [self buildMenu];
    _statusItem.menu = _menu;

    [self configureLoginItemOnFirstRun];
    [self scheduleRefreshTimer];
    __weak UQAppDelegate* weakSelf = self;
    [NSWorkspace.sharedWorkspace.notificationCenter
        addObserverForName:NSWorkspaceDidWakeNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification*) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                        [weakSelf refreshForMenu:NO];
                    });
                }];
#ifdef UQ_DEV
    NSArray<NSString*>* args = NSProcessInfo.processInfo.arguments;
    const NSUInteger soak = [args indexOfObject:@"--soak"];
    if (soak != NSNotFound && soak + 1 < args.count)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [weakSelf runSoak:args[soak + 1].intValue];
        });
    const NSUInteger clicks = [args indexOfObject:@"--click-test"];
    if (clicks != NSNotFound) {
        _demo = YES;
        [self apply:DemoSnapshot(uq::nowSeconds())];
        NSString* png = clicks + 1 < args.count ? args[clicks + 1] : nil;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [weakSelf runClickTest:png];
        });
    }
#endif
    [self refreshForMenu:NO];
}

// MARK: Menu

- (void)buildMenu {
    _menu = [[NSMenu alloc] initWithTitle:kAppName];
    _menu.delegate = self;
    _menu.autoenablesItems = NO;
    _card = [[UQCardView alloc] initWithFrame:NSMakeRect(0, 0, kCardWidth, 80)];
    _card.actions = self;
    [_card setFrameSize:NSMakeSize(kCardWidth, [_card preferredHeight])];
    _cardItem = [NSMenuItem new];
    _cardItem.view = _card;
    [_menu addItem:_cardItem];
    // The card draws its own buttons; this keeps ⌘Q working while the menu is open.
    NSMenuItem* quitKey = [[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(quit:) keyEquivalent:@"q"];
    quitKey.target = self;
    quitKey.hidden = YES;
    quitKey.allowsKeyEquivalentWhenHidden = YES;
    [_menu addItem:quitKey];
}

// Menu bar: two capsules (session, weekly) and the session's used share.
- (void)updateStatusItem {
    const int64_t now = uq::nowSeconds();
    double session = -1, weekly = -1;
    NSMutableArray<NSString*>* tips = [NSMutableArray array];
    for (const uq::LimitWindow& raw : _snapshot.windows) {
        const uq::LimitWindow w = uq::effectiveWindow(raw, now);
        const double used = std::clamp(w.usedPercent, 0.0, 100.0);
        if (w.isSession && session < 0) session = used;
        else if (!w.isSession && weekly < 0) weekly = used;
        [tips addObject:[NSString stringWithFormat:@"%@: %@ used", NS(w.title), NS(uq::formatPercent(used))]];
    }
    const double shown = session >= 0 ? session : weekly;
    NSString* key = [NSString stringWithFormat:@"%.0f/%.0f", session, weekly];
    if (![key isEqualToString:_glyphKey]) {
        _glyphKey = key;
        _statusItem.button.image = MeterGlyph(session / 100.0, weekly / 100.0);
    }
    NSString* title = shown < 0 ? @"–" : NS(uq::formatPercent(shown));
    if (![_statusItem.button.title isEqualToString:title]) _statusItem.button.title = title;
    _statusItem.button.toolTip = tips.count ? [tips componentsJoinedByString:@"\n"] : kAppName;
}

- (void)resizeCard {
    const CGFloat height = [_card preferredHeight];
    if (fabs(height - _card.frame.size.height) > 0.5) {
        [_card setFrameSize:NSMakeSize(kCardWidth, height)];
        if (_menuOpen) [_menu itemChanged:_cardItem];
    }
}

- (void)menuNeedsUpdate:(NSMenu*)menu {
    [self resizeCard];
    [_card setNeedsDisplay:YES];
}

- (void)menuWillOpen:(NSMenu*)menu {
    _menuOpen = YES;
    // Every click checks for fresh numbers (the engine spaces out API calls) and measures disk use.
    [self refreshForMenu:YES];
    // Countdowns and pace move once a minute, so redraw just after each minute turns.
    __weak UQCardView* card = _card;
    const double now = NSDate.date.timeIntervalSince1970;
    _clockTimer = [[NSTimer alloc] initWithFireDate:[NSDate dateWithTimeIntervalSince1970:floor(now / 60) * 60 + 60.05]
                                           interval:60
                                            repeats:YES
                                              block:^(NSTimer*) {
                                                  [card setNeedsDisplay:YES];
                                              }];
    _clockTimer.tolerance = 0.2;
    [NSRunLoop.currentRunLoop addTimer:_clockTimer forMode:NSRunLoopCommonModes];
}

- (void)menuDidClose:(NSMenu*)menu {
    _menuOpen = NO;
    [_clockTimer invalidate];
    _clockTimer = nil;
    [_card reset];  // the next open starts on the main view
    [self resizeCard];
}

// MARK: Card actions

- (NSInteger)cardRefreshMinutes {
    return [self refreshMinutes];
}

- (void)cardSetRefreshMinutes:(NSInteger)minutes {
    [NSUserDefaults.standardUserDefaults setInteger:minutes forKey:kRefreshMinutesKey];
    [self scheduleRefreshTimer];
}

- (BOOL)cardLaunchesAtLogin {
    return SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
}

- (void)cardToggleLaunchAtLogin {
    SMAppService* service = SMAppService.mainAppService;
    NSError* error = nil;
    if (service.status == SMAppServiceStatusEnabled)
        [service unregisterAndReturnError:&error];
    else
        [service registerAndReturnError:&error];
    if (error) NSLog(@"Usage?: launch at login: %@", error.localizedDescription);
}

- (void)cardRevealData {
    [_menu cancelTracking];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString* path = [NSHomeDirectory() stringByAppendingPathComponent:@".claude"];
        [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[ [NSURL fileURLWithPath:path] ]];
    });
}

- (void)cardQuit {
    [_menu cancelTracking];
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSApp terminate:nil];
    });
}

- (void)cardNeedsResize {
    [self resizeCard];
}

- (void)quit:(id)sender {
    [NSApp terminate:nil];
}

// MARK: Refresh

// Timer, wake and launch refreshes run at background QoS. Opening the menu also measures disk use
// and runs at user-initiated QoS, because someone is looking at the card.
- (void)refreshForMenu:(BOOL)forMenu {
#ifdef UQ_DEV
    if (_demo) return;
#endif
    if (_refreshing) {  // run once more when the current refresh lands
        _pending = YES;
        _pendingForMenu = _pendingForMenu || forMenu;
        if (forMenu)  // lifts the refresh already running to the priority of the one waiting on it
            dispatch_async(_queue, dispatch_block_create_with_qos_class(DISPATCH_BLOCK_ENFORCE_QOS_CLASS,
                                                                        QOS_CLASS_USER_INITIATED, 0, ^{
                                                                        }));
        return;
    }
    _refreshing = YES;
    uq::Engine* engine = _engine;
    __weak UQAppDelegate* weakSelf = self;
    dispatch_block_t work = ^{
        engine->refresh(uq::nowSeconds(), forMenu);
        const uq::Snapshot snapshot = engine->snapshot();
        malloc_zone_pressure_relief(nullptr, 0);  // hand scan buffers back to the system
        dispatch_async(dispatch_get_main_queue(), ^{
            UQAppDelegate* strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_refreshing = NO;
            [strongSelf apply:snapshot];
            if (strongSelf->_pending) {
                const BOOL again = strongSelf->_pendingForMenu;
                strongSelf->_pending = strongSelf->_pendingForMenu = NO;
                [strongSelf refreshForMenu:again];
            }
        });
    };
    dispatch_async(_queue, forMenu ? dispatch_block_create_with_qos_class(DISPATCH_BLOCK_ENFORCE_QOS_CLASS,
                                                                          QOS_CLASS_USER_INITIATED, 0, work)
                                   : work);
}

- (void)apply:(const uq::Snapshot&)snapshot {
    _snapshot = snapshot;
    [_card showSnapshot:snapshot];
    [self resizeCard];
    [self updateStatusItem];
}

- (NSInteger)refreshMinutes {
    const NSInteger minutes = [NSUserDefaults.standardUserDefaults integerForKey:kRefreshMinutesKey];
    return minutes > 0 ? minutes : 5;
}

- (void)scheduleRefreshTimer {
    [_refreshTimer invalidate];
    const NSTimeInterval interval = [self refreshMinutes] * 60.0;
    __weak UQAppDelegate* weakSelf = self;
    _refreshTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                    repeats:YES
                                                      block:^(NSTimer*) {
                                                          [weakSelf refreshForMenu:NO];
                                                      }];
    _refreshTimer.tolerance = interval / 10;
}

- (void)configureLoginItemOnFirstRun {
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:kLoginConfiguredKey] || ![NSBundle.mainBundle.bundlePath hasPrefix:@"/Applications/"]) return;
    NSError* error = nil;
    if (SMAppService.mainAppService.status != SMAppServiceStatusEnabled)
        [SMAppService.mainAppService registerAndReturnError:&error];
    if (error) NSLog(@"Usage?: launch at login: %@", error.localizedDescription);
    [defaults setBool:YES forKey:kLoginConfiguredKey];
}

#ifdef UQ_DEV
// Soak test for leaks and growth: each cycle runs a full refresh (log scan, storage, limits;
// the engine still spaces out API calls), opens the menu, sweeps the pointer across the bars,
// opens and closes Settings, closes the menu, then lets the run loop idle briefly, like real use.
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
        uq::Engine* engine = _engine;
        __block uq::Snapshot snapshot;
        dispatch_sync(_queue, ^{
            engine->refresh(uq::nowSeconds(), true);
            snapshot = engine->snapshot();
            malloc_zone_pressure_relief(nullptr, 0);
        });
        [self apply:snapshot];
        __weak NSMenu* menu = _menu;
        __weak UQCardView* card = _card;
        __block NSInteger day = 0;
        NSTimer* hover = [NSTimer timerWithTimeInterval:0.02  // sweep the pointer across the bars
                                                repeats:YES
                                                  block:^(NSTimer* t) {
                                                      [card setHoverDay:day < 30 ? day++ : -1];
                                                      if (day >= 30) [t invalidate];
                                                  }];
        NSTimer* flip = [NSTimer timerWithTimeInterval:0.7  // Settings on, then off again
                                               repeats:YES
                                                 block:^(NSTimer*) {
                                                     [card toggleSettings];
                                                 }];
        NSTimer* closer = [NSTimer timerWithTimeInterval:1.5
                                                 repeats:NO
                                                   block:^(NSTimer*) {
                                                       [flip invalidate];
                                                       [menu cancelTracking];
                                                   }];
        for (NSTimer* t in @[ hover, flip, closer ]) [NSRunLoop.currentRunLoop addTimer:t forMode:NSRunLoopCommonModes];
        [_menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, 0) inView:_statusItem.button];
    }
    if (i % 10 == 0) printf("cycle %3d: %.1f MB\n", i, FootprintMB());
    __weak UQAppDelegate* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), ^{
        [weakSelf soakStep:i + 1 of:cycles];
    });
}

// `UsageQ --click-test [out.png]`: opens the menu on demo numbers and uses the card the way a
// person would, checking each result while the menu stays open. `quit` or `cmdq` instead of a
// path checks that the power button or ⌘Q quits.
- (void)runClickTest:(NSString*)png {
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    id savedMinutes = [defaults objectForKey:kRefreshMinutesKey];
    const BOOL quit = [png isEqualToString:@"quit"] || [png isEqualToString:@"cmdq"];
    __block int failures = 0;
    void (^check)(BOOL, NSString*) = ^(BOOL ok, NSString* what) {
        printf("%s  %s\n", ok ? "pass" : "FAIL", what.UTF8String);
        fflush(stdout);
        if (!ok) ++failures;
    };
    UQCardView* card = _card;
    void (^post)(NSEventType, NSPoint) = ^(NSEventType type, NSPoint p) {
        NSEvent* e = [NSEvent mouseEventWithType:type
                                        location:[card convertPoint:p toView:nil]
                                   modifierFlags:0
                                       timestamp:NSProcessInfo.processInfo.systemUptime
                                    windowNumber:card.window.windowNumber
                                         context:nil
                                     eventNumber:0
                                      clickCount:type == NSEventTypeMouseMoved ? 0 : 1
                                        pressure:type == NSEventTypeLeftMouseDown ? 1 : 0];
        [NSApp postEvent:e atStart:NO];
    };
    void (^hover)(NSPoint) = ^(NSPoint p) {  // straight to the card; AppKit also follows the real cursor
        [card mouseMoved:[NSEvent mouseEventWithType:NSEventTypeMouseMoved
                                            location:[card convertPoint:p toView:nil]
                                       modifierFlags:0
                                           timestamp:NSProcessInfo.processInfo.systemUptime
                                        windowNumber:card.window.windowNumber
                                             context:nil
                                         eventNumber:0
                                          clickCount:0
                                            pressure:0]];
    };
    void (^click)(NSInteger) = ^(NSInteger target) {
        const NSRect r = [card rectForTarget:target];
        const NSPoint p = NSMakePoint(NSMidX(r), NSMidY(r));
        post(NSEventTypeMouseMoved, p);
        post(NSEventTypeLeftMouseDown, p);
        post(NSEventTypeLeftMouseUp, p);
    };
    void (^key)(CGKeyCode) = ^(CGKeyCode code) {  // through the window server, like a keyboard
        for (bool down : {true, false}) {
            CGEventRef e = CGEventCreateKeyboardEvent(nullptr, code, down);
            CGEventSetFlags(e, kCGEventFlagMaskCommand);
            CGEventPostToPid(getpid(), e);
            CFRelease(e);
        }
    };
    __weak UQAppDelegate* weakSelf = self;
    BOOL (^menuOpen)(void) = ^BOOL {
        UQAppDelegate* strongSelf = weakSelf;
        return strongSelf && strongSelf->_menuOpen;
    };

    NSMutableArray* steps = [NSMutableArray array];
    if (quit) {
        if ([png isEqualToString:@"cmdq"])
            [steps addObject:^{ key(12); }];  // ⌘Q
        else
            [steps addObject:^{ click(kTargetQuit); }];
    } else {
        [steps addObject:^{ click(kTargetSettings); }];
        [steps addObject:^{ check(card.showingSettings && menuOpen(), @"the gear opens Settings in the card; the menu stays open"); }];
        [steps addObject:^{ click(kTargetInterval + 15); }];
        [steps addObject:^{ check([weakSelf refreshMinutes] == 15 && menuOpen(), @"a refresh interval can be picked"); }];
        [steps addObject:^{
            if (png) {
                NSBitmapImageRep* rep = [card bitmapImageRepForCachingDisplayInRect:card.bounds];
                [card cacheDisplayInRect:card.bounds toBitmapImageRep:rep];
                WritePNG(rep, png);
            }
            click(kTargetDone);
        }];
        [steps addObject:^{ check(!card.showingSettings && menuOpen(), @"Done goes back to Spending"); }];
        [steps addObject:^{
            const NSRect chart = card.chartRect;
            hover(NSMakePoint(chart.origin.x + chart.size.width * (26.5 / 30), NSMidY(chart)));
        }];
        [steps addObject:^{ check(card.hoverDay == 26, @"hovering a bar picks its day"); }];
        [steps addObject:^{ hover(NSMakePoint(NSMidX(card.boxRect), NSMidY(card.boxRect))); }];
        [steps addObject:^{ check(card.hoverDay == 26, @"the day stays while reading its box"); }];
        [steps addObject:^{ hover(NSMakePoint(40, NSMaxY(card.boxRect) + 30)); }];
        [steps addObject:^{ check(card.hoverDay == -1, @"away from the chart the box shows the last 30 days"); }];
        [steps addObject:^{ click(kTargetSettings); }];
        [steps addObject:^{ click(kTargetSettings); }];
        [steps addObject:^{ check(!card.showingSettings && menuOpen(), @"the gear also closes Settings"); }];
    }
    NSMenu* menu = _menu;
    __block NSUInteger next = 0;
    NSTimer* timer = [NSTimer timerWithTimeInterval:0.5
                                            repeats:YES
                                              block:^(NSTimer* t) {
                                                  if (next < steps.count)
                                                      ((void (^)(void))steps[next++])();
                                                  else
                                                      [menu cancelTracking];
                                              }];
    [NSRunLoop.currentRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    [_menu popUpMenuPositioningItem:nil atLocation:NSZeroPoint inView:_statusItem.button];
    [timer invalidate];
    if (quit) {  // the menu closed and the app is still here
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            check(NO, [png stringByAppendingString:@" quits"]);
            exit(1);
        });
        return;
    }
    check(next == steps.count, @"every step ran with the menu open");
    check(!_card.showingSettings, @"closing the menu resets the card");
    if (savedMinutes)
        [defaults setObject:savedMinutes forKey:kRefreshMinutesKey];
    else
        [defaults removeObjectForKey:kRefreshMinutesKey];
    printf("%s\n", failures ? "click test FAILED" : "click test passed");
    exit(failures ? 1 : 0);
}
#endif

@end

// MARK: - Entry

#ifdef UQ_DEV
// Made-up numbers for screenshots, so no real account data ever lands in docs.
static uq::Snapshot DemoSnapshot(int64_t now) {
    uq::Snapshot s;
    s.updatedAt = now - 20;
    s.account = {"you@example.com", "Max 20x"};
    s.windows = {
        {"Session", 38, (now + 2 * 3600 + 29 * 60) / 60 * 60, 300, true},
        {"Fable weekly", 52, (now + 4 * 86400 + 1 * 3600 + 44 * 60) / 60 * 60, 10080, false},
    };
    uq::CostSummary& c = s.cost;
    c.valid = true;
    c.firstDay = uq::localMidnight(now, -29);
    double opus = 0, sonnet = 0;
    uint64_t opusTokens = 0, sonnetTokens = 0;
    for (int i = 0; i < 30; ++i) {
        const int64_t day = uq::localMidnight(c.firstDay + int64_t(i) * 86400 + 43200);
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
            c.dayModels[size_t(i)][1] = i % 3 ? uq::ModelUsage{"claude-sonnet-5-5", cost * 0.17, uint64_t(tokens * 0.21)}
                                              : uq::ModelUsage{"claude-fable-5-1", cost * 0.19, uint64_t(tokens * 0.06)};
            opus += cost * 0.78;
            opusTokens += uint64_t(tokens * 0.74);
            if (i % 3) {
                sonnet += cost * 0.17;
                sonnetTokens += uint64_t(tokens * 0.21);
            }
        }
        c.last30 += c.days[size_t(i)];
        if (i >= 25) c.window += c.days[size_t(i)];
        if (i >= 18 && i < 25) c.previousWindow += c.days[size_t(i)];
    }
    c.today = c.days[29];
    c.hasWindow = true;
    c.windowEnd = s.windows[1].resetsAt;
    c.windowStart = c.windowEnd - 7 * 86400;
    c.topModels = {uq::ModelUsage{"claude-opus-5-5", opus, opusTokens}, uq::ModelUsage{"claude-sonnet-5-5", sonnet, sonnetTokens}};
    c.topModel = "claude-opus-5-5";
    s.storage = {true, 1'420'000'000};
    return s;
}

// Answers the settings questions the card asks, without touching the real app's settings.
@interface UQDemoActions : NSObject <UQCardActions>
@end
@implementation UQDemoActions
- (NSInteger)cardRefreshMinutes {
    return 5;
}
- (void)cardSetRefreshMinutes:(NSInteger)minutes {
}
- (BOOL)cardLaunchesAtLogin {
    return YES;
}
- (void)cardToggleLaunchAtLogin {
}
- (void)cardRevealData {
}
- (void)cardQuit {
}
- (void)cardNeedsResize {
}
@end

static NSBitmapImageRep* Bitmap(CGFloat w, CGFloat h, CGFloat scale) {
    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr
                                                                    pixelsWide:NSInteger(w * scale)
                                                                    pixelsHigh:NSInteger(h * scale)
                                                                 bitsPerSample:8
                                                               samplesPerPixel:4
                                                                      hasAlpha:YES
                                                                      isPlanar:NO
                                                                colorSpaceName:NSCalibratedRGBColorSpace
                                                                   bytesPerRow:0
                                                                  bitsPerPixel:0];
    rep.size = NSMakeSize(w, h);
    return rep;
}

static int WritePNG(NSBitmapImageRep* rep, NSString* path) {
    NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [png writeToFile:path atomically:YES] ? 0 : 1;
}

// `UsageQ --render out.png [--dark] [--day N] [--demo] [--stale] [--settings]` draws the menu card
// with live (or demo) data, optionally with day N (0-29, 29 = today) hovered or Settings open.
static int RenderCard(NSString* path, BOOL dark, NSInteger hoverDay, BOOL demo, BOOL stale, BOOL settings) {
    uq::Snapshot snapshot;
    if (demo) {
        snapshot = DemoSnapshot(uq::nowSeconds());
        if (stale) {
            snapshot.notice = "Offline";
            snapshot.updatedAt = uq::nowSeconds() - 12 * 60;
        }
    } else {
        uq::Engine engine;
        engine.refresh(uq::nowSeconds(), true);
        snapshot = engine.snapshot();
    }
    UQDemoActions* actions = [UQDemoActions new];
    UQCardView* view = [[UQCardView alloc] initWithFrame:NSMakeRect(0, 0, kCardWidth, 80)];
    view.actions = actions;
    [view showSnapshot:snapshot];
    [view setHoverDay:hoverDay];
    if (settings) [view toggleSettings];
    const CGFloat height = [view preferredHeight];
    [view setFrameSize:NSMakeSize(kCardWidth, height)];
    NSAppearance* appearance = [NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
    view.appearance = appearance;
    NSBitmapImageRep* rep = Bitmap(kCardWidth, height, 2);
    CGContextRef cg = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep].CGContext;
    CGContextTranslateCTM(cg, 0, height);
    CGContextScaleCTM(cg, 1, -1);
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:cg flipped:YES];
    [appearance performAsCurrentDrawingAppearance:^{
        [[NSColor colorWithSRGBRed:dark ? 0.165 : 0.937 green:dark ? 0.165 : 0.937 blue:dark ? 0.17 : 0.94 alpha:1] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, 0, kCardWidth, height) xRadius:12 yRadius:12] fill];
        [view drawRect:view.bounds];
    }];
    [NSGraphicsContext restoreGraphicsState];
    return WritePNG(rep, path);
}

// `UsageQ --render-bar out.png [--dark]`: the menu bar item on a menu-bar-like strip.
static int RenderBar(NSString* path, BOOL dark) {
    const CGFloat w = 84, h = 26;
    NSBitmapImageRep* rep = Bitmap(w, h, 4);
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    NSColor* ink = dark ? NSColor.whiteColor : NSColor.blackColor;
    [[NSColor colorWithWhite:dark ? 0.12 : 0.94 alpha:1] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, 0, w, h) xRadius:7 yRadius:7] fill];
    NSImage* glyph = MeterGlyph(0.38, 0.52);
    NSImage* tinted = [NSImage imageWithSize:glyph.size
                                     flipped:NO
                              drawingHandler:^BOOL(NSRect r) {
                                  [glyph drawInRect:r];
                                  [ink set];
                                  NSRectFillUsingOperation(r, NSCompositingOperationSourceAtop);
                                  return YES;
                              }];
    NSDictionary* text = TextStyle([NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular], ink);
    const CGFloat x = round((w - (15 + 5 + TextWidth(@"38%", text))) / 2);
    [tinted drawInRect:NSMakeRect(x, (h - 13) / 2, 15, 13)];
    [@"38%" drawAtPoint:NSMakePoint(x + 20, (h - 16) / 2 - 0.5) withAttributes:text];
    [NSGraphicsContext restoreGraphicsState];
    return WritePNG(rep, path);
}
#endif

int main(int argc, const char* argv[]) {
    @autoreleasepool {
#ifdef UQ_DEV
        if (argc >= 3 && !strcmp(argv[1], "--render-bar")) return RenderBar(@(argv[2]), argc >= 4 && !strcmp(argv[3], "--dark"));
        if (argc >= 3 && !strcmp(argv[1], "--render")) {
            BOOL dark = NO, demo = NO, stale = NO, settings = NO;
            NSInteger day = -1;
            for (int i = 3; i < argc; ++i) {
                if (!strcmp(argv[i], "--dark")) dark = YES;
                if (!strcmp(argv[i], "--demo")) demo = YES;
                if (!strcmp(argv[i], "--stale")) stale = YES;
                if (!strcmp(argv[i], "--settings")) settings = YES;
                if (!strcmp(argv[i], "--day") && i + 1 < argc) day = atoi(argv[++i]);
            }
            return RenderCard(@(argv[2]), dark, day, demo, stale, settings);
        }
#endif
        NSApplication* app = NSApplication.sharedApplication;
        UQAppDelegate* delegate = [UQAppDelegate new];
        app.delegate = delegate;
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        [app run];
    }
    return 0;
}

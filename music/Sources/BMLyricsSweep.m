#import "../../common/BMPrefs.h"
#import "BMLyricsSweep.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

static const void *kLinkKey = &kLinkKey;
static const void *kT0Key = &kT0Key;
static const void *kMaskedKey = &kMaskedKey;
static const void *kCacheKey = &kCacheKey;
static const void *kUnderKey = &kUnderKey;
static const void *kStateKey = &kStateKey;

// Playback clock from MediaRemote (real song position, pause aware). Refreshed ~2x per second.
static double gElapsed = -1, gRate = 1;
static CFTimeInterval gFetchedAt = 0;
static NSDate *gTimestamp;

static double BMSongTime(void);
static void BMRefreshClock(void) {
    static void (*getInfo)(dispatch_queue_t, void (^)(CFDictionaryRef));
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        if (h) getInfo = dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    });
    if (!getInfo) return;
    getInfo(dispatch_get_main_queue(), ^(CFDictionaryRef info) {
        NSDictionary *d = (__bridge NSDictionary *)info;
        NSNumber *e = d[@"kMRMediaRemoteNowPlayingInfoElapsedTime"];
        NSNumber *r = d[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
        NSDate *t = d[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
        if (![e isKindOfClass:[NSNumber class]]) return;
        double newRate = [r isKindOfClass:[NSNumber class]] ? r.doubleValue : 1;
        NSDate *newTs = [t isKindOfClass:[NSDate class]] ? t : [NSDate date];
        double predicted = BMSongTime();
        double reported = e.doubleValue + [[NSDate date] timeIntervalSinceDate:newTs] * newRate;
        if (predicted >= 0 && newRate == gRate && fabs(predicted - reported) < 1.0) return;   // jitter
        gElapsed = e.doubleValue;
        gRate = newRate;
        gTimestamp = newTs;
        gFetchedAt = CACurrentMediaTime();
    });
}

// Current song position in seconds, or -1 when unknown.
static double BMSongTime(void) {
    if (gElapsed < 0) return -1;
    return gElapsed + [[NSDate date] timeIntervalSinceDate:gTimestamp] * gRate;
}

static void BMLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void BMLog(NSString *fmt, ...) {
    id dv = BMPrefRaw(CFSTR("DebugLog"), CFSTR("com.rocketkid300.bettermusic"));
    if (!([dv respondsToSelector:@selector(boolValue)] && [dv boolValue])) return;
    va_list ap; va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *path = @"/var/jb/var/mobile/Library/bettermusic-lyrics.log";
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!h) { [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]; h = [NSFileHandle fileHandleForWritingAtPath:path]; }
    [h seekToEndOfFile];
    [h writeData:[[m stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}

// Seconds to run the highlight ahead of the reported song time (display + clock delay).
static double BMLeadSeconds(void) {
    id v = BMPrefRaw(CFSTR("LyricsLead"), CFSTR("com.rocketkid300.bettermusic"));
    return v ? [v doubleValue] : 0.3;
}

static BOOL BMSweepEnabled(void) {
    id v = BMPrefRaw(CFSTR("LyricsSweep"), CFSTR("com.rocketkid300.bettermusic"));
    return v ? [v boolValue] : YES;
}

static id BMIvar(id obj, const char *name) {
    if (!obj) return nil;
    Ivar iv = class_getInstanceVariable([obj class], name);
    return iv ? object_getIvar(obj, iv) : nil;
}

static UILabel *BMLabel(UIView *line, BOOL selected) {
    SEL acc = selected ? @selector(accessibilitySelectedLyricLabel) : @selector(accessibilityLyricLabel);
    id l = nil;
    if ([line respondsToSelector:acc]) {
        l = ((id (*)(id, SEL))objc_msgSend)(line, acc);
    }
    const char *iv = selected ? "selectedLabel" : "label";
    if (![l isKindOfClass:[UILabel class]]) l = BMIvar(line, iv);
    if (![l isKindOfClass:[UILabel class]]) l = BMIvar(BMIvar(line, "contentView"), iv);
    return [l isKindOfClass:[UILabel class]] ? l : nil;
}

static BOOL BMIsSelected(UIView *line, UILabel *sel) {
    if ([line respondsToSelector:@selector(accessibilityIsSelected)])
        return ((BOOL (*)(id, SEL))objc_msgSend)(line, @selector(accessibilityIsSelected));
    return sel.alpha > 0.5 && !sel.hidden;
}

static void BMCollectLines(UIView *v, NSMutableArray *out, int depth) {
    if ([NSStringFromClass([v class]) hasSuffix:@"SyncedLyricsLineView"]) { [out addObject:v]; return; }
    if (depth > 6) return;
    for (UIView *s in v.subviews) BMCollectLines(s, out, depth + 1);
}

static NSArray *BMFragments(UILabel *l) {
    NSAttributedString *at = l.attributedText;
    CGFloat w = l.bounds.size.width;
    if (!at.length || w < 1) return @[];
    NSString *key = [NSString stringWithFormat:@"%@|%.0f", at.string, w];
    NSDictionary *cache = objc_getAssociatedObject(l, kCacheKey);
    if ([cache[@"key"] isEqualToString:key]) return cache[@"frags"];
    // UILabel applies label.font to ranges without a font attribute; do the same so rows wrap identically.
    NSMutableAttributedString *fat = [at mutableCopy];
    [fat enumerateAttribute:NSFontAttributeName inRange:NSMakeRange(0, fat.length) options:0 usingBlock:^(id v, NSRange r, BOOL *stop) {
        if (!v && l.font) [fat addAttribute:NSFontAttributeName value:l.font range:r];
    }];
    [fat enumerateAttribute:NSParagraphStyleAttributeName inRange:NSMakeRange(0, fat.length) options:0 usingBlock:^(id v, NSRange r, BOOL *stop) {
        NSMutableParagraphStyle *ps = v ? [v mutableCopy] : [[NSMutableParagraphStyle alloc] init];
        ps.lineBreakMode = NSLineBreakByWordWrapping;
        [fat addAttribute:NSParagraphStyleAttributeName value:ps range:r];
    }];
    NSTextStorage *ts = [[NSTextStorage alloc] initWithAttributedString:fat];
    NSLayoutManager *lm = [[NSLayoutManager alloc] init];
    NSTextContainer *tc = [[NSTextContainer alloc] initWithSize:CGSizeMake(w, CGFLOAT_MAX)];
    tc.lineFragmentPadding = 0;
    [lm addTextContainer:tc];
    [ts addLayoutManager:lm];
    NSMutableArray *frags = [NSMutableArray array];
    NSRange all = [lm glyphRangeForTextContainer:tc];
    [lm enumerateLineFragmentsForGlyphRange:all usingBlock:^(CGRect rect, CGRect used, NSTextContainer *c, NSRange gr, BOOL *stop) {
        CGFloat endX = CGRectGetMaxX(used);
        [frags addObject:@{@"rect": [NSValue valueWithCGRect:rect], @"loc": @(gr.location), @"len": @(gr.length),
                           @"x0": @(used.origin.x), @"x1": @(endX)}];
    }];
    // Safety net: label is clearly multi-row but layout found one row -> split by height.
    CGFloat rowH = l.font ? l.font.lineHeight : 0;
    if (frags.count == 1 && rowH > 1 && l.bounds.size.height > rowH * 1.6) {
        NSUInteger R = (NSUInteger)round(l.bounds.size.height / rowH);
        NSUInteger total = at.length;
        [frags removeAllObjects];
        for (NSUInteger i = 0; i < R; i++) {
            CGRect rr = CGRectMake(0, i * l.bounds.size.height / R, w, l.bounds.size.height / R);
            NSUInteger a = total * i / R, b = total * (i + 1) / R;
            [frags addObject:@{@"rect": [NSValue valueWithCGRect:rr], @"loc": @(a), @"len": @(b - a),
                               @"x0": @0, @"x1": @(w * 0.95), @"synth": @YES}];
        }
        BMLog(@"fallback split into %lu rows (rowH=%.1f)", (unsigned long)R, rowH);
    }
    BMLog(@"attrs0=%@ labelFont=%@ frags=%lu", [at attributesAtIndex:0 effectiveRange:NULL], l.font, (unsigned long)frags.count);
    // Store per-glyph x offsets for partial lines.
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *f in frags) {
        NSMutableArray *xs = [NSMutableArray array];
        NSUInteger loc = [f[@"loc"] unsignedIntegerValue], len = [f[@"len"] unsignedIntegerValue];
        CGRect r = [f[@"rect"] CGRectValue];
        for (NSUInteger g = 0; g <= len; g++) {
            if (f[@"synth"]) { [xs addObject:@(len ? [f[@"x1"] doubleValue] * g / len : 0)]; continue; }
            CGFloat x = (g < len) ? [lm locationForGlyphAtIndex:loc + g].x + r.origin.x : [f[@"x1"] doubleValue];
            [xs addObject:@(x)];
        }
        [out addObject:@{@"rect": f[@"rect"], @"xs": xs}];
    }
    objc_setAssociatedObject(l, kCacheKey, @{@"key": key, @"frags": out}, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return out;
}

// Time (seconds from line start) at which character boundary x (0..total) is reached.
static double BMTimeForChar(NSArray *words, double st, double dur, double G, double x) {
    double wordChars = 0;
    BOOL timed = NO;
    for (id w in words) {
        NSAttributedString *t = [w respondsToSelector:@selector(lyricsText)] ? [w performSelector:@selector(lyricsText)] : nil;
        wordChars += MAX(1, t.length);
        double ws = ((double (*)(id, SEL))objc_msgSend)(w, @selector(startTime));
        double we = ((double (*)(id, SEL))objc_msgSend)(w, @selector(endTime));
        if (we > ws + 0.01) timed = YES;
    }
    if (!timed || wordChars < 1) return dur * (G > 0 ? x / G : 0);
    double cx = x * wordChars / MAX(1, G), acc = 0;
    for (id w in words) {
        NSAttributedString *t = [w performSelector:@selector(lyricsText)];
        double len = MAX(1, t.length);
        double ws = ((double (*)(id, SEL))objc_msgSend)(w, @selector(startTime)) - st;
        double we = ((double (*)(id, SEL))objc_msgSend)(w, @selector(endTime)) - st;
        if (cx <= acc + len) return ws + (we - ws) * ((cx - acc) / len);
        acc += len;
    }
    return dur;
}

// Build a soft-edged mask on the bright label and animate it with Core Animation (GPU, smooth).
static BOOL BMStartSweep(UILabel *sel, id line, NSTimeInterval elapsed, BOOL paused) {
    if (![line respondsToSelector:@selector(startTime)]) return NO;
    double st = ((double (*)(id, SEL))objc_msgSend)(line, @selector(startTime));
    double en = ((double (*)(id, SEL))objc_msgSend)(line, @selector(endTime));
    double dur = en - st;
    if (dur < 0.3) { BMLog(@"skip short line dur=%.2f", dur); return NO; }
    NSArray *words = [line respondsToSelector:@selector(words)] ? [line performSelector:@selector(words)] : nil;
    if (![words isKindOfClass:[NSArray class]]) words = @[];
    NSArray *frags = BMFragments(sel);
    BMLog(@"line '%@' st=%.2f en=%.2f words=%lu frags=%lu bounds=%@ lines=%ld elapsed=%.2f paused=%d",
          sel.attributedText.string, st, en, (unsigned long)words.count, (unsigned long)frags.count,
          NSStringFromCGRect(sel.bounds), (long)sel.numberOfLines, elapsed, paused);
    if (!frags.count) return NO;
    double G = 0;
    for (NSDictionary *f in frags) G += [f[@"xs"] count] - 1;

    const CGFloat feather = 18;
    CALayer *mask = [CALayer layer];
    mask.frame = sel.bounds;
    CFTimeInterval now = [mask convertTime:CACurrentMediaTime() fromLayer:nil];
    double g0 = 0;
    for (NSDictionary *f in frags) {
        CGRect r = [f[@"rect"] CGRectValue];
        NSArray *xs = f[@"xs"];
        double n = xs.count - 1;
        CGFloat fw = [xs.lastObject doubleValue] - [xs.firstObject doubleValue];
        if (fw < 1) { g0 += n; continue; }
        CALayer *clip = [CALayer layer];
        clip.frame = CGRectMake(r.origin.x - 4, r.origin.y, r.size.width + 8, r.size.height);
        clip.masksToBounds = YES;
        CGFloat base = r.origin.x - 4;

        CAGradientLayer *head = [CAGradientLayer layer];
        CGFloat hw = fw + 8 + feather;
        head.anchorPoint = CGPointMake(0, 0);
        head.bounds = CGRectMake(0, 0, hw, r.size.height);
        head.startPoint = CGPointMake(0, 0.5);
        head.endPoint = CGPointMake(1, 0.5);
        head.colors = @[(id)[UIColor whiteColor].CGColor, (id)[UIColor whiteColor].CGColor, (id)[UIColor clearColor].CGColor];
        head.locations = @[@0, @((hw - feather) / hw), @1];

        // position.x (minX of head) so that its soft end sits at glyph x.
        NSMutableArray *vals = [NSMutableArray array], *times = [NSMutableArray array];
        CGFloat x0 = [xs.firstObject doubleValue];
        double tFirst = BMTimeForChar(words, st, dur, G, g0);
        double tLast = BMTimeForChar(words, st, dur, G, g0 + n);
        CGFloat startX = -hw;
        [vals addObject:@(startX)]; [times addObject:@0];
        if (tFirst > 0.001) { [vals addObject:@(startX)]; [times addObject:@(MIN(1, tFirst / dur))]; }
        for (NSUInteger j = 0; j <= (NSUInteger)n; j++) {
            double t = BMTimeForChar(words, st, dur, G, g0 + j);
            CGFloat gx = [xs[j] doubleValue] - x0 + 4;          // glyph x inside clip
            CGFloat minX = gx + feather * 0.5 - hw;
            double kt = MIN(1, MAX(0, t / dur));
            if (times.count && kt < [times.lastObject doubleValue]) kt = [times.lastObject doubleValue];
            [vals addObject:@(minX)]; [times addObject:@(kt)];
        }
        if ([times.lastObject doubleValue] < 1) { [vals addObject:vals.lastObject]; [times addObject:@1]; }
        (void)tLast; (void)base;
        head.position = CGPointMake(startX, 0);

        CAKeyframeAnimation *an = [CAKeyframeAnimation animationWithKeyPath:@"position.x"];
        an.values = vals;
        an.keyTimes = times;
        an.calculationMode = kCAAnimationLinear;
        an.duration = dur;
        an.beginTime = paused ? 0 : now - elapsed;
        an.fillMode = kCAFillModeBoth;
        an.removedOnCompletion = NO;
        [head addAnimation:an forKey:@"bmsweep"];
        [clip addSublayer:head];
        [mask addSublayer:clip];
        g0 += n;
    }
    if (paused) { mask.speed = 0; mask.timeOffset = elapsed; }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    sel.layer.mask = mask;
    [CATransaction commit];
    return YES;
}

@interface BMLyricsSweepDriver : NSObject
@property (nonatomic, weak) UIViewController *vc;
- (void)tick:(CADisplayLink *)link;
@end

@implementation BMLyricsSweepDriver
- (void)tick:(CADisplayLink *)link {
    UIViewController *vc = self.vc;
    if (!vc || !vc.viewIfLoaded.window || !BMSweepEnabled()) return;
    static int n; if (n++ % 20 == 0) BMRefreshClock();
    @try {
        NSMutableArray *lines = [NSMutableArray array];
        BMCollectLines(vc.view, lines, 0);
        for (UIView *lv in lines) {
            UILabel *sel = BMLabel(lv, YES);
            if (!sel) continue;
            if (!BMIsSelected(lv, sel)) {
                if (objc_getAssociatedObject(sel, kMaskedKey)) {
                    sel.layer.mask = nil;
                    objc_setAssociatedObject(sel, kMaskedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
                objc_setAssociatedObject(lv, kStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                UILabel *old = objc_getAssociatedObject(lv, kUnderKey);
                if (old) { [old removeFromSuperview]; objc_setAssociatedObject(lv, kUnderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
                continue;
            }
            // Our own 55% white copy of the whole line, so unsung rows stay readable.
            UILabel *ul = objc_getAssociatedObject(lv, kUnderKey);
            NSString *utext = sel.attributedText.string;
            if (!ul || ![ul.accessibilityIdentifier isEqualToString:utext]) {
                if (!ul) {
                    ul = [[UILabel alloc] init];
                    ul.backgroundColor = [UIColor clearColor];
                    ul.userInteractionEnabled = NO;
                    objc_setAssociatedObject(lv, kUnderKey, ul, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
                NSMutableAttributedString *m = [sel.attributedText mutableCopy] ?: [[NSMutableAttributedString alloc] initWithString:@""];
                [m addAttribute:NSForegroundColorAttributeName value:[UIColor colorWithWhite:1 alpha:0.55]
                          range:NSMakeRange(0, m.length)];
                ul.attributedText = m;
                ul.font = sel.font;
                ul.textAlignment = sel.textAlignment;
                ul.numberOfLines = sel.numberOfLines;
                ul.lineBreakMode = sel.lineBreakMode;
                ul.accessibilityIdentifier = utext;
            }
            if (ul.superview != sel.superview) [sel.superview insertSubview:ul belowSubview:sel];
            ul.frame = sel.frame;
            ul.alpha = sel.alpha;
            if (!objc_getAssociatedObject(lv, kT0Key)) objc_setAssociatedObject(lv, kT0Key, @(CACurrentMediaTime()), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            id line = BMIvar(lv, "line");
            double st = [line respondsToSelector:@selector(startTime)] ? ((double (*)(id, SEL))objc_msgSend)(line, @selector(startTime)) : 0;
            double song = BMSongTime();
            double elapsed = song >= 0 ? MAX(0, song + BMLeadSeconds() - st) : (CACurrentMediaTime() - [objc_getAssociatedObject(lv, kT0Key) doubleValue]);
            BOOL paused = song >= 0 && gRate == 0;
            NSDictionary *prev = objc_getAssociatedObject(lv, kStateKey);
            NSString *key = [NSString stringWithFormat:@"%@|%.0f", sel.attributedText.string, sel.bounds.size.width];
            BOOL restart = !prev || ![prev[@"key"] isEqualToString:key] || [prev[@"paused"] boolValue] != paused;
            if (!restart && song >= 0 && !paused) {
                double expected = [prev[@"elapsed"] doubleValue] + (CACurrentMediaTime() - [prev[@"at"] doubleValue]);
                if (fabs(expected - elapsed) > 1.0) restart = YES;       // seek or drift
            }
            if (!restart) continue;
            if (BMStartSweep(sel, line, elapsed, paused)) {
                objc_setAssociatedObject(lv, kStateKey, @{@"key": key, @"paused": @(paused), @"elapsed": @(elapsed), @"at": @(CACurrentMediaTime())}, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(sel, kMaskedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[BetterMusic] sweep error %@", e.name);
    }
}
@end

@implementation BMLyricsSweep
+ (void)attachTo:(UIViewController *)vc {
    if (objc_getAssociatedObject(vc, kLinkKey)) return;
    BMLyricsSweepDriver *d = [BMLyricsSweepDriver new];
    d.vc = vc;
    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:d selector:@selector(tick:)];
    link.preferredFramesPerSecond = 20; BMRefreshClock();
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    objc_setAssociatedObject(vc, kLinkKey, @[link, d], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSLog(@"[BetterMusic] lyric sweep attached to %@", NSStringFromClass([vc class]));
}
+ (void)detachFrom:(UIViewController *)vc {
    NSArray *p = objc_getAssociatedObject(vc, kLinkKey);
    if (!p) return;
    [p.firstObject invalidate];
    objc_setAssociatedObject(vc, kLinkKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
@end

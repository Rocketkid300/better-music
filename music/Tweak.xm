#import "../common/BMPrefs.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <notify.h>
#import "Sources/BMGlassView.h"
#import "Sources/BMLyricsSweep.h"

// Prefs domain and keys: write once, share with any future settings app.
#define BM_DOMAIN "com.rocketkid300.bettermusic"
#define BM_KEY_ENABLED "Enabled"
#define BM_KEY_TABGLASS "TabBarGlass"

static BOOL BMSafeMode(void);
static BOOL BMEnabled(void) {
    if (BMSafeMode()) return NO;
    id v = BMPrefRaw(CFSTR(BM_KEY_ENABLED), CFSTR(BM_DOMAIN));
    return v ? [v boolValue] : YES;
}

// One glass look for every round or capsule button (back, top-right group, shuffle, +).
static void BMGlassStyle(UIView *v) {
    v.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
    v.layer.borderWidth = 0.5;
    v.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.14].CGColor;
}

static void BMCollect(UIView *v, NSString *suffix, NSMutableArray *out, int depth);
static void BMClearDarkPanels(UIView *v, int depth);
static void BMSweepTinted(UIView *v, int depth);
static UIScrollView *BMStackScroll(UIView *v);

// Lay out the stack-wide tint. It reaches 1500pt beyond the content at both ends (overscroll bounce, late-loading
// sections) and the scroll view itself is painted in the tint colour, so black can never show through.
static void BMLayoutTint(UIScrollView *stack) {
    UIView *tv = [stack viewWithTag:0xBB];
    UIColor *top = objc_getAssociatedObject(stack, "bmTop"), *bot = objc_getAssociatedObject(stack, "bmBot");
    if (!tv || !top || !bot) return;
    CGFloat H = MAX(stack.contentSize.height, stack.bounds.size.height), pad = 1500, total = H + 2 * pad;
    CAGradientLayer *g2 = (CAGradientLayer *)tv.layer.sublayers.firstObject;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    tv.frame = CGRectMake(0, -pad, stack.bounds.size.width, total);
    g2.frame = tv.bounds;
    g2.colors = @[(id)top.CGColor, (id)top.CGColor, (id)bot.CGColor, (id)bot.CGColor];
    g2.locations = @[@0, @(pad / total), @((pad + H) / total), @1];
    [CATransaction commit];
    stack.backgroundColor = bot;
}
static BOOL gTintedActive;            // an album page with the stack-wide tint is on screen

// Make the navigation bar background transparent at the top of the album page and fade it in while scrolling.
static void BMFadeNavBackground(UIScrollView *stack) {
    UIView *bar = objc_getAssociatedObject(stack, "bmNavBar");
    if (!bar || !bar.window) {
        // The window holds one navigation bar per tab; take the one that shares an ancestor with this page.
        bar = nil;
        for (UIView *u = stack.superview; u && !bar; u = u.superview) {
            NSMutableArray *bars = [NSMutableArray array];
            BMCollect(u, @"NavigationBar", bars, 0);
            for (UIView *cand in bars) if (cand.window && !cand.hidden) { bar = cand; break; }
        }
        objc_setAssociatedObject(stack, "bmNavBar", bar, OBJC_ASSOCIATION_ASSIGN);
    }
    if (!bar) return;
    CGFloat y = stack.contentOffset.y + stack.adjustedContentInset.top;
    CGFloat a = MAX(0, MIN(1, y / 60.0));
    for (UIView *u in bar.subviews)
        if ([NSStringFromClass([u class]) isEqualToString:@"_UIBarBackground"]) u.alpha = a;
}

// Debug logging (video URLs, lyric timings) is off unless DebugLog is set.
static BOOL BMDebugOn(void) {
    id v = BMPrefRaw(CFSTR("DebugLog"), CFSTR(BM_DOMAIN));
    return [v respondsToSelector:@selector(boolValue)] && [v boolValue];
}

// Crash-loop guard. Each launch drops a marker that is removed after the app has run 25 seconds. If the marker is
// still there next launch, the previous run died early; after three early deaths in a row every visual change is
// skipped (safe mode) until the settings toggle "Safe mode" is switched off and the app survives a launch.
static BOOL gSafeMode = NO;
static BOOL BMSafeMode(void) { return gSafeMode; }

static void BMCheckSafeMode(void) {
    NSString *dir = @"/var/jb/var/mobile/Library";
    NSString *marker = [dir stringByAppendingPathComponent:@"bm-launch-marker"];
    NSString *count = [dir stringByAppendingPathComponent:@"bm-early-deaths"];
    NSFileManager *fm = [NSFileManager defaultManager];
    int deaths = [[NSString stringWithContentsOfFile:count encoding:NSUTF8StringEncoding error:nil] intValue];
    if ([fm fileExistsAtPath:marker]) deaths++;                       // last run did not survive 25 seconds
    [[NSString stringWithFormat:@"%d", deaths] writeToFile:count atomically:YES encoding:NSUTF8StringEncoding error:nil];
    id force = BMPrefRaw(CFSTR("SafeMode"), CFSTR(BM_DOMAIN));
    gSafeMode = deaths >= 3 || ([force respondsToSelector:@selector(boolValue)] && [force boolValue]);
    [@"1" writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"[BetterMusic] launch: early deaths=%d safeMode=%d", deaths, gSafeMode);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [fm removeItemAtPath:marker error:nil];                        // survived: this launch was healthy
        [@"0" writeToFile:count atomically:YES encoding:NSUTF8StringEncoding error:nil];
    });
}

// Phase 0 recon: log which interesting classes exist in this iOS build.
__attribute__((unused)) static void BMProbe(void) {
    unsigned int n = 0;
    Class *all = objc_copyClassList(&n);
    NSMutableArray *hits = [NSMutableArray array];
    const char *needles[] = {"MiniPlayer", "NowPlaying", "Lyrics", "TabBar"};
    for (unsigned int i = 0; i < n; i++) {
        const char *name = class_getName(all[i]);
        for (int k = 0; k < 4; k++) {
            if (strstr(name, needles[k])) { [hits addObject:@(name)]; break; }
        }
    }
    free(all);
    [hits sortUsingSelector:@selector(compare:)];
    NSString *out = [hits componentsJoinedByString:@"\n"];
    NSString *path = @"/var/jb/var/mobile/Library/bettermusic-classes.txt";
    [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"[BetterMusic] probe wrote %lu classes", (unsigned long)hits.count);
}

// Phase 0b: dump methods and ivars of the key classes.
__attribute__((unused)) static void BMDumpClasses(void) {
    const char *names[] = {
        "_TtC16MusicApplication17PlayerTimeControl",
        "_TtCC16MusicApplication32NowPlayingControlsViewController12VolumeSlider",
        "MusicApplication.NowPlayingControlsViewController",
        "MusicApplication.NowPlayingTransportButton",
        "MusicApplication.NowPlayingTransportControlStackView",
        "MusicNowPlayingControlsViewController"
    };
    NSMutableString *out = [NSMutableString string];
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        Class c = objc_getClass(names[i]);
        [out appendFormat:@"=== %s %@ super=%@\n", names[i], c ? @"" : @"(missing)",
            c ? NSStringFromClass(class_getSuperclass(c)) : @"-"];
        if (!c) continue;
        unsigned int n = 0;
        Ivar *iv = class_copyIvarList(c, &n);
        for (unsigned int k = 0; k < n; k++)
            [out appendFormat:@"  ivar %s %s\n", ivar_getName(iv[k]), ivar_getTypeEncoding(iv[k]) ?: ""];
        free(iv);
        Method *ms = class_copyMethodList(c, &n);
        for (unsigned int k = 0; k < n; k++)
            [out appendFormat:@"  - %s %s\n", sel_getName(method_getName(ms[k])), method_getTypeEncoding(ms[k]) ?: ""];
        free(ms);
        Method *cm = class_copyMethodList(object_getClass(c), &n);
        for (unsigned int k = 0; k < n; k++)
            [out appendFormat:@"  + %s\n", sel_getName(method_getName(cm[k]))];
        free(cm);
    }
    [out writeToFile:@"/var/jb/var/mobile/Library/bettermusic-methods3.txt" atomically:YES
            encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"[BetterMusic] method dump written");
}

// On-demand dump of the key window: create /var/jb/var/mobile/Library/bm-dump-trigger to get bettermusic-tree.txt.
static void BMTree(UIView *v, int depth, NSMutableString *out) {
    NSString *extra = @"";
    if ([v isKindOfClass:[UILabel class]]) extra = [NSString stringWithFormat:@" text='%@' font=%.1f", ((UILabel *)v).text, ((UILabel *)v).font.pointSize];
    CGFloat bw = -1, ba = 0;
    UIColor *bcol = v.backgroundColor ? [v.backgroundColor resolvedColorWithTraitCollection:v.traitCollection] : nil;
    if (bcol) [bcol getWhite:&bw alpha:&ba];
    NSString *bgs = bcol ? [NSString stringWithFormat:@" bg=%.2f/%.2f", bw, ba] : @"";
    [out appendFormat:@"%*s%@ f=%@ r=%.1f a=%.2f%@%@\n", depth * 2, "", NSStringFromClass([v class]),
        NSStringFromCGRect(v.frame), v.layer.cornerRadius, v.alpha, bgs, extra];
    if (depth > 16) return;
    for (UIView *s in v.subviews) BMTree(s, depth + 1, out);
}

static void BMStartTriggerWatcher(void) {
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(t, ^{
        NSString *trig = @"/var/jb/var/mobile/Library/bm-dump-trigger";
        NSString *strig = @"/var/jb/var/mobile/Library/bm-scroll-trigger";     // debug: scroll the album page (value: top | bottom | <points>)
        if ([[NSFileManager defaultManager] fileExistsAtPath:strig]) {
            NSString *arg = [[NSString stringWithContentsOfFile:strig encoding:NSUTF8StringEncoding error:nil] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            [[NSFileManager defaultManager] removeItemAtPath:strig error:nil];
            for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
                if (![sc isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                    NSMutableArray *cvs = [NSMutableArray array];
                    BMCollect(w, @"UICollectionView", cvs, 0);
                    UICollectionView *best = nil;
                    for (UIView *u in cvs) {
                        UICollectionView *c = (UICollectionView *)u;
                        if (c.backgroundView.tag == 0xB9) { best = c; break; }
                        if (!best || c.contentSize.height > best.contentSize.height) best = c;
                    }
                    if (best) { UIScrollView *page = BMStackScroll(best); if (page) best = (UICollectionView *)page; }
                    if (!best) continue;
                    CGFloat bottom = MAX(0, best.contentSize.height - best.bounds.size.height + best.adjustedContentInset.bottom);
                    CGFloat y = [arg isEqualToString:@"bottom"] ? bottom : ([arg isEqualToString:@"top"] ? -best.adjustedContentInset.top : MIN(bottom, [arg doubleValue]));
                    [best setContentOffset:CGPointMake(0, y) animated:NO];
                }
            }
        }
        NSString *ctrig = @"/var/jb/var/mobile/Library/bm-class-trigger";
        if ([[NSFileManager defaultManager] fileExistsAtPath:ctrig]) {
            [[NSFileManager defaultManager] removeItemAtPath:ctrig error:nil];
            unsigned int n = 0; Class *all = objc_copyClassList(&n);
            NSMutableArray *hits = [NSMutableArray array];
            const char *needles[] = {"Transition", "Presentation", "Animator", "InteractiveDismiss", "MiniPlayer"};
            for (unsigned int i = 0; i < n; i++) {
                const char *nm = class_getName(all[i]);
                BOOL m = NO;
                for (int k = 0; k < 5 && !m; k++) if (strstr(nm, needles[k]) && (strstr(nm, "MusicApplication") || strstr(nm, "MusicCoreUI") || strstr(nm, "NowPlaying") || strstr(nm, "Palette"))) m = YES;
                if (m) [hits addObject:@(nm)];
            }
            free(all);
            [hits sortUsingSelector:@selector(compare:)];
            [[hits componentsJoinedByString:@"\n"] writeToFile:@"/var/jb/var/mobile/Library/bm-classes2.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
            {   // methods and ivars of the pull-down transition classes
                const char *names[] = {"MusicApplication.PalettePresentationAnimationController", "MusicApplication.PalettePresentationInteraction",
                                       "MusicApplication.PaletteContainerView", "MusicApplication.PaletteTabBarController"};
                NSMutableString *o = [NSMutableString string];
                for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
                    Class c = objc_getClass(names[i]);
                    [o appendFormat:@"=== %s super=%@\n", names[i], c ? NSStringFromClass(class_getSuperclass(c)) : @"(missing)"];
                    if (!c) continue;
                    unsigned int n2 = 0;
                    Ivar *iv = class_copyIvarList(c, &n2);
                    for (unsigned int k = 0; k < n2; k++) [o appendFormat:@"  ivar %s\n", ivar_getName(iv[k])];
                    free(iv);
                    Method *ms = class_copyMethodList(c, &n2);
                    for (unsigned int k = 0; k < n2; k++) [o appendFormat:@"  - %s\n", sel_getName(method_getName(ms[k]))];
                    free(ms);
                }
                [o writeToFile:@"/var/jb/var/mobile/Library/bm-methods4.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
        }
        if (![[NSFileManager defaultManager] fileExistsAtPath:trig]) return;
        [[NSFileManager defaultManager] removeItemAtPath:trig error:nil];
        UIWindow *w = nil;
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *c in ((UIWindowScene *)sc).windows) {
                if (c.isKeyWindow) w = c;
                if (!w) w = c;
            }
        }
        NSMutableString *out = [NSMutableString string];
        BMTree(w, 0, out);
        [out writeToFile:@"/var/jb/var/mobile/Library/bettermusic-tree.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    });
    dispatch_resume(t);
    objc_setAssociatedObject([UIApplication class], "bmTrigTimer", (id)t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// ---- iOS 26 look for the app pages: rounder artwork and cards, "Home"/"New" titles ----
static BOOL BMPrefOn(CFStringRef key) {
    id v = BMPrefRaw(key, CFSTR(BM_DOMAIN));
    return v ? [v boolValue] : YES;
}

static void BMStyleArtwork(UIView *v) {
    CGFloat w = v.bounds.size.width, r;
    if (w >= 280) r = 24;          // big Now Playing cover
    else if (w >= 120) r = 12;     // album tiles
    else if (w >= 36) r = 8;       // list thumbnails, mini player
    else return;
    if (v.layer.cornerRadius != r) { v.layer.cornerRadius = r; v.layer.masksToBounds = YES; }
}

static void BMStyleCard(UIView *v, int depth) {
    if (depth > 3) return;
    for (UIView *s in v.subviews) {
        CGFloat r = s.layer.cornerRadius;
        if (r >= 8 && r <= 12 && s.bounds.size.width >= v.bounds.size.width * 0.9 && s.layer.cornerRadius != 20) s.layer.cornerRadius = 20;
        BMStyleCard(s, depth + 1);
    }
}

// ---- Album / playlist / artist page header in the iOS 26 style ----
static void BMCollect(UIView *v, NSString *suffix, NSMutableArray *out, int depth) {
    if ([NSStringFromClass([v class]) hasSuffix:suffix]) [out addObject:v];
    if (depth > 8) return;
    for (UIView *s in v.subviews) BMCollect(s, suffix, out, depth + 1);
}

static UIColor *BMAvgColor(UIImage *img) {
    CGImageRef cg = img.CGImage;
    if (!cg) return nil;
    uint8_t px[4] = {0, 0, 0, 0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, 1, 1, 8, 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
    CGContextDrawImage(ctx, CGRectMake(0, 0, 1, 1), cg);
    CGContextRelease(ctx); CGColorSpaceRelease(cs);
    return [UIColor colorWithRed:px[0] / 255.0 green:px[1] / 255.0 blue:px[2] / 255.0 alpha:1];
}

static UIImage *BMImageFromLayer(CALayer *l, int depth) {
    id c = l.contents;
    if (c && CFGetTypeID((__bridge CFTypeRef)c) == CGImageGetTypeID() && l.bounds.size.width > 60)
        return [UIImage imageWithCGImage:(__bridge CGImageRef)c];
    if (depth > 4) return nil;
    for (CALayer *s in l.sublayers) { UIImage *i = BMImageFromLayer(s, depth + 1); if (i) return i; }
    return nil;
}

static UIImage *BMImageOf(UIView *v, int depth) {
    UIImage *li = BMImageFromLayer(v.layer, 0);
    if (li) return li;
    if ([v isKindOfClass:[UIImageView class]] && ((UIImageView *)v).image && v.bounds.size.width > 100) return ((UIImageView *)v).image;
    id c = v.layer.contents;
    if (c && CFGetTypeID((__bridge CFTypeRef)c) == CGImageGetTypeID() && v.bounds.size.width > 100)
        return [UIImage imageWithCGImage:(__bridge CGImageRef)c];
    if (depth > 3) return nil;
    for (UIView *s in v.subviews) { UIImage *i = BMImageOf(s, depth + 1); if (i) return i; }
    return nil;
}

__attribute__((unused)) static void BMStyleBigButton(UIView *btn, BOOL primary) {
    CGFloat h = btn.bounds.size.height;
    btn.tintColor = primary ? [UIColor blackColor] : [UIColor whiteColor];
    NSMutableArray *bgs = [NSMutableArray array];
    BMCollect(btn, @"BackgroundView", bgs, 0);
    for (UIView *bg in bgs) {
        bg.backgroundColor = primary ? [UIColor whiteColor] : [UIColor colorWithWhite:1 alpha:0.18];
        bg.layer.cornerRadius = h / 2;
        bg.layer.masksToBounds = YES;
    }
    NSMutableArray *labels = [NSMutableArray array];
    BMCollect(btn, @"Label", labels, 0);
    for (UIView *l in labels) if ([l isKindOfClass:[UILabel class]]) ((UILabel *)l).textColor = primary ? [UIColor blackColor] : [UIColor whiteColor];
    NSMutableArray *imgs = [NSMutableArray array];
    BMCollect(btn, @"ImageView", imgs, 0);
    for (UIView *i in imgs) i.tintColor = primary ? [UIColor blackColor] : [UIColor whiteColor];
}

static UIView *BMNavPlus(UIView *from) {
    NSMutableArray *bars = [NSMutableArray array];
    BMCollect(from.window, @"NavigationBar", bars, 0);
    for (UIView *bar in bars) {
        NSMutableArray *sb = [NSMutableArray array];
        BMCollect(bar, @"SymbolButton", sb, 0);
        NSMutableArray *small = [NSMutableArray array];
        for (UIView *b in sb) if (fabs(b.bounds.size.width - 28) < 1) [small addObject:b];
        [small sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
            return [@([a.superview convertPoint:a.frame.origin toView:nil].x) compare:@([b.superview convertPoint:b.frame.origin toView:nil].x)];
        }];
        if (small.count >= 2) return small.firstObject;
    }
    return nil;
}

static void BMForward(UIView *target) {
    if (![target isKindOfClass:[UIControl class]]) return;
    UIControl *c = (UIControl *)target;
    [c sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];
    [c sendActionsForControlEvents:UIControlEventTouchUpInside];
}

static UIButton *BMRowButton(NSString *sym, NSString *title, BOOL primary, CGFloat pt) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    if (primary) b.backgroundColor = [UIColor whiteColor]; else BMGlassStyle(b);
    UIColor *fg = primary ? [UIColor blackColor] : [UIColor whiteColor];
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:pt weight:UIImageSymbolWeightBold];
    [b setImage:[[UIImage systemImageNamed:sym withConfiguration:cfg] imageWithTintColor:fg renderingMode:UIImageRenderingModeAlwaysOriginal] forState:UIControlStateNormal];
    if (title) {
        [b setTitle:[@" " stringByAppendingString:title] forState:UIControlStateNormal];
        [b setTitleColor:fg forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    }
    b.layer.masksToBounds = YES;
    return b;
}

static void BMBuildActionRow(UIView *playBtn, UIView *shuffleBtn) {
    UIView *container = playBtn.superview;
    if (!container || [container viewWithTag:0xB8]) return;
    UIView *row = [[UIView alloc] initWithFrame:container.bounds];
    row.tag = 0xB8;
    row.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    CGFloat W = container.bounds.size.width, H = container.bounds.size.height;
    UIButton *shuf = BMRowButton(@"shuffle", nil, NO, 18);
    UIButton *play = BMRowButton(@"play.fill", @"Play", YES, 18);
    UIButton *plus = BMRowButton(@"plus", nil, NO, 20);
    shuf.frame = CGRectMake(0, 0, H, H);
    plus.frame = CGRectMake(W - H, 0, H, H);
    play.frame = CGRectMake(H + 12, 0, W - 2 * H - 24, H);
    shuf.autoresizingMask = UIViewAutoresizingFlexibleRightMargin;
    plus.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    play.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    for (UIButton *b in @[shuf, play, plus]) b.layer.cornerRadius = H / 2;
    __weak UIView *wp = playBtn, *ws = shuffleBtn;
    [shuf addAction:[UIAction actionWithHandler:^(UIAction *a) { BMForward(ws); }] forControlEvents:UIControlEventTouchUpInside];
    [play addAction:[UIAction actionWithHandler:^(UIAction *a) { BMForward(wp); }] forControlEvents:UIControlEventTouchUpInside];
    __weak UIView *wc = container;
    [plus addAction:[UIAction actionWithHandler:^(UIAction *a) { BMForward(BMNavPlus(wc)); }] forControlEvents:UIControlEventTouchUpInside];
    [row addSubview:shuf]; [row addSubview:play]; [row addSubview:plus];
    [container addSubview:row];
}

static void BMClearCell(UICollectionViewCell *cell) {
    cell.backgroundColor = [UIColor clearColor];
    cell.backgroundView = nil;
    cell.selectedBackgroundView = nil;
    if ([cell respondsToSelector:@selector(setAutomaticallyUpdatesBackgroundConfiguration:)])
        cell.automaticallyUpdatesBackgroundConfiguration = NO;    // otherwise the app puts its grey group background back on every update
    cell.contentView.backgroundColor = [UIColor clearColor];
    if (![cell respondsToSelector:@selector(setBackgroundConfiguration:)]) return;
    // Setting a background configuration re-lays the cell out, which calls us again. Apply it asynchronously and at
    // most twice a second per cell so this can never become a layout loop (it froze Music once).
    NSNumber *last = objc_getAssociatedObject(cell, "bmCfgAt");
    CFTimeInterval now = CACurrentMediaTime();
    if (last && now - last.doubleValue < 0.5) return;
    objc_setAssociatedObject(cell, "bmCfgAt", @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UICollectionViewCell *wc = cell;
    dispatch_async(dispatch_get_main_queue(), ^{
        UICollectionViewCell *c = wc;
        if (c) c.backgroundConfiguration = [UIBackgroundConfiguration clearConfiguration];
    });
}

// The album page is a vertical stack of separate section views inside one scroll view; the tint lives on that scroll view.
static UIScrollView *BMStackScroll(UIView *v) {
    // The page has stacks inside stacks (header and tracks in the outer one, shelves in an inner one). Use the OUTERMOST,
    // which is the one that carries the tint, so every section below counts as part of the tinted page.
    UIScrollView *outer = nil;
    for (UIView *u = v; u; u = u.superview)
        if ([u isKindOfClass:[UIScrollView class]] && [NSStringFromClass([u class]) containsString:@"VerticalStackViewController"]) outer = (UIScrollView *)u;
    return outer;
}
static BOOL BMIsTinted(UIView *v) {
    UIScrollView *sv = BMStackScroll(v);
    return sv && [objc_getAssociatedObject(sv, "bmTinted") boolValue];
}

static void BMHideSystemBackgrounds(UIView *v, int depth) {
    if ([NSStringFromClass([v class]) isEqualToString:@"_UISystemBackgroundView"]) { v.alpha = 0; v.hidden = YES; return; }
    if (depth > 4) return;
    for (UIView *s in v.subviews) BMHideSystemBackgrounds(s, depth + 1);
}

// Make every cell, footer and section background on the album page see-through so the tint shows all the way down.
static void BMClearCollection(UICollectionView *cv) {
    for (UICollectionViewCell *cell in cv.visibleCells) { BMClearCell(cell); BMHideSystemBackgrounds(cell, 0); }
    for (UIView *v in cv.subviews) {
        if ([v isKindOfClass:[UICollectionViewCell class]]) continue;
        NSString *cn = NSStringFromClass([v class]);
        if ([cn hasPrefix:@"_UI"] || [cn hasPrefix:@"UIIndex"]) continue;       // scroll indicators etc.
        if (v == cv.backgroundView) continue;
        v.backgroundColor = [UIColor clearColor];
        BMHideSystemBackgrounds(v, 0);
        for (UIView *s in v.subviews) if ([s isKindOfClass:[UICollectionViewCell class]] || [s isMemberOfClass:[UIView class]]) s.backgroundColor = [UIColor clearColor];
    }
}

static void BMStyleDetailHeader(UIView *hdr) {
    {   // Albums with motion artwork use a tall full-width video header: leave Apple's layout alone there.
        NSMutableArray *probe = [NSMutableArray array];
        BMCollect(hdr, @"ArtworkComponentImageView", probe, 0);
        for (UIView *a in probe) if (a.bounds.size.width > 300) return;
    }
    hdr.tintColor = [UIColor whiteColor];                       // artist name, MORE, icons: white instead of red
    // Play (first) and Shuffle (second) buttons
    NSMutableArray *btns = [NSMutableArray array];
    BMCollect(hdr, @"SymbolButton", btns, 0);
    NSMutableArray *big = [NSMutableArray array];
    for (UIView *b in btns) if (b.bounds.size.width > 100 && b.bounds.size.height > 30) [big addObject:b];
    [big sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) { return [@(a.frame.origin.x) compare:@(b.frame.origin.x)]; }];
    if (big.count >= 2) {
        BMBuildActionRow(big[0], big[1]);
        for (UIView *orig in @[big[0], big[1]]) { orig.alpha = 0; orig.hidden = YES; }   // our row replaces these two; hidden so the app cannot fade them back in
    }
    // info line: "R&B/SOUL · 2026" -> "R&B/Soul · 2026", a little larger, like iOS 26
    NSMutableArray *labs = [NSMutableArray array];
    BMCollect(hdr, @"UILabel", labs, 0);
    for (UIView *lv in labs) {
        UILabel *lab = (UILabel *)lv;
        if ([lab isKindOfClass:[UILabel class]] && [lab.text containsString:@"\u00B7"] && lab.font.pointSize <= 13) {
            NSString *nt = [[lab.text lowercaseString] capitalizedString];
            if (![lab.text isEqualToString:nt]) lab.text = nt;
            if (lab.font.pointSize != 13) lab.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
            NSMutableArray *badges = [NSMutableArray array];
            BMCollect(hdr, @"BadgeListView", badges, 0);
            if (badges.count && ((UIView *)badges.firstObject).subviews.count && ![lab.text containsString:@"Lossless"]) {
                NSMutableAttributedString *as = [[NSMutableAttributedString alloc] initWithString:[lab.text stringByAppendingString:@" \u00B7 "]
                    attributes:@{NSFontAttributeName: lab.font, NSForegroundColorAttributeName: lab.textColor ?: [UIColor grayColor]}];
                NSTextAttachment *att = [[NSTextAttachment alloc] init];
                UIImage *wave = [[UIImage systemImageNamed:@"waveform"] imageWithTintColor:(lab.textColor ?: [UIColor grayColor]) renderingMode:UIImageRenderingModeAlwaysOriginal];
                att.image = wave;
                att.bounds = CGRectMake(0, -2, 15, 13);
                [as appendAttributedString:[NSAttributedString attributedStringWithAttachment:att]];
                [as appendAttributedString:[[NSAttributedString alloc] initWithString:@" Lossless"
                    attributes:@{NSFontAttributeName: lab.font, NSForegroundColorAttributeName: lab.textColor ?: [UIColor grayColor]}]];
                lab.attributedText = as;
            }
            for (UIView *bl in badges) bl.alpha = 0;
        }
    }

    // Cover-colored gradient behind the top of the page
    NSMutableArray *arts = [NSMutableArray array];
    BMCollect(hdr, @"ArtworkComponentImageView", arts, 0);
    UIImage *img = nil;
    for (UIView *a in arts) { img = BMImageOf(a, 0); if (img) break; }

    // Whole-page tint (iOS 26): a gradient behind the collection view, with the header and cells see-through.
    UICollectionView *cv = nil;
    for (UIView *u = hdr.superview; u; u = u.superview) if ([u isKindOfClass:[UICollectionView class]]) { cv = (UICollectionView *)u; break; }
    if (cv) {
        UIView *bgv = cv.backgroundView;
        if (!bgv || bgv.tag != 0xB9) {
            bgv = [[UIView alloc] initWithFrame:cv.bounds];
            bgv.tag = 0xB9;
            bgv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            bgv.userInteractionEnabled = NO;
            cv.backgroundView = bgv;
        }
        cv.backgroundColor = [UIColor clearColor];
        CAGradientLayer *gl = (CAGradientLayer *)bgv.layer.sublayers.firstObject;
        if (![gl isKindOfClass:[CAGradientLayer class]]) { gl = [CAGradientLayer layer]; [bgv.layer addSublayer:gl]; }
        UIColor *avg = img ? BMAvgColor(img) : nil;
        if (avg) {
            CGFloat r = 0, g = 0, bl = 0, al = 0;
            [avg getRed:&r green:&g blue:&bl alpha:&al];
            NSString *key = [NSString stringWithFormat:@"%.2f,%.2f,%.2f", r, g, bl];       // actual cover color, not an address
            if (![objc_getAssociatedObject(bgv, "bmColor") isEqualToString:key]) {
                objc_setAssociatedObject(bgv, "bmColor", key, OBJC_ASSOCIATION_COPY_NONATOMIC);
                CGFloat h = 0, sat = 0, b = 0;
                [avg getHue:&h saturation:&sat brightness:&b alpha:&al];
                UIColor *top = [UIColor colorWithHue:h saturation:MIN(0.80, sat * 1.25) brightness:MIN(0.34, MAX(0.2, b * 0.42)) alpha:1];
                CGFloat topB = MIN(0.34, MAX(0.2, b * 0.42));
                UIColor *bot = [UIColor colorWithHue:h saturation:MIN(0.80, sat * 1.25) brightness:topB * 0.82 alpha:1];
                // accent for the info line / playing track: a light, soft version of the same hue
                UIColor *acc = [UIColor colorWithHue:h saturation:MIN(0.45, sat * 0.8) brightness:0.92 alpha:0.9];
                objc_setAssociatedObject(bgv, "bmAccent", acc, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [CATransaction begin]; [CATransaction setDisableActions:YES];
                gl.colors = @[(id)top.CGColor, (id)bot.CGColor];
                [CATransaction commit];
            }
            bgv.hidden = NO;
        } else if (!objc_getAssociatedObject(bgv, "bmColor")) {
            bgv.hidden = YES;                                     // cover not loaded yet: show nothing rather than a stale tint
        }
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        gl.frame = bgv.bounds;
        [CATransaction commit];
        UIScrollView *stack = BMStackScroll(hdr);
        if (stack && gl.colors) {
            objc_setAssociatedObject(stack, "bmTinted", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            UIView *tv = [stack viewWithTag:0xBB];
            if (!tv) {
                tv = [[UIView alloc] init];
                tv.tag = 0xBB;
                tv.userInteractionEnabled = NO;
                [stack insertSubview:tv atIndex:0];
                [tv.layer addSublayer:[CAGradientLayer layer]];
            }
            objc_setAssociatedObject(stack, "bmTop", [UIColor colorWithCGColor:(__bridge CGColorRef)gl.colors.firstObject], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(stack, "bmBot", [UIColor colorWithCGColor:(__bridge CGColorRef)gl.colors.lastObject], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            BMLayoutTint(stack);
            bgv.hidden = YES;                                      // the stack-wide tint replaces the per-list one
            if (!objc_getAssociatedObject(stack, "bmNavTimer")) {  // nav bar fades with scrolling; scrolling alone triggers no layout, so poll lightly
                __weak UIScrollView *ws = stack;
                NSTimer *t = [NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *tm) {
                    UIScrollView *sv2 = ws;
                    if (!sv2) { [tm invalidate]; gTintedActive = NO; return; }
                    gTintedActive = (sv2.window != nil);
                    if (!sv2.window) return;
                    BMFadeNavBackground(sv2);
                    static int tick; if (++tick % 5 == 0) BMSweepTinted(sv2, 0);
                }];
                [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
                objc_setAssociatedObject(stack, "bmNavTimer", t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
        UIColor *accent = objc_getAssociatedObject(bgv, "bmAccent");
        cv.tintColor = accent ?: [UIColor whiteColor];                 // playing-track highlight, MORE, links
        if (accent) {
            NSMutableArray *info = [NSMutableArray array];
            BMCollect(hdr, @"UILabel", info, 0);
            for (UIView *lv in info) {
                UILabel *lab = (UILabel *)lv;
                if ([lab isKindOfClass:[UILabel class]] && lab.attributedText.length && [lab.attributedText.string containsString:@"\u00B7"]) {
                    NSMutableAttributedString *m = [lab.attributedText mutableCopy];
                    [m addAttribute:NSForegroundColorAttributeName value:accent range:NSMakeRange(0, m.length)];
                    lab.attributedText = m;
                }
            }
        }
        // The cover often finishes loading after the first layout: look again shortly.
        if (!img && !objc_getAssociatedObject(hdr, "bmRetry")) {
            objc_setAssociatedObject(hdr, "bmRetry", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            __weak UIView *wh = hdr;
            for (NSNumber *d in @[@0.4, @1.0, @2.0]) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    UIView *h2 = wh; if (h2) [h2 setNeedsLayout];
                });
            }
        }
        for (UIView *u = hdr; u && u != cv; u = u.superview) u.backgroundColor = [UIColor clearColor];
        for (UICollectionViewCell *cell in cv.visibleCells) BMClearCell(cell);
    }
}

static void BMApplyAvatarColor(CAGradientLayer *g) {
    id v = BMPrefRaw(CFSTR("AvatarColor"), CFSTR(BM_DOMAIN));
    NSInteger i = [v respondsToSelector:@selector(integerValue)] ? [v integerValue] : 0;
    // top, bottom
    static const CGFloat cols[][6] = {
        {0.42, 0.42, 0.45, 0.22, 0.22, 0.25},   // 0 grey (default)
        {0.30, 0.26, 0.62, 0.13, 0.11, 0.30},   // 1 purple
        {0.20, 0.45, 0.85, 0.08, 0.20, 0.45},   // 2 blue
        {0.90, 0.28, 0.32, 0.50, 0.10, 0.14},   // 3 red
        {0.25, 0.70, 0.45, 0.10, 0.35, 0.20},   // 4 green
        {0.95, 0.60, 0.20, 0.55, 0.28, 0.08},   // 5 orange
        {0.92, 0.38, 0.65, 0.52, 0.14, 0.34},   // 6 pink
    };
    if (i < 0 || i > 6) i = 0;
    g.colors = @[(id)[UIColor colorWithRed:cols[i][0] green:cols[i][1] blue:cols[i][2] alpha:1].CGColor,
                 (id)[UIColor colorWithRed:cols[i][3] green:cols[i][4] blue:cols[i][5] alpha:1].CGColor];
}

static void BMStyleAvatar(UIView *bar) {
    NSMutableArray *titles = [NSMutableArray array];
    BMCollect(bar, @"_UINavigationBarLargeTitleView", titles, 0);
    for (UIView *t in titles) {
        NSMutableArray *btns = [NSMutableArray array];
        BMCollect(t, @"UIButton", btns, 0);
        for (UIView *b in btns) {
            if (fabs(b.bounds.size.width - 40) > 1 || fabs(b.bounds.size.height - 40) > 1) continue;
            UIView *existing = [b viewWithTag:0xB7];
            if (existing) {
                for (CALayer *l in existing.layer.sublayers) if ([l.name isEqualToString:@"bmAvatarGrad"]) BMApplyAvatarColor((CAGradientLayer *)l);
                continue;
            }
            NSString *name = [UIDevice currentDevice].name;
            NSString *ini = name.length ? [[name substringToIndex:1] uppercaseString] : nil;
            UIView *c = [[UIView alloc] initWithFrame:b.bounds];
            c.tag = 0xB7;
            c.userInteractionEnabled = NO;
            c.layer.cornerRadius = 20;
            c.clipsToBounds = YES;
            CAGradientLayer *g = [CAGradientLayer layer];
            g.frame = c.bounds;
            g.name = @"bmAvatarGrad";
            g.startPoint = CGPointMake(0.2, 0); g.endPoint = CGPointMake(0.8, 1);
            [c.layer addSublayer:g];
            BMApplyAvatarColor(g);
            UILabel *l = [[UILabel alloc] initWithFrame:c.bounds];
            l.textAlignment = NSTextAlignmentCenter;
            l.textColor = [UIColor whiteColor];
            l.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
            l.text = ini ?: @"";
            [c addSubview:l];
            [b addSubview:c];
        }
    }
}

static void BMStyleNavBar(UIView *bar) {
    BMStyleAvatar(bar);
    NSMutableArray *backs = [NSMutableArray array];
    BMCollect(bar, @"_UIButtonBarButton", backs, 0);
    BOOL pushed = NO;
    for (UIView *b in backs) {
        NSMutableArray *masks = [NSMutableArray array];
        BMCollect(b, @"_UIBackButtonMaskView", masks, 0);
        if (!masks.count) continue;                               // not a back button
        pushed = YES;
        UIView *circle = [b viewWithTag:0xB6];
        if (!circle) {
            circle = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 40, 40)];
            circle.tag = 0xB6;
            circle.userInteractionEnabled = NO;
            circle.layer.cornerRadius = 20;
            [b insertSubview:circle atIndex:0];
        }
        // The back button is a fixed 44x44 area whose arrow is centred at (22,22): centre the 40pt circle there.
        // (Reading the arrow's frame here is unreliable: before layout it is zero, which put the circle in the screen corner.)
        circle.frame = CGRectMake(2, 2, 40, 40);
        BMGlassStyle(circle);
        for (UIView *m in masks) for (UIView *u in m.subviews)
            if ([u isKindOfClass:[UIImageView class]]) u.transform = CGAffineTransformMakeScale(0.62, 0.62);   // 28pt tall chevron -> ~17pt like the other two icons
    }
    bar.tintColor = pushed ? [UIColor whiteColor] : nil;          // white icons on detail pages only
    if (pushed) {
        NSMutableArray *stacks = [NSMutableArray array];
        BMCollect(bar, @"_UIButtonBarStackView", stacks, 0);
        for (UIView *st in stacks) {
            NSMutableArray *sbs = [NSMutableArray array];
            BMCollect(st, @"SymbolButton", sbs, 0);
            if (sbs.count < 2) continue;                          // only the right-hand button group
            st.tintColor = [UIColor whiteColor];
            NSMutableArray *ims = [NSMutableArray array];
            BMCollect(st, @"ImageView", ims, 0);
            for (UIView *iv in ims) iv.tintColor = [UIColor whiteColor];
            if (![st viewWithTag:0xBA]) {
                UIView *cap = [[UIView alloc] initWithFrame:CGRectMake(-8, 2, st.bounds.size.width + 16, 40)];
                cap.tag = 0xBA;
                cap.userInteractionEnabled = NO;
                cap.layer.cornerRadius = 20;
                BMGlassStyle(cap);
                [st insertSubview:cap atIndex:0];
            }
            NSMutableArray *bgs = [NSMutableArray array];
            BMCollect(st, @"BackgroundView", bgs, 0);              // the separate circles behind each button (icons stay)
            for (UIView *m in bgs) m.alpha = 0;
        }
    }
}

%hook UICollectionView
- (void)layoutSubviews {
    %orig;
    UICollectionView *cv = (UICollectionView *)self;
    if (!BMEnabled() || !BMPrefOn(CFSTR("DetailStyle"))) return;
    if (cv.backgroundView.tag == 0xB9 || BMIsTinted(cv)) {
        UIScrollView *stack = BMStackScroll(cv);
        if (stack) {
            cv.backgroundColor = [UIColor clearColor];
            if (cv.backgroundView.tag != 0xB9) cv.backgroundView = nil;
            for (UIView *u = cv.superview; u && u != stack; u = u.superview) u.backgroundColor = [UIColor clearColor];
            BMLayoutTint(stack);
            BMFadeNavBackground(stack);
            NSNumber *last = objc_getAssociatedObject(stack, "bmPanelsAt");
            CFTimeInterval now = CACurrentMediaTime();
            if (!last || now - last.doubleValue > 0.4) {            // dark panels that are not inside any list (section backgrounds)
                objc_setAssociatedObject(stack, "bmPanelsAt", @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                BMClearDarkPanels(stack, 0);
            }
        }
        BMClearCollection(cv);
    }
}
%end

// Opaque black / dark-grey panels (section backgrounds, shelf containers) become see-through so the tint shows.
static void BMClearNested(UIView *v, int depth) {
    if (depth > 5) return;
    for (UIView *c in v.subviews) {
        if ([c isKindOfClass:[UIScrollView class]]) {
            c.backgroundColor = [UIColor clearColor];
            if ([c isKindOfClass:[UICollectionView class]]) {
                UICollectionView *nested = (UICollectionView *)c;
                nested.backgroundView = nil;
                for (UICollectionViewCell *cell in nested.visibleCells) BMClearCell(cell);
            }
        }
        BMClearNested(c, depth + 1);
    }
}

static void BMClearDarkPanels(UIView *v, int depth) {
    if (depth > 4) return;
    for (UIView *c in v.subviews) {
        if ([c isKindOfClass:[UIImageView class]] || [c isKindOfClass:[UILabel class]] || [c isKindOfClass:[UIButton class]]) continue;
        CGFloat w = 0, a = 0;
        UIColor *bc = c.backgroundColor;
        if (bc) bc = [bc resolvedColorWithTraitCollection:c.traitCollection];        // system colors change with dark mode
        if (bc && [bc getWhite:&w alpha:&a] && w < 0.3 && a > 0.9 && c.bounds.size.width > 100) c.backgroundColor = [UIColor clearColor];
        BMClearDarkPanels(c, depth + 1);
    }
}

%hook UICollectionReusableView
- (void)layoutSubviews {
    %orig;
    UIView *me = (UIView *)self;
    UIView *sv = me.superview;
    if (![sv isKindOfClass:[UICollectionView class]]) return;
    UICollectionView *cv = (UICollectionView *)sv;
    if (!BMEnabled() || !BMPrefOn(CFSTR("DetailStyle"))) return;
    if (cv.backgroundView.tag != 0xB9 && !BMIsTinted(cv)) return;
    me.backgroundColor = [UIColor clearColor];
    BMHideSystemBackgrounds(me, 0);
    if ([me isKindOfClass:[UICollectionViewCell class]]) BMClearCell((UICollectionViewCell *)me);
    BMClearDarkPanels(me, 0);
    BMClearNested(me, 0);
}
%end

#import <AVFoundation/AVFoundation.h>

static void BMLogVideo(NSString *what, NSURL *u) {
    if (!u || !BMDebugOn()) return;
    NSString *ext = u.absoluteString.lowercaseString;
    if (![ext containsString:@".m3u8"] && ![ext containsString:@".mp4"] && ![ext containsString:@".mov"] && ![ext containsString:@"video"]) return;
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", what, u.absoluteString];
    NSString *path = @"/var/jb/var/mobile/Library/bm-video.log";
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!h) { [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]; h = [NSFileHandle fileHandleForWritingAtPath:path]; }
    [h seekToEndOfFile]; [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile];
}

%hook AVURLAsset
- (instancetype)initWithURL:(NSURL *)URL options:(NSDictionary *)o {
    BMLogVideo(@"asset", URL);
    return %orig;
}
%end

static UIImage *BMCapsule(CGFloat alpha);
static BOOL gLyricsOn;                 // lyrics screen visible: the volume row must stay hidden
static __weak UISlider *gVolSlider;

// Root-cause fix for grey coming back while scrolling: inside the tinted page, any dark background the app tries to
// set (on lists, rows, headers, containers) is replaced by clear at the moment it is set.
%hook UIView
- (void)setBackgroundColor:(UIColor *)c {
    if (c && gTintedActive) {
        UIView *me = (UIView *)self;
        BOOL skip = [me isKindOfClass:[UIImageView class]] || [me isKindOfClass:[UILabel class]] || [me isKindOfClass:[UIButton class]]
                 || [me isKindOfClass:[UIControl class]] || [me isKindOfClass:[UIVisualEffectView class]];
        if (!skip) {
            NSString *cn = NSStringFromClass([me class]);
            BOOL cand = [me isKindOfClass:[UIScrollView class]] || [me isKindOfClass:[UICollectionReusableView class]]
                     || [cn isEqualToString:@"UIView"] || [cn hasSuffix:@"TintColorObservingView"] || [cn hasPrefix:@"_UISystemBackground"];
            if (cand) {
                CGFloat w = 0, a = 0;
                UIColor *r = [c resolvedColorWithTraitCollection:me.traitCollection];
                // Rows, headers and Apple's background views are created and coloured BEFORE they are attached to the page, so
                // for those the tinted-page test cannot be used (it caused a one-frame grey flash while scrolling).
                BOOL early = [me isKindOfClass:[UICollectionReusableView class]] || [cn hasPrefix:@"_UISystemBackground"];
                if ([r getWhite:&w alpha:&a] && w < 0.3 && a > 0.5 && (early || BMIsTinted(me))) c = [UIColor clearColor];
            }
        }
    }
    %orig(c);
}
%end

// Safety net: every quarter second, walk the whole tinted page and clear anything dark that slipped through.
static void BMSweepTinted(UIView *v, int depth) {
    if (depth > 16) return;
    for (UIView *c in v.subviews) {
        if ([c isKindOfClass:[UIImageView class]] || [c isKindOfClass:[UILabel class]] || [c isKindOfClass:[UIButton class]]) continue;
        if (c.tag == 0xBB || c.tag == 0xB9) continue;                       // my own tint views
        NSString *cn = NSStringFromClass([c class]);
        if ([cn isEqualToString:@"_UISystemBackgroundView"]) { c.alpha = 0; c.hidden = YES; continue; }
        UIColor *bc = c.backgroundColor;
        if (bc) {
            CGFloat w = 0, a = 0;
            UIColor *r = [bc resolvedColorWithTraitCollection:c.traitCollection];
            if ([r getWhite:&w alpha:&a] && w < 0.3 && a > 0.5 && c.bounds.size.width > 60 && c.bounds.size.height > 20) c.backgroundColor = [UIColor clearColor];
        }
        if ([c isKindOfClass:[UICollectionViewCell class]]) BMClearCell((UICollectionViewCell *)c);
        BMSweepTinted(c, depth + 1);
    }
}

%group SysBG
%hook BMSysBG
- (void)layoutSubviews {
    %orig;
    if (gTintedActive) { UIView *me = (UIView *)self; me.alpha = 0; me.hidden = YES; }
}
- (void)didMoveToSuperview {
    %orig;
    if (gTintedActive) { UIView *me = (UIView *)self; me.alpha = 0; me.hidden = YES; }
}
%end
%end

%group Styling

%hook BMArtView
- (void)layoutSubviews {
    %orig;
    if (BMEnabled() && BMPrefOn(CFSTR("CardRounding"))) BMStyleArtwork((UIView *)self);
}
%end

%hook BMSongCell
- (void)layoutSubviews {
    %orig;
    if (BMEnabled() && BMPrefOn(CFSTR("DetailStyle"))) BMClearCell((UICollectionViewCell *)self);
}
%end

%hook BMDetailHeader
- (void)layoutSubviews {
    %orig;
    if (BMEnabled() && BMPrefOn(CFSTR("DetailStyle"))) BMStyleDetailHeader((UIView *)self);
}
%end

%hook BMNavBar
- (void)layoutSubviews {
    %orig;
    if (BMEnabled() && BMPrefOn(CFSTR("DetailStyle"))) BMStyleNavBar((UIView *)self);
}
%end

%hook BMPosterCell
- (void)layoutSubviews {
    %orig;
    if (BMEnabled() && BMPrefOn(CFSTR("CardRounding"))) BMStyleCard((UIView *)self, 0);
}
%end
%end

%hook UILabel
- (void)setText:(NSString *)t {
    if (t && BMEnabled() && BMPrefOn(CFSTR("TabRename"))) {
        if ([t isEqualToString:@"Listen Now"]) t = @"Home";
        else if ([t isEqualToString:@"Browse"]) t = @"New";
    }
    %orig(t);
}
%end

%hook UILabel
- (void)setAttributedText:(NSAttributedString *)at {
    if (at && BMEnabled() && BMPrefOn(CFSTR("TabRename"))) {
        NSString *m = [at.string isEqualToString:@"Listen Now"] ? @"Home" : ([at.string isEqualToString:@"Browse"] ? @"New" : nil);
        if (m) {
            NSMutableAttributedString *n = [[NSMutableAttributedString alloc] initWithString:m attributes:at.length ? [at attributesAtIndex:0 effectiveRange:NULL] : nil];
            at = n;
        }
    }
    %orig(at);
}
%end

// ---- App-only scale: lay the Music window out on a bigger "screen", then scale it down to fit ----
static double BMPrefAppScale(void) {
    id v = BMPrefRaw(CFSTR("AppScale"), CFSTR(BM_DOMAIN));
    double sc = [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 0.9;
    return MAX(0.7, MIN(1.0, sc));
}

static void BMApplyAppScale(void) {
    double sc = BMEnabled() ? BMPrefAppScale() : 1.0;
    CGRect screen = UIScreen.mainScreen.bounds;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (![NSStringFromClass([w class]) hasPrefix:@"MusicApplication"]) continue;
            NSNumber *cur = objc_getAssociatedObject(w, "bmScale");
            if (cur && fabs(cur.doubleValue - sc) < 0.001) continue;
            objc_setAssociatedObject(w, "bmScale", @(sc), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            w.transform = CGAffineTransformIdentity;
            w.bounds = CGRectMake(0, 0, screen.size.width / sc, screen.size.height / sc);
            w.center = CGPointMake(screen.size.width / 2, screen.size.height / 2);
            w.transform = CGAffineTransformMakeScale(sc, sc);
        }
    }
}

static void BMStartScaleWatcher(void) {
    BMApplyAppScale();
    NSTimer *t = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *tm) {
        @try { BMApplyAppScale(); } @catch (NSException *e) {}
    }];
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
}

static void BMInitStyling(void) {
    Class art = objc_getClass("MusicApplication.ArtworkComponentImageView");
    Class poster = objc_getClass("MusicApplication.PosterCell");
    Class detail = objc_getClass("MusicApplication.DetailHeader");
    Class nav = objc_getClass("MusicApplication.NavigationBar");
    Class song = objc_getClass("MusicApplication.SongCell");
    if (!art || !poster || !detail || !nav || !song) { NSLog(@"[BetterMusic] styling classes missing"); return; }
    Class sysbg = objc_getClass("_UISystemBackgroundView");
    if (sysbg) %init(SysBG, BMSysBG = sysbg);
    %init(Styling, BMArtView = art, BMPosterCell = poster, BMDetailHeader = detail, BMNavBar = nav, BMSongCell = song);
    NSLog(@"[BetterMusic] styling hooks installed");
}

__attribute__((constructor)) static void BetterMusicLoaded(void) {
    BMCheckSafeMode();
    %init;
    NSLog(@"[BetterMusic] loaded");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ if (BMDebugOn()) BMStartTriggerWatcher(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (BMSafeMode()) return; BMInitStyling(); BMStartScaleWatcher(); });
}

static BOOL BMTabGlassOn(void) {
    id v = BMPrefRaw(CFSTR(BM_KEY_TABGLASS), CFSTR(BM_DOMAIN));
    return v ? [v boolValue] : NO;                           // off by default: the stock tab bar stays as Apple made it
}

// Phase 2 recon: dump the mini player's superview chain and subviews once.
static void BMDumpViews(UIView *v, int depth, NSMutableString *out) {
    [out appendFormat:@"%*s%@ frame=%@ bg=%@\n", depth * 2, "", NSStringFromClass([v class]),
        NSStringFromCGRect(v.frame), v.backgroundColor];
    if (depth > 9) return;
    for (UIView *s in v.subviews) BMDumpViews(s, depth + 1, out);
}

// Hide the full-width gray blur and float a glass capsule behind the mini player.
// No frames are changed, so UIKit layout is untouched.
// Round the small artwork so its corners stay inside the capsule's curve (layer only, no layout).
static void BMRoundArtwork(UIView *v, int depth) {
    if ([NSStringFromClass([v class]) hasSuffix:@"NowPlayingContentView"]) {
        v.layer.cornerRadius = 10;
        v.layer.masksToBounds = YES;
        return;
    }
    if (depth > 3) return;
    for (UIView *s in v.subviews) BMRoundArtwork(s, depth + 1);
}

static void BMStyleMiniPlayer(UIView *palette) {
    UIVisualEffectView *fx = nil;
    for (UIView *v in palette.subviews)
        if ([v isKindOfClass:[UIVisualEffectView class]]) { fx = (UIVisualEffectView *)v; break; }
    if (!fx) return;
    for (UIView *v in fx.subviews)
        if (![NSStringFromClass([v class]) isEqualToString:@"_UIVisualEffectContentView"]) v.hidden = YES;
    UIView *container = fx.contentView.subviews.firstObject;
    if (!container || [container viewWithTag:0xB4]) return;
    // Fixed 56pt capsule, stretching only in width. (It used to stretch in height too: while the full-screen player is
    // pulled down the container briefly becomes much taller, and the glass became a big blurry block over the dock.)
    BMGlassView *g = [[BMGlassView alloc] initWithFrame:CGRectMake(10, 4, container.bounds.size.width - 20, 56)];
    g.tag = 0xB4;
    g.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [container insertSubview:g atIndex:0];
    BMRoundArtwork(container, 0);
}

// iOS 26 style controls: no resting knob on the progress bar or volume slider, rounded tracks.
// Make a track a thick capsule: edit its height constraint, fall back to a vertical scale.
static void BMThickTrack(UIView *track, UIView *owner, CGFloat h) {
    BOOL done = NO;
    NSMutableArray *hosts = [NSMutableArray arrayWithObjects:owner, track, nil];
    if (track.superview) [hosts addObject:track.superview];
    for (UIView *host in hosts)
        for (NSLayoutConstraint *c in host.constraints)
            if (c.firstItem == track && c.firstAttribute == NSLayoutAttributeHeight && !c.secondItem) { c.constant = h; done = YES; }
    if (!done && track.bounds.size.height > 0.5) track.transform = CGAffineTransformMakeScale(1, h / track.bounds.size.height);
    track.layer.cornerRadius = h / 2;
    track.clipsToBounds = YES;
}

__attribute__((unused)) static UIImage *BMCapsule(CGFloat alpha) {
    CGSize sz = CGSizeMake(16, 8);
    UIGraphicsBeginImageContextWithOptions(sz, NO, 0);
    [[UIColor colorWithWhite:1 alpha:alpha] setFill];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, sz.width, sz.height) cornerRadius:4] fill];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [img resizableImageWithCapInsets:UIEdgeInsetsMake(0, 4, 0, 4)];
}

// iOS 26 style controls: thick capsule bars, no resting knobs.
static void BMStyleControls(UIView *v, int depth) {
    NSString *cn = NSStringFromClass([v class]);
    if ([cn hasSuffix:@"PlayerTimeControl"]) {
        for (NSString *k in @[@"elapsedTrack", @"remainingTrack"]) {
            if (![v respondsToSelector:NSSelectorFromString(k)]) continue;
            UIView *t = [v valueForKey:k];
            if ([t isKindOfClass:[UIView class]]) BMThickTrack(t, v, 8);
        }
        if ([v respondsToSelector:@selector(knobView)]) {
            UIView *knob = [v performSelector:@selector(knobView)];
            if ([knob isKindOfClass:[UIView class]]) knob.layer.opacity = 0;
        }
        return;
    }
    if ([cn hasSuffix:@"VolumeSlider"] && [v isKindOfClass:[UISlider class]]) {
        gVolSlider = (UISlider *)v;                          // only remembered (the lyrics screen hides it); never restyled:
        return;                                              // an 8pt track image in a 4pt track showed as a half-cut sliver
    }
    if (depth > 8) return;
    for (UIView *s in v.subviews) BMStyleControls(s, depth + 1);
}

// While the full-screen player is pulled down, fade out its blurred / artwork-coloured background layers so the dock shows
// through cleanly (otherwise the shrinking sheet background is drawn as a blurry rectangle over the mini player and tab bar).
static void BMCollectBackdrops(UIView *root, CGFloat minW, NSMutableArray *out, int depth) {
    NSString *cn = NSStringFromClass([root class]);
    if (([root isKindOfClass:[UIVisualEffectView class]] || [cn hasSuffix:@"MusicLyricsBackgroundView"]) && root.bounds.size.width >= minW) { [out addObject:root]; return; }
    if (depth > 6) return;
    for (UIView *sv in root.subviews) BMCollectBackdrops(sv, minW, out, depth + 1);
}

%hook UIViewController
- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    if (!BMEnabled() || !BMPrefOn(CFSTR("DockTransition"))) return;
    if (![NSStringFromClass([self class]) isEqualToString:@"MusicApplication.NowPlayingViewController"]) return;
    id<UIViewControllerTransitionCoordinator> tc = self.transitionCoordinator;
    if (!tc || !self.isViewLoaded) return;
    NSMutableArray *bds = [NSMutableArray array];
    BMCollectBackdrops(self.view, self.view.bounds.size.width * 0.9, bds, 0);
    if (!bds.count) return;
    [tc animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> ctx) {
        for (UIView *b in bds) b.alpha = 0;
    } completion:^(id<UIViewControllerTransitionCoordinatorContext> ctx) {
        if (ctx.isCancelled) for (UIView *b in bds) b.alpha = 1;           // let go: the player springs back, bring its background back
    }];
    // after a completed dismissal the controller is reused: restore the layers once it is fully gone
    __weak UIViewController *wself = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *vc = wself;
        if (vc && !vc.view.window) for (UIView *b in bds) b.alpha = 1;
    });
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    if ([NSStringFromClass([self class]) hasSuffix:@"SyncedLyricsViewController"]) {
        [BMLyricsSweep detachFrom:self];
        gLyricsOn = NO;
        gVolSlider.alpha = 1;
    }
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (BMEnabled() && [NSStringFromClass([self class]) hasSuffix:@"SyncedLyricsViewController"])
    { gLyricsOn = YES; gVolSlider.alpha = 0; [BMLyricsSweep attachTo:self]; }
    if (BMEnabled() && [NSStringFromClass([self class]) hasSuffix:@"NowPlayingControlsViewController"])
        BMStyleControls(self.view, 0);
    static Class mini;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mini = objc_getClass("MusicApplication.MiniPlayerViewController"); });
    static Class np;
    static dispatch_once_t once2;
    dispatch_once(&once2, ^{ np = objc_getClass("MusicApplication.NowPlayingViewController"); });
    if (np && [self isKindOfClass:np] && !objc_getAssociatedObject(self, "bmDumped")) {
        objc_setAssociatedObject(self, "bmDumped", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (BMDebugOn()) {
            NSMutableString *o = [NSMutableString string];
            UIView *t = self.view;
            while (t.superview) t = t.superview;
            BMDumpViews(t, 0, o);
            [o writeToFile:@"/var/jb/var/mobile/Library/bettermusic-nowplaying.txt" atomically:YES
                  encoding:NSUTF8StringEncoding error:nil];
        }
        return;
    }
    if (!mini || ![self isKindOfClass:mini] || objc_getAssociatedObject(self, "bmDumped")) return;
    objc_setAssociatedObject(self, "bmDumped", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *top = self.view;
    int up = 0;
    while (top.superview && up++ < 4) top = top.superview;
    if (BMDebugOn()) {
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"vcClass=%@ viewClass=%@\n", NSStringFromClass([self class]), NSStringFromClass([self.view class])];
        BMDumpViews(top, 0, out);
        [out writeToFile:@"/var/jb/var/mobile/Library/bettermusic-miniplayer.txt" atomically:YES
                encoding:NSUTF8StringEncoding error:nil];
    }
    if (BMEnabled()) BMStyleMiniPlayer(top);
}
%end

// Phase 1: floating pill tab bar, only on Music's own tab bar controller.
static BOOL BMIsMusicTabController(id vc) {
    static Class palette;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ palette = objc_getClass("MusicApplication.PaletteTabBarController"); });
    return palette && [vc isKindOfClass:palette];
}

// iOS 26 tab names: Listen Now -> Home (house icon), Browse -> New. Re-applied only on mismatch.
static void BMRenameTabs(UITabBarController *tc) {
    id v = BMPrefRaw(CFSTR("TabRename"), CFSTR(BM_DOMAIN));
    if (v && ![v boolValue]) return;
    NSNumber *n = objc_getAssociatedObject(tc, "bmRenames");
    if (n.integerValue > 20) return;                       // never fight the app in a loop
    for (UITabBarItem *it in tc.tabBar.items) {
        if ([it.title isEqualToString:@"Listen Now"]) {
            it.title = @"Home";
            UIImage *img = [UIImage systemImageNamed:@"house.fill"];
            if (img) { it.image = img; it.selectedImage = img; }
            objc_setAssociatedObject(tc, "bmRenames", @(n.integerValue + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else if ([it.title isEqualToString:@"Browse"]) {
            it.title = @"New";
            objc_setAssociatedObject(tc, "bmRenames", @(n.integerValue + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

%hook UITabBarController
- (void)viewDidLayoutSubviews {
    %orig;
    if (BMEnabled() && BMIsMusicTabController(self)) BMRenameTabs(self);
    if (!BMEnabled() || !BMIsMusicTabController(self) || !BMTabGlassOn()) return;
    UITabBar *tb = self.tabBar;
    if (!tb) return;
    for (UIView *u in tb.subviews)                           // the flat full-width bar behind the pill
        if ([NSStringFromClass([u class]) isEqualToString:@"_UIBarBackground"]) { u.alpha = 0; u.hidden = YES; }

    // One-time styling only. Never touch tb.frame here: it re-triggers layout in a loop.
    if (objc_getAssociatedObject(tb, "bmStyled")) return;
    objc_setAssociatedObject(tb, "bmStyled", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UITabBarAppearance *ap = [[UITabBarAppearance alloc] init];
    [ap configureWithTransparentBackground];
    tb.standardAppearance = ap;
    tb.scrollEdgeAppearance = ap;
    BMGlassView *g = [[BMGlassView alloc] initWithFrame:CGRectMake(10, 1, tb.bounds.size.width - 20, tb.bounds.size.height - 2)];   // same 10pt margins as the mini player
    g.tag = 0xB3;
    g.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [tb insertSubview:g atIndex:0];
}
%end

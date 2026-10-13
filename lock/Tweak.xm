#import "../common/BMPrefs.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Recon only: create /var/jb/var/mobile/Library/bml-dump-trigger to get bettermusiclock-tree.txt.
// Changes nothing on screen.
static void BMLTree(UIView *v, int depth, NSMutableString *out) {
    NSString *extra = @"";
    if ([v isKindOfClass:[UILabel class]])
        extra = [NSString stringWithFormat:@" text='%@' font=%.1f", ((UILabel *)v).text, ((UILabel *)v).font.pointSize];
    [out appendFormat:@"%*s%@ f=%@ r=%.1f a=%.2f h=%d%@\n", depth * 2, "", NSStringFromClass([v class]),
        NSStringFromCGRect(v.frame), v.layer.cornerRadius, v.alpha, v.hidden, extra];
    if (depth > 26) return;
    for (UIView *s in v.subviews) BMLTree(s, depth + 1, out);
}

static void BMLDump(void) {
    NSMutableString *out = [NSMutableString string];
    SEL sel = NSSelectorFromString(@"allWindowsIncludingInternalWindows:onlyVisibleWindows:");
    NSArray *wins = nil;
    if ([UIWindow respondsToSelector:sel])
        wins = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)([UIWindow class], sel, YES, YES);
    [out appendFormat:@"windows=%lu\n", (unsigned long)wins.count];
    for (UIWindow *w in wins) {
        [out appendFormat:@"=== WINDOW %@ level=%.0f\n", NSStringFromClass([w class]), w.windowLevel];
        BMLTree(w, 0, out);
    }
    [out writeToFile:@"/var/jb/var/mobile/Library/bettermusiclock-tree.txt" atomically:YES
            encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"[BetterMusicLock] dump written (%lu windows)", (unsigned long)wins.count);
}

// ---- Tap the lock screen cover to expand it (iOS 26 style) ----
#define BML_DOMAIN CFSTR("com.rocketkid300.bettermusiclock")
#define kExpandedTag 0xB26

static BOOL BMLEnabled(void) {
    id v = BMPrefRaw(CFSTR("Enabled"), BML_DOMAIN);
    return v ? [v boolValue] : YES;
}

static double BMLPrefD(CFStringRef key, double def) {
    id v = BMPrefRaw(key, BML_DOMAIN);
    return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : def;
}

static UIFont *BMLClockFont(void) {
    CGFloat sz = MAX(14, MIN(60, BMLPrefD(CFSTR("ClockRowSize"), 34)));
    NSInteger idx = (NSInteger)BMLPrefD(CFSTR("ClockRowFont"), 0);
    UIFont *base = [UIFont systemFontOfSize:sz weight:(idx == 5 ? UIFontWeightLight : UIFontWeightSemibold)];
    UIFontDescriptor *d = base.fontDescriptor;
    UIFontDescriptorSystemDesign design = nil;
    if (idx == 1) design = UIFontDescriptorSystemDesignRounded;
    else if (idx == 2) design = UIFontDescriptorSystemDesignSerif;
    else if (idx == 3) design = UIFontDescriptorSystemDesignMonospaced;
    if (design) {
        UIFontDescriptor *dd = [d fontDescriptorWithDesign:design];
        if (dd) return [UIFont fontWithDescriptor:dd size:sz];
    }
    if (idx == 4) {
        UIFont *c = [UIFont fontWithName:@"AvenirNextCondensed-DemiBold" size:sz];
        if (c) return c;
    }
    return base;
}

static UIView *BMLFindClass(UIView *root, NSString *name, int depth) {
    if ([NSStringFromClass([root class]) isEqualToString:name]) return root;
    if (depth > 30) return nil;
    for (UIView *s in root.subviews) { UIView *r = BMLFindClass(s, name, depth + 1); if (r) return r; }
    return nil;
}

static UIView *BMLAncestor(UIView *v, NSString *name) {
    for (UIView *u = v; u; u = u.superview) if ([NSStringFromClass([u class]) isEqualToString:name]) return u;
    return nil;
}

static UIImage *BMLArtworkImage(UIView *art) {
    UIImage *best = nil; CGFloat area = 0;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:art];
    while (stack.count) {
        UIView *v = stack.lastObject; [stack removeLastObject];
        if ([v isKindOfClass:[UIImageView class]]) {
            UIImage *im = ((UIImageView *)v).image;
            CGFloat a = v.bounds.size.width * v.bounds.size.height;
            if (im && a > area && v.alpha > 0.05) { best = im; area = a; }
        }
        [stack addObjectsFromArray:v.subviews];
    }
    return best;
}

// ---------- Expanded player panel (replaces the stock player contents while expanded) ----------
#import <dlfcn.h>

static void BMLFetchInfo(void (^cb)(NSDictionary *)) {
    static void (*getInfo)(dispatch_queue_t, void (^)(CFDictionaryRef));
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        if (h) getInfo = (void (*)(dispatch_queue_t, void (^)(CFDictionaryRef)))dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    });
    if (!getInfo) return;
    getInfo(dispatch_get_main_queue(), ^(CFDictionaryRef info) { cb((__bridge NSDictionary *)info); });
}

static NSArray *BMLCollect(UIView *root, NSString *name, int depth) {
    NSMutableArray *out = [NSMutableArray array];
    if ([NSStringFromClass([root class]) isEqualToString:name]) [out addObject:root];
    if (depth > 30) return out;
    for (UIView *s in root.subviews) [out addObjectsFromArray:BMLCollect(s, name, depth + 1)];
    return out;
}

// Backdrop: full-screen gradient taken from the artwork's average color (iOS 26 expanded player look).
static UIColor *BMLAvgColor(UIImage *img) {
    CGImageRef cg = img.CGImage;
    if (!cg) return [UIColor colorWithWhite:0.15 alpha:1];
    uint8_t px[4] = {0, 0, 0, 0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, 1, 1, 8, 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
    CGContextDrawImage(ctx, CGRectMake(0, 0, 1, 1), cg);
    CGContextRelease(ctx); CGColorSpaceRelease(cs);
    return [UIColor colorWithRed:px[0] / 255.0 green:px[1] / 255.0 blue:px[2] / 255.0 alpha:1];
}

static void BMLApplyBackdrop(UIView *bd, UIImage *img) {
    if (!bd || !img) return;
    CGFloat h, sat, b, a;
    [BMLAvgColor(img) getHue:&h saturation:&sat brightness:&b alpha:&a];
    sat = MIN(1, sat * 1.15 + 0.05);
    UIColor *top = [UIColor colorWithHue:h saturation:sat brightness:MIN(0.62, MAX(0.38, b * 0.8)) alpha:1];
    UIColor *bot = [UIColor colorWithHue:h saturation:MIN(1, sat * 1.05) brightness:MIN(0.34, MAX(0.16, b * 0.4)) alpha:1];
    CAGradientLayer *gl = (CAGradientLayer *)bd.layer.sublayers.firstObject;
    if (![gl isKindOfClass:[CAGradientLayer class]]) {
        gl = [CAGradientLayer layer];
        gl.frame = bd.bounds;
        [bd.layer addSublayer:gl];
    }
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.4];
    gl.colors = @[(id)top.CGColor, (id)bot.CGColor];
    [CATransaction commit];
}

@interface BMLPanel : UIView
@property (nonatomic, weak) UIView *np;                 // stock MRUNowPlayingView
@property (nonatomic, weak) UIImageView *cover;         // big cover, upgraded to full-size artwork
@property (nonatomic, weak) UIView *backdrop;           // full-screen artwork-colored gradient
@property (nonatomic, weak) UILabel *clockL;            // compact "12:35  Tue 13 Oct" row above the cover
@property (nonatomic, strong) NSData *lastArt;
@property (nonatomic) BOOL hiDone;
@property (nonatomic, copy) NSString *hiKey;            // album/track id already fetched in full size
@property (nonatomic, strong) UILabel *titleL, *artistL, *elapsedL, *remainL;
@property (nonatomic, strong) UIView *track, *fill;
@property (nonatomic, strong) UIButton *back, *play, *fwd, *route;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) double elapsed, duration, rate;
@property (nonatomic) CFTimeInterval at;
@end

@implementation BMLPanel
- (instancetype)initWithFrame:(CGRect)f {
    if (!(self = [super initWithFrame:f])) return nil;
    UIColor *w = [UIColor whiteColor], *g = [UIColor colorWithWhite:1 alpha:0.6];
    self.layer.cornerRadius = 20;
    self.clipsToBounds = YES;
    UIVisualEffectView *bg = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
    bg.frame = self.bounds;
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:bg];
    _titleL = [self label:17 bold:YES color:w];
    _artistL = [self label:15 bold:NO color:g];
    _elapsedL = [self label:11 bold:NO color:g];
    _remainL = [self label:11 bold:NO color:g];
    _elapsedL.textAlignment = NSTextAlignmentLeft;
    _remainL.textAlignment = NSTextAlignmentRight;
    _track = [[UIView alloc] init]; _track.backgroundColor = [UIColor colorWithWhite:1 alpha:0.3];
    _fill = [[UIView alloc] init]; _fill.backgroundColor = [UIColor colorWithWhite:1 alpha:0.9];
    for (UIView *t in @[_track, _fill]) { t.layer.cornerRadius = 2; t.clipsToBounds = YES; }
    [self addSubview:_track]; [_track addSubview:_fill];
    _back = [self btn:@"backward.fill" size:24 action:@selector(onBack)];
    _play = [self btn:@"pause.fill" size:30 action:@selector(onPlay)];
    _fwd = [self btn:@"forward.fill" size:24 action:@selector(onFwd)];
    _route = [self btn:@"airplayaudio" size:20 action:@selector(onRoute)];
    return self;
}
- (UILabel *)label:(CGFloat)sz bold:(BOOL)b color:(UIColor *)c {
    UILabel *l = [[UILabel alloc] init];
    l.font = b ? [UIFont boldSystemFontOfSize:sz] : [UIFont systemFontOfSize:sz];
    l.textColor = c; l.textAlignment = NSTextAlignmentCenter;
    l.adjustsFontSizeToFitWidth = YES; l.minimumScaleFactor = 0.7;
    [self addSubview:l]; return l;
}
- (UIButton *)btn:(NSString *)sym size:(CGFloat)sz action:(SEL)a {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:sz weight:UIImageSymbolWeightBold];
    [b setImage:[UIImage systemImageNamed:sym withConfiguration:cfg] forState:UIControlStateNormal];
    b.tintColor = [UIColor whiteColor];
    [b addTarget:self action:a forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:b]; return b;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width, m = 16;
    _titleL.frame = CGRectMake(m, 10, W - 2 * m, 22);
    _artistL.frame = CGRectMake(m, 32, W - 2 * m, 20);
    _elapsedL.frame = CGRectMake(m, 58, 36, 14);
    _remainL.frame = CGRectMake(W - m - 40, 58, 40, 14);
    _track.frame = CGRectMake(m + 40, 63, W - 2 * m - 80, 4);
    [self updateFill];
    CGFloat cy = 98, cx = W / 2;
    _back.frame = CGRectMake(cx - 100, cy - 20, 44, 40);
    _play.frame = CGRectMake(cx - 22, cy - 20, 44, 40);
    _fwd.frame = CGRectMake(cx + 56, cy - 20, 44, 40);
    _route.frame = CGRectMake(W - m - 36, cy - 20, 36, 40);
}
- (double)now { return self.rate > 0 ? self.elapsed + (CACurrentMediaTime() - self.at) * self.rate : self.elapsed; }
// Full-size cover from Apple's public catalog (the system only hands out a 300px thumbnail).
- (void)fetchHiRes:(NSString *)adamId {
    NSURL *u = [NSURL URLWithString:[NSString stringWithFormat:@"https://itunes.apple.com/lookup?id=%@", adamId]];
    if (!u) return;
    __weak BMLPanel *ws = self;
    [[[NSURLSession sharedSession] dataTaskWithURL:u completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        NSString *art = nil;
        if (data) {
            NSDictionary *j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSArray *res = [j isKindOfClass:[NSDictionary class]] ? j[@"results"] : nil;
            art = [res isKindOfClass:[NSArray class]] && res.count ? res[0][@"artworkUrl100"] : nil;
        }
        if (![art isKindOfClass:[NSString class]]) return;
        art = [art stringByReplacingOccurrencesOfString:@"100x100bb" withString:@"1200x1200bb"];
        NSURL *iu = [NSURL URLWithString:art];
        if (!iu) return;
        [[[NSURLSession sharedSession] dataTaskWithURL:iu completionHandler:^(NSData *idata, NSURLResponse *r2, NSError *e2) {
            UIImage *hi = idata ? [UIImage imageWithData:idata scale:UIScreen.mainScreen.scale] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                BMLPanel *s = ws;
                if (!hi || !s || !s.cover || ![s.hiKey isEqualToString:adamId]) return;
                s.lastArt = nil;   // keep the thumbnail path from overwriting this
                [UIView transitionWithView:s.cover duration:0.3 options:UIViewAnimationOptionTransitionCrossDissolve
                                animations:^{ s.cover.image = hi; } completion:nil];
                BMLApplyBackdrop(s.backdrop, hi);
                s.hiDone = YES;
            });
        }] resume];
    }] resume];
}

- (void)updateClock {
    if (!self.clockL) return;
    static NSDateFormatter *tf, *df;
    if (!tf) {
        tf = [[NSDateFormatter alloc] init]; tf.dateFormat = [NSDateFormatter dateFormatFromTemplate:@"j:mm" options:0 locale:[NSLocale currentLocale]];
        df = [[NSDateFormatter alloc] init]; df.dateFormat = [NSDateFormatter dateFormatFromTemplate:@"EEE d MMM" options:0 locale:[NSLocale currentLocale]];
    }
    NSDate *now = [NSDate date];
    NSString *t = [tf stringFromDate:now], *d = [df stringFromDate:now];
    UIFont *f = BMLClockFont();
    BOOL showDate = BMLPrefD(CFSTR("ClockRowShowDate"), 1) != 0;
    NSMutableAttributedString *a = [[NSMutableAttributedString alloc] initWithString:(showDate ? [NSString stringWithFormat:@"%@   %@", t, d] : t)
        attributes:@{NSFontAttributeName: f, NSForegroundColorAttributeName: [UIColor whiteColor]}];
    if (showDate) [a addAttribute:NSForegroundColorAttributeName value:[UIColor colorWithWhite:1 alpha:0.6] range:NSMakeRange(t.length, a.length - t.length)];
    self.clockL.attributedText = a;
}

- (void)updateFill {
    [self updateClock];
    double d = MAX(1, self.duration), e = MIN(d, MAX(0, [self now]));
    CGFloat w = _track.bounds.size.width;
    _fill.frame = CGRectMake(0, 0, w * e / d, 4);
    _elapsedL.text = [NSString stringWithFormat:@"%d:%02d", (int)e / 60, (int)e % 60];
    int r = (int)(d - e);
    _remainL.text = [NSString stringWithFormat:@"-%d:%02d", r / 60, r % 60];
}
- (void)start {
    __weak BMLPanel *ws = self;
    [self refresh];
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) {
        BMLPanel *s = ws; if (!s) { [t invalidate]; return; }
        static int n; if (n++ % 8 == 0) [s refresh];
        [s updateFill];
    }];
}
- (void)stop { [_timer invalidate]; _timer = nil; }
- (void)refresh {
    __weak BMLPanel *ws = self;
    BMLFetchInfo(^(NSDictionary *d) {
        BMLPanel *s = ws; if (!s || !d) return;
        NSString *t = d[@"kMRMediaRemoteNowPlayingInfoTitle"], *a = d[@"kMRMediaRemoteNowPlayingInfoArtist"], *al = d[@"kMRMediaRemoteNowPlayingInfoAlbum"];
        if ([t isKindOfClass:[NSString class]]) s.titleL.text = t;
        NSMutableArray *parts = [NSMutableArray array];
        if ([a isKindOfClass:[NSString class]] && a.length) [parts addObject:a];
        (void)al;   // iOS 26 shows only the artist under the title
        s.artistL.text = [parts componentsJoinedByString:@" — "];
        NSNumber *e = d[@"kMRMediaRemoteNowPlayingInfoElapsedTime"], *du = d[@"kMRMediaRemoteNowPlayingInfoDuration"], *r = d[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
        NSDate *ts = d[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
        if ([e isKindOfClass:[NSNumber class]]) {
            double lag = [ts isKindOfClass:[NSDate class]] ? [[NSDate date] timeIntervalSinceDate:ts] : 0;
            s.rate = [r isKindOfClass:[NSNumber class]] ? r.doubleValue : 1;
            s.elapsed = e.doubleValue + lag * s.rate; s.at = CACurrentMediaTime();
        }
        if ([du isKindOfClass:[NSNumber class]]) s.duration = du.doubleValue;
        // Full-size artwork from now-playing info (the player thumbnail is only ~100pt).
        NSData *ad = d[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        id albumAdam = d[@"kMRMediaRemoteNowPlayingInfoAlbumiTunesStoreAdamIdentifier"] ?: d[@"kMRMediaRemoteNowPlayingInfoiTunesStoreIdentifier"];
        NSString *key = albumAdam ? [NSString stringWithFormat:@"%@", albumAdam] : nil;
        if (key.length && ![key isEqualToString:s.hiKey]) { s.hiKey = key; s.hiDone = NO; [s fetchHiRes:key]; }
        if (!s.hiDone && [ad isKindOfClass:[NSData class]] && ad.length && ![ad isEqualToData:s.lastArt] && s.cover) {
            UIImage *hi = [UIImage imageWithData:ad scale:UIScreen.mainScreen.scale];
            if (hi) {
                s.lastArt = ad;
                [UIView transitionWithView:s.cover duration:0.3 options:UIViewAnimationOptionTransitionCrossDissolve
                                animations:^{ s.cover.image = hi; } completion:nil];
                BMLApplyBackdrop(s.backdrop, hi);
            }
        }
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:30 weight:UIImageSymbolWeightBold];
        [s.play setImage:[UIImage systemImageNamed:(s.rate > 0 ? @"pause.fill" : @"play.fill") withConfiguration:cfg] forState:UIControlStateNormal];
    });
}
- (NSArray *)transport {
    UIView *c = BMLCollect(self.np, @"MRUNowPlayingTransportControlsView", 0).firstObject;
    NSMutableArray *vis = [NSMutableArray array];
    for (UIView *b in c.subviews) if ([b isKindOfClass:[UIControl class]] && b.alpha > 0.5) [vis addObject:b];
    [vis sortUsingComparator:^NSComparisonResult(UIView *x, UIView *y) { return x.frame.origin.x < y.frame.origin.x ? NSOrderedAscending : NSOrderedDescending; }];
    return vis;
}
- (void)press:(NSUInteger)i {
    NSArray *t = [self transport];
    if (i < t.count) [(UIControl *)t[i] sendActionsForControlEvents:UIControlEventTouchUpInside];
    [self performSelector:@selector(refresh) withObject:nil afterDelay:0.4];
}
- (void)onBack { [self press:0]; }
- (void)onPlay { [self press:1]; }
- (void)onFwd { [self press:2]; }
- (void)onRoute {
    UIControl *r = BMLCollect(self.np, @"MRUNowPlayingRoutingButton", 0).firstObject;
    [r sendActionsForControlEvents:UIControlEventTouchUpInside];
}
@end

// Find the hidden UILabel that Retica sizes to the big clock (font >= 100pt): its frame tells where the big digits are.
static UILabel *BMLFindBigClockLabel(UIView *root, int depth) {
    if ([root isKindOfClass:[UILabel class]] && ((UILabel *)root).font.pointSize >= 100) return (UILabel *)root;
    if (depth > 8) return nil;
    for (UIView *s in root.subviews) { UILabel *l = BMLFindBigClockLabel(s, depth + 1); if (l) return l; }
    return nil;
}

// Transform for the big clock view that shrinks it onto the small clock row's time and moves it there (iOS 26 style).
static CGAffineTransform BMLClockShrinkTransform(UIView *host, UIView *dateV, UILabel *rowLabel) {
    if (!dateV || !rowLabel.attributedText.length) return CGAffineTransformIdentity;
    UILabel *big = BMLFindBigClockLabel(dateV, 0);
    CGRect bigRect = big ? [big.superview convertRect:big.frame toView:host]
                         : [dateV.superview convertRect:dateV.frame toView:host];
    CGPoint c = CGPointMake(CGRectGetMidX(bigRect), CGRectGetMidY(bigRect));
    CGPoint A = [dateV.superview convertPoint:dateV.center toView:host];
    NSAttributedString *at = rowLabel.attributedText;
    UIFont *rowFont = [at attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL] ?: [UIFont systemFontOfSize:34];
    NSString *whole = at.string;
    NSRange sep = [whole rangeOfString:@"   "];
    NSString *timeStr = sep.location != NSNotFound ? [whole substringToIndex:sep.location] : whole;
    CGFloat totalW = [at size].width, timeW = [[[NSAttributedString alloc] initWithString:timeStr attributes:@{NSFontAttributeName: rowFont}] size].width;
    CGFloat startX = rowLabel.frame.origin.x + (rowLabel.frame.size.width - totalW) / 2;
    CGPoint target = CGPointMake(startX + timeW / 2, CGRectGetMidY(rowLabel.frame));
    CGFloat bigPt = big ? big.font.pointSize : 300;
    CGFloat sc = MAX(0.05, MIN(1.0, rowFont.pointSize / bigPt));
    CGFloat tx = target.x - A.x - sc * (c.x - A.x);
    CGFloat ty = target.y - A.y - sc * (c.y - A.y);
    return CGAffineTransformMake(sc, 0, 0, sc, tx, ty);
}

static BOOL BMLShrinkStyle(void) { return BMLPrefD(CFSTR("ClockTransition"), 0) >= 1; }   // 0 = fade (default), 1 = shrink and slide

static void BMLCollapse(UIView *art, BOOL animated);

static void BMLExpand(UIView *art) {
    UIWindow *w = art.window;
    UIView *host = BMLAncestor(art, @"CSCoverSheetView") ?: w;
    UIView *np = BMLAncestor(art, @"MRUNowPlayingView");
    UIView *platter = BMLAncestor(art, @"PLPlatterView") ?: np;
    UIImage *img = BMLArtworkImage(art);
    if (!host || !np || !img) return;
    if ([host viewWithTag:kExpandedTag]) return;

    UIView *dateV = BMLFindClass(host, @"SBFLockScreenDateView", 0);   // holds the big clock from Retica
    objc_setAssociatedObject(art, "bmlDate", dateV, OBJC_ASSOCIATION_ASSIGN);
    CGFloat W = host.bounds.size.width, H = host.bounds.size.height;
    CGFloat panelH = 130, top = 84;
    CGFloat side = MIN(W - 20, H - top - 10 - panelH - 50);        // near full width like iOS 26
    if (side < 120) return;
    CGRect target = CGRectMake((W - side) / 2, top, side, side);
    CGRect panelFrame = CGRectMake(10, top + side + 10, W - 20, panelH);
    CGFloat rowH = MAX(24, MIN(60, BMLPrefD(CFSTR("ClockRowSize"), 34))) * 1.25;
    UILabel *clock = [[UILabel alloc] initWithFrame:CGRectMake(10, 78 - rowH, W - 20, rowH)];
    clock.textAlignment = NSTextAlignmentCenter;
    clock.adjustsFontSizeToFitWidth = YES; clock.minimumScaleFactor = 0.6;
    clock.alpha = 0;
    CGRect start = [art.superview convertRect:art.frame toView:host];

    UIImageView *big = [[UIImageView alloc] initWithImage:img];
    big.tag = kExpandedTag;
    big.contentMode = UIViewContentModeScaleAspectFill;
    big.clipsToBounds = YES;
    big.layer.cornerRadius = 4;
    big.layer.minificationFilter = kCAFilterTrilinear;
    big.layer.magnificationFilter = kCAFilterTrilinear;
    big.frame = start;
    big.userInteractionEnabled = YES;
    [big addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:NSClassFromString(@"BMLTapTarget") action:NSSelectorFromString(@"bigTapped:")]];
    objc_setAssociatedObject(big, "bmlArt", art, OBJC_ASSOCIATION_ASSIGN);
    [host addSubview:big];
    objc_setAssociatedObject(art, "bmlBig", big, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIView *backdrop = [[UIView alloc] initWithFrame:host.bounds];
    backdrop.userInteractionEnabled = NO;
    backdrop.alpha = 0;
    BMLApplyBackdrop(backdrop, img);
    [host insertSubview:backdrop atIndex:0];
    objc_setAssociatedObject(art, "bmlBackdrop", backdrop, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    BMLPanel *panel = [[BMLPanel alloc] initWithFrame:panelFrame];
    panel.backdrop = backdrop;
    panel.np = np;
    panel.cover = big;
    panel.clockL = clock;
    panel.alpha = 0;
    [host addSubview:clock];
    [host addSubview:panel];
    objc_setAssociatedObject(art, "bmlClock", clock, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(art, "bmlPanel", panel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(art, "bmlPlatter", platter, OBJC_ASSOCIATION_ASSIGN);
    [panel start];
    [panel updateClock];                                          // make sure the small clock text exists before measuring it
    CGAffineTransform shrink = BMLShrinkStyle() ? BMLClockShrinkTransform(host, dateV, clock) : CGAffineTransformIdentity;

    [UIView animateWithDuration:0.55 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0.3 options:0 animations:^{
        big.frame = target;
        big.layer.cornerRadius = 24;
        platter.alpha = 0;
        panel.alpha = 1;
        backdrop.alpha = 1;
        dateV.transform = shrink;                                 // the big clock shrinks and slides up into the small one
    } completion:nil];
    BOOL slide = BMLShrinkStyle();
    [UIView animateWithDuration:slide ? 0.22 : 0.4 delay:slide ? 0.26 : 0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        dateV.alpha = 0;                                          // shrink style: hand over near the end; fade style: simple crossfade
        clock.alpha = 1;
    } completion:nil];
}

static void BMLCollapse(UIView *art, BOOL animated) {
    UIImageView *big = objc_getAssociatedObject(art, "bmlBig");
    BMLPanel *panel = objc_getAssociatedObject(art, "bmlPanel");
    UIView *platter = objc_getAssociatedObject(art, "bmlPlatter");
    UIView *clock = objc_getAssociatedObject(art, "bmlClock");
    UIView *dateV = objc_getAssociatedObject(art, "bmlDate");
    UIView *backdrop = objc_getAssociatedObject(art, "bmlBackdrop");
    objc_setAssociatedObject(art, "bmlBackdrop", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *host = big.superview;
    if (!big) return;
    objc_setAssociatedObject(art, "bmlDate", nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(art, "bmlClock", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(art, "bmlBig", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(art, "bmlPanel", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(art, "bmlPlatter", nil, OBJC_ASSOCIATION_ASSIGN);
    CGRect back = [art.superview convertRect:art.frame toView:host];
    void (^done)(BOOL) = ^(BOOL f) { [panel stop]; [panel removeFromSuperview]; [clock removeFromSuperview]; [backdrop removeFromSuperview]; [big removeFromSuperview]; };
    if (!animated) { platter.alpha = 1; dateV.transform = CGAffineTransformIdentity; dateV.alpha = 1; done(YES); return; }
    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0 options:0 animations:^{
        big.frame = back;
        big.layer.cornerRadius = 4;
        platter.alpha = 1;
        panel.alpha = 0;
        backdrop.alpha = 0;
        dateV.transform = CGAffineTransformIdentity;              // the clock grows back to full size
    } completion:done];
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        dateV.alpha = 1;                                          // big clock reappears right away, small one fades
        clock.alpha = 0;
    } completion:nil];
}

@interface BMLTapTarget : NSObject
+ (void)tapped:(UITapGestureRecognizer *)g;
+ (void)bigTapped:(UITapGestureRecognizer *)g;
@end
@implementation BMLTapTarget
+ (void)bigTapped:(UITapGestureRecognizer *)g {
    @try {
        UIView *art = objc_getAssociatedObject(g.view, "bmlArt");
        if (art) BMLCollapse(art, YES);
    } @catch (NSException *e) { NSLog(@"[BetterMusicLock] bigTap error %@", e.name); }
}
+ (void)tapped:(UITapGestureRecognizer *)g {
    @try {
        UIView *art = g.view;
        if (objc_getAssociatedObject(art, "bmlBig")) BMLCollapse(art, YES); else BMLExpand(art);
    } @catch (NSException *e) { NSLog(@"[BetterMusicLock] tap error %@", e.name); }
}
@end

%hook MRUArtworkView
- (void)didMoveToWindow {
    %orig;
    UIView *me = (UIView *)self;
    if (!me.window) { if (objc_getAssociatedObject(me, "bmlBig")) BMLCollapse(me, NO); return; }
    if (!BMLEnabled() || !BMLAncestor(me, @"CSMediaControlsView")) return;       // lock screen only
    if (objc_getAssociatedObject(me, "bmlTap")) return;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:[BMLTapTarget class] action:@selector(tapped:)];
    me.userInteractionEnabled = YES;
    [me addGestureRecognizer:tap];
    objc_setAssociatedObject(me, "bmlTap", tap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
%end

// ---- Fit a tall clock (Retica) above the music player while one is on the lock screen ----
static BOOL BMLChainVisible(UIView *v) {
    for (UIView *u = v; u; u = u.superview) if (u.hidden || u.alpha < 0.05) return NO;
    return v.window != nil;
}

// The list view we shifted, and the transform it must keep. SpringBoard resets list transforms while you
// interact with the lock screen, so the hook below puts ours back instantly.
static __weak UIView *gShiftList;
static CGAffineTransform gShiftT;

%hook CSAdjunctItemView
- (void)setTransform:(CGAffineTransform)t {
    if ((UIView *)self == gShiftList && !CGAffineTransformEqualToTransform(t, gShiftT)) t = gShiftT;
    %orig(t);
}
%end

static UIView *BMLInnermost(UIView *from, NSString *name) {
    for (UIView *u = from; u; u = u.superview) if ([NSStringFromClass([u class]) isEqualToString:name]) return u;
    return nil;
}

// Keep Retica's full-size clock: move the player (and the notification list it lives in) down instead.
static void BMLFitClock(void) {
    id pv = BMPrefRaw(CFSTR("FitClock"), BML_DOMAIN);
    if (pv && ![pv boolValue]) return;
    id sv = BMPrefRaw(CFSTR("PlayerShift"), BML_DOMAIN);
    CGFloat shift = sv ? [sv doubleValue] : 118;
    SEL sel = NSSelectorFromString(@"allWindowsIncludingInternalWindows:onlyVisibleWindows:");
    if (![UIWindow respondsToSelector:sel]) return;
    NSArray *wins = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)([UIWindow class], sel, YES, YES);
    for (UIWindow *w in wins) {
        if (![NSStringFromClass([w class]) isEqualToString:@"SBCoverSheetWindow"]) continue;
        UIView *host = BMLFindClass(w, @"CSCoverSheetView", 0);
        if (!host || [host viewWithTag:kExpandedTag]) return;
        UIView *date = BMLFindClass(host, @"SBFLockScreenDateView", 0);
        if (date && !CGAffineTransformIsIdentity(date.transform)) date.transform = CGAffineTransformIdentity;   // undo the earlier clock scaling
        UIView *np = BMLFindClass(host, @"MRUNowPlayingView", 0);
        UIView *list = np ? BMLInnermost(np, @"CSAdjunctItemView") : nil;       // the player's own item, not the whole list
        if (!list) {
            // Player gone: release any shift we held on the previous item.
            if (gShiftList) { gShiftT = CGAffineTransformIdentity; gShiftList.transform = CGAffineTransformIdentity; gShiftList = nil; }
            return;
        }
        if (gShiftList && gShiftList != list) { gShiftT = CGAffineTransformIdentity; gShiftList.transform = CGAffineTransformIdentity; }
        BOOL player = np && BMLChainVisible(np);
        CGAffineTransform want = player ? CGAffineTransformMakeTranslation(0, shift) : CGAffineTransformIdentity;
        gShiftList = list;
        gShiftT = want;
        if (!CGAffineTransformEqualToTransform(list.transform, want))
            [UIView animateWithDuration:0.3 animations:^{ list.transform = want; }];
        return;
    }
}

__attribute__((constructor)) static void BetterMusicLockLoaded(void) {
    NSLog(@"[BetterMusicLock] loaded");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        id dbg = BMPrefRaw(CFSTR("DebugLog"), CFSTR("com.rocketkid300.bettermusic"));   // the dump trigger is a debug tool: only with "Debug logging" on
        if ([dbg respondsToSelector:@selector(boolValue)] && [dbg boolValue]) {
            dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(t, DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
            dispatch_source_set_event_handler(t, ^{
                NSString *trig = @"/var/jb/var/mobile/Library/bml-dump-trigger";
                if (![[NSFileManager defaultManager] fileExistsAtPath:trig]) return;
                [[NSFileManager defaultManager] removeItemAtPath:trig error:nil];
                @try { BMLDump(); } @catch (NSException *e) { NSLog(@"[BetterMusicLock] dump error %@", e.name); }
            });
            dispatch_resume(t);
            objc_setAssociatedObject([UIApplication class], "bmlTimer", (id)t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        NSTimer *fit = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *tm) {
            @try { BMLFitClock(); } @catch (NSException *e) {}
        }];
        [[NSRunLoop mainRunLoop] addTimer:fit forMode:NSRunLoopCommonModes];
        objc_setAssociatedObject([UIApplication class], "bmlFitTimer", fit, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
}

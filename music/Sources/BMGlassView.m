#import "BMGlassView.h"

@implementation BMGlassView {
    CAGradientLayer *_sheen;
}

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        UIVisualEffectView *blur = [[UIVisualEffectView alloc]
            initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
        blur.frame = self.bounds;
        blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:blur];

        // Dark tint mutes content showing through behind the glass.
        UIView *tint = [[UIView alloc] initWithFrame:self.bounds];
        tint.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
        tint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:tint];

        _sheen = [CAGradientLayer layer];
        _sheen.colors = @[(id)[UIColor colorWithWhite:1 alpha:0.28].CGColor,
                          (id)[UIColor colorWithWhite:1 alpha:0.02].CGColor];
        _sheen.startPoint = CGPointMake(0, 0);
        _sheen.endPoint = CGPointMake(1, 1);
        [self.layer addSublayer:_sheen];

        self.layer.borderWidth = 0.5;
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
        self.clipsToBounds = YES;
        self.userInteractionEnabled = NO;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _sheen.frame = self.bounds;
    self.layer.cornerRadius = self.bounds.size.height / 2.0;
}

@end

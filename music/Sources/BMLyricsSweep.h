#import <UIKit/UIKit.h>

// Word-by-word lyric highlight: masks the bright "selected" label so it fills as the line plays.
@interface BMLyricsSweep : NSObject
+ (void)attachTo:(UIViewController *)vc;
+ (void)detachFrom:(UIViewController *)vc;
@end

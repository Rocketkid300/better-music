#import <UIKit/UIKit.h>

// Minimal stand-ins for the private Preferences classes.
@interface PSSpecifier : NSObject
- (id)propertyForKey:(NSString *)key;
@end
@interface PSListController : UIViewController {
    NSArray *_specifiers;
}
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (void)reloadSpecifiers;
@end

@interface BMRootListController : PSListController
@end

// Settings are stored where the Better Music tweaks read them (rootless Dopamine path).
static NSString *BMPrefPath(NSString *domain) {
    return [NSString stringWithFormat:@"/var/jb/var/mobile/Library/Preferences/%@.plist", domain];
}

@implementation BMRootListController

- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)spec {
    NSString *domain = [spec propertyForKey:@"defaults"], *key = [spec propertyForKey:@"key"];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:BMPrefPath(domain)];
    id v = d[key];
    return v ?: [spec propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
    NSString *domain = [spec propertyForKey:@"defaults"], *key = [spec propertyForKey:@"key"];
    // Sliders snap to their default when dragged close to it (within 3% of the slider's range).
    NSNumber *def = [spec propertyForKey:@"default"], *mn = [spec propertyForKey:@"min"], *mx = [spec propertyForKey:@"max"];
    if ([value isKindOfClass:[NSNumber class]] && [def isKindOfClass:[NSNumber class]] && [mn isKindOfClass:[NSNumber class]] && [mx isKindOfClass:[NSNumber class]]) {
        double range = mx.doubleValue - mn.doubleValue;
        if (range > 0 && fabs([value doubleValue] - def.doubleValue) < range * 0.03) value = def;
    }
    NSString *path = BMPrefPath(domain);
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:path] ?: [NSMutableDictionary dictionary];
    d[key] = value;
    [d writeToFile:path atomically:YES];
}

// "Reset to default" buttons under the sliders.
static void BMResetKey(NSString *domain, NSString *key) {
    NSString *path = BMPrefPath(domain);
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:path] ?: [NSMutableDictionary dictionary];
    [d removeObjectForKey:key];
    [d writeToFile:path atomically:YES];
}

- (void)resetAppScale { BMResetKey(@"com.rocketkid300.bettermusic", @"AppScale"); [self reloadSpecifiers]; }
- (void)resetPlayerShift { BMResetKey(@"com.rocketkid300.bettermusiclock", @"PlayerShift"); [self reloadSpecifiers]; }
- (void)resetClockSize { BMResetKey(@"com.rocketkid300.bettermusiclock", @"ClockRowSize"); [self reloadSpecifiers]; }

@end

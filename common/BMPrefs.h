#import <Foundation/Foundation.h>

// Settings live in /var/jb/var/mobile/Library/Preferences/<domain>.plist (written by the Better Music settings
// bundle). Re-read at most twice a second; falls back to the system preferences for anything not set there.
static inline id BMPrefRaw(CFStringRef key, CFStringRef domain) {
    static NSMutableDictionary *cache, *stamp;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary new]; stamp = [NSMutableDictionary new]; });
    NSString *d = (__bridge NSString *)domain, *k = (__bridge NSString *)key;
    @synchronized (cache) {
        NSDate *last = stamp[d];
        if (!last || [last timeIntervalSinceNow] < -0.5) {
            NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:
                [NSString stringWithFormat:@"/var/jb/var/mobile/Library/Preferences/%@.plist", d]];
            cache[d] = dict ?: @{};
            stamp[d] = [NSDate date];
        }
        id v = ((NSDictionary *)cache[d])[k];
        if (v) return v;
    }
    return CFBridgingRelease(CFPreferencesCopyAppValue(key, domain));
}

#import "NightShiftBridge.h"
#import <Foundation/Foundation.h>
#import <dlfcn.h>

typedef struct { int hour; int minute; } M7Time;
typedef struct { M7Time fromTime; M7Time toTime; } M7Schedule;
typedef struct {
    BOOL active;
    BOOL enabled;
    BOOL sunSchedulePermitted;
    int mode;
    M7Schedule schedule;
    unsigned long long disableFlags;
    BOOL available;
} M7BlueLightStatus;

// Declared here so the compiler knows the selectors; the class is looked up at runtime.
@interface CBBlueLightClient : NSObject
- (BOOL)getBlueLightStatus:(M7BlueLightStatus *)status;
- (BOOL)getStrength:(float *)strength;
- (BOOL)setEnabled:(BOOL)enabled;
- (BOOL)setStrength:(float)strength commit:(BOOL)commit;
@end

static id sharedClient(void) {
    static id client = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW);
        Class cls = NSClassFromString(@"CBBlueLightClient");
        if (cls && [cls instancesRespondToSelector:@selector(getBlueLightStatus:)]
                && [cls instancesRespondToSelector:@selector(setStrength:commit:)]) {
            client = [[cls alloc] init];
        }
    });
    return client;
}

bool M7NightShiftRead(bool *enabled, float *strength) {
    id client = sharedClient();
    if (!client) return false;
    M7BlueLightStatus status;
    memset(&status, 0, sizeof status);
    float value = 0;
    if (![client getBlueLightStatus:&status]) return false;
    [client getStrength:&value];
    if (enabled) *enabled = status.enabled;
    if (strength) *strength = value;
    return true;
}

bool M7NightShiftSetEnabled(bool enabled) {
    id client = sharedClient();
    return client ? [client setEnabled:enabled] : false;
}

bool M7NightShiftSetStrength(float strength) {
    id client = sharedClient();
    if (!client) return false;
    float clamped = strength < 0 ? 0 : (strength > 1 ? 1 : strength);
    return [client setStrength:clamped commit:YES];
}

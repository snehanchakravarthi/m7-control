#ifndef NIGHT_SHIFT_BRIDGE_H
#define NIGHT_SHIFT_BRIDGE_H

#include <stdbool.h>

/// Thin wrapper over CBBlueLightClient in Apple's private CoreBrightness framework.
/// Every call returns false if the client is unavailable on this macOS version.

bool M7NightShiftRead(bool *enabled, float *strength);
bool M7NightShiftSetEnabled(bool enabled);
/// strength is 0.0 (least warm) to 1.0 (most warm).
bool M7NightShiftSetStrength(float strength);

#endif

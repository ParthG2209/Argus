//
//  StylusHIDBridge.h
//  Argus
//
//  Creates a virtual HID graphics tablet (digitizer/pen) via IOHIDUserDevice
//  so macOS treats incoming stylus input as a real pressure-sensitive
//  drawing tablet — preserving pressure and tilt that mouse-event injection
//  would throw away.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ArgusStylusHID : NSObject

/// True once the virtual HID device has been created successfully.
@property (nonatomic, readonly) BOOL isActive;

/// Create the virtual HID pen device. Returns NO if IOHIDUserDeviceCreate
/// fails (commonly: missing usb entitlement or sandbox enabled).
- (BOOL)create;

/// Tear down the virtual HID device.
- (void)destroy;

/// Send a single pen report.
///
/// @param x          Normalized 0.0–1.0 (scaled to 0–32767).
/// @param y          Normalized 0.0–1.0 (scaled to 0–32767).
/// @param pressure   Normalized 0.0–1.0 (scaled to 0–1023).
/// @param tiltX      Degrees, -90..+90.
/// @param tiltY      Degrees, -90..+90.
/// @param tipSwitch  YES while the pen is touching (down/move).
/// @param barrel     YES when the barrel (secondary) button is pressed.
/// @param eraser     YES when the eraser end is active.
/// @param inRange    YES when the pen is detected (touching or hovering).
- (void)sendReportX:(double)x
                  y:(double)y
           pressure:(double)pressure
              tiltX:(double)tiltX
              tiltY:(double)tiltY
          tipSwitch:(BOOL)tipSwitch
             barrel:(BOOL)barrel
             eraser:(BOOL)eraser
            inRange:(BOOL)inRange;

@end

NS_ASSUME_NONNULL_END

//
//  CGVirtualDisplayBridge.h
//  Argus
//
//  Swift-friendly Objective-C wrapper around the private CGVirtualDisplay
//  API. Swift cannot speak to the private C/ObjC classes directly, so this
//  bridge exposes a small, safe surface that the Swift VirtualDisplayManager
//  drives.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface ArgusVirtualDisplay : NSObject

/// The CGDirectDisplayID of the live virtual display, or kCGNullDirectDisplay
/// (0) if not currently created.
@property (nonatomic, readonly) CGDirectDisplayID displayID;

/// True while a virtual display is alive.
@property (nonatomic, readonly) BOOL isActive;

/// Create a virtual extended display advertising multiple HiDPI modes
/// (macOS-style scaling). Each (width,height) pair is a POINT ("looks like")
/// size; with hiDPI=YES the backing framebuffer is 2x those points.
///
/// @param widths      C array of mode widths in POINTS, one per mode.
/// @param heights     C array of mode heights in POINTS, one per mode.
/// @param modeCount   Number of entries in widths/heights.
/// @param defaultIdx  Index of the mode to activate after creation.
/// @param refreshHz   Refresh rate (e.g. 60.0).
/// @param hiDPI       YES to expose modes as 2x Retina modes.
/// @param widthMM     Physical width in millimeters (e.g. 597).
/// @param heightMM    Physical height in millimeters (e.g. 336).
/// @param name        Display name shown in System Settings.
/// @return YES on success. On success `displayID` is valid.
- (BOOL)createWithModeWidths:(const uint32_t *)widths
                 modeHeights:(const uint32_t *)heights
                   modeCount:(NSUInteger)modeCount
                 defaultMode:(NSUInteger)defaultIdx
                   refreshHz:(double)refreshHz
                       hiDPI:(BOOL)hiDPI
                     widthMM:(double)widthMM
                    heightMM:(double)heightMM
                        name:(NSString *)name;

/// Switch the active display mode to the one whose framebuffer pixel size
/// matches (pixelWidth, pixelHeight). Returns NO if no matching mode is found.
- (BOOL)setActiveModePixelWidth:(uint32_t)pixelWidth
                    pixelHeight:(uint32_t)pixelHeight
                      refreshHz:(double)targetRefreshHz;

/// Tear down the virtual display and release the backing object.
- (void)destroy;

/// Position this display immediately to the right of the primary display,
/// using a CGBeginDisplayConfiguration / CGCompleteDisplayConfiguration
/// transaction. No-op if not active.
- (void)positionToRightOfPrimary;

@end

NS_ASSUME_NONNULL_END

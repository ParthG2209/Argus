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

/// Create a virtual extended display.
///
/// @param pixelsWide  Native panel width in pixels (e.g. 2732).
/// @param pixelsHigh  Native panel height in pixels (e.g. 2048).
/// @param refreshHz   Refresh rate (e.g. 60.0).
/// @param hiDPI       YES to enable 2x backing (Retina). Render res becomes
///                    2*pixelsWide x 2*pixelsHigh internally.
/// @param widthMM     Physical width in millimeters (e.g. 597).
/// @param heightMM    Physical height in millimeters (e.g. 336).
/// @param name        Display name shown in System Settings.
/// @return YES on success. On success `displayID` is valid.
- (BOOL)createWithPixelsWide:(uint32_t)pixelsWide
                  pixelsHigh:(uint32_t)pixelsHigh
                   refreshHz:(double)refreshHz
                       hiDPI:(BOOL)hiDPI
                     widthMM:(double)widthMM
                    heightMM:(double)heightMM
                        name:(NSString *)name;

/// Tear down the virtual display and release the backing object.
- (void)destroy;

/// Position this display immediately to the right of the primary display,
/// using a CGBeginDisplayConfiguration / CGCompleteDisplayConfiguration
/// transaction. No-op if not active.
- (void)positionToRightOfPrimary;

@end

NS_ASSUME_NONNULL_END

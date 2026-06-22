//
//  CGVirtualDisplayPrivate.h
//  Argus
//
//  Reverse-engineered declarations for the *private* CoreGraphics
//  CGVirtualDisplay Objective-C API. These classes live inside
//  CoreGraphics.framework but ship with no public headers, so we declare
//  the interface ourselves. The runtime provides the implementations.
//
//  Verified against macOS 13–15. The class-based interface below is the one
//  that actually exists at runtime (the older C-style CGVirtualDisplayCreate
//  symbols referenced in some docs are thin wrappers / no longer exported).
//
//  THIS IS A PRIVATE API. It is not App-Store-safe and may change between
//  macOS releases. Argus is a locally-signed, sandbox-disabled tool, which
//  is exactly the context this is intended for.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@class CGVirtualDisplay;

#pragma mark - Descriptor

/// Immutable-at-create description of the virtual EDID-like display.
@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy)   NSString *name;

// Maximum addressable pixel dimensions (the panel's native pixel count).
@property (nonatomic, assign) unsigned int maxPixelsWide;
@property (nonatomic, assign) unsigned int maxPixelsHigh;

// Physical size — drives the reported DPI. Setting a generous size avoids
// CGVirtualDisplay's high-pixel-density rejection threshold.
@property (nonatomic, assign) CGSize sizeInMillimeters;

@property (nonatomic, assign) unsigned int serialNum;
@property (nonatomic, assign) unsigned int productID;
@property (nonatomic, assign) unsigned int vendorID;

// Called by CoreGraphics when the display is torn down by the system.
@property (nonatomic, copy, nullable) void (^terminationHandler)(id _Nullable terminationData, id _Nullable display);
@end

#pragma mark - Mode

/// One resolution + refresh-rate the virtual display advertises.
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@property (nonatomic, readonly) unsigned int width;
@property (nonatomic, readonly) unsigned int height;
@property (nonatomic, readonly) double refreshRate;
@end

#pragma mark - Settings

/// Mutable settings applied after creation. hiDPI=1 enables 2x backing.
@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, assign) unsigned int hiDPI;
@property (nonatomic, strong) NSArray<CGVirtualDisplayMode *> *modes;
@end

#pragma mark - Display

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;

@property (nonatomic, readonly) CGDirectDisplayID displayID;
@property (nonatomic, readonly) unsigned int hiDPI;
@property (nonatomic, readonly) NSArray<CGVirtualDisplayMode *> *modes;
@end

NS_ASSUME_NONNULL_END

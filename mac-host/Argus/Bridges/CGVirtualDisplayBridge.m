//
//  CGVirtualDisplayBridge.m
//  Argus
//

#import "CGVirtualDisplayBridge.h"
#import "CGVirtualDisplayPrivate.h"

@interface ArgusVirtualDisplay ()
@property (nonatomic, strong, nullable) CGVirtualDisplay *display;
@property (nonatomic, strong, nullable) dispatch_queue_t displayQueue;
@end

@implementation ArgusVirtualDisplay

- (CGDirectDisplayID)displayID {
    return self.display ? self.display.displayID : kCGNullDirectDisplay;
}

- (BOOL)isActive {
    return self.display != nil && self.display.displayID != kCGNullDirectDisplay;
}

- (BOOL)createWithPixelsWide:(uint32_t)pixelsWide
                  pixelsHigh:(uint32_t)pixelsHigh
                   refreshHz:(double)refreshHz
                       hiDPI:(BOOL)hiDPI
                     widthMM:(double)widthMM
                    heightMM:(double)heightMM
                        name:(NSString *)name {
    if (self.display) {
        [self destroy];
    }

    // Class availability guard — fail gracefully on an OS that renamed the
    // private classes rather than crashing.
    Class descClass     = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeClass     = NSClassFromString(@"CGVirtualDisplayMode");
    Class displayClass  = NSClassFromString(@"CGVirtualDisplay");
    if (!descClass || !settingsClass || !modeClass || !displayClass) {
        NSLog(@"[Argus] CGVirtualDisplay private classes unavailable on this OS.");
        return NO;
    }

    self.displayQueue = dispatch_queue_create("com.argus.virtualdisplay",
                                              DISPATCH_QUEUE_SERIAL);

    CGVirtualDisplayDescriptor *descriptor = [[descClass alloc] init];
    descriptor.queue             = self.displayQueue;
    descriptor.name              = name;
    descriptor.maxPixelsWide     = pixelsWide;
    descriptor.maxPixelsHigh     = pixelsHigh;
    descriptor.sizeInMillimeters = CGSizeMake(widthMM, heightMM);
    descriptor.productID         = 0x1234;
    descriptor.vendorID          = 0x3456;
    descriptor.serialNum         = 0x0001;

    __weak typeof(self) weakSelf = self;
    descriptor.terminationHandler = ^(id _Nullable terminationData, id _Nullable display) {
        NSLog(@"[Argus] Virtual display terminated by system.");
        // Drop our reference on the main queue.
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.display = nil;
        });
    };

    CGVirtualDisplay *vd = [[displayClass alloc] initWithDescriptor:descriptor];
    if (!vd) {
        NSLog(@"[Argus] Failed to allocate CGVirtualDisplay.");
        return NO;
    }

    CGVirtualDisplayMode *mode =
        [[modeClass alloc] initWithWidth:pixelsWide
                                  height:pixelsHigh
                             refreshRate:refreshHz];

    CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
    settings.hiDPI = hiDPI ? 1 : 0;
    settings.modes = @[ mode ];

    if (![vd applySettings:settings]) {
        NSLog(@"[Argus] applySettings: failed (density rejection?). "
               "Try a larger sizeInMillimeters.");
        return NO;
    }

    self.display = vd;
    NSLog(@"[Argus] Virtual display created: displayID=%u  %ux%u@%.0fHz hiDPI=%d",
          vd.displayID, pixelsWide, pixelsHigh, refreshHz, hiDPI);
    return YES;
}

- (void)destroy {
    if (self.display) {
        NSLog(@"[Argus] Destroying virtual display %u", self.display.displayID);
    }
    // Releasing the CGVirtualDisplay instance tears it down.
    self.display = nil;
    self.displayQueue = nil;
}

- (void)positionToRightOfPrimary {
    if (![self isActive]) { return; }

    CGDirectDisplayID virtualID = self.display.displayID;
    CGDirectDisplayID mainID    = CGMainDisplayID();
    if (virtualID == mainID) { return; }

    // Place the virtual display's top-left at the primary's right edge.
    CGRect mainBounds = CGDisplayBounds(mainID);
    int32_t originX = (int32_t)(mainBounds.origin.x + mainBounds.size.width);
    int32_t originY = (int32_t)mainBounds.origin.y;

    CGDisplayConfigRef config;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) {
        NSLog(@"[Argus] CGBeginDisplayConfiguration failed.");
        return;
    }
    CGConfigureDisplayOrigin(config, virtualID, originX, originY);
    if (CGCompleteDisplayConfiguration(config, kCGConfigurePermanently) != kCGErrorSuccess) {
        NSLog(@"[Argus] CGCompleteDisplayConfiguration failed.");
        CGCancelDisplayConfiguration(config);
        return;
    }
    NSLog(@"[Argus] Positioned virtual display at (%d, %d).", originX, originY);
}

@end

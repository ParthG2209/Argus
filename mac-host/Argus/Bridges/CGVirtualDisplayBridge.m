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

- (BOOL)createWithModeWidths:(const uint32_t *)widths
                 modeHeights:(const uint32_t *)heights
                   modeCount:(NSUInteger)modeCount
                 defaultMode:(NSUInteger)defaultIdx
                   refreshHz:(double)refreshHz
                       hiDPI:(BOOL)hiDPI
                     widthMM:(double)widthMM
                    heightMM:(double)heightMM
                        name:(NSString *)name {
    if (self.display) {
        [self destroy];
    }
    if (modeCount == 0) { return NO; }

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

    // `widths`/`heights` are POINT dimensions (the "looks like" sizes passed
    // to each CGVirtualDisplayMode). Under hiDPI the actual framebuffer is 2x,
    // so the max addressable pixel count must be 2x the largest point size or
    // every mode is rejected and the display falls back to 800x600.
    uint32_t maxPt = 0, maxPtH = 0;
    for (NSUInteger i = 0; i < modeCount; i++) {
        if (widths[i]  > maxPt)  maxPt  = widths[i];
        if (heights[i] > maxPtH) maxPtH = heights[i];
    }
    uint32_t scale = hiDPI ? 2 : 1;
    uint32_t maxW = maxPt * scale;
    uint32_t maxH = maxPtH * scale;

    self.displayQueue = dispatch_queue_create("com.argus.virtualdisplay",
                                              DISPATCH_QUEUE_SERIAL);

    CGVirtualDisplayDescriptor *descriptor = [[descClass alloc] init];
    descriptor.queue             = self.displayQueue;
    descriptor.name              = name;
    descriptor.maxPixelsWide     = maxW;
    descriptor.maxPixelsHigh     = maxH;
    descriptor.sizeInMillimeters = CGSizeMake(widthMM, heightMM);
    descriptor.productID         = 0x1234;
    descriptor.vendorID          = 0x3456;
    descriptor.serialNum         = 0x0001;

    __weak typeof(self) weakSelf = self;
    descriptor.terminationHandler = ^(id _Nullable terminationData, id _Nullable display) {
        NSLog(@"[Argus] Virtual display terminated by system.");
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.display = nil;
        });
    };

    CGVirtualDisplay *vd = [[displayClass alloc] initWithDescriptor:descriptor];
    if (!vd) {
        NSLog(@"[Argus] Failed to allocate CGVirtualDisplay.");
        return NO;
    }

    NSMutableArray<CGVirtualDisplayMode *> *modes = [NSMutableArray array];
    for (NSUInteger i = 0; i < modeCount; i++) {
        [modes addObject:[[modeClass alloc] initWithWidth:widths[i]
                                                   height:heights[i]
                                              refreshRate:refreshHz]];
    }

    CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
    settings.hiDPI = hiDPI ? 1 : 0;
    settings.modes = modes;

    if (![vd applySettings:settings]) {
        NSLog(@"[Argus] applySettings: failed (density rejection?). "
               "Try a larger sizeInMillimeters.");
        return NO;
    }

    self.display = vd;
    NSLog(@"[Argus] Virtual display created: displayID=%u  %lu modes, hiDPI=%d",
          vd.displayID, (unsigned long)modeCount, hiDPI);

    // Activate the requested default scaling mode. macOS needs time to
    // register the display after creation — poll until modes appear (up to 2s).
    if (defaultIdx < modeCount) {
        uint32_t targetW = widths[defaultIdx] * scale;
        uint32_t targetH = heights[defaultIdx] * scale;
        BOOL modeSet = [self setActiveModePixelWidth:targetW pixelHeight:targetH];
        if (!modeSet) {
            NSLog(@"[Argus] WARNING: could not set display mode after 2s. "
                   "macOS may be running at a default (60Hz) refresh rate.");
        }
        // Log the actual active refresh rate regardless.
        CGDisplayModeRef active = CGDisplayCopyDisplayMode(vd.displayID);
        if (active) {
            double hz = CGDisplayModeGetRefreshRate(active);
            size_t pw = CGDisplayModeGetPixelWidth(active);
            size_t ph = CGDisplayModeGetPixelHeight(active);
            NSLog(@"[Argus] ACTUAL active mode: %zux%zu @ %.2f Hz", pw, ph, hz);
            CGDisplayModeRelease(active);
        } else {
            NSLog(@"[Argus] WARNING: CGDisplayCopyDisplayMode returned NULL.");
        }
    }
    return YES;
}

- (BOOL)setActiveModePixelWidth:(uint32_t)pixelWidth
                    pixelHeight:(uint32_t)pixelHeight {
    if (![self isActive]) { return NO; }
    CGDirectDisplayID did = self.display.displayID;

    // Include HiDPI ("duplicate low-resolution") modes in the listing.
    NSDictionary *opts = @{ (__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes : @YES };
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(did, (__bridge CFDictionaryRef)opts);
    if (!modes) { return NO; }

    // Among modes matching the pixel size, pick the HIGHEST refresh rate.
    // macOS often lists several refresh variants per resolution (e.g. a 60 Hz
    // duplicate next to our 144 Hz mode); taking the first match would silently
    // land on the low-refresh one.
    CGDisplayModeRef match = NULL;
    double matchRefresh = -1.0;
    CFIndex count = CFArrayGetCount(modes);
    for (CFIndex i = 0; i < count; i++) {
        CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        size_t mw = CGDisplayModeGetPixelWidth(m);
        size_t mh = CGDisplayModeGetPixelHeight(m);
        double r = CGDisplayModeGetRefreshRate(m);
        
        if (mw == pixelWidth && mh == pixelHeight) {
            if (r > matchRefresh) { matchRefresh = r; match = m; }
        }
    }

    BOOL ok = NO;
    if (match) {
        CGDisplayConfigRef config;
        if (CGBeginDisplayConfiguration(&config) == kCGErrorSuccess) {
            CGConfigureDisplayWithDisplayMode(config, did, match, NULL);
            ok = (CGCompleteDisplayConfiguration(config, kCGConfigurePermanently) == kCGErrorSuccess);
            if (ok) {
                // Read back what's actually active now.
                CGDisplayModeRef active = CGDisplayCopyDisplayMode(did);
                double activeR = active ? CGDisplayModeGetRefreshRate(active) : 0;
                if (active) CGDisplayModeRelease(active);
                NSLog(@"[Argus] Active mode set: framebuffer %ux%u (looks like %ux%u) "
                       "@ %.2f Hz (active now reports %.2f Hz).",
                      pixelWidth, pixelHeight, pixelWidth / 2, pixelHeight / 2,
                      matchRefresh, activeR);
            }
        }
    } else {
        NSLog(@"[Argus] No display mode matching framebuffer %ux%u.", pixelWidth, pixelHeight);
    }
    CFRelease(modes);
    return ok;
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

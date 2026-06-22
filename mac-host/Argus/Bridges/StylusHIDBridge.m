//
//  StylusHIDBridge.m
//  Argus
//

#import "StylusHIDBridge.h"
#import <IOKit/hid/IOHIDKeys.h>
#import <IOKit/IOReturn.h>
#import <CoreFoundation/CoreFoundation.h>

// IOHIDUserDevice is a *private* IOKit API: the symbols are exported from
// IOKit.framework, but the header (IOKit/hid/IOHIDUserDevice.h) is not shipped
// in the public macOS SDK. Forward-declare the functions we use so the
// compiler is satisfied; the linker resolves them against IOKit.framework.
typedef struct __IOHIDUserDevice * IOHIDUserDeviceRef;

extern IOHIDUserDeviceRef IOHIDUserDeviceCreate(CFAllocatorRef allocator,
                                                CFDictionaryRef properties)
    CF_RETURNS_RETAINED;

extern IOReturn IOHIDUserDeviceHandleReport(IOHIDUserDeviceRef device,
                                            const uint8_t *report,
                                            CFIndex reportLength);

// HID report descriptor: a single-finger digitizer "Pen".
//
// Report layout (11 bytes, little-endian, no report ID):
//   byte 0      : bit0 TipSwitch, bit1 Barrel, bit2 Eraser, bit3 InRange,
//                 bits4-7 padding
//   bytes 1-2   : Tip Pressure  uint16  (0..1023)
//   bytes 3-4   : X             uint16  (0..32767)
//   bytes 5-6   : Y             uint16  (0..32767)
//   bytes 7-8   : X Tilt        int16   (-90..90)
//   bytes 9-10  : Y Tilt        int16   (-90..90)
static const uint8_t kArgusPenReportDescriptor[] = {
    0x05, 0x0D,             // Usage Page (Digitizers)
    0x09, 0x02,             // Usage (Pen)
    0xA1, 0x01,             // Collection (Application)
    0x09, 0x20,             //   Usage (Stylus)
    0xA1, 0x00,             //   Collection (Physical)

    // --- Buttons: Tip, Barrel, Eraser, In Range (4 x 1 bit) ---
    0x09, 0x42,             //     Usage (Tip Switch)
    0x09, 0x44,             //     Usage (Barrel Switch)
    0x09, 0x45,             //     Usage (Eraser)
    0x09, 0x32,             //     Usage (In Range)
    0x15, 0x00,             //     Logical Minimum (0)
    0x25, 0x01,             //     Logical Maximum (1)
    0x75, 0x01,             //     Report Size (1)
    0x95, 0x04,             //     Report Count (4)
    0x81, 0x02,             //     Input (Data,Var,Abs)
    // padding to fill the byte
    0x75, 0x01,             //     Report Size (1)
    0x95, 0x04,             //     Report Count (4)
    0x81, 0x03,             //     Input (Const,Var,Abs)

    // --- Tip Pressure (uint16, 0..1023) ---
    0x09, 0x30,             //     Usage (Tip Pressure)
    0x15, 0x00,             //     Logical Minimum (0)
    0x26, 0xFF, 0x03,       //     Logical Maximum (1023)
    0x75, 0x10,             //     Report Size (16)
    0x95, 0x01,             //     Report Count (1)
    0x81, 0x02,             //     Input (Data,Var,Abs)

    // --- X, Y (Generic Desktop, uint16, 0..32767) ---
    0x05, 0x01,             //     Usage Page (Generic Desktop)
    0x09, 0x30,             //     Usage (X)
    0x09, 0x31,             //     Usage (Y)
    0x16, 0x00, 0x00,       //     Logical Minimum (0)
    0x26, 0xFF, 0x7F,       //     Logical Maximum (32767)
    0x75, 0x10,             //     Report Size (16)
    0x95, 0x02,             //     Report Count (2)
    0x81, 0x02,             //     Input (Data,Var,Abs)

    // --- Tilt X, Tilt Y (Digitizers, int16, -90..90) ---
    0x05, 0x0D,             //     Usage Page (Digitizers)
    0x09, 0x3D,             //     Usage (X Tilt)
    0x09, 0x3E,             //     Usage (Y Tilt)
    0x16, 0xA6, 0xFF,       //     Logical Minimum (-90)
    0x26, 0x5A, 0x00,       //     Logical Maximum (90)
    0x75, 0x10,             //     Report Size (16)
    0x95, 0x02,             //     Report Count (2)
    0x81, 0x02,             //     Input (Data,Var,Abs)

    0xC0,                   //   End Collection
    0xC0                    // End Collection
};

#pragma pack(push, 1)
typedef struct {
    uint8_t  buttons;   // bit0 tip, bit1 barrel, bit2 eraser, bit3 inrange
    uint16_t pressure;  // 0..1023
    uint16_t x;         // 0..32767
    uint16_t y;         // 0..32767
    int16_t  tiltX;     // -90..90
    int16_t  tiltY;     // -90..90
} ArgusPenReport;
#pragma pack(pop)

@interface ArgusStylusHID ()
@property (nonatomic, assign) IOHIDUserDeviceRef device;
@end

@implementation ArgusStylusHID

- (BOOL)isActive { return self.device != NULL; }

- (BOOL)create {
    if (self.device) { return YES; }

    NSData *descriptor = [NSData dataWithBytes:kArgusPenReportDescriptor
                                        length:sizeof(kArgusPenReportDescriptor)];

    NSDictionary *properties = @{
        @(kIOHIDReportDescriptorKey) : descriptor,
        @(kIOHIDVendorIDKey)         : @(0x056A),   // Wacom vendor ID
        @(kIOHIDProductIDKey)        : @(0x0000),
        @(kIOHIDProductKey)          : @"Argus Pen Input",
        @(kIOHIDManufacturerKey)     : @"Argus",
        @(kIOHIDSerialNumberKey)     : @"ARGUS-PEN-0001",
    };

    self.device = IOHIDUserDeviceCreate(kCFAllocatorDefault,
                                        (__bridge CFDictionaryRef)properties);
    if (!self.device) {
        NSLog(@"[Argus] IOHIDUserDeviceCreate failed — check the usb "
               "entitlement and that the App Sandbox is disabled.");
        return NO;
    }
    NSLog(@"[Argus] Virtual HID pen device created.");
    return YES;
}

- (void)destroy {
    if (self.device) {
        CFRelease(self.device);
        self.device = NULL;
        NSLog(@"[Argus] Virtual HID pen device destroyed.");
    }
}

static inline uint16_t scaleU16(double norm, uint16_t maxValue) {
    if (norm < 0.0) norm = 0.0;
    if (norm > 1.0) norm = 1.0;
    return (uint16_t)lround(norm * (double)maxValue);
}

static inline int16_t clampTilt(double deg) {
    if (deg < -90.0) deg = -90.0;
    if (deg >  90.0) deg =  90.0;
    return (int16_t)lround(deg);
}

- (void)sendReportX:(double)x
                  y:(double)y
           pressure:(double)pressure
              tiltX:(double)tiltX
              tiltY:(double)tiltY
          tipSwitch:(BOOL)tipSwitch
             barrel:(BOOL)barrel
             eraser:(BOOL)eraser
            inRange:(BOOL)inRange {
    if (!self.device) { return; }

    ArgusPenReport report;
    report.buttons  = (uint8_t)((tipSwitch ? 0x01 : 0) |
                                (barrel    ? 0x02 : 0) |
                                (eraser    ? 0x04 : 0) |
                                (inRange   ? 0x08 : 0));
    report.pressure = scaleU16(pressure, 1023);
    report.x        = scaleU16(x, 32767);
    report.y        = scaleU16(y, 32767);
    report.tiltX    = clampTilt(tiltX);
    report.tiltY    = clampTilt(tiltY);

    IOReturn result = IOHIDUserDeviceHandleReport(self.device,
                                                  (const uint8_t *)&report,
                                                  sizeof(report));
    if (result != kIOReturnSuccess) {
        NSLog(@"[Argus] IOHIDUserDeviceHandleReport error: 0x%08x", result);
    }
}

@end

#import "Presence.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <UIKit/UIKit.h>

#define GW 16
#define GH 12

@interface Presence () <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) CIDetector *faces;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, copy) NSString *problem;
@end

@implementation Presence {
    float _prev[GW * GH];
    BOOL _havePrev;
    CFAbsoluteTime _lastFace;
}

- (instancetype)init {
    if ((self = [super init])) {
        _sensitivity = 4;
        _queue = dispatch_queue_create("presence", DISPATCH_QUEUE_SERIAL);
        _faces = [CIDetector detectorOfType:CIDetectorTypeFace context:nil options:@{CIDetectorAccuracy: CIDetectorAccuracyLow}];
    }
    return self;
}

- (void)start {
    if (self.running) return;
    AVAuthorizationStatus st = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (st == AVAuthorizationStatusNotDetermined) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (granted) [self start]; else self.problem = @"camera access denied"; });
        }];
        return;
    }
    if (st != AVAuthorizationStatusAuthorized) { self.problem = @"camera access denied (Settings → Privacy → Camera)"; return; }

    AVCaptureDevice *cam = nil;
    for (AVCaptureDevice *d in [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo])
        if (d.position == AVCaptureDevicePositionFront) cam = d;
    if (!cam) { self.problem = @"no front camera"; return; }

    NSError *err = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:cam error:&err];
    if (!input) { self.problem = err.localizedDescription ?: @"camera input failed"; return; }

    AVCaptureSession *s = [[AVCaptureSession alloc] init];
    if ([s canSetSessionPreset:AVCaptureSessionPresetLow]) s.sessionPreset = AVCaptureSessionPresetLow;
    if (![s canAddInput:input]) { self.problem = @"camera busy"; return; }
    [s addInput:input];

    AVCaptureVideoDataOutput *out = [[AVCaptureVideoDataOutput alloc] init];
    out.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
    out.alwaysDiscardsLateVideoFrames = YES;
    [out setSampleBufferDelegate:self queue:self.queue];
    if (![s canAddOutput:out]) { self.problem = @"camera output failed"; return; }
    [s addOutput:out];

    // ~5 fps is plenty and keeps the A5 cool
    if ([cam lockForConfiguration:nil]) {
        if ([cam respondsToSelector:@selector(setActiveVideoMinFrameDuration:)]) {
            cam.activeVideoMinFrameDuration = CMTimeMake(1, 5);
            cam.activeVideoMaxFrameDuration = CMTimeMake(1, 5);
        }
        [cam unlockForConfiguration];
    }

    self.session = s;
    _havePrev = NO;
    self.problem = nil;
    dispatch_async(self.queue, ^{ [s startRunning]; });
    self.running = YES;
}

- (void)stop {
    AVCaptureSession *s = self.session;
    self.session = nil;
    self.running = NO;
    if (s) dispatch_async(self.queue, ^{ [s stopRunning]; });
}

- (void)fire:(NSString *)reason {
    dispatch_async(dispatch_get_main_queue(), ^{ if (self.onPresence) self.onPresence(reason); });
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sb fromConnection:(AVCaptureConnection *)conn {
    CVImageBufferRef px = CMSampleBufferGetImageBuffer(sb);
    if (!px) return;

    // --- motion: average brightness per grid cell, compare with previous frame
    CVPixelBufferLockBaseAddress(px, kCVPixelBufferLock_ReadOnly);
    uint8_t *base = CVPixelBufferGetBaseAddress(px);
    size_t w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px), bpr = CVPixelBufferGetBytesPerRow(px);
    float cur[GW * GH];
    for (int gy = 0; gy < GH; gy++) {
        for (int gx = 0; gx < GW; gx++) {
            size_t x0 = gx * w / GW, x1 = (gx + 1) * w / GW, y0 = gy * h / GH, y1 = (gy + 1) * h / GH;
            unsigned long sum = 0, n = 0;
            for (size_t y = y0; y < y1; y += 2) {
                uint8_t *row = base + y * bpr;
                for (size_t x = x0; x < x1; x += 2) {
                    uint8_t *p = row + x * 4;   // BGRA
                    sum += (p[0] + 2 * p[1] + p[2]) >> 2;
                    n++;
                }
            }
            cur[gy * GW + gx] = n ? (float)sum / n : 0;
        }
    }
    CVPixelBufferUnlockBaseAddress(px, kCVPixelBufferLock_ReadOnly);

    if (_havePrev) {
        int changed = 0;
        for (int i = 0; i < GW * GH; i++) if (fabsf(cur[i] - _prev[i]) > 14.0f) changed++;
        if (changed >= self.sensitivity) [self fire:@"motion"];
    }
    memcpy(_prev, cur, sizeof(cur));
    _havePrev = YES;

    // --- face: once a second, try both landscape orientations of the front camera
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - _lastFace >= 1.0) {
        _lastFace = now;
        CIImage *img = [CIImage imageWithCVPixelBuffer:px];
        NSArray *orients = self.landscapeLeft ? @[@3, @1] : @[@1, @3];
        for (NSNumber *o in orients) {
            if ([self.faces featuresInImage:img options:@{CIDetectorImageOrientation: o}].count) { [self fire:@"face"]; break; }
        }
    }
}

@end

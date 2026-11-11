#import <Foundation/Foundation.h>

// Front-camera presence detector. Frames are analysed in memory and discarded;
// nothing is recorded, stored or sent anywhere.
//  - motion: compares a 16x12 grid of average brightness between frames (~5 fps)
//  - face:   CoreImage face detection once a second (keeps the screen on while someone sits still)
@interface Presence : NSObject

@property (nonatomic, copy) void (^onPresence)(NSString *reason);   // called on main queue, "motion" or "face"
@property (nonatomic, assign) NSInteger sensitivity;                 // cells that must change: 2 = high, 4 = medium, 8 = low
@property (nonatomic, assign) BOOL landscapeLeft;                   // set from UI orientation for face detection
@property (nonatomic, readonly) BOOL running;
@property (nonatomic, copy, readonly) NSString *problem;            // non-nil if the camera could not start

- (void)start;
- (void)stop;

@end

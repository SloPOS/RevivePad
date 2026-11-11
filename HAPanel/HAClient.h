#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// Append a line to /var/mobile/Library/HAPanel/debug.log (read it over SSH).
void HALog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
// https://<ip with dashes>.<hash>.plex.direct:32400/... -> http://<ip>:32400/... (iOS 8 cannot check that certificate)
NSString *DePlexDirectURL(NSString *url);

typedef void (^HAStateBlock)(NSDictionary *state, NSError *error);
typedef void (^HAJSONBlock)(id json, NSError *error);
typedef void (^HAImageBlock)(UIImage *image);

// Minimal Home Assistant REST client (iOS 8 compatible, plain NSURLSession).
@interface HAClient : NSObject

@property (nonatomic, copy) NSString *baseURL;   // e.g. http://192.168.1.10:8123
@property (nonatomic, copy) NSString *token;     // long-lived access token
@property (nonatomic, copy) NSString *panel;     // which layout file to load, e.g. "bedroom"

+ (instancetype)shared;
- (BOOL)isConfigured;
- (void)reloadConfig;
// Writes config.plist (readable by the app's user only). A nil or empty token keeps the stored one.
- (BOOL)saveURL:(NSString *)url token:(NSString *)token panel:(NSString *)panel;

- (void)getState:(NSString *)entityId completion:(HAStateBlock)completion;
- (void)callService:(NSString *)domain service:(NSString *)service data:(NSDictionary *)data completion:(HAJSONBlock)completion;
- (void)callServiceWithResponse:(NSString *)domain service:(NSString *)service data:(NSDictionary *)data completion:(HAJSONBlock)completion;
- (void)loadImagePath:(NSString *)path completion:(HAImageBlock)completion;
// Fetches /local/hapanel/<panel>.json; returns raw data so callers can detect changes.
- (void)fetchLayout:(void (^)(NSData *data, NSError *error))completion;
// Fetches any file under /local/hapanel/, e.g. "home.json" (shared by every iPad).
- (void)fetchPanelFile:(NSString *)name completion:(void (^)(NSData *data, NSError *error))completion;
// POST /api/template; the template must output JSON.
- (void)renderTemplate:(NSString *)tpl completion:(HAJSONBlock)completion;
// Uncached image fetch (photo frame, camera snapshots). auth adds the HA token; downscaled to maxSide.
- (void)fetchImageURL:(NSString *)url auth:(BOOL)auth maxSide:(CGFloat)maxSide completion:(HAImageBlock)completion;
// Small JSON disk cache (Library/Caches/HAPanel/json). maxAge 0 = any age.
- (NSData *)cachedJSONForKey:(NSString *)key maxAge:(NSTimeInterval)age;
- (void)storeJSON:(NSData *)data forKey:(NSString *)key;
// GET any API path, e.g. /api/history/period/...
- (void)getJSON:(NSString *)path completion:(HAJSONBlock)completion;

@end

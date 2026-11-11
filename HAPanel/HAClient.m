#import "HAClient.h"

// Connection settings: /var/mobile/Library/HAPanel/config.plist  { url, token, panel }.
// Written by the app's own Connection form (gear) or over SSH (tools/configure.sh).
static NSString *const kConfigPath = @"/var/mobile/Library/HAPanel/config.plist";
static NSString *const kDefaultURL = @"http://homeassistant.local:8123";   // overridden by "url" in config.plist

@interface HAClient ()
@property (nonatomic, strong) NSURLSession *session, *imageSession;
@end

// Debug log readable over SSH: /var/mobile/Library/HAPanel/debug.log (rotated at 256 KB)
void HALog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    static dispatch_queue_t q; static NSDateFormatter *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("halog", DISPATCH_QUEUE_SERIAL);
        f = [[NSDateFormatter alloc] init]; f.dateFormat = @"HH:mm:ss";
    });
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [f stringFromDate:[NSDate date]], msg];
    dispatch_async(q, ^{
        NSString *path = @"/var/mobile/Library/HAPanel/debug.log";
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        if ([attrs fileSize] > 256 * 1024) {
            [[NSFileManager defaultManager] removeItemAtPath:[path stringByAppendingString:@".1"] error:nil];
            [[NSFileManager defaultManager] moveItemAtPath:path toPath:[path stringByAppendingString:@".1"] error:nil];
        }
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!h) { [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil]; h = [NSFileHandle fileHandleForWritingAtPath:path]; }
        [h seekToEndOfFile];
        [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [h closeFile];
    });
}

// Disk cache for images and JSON (Library/Caches/HAPanel), so album art and library pages survive restarts.
static NSString *CachePath(NSString *kind, NSString *key) {
    NSString *dir = [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject] stringByAppendingPathComponent:[@"HAPanel/" stringByAppendingString:kind]];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    unsigned long long h = 1469598103934665603ULL;   // FNV-1a, good enough for file names
    for (NSUInteger i = 0; i < key.length; i++) { h ^= [key characterAtIndex:i]; h *= 1099511628211ULL; }
    return [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%016llx", h]];
}

@implementation HAClient

- (NSData *)cachedJSONForKey:(NSString *)key maxAge:(NSTimeInterval)age {
    NSString *p = CachePath(@"json", key);
    NSDate *m = [[[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil] fileModificationDate];
    if (!m || (age > 0 && [[NSDate date] timeIntervalSinceDate:m] > age)) return nil;
    return [NSData dataWithContentsOfFile:p];
}

- (void)storeJSON:(NSData *)data forKey:(NSString *)key {
    if (data.length) [data writeToFile:CachePath(@"json", key) atomically:YES];
}

+ (instancetype)shared {
    static HAClient *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [[HAClient alloc] init]; });
    return c;
}

- (instancetype)init {
    if ((self = [super init])) {
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.timeoutIntervalForRequest = 8;
        cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        _session = [NSURLSession sessionWithConfiguration:cfg];
        // images get their own session with few parallel downloads, so a page of album art
        // can't starve state polling or overwhelm the A5
        NSURLSessionConfiguration *ic = [NSURLSessionConfiguration defaultSessionConfiguration];
        ic.timeoutIntervalForRequest = 20;
        ic.HTTPMaximumConnectionsPerHost = 3;
        ic.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        _imageSession = [NSURLSession sessionWithConfiguration:ic];
        [self reloadConfig];
    }
    return self;
}

- (void)reloadConfig {
    NSDictionary *file = [NSDictionary dictionaryWithContentsOfFile:kConfigPath];
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *url = file[@"url"] ?: [d stringForKey:@"url"] ?: kDefaultURL;
    NSString *tok = file[@"token"] ?: [d stringForKey:@"token"];
    while ([url hasSuffix:@"/"]) url = [url substringToIndex:url.length - 1];
    self.baseURL = url;
    self.token = [tok stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *panel = file[@"panel"] ?: @"default";
    self.panel = [panel stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (BOOL)saveURL:(NSString *)url token:(NSString *)token panel:(NSString *)panel {
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:[NSDictionary dictionaryWithContentsOfFile:kConfigPath] ?: @{}];
    url = [url stringByTrimmingCharactersInSet:ws];
    if (url.length && [url rangeOfString:@"://"].location == NSNotFound) url = [@"http://" stringByAppendingString:url];
    if (url.length) d[@"url"] = url;
    token = [token stringByTrimmingCharactersInSet:ws];
    if (token.length) d[@"token"] = token;
    panel = [[panel stringByTrimmingCharactersInSet:ws] lowercaseString];
    if (panel.length) d[@"panel"] = panel;
    [[NSFileManager defaultManager] createDirectoryAtPath:[kConfigPath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    BOOL ok = [d writeToFile:kConfigPath atomically:YES];
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:kConfigPath error:nil];
    [self reloadConfig];
    return ok;
}

- (void)fetchLayout:(void (^)(NSData *, NSError *))completion {
    [self fetchPanelFile:[self.panel stringByAppendingString:@".json"] completion:completion];
}

- (void)fetchImageURL:(NSString *)url auth:(BOOL)auth maxSide:(CGFloat)maxSide completion:(HAImageBlock)completion {
    NSString *full = [url hasPrefix:@"http"] ? url : [self.baseURL stringByAppendingString:url];
    NSString *sep = [full rangeOfString:@"?"].location == NSNotFound ? @"?" : @"&";
    full = [full stringByAppendingFormat:@"%@_t=%.0f", sep, [[NSDate date] timeIntervalSince1970] * 1000];   // defeat caches
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:full] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    if (auth) [r setValue:[NSString stringWithFormat:@"Bearer %@", self.token ?: @""] forHTTPHeaderField:@"Authorization"];
    [[self.session dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        UIImage *img = (!err && [(NSHTTPURLResponse *)resp statusCode] == 200 && data.length) ? [UIImage imageWithData:data] : nil;
        if (img && maxSide > 0 && MAX(img.size.width, img.size.height) > maxSide) {
            CGFloat k = maxSide / MAX(img.size.width, img.size.height);
            CGSize sz = CGSizeMake(roundf(img.size.width * k), roundf(img.size.height * k));
            UIGraphicsBeginImageContextWithOptions(sz, YES, 1);
            [img drawInRect:CGRectMake(0, 0, sz.width, sz.height)];
            img = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(img); });
    }] resume];
}

- (void)getJSON:(NSString *)path completion:(HAJSONBlock)completion {
    [self runJSON:[self requestForPath:path method:@"GET" body:nil] completion:completion];
}

- (void)renderTemplate:(NSString *)tpl completion:(HAJSONBlock)completion {
    [self runJSON:[self requestForPath:@"/api/template" method:@"POST" body:@{@"template": tpl}] completion:completion];
}

- (void)fetchPanelFile:(NSString *)name completion:(void (^)(NSData *, NSError *))completion {
    NSString *path = [NSString stringWithFormat:@"%@/local/hapanel/%@?t=%.0f", self.baseURL, name, [[NSDate date] timeIntervalSince1970]];
    NSURLRequest *r = [NSURLRequest requestWithURL:[NSURL URLWithString:path] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:8];
    NSURLSessionDataTask *t = [self.session dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
        if (!err && code != 200) err = [NSError errorWithDomain:@"HA" code:code userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: HTTP %ld", name, (long)code]}];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(err ? nil : data, err); });
    }];
    [t resume];
}

- (BOOL)isConfigured { return self.token.length > 20 && self.baseURL.length > 0; }

- (NSMutableURLRequest *)requestForPath:(NSString *)path method:(NSString *)method body:(NSDictionary *)body {
    NSURL *url = [NSURL URLWithString:[self.baseURL stringByAppendingString:path]];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:url];
    r.HTTPMethod = method;
    [r setValue:[NSString stringWithFormat:@"Bearer %@", self.token ?: @""] forHTTPHeaderField:@"Authorization"];
    [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    if (body) r.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    return r;
}

- (void)runJSON:(NSURLRequest *)req completion:(HAJSONBlock)completion {
    NSURLSessionDataTask *t = [self.session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        id json = nil;
        NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
        if (!err && (code < 200 || code >= 300)) {
            // HA usually explains itself: {"message": "..."} or plain text
            NSString *why = nil;
            id body = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if ([body isKindOfClass:[NSDictionary class]] && [body[@"message"] isKindOfClass:[NSString class]]) why = body[@"message"];
            else if (data.length && data.length < 300) why = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            NSString *desc = why.length ? [NSString stringWithFormat:@"HTTP %ld: %@", (long)code, why] : [NSString stringWithFormat:@"HTTP %ld", (long)code];
            err = [NSError errorWithDomain:@"HA" code:code userInfo:@{NSLocalizedDescriptionKey: desc}];
        }
        if (err && ![req.URL.path hasPrefix:@"/api/states/"]) HALog(@"%@ %@ -> %@", req.HTTPMethod, req.URL.path, err.localizedDescription);
        if (!err && data.length) json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(json, err); });
    }];
    [t resume];
}

- (void)getState:(NSString *)entityId completion:(HAStateBlock)completion {
    NSString *path = [@"/api/states/" stringByAppendingString:entityId];
    [self runJSON:[self requestForPath:path method:@"GET" body:nil] completion:^(id json, NSError *error) {
        completion([json isKindOfClass:[NSDictionary class]] ? json : nil, error);
    }];
}

- (void)callService:(NSString *)domain service:(NSString *)service data:(NSDictionary *)data completion:(HAJSONBlock)completion {
    NSString *path = [NSString stringWithFormat:@"/api/services/%@/%@", domain, service];
    [self runJSON:[self requestForPath:path method:@"POST" body:data ?: @{}] completion:completion];
}

- (void)callServiceWithResponse:(NSString *)domain service:(NSString *)service data:(NSDictionary *)data completion:(HAJSONBlock)completion {
    NSString *path = [NSString stringWithFormat:@"/api/services/%@/%@?return_response", domain, service];
    [self runJSON:[self requestForPath:path method:@"POST" body:data ?: @{}] completion:completion];
}

// iOS 8 can't validate Plex's *.plex.direct certificates, so https://192-168-1-20.<hash>.plex.direct:32400/...
// is rewritten to plain http://192.168.1.20:32400/... (Plex serves both on the LAN).
static NSString *DePlexDirect(NSString *url) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^https://(\\d+)-(\\d+)-(\\d+)-(\\d+)\\.[0-9a-f]+\\.plex\\.direct(:\\d+)?" options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:url options:0 range:NSMakeRange(0, url.length)];
    if (!m) return url;
    NSString *port = [m rangeAtIndex:5].location != NSNotFound ? [url substringWithRange:[m rangeAtIndex:5]] : @":32400";
    NSString *host = [NSString stringWithFormat:@"http://%@.%@.%@.%@%@", [url substringWithRange:[m rangeAtIndex:1]], [url substringWithRange:[m rangeAtIndex:2]],
                      [url substringWithRange:[m rangeAtIndex:3]], [url substringWithRange:[m rangeAtIndex:4]], port];
    return [host stringByAppendingString:[url substringFromIndex:m.range.length]];
}

// Stable cache key: drop query params that change on every state update (access tokens).
// Home Assistant's "cache" parameter stays: it is a hash of the picture and is the only part of a
// media player's picture address that changes from one track to the next.
static NSString *ImageKey(NSString *path) {
    NSURLComponents *c = [NSURLComponents componentsWithString:path];
    if (!c) return path;
    NSMutableArray *keep = [NSMutableArray array];
    for (NSURLQueryItem *q in c.queryItems ?: @[]) if (![@[@"token", @"_t", @"X-Plex-Token"] containsObject:q.name]) [keep addObject:q];
    c.queryItems = keep.count ? keep : nil;
    return c.string ?: path;
}

NSString *DePlexDirectURL(NSString *url) { return DePlexDirect(url); }

- (void)loadImagePath:(NSString *)path completion:(HAImageBlock)completion {
    if (!path.length) { completion(nil); return; }
    static NSCache *cache;
    if (!cache) { cache = [[NSCache alloc] init]; cache.countLimit = 200; }
    NSString *key = ImageKey(path);
    UIImage *hit = [cache objectForKey:key];
    if (hit) { completion(hit); return; }
    NSString *disk = CachePath(@"img", key);
    UIImage *onDisk = [UIImage imageWithContentsOfFile:disk];
    if (onDisk) { [cache setObject:onDisk forKey:key]; completion(onDisk); return; }

    NSString *full = DePlexDirect([path hasPrefix:@"http"] ? path : [self.baseURL stringByAppendingString:path]);
    NSURL *u = [NSURL URLWithString:full];
    if (!u) { HALog(@"image: bad URL %@", [full substringToIndex:MIN(full.length, (NSUInteger)120)]); completion(nil); return; }
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:u];
    if ([full hasPrefix:self.baseURL]) [r setValue:[NSString stringWithFormat:@"Bearer %@", self.token ?: @""] forHTTPHeaderField:@"Authorization"];
    NSURLSessionDataTask *t = [self.imageSession dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
        UIImage *img = (!err && code == 200 && data.length) ? [UIImage imageWithData:data] : nil;
        if (!img) HALog(@"image failed (%ld %@): %@", (long)code, err.localizedDescription ?: @"", [[ImageKey(full) componentsSeparatedByString:@"?"] firstObject]);
        if (img && MAX(img.size.width, img.size.height) > 320) {   // keep the A5's memory happy
            CGFloat k = 320 / MAX(img.size.width, img.size.height);
            CGSize sz = CGSizeMake(roundf(img.size.width * k), roundf(img.size.height * k));
            UIGraphicsBeginImageContextWithOptions(sz, YES, 1);
            [img drawInRect:CGRectMake(0, 0, sz.width, sz.height)];
            img = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
        }
        if (img) {
            [cache setObject:img forKey:key];
            [UIImageJPEGRepresentation(img, 0.85) writeToFile:disk atomically:YES];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(img); });
    }];
    [t resume];
}

@end

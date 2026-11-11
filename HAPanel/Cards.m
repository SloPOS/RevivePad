#import "Cards.h"
#import "HAClient.h"

#pragma mark - Style

NSDictionary *HA_DefaultTheme(void) {
    return @{ @"background": @"#0A0A0C", @"card": @"#1C1C1E", @"button": @"#3A3A3C", @"text": @"#FFFFFF",
              @"dim": @"#8E8E93", @"accent": @"#FFB340", @"media": @"#0A84FF", @"heat": @"#FF6B35", @"cool": @"#32ADE6" };
}

static NSMutableDictionary *gTheme;   // key -> UIColor

UIColor *HA_ColorFromHex(NSString *hex) {
    if (![hex isKindOfClass:[NSString class]]) return nil;
    NSString *h = [[hex stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (h.length != 6) return nil;
    unsigned int v = 0;
    if (![[NSScanner scannerWithString:h] scanHexInt:&v]) return nil;
    return RGB((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF);
}

NSString *HA_HexFromColor(UIColor *c) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) { [c getWhite:&r alpha:&a]; g = b = r; }
    return [NSString stringWithFormat:@"#%02X%02X%02X", (int)roundf(r * 255), (int)roundf(g * 255), (int)roundf(b * 255)];
}

void HA_SetTheme(NSDictionary *hexByKey) {
    NSMutableDictionary *t = [NSMutableDictionary dictionary];
    NSDictionary *def = HA_DefaultTheme();
    for (NSString *k in def) t[k] = HA_ColorFromHex(hexByKey[k]) ?: HA_ColorFromHex(def[k]);
    gTheme = t;
}

static UIColor *T(NSString *k) {
    if (!gTheme) HA_SetTheme(nil);
    return gTheme[k];
}

UIColor *HA_BG(void)     { return T(@"background"); }
UIColor *HA_CARD(void)   { return T(@"card"); }
UIColor *HA_OFF(void)    { return T(@"button"); }
UIColor *HA_TEXT(void)   { return T(@"text"); }
UIColor *HA_DIM(void)    { return T(@"dim"); }
UIColor *HA_ACCENT(void) { return T(@"accent"); }
UIColor *HA_BLUE(void)   { return T(@"media"); }
UIColor *HA_HEAT(void)   { return T(@"heat"); }
UIColor *HA_COOL(void)   { return T(@"cool"); }

NSString *HA_Str(id v) { return [v isKindOfClass:[NSString class]] ? v : ([v respondsToSelector:@selector(stringValue)] ? [v stringValue] : nil); }
NSInteger HA_Int(id v, NSInteger def) { return [v respondsToSelector:@selector(integerValue)] ? [v integerValue] : def; }

NSString *HA_PictureOf(NSDictionary *state) {
    id a = state[@"attributes"];
    id p = a[@"entity_picture_local"];
    if (![p isKindOfClass:[NSString class]]) p = a[@"entity_picture"];
    return [p isKindOfClass:[NSString class]] ? p : nil;
}

NSString *HA_NowPlayingPicture(NSDictionary *speaker, NSDictionary *plexSession, NSString *plexServer) {
    NSString *own = HA_PictureOf(speaker);
    if (own) return own;
    NSDictionary *a = speaker[@"attributes"];
    NSString *cid = HA_Str(a[@"media_content_id"]), *prefix = @"/library/metadata/";
    if (plexServer.length && [cid hasPrefix:prefix] && cid.length > prefix.length)
        return [NSString stringWithFormat:@"/api/plex_image_proxy/%@/%@", plexServer, [cid substringFromIndex:prefix.length]];
    // The Plex session entity can be a track or two behind the speaker: only trust it on the same track.
    NSString *mine = HA_Str(a[@"media_title"]), *theirs = HA_Str(plexSession[@"attributes"][@"media_title"]);
    if (mine.length && theirs.length && ![mine isEqualToString:theirs]) return nil;
    return HA_PictureOf(plexSession);
}

NSTimeInterval HA_MediaPosition(NSDictionary *state) {
    NSDictionary *a = state[@"attributes"];
    id pos = a[@"media_position"];
    if (![pos isKindOfClass:[NSNumber class]]) return -1;
    NSTimeInterval p = [pos doubleValue];
    NSString *at = HA_Str(a[@"media_position_updated_at"]);
    if ([HA_Str(state[@"state"]) isEqualToString:@"playing"] && at.length >= 19) {
        static NSDateFormatter *f;
        if (!f) {
            f = [[NSDateFormatter alloc] init];
            f.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
            f.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
            f.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss";
        }
        NSDate *d = [f dateFromString:[at substringToIndex:19]];
        if (d) p += MAX(0, [[NSDate date] timeIntervalSinceDate:d]);
    }
    id dur = a[@"media_duration"];
    if ([dur isKindOfClass:[NSNumber class]] && [dur doubleValue] > 0) p = MIN(p, [dur doubleValue]);
    return MAX(0, p);
}

NSString *HA_Clock(NSTimeInterval s) {
    NSInteger t = (NSInteger)MAX(0, s);
    return t >= 3600 ? [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)(t / 3600), (long)(t / 60 % 60), (long)(t % 60)]
                     : [NSString stringWithFormat:@"%ld:%02ld", (long)(t / 60), (long)(t % 60)];
}

static UIImage *HA_SeekThumb(void);
static NSDictionary *gQueue;
static NSString *QueueFile(void) {
    NSString *dir = [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject] stringByAppendingPathComponent:@"HAPanel"];
    return [dir stringByAppendingPathComponent:@"queue.plist"];
}
void HA_QueueRemember(NSDictionary *queue) {
    gQueue = [queue copy];
    [gQueue writeToFile:QueueFile() atomically:YES];
}

BOOL HA_QueueSkip(NSInteger delta, NSString *entity, NSDictionary *state, HACard *card) {
    NSInteger feat = HA_Int(state[@"attributes"][@"supported_features"], 0);
    if (feat & (delta > 0 ? 32 : 16)) return NO;   // the player can skip by itself
    if (!gQueue) gQueue = [NSDictionary dictionaryWithContentsOfFile:QueueFile()];
    NSArray *keys = gQueue[@"keys"];
    NSString *cid = HA_Str(state[@"attributes"][@"media_content_id"]), *prefix = @"/library/metadata/";
    NSString *cur = [cid hasPrefix:prefix] ? [cid substringFromIndex:prefix.length] : cid;
    NSUInteger idx = cur ? [keys indexOfObject:cur] : NSNotFound;
    if (!entity || idx == NSNotFound || !HA_Str(gQueue[@"base"]) || !HA_Str(gQueue[@"token"])) return NO;
    NSInteger t = (NSInteger)idx + delta;
    BOOL repeat = [gQueue[@"repeat"] boolValue];
    if (t < 0) t = 0;
    if (t >= (NSInteger)keys.count) { if (!repeat) return YES; t = 0; }   // last track: nothing to skip to
    NSInteger from = MAX(0, t - 50), len = MIN((NSInteger)keys.count - from, 200);
    NSString *list = [[keys subarrayWithRange:NSMakeRange(from, len)] componentsJoinedByString:@","];
    NSURLComponents *u = [NSURLComponents componentsWithString:[gQueue[@"base"] stringByAppendingString:@"/playQueues"]];
    u.queryItems = @[[NSURLQueryItem queryItemWithName:@"type" value:@"audio"],
                     [NSURLQueryItem queryItemWithName:@"shuffle" value:@"0"],
                     [NSURLQueryItem queryItemWithName:@"repeat" value:repeat ? @"1" : @"0"],
                     [NSURLQueryItem queryItemWithName:@"continuous" value:@"0"],
                     [NSURLQueryItem queryItemWithName:@"includeRelated" value:@"0"],
                     [NSURLQueryItem queryItemWithName:@"uri" value:[NSString stringWithFormat:@"server://%@/com.plexapp.plugins.library/library/metadata/%@", gQueue[@"server"], list]],
                     [NSURLQueryItem queryItemWithName:@"key" value:[prefix stringByAppendingString:keys[t]]]];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:u.URL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10];
    r.HTTPMethod = @"POST";
    [r setValue:gQueue[@"token"] forHTTPHeaderField:@"X-Plex-Token"];
    [r setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [r setValue:@"hapanel" forHTTPHeaderField:@"X-Plex-Client-Identifier"];
    __weak HACard *wc = card;
    [[[NSURLSession sharedSession] dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        id mc = [json isKindOfClass:[NSDictionary class]] ? json[@"MediaContainer"] : nil;
        id qid = [mc isKindOfClass:[NSDictionary class]] ? mc[@"playQueueID"] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![qid respondsToSelector:@selector(integerValue)]) { HALog(@"skip: plex queue failed (%ld %@)", (long)[(NSHTTPURLResponse *)resp statusCode], err.localizedDescription ?: @""); return; }
            HALog(@"skip: track %ld of %lu, plex queue %ld", (long)t + 1, (unsigned long)keys.count, (long)[qid integerValue]);
            [wc.host card:wc callService:@"media_player.play_media" data:@{@"entity_id": entity, @"media_content_type": @"music",
                @"media_content_id": [NSString stringWithFormat:@"plex://{\"playqueue_id\": %ld}", (long)[qid integerValue]]}];
        });
    }] resume];
    return YES;
}

static NSString *gPendingEntity, *gPendingLabel; static NSDate *gPendingUntil;
void HA_SetPendingPlay(id entity, NSString *title) {
    gPendingEntity = [entity isKindOfClass:[NSArray class]] ? [entity firstObject] : entity;
    gPendingLabel = title ? @"STARTING…" : nil;
    gPendingUntil = title ? [NSDate dateWithTimeIntervalSinceNow:20] : nil;
}
NSString *HA_PendingPlayLabel(NSString *entity) {
    if (!gPendingUntil || [gPendingUntil timeIntervalSinceNow] < 0) return nil;
    return (!entity || [entity isEqualToString:gPendingEntity]) ? gPendingLabel : nil;
}

NSArray *HA_CleanList(NSArray *list) {
    NSMutableArray *out = [NSMutableArray array];
    for (id item in ([list isKindOfClass:[NSArray class]] ? list : @[])) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        [item enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) { if (v != [NSNull null]) d[k] = v; }];
        [out addObject:d];
    }
    return out;
}

NSDate *HA_ParseISO(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return nil;
    static NSDateFormatter *f;
    if (!f) {
        f = [[NSDateFormatter alloc] init];
        f.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        f.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZZZZZ";
    }
    NSRange dot = [s rangeOfString:@"."];
    if (dot.location != NSNotFound) {   // drop fractional seconds
        NSUInteger end = dot.location + 1;
        while (end < s.length && isdigit([s characterAtIndex:end])) end++;
        s = [[s substringToIndex:dot.location] stringByAppendingString:[s substringFromIndex:end]];
    }
    return [f dateFromString:s];
}

NSString *HA_ISO(NSDate *d) {
    static NSDateFormatter *f;
    if (!f) {
        f = [[NSDateFormatter alloc] init];
        f.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        f.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
        f.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'%2B00:00'";
    }
    return [f stringFromDate:d];
}

@interface HAPress : NSObject
+ (instancetype)shared;
@end
@implementation HAPress
+ (instancetype)shared { static HAPress *p; static dispatch_once_t o; dispatch_once(&o, ^{ p = [HAPress new]; }); return p; }
- (void)down:(UIButton *)b {
    [UIView animateWithDuration:0.08 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{ b.transform = CGAffineTransformMakeScale(0.95, 0.95); } completion:nil];
}
- (void)up:(UIButton *)b {
    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.5 initialSpringVelocity:0.6
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{ b.transform = CGAffineTransformIdentity; } completion:nil];
}
@end

void HA_AddPress(UIButton *b) {
    [b addTarget:[HAPress shared] action:@selector(down:) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
    [b addTarget:[HAPress shared] action:@selector(up:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
}

void HA_SetBG(UIView *v, UIColor *c) {
    if (!c || [v.backgroundColor isEqual:c]) return;
    if (!v.window || !v.backgroundColor) { v.backgroundColor = c; return; }
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ v.backgroundColor = c; } completion:nil];
}

void HA_Fade(UIView *v, CFTimeInterval duration) {
    if (!v.window) return;
    CATransition *t = [CATransition animation];
    t.type = kCATransitionFade; t.duration = duration;
    [v.layer addAnimation:t forKey:@"fade"];
}

void HA_Push(UIView *v, BOOL up) {
    CATransition *t = [CATransition animation];
    t.type = kCATransitionPush; t.subtype = up ? kCATransitionFromTop : kCATransitionFromBottom;
    t.duration = 0.18;
    t.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [v.layer addAnimation:t forKey:@"push"];
}

UIButton *HA_Chip(NSString *title, id target, SEL action) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = HA_FONT(15, 0.3);
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumScaleFactor = 0.6;
    b.backgroundColor = HA_OFF();
    [b setTitleColor:HA_TEXT() forState:UIControlStateNormal];
    b.layer.cornerRadius = 10;
    if (action) [b addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    HA_AddPress(b);
    return b;
}

UIFont *HA_FONT(CGFloat size, CGFloat weight) {
    if ([UIFont respondsToSelector:@selector(systemFontOfSize:weight:)]) return [UIFont systemFontOfSize:size weight:weight];
    return weight > 0.2 ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
}

// Only emoji that exist on iOS 8 (Unicode 6). The newer weather emoji (U+1F327 rain cloud,
// U+1F329 lightning cloud, U+1F32B fog, U+26C8 storm...) render as "?" boxes there.
NSString *HA_WeatherGlyph(NSString *c) {
    NSDictionary *m = @{ @"sunny": @"☀️",            // ☀️
                         @"clear-night": @"\U0001F319",       // 🌙
                         @"partlycloudy": @"⛅️",     // ⛅
                         @"cloudy": @"☁️",           // ☁️
                         @"fog": @"\U0001F301",               // 🌁
                         @"rainy": @"☔️",            // ☔
                         @"pouring": @"☔️",          // ☔
                         @"lightning": @"⚡️",        // ⚡
                         @"lightning-rainy": @"⚡️",  // ⚡
                         @"snowy": @"❄️",            // ❄️
                         @"snowy-rainy": @"❄️",      // ❄️
                         @"hail": @"❄️",             // ❄️
                         @"windy": @"\U0001F4A8",             // 💨
                         @"windy-variant": @"\U0001F4A8",     // 💨
                         @"exceptional": @"⚠️" };    // ⚠️
    return (c && m[c]) ? m[c] : @"☁️";
}

NSString *HA_WeatherText(NSString *c) {
    if (![c isKindOfClass:[NSString class]] || !c.length) return @"";
    if ([c isEqualToString:@"partlycloudy"]) return @"Partly cloudy";
    if ([c isEqualToString:@"clear-night"]) return @"Clear";
    if ([c isEqualToString:@"lightning-rainy"]) return @"Storms";
    if ([c isEqualToString:@"snowy-rainy"]) return @"Sleet";
    if ([c isEqualToString:@"windy-variant"]) return @"Windy";
    return [[[c substringToIndex:1] uppercaseString] stringByAppendingString:[c substringFromIndex:1]];
}

#define Str HA_Str
#define Int HA_Int

#pragma mark - Card subclasses (declared here, private)

@interface HALightCard : HACard @end
@interface HAMediaCard : HACard @end
@interface HAForecastCard : HACard @end
@interface HAAdblockCard : HACard @end
@interface HAButtonsCard : HACard @end
@interface HASensorsCard : HACard @end
@interface HAHomeCard : HACard @end

#pragma mark - Base

@implementation HACard

+ (HACard *)cardWithSpec:(NSDictionary *)spec host:(id<HACardHost>)host {
    NSDictionary *types = @{ @"light": [HALightCard class], @"media": [HAMediaCard class], @"forecast": [HAForecastCard class],
                             @"adblock": [HAAdblockCard class], @"buttons": [HAButtonsCard class], @"sensors": [HASensorsCard class],
                             @"home": [HAHomeCard class] };
    NSDictionary *more = @{ @"climate": @"HAClimateCard", @"climate_detail": @"HAClimateDetailCard", @"light_members": @"HALightMembersCard",
                            @"context": @"HAContextCard", @"library": @"HALibraryCard", @"weather_detail": @"HAWeatherDetailCard",
                            @"tesla": @"HATeslaCarsCard", @"updates": @"HAUpdatesCard", @"timer": @"HATimerCard", @"cameras": @"HACamerasCard",
                            @"freeze_dryer": @"HAFreezeDryerCard", @"network": @"HANetworkCard", @"batteries": @"HABatteriesCard", @"detections": @"HADetectionsCard" };   // Cards3.m   // defined in Cards2.m
    NSString *type = Str(spec[@"type"]) ?: @"";
    Class cls = types[type] ?: (more[type] ? NSClassFromString(more[type]) : nil);
    return cls ? [[cls alloc] initWithSpec:spec host:host] : nil;
}

- (instancetype)initWithSpec:(NSDictionary *)spec host:(id<HACardHost>)host {
    if ((self = [super initWithFrame:CGRectZero])) {
        _spec = spec;
        _host = host;
        _active = YES;
        self.backgroundColor = HA_CARD();
        self.layer.cornerRadius = 18;
        self.clipsToBounds = YES;
        _titleLabel = [self addLabel:15 weight:0.4 color:HA_DIM()];
        NSString *t = Str(spec[@"title"]);
        _titleLabel.text = t ? [t uppercaseString] : @"";
        // "opens": "Lights" adds a button in the top-right corner that opens that sidebar drawer
        if (Str(spec[@"opens"])) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            [b setTitle:[NSString stringWithFormat:@"%@ ›", Str(spec[@"opens_label"]) ?: Str(spec[@"opens"])] forState:UIControlStateNormal];
            [b setTitleColor:HA_DIM() forState:UIControlStateNormal];
            b.titleLabel.font = HA_FONT(15, 0.3);
            b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
            b.tag = 991;
            [b addTarget:self action:@selector(opensTapped) forControlEvents:UIControlEventTouchUpInside];
            [self addSubview:b];
            // "tap_opens": true makes the whole card a button for that drawer
            if ([spec[@"tap_opens"] boolValue]) {
                [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(opensTapped)]];
                b.hidden = [spec[@"opens_label"] isEqual:@""];
            }
        }
    }
    return self;
}

- (void)opensTapped { [self.host card:self openDrawer:Str(self.spec[@"opens"])]; }

- (NSArray *)entityIds { return @[]; }
- (void)updateStates:(NSDictionary *)states {}
- (void)tick {}
- (void)reload {}

- (UILabel *)addLabel:(CGFloat)size weight:(CGFloat)w color:(UIColor *)c {
    UILabel *l = [[UILabel alloc] init];
    l.font = HA_FONT(size, w);
    l.textColor = c;
    l.backgroundColor = [UIColor clearColor];
    l.adjustsFontSizeToFitWidth = YES;
    l.minimumScaleFactor = 0.5;
    [self addSubview:l];
    return l;
}

- (UIButton *)addButton:(NSString *)title size:(CGFloat)size action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:HA_TEXT() forState:UIControlStateNormal];
    [b setTitleColor:HA_DIM() forState:UIControlStateHighlighted];
    b.titleLabel.font = HA_FONT(size, 0.3);
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumScaleFactor = 0.5;
    b.backgroundColor = HA_OFF();
    b.layer.cornerRadius = 14;
    if (action) [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    HA_AddPress(b);
    [self addSubview:b];
    return b;
}

- (CGRect)contentRect {
    BOOL hasTitle = self.titleLabel.text.length > 0;
    CGFloat top = hasTitle ? 44 : 16;
    return CGRectMake(20, top, self.bounds.size.width - 40, self.bounds.size.height - top - 16);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    UIView *opens = [self viewWithTag:991];
    CGFloat ow = opens ? 150 : 0;
    self.titleLabel.frame = CGRectMake(20, 16, self.bounds.size.width - 40 - ow, 20);
    opens.frame = CGRectMake(self.bounds.size.width - 20 - ow, 6, ow, 40);
    [self bringSubviewToFront:opens];
}

@end

#pragma mark - Light
// { "type":"light", "entity":"light.bedroom", "title":"Bedroom", "members": true }

@interface HALightCard ()
@property (nonatomic, copy) NSString *entity;
@property (nonatomic, strong) UIButton *bigButton;
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, strong) UILabel *pct;
@property (nonatomic, strong) NSMutableArray *memberButtons;
@property (nonatomic, strong) NSArray *memberIds;
@property (nonatomic, assign) BOOL on, showMembers;
@property (nonatomic, strong) NSDate *suppressUntil;
@end

@implementation HALightCard

- (instancetype)initWithSpec:(NSDictionary *)spec host:(id<HACardHost>)host {
    if ((self = [super initWithSpec:spec host:host])) {
        _entity = Str(spec[@"entity"]) ?: @"";
        _showMembers = spec[@"members"] ? [spec[@"members"] boolValue] : YES;
        _bigButton = [self addButton:@"Off" size:28 action:@selector(bigTapped)];
        _pct = [self addLabel:16 weight:0 color:HA_DIM()];
        _pct.textAlignment = NSTextAlignmentRight;
        _slider = [[UISlider alloc] init];
        _slider.minimumValue = 1; _slider.maximumValue = 100;
        _slider.minimumTrackTintColor = HA_ACCENT();
        [_slider addTarget:self action:@selector(sliderBegan) forControlEvents:UIControlEventTouchDown];
        [_slider addTarget:self action:@selector(sliderMoved) forControlEvents:UIControlEventValueChanged];
        [_slider addTarget:self action:@selector(sliderEnded) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
        [self addSubview:_slider];
        _memberButtons = [NSMutableArray array];
        if (!Str(spec[@"title"])) self.titleLabel.text = @"LIGHT";
    }
    return self;
}

- (NSArray *)entityIds { return [@[self.entity] arrayByAddingObjectsFromArray:self.showMembers ? (self.memberIds ?: @[]) : @[]]; }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect c = [self contentRect];
    NSInteger n = self.memberButtons.count;
    NSInteger cols = 3, rows = n ? (n + cols - 1) / cols : 0;
    CGFloat membersH = rows * 44;
    // A button across the whole tile, with the brightness slider under it. Tiles too
    // short for both keep the button and drop the slider.
    BOOL showSlider = c.size.height - membersH >= 150;
    CGFloat sliderH = showSlider ? 66 : 0;
    CGFloat avail = c.size.height - sliderH - membersH;
    CGFloat d = MAX(50, MIN(avail, c.size.width));
    CGFloat blockH = d + sliderH + membersH;
    CGFloat top = c.origin.y + MAX(0, (c.size.height - blockH) / 2);
    self.bigButton.frame = CGRectMake(c.origin.x, top, c.size.width, d);   // full width of the tile, inside its padding
    self.bigButton.layer.cornerRadius = MIN(30, d * 0.18);
    self.bigButton.titleLabel.font = HA_FONT(MAX(18, MIN(40, d * 0.2)), 0.3);
    self.pct.hidden = self.slider.hidden = !showSlider;
    CGFloat y = top + d + 6;
    self.pct.frame = CGRectMake(c.origin.x + c.size.width - 80, y, 80, 18);   // brightness % just above the slider
    y += 18;
    self.slider.frame = CGRectMake(c.origin.x, y, c.size.width, 34);
    y += showSlider ? 42 : 8;
    CGFloat bw = (c.size.width - (cols - 1) * 8) / cols;
    for (NSInteger i = 0; i < n; i++) {
        UIButton *b = self.memberButtons[i];
        b.frame = CGRectMake(c.origin.x + (i % cols) * (bw + 8), y + (i / cols) * 44, bw, 36);
    }
}

- (void)updateStates:(NSDictionary *)states {
    NSDictionary *s = states[self.entity];
    if (!s) return;
    NSDictionary *a = s[@"attributes"];
    self.on = [s[@"state"] isEqualToString:@"on"];
    if (!Str(self.spec[@"title"]) && Str(a[@"friendly_name"])) self.titleLabel.text = [Str(a[@"friendly_name"]) uppercaseString];
    [self.bigButton setTitle:self.on ? @"On" : @"Off" forState:UIControlStateNormal];
    HA_SetBG(self.bigButton, self.on ? HA_ACCENT() : HA_OFF());
    [self.bigButton setTitleColor:self.on ? [UIColor blackColor] : HA_TEXT() forState:UIControlStateNormal];
    if (!(self.suppressUntil && [self.suppressUntil timeIntervalSinceNow] > 0)) {
        NSNumber *bri = a[@"brightness"];
        float p = (self.on && [bri isKindOfClass:[NSNumber class]]) ? roundf(bri.floatValue / 255.0f * 100.0f) : 0;
        self.slider.value = MAX(p, 1);
        self.pct.text = self.on ? [NSString stringWithFormat:@"%.0f%%", p] : @"";
    }
    NSArray *members = a[@"entity_id"];
    if (self.showMembers && [members isKindOfClass:[NSArray class]] && ![members isEqualToArray:self.memberIds]) {
        self.memberIds = [members subarrayWithRange:NSMakeRange(0, MIN(members.count, (NSUInteger)9))];
        for (UIButton *b in self.memberButtons) [b removeFromSuperview];
        [self.memberButtons removeAllObjects];
        for (NSUInteger i = 0; i < self.memberIds.count; i++) {
            UIButton *b = [self addButton:@"" size:13 action:@selector(memberTapped:)];
            b.tag = i; b.layer.cornerRadius = 10;
            [self.memberButtons addObject:b];
        }
        [self setNeedsLayout];
        [self.host cardWantsRefresh:self];
    }
    for (NSUInteger i = 0; i < self.memberIds.count && i < self.memberButtons.count; i++) {
        NSDictionary *m = states[self.memberIds[i]];
        UIButton *b = self.memberButtons[i];
        NSString *name = Str(m[@"attributes"][@"friendly_name"]) ?: self.memberIds[i];
        NSString *strip = Str(self.spec[@"strip_prefix"]);
        if (strip.length) name = [name stringByReplacingOccurrencesOfString:strip withString:@""];
        NSString *st = m[@"state"];
        BOOL mon = [st isEqualToString:@"on"];
        BOOL dead = !m || [st isEqualToString:@"unavailable"] || [st isEqualToString:@"unknown"];
        [b setTitle:name forState:UIControlStateNormal];
        b.enabled = !dead; b.alpha = dead ? 0.35 : 1.0;
        HA_SetBG(b, mon ? [HA_ACCENT() colorWithAlphaComponent:0.85] : HA_OFF());
        [b setTitleColor:mon ? [UIColor blackColor] : HA_TEXT() forState:UIControlStateNormal];
    }
}

- (void)bigTapped {
    NSString *svc = self.on ? @"light.turn_off" : @"light.turn_on";
    self.on = !self.on;
    HA_SetBG(self.bigButton, self.on ? HA_ACCENT() : HA_OFF());
    [self.bigButton setTitle:self.on ? @"On" : @"Off" forState:UIControlStateNormal];
    [self.host card:self callService:svc data:@{@"entity_id": self.entity}];
}

- (void)memberTapped:(UIButton *)b {
    if (b.tag < (NSInteger)self.memberIds.count) [self.host card:self callService:@"light.toggle" data:@{@"entity_id": self.memberIds[b.tag]}];
}

- (void)sliderBegan { self.suppressUntil = [NSDate dateWithTimeIntervalSinceNow:60]; }
- (void)sliderMoved { self.pct.text = [NSString stringWithFormat:@"%.0f%%", self.slider.value]; }
- (void)sliderEnded {
    self.suppressUntil = [NSDate dateWithTimeIntervalSinceNow:3];
    [self.host card:self callService:@"light.turn_on" data:@{@"entity_id": self.entity, @"brightness_pct": @((NSInteger)roundf(self.slider.value))}];
}

@end

#pragma mark - Media
// { "type":"media", "players":[ {"entity":"media_player.x","name":"Speaker"} ] }

@interface HAMediaCard ()
@property (nonatomic, strong) NSArray *players;
@property (nonatomic, strong) UISegmentedControl *picker;
@property (nonatomic, strong) UIImageView *art;
@property (nonatomic, strong) UILabel *track, *artist, *stateLabel;
@property (nonatomic, strong) UIButton *prev, *play, *next;
@property (nonatomic, strong) UISlider *volume;
@property (nonatomic, copy) NSString *artPath;
@property (nonatomic, strong) NSDate *suppressUntil, *optimisticUntil;
@property (nonatomic, strong) UIButton *stop;
@property (nonatomic, assign) BOOL isPlaying;
// seek bar: elapsed | slider | remaining
@property (nonatomic, strong) UISlider *seek;
@property (nonatomic, strong) UILabel *elapsed, *remaining;
@property (nonatomic, strong) NSDictionary *last;          // the speaker's latest state
@property (nonatomic, strong) NSDate *seekHold;            // ignore position updates until then (dragging / just sought)
@end

@implementation HAMediaCard

- (instancetype)initWithSpec:(NSDictionary *)spec host:(id<HACardHost>)host {
    if ((self = [super initWithSpec:spec host:host])) {
        NSMutableArray *ps = [NSMutableArray array];
        for (id p in ([spec[@"players"] isKindOfClass:[NSArray class]] ? spec[@"players"] : @[])) {
            if ([p isKindOfClass:[NSString class]]) [ps addObject:@{@"entity": p, @"name": p}];
            else if ([p isKindOfClass:[NSDictionary class]] && Str(p[@"entity"])) [ps addObject:p];
        }
        if (!ps.count && Str(spec[@"entity"])) [ps addObject:@{@"entity": spec[@"entity"], @"name": Str(spec[@"title"]) ?: @""}];
        _players = ps;
        if (ps.count > 1) {
            NSMutableArray *names = [NSMutableArray array];
            for (NSDictionary *p in ps) [names addObject:Str(p[@"name"]) ?: p[@"entity"]];
            _picker = [[UISegmentedControl alloc] initWithItems:names];
            NSString *key = [@"player." stringByAppendingString:Str(spec[@"title"]) ?: @"media"];
            NSInteger sel = [[NSUserDefaults standardUserDefaults] integerForKey:key];
            _picker.selectedSegmentIndex = (sel >= 0 && sel < (NSInteger)ps.count) ? sel : 0;
            _picker.tintColor = HA_BLUE();
            [_picker addTarget:self action:@selector(pickerChanged) forControlEvents:UIControlEventValueChanged];
            [self addSubview:_picker];
        }
        _art = [[UIImageView alloc] init];
        _art.backgroundColor = HA_OFF();
        _art.layer.cornerRadius = 12; _art.clipsToBounds = YES;
        _art.contentMode = UIViewContentModeScaleAspectFill;
        [self addSubview:_art];
        _stateLabel = [self addLabel:14 weight:0.3 color:HA_DIM()];
        _track = [self addLabel:26 weight:0.3 color:HA_TEXT()];
        _artist = [self addLabel:19 weight:0 color:HA_DIM()];
        _prev = [self addButton:@"◀︎◀︎" size:28 action:@selector(prevTapped)];
        _play = [self addButton:@"▶︎" size:32 action:@selector(playTapped)];
        _next = [self addButton:@"▶︎▶︎" size:28 action:@selector(nextTapped)];
        _stop = [self addButton:@"■" size:24 action:@selector(stopTapped)];   // stop casting (quits the app on the speaker)
        _volume = [[UISlider alloc] init];
        _volume.minimumTrackTintColor = HA_BLUE();
        [_volume addTarget:self action:@selector(volBegan) forControlEvents:UIControlEventTouchDown];
        [_volume addTarget:self action:@selector(volEnded) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
        [self addSubview:_volume];
        _seek = [[UISlider alloc] init];
        _seek.minimumTrackTintColor = HA_BLUE();
        [_seek setThumbImage:HA_SeekThumb() forState:UIControlStateNormal];
        [_seek addTarget:self action:@selector(seekBegan) forControlEvents:UIControlEventTouchDown];
        [_seek addTarget:self action:@selector(seekMoved) forControlEvents:UIControlEventValueChanged];
        [_seek addTarget:self action:@selector(seekEnded) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
        [self addSubview:_seek];
        _elapsed = [self addLabel:13 weight:0 color:HA_DIM()];
        _remaining = [self addLabel:13 weight:0 color:HA_DIM()];
        _remaining.textAlignment = NSTextAlignmentRight;
    }
    return self;
}

static UIImage *HA_SeekThumb(void) {   // a smaller knob than the volume slider's
    static UIImage *img;
    if (!img) {
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(18, 18), NO, 0);
        [[UIColor whiteColor] setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(1, 1, 16, 16)] fill];
        img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    }
    return img;
}

- (void)placeSeekAt:(CGRect)r {
    self.elapsed.frame = CGRectMake(r.origin.x, r.origin.y, 44, r.size.height);
    self.remaining.frame = CGRectMake(CGRectGetMaxX(r) - 50, r.origin.y, 50, r.size.height);
    self.seek.frame = CGRectMake(r.origin.x + 48, r.origin.y, r.size.width - 102, r.size.height);
}

// Position and remaining time, once a second; left alone while a finger is on the bar.
- (void)paintPosition {
    NSDictionary *a = self.last[@"attributes"];
    NSTimeInterval dur = [a[@"media_duration"] isKindOfClass:[NSNumber class]] ? [a[@"media_duration"] doubleValue] : 0;
    NSTimeInterval pos = HA_MediaPosition(self.last);
    NSString *st = HA_Str(self.last[@"state"]);
    BOOL have = dur > 0 && pos >= 0 && ([st isEqualToString:@"playing"] || [st isEqualToString:@"paused"] || [st isEqualToString:@"buffering"]);
    self.seek.enabled = have && (HA_Int(a[@"supported_features"], 0) & 2);
    self.seek.alpha = have ? 1 : 0.3;
    if (!have) { self.seek.value = 0; self.elapsed.text = @""; self.remaining.text = @""; return; }
    if (self.seekHold && [self.seekHold timeIntervalSinceNow] > 0) return;
    self.seek.value = pos / dur;
    self.elapsed.text = HA_Clock(pos);
    self.remaining.text = [@"-" stringByAppendingString:HA_Clock(dur - pos)];
}

- (void)tick { [self paintPosition]; }
- (void)seekBegan { self.seekHold = [NSDate dateWithTimeIntervalSinceNow:120]; }
- (void)seekMoved {
    NSTimeInterval dur = [self.last[@"attributes"][@"media_duration"] doubleValue];
    self.elapsed.text = HA_Clock(self.seek.value * dur);
    self.remaining.text = [@"-" stringByAppendingString:HA_Clock(dur * (1 - self.seek.value))];
}
- (void)seekEnded {
    NSTimeInterval dur = [self.last[@"attributes"][@"media_duration"] doubleValue];
    if (dur <= 0) { self.seekHold = nil; return; }
    self.seekHold = [NSDate dateWithTimeIntervalSinceNow:5];   // until the speaker reports the new position
    [self media:@"media_seek" extra:@{@"seek_position": @(round(self.seek.value * dur))}];
}

- (NSString *)current {
    if (!self.players.count) return @"";
    NSInteger i = self.picker ? self.picker.selectedSegmentIndex : 0;
    if (i < 0 || i >= (NSInteger)self.players.count) i = 0;
    return self.players[i][@"entity"];
}

- (NSArray *)entityIds {
    NSString *c = [self current], *plex = Str(self.spec[@"plex_session"]);
    NSMutableArray *ids = [NSMutableArray array];
    if (c.length) [ids addObject:c];
    if (plex.length) [ids addObject:plex];
    return ids;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect c = [self contentRect];
    CGFloat y = c.origin.y;
    if (self.bounds.size.height < 260 && self.bounds.size.width > 520) {
        // Wide, short strip (e.g. above the music library): picker on top, then one row of
        // art | title/artist | prev play next | volume
        self.titleLabel.hidden = self.picker != nil;
        CGFloat top = 16;
        if (self.picker) { self.picker.frame = CGRectMake(20, 12, MIN(self.bounds.size.width - 40, 130 * self.players.count), 30); top = 52; }
        else top = self.titleLabel.text.length ? 44 : 16;
        CGFloat fullH = self.bounds.size.height - top - 16, W = self.bounds.size.width - 40;
        CGFloat H = fullH - 30;   // the seek bar runs along the bottom, right of the artwork
        self.art.frame = CGRectMake(20, top, fullH, fullH);
        CGFloat x = 20 + fullH + 18, textW = MAX(160, W * 0.3);
        [self placeSeekAt:CGRectMake(x, top + fullH - 24, 20 + W - x, 24)];
        CGFloat ty = top + MAX(0, (H - 80) / 2);
        self.stateLabel.frame = CGRectMake(x, ty, textW, 18);
        self.track.frame = CGRectMake(x, ty + 20, textW, 32);
        self.artist.frame = CGRectMake(x, ty + 54, textW, 24);
        x += textW + 16;
        CGFloat bw = 58, bh = MIN(56, H), by = top + (H - bh) / 2;
        self.prev.frame = CGRectMake(x, by, bw, bh);
        self.play.frame = CGRectMake(x + bw + 8, by, bw + 10, bh);
        self.next.frame = CGRectMake(x + 2 * bw + 26, by, bw, bh);
        self.stop.frame = CGRectMake(x + 3 * bw + 34, by, bw, bh);
        x += 4 * bw + 50;
        self.volume.frame = CGRectMake(x, top + (H - 34) / 2, MAX(80, 20 + W - x), 34);
        return;
    }
    if (self.picker) {
        self.picker.frame = CGRectMake(c.origin.x, self.titleLabel.text.length ? 12 : y, MIN(c.size.width, 120 * self.players.count), 30);
        if (!self.titleLabel.text.length) y += 40;
        self.titleLabel.hidden = YES;
        y = MAX(y, 54);
    }
    CGFloat h = c.origin.y + c.size.height - y;
    CGFloat art = MIN(h, c.size.width * 0.42);
    self.art.frame = CGRectMake(c.origin.x, y, art, art);
    CGFloat tx = c.origin.x + art + 20, tw = c.origin.x + c.size.width - tx;
    self.stateLabel.frame = CGRectMake(tx, y, tw, 18);
    self.track.frame = CGRectMake(tx, y + 22, tw, 34);
    self.artist.frame = CGRectMake(tx, y + 58, tw, 24);
    CGFloat bh = MIN(60, MAX(44, h - 150)), bw = (tw - 30) / 4;
    CGFloat by = y + 96;
    self.prev.frame = CGRectMake(tx, by, bw, bh);
    self.play.frame = CGRectMake(tx + bw + 10, by, bw, bh);
    self.next.frame = CGRectMake(tx + 2 * (bw + 10), by, bw, bh);
    self.stop.frame = CGRectMake(tx + 3 * (bw + 10), by, bw, bh);
    self.volume.frame = CGRectMake(tx, by + bh + 14, tw, 34);
    [self placeSeekAt:CGRectMake(tx, MIN(by + bh + 56, CGRectGetMaxY(c) - 24), tw, 24)];
}

- (void)pickerChanged {
    NSString *key = [@"player." stringByAppendingString:Str(self.spec[@"title"]) ?: @"media"];
    [[NSUserDefaults standardUserDefaults] setInteger:self.picker.selectedSegmentIndex forKey:key];
    self.artPath = nil; self.art.image = nil; self.track.text = @""; self.artist.text = @"";
    [self.host cardWantsRefresh:self];
}

- (void)paintPlaying:(BOOL)playing {
    self.isPlaying = playing;
    [self.play setTitle:playing ? @"❚❚" : @"▶︎" forState:UIControlStateNormal];
    HA_SetBG(self.play, playing ? HA_BLUE() : HA_OFF());
}

- (void)updateStates:(NSDictionary *)states {
    // State and controls always come from the speaker (Cast) entity. The optional "plex_session"
    // entity is only used for artwork: Plex's Cast session can't be controlled through Home Assistant.
    NSDictionary *s = states[[self current]];
    if (!s) return;
    self.last = s;
    [self paintPosition];
    NSDictionary *a = s[@"attributes"];
    NSString *state = s[@"state"];
    BOOL playing = [state isEqualToString:@"playing"] || [state isEqualToString:@"buffering"];
    BOOL idle = [@[@"off", @"idle", @"unavailable", @"standby", @"unknown"] containsObject:state ?: @""];
    BOOL optimistic = self.optimisticUntil && [self.optimisticUntil timeIntervalSinceNow] > 0;
    if (optimistic && playing == self.isPlaying) { self.optimisticUntil = nil; optimistic = NO; }   // HA caught up
    if (!optimistic) {
        NSString *pending = HA_PendingPlayLabel([self current]);
        self.stateLabel.text = (pending && !playing) ? pending : [state uppercaseString];
        [self paintPlaying:playing];
    }
    NSString *title = Str(a[@"media_title"]);
    NSString *artist = Str(a[@"media_artist"]) ?: Str(a[@"media_album_name"]) ?: Str(a[@"app_name"]);
    self.track.text = title.length ? title : (idle ? @"Nothing playing" : @"");
    self.artist.text = artist ?: @"";
    self.stop.enabled = !idle; self.stop.alpha = idle ? 0.35 : 1;
    NSNumber *vol = a[@"volume_level"];
    BOOL hasVol = [vol isKindOfClass:[NSNumber class]];
    if (hasVol && !(self.suppressUntil && [self.suppressUntil timeIntervalSinceNow] > 0)) self.volume.value = vol.floatValue;
    self.volume.enabled = hasVol;
    NSString *pic = idle ? nil : HA_NowPlayingPicture(s, states[Str(self.spec[@"plex_session"]) ?: @""], Str(self.spec[@"plex_server"]));
    if (!(pic == self.artPath || [pic isEqualToString:self.artPath])) {
        self.artPath = pic;
        if (!pic) { self.art.image = nil; return; }
        HALog(@"art: %@ [%@] \"%@\" speaker picture %@, plex session [%@] \"%@\", content %@", [self current], Str(s[@"state"]), Str(s[@"attributes"][@"media_title"]) ?: @"", HA_PictureOf(s) ? @"yes" : @"no",
              Str(states[Str(self.spec[@"plex_session"]) ?: @""][@"state"]) ?: @"-", Str(states[Str(self.spec[@"plex_session"]) ?: @""][@"attributes"][@"media_title"]) ?: @"", Str(s[@"attributes"][@"media_content_id"]) ?: @"-");

        __weak HAMediaCard *ws = self;
        [[HAClient shared] loadImagePath:pic completion:^(UIImage *img) { if ([pic isEqualToString:ws.artPath]) { HA_Fade(ws.art, 0.3); ws.art.image = img; } }];
    }
}

- (void)media:(NSString *)svc extra:(NSDictionary *)extra {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithObject:[self current] forKey:@"entity_id"];
    if (extra) [d addEntriesFromDictionary:extra];
    [self.host card:self callService:[@"media_player." stringByAppendingString:svc] data:d];
}
- (void)prevTapped { if (!HA_QueueSkip(-1, [self current], self.last, self)) [self media:@"media_previous_track" extra:nil]; else self.stateLabel.text = @"PREVIOUS…"; }
- (void)nextTapped { if (!HA_QueueSkip(1, [self current], self.last, self)) [self media:@"media_next_track" extra:nil]; else self.stateLabel.text = @"NEXT…"; }
- (void)playTapped {
    // explicit pause / play (not play_pause) and flip the button right away; HA confirms within a few seconds
    BOOL wasPlaying = self.isPlaying;
    [self paintPlaying:!wasPlaying];
    self.stateLabel.text = wasPlaying ? @"PAUSING…" : @"RESUMING…";
    self.optimisticUntil = [NSDate dateWithTimeIntervalSinceNow:6];
    [self media:wasPlaying ? @"media_pause" : @"media_play" extra:nil];
}
- (void)stopTapped {
    [self paintPlaying:NO];
    self.stateLabel.text = @"STOPPING…";
    self.optimisticUntil = [NSDate dateWithTimeIntervalSinceNow:6];
    HA_SetPendingPlay(nil, nil);
    [self media:@"turn_off" extra:nil];   // Cast: quits the running app = stops casting
}
- (void)volBegan { self.suppressUntil = [NSDate dateWithTimeIntervalSinceNow:60]; }
- (void)volEnded {
    self.suppressUntil = [NSDate dateWithTimeIntervalSinceNow:3];
    [self media:@"volume_set" extra:@{@"volume_level": @(roundf(self.volume.value * 100) / 100.0)}];
}

@end

#pragma mark - Forecast
// { "type":"forecast", "entity":"weather.forecast_home", "days":5 }

@interface HAForecastCard ()
@property (nonatomic, copy) NSString *entity;
@property (nonatomic, strong) NSMutableArray *cols;
@property (nonatomic, assign) NSUInteger shown;   // days the provider actually returned (0 = not loaded yet)
@end

@implementation HAForecastCard

- (instancetype)initWithSpec:(NSDictionary *)spec host:(id<HACardHost>)host {
    if ((self = [super initWithSpec:spec host:host])) {
        _entity = Str(spec[@"entity"]) ?: @"weather.forecast_home";
        if (!Str(spec[@"title"])) self.titleLabel.text = @"FORECAST";
        NSInteger days = MAX(1, MIN(10, Int(spec[@"days"], 5)));
        _cols = [NSMutableArray array];
        for (NSInteger i = 0; i < days; i++) {
            NSMutableArray *ls = [NSMutableArray array];
            for (NSInteger j = 0; j < 4; j++) {
                UILabel *l = [self addLabel:(j == 1 ? 38 : 19) weight:(j == 0 ? 0.3 : 0) color:(j == 3 ? HA_DIM() : HA_TEXT())];
                l.textAlignment = NSTextAlignmentCenter;
                [ls addObject:l];
            }
            [_cols addObject:ls];
        }
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect c = [self contentRect];
    NSUInteger n = self.shown ? MIN(self.shown, self.cols.count) : self.cols.count;   // spread the days we have across the width
    CGFloat w = c.size.width / MAX(1, n);
    if (c.size.height < 120) {
        // Compact: day / icon / "hi° lo°" packed into the available height.
        CGFloat dayH = 20, iconH = MAX(24, c.size.height - 46), y0 = c.origin.y + MAX(0, (c.size.height - (dayH + iconH + 22)) / 2);
        for (NSUInteger i = 0; i < self.cols.count; i++) {
            UILabel *day = self.cols[i][0], *icon = self.cols[i][1], *hi = self.cols[i][2], *lo = self.cols[i][3];
            day.font = HA_FONT(16, 0.3); icon.font = HA_FONT(iconH * 0.8, 0); hi.font = HA_FONT(17, 0.3); lo.font = HA_FONT(17, 0);
            CGFloat x = c.origin.x + i * w;
            day.frame = CGRectMake(x, y0, w, dayH);
            icon.frame = CGRectMake(x, y0 + dayH, w, iconH);
            hi.frame = CGRectMake(x, y0 + dayH + iconH + 2, w / 2, 20); hi.textAlignment = NSTextAlignmentRight;
            lo.frame = CGRectMake(x + w / 2 + 6, y0 + dayH + iconH + 2, w / 2 - 6, 20); lo.textAlignment = NSTextAlignmentLeft;
        }
        return;
    }
    for (NSUInteger i = 0; i < self.cols.count; i++) {
        ((UILabel *)self.cols[i][2]).textAlignment = NSTextAlignmentCenter;
        ((UILabel *)self.cols[i][3]).textAlignment = NSTextAlignmentCenter;
    }
    // Scale up to fill tall cards (up to 2x), and centre vertically.
    CGFloat base[4] = {24, 50, 24, 24}, fonts[4] = {19, 38, 19, 19};
    CGFloat baseH = base[0] + base[1] + base[2] + base[3] + 12;
    CGFloat k = MAX(1.0, MIN(2.0, c.size.height / (baseH * 1.25)));
    k = MIN(k, MAX(1.0, w / 90.0));
    CGFloat y0 = c.origin.y + MAX(0, (c.size.height - baseH * k) / 2);
    for (NSUInteger i = 0; i < self.cols.count; i++) {
        CGFloat y = y0;
        for (NSInteger j = 0; j < 4; j++) {
            UILabel *l = self.cols[i][j];
            l.font = HA_FONT(fonts[j] * k, j == 0 ? 0.3 : 0);
            l.frame = CGRectMake(c.origin.x + i * w, y, w, base[j] * k);
            y += (base[j] + 4) * k;
        }
    }
}

- (void)reload {
    __weak HAForecastCard *ws = self;
    [[HAClient shared] callServiceWithResponse:@"weather" service:@"get_forecasts" data:@{@"entity_id": self.entity, @"type": @"daily"} completion:^(id json, NSError *e) {
        HAForecastCard *ss = ws;
        if (!ss || ![json isKindOfClass:[NSDictionary class]]) return;
        NSArray *fc = HA_CleanList(json[@"service_response"][ss.entity][@"forecast"]);
        if (![fc isKindOfClass:[NSArray class]]) return;
        NSDateFormatter *inFmt = [[NSDateFormatter alloc] init];
        inFmt.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        inFmt.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZZZZZ";
        NSDateFormatter *outFmt = [[NSDateFormatter alloc] init]; outFmt.dateFormat = @"EEE";
        ss.shown = MAX((NSUInteger)1, MIN(fc.count, ss.cols.count));
        [ss setNeedsLayout];
        for (NSUInteger i = 0; i < ss.cols.count; i++) {
            NSArray *ls = ss.cols[i];
            BOOL has = i < fc.count;
            for (UILabel *l in ls) l.hidden = !has;
            if (!has) continue;
            NSDictionary *d = fc[i];
            NSDate *date = [inFmt dateFromString:Str(d[@"datetime"]) ?: @""];
            ((UILabel *)ls[0]).text = i == 0 ? @"Today" : (date ? [outFmt stringFromDate:date] : @"");
            ((UILabel *)ls[1]).text = HA_WeatherGlyph(Str(d[@"condition"]));
            ((UILabel *)ls[2]).text = [NSString stringWithFormat:@"%.0f°", [d[@"temperature"] doubleValue]];
            ((UILabel *)ls[3]).text = d[@"templow"] ? [NSString stringWithFormat:@"%.0f°", [d[@"templow"] doubleValue]] : @"";
        }
    }];
}

@end

#pragma mark - Ad blocking
// { "type":"adblock", "pause_minutes":[10, 60] }   uses rest_command.adguard_pause / adguard_resume

@interface HAAdblockCard ()
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) NSMutableArray *pauseButtons;
@property (nonatomic, strong) UIButton *resume;
@property (nonatomic, strong) NSDate *until;
@end

@implementation HAAdblockCard

- (instancetype)initWithSpec:(NSDictionary *)spec host:(id<HACardHost>)host {
    if ((self = [super initWithSpec:spec host:host])) {
        if (!Str(spec[@"title"])) self.titleLabel.text = @"AD BLOCKING";
        _status = [self addLabel:20 weight:0.2 color:HA_TEXT()];
        _pauseButtons = [NSMutableArray array];
        NSArray *mins = [spec[@"pause_minutes"] isKindOfClass:[NSArray class]] ? spec[@"pause_minutes"] : @[@10, @60];
        for (id m in mins) {
            NSInteger v = Int(m, 10);
            NSString *t = v % 60 == 0 ? [NSString stringWithFormat:@"Pause %ld hr", (long)(v / 60)] : [NSString stringWithFormat:@"Pause %ld min", (long)v];
            UIButton *b = [self addButton:t size:17 action:@selector(pauseTapped:)];
            b.tag = v;
            [_pauseButtons addObject:b];
        }
        _resume = [self addButton:@"Resume" size:17 action:@selector(resumeTapped)];
        [self tick];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect c = [self contentRect];
    self.status.frame = CGRectMake(c.origin.x, c.origin.y - 2, c.size.width, 26);
    NSInteger n = MAX(1, self.pauseButtons.count);
    CGFloat bw = (c.size.width - (n - 1) * 10) / n;
    CGFloat bh = MIN(52, (c.size.height - 40) / 2 - 6);
    for (NSInteger i = 0; i < (NSInteger)self.pauseButtons.count; i++)
        ((UIButton *)self.pauseButtons[i]).frame = CGRectMake(c.origin.x + i * (bw + 10), c.origin.y + 32, bw, bh);
    self.resume.frame = CGRectMake(c.origin.x, c.origin.y + 32 + bh + 10, c.size.width, bh);
}

- (void)pauseTapped:(UIButton *)b {
    [self.host card:self callService:@"rest_command.adguard_pause" data:@{@"minutes": @(b.tag)}];
    self.until = [NSDate dateWithTimeIntervalSinceNow:b.tag * 60];
    [self tick];
}

- (void)resumeTapped {
    [self.host card:self callService:@"rest_command.adguard_resume" data:@{}];
    self.until = nil;
    [self tick];
}

- (void)tick {
    NSTimeInterval left = [self.until timeIntervalSinceNow];
    if (self.until && left > 0) {
        self.status.text = [NSString stringWithFormat:@"Paused · %ld:%02ld left", (long)left / 60, (long)left % 60];
        self.status.textColor = HA_ACCENT();
    } else {
        self.until = nil;
        self.status.text = @"Blocking ads";
        self.status.textColor = HA_TEXT();
    }
}

@end

#pragma mark - Buttons
// { "type":"buttons", "title":"Scenes", "columns":2,
//   "buttons":[ {"name":"Movie", "service":"scene.turn_on", "data":{"entity_id":"scene.movie"}},
//               {"name":"Fan", "entity":"fan.bedroom"} ] }     // "entity" alone = toggle, lit when on

@interface HAButtonsCard ()
@property (nonatomic, strong) NSArray *defs;
@property (nonatomic, strong) NSMutableArray *buttons;
@end

@implementation HAButtonsCard

- (instancetype)initWithSpec:(NSDictionary *)spec host:(id<HACardHost>)host {
    if ((self = [super initWithSpec:spec host:host])) {
        _defs = [spec[@"buttons"] isKindOfClass:[NSArray class]] ? spec[@"buttons"] : @[];
        _buttons = [NSMutableArray array];
        for (NSUInteger i = 0; i < _defs.count; i++) {
            NSDictionary *d = [_defs[i] isKindOfClass:[NSDictionary class]] ? _defs[i] : @{};
            UIButton *b = [self addButton:Str(d[@"name"]) ?: @"?" size:18 action:@selector(tapped:)];
            b.tag = i;
            [_buttons addObject:b];
        }
    }
    return self;
}

- (NSArray *)entityIds {
    NSMutableArray *ids = [NSMutableArray array];
    for (id d in self.defs) if ([d isKindOfClass:[NSDictionary class]] && Str(d[@"entity"]) && !Str(d[@"service"])) [ids addObject:d[@"entity"]];
    return ids;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect c = [self contentRect];
    NSInteger n = self.buttons.count; if (!n) return;
    NSInteger cols = MAX(1, Int(self.spec[@"columns"], n <= 2 ? n : 2));
    NSInteger rows = (n + cols - 1) / cols;
    CGFloat bw = (c.size.width - (cols - 1) * 10) / cols;
    CGFloat bh = MIN(80, (c.size.height - (rows - 1) * 10) / rows);
    for (NSInteger i = 0; i < n; i++)
        ((UIButton *)self.buttons[i]).frame = CGRectMake(c.origin.x + (i % cols) * (bw + 10), c.origin.y + (i / cols) * (bh + 10), bw, bh);
}

- (void)tapped:(UIButton *)b {
    NSDictionary *d = self.defs[b.tag];
    NSString *svc = Str(d[@"service"]);
    NSDictionary *data = [d[@"data"] isKindOfClass:[NSDictionary class]] ? d[@"data"] : nil;
    if (!svc && Str(d[@"entity"])) {
        NSString *ent = d[@"entity"];
        NSString *domain = [ent componentsSeparatedByString:@"."][0];
        if ([@[@"scene", @"script"] containsObject:domain]) svc = [domain stringByAppendingString:@".turn_on"];
        else svc = @"homeassistant.toggle";
        data = @{@"entity_id": ent};
    }
    if (svc) [self.host card:self callService:svc data:data ?: @{}];
}

- (void)updateStates:(NSDictionary *)states {
    for (NSUInteger i = 0; i < self.defs.count; i++) {
        NSDictionary *d = self.defs[i];
        if (![d isKindOfClass:[NSDictionary class]] || Str(d[@"service"]) || !Str(d[@"entity"])) continue;
        NSString *st = states[d[@"entity"]][@"state"];
        BOOL on = [@[@"on", @"open", @"playing", @"home"] containsObject:st ?: @""];
        UIButton *b = self.buttons[i];
        HA_SetBG(b, on ? HA_ACCENT() : HA_OFF());
        [b setTitleColor:on ? [UIColor blackColor] : HA_TEXT() forState:UIControlStateNormal];
    }
}

@end

#pragma mark - Sensors
// { "type":"sensors", "title":"Climate", "entities":[ {"entity":"sensor.bedroom_temperature","name":"Temp"} ] }

@interface HASensorsCard ()
@property (nonatomic, strong) NSArray *defs;
@property (nonatomic, strong) NSMutableArray *names, *values;
@end

@implementation HASensorsCard

- (instancetype)initWithSpec:(NSDictionary *)spec host:(id<HACardHost>)host {
    if ((self = [super initWithSpec:spec host:host])) {
        NSMutableArray *defs = [NSMutableArray array];
        for (id e in ([spec[@"entities"] isKindOfClass:[NSArray class]] ? spec[@"entities"] : @[])) {
            if ([e isKindOfClass:[NSString class]]) [defs addObject:@{@"entity": e}];
            else if ([e isKindOfClass:[NSDictionary class]] && Str(e[@"entity"])) [defs addObject:e];
        }
        _defs = defs;
        _names = [NSMutableArray array]; _values = [NSMutableArray array];
        for (NSDictionary *d in defs) {
            UILabel *n = [self addLabel:18 weight:0 color:HA_DIM()];
            n.text = Str(d[@"name"]) ?: d[@"entity"];
            UILabel *v = [self addLabel:22 weight:0.3 color:HA_TEXT()];
            v.textAlignment = NSTextAlignmentRight;
            v.text = @"–";
            [_names addObject:n]; [_values addObject:v];
        }
    }
    return self;
}

- (NSArray *)entityIds { return [self.defs valueForKey:@"entity"]; }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect c = [self contentRect];
    CGFloat rh = MIN(40, c.size.height / MAX(1, self.defs.count));
    for (NSUInteger i = 0; i < self.defs.count; i++) {
        ((UILabel *)self.names[i]).frame = CGRectMake(c.origin.x, c.origin.y + i * rh, c.size.width * 0.55, rh);
        ((UILabel *)self.values[i]).frame = CGRectMake(c.origin.x + c.size.width * 0.55, c.origin.y + i * rh, c.size.width * 0.45, rh);
    }
}

- (void)updateStates:(NSDictionary *)states {
    for (NSUInteger i = 0; i < self.defs.count; i++) {
        NSDictionary *d = self.defs[i];
        NSDictionary *s = states[d[@"entity"]];
        if (!s) continue;
        NSString *v = Str(s[@"state"]) ?: @"";
        NSString *unit = Str(s[@"attributes"][@"unit_of_measurement"]);
        double num = [v doubleValue];
        if (num != 0 && [v rangeOfString:@"."].location != NSNotFound) v = [NSString stringWithFormat:@"%.1f", num];
        ((UILabel *)self.values[i]).text = unit.length ? [NSString stringWithFormat:@"%@ %@", v, unit] : v;
        if (!Str(d[@"name"]) && Str(s[@"attributes"][@"friendly_name"])) ((UILabel *)self.names[i]).text = s[@"attributes"][@"friendly_name"];
    }
}

@end

#pragma mark - Home (all switches in the house, grouped by area)
// Built-in card for the shared Home drawer. Spec comes from /local/hapanel/home.json:
// { "domains":["light","switch","cover"], "exclude":["switch.wyze_cam_*"], "area_order":["Bedroom"], "columns":4 }
// One /api/template call returns every matching entity with its area, so refreshing is a single request.

@interface HAHomeCard ()
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) NSArray *items;               // [{e,n,s,a}] after filtering
@property (nonatomic, strong) NSMutableDictionary *tiles;   // entity_id -> UIButton
@property (nonatomic, strong) NSMutableArray *headers;
@property (nonatomic, copy) NSString *signature;             // entity list, to know when to rebuild
@property (nonatomic, strong) UILabel *empty;
@property (nonatomic, assign) NSInteger ticks;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, strong) NSDate *suppressUntil;
@end

@implementation HAHomeCard

- (instancetype)initWithSpec:(NSDictionary *)spec host:(id<HACardHost>)host {
    if ((self = [super initWithSpec:spec host:host])) {
        if (!Str(spec[@"title"])) self.titleLabel.text = @"WHOLE HOME";
        _scroll = [[UIScrollView alloc] init];
        _scroll.alwaysBounceVertical = YES;
        _scroll.indicatorStyle = UIScrollViewIndicatorStyleWhite;
        [self addSubview:_scroll];
        _tiles = [NSMutableDictionary dictionary];
        _headers = [NSMutableArray array];
        _empty = [self addLabel:18 weight:0 color:HA_DIM()];
        _empty.text = @"Loading…";
        _empty.textAlignment = NSTextAlignmentCenter;
        _empty.numberOfLines = 0;
    }
    return self;
}

- (NSString *)templateString {
    NSArray *domains = [self.spec[@"domains"] isKindOfClass:[NSArray class]] ? self.spec[@"domains"] : @[@"light", @"switch", @"cover", @"fan", @"lock", @"input_boolean"];
    NSData *dj = [NSJSONSerialization dataWithJSONObject:domains options:0 error:nil];
    NSString *list = [[NSString alloc] initWithData:dj encoding:NSUTF8StringEncoding];
    return [NSString stringWithFormat:
        @"{%%- set ns = namespace(o=[]) -%%}"
        @"{%%- for s in states if s.domain in %@ -%%}"
        @"{%%- set ns.o = ns.o + [{'e': s.entity_id, 'n': s.name, 's': s.state, 'a': (area_name(s.entity_id) or '')}] -%%}"
        @"{%%- endfor -%%}{{ ns.o | tojson }}", list];
}

- (BOOL)excluded:(NSString *)eid {
    for (id pat in ([self.spec[@"exclude"] isKindOfClass:[NSArray class]] ? self.spec[@"exclude"] : @[])) {
        if ([pat isKindOfClass:[NSString class]] && [[NSPredicate predicateWithFormat:@"SELF LIKE %@", pat] evaluateWithObject:eid]) return YES;
    }
    return NO;
}

- (void)reload { self.ticks = 0; [self refresh]; }

- (void)tick {
    if (!self.active) return;
    if (++self.ticks % 3 == 0) [self refresh];
}

- (void)refresh {
    if (self.loading || !self.active) return;
    if (self.suppressUntil && [self.suppressUntil timeIntervalSinceNow] > 0) return;
    self.loading = YES;
    __weak HAHomeCard *ws = self;
    [[HAClient shared] renderTemplate:[self templateString] completion:^(id json, NSError *e) {
        HAHomeCard *ss = ws;
        if (!ss) return;
        ss.loading = NO;
        if (![json isKindOfClass:[NSArray class]]) {
            ss.empty.text = [NSString stringWithFormat:@"Could not load devices\n%@", e.localizedDescription ?: @"unexpected response"];
            ss.empty.hidden = NO;
            return;
        }
        NSMutableArray *items = [NSMutableArray array];
        for (NSDictionary *it in json) if ([it isKindOfClass:[NSDictionary class]] && Str(it[@"e"]) && ![ss excluded:it[@"e"]]) [items addObject:it];
        NSArray *order = [ss.spec[@"area_order"] isKindOfClass:[NSArray class]] ? ss.spec[@"area_order"] : @[];
        [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSString *aa = Str(a[@"a"]) ?: @"", *ba = Str(b[@"a"]) ?: @"";
            NSUInteger ia = [order indexOfObject:aa], ib = [order indexOfObject:ba];
            if (ia != ib) return ia < ib ? NSOrderedAscending : NSOrderedDescending;   // listed areas first
            if (![aa isEqualToString:ba]) {
                if (!aa.length) return NSOrderedDescending;                              // unassigned last
                if (!ba.length) return NSOrderedAscending;
                return [aa localizedCaseInsensitiveCompare:ba];
            }
            return [Str(a[@"n"]) ?: @"" localizedCaseInsensitiveCompare:Str(b[@"n"]) ?: @""];
        }];
        ss.items = items;
        NSString *sig = [[items valueForKey:@"e"] componentsJoinedByString:@","];
        if (![sig isEqualToString:ss.signature]) { ss.signature = sig; [ss rebuild]; }
        [ss paint];
    }];
}

- (void)rebuild {
    for (UIView *v in self.scroll.subviews) [v removeFromSuperview];
    [self.tiles removeAllObjects];
    [self.headers removeAllObjects];
    NSString *area = nil;
    for (NSDictionary *it in self.items) {
        NSString *a = Str(it[@"a"]).length ? it[@"a"] : @"Other";
        if (![a isEqualToString:area]) {
            area = a;
            UILabel *h = [[UILabel alloc] init];
            h.text = [a uppercaseString];
            h.font = HA_FONT(15, 0.4);
            h.textColor = HA_DIM();
            [self.scroll addSubview:h];
            [self.headers addObject:h];
        }
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.titleLabel.font = HA_FONT(16, 0.2);
        b.titleLabel.numberOfLines = 2;
        b.titleLabel.textAlignment = NSTextAlignmentCenter;
        b.titleLabel.adjustsFontSizeToFitWidth = YES;
        b.titleLabel.minimumScaleFactor = 0.6;
        b.titleEdgeInsets = UIEdgeInsetsMake(0, 6, 0, 6);
        b.layer.cornerRadius = 14;
        b.accessibilityIdentifier = it[@"e"];
        HA_AddPress(b);
        [b addTarget:self action:@selector(tileTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.scroll addSubview:b];
        self.tiles[it[@"e"]] = b;
    }
    self.empty.text = self.items.count ? @"" : @"No devices match home.json";
    self.empty.hidden = self.items.count > 0;
    [self setNeedsLayout];
}

- (void)paint {
    for (NSDictionary *it in self.items) {
        UIButton *b = self.tiles[it[@"e"]];
        NSString *st = Str(it[@"s"]) ?: @"";
        BOOL on = [@[@"on", @"open", @"opening", @"unlocked"] containsObject:st];
        BOOL dead = [st isEqualToString:@"unavailable"] || [st isEqualToString:@"unknown"];
        [b setTitle:Str(it[@"n"]) ?: it[@"e"] forState:UIControlStateNormal];
        HA_SetBG(b, on ? HA_ACCENT() : HA_OFF());
        [b setTitleColor:on ? [UIColor blackColor] : HA_TEXT() forState:UIControlStateNormal];
        b.enabled = !dead; b.alpha = dead ? 0.35 : 1;
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect c = [self contentRect];
    self.scroll.frame = c;
    self.empty.frame = CGRectInset(c, 20, 40);
    NSInteger cols = MAX(1, Int(self.spec[@"columns"], 4));
    CGFloat gap = 10, tw = (c.size.width - (cols - 1) * gap) / cols, th = 64;
    CGFloat y = 0; NSInteger col = 0, hi = 0;
    NSString *area = nil;
    for (NSDictionary *it in self.items) {
        NSString *a = Str(it[@"a"]).length ? it[@"a"] : @"Other";
        if (![a isEqualToString:area]) {
            if (area) y += (col ? th + gap : 0) + 10;
            area = a; col = 0;
            if (hi < (NSInteger)self.headers.count) ((UIView *)self.headers[hi++]).frame = CGRectMake(0, y, c.size.width, 22);
            y += 28;
        }
        ((UIView *)self.tiles[it[@"e"]]).frame = CGRectMake(col * (tw + gap), y, tw, th);
        if (++col == cols) { col = 0; y += th + gap; }
    }
    if (col) y += th + gap;
    self.scroll.contentSize = CGSizeMake(c.size.width, y + 10);
}

- (void)tileTapped:(UIButton *)b {
    NSString *eid = b.accessibilityIdentifier;
    NSString *domain = [eid componentsSeparatedByString:@"."][0];
    NSString *svc = @"homeassistant.toggle";
    NSString *cur = nil;
    for (NSDictionary *it in self.items) if ([it[@"e"] isEqualToString:eid]) cur = Str(it[@"s"]);
    if ([domain isEqualToString:@"cover"]) svc = @"cover.toggle";
    if ([domain isEqualToString:@"lock"]) svc = [cur isEqualToString:@"locked"] ? @"lock.unlock" : @"lock.lock";
    // optimistic flip so the tile responds instantly
    NSMutableArray *items = [self.items mutableCopy];
    for (NSUInteger i = 0; i < items.count; i++) if ([items[i][@"e"] isEqualToString:eid]) {
        NSMutableDictionary *m = [items[i] mutableCopy];
        m[@"s"] = [cur isEqualToString:@"on"] ? @"off" : ([cur isEqualToString:@"off"] ? @"on" : (cur ?: @""));
        items[i] = m;
    }
    self.items = items;
    [self paint];
    self.suppressUntil = [NSDate dateWithTimeIntervalSinceNow:1.0];
    [self.host card:self callService:svc data:@{@"entity_id": eid}];
    __weak HAHomeCard *ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [ws refresh]; });
}

@end

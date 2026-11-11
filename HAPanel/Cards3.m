// Third batch of cards: tesla, updates, timer. Registered by name in Cards.m.
#import "Cards.h"
#import "HAClient.h"
#import <QuartzCore/QuartzCore.h>

#define Str HA_Str
#define Int HA_Int

static NSArray *Arr3(id v) { return [v isKindOfClass:[NSArray class]] ? v : @[]; }
static NSDictionary *Dict3(id v) { return [v isKindOfClass:[NSDictionary class]] ? v : nil; }

static UILabel *L3(UIView *parent, CGFloat size, CGFloat weight, UIColor *color) {
    UILabel *l = [[UILabel alloc] init];
    l.font = HA_FONT(size, weight); l.textColor = color;
    l.adjustsFontSizeToFitWidth = YES; l.minimumScaleFactor = 0.5;
    [parent addSubview:l];
    return l;
}

#pragma mark - Tesla (TeslaMate over MQTT)
// { "type":"tesla", "prefix":"tesla_" }   reads sensor.tesla_* / binary_sensor.tesla_* from packages/teslamate.yaml

@interface HATeslaCard : HACard
@property (nonatomic, copy) NSString *p;
@property (nonatomic, strong) NSDictionary *states;
@property (nonatomic, strong) UILabel *name, *stateLabel, *battery, *range, *chargeTitle, *waiting;
@property (nonatomic, strong) UIView *barBack, *barFill, *barLimit;
@property (nonatomic, strong) NSMutableArray *chargeFacts, *facts;   // pairs of labels
@property (nonatomic, strong) UIImageView *carImage;
@end

@implementation HATeslaCard

- (instancetype)initWithSpec:(NSDictionary *)spec host:(id<HACardHost>)host {
    if ((self = [super initWithSpec:spec host:host])) {
        _p = Str(spec[@"prefix"]) ?: @"tesla_";
        if (!Str(spec[@"title"])) self.titleLabel.text = @"TESLA";
        if ([spec[@"embedded"] boolValue]) { self.backgroundColor = [UIColor clearColor]; self.layer.cornerRadius = 0; }   // a page inside the cars card
        if (Str(spec[@"image"])) {
            _carImage = [[UIImageView alloc] init];
            _carImage.contentMode = UIViewContentModeScaleAspectFit;
            [self addSubview:_carImage];
            _carImage.hidden = YES;   // shown once the picture loads; until then the text uses the full width
            __weak HATeslaCard *ws = self;
            [[HAClient shared] loadImagePath:spec[@"image"] completion:^(UIImage *img) {
                if (!img) return;
                ws.carImage.hidden = NO;
                HA_Fade(ws.carImage, 0.3);
                ws.carImage.image = img;
                [ws setNeedsLayout];
            }];
        }
        _name = L3(self, 30, 0.3, HA_TEXT());
        _stateLabel = L3(self, 15, 0.4, HA_ACCENT());
        _battery = L3(self, 64, -0.4, HA_TEXT());
        _range = L3(self, 22, 0.2, HA_DIM());
        _barBack = [[UIView alloc] init]; _barBack.backgroundColor = HA_OFF(); _barBack.layer.cornerRadius = 9; _barBack.clipsToBounds = YES;
        _barFill = [[UIView alloc] init];
        _barLimit = [[UIView alloc] init]; _barLimit.backgroundColor = HA_TEXT();
        [_barBack addSubview:_barFill]; [_barBack addSubview:_barLimit];
        [self addSubview:_barBack];
        _chargeTitle = L3(self, 13, 0.4, HA_DIM()); _chargeTitle.text = @"CHARGING";
        _waiting = L3(self, 18, 0, HA_DIM());
        _waiting.numberOfLines = 0; _waiting.textAlignment = NSTextAlignmentCenter;
        _waiting.text = @"Waiting for TeslaMate…\nEnable MQTT in the TeslaMate container to see your car here.";
        _chargeFacts = [NSMutableArray array]; _facts = [NSMutableArray array];
        for (NSInteger i = 0; i < 4; i++) [_chargeFacts addObject:@[L3(self, 13, 0, HA_DIM()), L3(self, 22, 0.3, HA_TEXT())]];
        for (NSInteger i = 0; i < 9; i++) [_facts addObject:@[L3(self, 13, 0, HA_DIM()), L3(self, 19, 0.3, HA_TEXT())]];
    }
    return self;
}

- (NSString *)s:(NSString *)key { return [NSString stringWithFormat:@"sensor.%@%@", self.p, key]; }
- (NSString *)b:(NSString *)key { return [NSString stringWithFormat:@"binary_sensor.%@%@", self.p, key]; }

- (NSArray *)entityIds {
    NSMutableArray *ids = [NSMutableArray array];
    for (NSString *k in @[@"name", @"state", @"battery", @"range", @"charge_limit", @"charger_power", @"charge_added", @"time_to_full",
                          @"inside_temperature", @"outside_temperature", @"odometer", @"location", @"software"]) [ids addObject:[self s:k]];
    for (NSString *k in @[@"plugged_in", @"locked", @"sentry_mode", @"climate_on", @"doors_open", @"windows_open", @"trunk_open", @"frunk_open", @"update_available"])
        [ids addObject:[self b:k]];
    return ids;
}

- (NSString *)v:(NSString *)eid {
    NSString *st = Str(self.states[eid][@"state"]);
    return (st && ![st isEqualToString:@"unknown"] && ![st isEqualToString:@"unavailable"]) ? st : nil;
}
- (BOOL)on:(NSString *)key { return [[self v:[self b:key]] isEqualToString:@"on"]; }

- (void)updateStates:(NSDictionary *)states {
    self.states = states;
    NSString *bat = [self v:[self s:@"battery"]];
    BOOL has = bat != nil;
    for (UIView *v in self.subviews) if (v != self.titleLabel && v != self.waiting && v != self.carImage && v.tag != 991) v.hidden = !has;
    self.waiting.hidden = has;
    if (!has) return;
    NSString *state = [self v:[self s:@"state"]] ?: @"";
    BOOL charging = [state isEqualToString:@"charging"];
    self.name.text = Str(self.spec[@"name"]) ?: [self v:[self s:@"name"]] ?: @"Tesla";
    self.stateLabel.text = [[state stringByReplacingOccurrencesOfString:@"_" withString:@" "] uppercaseString];
    self.battery.text = [NSString stringWithFormat:@"%@%%", bat];
    NSString *range = [self v:[self s:@"range"]];
    self.range.text = range ? [NSString stringWithFormat:@"%@ mi range", range] : @"";
    double pct = MAX(0, MIN(100, [bat doubleValue])), limit = [[self v:[self s:@"charge_limit"]] doubleValue];
    UIColor *fill = pct <= 20 ? RGB(255, 69, 58) : (charging ? HA_ACCENT() : RGB(48, 209, 88));
    HA_SetBG(self.barFill, fill);
    self.barFill.tag = (NSInteger)pct; self.barLimit.tag = (NSInteger)limit;
    if (charging && ![self.barFill.layer animationForKey:@"pulse"]) {   // gentle pulse while charging
        CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"opacity"];
        a.fromValue = @1; a.toValue = @0.55; a.duration = 1.2; a.autoreverses = YES; a.repeatCount = HUGE_VALF;
        [self.barFill.layer addAnimation:a forKey:@"pulse"];
    } else if (!charging) [self.barFill.layer removeAnimationForKey:@"pulse"];

    BOOL plugged = [self on:@"plugged_in"];
    NSArray *cf = @[@[@"Power", [self v:[self s:@"charger_power"]] ? [NSString stringWithFormat:@"%@ kW", [self v:[self s:@"charger_power"]]] : @"–"],
                    @[@"Added", [self v:[self s:@"charge_added"]] ? [NSString stringWithFormat:@"%@ kWh", [self v:[self s:@"charge_added"]]] : @"–"],
                    @[@"Full in", [self v:[self s:@"time_to_full"]] ? [self hours:[self v:[self s:@"time_to_full"]]] : @"–"],
                    @[@"Limit", limit > 0 ? [NSString stringWithFormat:@"%.0f%%", limit] : @"–"]];
    for (NSUInteger i = 0; i < cf.count; i++) {
        ((UILabel *)self.chargeFacts[i][0]).text = cf[i][0];
        ((UILabel *)self.chargeFacts[i][1]).text = cf[i][1];
    }
    self.chargeTitle.text = charging ? @"CHARGING" : (plugged ? @"PLUGGED IN" : @"NOT PLUGGED IN");
    self.chargeTitle.textColor = charging ? HA_ACCENT() : HA_DIM();
    for (NSArray *pr in self.chargeFacts) for (UIView *v in pr) v.hidden = !(charging || plugged);

    NSMutableArray *open = [NSMutableArray array];
    if ([self on:@"doors_open"]) [open addObject:@"doors"];
    if ([self on:@"windows_open"]) [open addObject:@"windows"];
    if ([self on:@"trunk_open"]) [open addObject:@"trunk"];
    if ([self on:@"frunk_open"]) [open addObject:@"frunk"];
    NSString *it = [self v:[self s:@"inside_temperature"]], *ot = [self v:[self s:@"outside_temperature"]];
    NSString *odo = [self v:[self s:@"odometer"]], *sw = [self v:[self s:@"software"]];
    NSArray *f = @[@[@"Lock", [self on:@"locked"] ? @"Unlocked ⚠︎" : @"Locked"],
                   @[@"Sentry", [self on:@"sentry_mode"] ? @"On" : @"Off"],
                   @[@"Climate", [self on:@"climate_on"] ? @"On" : @"Off"],
                   @[@"Open", open.count ? [open componentsJoinedByString:@", "] : @"All closed"],
                   @[@"Inside", it ? [it stringByAppendingString:@"°"] : @"–"],
                   @[@"Outside", ot ? [ot stringByAppendingString:@"°"] : @"–"],
                   @[@"Location", [self v:[self s:@"location"]] ?: @"Away"],
                   @[@"Odometer", odo ? [NSString stringWithFormat:@"%@ mi", odo] : @"–"],
                   @[@"Software", sw ? [NSString stringWithFormat:@"%@%@", sw, [self on:@"update_available"] ? @"  • update" : @""] : @"–"]];
    for (NSUInteger i = 0; i < f.count; i++) {
        ((UILabel *)self.facts[i][0]).text = f[i][0];
        UILabel *v = self.facts[i][1];
        v.text = f[i][1];
        BOOL warn = (i == 0 && [self on:@"locked"]) || (i == 3 && open.count) || (i == 8 && [self on:@"update_available"]);
        v.textColor = warn ? HA_ACCENT() : HA_TEXT();
    }
    [self setNeedsLayout];
}

- (NSString *)hours:(NSString *)h {
    double v = [h doubleValue];
    if (v <= 0) return @"–";
    return v < 1 ? [NSString stringWithFormat:@"%.0f min", v * 60] : [NSString stringWithFormat:@"%.0fh %02.0fm", floor(v), fmod(v * 60, 60)];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect c = [self contentRect];
    self.waiting.frame = CGRectInset(c, 20, 40);
    CGFloat W = c.size.width, x = c.origin.x, y = c.origin.y;
    // car picture on the right of the name / battery block when there is one
    CGFloat imgW = (self.carImage && !self.carImage.hidden) ? MIN(W * 0.5, 320) : 0, left = W - imgW - (imgW ? 12 : 0);
    self.carImage.frame = CGRectMake(x + W - imgW, y, imgW, 142);
    self.name.frame = CGRectMake(x, y, left, 36);
    self.stateLabel.frame = CGRectMake(x, y + 36, left, 18);
    self.stateLabel.textAlignment = NSTextAlignmentLeft;
    y += 58;
    self.battery.frame = CGRectMake(x, y, MIN(200, left * 0.55), 70);
    self.range.frame = CGRectMake(x + MIN(200, left * 0.55), y + 34, left - MIN(200, left * 0.55), 28);
    y += 84;
    self.barBack.frame = CGRectMake(x, y, W, 18);
    self.barFill.frame = CGRectMake(0, 0, W * self.barFill.tag / 100.0, 18);
    self.barLimit.frame = CGRectMake(W * self.barLimit.tag / 100.0 - 1, 0, self.barLimit.tag ? 2 : 0, 18);
    y += 34;
    self.chargeTitle.frame = CGRectMake(x, y, W, 16);
    y += 20;
    CGFloat cw = W / 4;
    for (NSUInteger i = 0; i < self.chargeFacts.count; i++) {
        ((UILabel *)self.chargeFacts[i][0]).frame = CGRectMake(x + i * cw, y, cw - 8, 16);
        ((UILabel *)self.chargeFacts[i][1]).frame = CGRectMake(x + i * cw, y + 16, cw - 8, 28);
    }
    y += 60;
    CGFloat fw = W / 3;
    for (NSUInteger i = 0; i < self.facts.count; i++) {
        CGFloat fx = x + (i % 3) * fw, fy = y + (i / 3) * 54;
        ((UILabel *)self.facts[i][0]).frame = CGRectMake(fx, fy, fw - 8, 16);
        ((UILabel *)self.facts[i][1]).frame = CGRectMake(fx, fy + 16, fw - 8, 26);
    }
}

@end

#pragma mark - Tesla cars: swipe between several cars (one HATeslaCard page each)
// { "type":"tesla", "cars":[ {"prefix":"tesla_", "name":"Model S", "image":"/local/hapanel/cars/model_s.png"},
//                            {"prefix":"tesla_2_", "name":"Model X", "image":"/local/hapanel/cars/model_x.png"} ] }
// Without "cars" it behaves as a single car (the spec itself is the only page).

@interface HATeslaCarsCard : HACard <UIScrollViewDelegate>
@property (nonatomic, strong) NSMutableArray *pages;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIPageControl *dots;
@end

@implementation HATeslaCarsCard

- (instancetype)initWithSpec:(NSDictionary *)spec host:(id<HACardHost>)host {
    if ((self = [super initWithSpec:spec host:host])) {
        if (!Str(spec[@"title"])) self.titleLabel.text = @"TESLA";
        NSArray *cars = Arr3(spec[@"cars"]).count ? spec[@"cars"] : @[spec];
        _scroll = [[UIScrollView alloc] init];
        _scroll.pagingEnabled = YES;
        _scroll.showsHorizontalScrollIndicator = NO;
        _scroll.delegate = self;
        [self addSubview:_scroll];
        _pages = [NSMutableArray array];
        for (id c in cars) {
            if (!Dict3(c)) continue;
            NSMutableDictionary *ps = [c mutableCopy];
            ps[@"title"] = @""; ps[@"embedded"] = @YES; ps[@"type"] = @"tesla_page";
            HATeslaCard *page = [[HATeslaCard alloc] initWithSpec:ps host:host];
            [_scroll addSubview:page];
            [_pages addObject:page];
        }
        _dots = [[UIPageControl alloc] init];
        _dots.numberOfPages = _pages.count;
        _dots.hidesForSinglePage = YES;
        _dots.currentPageIndicatorTintColor = HA_TEXT();
        _dots.pageIndicatorTintColor = HA_OFF();
        [_dots addTarget:self action:@selector(dotsTapped) forControlEvents:UIControlEventValueChanged];
        [self addSubview:_dots];
    }
    return self;
}

- (NSArray *)entityIds {
    NSMutableOrderedSet *s = [NSMutableOrderedSet orderedSet];
    for (HACard *p in self.pages) [s addObjectsFromArray:[p entityIds]];
    return [s array];
}
- (void)updateStates:(NSDictionary *)states { for (HACard *p in self.pages) [p updateStates:states]; }
- (void)tick { for (HACard *p in self.pages) [p tick]; }
- (void)reload { for (HACard *p in self.pages) [p reload]; }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect c = [self contentRect];
    CGFloat dotsH = self.pages.count > 1 ? 24 : 0;
    // pages fill the card below the title (the page itself has no title and no background)
    self.scroll.frame = CGRectMake(0, c.origin.y - 16, self.bounds.size.width, c.size.height + 16 - dotsH);
    CGFloat w = self.scroll.bounds.size.width, h = self.scroll.bounds.size.height;
    for (NSUInteger i = 0; i < self.pages.count; i++) ((UIView *)self.pages[i]).frame = CGRectMake(i * w, 0, w, h);
    NSInteger page = self.dots.currentPage;
    self.scroll.contentSize = CGSizeMake(w * self.pages.count, h);
    self.scroll.contentOffset = CGPointMake(page * w, 0);
    self.dots.frame = CGRectMake(0, self.bounds.size.height - dotsH - 8, self.bounds.size.width, dotsH);
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)sv {
    self.dots.currentPage = (NSInteger)lround(sv.contentOffset.x / MAX(1, sv.bounds.size.width));
}

- (void)dotsTapped {
    [self.scroll setContentOffset:CGPointMake(self.dots.currentPage * self.scroll.bounds.size.width, 0) animated:YES];
}

@end

#pragma mark - Updates: every available update in Home Assistant, with Update / Skip
// { "type":"updates" }   (pair the drawer with "badge": "updates" for a count on the rail icon)

@interface HAUpdatesCard : HACard
@property (nonatomic, strong) NSArray *items;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UILabel *empty;
@property (nonatomic, strong) NSDate *lastLoad;
@property (nonatomic, assign) BOOL loading;
@end

@implementation HAUpdatesCard

+ (NSString *)templateString {
    return @"{%- set ns = namespace(o=[]) -%}"
           @"{%- for s in states.update if s.state == 'on' or s.attributes.in_progress -%}"
           @"{%- set ns.o = ns.o + [{'e': s.entity_id, 'n': s.attributes.title or s.name, 'iv': s.attributes.installed_version, "
           @"'lv': s.attributes.latest_version, 'p': s.attributes.in_progress, 'pct': s.attributes.update_percentage, "
           @"'core': s.entity_id in ['update.home_assistant_core_update', 'update.home_assistant_operating_system_update']}] -%}"
           @"{%- endfor -%}{{ ns.o | tojson }}";
}

- (instancetype)initWithSpec:(NSDictionary *)spec host:(id<HACardHost>)host {
    if ((self = [super initWithSpec:spec host:host])) {
        if (!Str(spec[@"title"])) self.titleLabel.text = @"UPDATES";
        _scroll = [[UIScrollView alloc] init];
        [self addSubview:_scroll];
        _empty = L3(self, 20, 0, HA_DIM());
        _empty.textAlignment = NSTextAlignmentCenter;
        _empty.text = @"Checking…";
    }
    return self;
}

- (void)reload { self.lastLoad = nil; [self tick]; }

- (void)tick {
    if (!self.active || self.loading) return;
    BOOL busy = NO;
    for (NSDictionary *it in self.items) if ([it[@"p"] boolValue]) busy = YES;
    if (self.lastLoad && [[NSDate date] timeIntervalSinceDate:self.lastLoad] < (busy ? 5 : 60)) return;
    self.loading = YES;
    self.lastLoad = [NSDate date];
    __weak HAUpdatesCard *ws = self;
    [[HAClient shared] renderTemplate:[HAUpdatesCard templateString] completion:^(id json, NSError *e) {
        HAUpdatesCard *ss = ws;
        ss.loading = NO;
        if (![json isKindOfClass:[NSArray class]]) { ss.empty.text = [NSString stringWithFormat:@"Could not check: %@", e.localizedDescription ?: @"?"]; ss.empty.hidden = NO; return; }
        ss.items = [json sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [Str(a[@"n"]) ?: @"" localizedCaseInsensitiveCompare:Str(b[@"n"]) ?: @""]; }];
        [ss rebuild];
    }];
}

- (void)rebuild {
    for (UIView *v in self.scroll.subviews) [v removeFromSuperview];
    self.empty.hidden = self.items.count > 0;
    self.empty.text = @"✓  Everything is up to date";
    CGFloat w = self.scroll.bounds.size.width ?: 600, y = 0;
    for (NSUInteger i = 0; i < self.items.count; i++) {
        NSDictionary *it = Dict3(self.items[i]);
        UILabel *n = L3(self.scroll, 19, 0.3, HA_TEXT()); n.text = Str(it[@"n"]);
        n.frame = CGRectMake(0, y, w - 250, 26);
        UILabel *v = L3(self.scroll, 15, 0, HA_DIM());
        v.text = [NSString stringWithFormat:@"%@  →  %@", Str(it[@"iv"]) ?: @"?", Str(it[@"lv"]) ?: @"?"];
        v.frame = CGRectMake(0, y + 26, w - 250, 20);
        if ([it[@"p"] boolValue]) {
            UILabel *p = L3(self.scroll, 17, 0.3, HA_ACCENT());
            p.text = it[@"pct"] && it[@"pct"] != [NSNull null] ? [NSString stringWithFormat:@"Updating… %@%%", it[@"pct"]] : @"Updating…";
            p.textAlignment = NSTextAlignmentRight;
            p.frame = CGRectMake(w - 240, y + 8, 240, 30);
        } else {
            UIButton *u = HA_Chip(@"Update", self, @selector(updateTapped:));
            u.tag = i; u.frame = CGRectMake(w - 240, y + 4, 120, 40);
            u.backgroundColor = HA_ACCENT(); [u setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
            UIButton *s = HA_Chip(@"Skip", self, @selector(skipTapped:));
            s.tag = i; s.frame = CGRectMake(w - 110, y + 4, 110, 40);
            [self.scroll addSubview:u]; [self.scroll addSubview:s];
        }
        y += 62;
    }
    self.scroll.contentSize = CGSizeMake(w, y);
    HA_Fade(self.scroll, 0.2);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect c = [self contentRect];
    BOOL resized = fabs(self.scroll.frame.size.width - c.size.width) > 1;
    self.scroll.frame = c;
    self.empty.frame = c;
    if (resized && self.items) [self rebuild];
}

- (void)confirm:(NSString *)title message:(NSString *)msg then:(void (^)(void))run {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Update" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { run(); }]];
    [[UIApplication sharedApplication].keyWindow.rootViewController presentViewController:ac animated:YES completion:nil];
}

- (void)updateTapped:(UIButton *)b {
    NSDictionary *it = Dict3(self.items[b.tag]);
    void (^run)(void) = ^{
        [self.host card:self callService:@"update.install" data:@{@"entity_id": it[@"e"]}];
        self.lastLoad = [NSDate dateWithTimeIntervalSinceNow:-55];   // re-check in ~5 s
    };
    if ([it[@"core"] boolValue]) [self confirm:Str(it[@"n"]) message:@"Home Assistant will restart and be unavailable for a few minutes." then:run];
    else run();
}

- (void)skipTapped:(UIButton *)b {
    [self.host card:self callService:@"update.skip" data:@{@"entity_id": Dict3(self.items[b.tag])[@"e"]}];
    self.lastLoad = [NSDate dateWithTimeIntervalSinceNow:-57];
}

@end

#pragma mark - Timer (HA timer helper)
// { "type":"timer", "entity":"timer.panel", "presets":[1,3,5,10,15,30,60] }

@interface HATimerCard : HACard
@property (nonatomic, copy) NSString *entity;
@property (nonatomic, strong) NSDictionary *state;
@property (nonatomic, strong) UILabel *clock, *caption;
@property (nonatomic, strong) NSMutableArray *presetButtons;
@property (nonatomic, strong) UIButton *start, *cancel, *plus;
@property (nonatomic, assign) NSInteger chosen;   // seconds chosen while idle
@end

@implementation HATimerCard

- (instancetype)initWithSpec:(NSDictionary *)spec host:(id<HACardHost>)host {
    if ((self = [super initWithSpec:spec host:host])) {
        _entity = Str(spec[@"entity"]) ?: @"timer.panel";
        if (!Str(spec[@"title"])) self.titleLabel.text = @"TIMER";
        _clock = L3(self, 96, -0.6, HA_TEXT());
        _clock.textAlignment = NSTextAlignmentCenter;
        _clock.text = @"0:00";
        _caption = L3(self, 15, 0.4, HA_DIM());
        _caption.textAlignment = NSTextAlignmentCenter;
        _presetButtons = [NSMutableArray array];
        for (id m in (Arr3(spec[@"presets"]).count ? spec[@"presets"] : @[@1, @3, @5, @10, @15, @30, @60])) {
            NSInteger min = Int(m, 5);
            UIButton *b = HA_Chip(min >= 60 && min % 60 == 0 ? [NSString stringWithFormat:@"%ld hr", (long)(min / 60)] : [NSString stringWithFormat:@"%ld min", (long)min], self, @selector(presetTapped:));
            b.tag = min * 60;
            [self addSubview:b];
            [_presetButtons addObject:b];
        }
        _start = HA_Chip(@"Start", self, @selector(startTapped));
        _start.titleLabel.font = HA_FONT(20, 0.3);
        _cancel = HA_Chip(@"Cancel", self, @selector(cancelTapped));
        _cancel.titleLabel.font = HA_FONT(20, 0.3);
        _plus = HA_Chip(@"+1 min", self, @selector(plusTapped));
        _plus.titleLabel.font = HA_FONT(20, 0.3);
        [self addSubview:_start]; [self addSubview:_cancel]; [self addSubview:_plus];
        _chosen = 5 * 60;
    }
    return self;
}

- (NSArray *)entityIds { return @[self.entity]; }

static NSString *HMS(NSInteger s) {
    s = MAX(0, s);
    return s >= 3600 ? [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)(s / 3600), (long)(s / 60 % 60), (long)(s % 60)]
                     : [NSString stringWithFormat:@"%ld:%02ld", (long)(s / 60), (long)(s % 60)];
}

static NSInteger Seconds(NSString *hms) {   // "0:05:00" -> 300
    NSArray *p = [hms componentsSeparatedByString:@":"];
    NSInteger t = 0;
    for (NSString *x in p) t = t * 60 + [x integerValue];
    return t;
}

- (NSString *)status { return Str(self.state[@"state"]) ?: @"idle"; }

- (NSInteger)remaining {
    NSDictionary *a = self.state[@"attributes"];
    if ([[self status] isEqualToString:@"active"]) {
        NSDate *end = HA_ParseISO(Str(a[@"finishes_at"]));
        return end ? (NSInteger)ceil([end timeIntervalSinceNow]) : Seconds(Str(a[@"remaining"]));
    }
    if ([[self status] isEqualToString:@"paused"]) return Seconds(Str(a[@"remaining"]));
    return self.chosen;
}

- (void)updateStates:(NSDictionary *)states {
    if (states[self.entity]) self.state = states[self.entity];
    [self paint];
}

- (void)tick { [self paint]; }

- (void)paint {
    NSString *st = [self status];
    BOOL active = [st isEqualToString:@"active"], paused = [st isEqualToString:@"paused"];
    NSString *t = HMS([self remaining]);
    if (![t isEqualToString:self.clock.text]) self.clock.text = t;
    self.clock.textColor = active ? HA_ACCENT() : HA_TEXT();
    self.caption.text = active ? @"RUNNING" : (paused ? @"PAUSED" : @"CHOOSE A TIME, THEN START");
    [self.start setTitle:active ? @"Pause" : (paused ? @"Resume" : @"Start") forState:UIControlStateNormal];
    HA_SetBG(self.start, active ? HA_OFF() : HA_ACCENT());
    [self.start setTitleColor:active ? HA_TEXT() : [UIColor blackColor] forState:UIControlStateNormal];
    self.cancel.enabled = self.plus.enabled = active || paused;
    self.cancel.alpha = self.plus.alpha = (active || paused) ? 1 : 0.35;
    for (UIButton *b in self.presetButtons) {
        BOOL sel = !active && !paused && b.tag == self.chosen;
        HA_SetBG(b, sel ? HA_ACCENT() : HA_OFF());
        [b setTitleColor:sel ? [UIColor blackColor] : HA_TEXT() forState:UIControlStateNormal];
    }
}

// Fits whatever tile it is given: the buttons shrink first, then preset rows are dropped, and the
// clock takes the room that is left. A wide, short tile puts the clock beside the buttons.
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect c = [self contentRect];
    BOOL wide = c.size.width > 520 && c.size.height < 320;
    CGFloat g = 8, clockW = wide ? c.size.width * 0.36 : c.size.width;
    CGRect ctl = wide ? CGRectMake(c.origin.x + clockW + 16, c.origin.y, c.size.width - clockW - 16, c.size.height) : c;
    NSInteger n = self.presetButtons.count, cols = MIN(n, ctl.size.width > 520 ? (NSInteger)7 : (NSInteger)4);
    NSInteger rows = cols ? (n + cols - 1) / cols : 0;
    CGFloat ah = MAX(34, MIN(56, c.size.height * 0.17)), ph = MAX(30, MIN(44, c.size.height * 0.13));
    CGFloat room = wide ? c.size.height : c.size.height - 54;   // keep at least 54 pt for the clock
    while (rows > 0 && rows * (ph + g) + ah > room) rows--;
    CGFloat ctlH = rows * (ph + g) + ah;
    CGRect clockR = wide ? CGRectMake(c.origin.x, c.origin.y, clockW, c.size.height)
                         : CGRectMake(c.origin.x, c.origin.y, c.size.width, MAX(30, c.size.height - ctlH - 8));
    CGFloat cy = wide ? c.origin.y + (c.size.height - ctlH) / 2 : CGRectGetMaxY(c) - ctlH;

    BOOL showCaption = clockR.size.height > 96;
    CGFloat capH = showCaption ? 20 : 0;
    CGFloat fs = MAX(22, MIN(96, MIN((clockR.size.height - capH) * 0.82, clockR.size.width / 2.4)));
    self.clock.font = HA_FONT(fs, -0.6);
    CGFloat ch = fs * 1.12, top = clockR.origin.y + MAX(0, (clockR.size.height - ch - capH) / 2);
    self.clock.frame = CGRectMake(clockR.origin.x, top, clockR.size.width, ch);
    self.caption.hidden = !showCaption;
    self.caption.frame = CGRectMake(clockR.origin.x, top + ch, clockR.size.width, 18);

    CGFloat bw = cols ? (ctl.size.width - (cols - 1) * g) / cols : 0;
    for (NSInteger i = 0; i < n; i++) {
        UIView *b = self.presetButtons[i];
        b.hidden = i >= rows * cols;
        b.frame = CGRectMake(ctl.origin.x + (i % cols) * (bw + g), cy + (i / cols) * (ph + g), bw, ph);
    }
    CGFloat y = cy + rows * (ph + g), w3 = (ctl.size.width - 2 * g) / 3;
    NSArray *acts = @[self.start, self.plus, self.cancel];
    for (NSUInteger i = 0; i < 3; i++) {
        UIButton *b = acts[i];
        b.frame = CGRectMake(ctl.origin.x + i * (w3 + g), y, w3, ah);
        b.titleLabel.font = HA_FONT(MIN(20, ah * 0.4), 0.3);
    }
}

- (void)presetTapped:(UIButton *)b {
    NSString *st = [self status];
    if ([st isEqualToString:@"active"] || [st isEqualToString:@"paused"]) {
        // tapping a preset while running restarts with that time
        [self.host card:self callService:@"timer.start" data:@{@"entity_id": self.entity, @"duration": HMS(b.tag)}];
    }
    self.chosen = b.tag;
    HA_Push(self.clock, YES);
    [self paint];
}

- (void)startTapped {
    NSString *st = [self status];
    if ([st isEqualToString:@"active"]) [self.host card:self callService:@"timer.pause" data:@{@"entity_id": self.entity}];
    else if ([st isEqualToString:@"paused"]) [self.host card:self callService:@"timer.start" data:@{@"entity_id": self.entity}];
    else [self.host card:self callService:@"timer.start" data:@{@"entity_id": self.entity, @"duration": [NSString stringWithFormat:@"%02ld:%02ld:%02ld", (long)(self.chosen / 3600), (long)(self.chosen / 60 % 60), (long)(self.chosen % 60)]}];
}

- (void)cancelTapped { [self.host card:self callService:@"timer.cancel" data:@{@"entity_id": self.entity}]; }
- (void)plusTapped { [self.host card:self callService:@"timer.change" data:@{@"entity_id": self.entity, @"duration": @"00:01:00"}]; }

@end

#pragma mark - Cameras: a strip of live snapshots, tap for full screen
// { "type":"cameras", "interval":6, "cameras":[ {"name":"Front Yard",
//     "url":"http://192.168.1.50:1984/api/frame.jpeg?src=front_yard_cam&width=480"} ] }
// Snapshots come straight from the Wyze bridge's go2rtc (resized there, ~30 KB each). One camera is
// fetched at a time in rotation, and nothing is fetched while the screen is idle or the card hidden.

@interface HACamerasCard : HACard
@property (nonatomic, strong) NSArray *cams;
@property (nonatomic, strong) NSMutableArray *views;   // UIButton tiles with UIImageView (tag 1) + name (tag 2)
@property (nonatomic, strong) NSMutableArray *busyFlags, *lastFetches, *failures;   // per camera
@property (nonatomic, strong) UIView *viewer;
@property (nonatomic, assign) NSInteger viewerIndex;
@property (nonatomic, strong) NSDate *viewerOpened;
@property (nonatomic, assign) BOOL viewerBusy;
@end

@implementation HACamerasCard

- (instancetype)initWithSpec:(NSDictionary *)spec host:(id<HACardHost>)host {
    if ((self = [super initWithSpec:spec host:host])) {
        if (!Str(spec[@"title"])) self.titleLabel.text = @"";
        NSMutableArray *cams = [NSMutableArray array];
        for (id c in Arr3(spec[@"cameras"])) if (Str(Dict3(c)[@"url"])) [cams addObject:c];
        _cams = cams;
        _views = [NSMutableArray array];
        for (NSUInteger i = 0; i < cams.count; i++) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            b.tag = i; b.backgroundColor = [UIColor blackColor]; b.layer.cornerRadius = 12; b.clipsToBounds = YES;
            [b addTarget:self action:@selector(camTapped:) forControlEvents:UIControlEventTouchUpInside];
            HA_AddPress(b);
            UIImageView *iv = [[UIImageView alloc] init];
            iv.contentMode = UIViewContentModeScaleAspectFill; iv.tag = 9001; iv.userInteractionEnabled = NO;
            UILabel *n = L3(b, 14, 0.4, [UIColor whiteColor]);
            n.text = Str(cams[i][@"name"]) ?: @"Camera"; n.tag = 9002;
            n.shadowColor = [UIColor colorWithWhite:0 alpha:0.8]; n.shadowOffset = CGSizeMake(0, 1);
            [b insertSubview:iv atIndex:0];
            [self addSubview:b];
            [_views addObject:b];
        }
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect c = [self contentRect];
    if (!self.titleLabel.text.length) c = CGRectInset(self.bounds, 14, 14);
    NSUInteger n = MAX((NSUInteger)1, self.views.count);
    CGFloat gap = 12, w = (c.size.width - (n - 1) * gap) / n, h = c.size.height;
    for (NSUInteger i = 0; i < self.views.count; i++) {
        UIButton *b = self.views[i];
        b.bounds = CGRectMake(0, 0, w, h);
        b.center = CGPointMake(c.origin.x + i * (w + gap) + w / 2, c.origin.y + h / 2);
        [b viewWithTag:9001].frame = b.bounds;
        [b viewWithTag:9002].frame = CGRectMake(10, h - 26, w - 20, 20);
    }
}

- (BOOL)awake { return ![self.host respondsToSelector:@selector(screenAwake)] || [self.host screenAwake]; }

- (void)reload { self.busyFlags = nil; }

// Each camera refreshes on its own schedule (at most two downloads at once), so one camera that is
// slow or offline never holds up the others. A camera that fails twice in a row is marked "No signal".
- (void)tick {
    [self viewerTick];
    if (!self.cams.count || !self.window || !self.active || ![self awake]) return;
    if (!self.busyFlags) {
        self.busyFlags = [NSMutableArray array]; self.lastFetches = [NSMutableArray array]; self.failures = [NSMutableArray array];
        for (NSUInteger i = 0; i < self.cams.count; i++) { [self.busyFlags addObject:@NO]; [self.lastFetches addObject:[NSDate distantPast]]; [self.failures addObject:@0]; }
    }
    double interval = MAX(2.0, [self.spec[@"interval"] respondsToSelector:@selector(doubleValue)] ? [self.spec[@"interval"] doubleValue] : 6);
    NSUInteger running = 0;
    for (NSNumber *b in self.busyFlags) if (b.boolValue) running++;
    if (running >= 2) return;
    // start the camera that has waited longest
    NSInteger pick = -1; NSDate *oldest = nil;
    for (NSUInteger i = 0; i < self.cams.count; i++) {
        if ([self.busyFlags[i] boolValue]) continue;
        NSDate *last = self.lastFetches[i];
        double wait = [self.failures[i] integerValue] >= 2 ? MAX(interval, 30) : interval;   // back off on dead cameras
        if ([[NSDate date] timeIntervalSinceDate:last] < wait) continue;
        if (!oldest || [last compare:oldest] == NSOrderedAscending) { oldest = last; pick = i; }
    }
    if (pick < 0) return;
    NSUInteger i = pick;
    self.busyFlags[i] = @YES;
    self.lastFetches[i] = [NSDate date];
    __weak HACamerasCard *ws = self;
    [[HAClient shared] fetchImageURL:Str(self.cams[i][@"url"]) auth:NO maxSide:640 completion:^(UIImage *img) {
        HACamerasCard *ss = ws;
        if (!ss || i >= ss.views.count) return;
        ss.busyFlags[i] = @NO;
        UIImageView *iv = (UIImageView *)[ss.views[i] viewWithTag:9001];
        UILabel *name = (UILabel *)[ss.views[i] viewWithTag:9002];
        NSString *base = Str(ss.cams[i][@"name"]) ?: @"Camera";
        if (img) {
            ss.failures[i] = @0;
            iv.image = img; iv.alpha = 1;   // no fade: a fresh frame every few seconds should just update
            name.text = base;
        } else {
            ss.failures[i] = @([ss.failures[i] integerValue] + 1);
            if ([ss.failures[i] integerValue] >= 2) { iv.alpha = 0.3; name.text = [base stringByAppendingString:@" · no signal"]; }
        }
    }];
}

#pragma mark full-screen viewer

- (NSString *)fullURL:(NSUInteger)i {
    NSString *u = Str(self.cams[i][@"full_url"]) ?: Str(self.cams[i][@"url"]);
    return [u stringByReplacingOccurrencesOfString:@"width=480" withString:@"width=1024"];
}

- (void)camTapped:(UIButton *)b {
    UIWindow *win = self.window;
    if (!win) return;
    UIControl *v = [[UIControl alloc] initWithFrame:win.rootViewController.view.bounds];
    v.backgroundColor = [UIColor blackColor];
    [v addTarget:self action:@selector(closeViewer) forControlEvents:UIControlEventTouchUpInside];
    UIImageView *iv = [[UIImageView alloc] initWithFrame:v.bounds];
    iv.contentMode = UIViewContentModeScaleAspectFit; iv.tag = 9001; iv.userInteractionEnabled = NO;
    iv.image = ((UIImageView *)[b viewWithTag:9001]).image;
    [v addSubview:iv];
    UILabel *n = L3(v, 26, 0.4, [UIColor whiteColor]);
    n.text = [NSString stringWithFormat:@"%@   \u00B7   tap to close", Str(self.cams[b.tag][@"name"]) ?: @"Camera"];
    n.shadowColor = [UIColor colorWithWhite:0 alpha:0.8]; n.shadowOffset = CGSizeMake(0, 1);
    n.frame = CGRectMake(24, v.bounds.size.height - 52, v.bounds.size.width - 48, 34);
    [win.rootViewController.view addSubview:v];
    // zoom out of the tapped tile
    CGRect from = [b convertRect:b.bounds toView:v];
    v.alpha = 0;
    iv.frame = from;
    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0.3 options:0 animations:^{
        v.alpha = 1; iv.frame = v.bounds;
    } completion:nil];
    self.viewer = v;
    self.viewerIndex = b.tag;
    self.viewerOpened = [NSDate date];
    self.viewerBusy = NO;   // a download still running for the previous camera no longer counts
    [self viewerTick];      // start this camera's first full-size frame now, not at the next second
}

- (void)viewerTick {
    if (!self.viewer) return;
    if ([[NSDate date] timeIntervalSinceDate:self.viewerOpened] > 120) { [self closeViewer]; return; }
    if (self.viewerBusy) return;
    self.viewerBusy = YES;
    __weak HACamerasCard *ws = self;
    __weak UIView *target = self.viewer;
    NSUInteger i = self.viewerIndex;
    [[HAClient shared] fetchImageURL:[self fullURL:i] auth:NO maxSide:1024 completion:^(UIImage *img) {
        HACamerasCard *ss = ws;
        // A frame that arrives after the viewer was closed or switched to another camera is dropped:
        // it used to land in the new viewer and show the previous camera for a second or two.
        if (!ss || !target || ss.viewer != target) return;
        ss.viewerBusy = NO;
        if (img) ((UIImageView *)[target viewWithTag:9001]).image = img;
    }];
}

- (void)closeViewer {
    UIView *v = self.viewer;
    self.viewer = nil;
    [UIView animateWithDuration:0.2 animations:^{ v.alpha = 0; } completion:^(BOOL f) { [v removeFromSuperview]; }];
}

@end

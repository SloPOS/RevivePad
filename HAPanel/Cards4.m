// Fourth batch of cards: freeze_dryer, network, batteries, detections. Registered by name in Cards.m.
// All three size themselves to the tile they are given.
#import "Cards.h"
#import "HAClient.h"
#import <QuartzCore/QuartzCore.h>

#define Str HA_Str
#define Int HA_Int

static NSArray *Arr4(id v) { return [v isKindOfClass:[NSArray class]] ? v : @[]; }
static NSDictionary *Dict4(id v) { return [v isKindOfClass:[NSDictionary class]] ? v : nil; }
static BOOL IsNum(id v) { return [v isKindOfClass:[NSNumber class]] || ([v isKindOfClass:[NSString class]] && [(NSString *)v length] && [[NSScanner scannerWithString:v] scanDouble:NULL]); }
static BOOL Dead(NSDictionary *s) { NSString *st = Str(s[@"state"]); return !s || !st || [st isEqualToString:@"unavailable"] || [st isEqualToString:@"unknown"]; }

static UILabel *L4(UIView *parent, CGFloat size, CGFloat weight, UIColor *color) {
    UILabel *l = [[UILabel alloc] init];
    l.font = HA_FONT(size, weight); l.textColor = color;
    l.adjustsFontSizeToFitWidth = YES; l.minimumScaleFactor = 0.5;
    [parent addSubview:l];
    return l;
}

static UIColor *Green4(void) { return [UIColor colorWithRed:0.30 green:0.80 blue:0.40 alpha:1]; }
static UIColor *Red4(void) { return [UIColor colorWithRed:1.0 green:0.35 blue:0.30 alpha:1]; }
static UIColor *Amber4(void) { return [UIColor colorWithRed:1.0 green:0.70 blue:0.25 alpha:1]; }

static NSString *Duration4(double seconds) {   // 11520 -> "3h 12m"
    NSInteger s = MAX(0, (NSInteger)seconds);
    if (s >= 3600) return [NSString stringWithFormat:@"%ldh %02ldm", (long)(s / 3600), (long)(s / 60 % 60)];
    return [NSString stringWithFormat:@"%ldm", (long)(s / 60)];
}

// A thin horizontal bar: track, fill, colour by level.
static UIView *Bar4(UIView *parent, CGRect f, double frac, UIColor *color) {
    UIView *track = [[UIView alloc] initWithFrame:f];
    track.backgroundColor = HA_OFF();
    track.layer.cornerRadius = f.size.height / 2;
    track.clipsToBounds = YES;
    UIView *fill = [[UIView alloc] initWithFrame:CGRectMake(0, 0, f.size.width * MAX(0, MIN(1, frac)), f.size.height)];
    fill.backgroundColor = color;
    [track addSubview:fill];
    [parent addSubview:track];
    return track;
}

#pragma mark - Freeze dryer (HarvestRight through an ESP32 / MQTT adapter)
// { "type":"freeze_dryer", "prefix":"harvestright_freeze_dryer" }
// Reads sensor.<prefix>_mode, _temperature, _batch_elapsed, _prep_remaining and text.<prefix>_batch_name.

@interface HAFreezeDryerCard : HACard
@property (nonatomic, copy) NSString *p;
@property (nonatomic, strong) UILabel *mode, *batch;
@property (nonatomic, strong) NSArray *facts;   // @[caption, value] pairs: temperature, elapsed, prep left
@end

@implementation HAFreezeDryerCard

- (instancetype)initWithSpec:(NSDictionary *)spec host:(id<HACardHost>)host {
    if ((self = [super initWithSpec:spec host:host])) {
        _p = Str(spec[@"prefix"]) ?: @"harvestright_freeze_dryer";
        if (!Str(spec[@"title"])) self.titleLabel.text = @"FREEZE DRYER";
        _mode = L4(self, 34, 0.2, HA_TEXT());
        _batch = L4(self, 16, 0, HA_DIM());
        NSMutableArray *f = [NSMutableArray array];
        for (NSString *cap in @[@"TEMPERATURE", @"ELAPSED", @"PREP LEFT"]) {
            UILabel *c = L4(self, 12, 0.4, HA_DIM()); c.text = cap;
            UILabel *v = L4(self, 24, 0.2, HA_TEXT()); v.text = @"--";
            [f addObject:@[c, v]];
        }
        _facts = f;
        _mode.text = @"Waiting for data";
    }
    return self;
}

- (NSString *)eid:(NSString *)domain name:(NSString *)n { return [NSString stringWithFormat:@"%@.%@_%@", domain, self.p, n]; }

- (NSArray *)entityIds {
    return @[[self eid:@"sensor" name:@"mode"], [self eid:@"sensor" name:@"temperature"], [self eid:@"sensor" name:@"batch_elapsed"],
             [self eid:@"sensor" name:@"prep_remaining"], [self eid:@"text" name:@"batch_name"]];
}

- (void)updateStates:(NSDictionary *)states {
    NSDictionary *mode = states[[self eid:@"sensor" name:@"mode"]], *temp = states[[self eid:@"sensor" name:@"temperature"]];
    NSDictionary *el = states[[self eid:@"sensor" name:@"batch_elapsed"]], *prep = states[[self eid:@"sensor" name:@"prep_remaining"]];
    NSDictionary *name = states[[self eid:@"text" name:@"batch_name"]];
    BOOL off = Dead(mode) && Dead(temp);
    NSString *m = Dead(mode) ? (off ? @"Off" : @"Running") : [Str(mode[@"state"]) stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    self.mode.text = m.length ? [[[m substringToIndex:1] uppercaseString] stringByAppendingString:[m substringFromIndex:1]] : @"Off";
    self.mode.textColor = off ? HA_DIM() : HA_ACCENT();
    self.batch.text = off ? @"Not running" : (Dead(name) || !Str(name[@"state"]).length ? @"" : [NSString stringWithFormat:@"Batch: %@", name[@"state"]]);
    NSString *unit = Str(temp[@"attributes"][@"unit_of_measurement"]) ?: @"°";
    ((UILabel *)self.facts[0][1]).text = Dead(temp) || !IsNum(temp[@"state"]) ? @"--" : [NSString stringWithFormat:@"%.0f%@", [temp[@"state"] doubleValue], unit];
    ((UILabel *)self.facts[1][1]).text = Dead(el) || !IsNum(el[@"state"]) ? @"--" : Duration4([el[@"state"] doubleValue]);
    ((UILabel *)self.facts[2][1]).text = Dead(prep) || !IsNum(prep[@"state"]) || [prep[@"state"] doubleValue] <= 0 ? @"--" : Duration4([prep[@"state"] doubleValue]);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect c = [self contentRect];
    BOOL stack = c.size.width < 300;                      // narrow tile: facts one under another
    NSInteger shown = c.size.height < 150 ? (stack ? 1 : 3) : 3;
    CGFloat factsH = stack ? shown * 30 : 50;
    BOOL showBatch = c.size.height - factsH > 70;
    CGFloat headH = c.size.height - factsH - 8;
    CGFloat fs = MAX(20, MIN(44, headH * (showBatch ? 0.42 : 0.7)));
    self.mode.font = HA_FONT(fs, 0.2);
    CGFloat blockH = fs * 1.2 + (showBatch ? 22 : 0), y = c.origin.y + MAX(0, (headH - blockH) / 2);
    self.mode.frame = CGRectMake(c.origin.x, y, c.size.width, fs * 1.2);
    self.batch.hidden = !showBatch;
    self.batch.frame = CGRectMake(c.origin.x, y + fs * 1.2, c.size.width, 20);
    CGFloat fy = CGRectGetMaxY(c) - factsH, fw = c.size.width / 3;
    for (NSUInteger i = 0; i < self.facts.count; i++) {
        UILabel *cap = self.facts[i][0], *val = self.facts[i][1];
        cap.hidden = val.hidden = (NSInteger)i >= shown;
        if (stack) {
            cap.frame = CGRectMake(c.origin.x, fy + i * 30, c.size.width * 0.55, 28);
            val.frame = CGRectMake(c.origin.x + c.size.width * 0.55, fy + i * 30, c.size.width * 0.45, 28);
            val.textAlignment = NSTextAlignmentRight; val.font = HA_FONT(19, 0.2);
        } else {
            cap.frame = CGRectMake(c.origin.x + i * fw, fy, fw - 8, 16);
            val.frame = CGRectMake(c.origin.x + i * fw, fy + 18, fw - 8, 30);
            val.textAlignment = NSTextAlignmentLeft; val.font = HA_FONT(24, 0.2);
        }
    }
}

@end

#pragma mark - Network
// { "type":"network", "wan":"binary_sensor.router_wan_status", "down":"sensor.router_download_speed",
//   "up":"sensor.router_upload_speed", "ip":"sensor.router_external_ip",
//   "sensors":[ { "entity":"sensor.adguard_dns_queries_blocked", "name":"Blocked today" } ] }
// Without wan/down/up/ip the card looks for a UPnP router's entities (names ending in _wan_status,
// _download_speed, _upload_speed, _external_ip).

@interface HANetworkCard : HACard
@property (nonatomic, strong) NSMutableDictionary *ids;   // wan, down, up, ip
@property (nonatomic, strong) NSArray *extra;
@property (nonatomic, strong) UIView *dot;
@property (nonatomic, strong) UILabel *status, *down, *up, *ip, *downCap, *upCap;
@property (nonatomic, strong) NSMutableArray *extraLabels;   // @[name, value]
@property (nonatomic, strong) NSDate *lastFind;
@end

@implementation HANetworkCard

- (instancetype)initWithSpec:(NSDictionary *)spec host:(id<HACardHost>)host {
    if ((self = [super initWithSpec:spec host:host])) {
        if (!Str(spec[@"title"])) self.titleLabel.text = @"INTERNET";
        _ids = [NSMutableDictionary dictionary];
        for (NSString *k in @[@"wan", @"down", @"up", @"ip"]) if (Str(spec[k])) _ids[k] = spec[k];
        _extra = Arr4(spec[@"sensors"]);
        _dot = [[UIView alloc] init];
        [self addSubview:_dot];
        _status = L4(self, 30, 0.2, HA_TEXT()); _status.text = @"--";
        _downCap = L4(self, 12, 0.4, HA_DIM()); _downCap.text = @"↓ DOWN";
        _upCap = L4(self, 12, 0.4, HA_DIM()); _upCap.text = @"↑ UP";
        _down = L4(self, 24, 0.2, HA_TEXT()); _down.text = @"--";
        _up = L4(self, 24, 0.2, HA_TEXT()); _up.text = @"--";
        _ip = L4(self, 14, 0, HA_DIM());
        _extraLabels = [NSMutableArray array];
        for (id e in _extra) {
            UILabel *n = L4(self, 14, 0, HA_DIM()); n.text = Str(Dict4(e)[@"name"]) ?: @"";
            UILabel *v = L4(self, 15, 0.3, HA_TEXT()); v.textAlignment = NSTextAlignmentRight; v.text = @"--";
            [_extraLabels addObject:@[n, v]];
        }
    }
    return self;
}

- (NSArray *)entityIds {
    NSMutableArray *a = [NSMutableArray arrayWithArray:self.ids.allValues];
    for (id e in self.extra) if (Str(Dict4(e)[@"entity"])) [a addObject:Dict4(e)[@"entity"]];
    return a;
}

- (void)reload { self.lastFind = nil; [self tick]; }

- (void)tick {
    if (self.ids.count || !self.active) return;
    if (self.lastFind && [[NSDate date] timeIntervalSinceDate:self.lastFind] < 300) return;
    self.lastFind = [NSDate date];
    NSString *tpl = @"{%- set ns = namespace(o={}) -%}"
                    @"{%- for s in states if s.entity_id.endswith('_wan_status') -%}{%- set ns.o = dict(ns.o, wan=s.entity_id) -%}{%- endfor -%}"
                    @"{%- for s in states.sensor -%}"
                    @"{%- if s.entity_id.endswith('_download_speed') -%}{%- set ns.o = dict(ns.o, down=s.entity_id) -%}{%- endif -%}"
                    @"{%- if s.entity_id.endswith('_upload_speed') -%}{%- set ns.o = dict(ns.o, up=s.entity_id) -%}{%- endif -%}"
                    @"{%- if s.entity_id.endswith('_external_ip') -%}{%- set ns.o = dict(ns.o, ip=s.entity_id) -%}{%- endif -%}"
                    @"{%- endfor -%}{{ ns.o | tojson }}";
    __weak HANetworkCard *ws = self;
    [[HAClient shared] renderTemplate:tpl completion:^(id json, NSError *e) {
        HANetworkCard *ss = ws;
        if (![json isKindOfClass:[NSDictionary class]]) return;
        [ss.ids addEntriesFromDictionary:json];
        if (!ss.ids.count) ss.status.text = @"No router data";
        [ss.host cardWantsRefresh:ss];
    }];
}

// Speeds as megabits per second, whatever unit the sensor reports.
static NSString *Mbps(NSDictionary *s) {
    if (Dead(s) || !IsNum(s[@"state"])) return @"--";
    double v = [s[@"state"] doubleValue];
    NSString *u = Str(s[@"attributes"][@"unit_of_measurement"]) ?: @"";
    double m;
    if ([u isEqualToString:@"KiB/s"]) m = v * 8 * 1024 / 1e6;
    else if ([u isEqualToString:@"kB/s"]) m = v * 8 / 1000;
    else if ([u isEqualToString:@"MiB/s"]) m = v * 8 * 1048576 / 1e6;
    else if ([u isEqualToString:@"MB/s"]) m = v * 8;
    else if ([u isEqualToString:@"B/s"]) m = v * 8 / 1e6;
    else if ([u isEqualToString:@"kbit/s"]) m = v / 1000;
    else if ([u isEqualToString:@"Mbit/s"]) m = v;
    else return [NSString stringWithFormat:@"%.4g %@", v, u];
    return [NSString stringWithFormat:m >= 100 ? @"%.0f Mb/s" : (m >= 10 ? @"%.1f Mb/s" : @"%.2f Mb/s"), m];
}

- (void)updateStates:(NSDictionary *)states {
    NSDictionary *wan = self.ids[@"wan"] ? states[self.ids[@"wan"]] : nil;
    NSString *st = Str(wan[@"state"]);
    BOOL known = wan && !Dead(wan), up = [st isEqualToString:@"on"] || [st isEqualToString:@"connected"] || [st isEqualToString:@"home"];
    if (self.ids[@"wan"]) {
        self.status.text = known ? (up ? @"Online" : @"Offline") : @"Unknown";
        HA_SetBG(self.dot, known ? (up ? Green4() : Red4()) : HA_DIM());
    } else if (self.ids.count) { self.status.text = @"Internet"; HA_SetBG(self.dot, HA_DIM()); }
    self.down.text = self.ids[@"down"] ? Mbps(states[self.ids[@"down"]]) : @"--";
    self.up.text = self.ids[@"up"] ? Mbps(states[self.ids[@"up"]]) : @"--";
    NSDictionary *ip = self.ids[@"ip"] ? states[self.ids[@"ip"]] : nil;
    self.ip.text = Dead(ip) ? @"" : [NSString stringWithFormat:@"Public address %@", ip[@"state"]];
    for (NSUInteger i = 0; i < self.extra.count && i < self.extraLabels.count; i++) {
        NSDictionary *s = states[Str(Dict4(self.extra[i])[@"entity"]) ?: @""];
        NSString *u = Str(s[@"attributes"][@"unit_of_measurement"]);
        ((UILabel *)self.extraLabels[i][1]).text = Dead(s) ? @"--" : (u ? [NSString stringWithFormat:@"%@ %@", s[@"state"], u] : Str(s[@"state"]));
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect c = [self contentRect];
    CGFloat H = c.size.height;
    NSInteger nx = self.extraLabels.count;
    BOOL showIP = H >= 150;
    NSInteger shownExtra = MAX(0, MIN(nx, (NSInteger)((H - 130 - (showIP ? 20 : 0)) / 26)));
    CGFloat tailH = (showIP ? 20 : 0) + shownExtra * 26;
    CGFloat body = H - tailH;
    CGFloat fs = MAX(20, MIN(36, body * 0.3)), vs = MAX(17, MIN(26, body * 0.22));
    self.status.font = HA_FONT(fs, 0.2);
    self.down.font = self.up.font = HA_FONT(vs, 0.2);
    CGFloat blockH = fs * 1.25 + 8 + 14 + vs * 1.25, y = c.origin.y + MAX(0, (body - blockH) / 2);
    self.dot.frame = CGRectMake(c.origin.x, y + fs * 0.625 - 7, 14, 14);
    self.dot.layer.cornerRadius = 7;
    self.status.frame = CGRectMake(c.origin.x + 24, y, c.size.width - 24, fs * 1.25);
    y += fs * 1.25 + 8;
    CGFloat half = c.size.width / 2;
    self.downCap.frame = CGRectMake(c.origin.x, y, half - 6, 14);
    self.upCap.frame = CGRectMake(c.origin.x + half, y, half - 6, 14);
    self.down.frame = CGRectMake(c.origin.x, y + 14, half - 6, vs * 1.25);
    self.up.frame = CGRectMake(c.origin.x + half, y + 14, half - 6, vs * 1.25);
    CGFloat ty = CGRectGetMaxY(c) - tailH;
    self.ip.hidden = !showIP;
    self.ip.frame = CGRectMake(c.origin.x, ty, c.size.width, 18);
    if (showIP) ty += 20;
    for (NSInteger i = 0; i < nx; i++) {
        UILabel *n = self.extraLabels[i][0], *v = self.extraLabels[i][1];
        n.hidden = v.hidden = i >= shownExtra;
        n.frame = CGRectMake(c.origin.x, ty + i * 26, c.size.width * 0.6, 24);
        v.frame = CGRectMake(c.origin.x + c.size.width * 0.6, ty + i * 26, c.size.width * 0.4, 24);
    }
}

@end

#pragma mark - Batteries
// { "type":"batteries", "low":20, "only_low":false, "exclude":["sensor.tesla*", "sensor.*_battery_level"] }
// Every battery-level sensor in Home Assistant, lowest first; anything at or under "low" is red.

@interface HABatteriesCard : HACard
@property (nonatomic, strong) NSArray *items;
@property (nonatomic, strong) UIView *rowsView;
@property (nonatomic, strong) UILabel *empty;
@property (nonatomic, strong) NSDate *lastLoad;
@property (nonatomic, assign) BOOL loading;
@end

@implementation HABatteriesCard

- (instancetype)initWithSpec:(NSDictionary *)spec host:(id<HACardHost>)host {
    if ((self = [super initWithSpec:spec host:host])) {
        if (!Str(spec[@"title"])) self.titleLabel.text = @"BATTERIES";
        _rowsView = [[UIView alloc] init];
        [self addSubview:_rowsView];
        _empty = L4(self, 17, 0, HA_DIM());
        _empty.textAlignment = NSTextAlignmentCenter; _empty.numberOfLines = 0;
        _empty.text = @"Checking…";
    }
    return self;
}

- (double)low { return [self.spec[@"low"] respondsToSelector:@selector(doubleValue)] ? [self.spec[@"low"] doubleValue] : 20; }

- (BOOL)excluded:(NSString *)eid {
    for (id pat in Arr4(self.spec[@"exclude"]))
        if ([pat isKindOfClass:[NSString class]] && [[NSPredicate predicateWithFormat:@"SELF LIKE %@", pat] evaluateWithObject:eid]) return YES;
    return NO;
}

- (void)reload { self.lastLoad = nil; [self tick]; }

- (void)tick {
    if (!self.active || self.loading) return;
    if (self.lastLoad && [[NSDate date] timeIntervalSinceDate:self.lastLoad] < 300) return;
    self.loading = YES;
    self.lastLoad = [NSDate date];
    NSString *tpl = @"{%- set ns = namespace(o=[]) -%}"
                    @"{%- for s in states.sensor if s.attributes.device_class == 'battery' and s.state | is_number -%}"
                    @"{%- set ns.o = ns.o + [{'e': s.entity_id, 'n': s.name, 'v': s.state | float}] -%}"
                    @"{%- endfor -%}{{ ns.o | tojson }}";
    __weak HABatteriesCard *ws = self;
    [[HAClient shared] renderTemplate:tpl completion:^(id json, NSError *e) {
        HABatteriesCard *ss = ws;
        ss.loading = NO;
        if (![json isKindOfClass:[NSArray class]]) { ss.empty.text = [NSString stringWithFormat:@"Could not check: %@", e.localizedDescription ?: @"?"]; ss.empty.hidden = NO; return; }
        NSMutableArray *keep = [NSMutableArray array];
        for (id it in json) {
            if (![it isKindOfClass:[NSDictionary class]] || !Str(it[@"e"]) || [ss excluded:it[@"e"]]) continue;
            if ([ss.spec[@"only_low"] boolValue] && [it[@"v"] doubleValue] > [ss low]) continue;
            [keep addObject:it];
        }
        [keep sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [@([a[@"v"] doubleValue]) compare:@([b[@"v"] doubleValue])]; }];
        ss.items = keep;
        [ss rebuild];
    }];
}

- (void)rebuild {
    for (UIView *v in [self.rowsView.subviews copy]) [v removeFromSuperview];
    if (!self.items) return;
    self.empty.hidden = self.items.count > 0;
    self.empty.text = [self.spec[@"only_low"] boolValue] ? [NSString stringWithFormat:@"✓  Every battery is above %.0f%%", [self low]] : @"No battery sensors found";
    CGFloat W = self.rowsView.bounds.size.width, H = self.rowsView.bounds.size.height;
    if (W < 10 || H < 10) return;
    NSInteger cols = W >= 520 ? 2 : 1;
    CGFloat rowH = 30, colW = (W - (cols - 1) * 24) / cols;
    NSInteger perCol = MAX(1, (NSInteger)(H / rowH));
    BOOL bars = colW >= 240;
    for (NSInteger i = 0; i < (NSInteger)self.items.count && i < perCol * cols; i++) {
        NSDictionary *it = self.items[i];
        double v = [it[@"v"] doubleValue];
        UIColor *col = v <= [self low] ? Red4() : (v <= [self low] * 2 ? Amber4() : Green4());
        CGFloat x = (i / perCol) * (colW + 24), y = (i % perCol) * rowH;
        NSString *n = Str(it[@"n"]) ?: Str(it[@"e"]);
        for (NSString *tail in @[@" Battery level", @" battery level", @" Battery", @" battery"]) if ([n hasSuffix:tail]) { n = [n substringToIndex:n.length - tail.length]; break; }
        UILabel *name = L4(self.rowsView, 15, 0, HA_TEXT());
        name.text = n;
        CGFloat barW = bars ? colW * 0.3 : 0;
        name.frame = CGRectMake(x, y, colW - barW - 56, rowH);
        if (bars) Bar4(self.rowsView, CGRectMake(x + colW - barW - 50, y + rowH / 2 - 3, barW, 6), v / 100, col);
        UILabel *pct = L4(self.rowsView, 15, 0.3, col);
        pct.text = [NSString stringWithFormat:@"%.0f%%", v];
        pct.textAlignment = NSTextAlignmentRight;
        pct.frame = CGRectMake(x + colW - 46, y, 46, rowH);
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect c = [self contentRect];
    BOOL resized = !CGSizeEqualToSize(self.rowsView.frame.size, c.size);
    self.rowsView.frame = c;
    self.empty.frame = c;
    if (resized) [self rebuild];
}

@end

#pragma mark - Detections (history of Frigate alerts)
// { "type":"detections", "frigate":"http://192.168.1.61:5000", "labels":["person","dog","cat"],
//   "limit":60, "columns":4, "cameras": { "front_yard": "Front Yard" } }
// A grid of what the cameras have seen, newest first, straight from the Frigate API. Tap a picture
// for the full snapshot (needs snapshots enabled in Frigate; otherwise the thumbnail is shown).

@interface HADetectionsCard : HACard
@property (nonatomic, strong) NSArray *events;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UILabel *empty;
@property (nonatomic, strong) NSCache *thumbs;
@property (nonatomic, strong) NSDate *lastLoad;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, copy) NSString *drawnKey;
@property (nonatomic, strong) UIView *viewer;
@end

@implementation HADetectionsCard

- (instancetype)initWithSpec:(NSDictionary *)spec host:(id<HACardHost>)host {
    if ((self = [super initWithSpec:spec host:host])) {
        if (!Str(spec[@"title"])) self.titleLabel.text = @"CAMERA ALERTS";
        _scroll = [[UIScrollView alloc] init];
        _scroll.indicatorStyle = UIScrollViewIndicatorStyleWhite;
        [self addSubview:_scroll];
        _empty = L4(self, 18, 0, HA_DIM());
        _empty.textAlignment = NSTextAlignmentCenter; _empty.numberOfLines = 0;
        _empty.text = @"Loading…";
        _thumbs = [[NSCache alloc] init];
        _thumbs.countLimit = 120;
    }
    return self;
}

- (NSString *)base {
    NSString *b = Str(self.spec[@"frigate"]) ?: @"";
    while ([b hasSuffix:@"/"]) b = [b substringToIndex:b.length - 1];
    return b;
}

- (void)reload { self.lastLoad = nil; [self tick]; }

- (void)tick {
    if (![self base].length) { self.empty.text = @"Set \"frigate\" to the Frigate address in the layout"; return; }
    if (!self.active || self.loading) return;
    if (self.lastLoad && [[NSDate date] timeIntervalSinceDate:self.lastLoad] < 30) return;
    self.loading = YES;
    self.lastLoad = [NSDate date];
    NSArray *labels = Arr4(self.spec[@"labels"]).count ? self.spec[@"labels"] : @[@"person", @"dog", @"cat"];
    NSString *u = [NSString stringWithFormat:@"%@/api/events?limit=%ld&labels=%@", [self base], (long)MAX(4, MIN(200, Int(self.spec[@"limit"], 60))), [labels componentsJoinedByString:@","]];
    NSURLRequest *r = [NSURLRequest requestWithURL:[NSURL URLWithString:u] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10];
    __weak HADetectionsCard *ws = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            HADetectionsCard *ss = ws;
            ss.loading = NO;
            if (![json isKindOfClass:[NSArray class]]) {
                if (!ss.events.count) { ss.empty.hidden = NO; ss.empty.text = [NSString stringWithFormat:@"Could not reach Frigate\n%@", err.localizedDescription ?: @""]; }
                return;
            }
            NSMutableArray *ev = [NSMutableArray array];
            for (id e in json) if ([e isKindOfClass:[NSDictionary class]] && Str(e[@"id"])) [ev addObject:e];
            ss.events = ev;
            [ss rebuild];
        });
    }] resume];
}

- (NSString *)cameraName:(NSString *)cam {
    NSDictionary *names = Dict4(self.spec[@"cameras"]);
    id n = names[cam ?: @""];
    if ([n isKindOfClass:[NSDictionary class]]) n = n[@"name"];
    return Str(n) ?: [[(cam ?: @"") stringByReplacingOccurrencesOfString:@"_" withString:@" "] capitalizedString];
}

static NSString *When4(double ts) {
    static NSDateFormatter *t, *d;
    if (!t) { t = [[NSDateFormatter alloc] init]; t.dateFormat = @"h:mm a"; d = [[NSDateFormatter alloc] init]; d.dateFormat = @"EEE MMM d"; }
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:ts];
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSString *day = [cal isDateInToday:date] ? @"Today" : ([cal isDateInYesterday:date] ? @"Yesterday" : [d stringFromDate:date]);
    return [NSString stringWithFormat:@"%@ %@", day, [t stringFromDate:date]];
}

- (void)rebuild {
    CGFloat W = self.scroll.bounds.size.width;
    if (W < 10 || !self.events) return;
    NSMutableString *key = [NSMutableString stringWithFormat:@"%.0f", W];
    for (NSDictionary *e in self.events) [key appendFormat:@"|%@", e[@"id"]];
    if ([key isEqualToString:self.drawnKey]) return;
    self.drawnKey = key;
    for (UIView *v in [self.scroll.subviews copy]) if ([v isKindOfClass:[UIButton class]]) [v removeFromSuperview];
    self.empty.hidden = self.events.count > 0;
    self.empty.text = @"Nothing seen yet";
    NSInteger cols = MAX(1, Int(self.spec[@"columns"], W >= 700 ? 4 : (W >= 440 ? 3 : (W >= 260 ? 2 : 1))));
    CGFloat gap = 12, tw = (W - (cols - 1) * gap) / cols, ih = tw * 0.62, th = ih + 44;
    for (NSUInteger i = 0; i < self.events.count; i++) {
        NSDictionary *e = self.events[i];
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.tag = i;
        b.frame = CGRectMake((i % cols) * (tw + gap), (i / cols) * (th + gap), tw, th);
        b.backgroundColor = HA_OFF(); b.layer.cornerRadius = 12; b.clipsToBounds = YES;
        [b addTarget:self action:@selector(eventTapped:) forControlEvents:UIControlEventTouchUpInside];
        UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, tw, ih)];
        iv.contentMode = UIViewContentModeScaleAspectFill; iv.clipsToBounds = YES; iv.userInteractionEnabled = NO;
        iv.backgroundColor = [UIColor blackColor];
        [b addSubview:iv];
        UILabel *what = L4(b, 15, 0.3, HA_TEXT());
        what.text = [NSString stringWithFormat:@"%@ · %@", [(Str(e[@"label"]) ?: @"?") capitalizedString], [self cameraName:Str(e[@"camera"])]];
        what.frame = CGRectMake(10, ih + 4, tw - 20, 20);
        UILabel *when = L4(b, 12, 0, HA_DIM());
        when.text = [e[@"start_time"] respondsToSelector:@selector(doubleValue)] ? When4([e[@"start_time"] doubleValue]) : @"";
        when.frame = CGRectMake(10, ih + 23, tw - 20, 16);
        [self.scroll addSubview:b];
        NSString *eid = e[@"id"];
        UIImage *have = [self.thumbs objectForKey:eid];
        if (have) { iv.image = have; continue; }
        __weak HADetectionsCard *ws = self;
        __weak UIImageView *wiv = iv;
        [[HAClient shared] fetchImageURL:[NSString stringWithFormat:@"%@/api/events/%@/thumbnail.jpg", [self base], eid] auth:NO maxSide:360 completion:^(UIImage *img) {
            if (!img) return;
            [ws.thumbs setObject:img forKey:eid];
            wiv.image = img;
        }];
    }
    NSInteger rows = (self.events.count + cols - 1) / cols;
    self.scroll.contentSize = CGSizeMake(W, rows * (th + gap));
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect c = [self contentRect];
    self.scroll.frame = c;
    self.empty.frame = c;
    [self rebuild];
}

- (void)eventTapped:(UIButton *)b {
    UIWindow *win = self.window;
    if (!win || b.tag >= (NSInteger)self.events.count) return;
    NSDictionary *e = self.events[b.tag];
    UIControl *v = [[UIControl alloc] initWithFrame:win.rootViewController.view.bounds];
    v.backgroundColor = [UIColor blackColor];
    [v addTarget:self action:@selector(closeViewer) forControlEvents:UIControlEventTouchUpInside];
    UIImageView *iv = [[UIImageView alloc] initWithFrame:v.bounds];
    iv.contentMode = UIViewContentModeScaleAspectFit; iv.userInteractionEnabled = NO;
    iv.image = [self.thumbs objectForKey:e[@"id"]];   // the small picture until the full one arrives
    [v addSubview:iv];
    UILabel *n = L4(v, 24, 0.4, [UIColor whiteColor]);
    n.text = [NSString stringWithFormat:@"%@ · %@ · %@   ·   tap to close", [(Str(e[@"label"]) ?: @"?") capitalizedString], [self cameraName:Str(e[@"camera"])],
              [e[@"start_time"] respondsToSelector:@selector(doubleValue)] ? When4([e[@"start_time"] doubleValue]) : @""];
    n.shadowColor = [UIColor colorWithWhite:0 alpha:0.8]; n.shadowOffset = CGSizeMake(0, 1);
    n.frame = CGRectMake(24, v.bounds.size.height - 50, v.bounds.size.width - 48, 32);
    v.alpha = 0;
    [win.rootViewController.view addSubview:v];
    [UIView animateWithDuration:0.2 animations:^{ v.alpha = 1; }];
    self.viewer = v;
    if ([e[@"has_snapshot"] boolValue]) {
        __weak UIImageView *wiv = iv;
        [[HAClient shared] fetchImageURL:[NSString stringWithFormat:@"%@/api/events/%@/snapshot.jpg?bbox=1", [self base], e[@"id"]] auth:NO maxSide:1024 completion:^(UIImage *img) {
            if (img) wiv.image = img;
        }];
    }
}

- (void)closeViewer {
    UIView *v = self.viewer;
    self.viewer = nil;
    [UIView animateWithDuration:0.2 animations:^{ v.alpha = 0; } completion:^(BOOL f) { [v removeFromSuperview]; }];
}

@end

// Second batch of cards: climate, climate_detail, light_members, context, library.
// Registered by name in +[HACard cardWithSpec:host:] (Cards.m).
#import "Cards.h"
#import "HAClient.h"
#import <QuartzCore/QuartzCore.h>

#define Str HA_Str
#define Int HA_Int

static NSArray *Arr(id v) { return [v isKindOfClass:[NSArray class]] ? v : @[]; }
static NSDictionary *Dict(id v) { return [v isKindOfClass:[NSDictionary class]] ? v : nil; }

static NSString *Pretty(NSString *s) {   // "heat_cool" -> "Heat/Cool", "auto" -> "Auto"
    if (!s.length) return @"";
    if ([s isEqualToString:@"heat_cool"]) return @"Heat/Cool";
    if ([s isEqualToString:@"fan_only"]) return @"Fan";
    NSString *t = [s stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    return [[[t substringToIndex:1] uppercaseString] stringByAppendingString:[t substringFromIndex:1]];
}

static void Paint(UIButton *b, BOOL on, UIColor *onColor) {
    HA_SetBG(b, on ? onColor : HA_OFF());
    [b setTitleColor:on ? [UIColor blackColor] : HA_TEXT() forState:UIControlStateNormal];
}

static UIColor *ModeColor(NSString *mode) {
    if ([mode isEqualToString:@"heat"]) return HA_HEAT();
    if ([mode isEqualToString:@"cool"]) return HA_COOL();
    if ([mode isEqualToString:@"heat_cool"] || [mode isEqualToString:@"auto"]) return HA_ACCENT();
    return HA_DIM();
}

#pragma mark - Climate (round thermostat dial)
// { "type":"climate", "entity":"climate.x", "title":"Thermostat", "opens":"Climate", "step":1 }
// Drawn like a round wall thermostat: a ring of tick marks, the target temperature in the middle,
// the current temperature marked on the ring, and a face that turns blue while cooling and
// orange while heating. Drag around the ring (or use the - / + buttons) to change the target.

@interface HAThermoDial : UIControl
@property (nonatomic, assign) double lo, hi;              // scale ends (min_temp / max_temp)
@property (nonatomic, assign) double target, low, high;   // target, or low/high in range mode
@property (nonatomic, assign) double current;             // NAN when unknown
@property (nonatomic, assign) BOOL range, off;
@property (nonatomic, copy) NSString *mode, *action;
@property (nonatomic, assign) double dragValue;           // set while the ring is dragged
@end

@implementation HAThermoDial

static const CGFloat kDialStart = 135, kDialSweep = 270;   // degrees, clockwise from 3 o'clock; the gap is at the bottom

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.backgroundColor = [UIColor clearColor];
        self.contentMode = UIViewContentModeRedraw;
        self.tag = 9901;   // HAPagesScroll leaves touches on this view alone (see PanelViewController.m)
        _lo = 50; _hi = 90; _current = NAN;
    }
    return self;
}

- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)e {
    CGFloat R = MIN(self.bounds.size.width, self.bounds.size.height) / 2;
    CGFloat dx = p.x - CGRectGetMidX(self.bounds), dy = p.y - CGRectGetMidY(self.bounds);
    return dx * dx + dy * dy <= R * R;
}

- (CGFloat)angleFor:(double)v {
    double f = (_hi > _lo) ? (v - _lo) / (_hi - _lo) : 0;
    return (kDialStart + kDialSweep * MAX(0, MIN(1, f))) * M_PI / 180;
}

- (void)drawText:(NSString *)t font:(UIFont *)font color:(UIColor *)c center:(CGPoint)p {
    NSDictionary *at = @{NSFontAttributeName: font, NSForegroundColorAttributeName: c};
    CGSize s = [t sizeWithAttributes:at];
    [t drawAtPoint:CGPointMake(p.x - s.width / 2, p.y - s.height / 2) withAttributes:at];
}

- (void)drawRect:(CGRect)rect {
    CGContextRef g = UIGraphicsGetCurrentContext();
    CGFloat D = MIN(self.bounds.size.width, self.bounds.size.height), R = D / 2;
    CGPoint c = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    BOOL cooling = [_action isEqualToString:@"cooling"], heating = [_action isEqualToString:@"heating"];

    // brushed-metal bezel
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGFloat bez[] = { 0.62, 0.63, 0.66, 1,  0.22, 0.22, 0.24, 1 };
    CGGradientRef bg = CGGradientCreateWithColorComponents(cs, bez, NULL, 2);
    CGContextSaveGState(g);
    CGContextAddEllipseInRect(g, CGRectMake(c.x - R, c.y - R, D, D));
    CGContextClip(g);
    CGContextDrawLinearGradient(g, bg, CGPointMake(c.x, c.y - R), CGPointMake(c.x, c.y + R), 0);
    CGContextRestoreGState(g);
    CGGradientRelease(bg);

    // face: black when idle, blue while cooling, orange while heating (a little lighter towards the top)
    CGFloat fr = R * 0.93;
    CGFloat idle[] = { 0.13, 0.13, 0.15, 1,  0.03, 0.03, 0.04, 1 };
    CGFloat cool[] = { 0.16, 0.56, 0.96, 1,  0.02, 0.33, 0.78, 1 };
    CGFloat heat[] = { 0.98, 0.52, 0.16, 1,  0.84, 0.30, 0.04, 1 };
    CGGradientRef fg = CGGradientCreateWithColorComponents(cs, cooling ? cool : (heating ? heat : idle), NULL, 2);
    CGContextSaveGState(g);
    CGContextAddEllipseInRect(g, CGRectMake(c.x - fr, c.y - fr, fr * 2, fr * 2));
    CGContextClip(g);
    CGContextDrawRadialGradient(g, fg, CGPointMake(c.x, c.y - fr * 0.4), 0, c, fr * 1.15, kCGGradientDrawsAfterEndLocation);
    CGContextRestoreGState(g);
    CGGradientRelease(fg);
    CGColorSpaceRelease(cs);

    // tick ring: brighter between the current temperature and the target
    BOOL haveCur = !isnan(_current);
    double tLo = _range ? _low : _target, tHi = _range ? _high : _target;
    double bandA = haveCur ? MIN(_current, tLo) : tLo, bandB = haveCur ? MAX(_current, tHi) : tHi;
    NSInteger N = 120;
    CGContextSetLineCap(g, kCGLineCapRound);
    for (NSInteger i = 0; i <= N; i++) {
        double v = _lo + (_hi - _lo) * i / N;
        CGFloat a = (kDialStart + kDialSweep * i / N) * M_PI / 180;
        BOOL lit = !_off && v >= bandA - 0.01 && v <= bandB + 0.01;
        CGContextSetStrokeColorWithColor(g, [UIColor colorWithWhite:1 alpha:lit ? 0.95 : 0.28].CGColor);
        CGContextSetLineWidth(g, MAX(1, D * 0.006));
        CGContextMoveToPoint(g, c.x + cos(a) * fr * 0.80, c.y + sin(a) * fr * 0.80);
        CGContextAddLineToPoint(g, c.x + cos(a) * fr * 0.92, c.y + sin(a) * fr * 0.92);
        CGContextStrokePath(g);
    }
    // target marker(s): a longer, bolder tick
    if (!_off) {
        for (NSNumber *t in (_range ? @[@(_low), @(_high)] : @[@(_target)])) {
            CGFloat a = [self angleFor:t.doubleValue];
            CGContextSetStrokeColorWithColor(g, [UIColor whiteColor].CGColor);
            CGContextSetLineWidth(g, MAX(2.5, D * 0.016));
            CGContextMoveToPoint(g, c.x + cos(a) * fr * 0.74, c.y + sin(a) * fr * 0.74);
            CGContextAddLineToPoint(g, c.x + cos(a) * fr * 0.93, c.y + sin(a) * fr * 0.93);
            CGContextStrokePath(g);
        }
    }
    // current temperature: small number just inside the ring at its position
    if (haveCur) {
        CGFloat a = [self angleFor:_current];
        [self drawText:[NSString stringWithFormat:@"%.0f", _current] font:HA_FONT(MAX(11, D * 0.068), 0.3)
                 color:[UIColor colorWithWhite:1 alpha:0.9] center:CGPointMake(c.x + cos(a) * fr * 0.70, c.y + sin(a) * fr * 0.70)];
    }

    // centre: what it is doing, then the target
    NSString *cap, *big;
    if (_off) { cap = @""; big = @"OFF"; }
    else if (cooling) cap = @"COOLING";
    else if (heating) cap = @"HEATING";
    else if ([_mode isEqualToString:@"cool"]) cap = @"COOL SET TO";
    else if ([_mode isEqualToString:@"heat"]) cap = @"HEAT SET TO";
    else if (_range) cap = @"HEAT • COOL";
    else cap = @"SET TO";
    if (!_off) big = _range ? [NSString stringWithFormat:@"%.0f • %.0f", _low, _high] : [NSString stringWithFormat:@"%.0f", _target];
    CGFloat bigSize = D * (_off ? 0.2 : (_range ? 0.2 : 0.36));
    [self drawText:big font:HA_FONT(bigSize, -0.6) color:[UIColor whiteColor] center:CGPointMake(c.x, c.y + D * 0.02)];
    if (cap.length) [self drawText:cap font:HA_FONT(MAX(9, D * 0.052), 0.4) color:[UIColor colorWithWhite:1 alpha:0.85] center:CGPointMake(c.x, c.y - bigSize * 0.5 - D * 0.02)];
}

// Dragging on the ring sets the target: the angle under the finger is the temperature.
- (BOOL)valueAt:(CGPoint)p requireRing:(BOOL)ring {
    CGFloat R = MIN(self.bounds.size.width, self.bounds.size.height) / 2;
    CGFloat dx = p.x - CGRectGetMidX(self.bounds), dy = p.y - CGRectGetMidY(self.bounds), dist = sqrt(dx * dx + dy * dy);
    if (ring && (dist < R * 0.55 || dist > R * 1.1)) return NO;
    double deg = fmod(atan2(dy, dx) * 180 / M_PI - kDialStart + 720, 360);
    double f = deg / kDialSweep;
    if (f > 1) f = (deg > kDialSweep + (360 - kDialSweep) / 2) ? 0 : 1;   // in the gap at the bottom: snap to the nearer end
    self.dragValue = _lo + (_hi - _lo) * f;
    return YES;
}

- (BOOL)beginTrackingWithTouch:(UITouch *)t withEvent:(UIEvent *)e {
    if (_off || _range || ![self valueAt:[t locationInView:self] requireRing:YES]) return NO;
    [self sendActionsForControlEvents:UIControlEventValueChanged];
    return YES;
}

- (BOOL)continueTrackingWithTouch:(UITouch *)t withEvent:(UIEvent *)e {
    if ([self valueAt:[t locationInView:self] requireRing:NO]) [self sendActionsForControlEvents:UIControlEventValueChanged];
    return YES;
}

@end

@interface HAClimateCard : HACard
@property (nonatomic, copy) NSString *entity;
@property (nonatomic, strong) HAThermoDial *dial;
@property (nonatomic, strong) UILabel *current, *sub, *insideCaption;
@property (nonatomic, strong) UIButton *minus, *plus;
@property (nonatomic, strong) NSMutableArray *modeChips;
@property (nonatomic, strong) NSArray *modes;
@property (nonatomic, strong) NSDictionary *state;
@property (nonatomic, assign) double pendingLow, pendingHigh, pendingTemp;
@property (nonatomic, assign) double haLo, haHi;   // the thermostat's own limits (the dial may show a narrower range)
@property (nonatomic, assign) double startTemp, startLow, startHigh;   // the targets before this adjustment began
@property (nonatomic, assign) BOOL confirming;     // the "are you sure" question for a big change is on screen
@property (nonatomic, strong) NSDate *confirmAt;
@property (nonatomic, weak) UIAlertController *confirmAlert;
@property (nonatomic, strong) NSDate *pendingAt;
@end

@implementation HAClimateCard

- (instancetype)initWithSpec:(NSDictionary *)spec host:(id<HACardHost>)host {
    if ((self = [super initWithSpec:spec host:host])) {
        _entity = Str(spec[@"entity"]) ?: @"";
        if (!Str(spec[@"title"])) self.titleLabel.text = @"THERMOSTAT";
        _dial = [[HAThermoDial alloc] initWithFrame:CGRectZero];
        [_dial addTarget:self action:@selector(dialDragged) forControlEvents:UIControlEventValueChanged];
        [self addSubview:_dial];
        _insideCaption = [self addLabel:13 weight:0.4 color:HA_DIM()];
        _insideCaption.text = @"INSIDE";
        _current = [self addLabel:52 weight:-0.5 color:HA_TEXT()];
        _sub = [self addLabel:16 weight:0 color:HA_DIM()];
        _sub.numberOfLines = 2;
        _minus = [self addButton:@"−" size:32 action:@selector(minusTapped)];
        _plus = [self addButton:@"+" size:32 action:@selector(plusTapped)];
        _modeChips = [NSMutableArray array];
        _haLo = 50; _haHi = 90;
        [self insertSubview:_minus belowSubview:_dial];   // the buttons peek out from behind the dial
        [self insertSubview:_plus belowSubview:_dial];
    }
    return self;
}

- (NSArray *)entityIds { return @[self.entity]; }

// The dial takes as much of the tile as it can. Wide tiles put the readings and - / + beside it;
// - and + always peek out from behind the dial on either side.
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect c = [self contentRect];
    NSInteger n = self.modeChips.count;
    BOOL showChips = n && c.size.height >= 210;
    CGFloat chipsH = showChips ? 40 : 0;
    CGFloat bodyH = c.size.height - (showChips ? chipsH + 12 : 0);
    BOOL side = c.size.width >= 420;
    CGFloat D, bs;
    if (side) {
        CGFloat maxD = MIN(bodyH, c.size.width - 190);
        bs = MAX(40, MIN(62, maxD * 0.26));
        D = MAX(60, MIN(maxD, c.size.width - 190 - bs * 1.3));
        self.dial.frame = CGRectMake(c.origin.x + bs * 0.65, c.origin.y + (bodyH - D) / 2, D, D);
        CGFloat rx = CGRectGetMaxX(self.dial.frame) + bs * 0.65 + 16, rw = CGRectGetMaxX(c) - rx;
        BOOL roomy = bodyH >= 20 + 58 + 44;
        CGFloat blockH = (roomy ? 20 : 0) + 58 + (roomy ? 44 : 22);
        CGFloat y = c.origin.y + MAX(0, (bodyH - blockH) / 2);
        self.insideCaption.hidden = !roomy;
        self.insideCaption.frame = CGRectMake(rx, y, rw, 18);
        if (roomy) y += 20;
        self.current.hidden = self.sub.hidden = NO;
        self.current.frame = CGRectMake(rx, y, rw, 58);
        y += 58;
        self.sub.numberOfLines = roomy ? 2 : 1;
        self.sub.frame = CGRectMake(rx, y, rw, roomy ? 44 : 22);
    } else {
        bs = MAX(38, MIN(60, MIN(c.size.width, bodyH) * 0.27));
        D = MAX(60, MIN(c.size.width - bs * 1.3, bodyH));
        self.dial.frame = CGRectMake(c.origin.x + (c.size.width - D) / 2, c.origin.y + MAX(0, (bodyH - D) / 2), D, D);
        self.insideCaption.hidden = self.current.hidden = self.sub.hidden = YES;   // the dial shows the current temperature itself
    }
    // - and + sit on either side of the dial, tucked behind its edge a little below the middle,
    // for one-degree steps when the ring is too small to hit exactly
    CGFloat R = D / 2, dy = R * 0.42, ex = sqrt(R * R - dy * dy);
    CGPoint dc = CGPointMake(CGRectGetMidX(self.dial.frame), CGRectGetMidY(self.dial.frame));
    self.minus.hidden = self.plus.hidden = NO;
    self.minus.bounds = self.plus.bounds = CGRectMake(0, 0, bs, bs);
    self.minus.center = CGPointMake(dc.x - ex - bs * 0.16, dc.y + dy);
    self.plus.center = CGPointMake(dc.x + ex + bs * 0.16, dc.y + dy);
    self.minus.layer.cornerRadius = self.plus.layer.cornerRadius = bs / 2;
    self.minus.titleLabel.font = self.plus.titleLabel.font = HA_FONT(bs * 0.5, 0.3);
    self.minus.titleEdgeInsets = UIEdgeInsetsMake(0, 0, 2, bs * 0.34);   // the symbol sits in the part that shows
    self.plus.titleEdgeInsets = UIEdgeInsetsMake(0, bs * 0.34, 2, 0);
    CGFloat cw = n ? (c.size.width - (n - 1) * 8) / n : 0;
    for (NSInteger i = 0; i < n; i++) {
        UIButton *b = self.modeChips[i];
        b.hidden = !showChips;
        b.frame = CGRectMake(c.origin.x + i * (cw + 8), CGRectGetMaxY(c) - chipsH, cw, chipsH);
    }
}

- (BOOL)isRange { NSDictionary *a = self.state[@"attributes"]; return a[@"target_temp_low"] && a[@"target_temp_low"] != [NSNull null] && [self.state[@"state"] isEqualToString:@"heat_cool"]; }

static double Num(id v, double def) { return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : def; }

- (void)updateStates:(NSDictionary *)states {
    NSDictionary *s = states[self.entity];
    if (!s) return;
    self.state = s;
    NSDictionary *a = s[@"attributes"];
    NSString *mode = Str(s[@"state"]) ?: @"";
    NSString *action = Str(a[@"hvac_action"]) ?: @"";
    id cur = a[@"current_temperature"];
    BOOL haveCur = [cur respondsToSelector:@selector(doubleValue)];
    self.current.text = haveCur ? [NSString stringWithFormat:@"%.0f°", [cur doubleValue]] : @"--";
    self.current.textColor = [action isEqualToString:@"cooling"] ? HA_COOL() : ([action isEqualToString:@"heating"] ? HA_HEAT() : HA_TEXT());
    NSMutableArray *bits = [NSMutableArray array];
    if ([a[@"current_humidity"] respondsToSelector:@selector(doubleValue)]) [bits addObject:[NSString stringWithFormat:@"%@%% humidity", a[@"current_humidity"]]];
    if (action.length) [bits addObject:Pretty(action)];
    self.sub.text = [bits componentsJoinedByString:@"\n"];

    HAThermoDial *d = self.dial;
    // The ring covers "min".."max" from the layout; by default 65-85 on a Fahrenheit thermostat, so
    // each degree gets more of the ring. The - / + buttons can still go to the thermostat's own limits.
    self.haLo = Num(a[@"min_temp"], 50); self.haHi = Num(a[@"max_temp"], 90);
    BOOL fahrenheit = self.haHi > 60;
    d.lo = Num(self.spec[@"min"], fahrenheit ? MAX(self.haLo, 65) : self.haLo);
    d.hi = Num(self.spec[@"max"], fahrenheit ? MIN(self.haHi, 85) : self.haHi);
    d.current = haveCur ? [cur doubleValue] : NAN;
    d.mode = mode; d.action = action;
    d.range = [self isRange];
    BOOL haveTarget = d.range || [a[@"temperature"] respondsToSelector:@selector(doubleValue)];
    d.off = [mode isEqualToString:@"off"] || !haveTarget;
    if (!self.pendingAt && !self.confirming) {
        d.target = Num(a[@"temperature"], d.target);
        d.low = Num(a[@"target_temp_low"], d.low); d.high = Num(a[@"target_temp_high"], d.high);
    }
    [d setNeedsDisplay];
    BOOL canSet = !d.off;
    self.minus.enabled = self.plus.enabled = canSet;
    self.minus.alpha = self.plus.alpha = canSet ? 1 : 0.35;

    NSArray *modes = Arr(a[@"hvac_modes"]).count ? a[@"hvac_modes"] : @[@"off", @"heat", @"cool", @"heat_cool"];
    if (![modes isEqualToArray:self.modes]) {
        self.modes = modes;
        for (UIButton *b in self.modeChips) [b removeFromSuperview];
        [self.modeChips removeAllObjects];
        for (NSUInteger i = 0; i < modes.count; i++) {
            UIButton *b = HA_Chip(Pretty(modes[i]), self, @selector(modeTapped:));
            b.tag = i;
            [self addSubview:b];
            [self.modeChips addObject:b];
        }
        [self setNeedsLayout];
    }
    for (NSUInteger i = 0; i < self.modeChips.count; i++) Paint(self.modeChips[i], [self.modes[i] isEqualToString:mode], ModeColor(mode));
}

- (void)beginPending {
    if (self.pendingAt) return;
    self.pendingTemp = self.dial.target; self.pendingLow = self.dial.low; self.pendingHigh = self.dial.high;
    self.startTemp = self.pendingTemp; self.startLow = self.pendingLow; self.startHigh = self.pendingHigh;
}

- (void)showPending {
    HAThermoDial *d = self.dial;
    d.target = MAX(self.haLo, MIN(self.haHi, self.pendingTemp)); self.pendingTemp = d.target;
    d.low = self.pendingLow; d.high = self.pendingHigh;
    [d setNeedsDisplay];
    self.pendingAt = [NSDate date];   // sent 3 s after the last change (see -tick)
}

- (void)nudge:(double)delta {
    double step = [self.spec[@"step"] respondsToSelector:@selector(doubleValue)] ? [self.spec[@"step"] doubleValue] : 1;
    [self beginPending];
    if ([self isRange]) { self.pendingLow += delta * step; self.pendingHigh += delta * step; }
    else self.pendingTemp += delta * step;
    [self showPending];
}

- (void)dialDragged {
    double step = [self.spec[@"step"] respondsToSelector:@selector(doubleValue)] ? MAX(0.5, [self.spec[@"step"] doubleValue]) : 1;
    double v = round(self.dial.dragValue / step) * step;
    [self beginPending];
    if (v == self.pendingTemp && self.pendingAt) { self.pendingAt = [NSDate date]; return; }
    self.pendingTemp = v;
    [self showPending];
}

- (void)minusTapped { [self nudge:-1]; }
- (void)plusTapped { [self nudge:1]; }

// Nothing is sent until the target has been left alone for 3 seconds ("delay" in the layout), so
// a slip or an overshoot can be corrected before the system reacts. A change of more than 5 degrees
// ("confirm_over") asks first, in case it was a bad press.
- (void)tick {
    double delay = [self.spec[@"delay"] respondsToSelector:@selector(doubleValue)] ? MAX(0.5, [self.spec[@"delay"] doubleValue]) : 3;
    if (self.confirming && [[NSDate date] timeIntervalSinceDate:self.confirmAt] > 30) {   // nobody answered: keep the old setting
        [self.confirmAlert dismissViewControllerAnimated:YES completion:nil];
        HALog(@"climate: no answer, kept %.0f", self.startTemp);
        [self keepOld];
    }
    if (!self.pendingAt || self.confirming || self.dial.tracking || [[NSDate date] timeIntervalSinceDate:self.pendingAt] <= delay) return;
    self.pendingAt = nil;
    BOOL range = [self isRange];
    double change = range ? self.pendingLow - self.startLow : self.pendingTemp - self.startTemp;
    double limit = [self.spec[@"confirm_over"] respondsToSelector:@selector(doubleValue)] ? [self.spec[@"confirm_over"] doubleValue] : 5;
    if (fabs(change) < 0.01) return;   // back where it started: nothing to send
    if (fabs(change) <= limit) { [self sendPending]; return; }
    self.confirming = YES;
    self.confirmAt = [NSDate date];
    HALog(@"climate: asking before a %.0f degree change (%.0f -> %.0f)", change, range ? self.startLow : self.startTemp, range ? self.pendingLow : self.pendingTemp);
    NSString *to = range ? [NSString stringWithFormat:@"%.0f–%.0f°", self.pendingLow, self.pendingHigh] : [NSString stringWithFormat:@"%.0f°", self.pendingTemp];
    NSString *was = range ? [NSString stringWithFormat:@"%.0f–%.0f°", self.startLow, self.startHigh] : [NSString stringWithFormat:@"%.0f°", self.startTemp];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Set the thermostat to %@?", to]
                                                                message:[NSString stringWithFormat:@"That is %.0f° %@ than the current setting of %@.", fabs(change), change > 0 ? @"warmer" : @"cooler", was]
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Keep %@", was] style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { HALog(@"climate: change declined, kept %.0f", self.startTemp); [self keepOld]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Set %@", to] style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        self.confirming = NO;
        [self sendPending];
    }]];
    self.confirmAlert = ac;
    [[UIApplication sharedApplication].keyWindow.rootViewController presentViewController:ac animated:YES completion:nil];
}

- (void)keepOld {
    self.confirming = NO;
    self.dial.target = self.startTemp; self.dial.low = self.startLow; self.dial.high = self.startHigh;
    [self.dial setNeedsDisplay];
}

- (void)sendPending {
    HALog(@"climate: sending %.0f", [self isRange] ? self.pendingLow : self.pendingTemp);
    NSDictionary *data = [self isRange] ? @{@"entity_id": self.entity, @"target_temp_low": @(self.pendingLow), @"target_temp_high": @(self.pendingHigh)}
                                        : @{@"entity_id": self.entity, @"temperature": @(self.pendingTemp)};
    [self.host card:self callService:@"climate.set_temperature" data:data];
}

- (void)modeTapped:(UIButton *)b {
    if (b.tag < (NSInteger)self.modes.count)
        [self.host card:self callService:@"climate.set_hvac_mode" data:@{@"entity_id": self.entity, @"hvac_mode": self.modes[b.tag]}];
}

@end

#pragma mark - Climate detail (drawer): modes, fan, presets, 24 h graph, activity log
// { "type":"climate_detail", "entity":"climate.x", "hours":24 }

@interface HAGraphView : UIView
@property (nonatomic, strong) NSArray *temps;     // [@[NSDate, NSNumber]]
@property (nonatomic, strong) NSArray *targets;   // [@[NSDate, NSNumber]]
@property (nonatomic, strong) NSArray *actions;   // [@[NSDate start, NSDate end, NSString action]]
@property (nonatomic, strong) NSDate *start, *end;
@end

@implementation HAGraphView

- (instancetype)initWithFrame:(CGRect)f { if ((self = [super initWithFrame:f])) { self.backgroundColor = [UIColor clearColor]; self.contentMode = UIViewContentModeRedraw; } return self; }

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGFloat L = 40, R = 8, T = 8, B = 22;
    CGRect plot = CGRectMake(L, T, self.bounds.size.width - L - R, self.bounds.size.height - T - B);
    double lo = 1e9, hi = -1e9;
    for (NSArray *p in [self.temps arrayByAddingObjectsFromArray:self.targets ?: @[]]) { double v = [p[1] doubleValue]; lo = MIN(lo, v); hi = MAX(hi, v); }
    NSDictionary *axis = @{NSFontAttributeName: HA_FONT(11, 0), NSForegroundColorAttributeName: HA_DIM()};
    if (lo > hi || !self.start || !self.end) {
        [@"No history yet" drawAtPoint:CGPointMake(L, T + plot.size.height / 2 - 8) withAttributes:axis];
        return;
    }
    lo = floor(lo - 1); hi = ceil(hi + 1);
    NSTimeInterval span = MAX(1, [self.end timeIntervalSinceDate:self.start]);
    CGFloat (^X)(NSDate *) = ^CGFloat(NSDate *d) { return plot.origin.x + plot.size.width * MAX(0, MIN(1, [d timeIntervalSinceDate:self.start] / span)); };
    CGFloat (^Y)(double) = ^CGFloat(double v) { return plot.origin.y + plot.size.height * (1 - (v - lo) / (hi - lo)); };

    // heating / cooling bands
    for (NSArray *a in self.actions) {
        UIColor *c = [a[2] isEqualToString:@"cooling"] ? HA_COOL() : ([a[2] isEqualToString:@"heating"] ? HA_HEAT() : nil);
        if (!c) continue;
        CGContextSetFillColorWithColor(ctx, [c colorWithAlphaComponent:0.18].CGColor);
        CGContextFillRect(ctx, CGRectMake(X(a[0]), plot.origin.y, MAX(1, X(a[1]) - X(a[0])), plot.size.height));
    }
    // grid + labels
    CGContextSetStrokeColorWithColor(ctx, [HA_DIM() colorWithAlphaComponent:0.25].CGColor);
    CGContextSetLineWidth(ctx, 1);
    for (int i = 0; i <= 4; i++) {
        double v = lo + (hi - lo) * i / 4.0;
        CGFloat y = Y(v);
        CGContextMoveToPoint(ctx, plot.origin.x, y); CGContextAddLineToPoint(ctx, CGRectGetMaxX(plot), y);
        [[NSString stringWithFormat:@"%.0f°", v] drawAtPoint:CGPointMake(4, y - 7) withAttributes:axis];
    }
    CGContextStrokePath(ctx);
    NSDateFormatter *tf = [[NSDateFormatter alloc] init]; tf.dateFormat = @"ha";
    for (int i = 0; i <= 4; i++) {
        NSDate *d = [self.start dateByAddingTimeInterval:span * i / 4.0];
        NSString *s = [[tf stringFromDate:d] lowercaseString];
        [s drawAtPoint:CGPointMake(X(d) - (i == 4 ? 24 : (i ? 10 : 0)), CGRectGetMaxY(plot) + 4) withAttributes:axis];
    }
    // target (stepped, dashed)
    if (self.targets.count) {
        CGContextSetStrokeColorWithColor(ctx, HA_ACCENT().CGColor);
        CGContextSetLineWidth(ctx, 2);
        CGFloat dash[] = {5, 4};
        CGContextSetLineDash(ctx, 0, dash, 2);
        for (NSUInteger i = 0; i < self.targets.count; i++) {
            NSArray *p = self.targets[i];
            NSDate *next = i + 1 < self.targets.count ? self.targets[i + 1][0] : self.end;
            CGFloat y = Y([p[1] doubleValue]);
            if (i == 0) CGContextMoveToPoint(ctx, X(p[0]), y); else CGContextAddLineToPoint(ctx, X(p[0]), y);
            CGContextAddLineToPoint(ctx, X(next), y);
        }
        CGContextStrokePath(ctx);
        CGContextSetLineDash(ctx, 0, NULL, 0);
    }
    // indoor temperature
    if (self.temps.count) {
        CGContextSetStrokeColorWithColor(ctx, HA_TEXT().CGColor);
        CGContextSetLineWidth(ctx, 2.5);
        CGContextSetLineJoin(ctx, kCGLineJoinRound);
        for (NSUInteger i = 0; i < self.temps.count; i++) {
            NSArray *p = self.temps[i];
            CGPoint pt = CGPointMake(X(p[0]), Y([p[1] doubleValue]));
            if (i == 0) CGContextMoveToPoint(ctx, pt.x, pt.y); else CGContextAddLineToPoint(ctx, pt.x, pt.y);
        }
        NSArray *last = self.temps.lastObject;
        CGContextAddLineToPoint(ctx, X(self.end), Y([last[1] doubleValue]));
        CGContextStrokePath(ctx);
    }
}

@end

@interface HAClimateDetailCard : HACard
@property (nonatomic, copy) NSString *entity;
@property (nonatomic, strong) UILabel *modeCaption, *fanCaption, *presetCaption, *graphCaption, *logCaption;
@property (nonatomic, strong) NSMutableArray *modeChips, *fanChips, *presetChips;
@property (nonatomic, strong) NSArray *modes, *fans, *presets;
@property (nonatomic, strong) HAGraphView *graph;
@property (nonatomic, strong) UIScrollView *log;
@property (nonatomic, strong) NSDate *lastHistory;
@property (nonatomic, assign) BOOL loading;
@end

@implementation HAClimateDetailCard

- (instancetype)initWithSpec:(NSDictionary *)spec host:(id<HACardHost>)host {
    if ((self = [super initWithSpec:spec host:host])) {
        _entity = Str(spec[@"entity"]) ?: @"";
        if (!Str(spec[@"title"])) self.titleLabel.text = @"CLIMATE";
        _modeCaption = [self addLabel:13 weight:0.4 color:HA_DIM()]; _modeCaption.text = @"MODE";
        _fanCaption = [self addLabel:13 weight:0.4 color:HA_DIM()]; _fanCaption.text = @"FAN";
        _presetCaption = [self addLabel:13 weight:0.4 color:HA_DIM()]; _presetCaption.text = @"PRESET";
        _graphCaption = [self addLabel:13 weight:0.4 color:HA_DIM()];
        _logCaption = [self addLabel:13 weight:0.4 color:HA_DIM()]; _logCaption.text = @"ACTIVITY";
        _modeChips = [NSMutableArray array]; _fanChips = [NSMutableArray array]; _presetChips = [NSMutableArray array];
        _graph = [[HAGraphView alloc] init];
        [self addSubview:_graph];
        _log = [[UIScrollView alloc] init];
        _log.indicatorStyle = UIScrollViewIndicatorStyleWhite;
        [self addSubview:_log];
    }
    return self;
}

- (NSInteger)hours { return MAX(1, Int(self.spec[@"hours"], 24)); }
- (NSArray *)entityIds { return @[self.entity]; }

- (void)rebuildChips:(NSMutableArray *)chips values:(NSArray *)values action:(SEL)action {
    for (UIButton *b in chips) [b removeFromSuperview];
    [chips removeAllObjects];
    for (NSUInteger i = 0; i < values.count; i++) {
        UIButton *b = HA_Chip(Pretty(Str(values[i])), self, action);
        b.tag = i;
        [self addSubview:b];
        [chips addObject:b];
    }
    [self setNeedsLayout];
}

- (CGFloat)layoutRow:(NSArray *)chips caption:(UILabel *)cap at:(CGFloat)y in:(CGRect)c {
    cap.hidden = chips.count == 0;
    if (!chips.count) return y;
    cap.frame = CGRectMake(c.origin.x, y, c.size.width, 16);
    y += 20;
    NSInteger n = chips.count;
    CGFloat w = MIN(140, (c.size.width - (n - 1) * 8) / n);
    for (NSInteger i = 0; i < n; i++) ((UIView *)chips[i]).frame = CGRectMake(c.origin.x + i * (w + 8), y, w, 38);
    return y + 38 + 12;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect c = [self contentRect];
    CGFloat y = c.origin.y;
    y = [self layoutRow:self.modeChips caption:self.modeCaption at:y in:c];
    y = [self layoutRow:self.fanChips caption:self.fanCaption at:y in:c];
    y = [self layoutRow:self.presetChips caption:self.presetCaption at:y in:c];
    self.graphCaption.frame = CGRectMake(c.origin.x, y, c.size.width, 16);
    CGFloat gh = MAX(140, MIN(230, (CGRectGetMaxY(c) - y) * 0.5));
    self.graph.frame = CGRectMake(c.origin.x, y + 18, c.size.width, gh);
    [self.graph setNeedsDisplay];
    y += 18 + gh + 10;
    self.logCaption.frame = CGRectMake(c.origin.x, y, c.size.width, 16);
    self.log.frame = CGRectMake(c.origin.x, y + 20, c.size.width, MAX(40, CGRectGetMaxY(c) - y - 20));
}

- (void)updateStates:(NSDictionary *)states {
    NSDictionary *s = states[self.entity];
    if (!s) return;
    NSDictionary *a = s[@"attributes"];
    NSString *mode = Str(s[@"state"]);
    NSArray *modes = Arr(a[@"hvac_modes"]), *fans = Arr(a[@"fan_modes"]), *presets = Arr(a[@"preset_modes"]);
    if (![modes isEqualToArray:self.modes]) { self.modes = modes; [self rebuildChips:self.modeChips values:modes action:@selector(modeTapped:)]; }
    if (![fans isEqualToArray:self.fans]) { self.fans = fans; [self rebuildChips:self.fanChips values:fans action:@selector(fanTapped:)]; }
    if (![presets isEqualToArray:self.presets]) { self.presets = presets; [self rebuildChips:self.presetChips values:presets action:@selector(presetTapped:)]; }
    for (NSUInteger i = 0; i < self.modeChips.count; i++) Paint(self.modeChips[i], [modes[i] isEqual:mode], ModeColor(mode));
    for (NSUInteger i = 0; i < self.fanChips.count; i++) Paint(self.fanChips[i], [fans[i] isEqual:a[@"fan_mode"]], HA_ACCENT());
    for (NSUInteger i = 0; i < self.presetChips.count; i++) Paint(self.presetChips[i], [presets[i] isEqual:a[@"preset_mode"]], HA_ACCENT());
}

- (void)modeTapped:(UIButton *)b { [self.host card:self callService:@"climate.set_hvac_mode" data:@{@"entity_id": self.entity, @"hvac_mode": self.modes[b.tag]}]; }
- (void)fanTapped:(UIButton *)b { [self.host card:self callService:@"climate.set_fan_mode" data:@{@"entity_id": self.entity, @"fan_mode": self.fans[b.tag]}]; }
- (void)presetTapped:(UIButton *)b { [self.host card:self callService:@"climate.set_preset_mode" data:@{@"entity_id": self.entity, @"preset_mode": self.presets[b.tag]}]; }

- (void)reload { self.lastHistory = nil; [self tick]; }

- (void)tick {
    if (!self.active || self.loading) return;
    if (self.lastHistory && [[NSDate date] timeIntervalSinceDate:self.lastHistory] < 300) return;
    self.loading = YES;
    NSDate *end = [NSDate date], *start = [end dateByAddingTimeInterval:-3600.0 * [self hours]];
    NSString *path = [NSString stringWithFormat:@"/api/history/period/%@?filter_entity_id=%@&end_time=%@", HA_ISO(start), self.entity, HA_ISO(end)];
    __weak HAClimateDetailCard *ws = self;
    [[HAClient shared] getJSON:path completion:^(id json, NSError *e) {
        HAClimateDetailCard *ss = ws;
        if (!ss) return;
        ss.loading = NO;
        ss.lastHistory = [NSDate date];
        NSArray *rows = Arr(Arr(json).firstObject);
        [ss applyHistory:rows start:start end:end error:e];
    }];
}

- (void)applyHistory:(NSArray *)rows start:(NSDate *)start end:(NSDate *)end error:(NSError *)e {
    self.graphCaption.text = [NSString stringWithFormat:@"LAST %ld HOURS  ·  ━ indoor   ┄ target   shaded = running", (long)[self hours]];
    NSMutableArray *temps = [NSMutableArray array], *targets = [NSMutableArray array], *actions = [NSMutableArray array], *events = [NSMutableArray array];
    NSString *prevMode = nil, *prevAction = nil; id prevTarget = nil;
    NSDate *actionStart = nil;
    for (NSDictionary *r in rows) {
        if (!Dict(r)) continue;
        NSDate *t = HA_ParseISO(r[@"last_changed"]) ?: HA_ParseISO(r[@"last_updated"]);
        if (!t) continue;
        if ([t compare:start] == NSOrderedAscending) t = start;
        NSDictionary *a = Dict(r[@"attributes"]);
        NSString *mode = Str(r[@"state"]);
        if ([mode isEqualToString:@"unavailable"] || [mode isEqualToString:@"unknown"]) continue;
        id cur = a[@"current_temperature"], tgt = a[@"temperature"];
        if ([cur respondsToSelector:@selector(doubleValue)]) [temps addObject:@[t, cur]];
        if ([tgt respondsToSelector:@selector(doubleValue)]) [targets addObject:@[t, tgt]];
        NSString *action = Str(a[@"hvac_action"]) ?: @"";
        if (prevMode && ![mode isEqualToString:prevMode]) [events addObject:@[t, [NSString stringWithFormat:@"Mode changed to %@", Pretty(mode)]]];
        if (prevTarget && tgt && ![tgt isEqual:prevTarget] && [tgt respondsToSelector:@selector(doubleValue)])
            [events addObject:@[t, [NSString stringWithFormat:@"Target set to %.0f°", [tgt doubleValue]]]];
        if (![action isEqualToString:prevAction ?: @""]) {
            if (actionStart && prevAction.length) [actions addObject:@[actionStart, t, prevAction]];
            if ([action isEqualToString:@"cooling"] || [action isEqualToString:@"heating"])
                [events addObject:@[t, [NSString stringWithFormat:@"%@ started", Pretty(action)]]];
            else if ([prevAction isEqualToString:@"cooling"] || [prevAction isEqualToString:@"heating"])
                [events addObject:@[t, [NSString stringWithFormat:@"%@ stopped", Pretty(prevAction)]]];
            actionStart = t;
        }
        prevMode = mode; prevAction = action; if (tgt) prevTarget = tgt;
    }
    if (actionStart && prevAction.length) [actions addObject:@[actionStart, end, prevAction]];
    self.graph.temps = temps; self.graph.targets = targets; self.graph.actions = actions;
    self.graph.start = start; self.graph.end = end;
    [self.graph setNeedsDisplay];

    for (UIView *v in self.log.subviews) [v removeFromSuperview];
    NSDateFormatter *tf = [[NSDateFormatter alloc] init]; tf.dateFormat = @"EEE h:mm a";
    CGFloat y = 0, w = self.log.bounds.size.width ?: 500;
    NSArray *ordered = [[events reverseObjectEnumerator] allObjects];
    if (!ordered.count) ordered = @[@[[NSDate date], e ? [NSString stringWithFormat:@"Could not load history: %@", e.localizedDescription] : @"No changes in this period"]];
    for (NSArray *ev in [ordered subarrayWithRange:NSMakeRange(0, MIN(ordered.count, (NSUInteger)60))]) {
        UILabel *time = [[UILabel alloc] initWithFrame:CGRectMake(0, y, 130, 26)];
        time.text = [tf stringFromDate:ev[0]]; time.font = HA_FONT(15, 0); time.textColor = HA_DIM();
        UILabel *msg = [[UILabel alloc] initWithFrame:CGRectMake(140, y, w - 140, 26)];
        msg.text = ev[1]; msg.font = HA_FONT(16, 0.2); msg.textColor = HA_TEXT();
        [self.log addSubview:time]; [self.log addSubview:msg];
        y += 30;
    }
    self.log.contentSize = CGSizeMake(w, y);
}

@end

#pragma mark - Light members (drawer): one row per bulb with toggle + brightness
// { "type":"light_members", "entity":"light.bedroom", "strip_prefix":"Bedroom " }

@interface HALightMembersCard : HACard
@property (nonatomic, copy) NSString *entity;
@property (nonatomic, strong) NSArray *members;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) NSMutableArray *rows;   // each: @[nameLabel, toggleButton, slider]
@property (nonatomic, strong) NSDate *suppressUntil;
@end

@implementation HALightMembersCard

- (instancetype)initWithSpec:(NSDictionary *)spec host:(id<HACardHost>)host {
    if ((self = [super initWithSpec:spec host:host])) {
        _entity = Str(spec[@"entity"]) ?: @"";
        if (!Str(spec[@"title"])) self.titleLabel.text = @"LIGHTS";
        _scroll = [[UIScrollView alloc] init];
        [self addSubview:_scroll];
        _rows = [NSMutableArray array];
    }
    return self;
}

- (NSArray *)entityIds { return [@[self.entity] arrayByAddingObjectsFromArray:self.members ?: @[]]; }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect c = [self contentRect];
    self.scroll.frame = c;
    CGFloat y = 0, w = c.size.width;
    for (NSArray *row in self.rows) {
        ((UIView *)row[0]).frame = CGRectMake(0, y, w * 0.38, 52);
        ((UIView *)row[1]).frame = CGRectMake(w * 0.38, y + 6, 84, 40);
        ((UIView *)row[2]).frame = CGRectMake(w * 0.38 + 100, y + 9, w - (w * 0.38 + 100), 34);
        y += 60;
    }
    self.scroll.contentSize = CGSizeMake(w, y);
}

- (void)updateStates:(NSDictionary *)states {
    NSArray *members = Arr(states[self.entity][@"attributes"][@"entity_id"]);
    if (members.count && ![members isEqualToArray:self.members]) {
        self.members = members;
        for (NSArray *row in self.rows) for (UIView *v in row) [v removeFromSuperview];
        [self.rows removeAllObjects];
        for (NSUInteger i = 0; i < members.count; i++) {
            UILabel *name = [[UILabel alloc] init];
            name.font = HA_FONT(19, 0.2); name.textColor = HA_TEXT(); name.adjustsFontSizeToFitWidth = YES; name.minimumScaleFactor = 0.6;
            UIButton *toggle = HA_Chip(@"Off", self, @selector(toggleTapped:));
            toggle.tag = i;
            UISlider *slider = [[UISlider alloc] init];
            slider.minimumValue = 1; slider.maximumValue = 100; slider.tag = i;
            slider.minimumTrackTintColor = HA_ACCENT();
            [slider addTarget:self action:@selector(sliderBegan) forControlEvents:UIControlEventTouchDown];
            [slider addTarget:self action:@selector(sliderEnded:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
            [self.scroll addSubview:name]; [self.scroll addSubview:toggle]; [self.scroll addSubview:slider];
            [self.rows addObject:@[name, toggle, slider]];
        }
        [self setNeedsLayout];
        [self.host cardWantsRefresh:self];
    }
    BOOL suppress = self.suppressUntil && [self.suppressUntil timeIntervalSinceNow] > 0;
    for (NSUInteger i = 0; i < self.members.count && i < self.rows.count; i++) {
        NSDictionary *s = states[self.members[i]];
        NSArray *row = self.rows[i];
        NSString *n = Str(s[@"attributes"][@"friendly_name"]) ?: self.members[i];
        NSString *strip = Str(self.spec[@"strip_prefix"]);
        if (strip.length) n = [n stringByReplacingOccurrencesOfString:strip withString:@""];
        ((UILabel *)row[0]).text = n;
        NSString *st = Str(s[@"state"]);
        BOOL on = [st isEqualToString:@"on"], dead = !s || [st isEqualToString:@"unavailable"] || [st isEqualToString:@"unknown"];
        UIButton *b = row[1];
        [b setTitle:dead ? @"–" : (on ? @"On" : @"Off") forState:UIControlStateNormal];
        Paint(b, on, HA_ACCENT());
        b.enabled = !dead;
        UISlider *sl = row[2];
        id bri = s[@"attributes"][@"brightness"];
        sl.enabled = !dead && [bri respondsToSelector:@selector(floatValue)];
        if (!suppress) sl.value = (on && [bri respondsToSelector:@selector(floatValue)]) ? MAX(1, [bri floatValue] / 255.0f * 100.0f) : 1;
        for (UIView *v in row) v.alpha = dead ? 0.35 : 1;
    }
}

- (void)toggleTapped:(UIButton *)b { [self.host card:self callService:@"light.toggle" data:@{@"entity_id": self.members[b.tag]}]; }
- (void)sliderBegan { self.suppressUntil = [NSDate dateWithTimeIntervalSinceNow:60]; }
- (void)sliderEnded:(UISlider *)s {
    self.suppressUntil = [NSDate dateWithTimeIntervalSinceNow:3];
    [self.host card:self callService:@"light.turn_on" data:@{@"entity_id": self.members[s.tag], @"brightness_pct": @((NSInteger)roundf(s.value))}];
}

@end

#pragma mark - Context: "now playing" while music plays, otherwise time/state-based actions
// { "type":"context",
//   "players": ["media_player.bedroom", "media_player.bedroom_speaker"],
//   "player_names": { "media_player.bedroom": "Bedroom" },
//   "items": [
//     { "when": { "after": "20:00", "before": "03:00" }, "title": "Good night", "subtitle": "...",
//       "buttons": [ { "name": "Goodnight", "icon": "🌙", "entity": "script.goodnight", "confirm": true } ] },
//     { "when": { "state": { "entity": "climate.x", "is": "cool" } }, "title": "...", "buttons": [...] } ] }

@interface HAContextCard : HACard
@property (nonatomic, strong) NSDictionary *states;
@property (nonatomic, strong) UIView *nowView, *itemView;
// now playing
@property (nonatomic, strong) UIImageView *art;
@property (nonatomic, strong) UILabel *npCaption, *npTitle, *npArtist, *npTime;   // npTime: time left in the track
@property (nonatomic, strong) UIButton *openArea;            // artwork and titles: tap for the full player
@property (nonatomic, strong) UIButton *prev, *play, *next, *stop;
@property (nonatomic, strong) UISlider *volume;
@property (nonatomic, copy) NSString *player, *artPath;   // player = the speaker (Cast) entity shown and controlled
@property (nonatomic, strong) NSDate *suppressVolume, *optimisticUntil;
@property (nonatomic, assign) BOOL isPlaying;
// items
@property (nonatomic, strong) UILabel *itemTitle, *itemSub;
@property (nonatomic, strong) NSMutableArray *itemButtons;
@property (nonatomic, assign) NSInteger shownItem;   // -2 = nothing yet, -1 = greeting
@property (nonatomic, strong) NSDictionary *shownSpec;
@end

@implementation HAContextCard

- (instancetype)initWithSpec:(NSDictionary *)spec host:(id<HACardHost>)host {
    if ((self = [super initWithSpec:spec host:host])) {
        self.titleLabel.text = @"";
        _shownItem = -2;
        _nowView = [[UIView alloc] init]; [self addSubview:_nowView];
        _itemView = [[UIView alloc] init]; [self addSubview:_itemView];
        _art = [[UIImageView alloc] init];
        _art.backgroundColor = HA_OFF(); _art.layer.cornerRadius = 12; _art.clipsToBounds = YES;
        _art.contentMode = UIViewContentModeScaleAspectFill;
        [_nowView addSubview:_art];
        _openArea = [UIButton buttonWithType:UIButtonTypeCustom];
        [_openArea addTarget:self action:@selector(openPlayer) forControlEvents:UIControlEventTouchUpInside];
        [_nowView addSubview:_openArea];
        _npTime = [self label:15 w:0 c:HA_DIM() in:_nowView];
        _npTime.textAlignment = NSTextAlignmentRight;
        _npCaption = [self label:13 w:0.4 c:HA_BLUE() in:_nowView];
        _npTitle = [self label:26 w:0.3 c:HA_TEXT() in:_nowView];
        _npArtist = [self label:19 w:0 c:HA_DIM() in:_nowView];
        _prev = [self btn:@"◀︎◀︎" sel:@selector(prevTapped) in:_nowView];
        _play = [self btn:@"■" sel:@selector(playTapped) in:_nowView];   // one button: stop while playing, play while stopped
        _next = [self btn:@"▶︎▶︎" sel:@selector(nextTapped) in:_nowView];
        _volume = [[UISlider alloc] init];
        _volume.minimumTrackTintColor = HA_BLUE();
        [_volume addTarget:self action:@selector(volBegan) forControlEvents:UIControlEventTouchDown];
        [_volume addTarget:self action:@selector(volEnded) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
        [_nowView addSubview:_volume];
        _itemTitle = [self label:30 w:0.2 c:HA_TEXT() in:_itemView];
        _itemSub = [self label:18 w:0 c:HA_DIM() in:_itemView];
        _itemSub.numberOfLines = 2;
        _itemButtons = [NSMutableArray array];
        _nowView.hidden = YES;
    }
    return self;
}

- (UILabel *)label:(CGFloat)s w:(CGFloat)w c:(UIColor *)c in:(UIView *)p {
    UILabel *l = [[UILabel alloc] init];
    l.font = HA_FONT(s, w); l.textColor = c; l.adjustsFontSizeToFitWidth = YES; l.minimumScaleFactor = 0.5;
    [p addSubview:l];
    return l;
}

- (UIButton *)btn:(NSString *)t sel:(SEL)sel in:(UIView *)p {
    UIButton *b = HA_Chip(t, self, sel);
    b.titleLabel.font = HA_FONT(26, 0.3);
    b.layer.cornerRadius = 14;
    [p addSubview:b];
    return b;
}

- (NSArray *)entityIds {
    NSMutableOrderedSet *ids = [NSMutableOrderedSet orderedSetWithArray:Arr(self.spec[@"players"])];
    if (Str(self.spec[@"plex_session"])) [ids addObject:self.spec[@"plex_session"]];
    for (NSDictionary *it in Arr(self.spec[@"items"])) {
        NSDictionary *when = Dict(Dict(it)[@"when"]);
        for (id st in ([when[@"state"] isKindOfClass:[NSArray class]] ? when[@"state"] : (when[@"state"] ? @[when[@"state"]] : @[])))
            if (Str(Dict(st)[@"entity"])) [ids addObject:st[@"entity"]];
    }
    return [ids array];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect c = CGRectInset(self.bounds, 20, 16);
    self.nowView.frame = c; self.itemView.frame = c;
    CGFloat W = c.size.width, H = c.size.height;
    // now playing
    if (W < 460) {
        // Narrow tile: picture and titles on top, then three buttons and the volume across the full width.
        CGFloat bh = MIN(52, MAX(40, H * 0.26)), vh = 30, g = H < 190 ? 8 : 12;
        CGFloat art = MAX(44, MIN(MIN(110, W * 0.3), H - bh - vh - 2 * g));
        CGFloat y = MAX(0, (H - art - bh - vh - 2 * g) / 2);
        self.art.frame = CGRectMake(0, y, art, art);
        CGFloat x = art + 14, w = W - x, ty = y + MAX(0, (art - 64) / 2);
        self.npCaption.frame = CGRectMake(x, ty, w, 14);
        self.npTitle.frame = CGRectMake(x, ty + 16, w, 28);
        self.npArtist.frame = CGRectMake(x, ty + 44, w - 54, 20);
        self.npTime.frame = CGRectMake(x + w - 52, ty + 44, 52, 20);
        self.openArea.frame = CGRectMake(0, y, W, art);
        CGFloat bw = (W - 20) / 3, by = y + art + g;
        self.prev.frame = CGRectMake(0, by, bw, bh);
        self.play.frame = CGRectMake(bw + 10, by, bw, bh);
        self.next.frame = CGRectMake(2 * (bw + 10), by, bw, bh);
        self.volume.frame = CGRectMake(0, by + bh + g, W, vh);
    } else {
        CGFloat art = MIN(H, W * 0.32);
        self.art.frame = CGRectMake(0, (H - art) / 2, art, art);
        CGFloat x = art + 20, w = W - x;
        CGFloat y = MAX(0, (H - 180) / 2);
        self.npCaption.frame = CGRectMake(x, y, w, 16);
        self.npTitle.frame = CGRectMake(x, y + 20, w, 32);
        self.npArtist.frame = CGRectMake(x, y + 54, w - 64, 24);
        self.npTime.frame = CGRectMake(x + w - 60, y + 54, 60, 24);
        self.openArea.frame = CGRectMake(0, 0, W, y + 82);
        CGFloat bw = MIN(130, (w - 24) / 3);
        self.prev.frame = CGRectMake(x, y + 88, bw, 52);
        self.play.frame = CGRectMake(x + bw + 12, y + 88, bw, 52);
        self.next.frame = CGRectMake(x + 2 * (bw + 12), y + 88, bw, 52);
        self.volume.frame = CGRectMake(x, y + 148, w, 30);
    }
    for (UIButton *b in @[self.prev, self.play, self.next]) b.titleLabel.font = HA_FONT(b.bounds.size.width < 84 ? 20 : 26, 0.3);
    // items
    NSInteger n = self.itemButtons.count;
    CGFloat btnH = n ? MIN(84, H * 0.42) : 0;
    CGFloat textH = 38 + (self.itemSub.text.length ? 48 : 0);
    CGFloat top = MAX(0, (H - textH - btnH - (n ? 14 : 0)) / 2);
    self.itemTitle.frame = CGRectMake(0, top, W, 38);
    self.itemSub.frame = CGRectMake(0, top + 40, W, 44);
    CGFloat ibw = n ? MIN(260, (W - (n - 1) * 12) / n) : 0;
    for (NSInteger i = 0; i < n; i++) ((UIView *)self.itemButtons[i]).frame = CGRectMake(i * (ibw + 12), top + textH + 14, ibw, btnH);
}

- (void)updateStates:(NSDictionary *)states { self.states = states; [self evaluate]; }
- (void)tick { [self evaluate]; }

static NSInteger Minutes(NSString *hhmm) {
    NSArray *p = [hhmm componentsSeparatedByString:@":"];
    return p.count == 2 ? [p[0] integerValue] * 60 + [p[1] integerValue] : -1;
}

- (BOOL)matches:(NSDictionary *)when {
    if (!when) return YES;
    NSDateComponents *dc = [[NSCalendar currentCalendar] components:NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitWeekday fromDate:[NSDate date]];
    NSInteger now = dc.hour * 60 + dc.minute;
    NSInteger after = Str(when[@"after"]) ? Minutes(when[@"after"]) : -1, before = Str(when[@"before"]) ? Minutes(when[@"before"]) : -1;
    if (after >= 0 && before >= 0) {
        BOOL inside = after <= before ? (now >= after && now < before) : (now >= after || now < before);   // wraps midnight
        if (!inside) return NO;
    } else if (after >= 0 && now < after) return NO;
    else if (before >= 0 && now >= before) return NO;
    NSArray *days = Arr(when[@"days"]);
    if (days.count) {
        NSArray *names = @[@"sun", @"mon", @"tue", @"wed", @"thu", @"fri", @"sat"];
        if (![days containsObject:names[(dc.weekday - 1) % 7]]) return NO;
    }
    for (id st in ([when[@"state"] isKindOfClass:[NSArray class]] ? when[@"state"] : (when[@"state"] ? @[when[@"state"]] : @[]))) {
        NSDictionary *cond = Dict(st);
        NSString *cur = Str(self.states[cond[@"entity"]][@"state"]);
        if (!cur) return NO;
        id is = cond[@"is"], isNot = cond[@"not"];
        if (is && !([is isKindOfClass:[NSArray class]] ? [is containsObject:cur] : [Str(is) isEqualToString:cur])) return NO;
        if (isNot && ([isNot isKindOfClass:[NSArray class]] ? [isNot containsObject:cur] : [Str(isNot) isEqualToString:cur])) return NO;
    }
    return YES;
}

- (void)evaluate {
    // 1) music playing on any watched player wins
    // (playing first; a paused speaker keeps the card so it can be resumed or stopped)
    NSString *playing = nil, *paused = nil;
    for (NSString *p in Arr(self.spec[@"players"])) {
        NSString *st = Str(self.states[p][@"state"]);
        if ([st isEqualToString:@"playing"] || [st isEqualToString:@"buffering"]) { playing = p; break; }
        if (!paused && [st isEqualToString:@"paused"]) paused = p;
    }
    if (!playing) playing = paused;
    if (playing) { [self showNowPlaying:playing]; return; }
    self.player = nil;
    self.nowView.hidden = YES;
    self.itemView.hidden = NO;
    // 2) first matching item, 3) a greeting
    NSArray *items = Arr(self.spec[@"items"]);
    NSInteger pick = -1;
    for (NSUInteger i = 0; i < items.count; i++) if (Dict(items[i]) && [self matches:Dict(items[i][@"when"])]) { pick = i; break; }
    if (pick == self.shownItem) return;
    HA_Fade(self, 0.35);   // cross-dissolve between greeting / goodnight / now playing
    self.shownItem = pick;
    NSDictionary *it = pick >= 0 ? items[pick] : nil;
    self.shownSpec = it;
    NSInteger hour = [[NSCalendar currentCalendar] component:NSCalendarUnitHour fromDate:[NSDate date]];
    NSString *greet = hour < 12 ? @"Good morning" : (hour < 18 ? @"Good afternoon" : @"Good evening");
    self.itemTitle.text = Str(it[@"title"]) ?: greet;
    self.itemSub.text = Str(it[@"subtitle"]) ?: @"";
    for (UIView *b in self.itemButtons) [b removeFromSuperview];
    [self.itemButtons removeAllObjects];
    NSArray *buttons = Arr(it[@"buttons"]);
    for (NSUInteger i = 0; i < buttons.count; i++) {
        NSDictionary *d = Dict(buttons[i]);
        NSString *title = Str(d[@"icon"]) ? [NSString stringWithFormat:@"%@  %@", d[@"icon"], Str(d[@"name"]) ?: @""] : (Str(d[@"name"]) ?: @"?");
        UIButton *b = HA_Chip(title, self, @selector(itemButtonTapped:));
        b.titleLabel.font = HA_FONT(22, 0.3);
        b.layer.cornerRadius = 16;
        b.tag = i;
        [self.itemView addSubview:b];
        [self.itemButtons addObject:b];
    }
    [self setNeedsLayout];
}

- (void)paintPlaying:(BOOL)playing {
    self.isPlaying = playing;
    [self.play setTitle:playing ? @"■" : @"▶︎" forState:UIControlStateNormal];
    HA_SetBG(self.play, playing ? HA_BLUE() : HA_OFF());
}

- (void)showNowPlaying:(NSString *)p {
    if (self.nowView.hidden) HA_Fade(self, 0.35);
    if (![p isEqualToString:self.player]) self.optimisticUntil = nil;
    self.player = p;
    self.nowView.hidden = NO;
    self.itemView.hidden = YES;
    self.shownItem = -2;
    NSDictionary *a = self.states[p][@"attributes"];
    NSString *st = Str(self.states[p][@"state"]);
    BOOL playing = ![st isEqualToString:@"paused"];
    BOOL optimistic = self.optimisticUntil && [self.optimisticUntil timeIntervalSinceNow] > 0;
    if (optimistic && playing == self.isPlaying) { self.optimisticUntil = nil; optimistic = NO; }
    NSString *name = Str(Dict(self.spec[@"player_names"])[p]) ?: Str(a[@"friendly_name"]) ?: p;
    if (!optimistic) {
        [self paintPlaying:playing];
        self.npCaption.text = [[NSString stringWithFormat:@"%@ · %@", playing ? @"Now playing" : @"Stopped", name] uppercaseString];
    }
    self.npTitle.text = Str(a[@"media_title"]) ?: @"";
    self.npArtist.text = Str(a[@"media_artist"]) ?: Str(a[@"media_album_name"]) ?: Str(a[@"app_name"]) ?: @"";
    NSTimeInterval dur = [a[@"media_duration"] isKindOfClass:[NSNumber class]] ? [a[@"media_duration"] doubleValue] : 0, pos = HA_MediaPosition(self.states[p]);
    self.npTime.text = (dur > 0 && pos >= 0) ? [@"-" stringByAppendingString:HA_Clock(dur - pos)] : @"";
    id vol = a[@"volume_level"];
    if ([vol respondsToSelector:@selector(floatValue)] && !(self.suppressVolume && [self.suppressVolume timeIntervalSinceNow] > 0)) self.volume.value = [vol floatValue];
    // artwork: the speaker's own picture, else the Plex session's (plex_session is used for art only)
    NSString *pic = HA_NowPlayingPicture(self.states[p], self.states[Str(self.spec[@"plex_session"]) ?: @""], Str(self.spec[@"plex_server"]));
    if (!(pic == self.artPath || [pic isEqualToString:self.artPath])) {
        self.artPath = pic;
        self.art.image = nil;
        HALog(@"art: %@ [%@] \"%@\" speaker picture %@, plex session [%@] \"%@\", content %@", p, Str(self.states[p][@"state"]), Str(self.states[p][@"attributes"][@"media_title"]) ?: @"", HA_PictureOf(self.states[p]) ? @"yes" : @"no",
              Str(self.states[Str(self.spec[@"plex_session"]) ?: @""][@"state"]) ?: @"-", Str(self.states[Str(self.spec[@"plex_session"]) ?: @""][@"attributes"][@"media_title"]) ?: @"", Str(self.states[p][@"attributes"][@"media_content_id"]) ?: @"-");
        __weak HAContextCard *ws = self;
        if (pic) [[HAClient shared] loadImagePath:pic completion:^(UIImage *img) { if ([pic isEqualToString:ws.artPath]) { HA_Fade(ws.art, 0.3); ws.art.image = img; } }];
    }
}

- (void)media:(NSString *)svc extra:(NSDictionary *)extra {
    if (!self.player) return;
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithObject:self.player forKey:@"entity_id"];
    if (extra) [d addEntriesFromDictionary:extra];
    [self.host card:self callService:[@"media_player." stringByAppendingString:svc] data:d];
}
- (void)prevTapped { if (!HA_QueueSkip(-1, self.player, self.states[self.player ?: @""], self)) [self media:@"media_previous_track" extra:nil]; else self.npCaption.text = @"PREVIOUS…"; }
- (void)nextTapped { if (!HA_QueueSkip(1, self.player, self.states[self.player ?: @""], self)) [self media:@"media_next_track" extra:nil]; else self.npCaption.text = @"NEXT…"; }
// Artwork, title, artist or the caption: open the full player ("opens": drawer or tab name, default Music).
- (void)openPlayer { [self.host card:self openDrawer:Str(self.spec[@"opens"]) ?: @"Music"]; }
- (void)playTapped {
    // One play/stop button. "Stop" pauses the speaker, so the same button can start the music again;
    // the music card's own stop button is the one that ends the Cast session.
    BOOL wasPlaying = self.isPlaying;
    [self paintPlaying:!wasPlaying];
    self.npCaption.text = wasPlaying ? @"STOPPING…" : @"STARTING…";
    self.optimisticUntil = [NSDate dateWithTimeIntervalSinceNow:6];
    [self media:wasPlaying ? @"media_pause" : @"media_play" extra:nil];
}
- (void)volBegan { self.suppressVolume = [NSDate dateWithTimeIntervalSinceNow:60]; }
- (void)volEnded { self.suppressVolume = [NSDate dateWithTimeIntervalSinceNow:3]; [self media:@"volume_set" extra:@{@"volume_level": @(roundf(self.volume.value * 100) / 100.0)}]; }

- (void)itemButtonTapped:(UIButton *)b {
    NSDictionary *d = Dict(Arr(self.shownSpec[@"buttons"])[b.tag]);
    if (!d) return;
    NSString *svc = Str(d[@"service"]);
    NSDictionary *data = Dict(d[@"data"]);
    if (!svc && Str(d[@"entity"])) {
        NSString *ent = d[@"entity"], *domain = [ent componentsSeparatedByString:@"."][0];
        svc = [@[@"script", @"scene"] containsObject:domain] ? [domain stringByAppendingString:@".turn_on"]
            : ([domain isEqualToString:@"automation"] ? @"automation.trigger" : @"homeassistant.toggle");
        data = @{@"entity_id": ent};
    }
    if (!svc) return;
    void (^run)(void) = ^{ [self.host card:self callService:svc data:data ?: @{}]; };
    if ([d[@"confirm"] boolValue]) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:Str(d[@"name"]) message:Str(d[@"confirm_text"]) ?: @"Run this now?" preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [ac addAction:[UIAlertAction actionWithTitle:Str(d[@"name"]) ?: @"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { run(); }]];
        [[UIApplication sharedApplication].keyWindow.rootViewController presentViewController:ac animated:YES completion:nil];
    } else run();
}

@end

#pragma mark - Library: browse Plex (through Home Assistant) and cast to speakers
// { "type":"library", "browse_entity":"media_player.bedroom", "auto_open":["Plex","Music"],
//   "targets":[ {"name":"Bedroom","entity":"media_player.bedroom"},
//               {"name":"All speakers","entity":["media_player.bedroom","media_player.down_stairs"]} ] }

@interface HALibraryCard : HACard
@property (nonatomic, strong) NSMutableArray *path;        // stack of nodes (dicts from browse_media)
@property (nonatomic, strong) NSArray *children;
@property (nonatomic, strong) UIButton *back, *playAll, *shuffleBtn, *repeatBtn;
@property (nonatomic, assign) BOOL shuffle, repeat;        // play options, remembered between launches
@property (nonatomic, strong) UILabel *where, *status;
@property (nonatomic, strong) UISegmentedControl *targets;
@property (nonatomic, strong) UIScrollView *grid;
@property (nonatomic, strong) NSMutableArray *tiles;
@property (nonatomic, assign) NSUInteger autoOpened;
@property (nonatomic, assign) BOOL loading, loadedOnce;
@property (nonatomic, strong) NSDictionary *states;
@property (nonatomic, strong) NSDate *lastAttempt;
@property (nonatomic, assign) NSInteger navDirection;   // +1 forward, -1 back, 0 none (for the push animation)
@end

@implementation HALibraryCard

- (instancetype)initWithSpec:(NSDictionary *)spec host:(id<HACardHost>)host {
    if ((self = [super initWithSpec:spec host:host])) {
        self.titleLabel.text = @"";
        _path = [NSMutableArray array];
        _tiles = [NSMutableArray array];
        _back = [self addButton:@"‹ Back" size:17 action:@selector(backTapped)];
        _playAll = [self addButton:@"▶︎  Play all" size:17 action:@selector(playAllTapped)];
        _playAll.backgroundColor = HA_BLUE();
        _shuffleBtn = [self addButton:@"🔀" size:20 action:@selector(shuffleTapped)];
        _repeatBtn = [self addButton:@"🔁" size:20 action:@selector(repeatTapped)];
        _shuffle = [[NSUserDefaults standardUserDefaults] boolForKey:@"music.shuffle"];
        _repeat = [[NSUserDefaults standardUserDefaults] boolForKey:@"music.repeat"];
        [self paintOptions];
        _where = [self addLabel:22 weight:0.3 color:HA_TEXT()];
        _status = [self addLabel:15 weight:0 color:HA_DIM()];
        NSMutableArray *names = [NSMutableArray array];
        for (NSDictionary *t in Arr(spec[@"targets"])) [names addObject:Str(Dict(t)[@"name"]) ?: @"?"];
        if (names.count) {
            _targets = [[UISegmentedControl alloc] initWithItems:names];
            _targets.selectedSegmentIndex = 0;
            _targets.tintColor = HA_BLUE();
            [self addSubview:_targets];
        }
        _grid = [[UIScrollView alloc] init];
        _grid.alwaysBounceVertical = YES;
        [self addSubview:_grid];
    }
    return self;
}

// "browse_entity" may be one entity or a list; the first one Home Assistant reports as available is used.
- (NSArray *)browseCandidates {
    id b = self.spec[@"browse_entity"];
    NSMutableArray *c = [NSMutableArray array];
    if (Str(b)) [c addObject:b];
    for (id e in Arr(b)) if (Str(e)) [c addObject:e];
    for (NSDictionary *t in Arr(self.spec[@"targets"])) { id e = Dict(t)[@"entity"]; if (Str(e)) [c addObject:e]; }
    return c;
}

- (NSString *)browseEntity {
    for (NSString *e in [self browseCandidates]) {
        NSString *st = Str(self.states[e][@"state"]);
        if (st && ![st isEqualToString:@"unavailable"]) return e;
    }
    return nil;
}

- (NSArray *)entityIds {
    NSMutableOrderedSet *s = [NSMutableOrderedSet orderedSetWithArray:[self browseCandidates]];
    for (NSDictionary *t in Arr(self.spec[@"targets"])) { id e = Dict(t)[@"entity"]; for (id x in (Str(e) ? @[e] : Arr(e))) [s addObject:x]; }
    return [s array];
}

- (void)updateStates:(NSDictionary *)states {
    self.states = states;
    // grey out targets that are offline
    NSArray *targets = Arr(self.spec[@"targets"]);
    for (NSUInteger i = 0; i < targets.count && i < self.targets.numberOfSegments; i++) {
        id e = Dict(targets[i])[@"entity"];
        BOOL any = NO;
        for (id x in (Str(e) ? @[e] : Arr(e))) if (![Str(states[x][@"state"]) ?: @"unavailable" isEqualToString:@"unavailable"]) any = YES;
        [self.targets setEnabled:any forSegmentAtIndex:i];
    }
}

// Pages are cached on disk (key = entity + content id). A cached page shows instantly; it's refreshed
// in the background when older than 10 minutes. The Music drawer preloads the first page at startup.
- (NSString *)cacheKeyFor:(NSDictionary *)node {
    return [NSString stringWithFormat:@"browse|%@|%@", Str(node[@"media_content_type"]) ?: @"", Str(node[@"media_content_id"]) ?: @"root"];
}

- (void)reload { if (!self.loadedOnce) [self load]; }   // also runs while the drawer is closed = preload
- (void)tick {
    if (self.loadedOnce || self.loading) return;
    if (self.lastAttempt && [[NSDate date] timeIntervalSinceDate:self.lastAttempt] < 10) return;   // retry every 10 s
    [self load];
}

- (void)applyResponse:(NSDictionary *)resp fromCache:(BOOL)cached {
    if (self.path.count) {   // keep the node's own flags (can_play, children_media_class) from the response
        NSMutableDictionary *n = [self.path.lastObject mutableCopy];
        [n addEntriesFromDictionary:resp];
        [n removeObjectForKey:@"children"];
        self.path[self.path.count - 1] = n;
    }
    self.children = HA_CleanList(Arr(resp[@"children"]));
    // auto_open: descend into e.g. "Plex" then "Music" on first load
    NSArray *auto_ = Arr(self.spec[@"auto_open"]);
    if (self.autoOpened < auto_.count) {
        NSString *want = [Str(auto_[self.autoOpened]) lowercaseString];
        for (NSDictionary *ch in self.children) {
            if ([[Str(ch[@"title"]) lowercaseString] rangeOfString:want].location != NSNotFound && [ch[@"can_expand"] boolValue]) {
                self.autoOpened++;
                [self.path addObject:ch];
                [self load];
                return;
            }
        }
        self.autoOpened = auto_.count;   // not found; stop trying
    }
    [self rebuildTiles];
}

- (void)load {
    self.lastAttempt = [NSDate date];
    NSDictionary *node = self.path.lastObject;
    NSString *key = [self cacheKeyFor:node];
    HAClient *ha = [HAClient shared];

    // 1) cached copy first (any age) so the page appears immediately
    NSData *cached = [ha cachedJSONForKey:key maxAge:0];
    NSDictionary *cresp = cached ? Dict([NSJSONSerialization JSONObjectWithData:cached options:0 error:nil]) : nil;
    BOOL fresh = [ha cachedJSONForKey:key maxAge:600] != nil;
    if (cresp) {
        self.loadedOnce = YES;
        self.status.text = @"";
        NSUInteger before = self.path.count;
        [self applyResponse:cresp fromCache:YES];
        if (self.path.count != before) return;   // auto_open descended; that load handles the rest
        if (fresh) return;                         // recent enough: skip the network
    }

    // 2) refresh from Home Assistant
    if (!self.states) { if (!cresp) self.status.text = @"Loading…"; return; }   // wait for the first state poll
    NSString *entity = [self browseEntity];
    if (!entity) {
        if (!cresp) self.status.text = @"Speakers are offline in Home Assistant — Cast devices can't be reached (retrying)";
        return;
    }
    self.loading = YES;
    if (!cresp) self.status.text = @"Loading…";
    NSMutableDictionary *data = [NSMutableDictionary dictionaryWithObject:entity forKey:@"entity_id"];
    if (Str(node[@"media_content_id"])) data[@"media_content_id"] = node[@"media_content_id"];
    if (Str(node[@"media_content_type"])) data[@"media_content_type"] = node[@"media_content_type"];
    NSDate *started = [NSDate date];
    __weak HALibraryCard *ws = self;
    [ha callServiceWithResponse:@"media_player" service:@"browse_media" data:data completion:^(id json, NSError *e) {
        HALibraryCard *ss = ws;
        if (!ss) return;
        ss.loading = NO;
        NSDictionary *resp = Dict(Dict(Dict(json)[@"service_response"])[entity]);
        if (!resp) { if (!cresp) ss.status.text = [NSString stringWithFormat:@"Could not browse: %@", e.localizedDescription ?: @"no response"]; return; }
        NSArray *kids = Arr(resp[@"children"]);
        NSDictionary *k0 = Dict(kids.firstObject);
        HALog(@"browse %@ '%@': %lu items in %.1fs, child class %@, thumb %@", entity, Str(resp[@"title"]) ?: @"",
              (unsigned long)kids.count, -[started timeIntervalSinceNow], Str(resp[@"children_media_class"]) ?: Str(k0[@"media_class"]) ?: @"?",
              [[Str(k0[@"thumbnail"]) ?: @"none" componentsSeparatedByString:@"?"] firstObject]);
        NSData *raw = [NSJSONSerialization dataWithJSONObject:resp options:0 error:nil];
        [[HAClient shared] storeJSON:raw forKey:key];
        if (![[ss cacheKeyFor:ss.path.lastObject] isEqualToString:key]) return;   // user navigated away meanwhile
        ss.loadedOnce = YES;
        ss.status.text = @"";
        if (cresp && [raw isEqualToData:cached]) return;   // nothing changed
        ss.navDirection = 0;
        [ss applyResponse:resp fromCache:NO];
    }];
}

// Tracks (album / playlist contents) are shown as a list; everything else as an artwork grid.
- (BOOL)listMode {
    NSString *cls = Str(self.path.lastObject[@"children_media_class"]);
    if ([cls isEqualToString:@"track"] || [cls isEqualToString:@"episode"]) return YES;
    NSUInteger tracks = 0;
    for (NSDictionary *ch in self.children) if ([Str(ch[@"media_class"]) isEqualToString:@"track"]) tracks++;
    return self.children.count && tracks * 2 > self.children.count;
}

static UIColor *TileColor(NSString *title) {   // stable muted colour per title for placeholders
    NSUInteger h = [title hash];
    return [UIColor colorWithHue:(h % 360) / 360.0 saturation:0.35 brightness:0.38 alpha:1];
}

- (void)rebuildTiles {
    for (UIView *v in self.tiles) [v removeFromSuperview];
    [self.tiles removeAllObjects];
    BOOL list = [self listMode];
    for (NSUInteger i = 0; i < self.children.count; i++) {
        NSDictionary *ch = Dict(self.children[i]);
        NSString *title = Str(ch[@"title"]) ?: @"";
        UIButton *tile = [UIButton buttonWithType:UIButtonTypeCustom];
        tile.tag = i;
        [tile addTarget:self action:@selector(tileTapped:) forControlEvents:UIControlEventTouchUpInside];
        HA_AddPress(tile);
        if (list) {
            tile.backgroundColor = (i % 2) ? [UIColor clearColor] : [HA_OFF() colorWithAlphaComponent:0.35];
            tile.layer.cornerRadius = 8;
            UILabel *num = [[UILabel alloc] init];
            num.text = [NSString stringWithFormat:@"%lu", (unsigned long)i + 1];
            num.font = HA_FONT(15, 0); num.textColor = HA_DIM(); num.textAlignment = NSTextAlignmentRight; num.tag = 9004;
            UILabel *name = [[UILabel alloc] init];
            name.text = title; name.font = HA_FONT(18, 0.2); name.textColor = HA_TEXT(); name.tag = 9002;
            name.lineBreakMode = NSLineBreakByTruncatingTail;
            UILabel *play = [[UILabel alloc] init];
            play.text = [ch[@"can_expand"] boolValue] ? @"›" : @"▶︎";
            play.font = HA_FONT(18, 0); play.textColor = HA_BLUE(); play.textAlignment = NSTextAlignmentCenter; play.tag = 9005;
            for (UILabel *l in @[num, name, play]) { l.userInteractionEnabled = NO; [tile addSubview:l]; }
        } else {
            UIImageView *img = [[UIImageView alloc] init];
            img.backgroundColor = TileColor(title); img.layer.cornerRadius = 10; img.clipsToBounds = YES;
            img.contentMode = UIViewContentModeScaleAspectFill; img.userInteractionEnabled = NO; img.tag = 9001;
            UILabel *initials = [[UILabel alloc] init];   // shown until (or instead of) the artwork
            initials.text = title.length ? [[title substringToIndex:MIN((NSUInteger)2, title.length)] uppercaseString] : @"♫";
            initials.textAlignment = NSTextAlignmentCenter; initials.font = HA_FONT(30, 0.3);
            initials.textColor = [UIColor colorWithWhite:1 alpha:0.75]; initials.tag = 9003; initials.userInteractionEnabled = NO;
            UILabel *name = [[UILabel alloc] init];
            name.text = title; name.numberOfLines = 2; name.textAlignment = NSTextAlignmentCenter;
            name.lineBreakMode = NSLineBreakByTruncatingTail;
            name.font = HA_FONT(13, 0.2); name.textColor = HA_TEXT(); name.tag = 9002; name.userInteractionEnabled = NO;
            [tile addSubview:img]; [tile addSubview:initials]; [tile addSubview:name];
            NSString *thumb = Str(ch[@"thumbnail"]);
            if (thumb.length) {
                __weak UIImageView *wimg = img; __weak UILabel *wi = initials;
                [[HAClient shared] loadImagePath:thumb completion:^(UIImage *im) { if (im) { HA_Fade(wimg, 0.2); wimg.image = im; wi.hidden = YES; } }];
            }
        }
        [self.grid addSubview:tile];
        [self.tiles addObject:tile];
    }
    NSDictionary *node = self.path.lastObject;
    self.where.text = Str(node[@"title"]) ?: @"Library";
    self.back.hidden = self.path.count == 0;
    self.playAll.hidden = ![node[@"can_play"] boolValue];
    if (!self.children.count && !self.status.text.length) self.status.text = @"Empty";
    [self.grid setContentOffset:CGPointZero animated:NO];
    if (self.navDirection) {   // classic navigation-controller push / pop
        CATransition *t = [CATransition animation];
        t.type = kCATransitionPush;
        t.subtype = self.navDirection > 0 ? kCATransitionFromRight : kCATransitionFromLeft;
        t.duration = 0.28;
        t.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [self.grid.layer addAnimation:t forKey:@"nav"];
        [self.where.layer addAnimation:[t copy] forKey:@"nav"];
        self.navDirection = 0;
    }
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect c = CGRectInset(self.bounds, 20, 16);
    CGFloat x = c.origin.x;
    if (!self.back.hidden) { self.back.frame = CGRectMake(x, c.origin.y, 90, 40); x += 100; }
    CGFloat tw = self.targets ? MIN(300, c.size.width * 0.4) : 0;
    self.targets.frame = CGRectMake(CGRectGetMaxX(c) - tw, c.origin.y + 5, tw, 30);
    CGFloat pw = self.playAll.hidden ? 0 : 130;
    self.playAll.frame = CGRectMake(CGRectGetMaxX(c) - tw - (tw ? 12 : 0) - pw, c.origin.y, pw, 40);
    CGFloat ox = CGRectGetMaxX(c) - tw - (tw ? 12 : 0) - pw - (pw ? 8 : 0) - 104;   // shuffle and repeat, left of Play all
    self.shuffleBtn.frame = CGRectMake(ox, c.origin.y, 48, 40);
    self.repeatBtn.frame = CGRectMake(ox + 56, c.origin.y, 48, 40);
    self.where.frame = CGRectMake(x, c.origin.y, ox - x - 12, 40);
    self.status.frame = CGRectMake(c.origin.x, c.origin.y + 46, c.size.width, 20);
    self.grid.frame = CGRectMake(c.origin.x, c.origin.y + 70, c.size.width, c.size.height - 70);
    CGFloat W = c.size.width;
    if ([self listMode]) {
        CGFloat rowH = 48;
        for (NSUInteger i = 0; i < self.tiles.count; i++) {
            UIButton *t = self.tiles[i];
            t.bounds = CGRectMake(0, 0, W, rowH - 4);
            t.center = CGPointMake(W / 2, i * rowH + (rowH - 4) / 2);
            [t viewWithTag:9004].frame = CGRectMake(0, 0, 36, rowH - 4);
            [t viewWithTag:9002].frame = CGRectMake(48, 0, W - 48 - 50, rowH - 4);
            [t viewWithTag:9005].frame = CGRectMake(W - 44, 0, 36, rowH - 4);
        }
        self.grid.contentSize = CGSizeMake(W, self.tiles.count * rowH);
        return;
    }
    // grid: fixed-size cells; title area is a fixed two lines so rows never overlap or leave gaps
    NSInteger cols = MAX(2, Int(self.spec[@"columns"], (NSInteger)(W / 140)));
    CGFloat gap = 14, w = floor((W - (cols - 1) * gap) / cols), labelH = 34, h = w + 6 + labelH;
    for (NSUInteger i = 0; i < self.tiles.count; i++) {
        UIButton *t = self.tiles[i];
        t.bounds = CGRectMake(0, 0, w, h);
        t.center = CGPointMake((i % cols) * (w + gap) + w / 2, (i / cols) * (h + gap) + h / 2);
        [t viewWithTag:9001].frame = CGRectMake(0, 0, w, w);
        [t viewWithTag:9003].frame = CGRectMake(0, 0, w, w);
        [t viewWithTag:9002].frame = CGRectMake(0, w + 6, w, labelH);
    }
    NSUInteger rows = (self.tiles.count + cols - 1) / cols;
    self.grid.contentSize = CGSizeMake(W, rows * (h + gap));
}

- (void)tileTapped:(UIButton *)b {
    NSDictionary *ch = Dict(self.children[b.tag]);
    if ([ch[@"can_expand"] boolValue]) {
        [self.path addObject:ch];
        self.navDirection = 1;
        [self load];
    } else if ([ch[@"can_play"] boolValue]) {
        // A song inside an album or playlist plays the whole thing from that song on.
        NSDictionary *parent = self.path.lastObject;
        BOOL track = [Str(ch[@"media_class"]) isEqualToString:@"track"] || [Str(ch[@"media_content_type"]) isEqualToString:@"track"];
        [self play:(track && [parent[@"can_play"] boolValue]) ? parent : ch startingAt:track ? ch : nil];
    }
}

- (void)backTapped {
    if (!self.path.count) return;
    [self.path removeLastObject];
    self.navDirection = -1;
    self.autoOpened = Arr(self.spec[@"auto_open"]).count;   // don't auto-descend again
    [self load];
}

- (void)playAllTapped { if (self.path.lastObject) [self play:self.path.lastObject startingAt:nil]; }

#pragma mark play options and queues

- (void)paintOptions {
    HA_SetBG(self.shuffleBtn, self.shuffle ? HA_BLUE() : HA_OFF());
    HA_SetBG(self.repeatBtn, self.repeat ? HA_BLUE() : HA_OFF());
}

// Speakers selected as the target that Home Assistant can reach.
- (NSArray *)onlineTargets {
    NSArray *targets = Arr(self.spec[@"targets"]);
    NSInteger i = self.targets ? self.targets.selectedSegmentIndex : 0;
    id entity = (i >= 0 && i < (NSInteger)targets.count) ? Dict(targets[i])[@"entity"] : [self browseEntity];
    NSMutableArray *online = [NSMutableArray array];
    for (NSString *e in (Str(entity) ? @[entity] : Arr(entity))) if (![Str(self.states[e][@"state"]) ?: @"unavailable" isEqualToString:@"unavailable"]) [online addObject:e];
    return online;
}

// Players that have their own shuffle / repeat switch (Spotify, Music Assistant, Sonos...) get it set
// directly, so the option also applies to what is already playing. Cast speakers have none: for
// those the option is built into the queue when playback starts.
- (void)sendOption:(NSString *)service data:(NSDictionary *)data feature:(NSInteger)bit {
    for (NSString *e in [self onlineTargets]) {
        if (!(Int(self.states[e][@"attributes"][@"supported_features"], 0) & bit)) continue;
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:data];
        d[@"entity_id"] = e;
        [self.host card:self callService:service data:d];
    }
}

- (void)shuffleTapped {
    self.shuffle = !self.shuffle;
    [[NSUserDefaults standardUserDefaults] setBool:self.shuffle forKey:@"music.shuffle"];
    [self paintOptions];
    self.status.text = self.shuffle ? @"Shuffle on: applies to what you play next" : @"Shuffle off";
    [self sendOption:@"media_player.shuffle_set" data:@{@"shuffle": @(self.shuffle)} feature:32768];
}

- (void)repeatTapped {
    self.repeat = !self.repeat;
    [[NSUserDefaults standardUserDefaults] setBool:self.repeat forKey:@"music.repeat"];
    [self paintOptions];
    self.status.text = self.repeat ? @"Repeat on: applies to what you play next" : @"Repeat off";
    [self sendOption:@"media_player.repeat_set" data:@{@"repeat": self.repeat ? @"all" : @"off"} feature:262144];
}

// "plex://<server id>/<number>" -> the number
static NSString *PlexKey(NSDictionary *node) {
    NSString *cid = Str(node[@"media_content_id"]);
    if (![cid hasPrefix:@"plex://"]) return nil;
    NSString *last = [[[cid componentsSeparatedByString:@"?"] firstObject] lastPathComponent];
    return (last.length && [last rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound) ? last : nil;
}

// Play a container (album, playlist, artist) or a single item. With a start item the whole container
// is queued and playback begins at that item. For Plex the queue is made on the Plex server (a "play
// queue": start item, shuffle and repeat are all part of it) and Home Assistant is told to play that
// queue. The server address and access come from the artwork links Home Assistant already hands out.
// Anything else is played through Home Assistant as is.
- (void)play:(NSDictionary *)node startingAt:(NSDictionary *)start {
    if (!Str(node[@"media_content_id"])) return;
    NSString *key = PlexKey(node), *startKey = start ? PlexKey(start) : nil;
    NSURLComponents *thumb = [NSURLComponents componentsWithString:Str(node[@"thumbnail"]) ?: Str(start[@"thumbnail"]) ?: @""];
    NSString *token = nil;
    for (NSURLQueryItem *q in thumb.queryItems ?: @[]) if ([q.name isEqualToString:@"X-Plex-Token"]) token = q.value;
    NSString *server = [NSURL URLWithString:Str(node[@"media_content_id"])].host;
    BOOL needQueue = start || self.shuffle || self.repeat;
    if (!needQueue || !key || (start && !startKey) || !token.length || !thumb.host || !server.length) {
        // Not Plex (or nothing to queue): the tapped item itself, shuffled by Home Assistant where it can.
        NSDictionary *item = start ?: node;
        NSString *cid = item[@"media_content_id"];
        if (!start && self.shuffle && [cid hasPrefix:@"plex://"]) cid = [cid stringByAppendingString:[cid rangeOfString:@"?"].location == NSNotFound ? @"?shuffle=1" : @"&shuffle=1"];
        [self sendPlay:cid type:Str(item[@"media_content_type"]) ?: @"music" title:Str(item[@"title"]) ?: @""];
        return;
    }
    BOOL playlist = [Str(node[@"media_content_type"]) isEqualToString:@"playlist"] || [Str(node[@"media_class"]) isEqualToString:@"playlist"];
    NSURLComponents *u = [[NSURLComponents alloc] init];
    u.scheme = thumb.scheme; u.host = thumb.host; u.port = thumb.port; u.path = @"/playQueues";
    NSMutableArray *q = [NSMutableArray arrayWithArray:@[
        [NSURLQueryItem queryItemWithName:@"type" value:@"audio"],
        [NSURLQueryItem queryItemWithName:@"shuffle" value:self.shuffle ? @"1" : @"0"],
        [NSURLQueryItem queryItemWithName:@"repeat" value:self.repeat ? @"1" : @"0"],
        [NSURLQueryItem queryItemWithName:@"continuous" value:@"0"],
        [NSURLQueryItem queryItemWithName:@"includeRelated" value:@"0"]]];
    if (playlist) [q addObject:[NSURLQueryItem queryItemWithName:@"playlistID" value:key]];
    else [q addObject:[NSURLQueryItem queryItemWithName:@"uri" value:[NSString stringWithFormat:@"server://%@/com.plexapp.plugins.library/library/metadata/%@", server, key]]];
    if (startKey) [q addObject:[NSURLQueryItem queryItemWithName:@"key" value:[@"/library/metadata/" stringByAppendingString:startKey]]];
    u.queryItems = q;
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:DePlexDirectURL(u.string)] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10];
    r.HTTPMethod = @"POST";
    [r setValue:token forHTTPHeaderField:@"X-Plex-Token"];
    [r setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [r setValue:@"hapanel" forHTTPHeaderField:@"X-Plex-Client-Identifier"];
    NSString *title = Str((start ?: node)[@"title"]) ?: @"";
    self.status.text = [NSString stringWithFormat:@"Queuing %@…", Str(node[@"title"]) ?: @""];
    __weak HALibraryCard *ws = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        id qid = [json isKindOfClass:[NSDictionary class]] ? Dict(json[@"MediaContainer"])[@"playQueueID"] : nil;
        NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
        dispatch_async(dispatch_get_main_queue(), ^{
            HALibraryCard *ss = ws;
            if (!ss) return;
            if (![qid respondsToSelector:@selector(integerValue)]) {
                HALog(@"plex queue failed (%ld %@): playing the item on its own", (long)code, err.localizedDescription ?: @"");
                NSDictionary *item = start ?: node;
                [ss sendPlay:item[@"media_content_id"] type:Str(item[@"media_content_type"]) ?: @"music" title:title];
                return;
            }
            NSMutableArray *keys = [NSMutableArray array];
            for (id m in Arr(Dict(json[@"MediaContainer"])[@"Metadata"])) { NSString *k = Str(Dict(m)[@"ratingKey"]); if (k) [keys addObject:k]; }
            NSURLComponents *b = [[NSURLComponents alloc] init];
            b.scheme = r.URL.scheme; b.host = r.URL.host; b.port = r.URL.port;
            HA_QueueRemember(@{@"keys": keys, @"base": b.string ?: @"", @"token": token, @"server": server, @"repeat": @(ss.repeat)});
            HALog(@"plex queue %ld: %@ from \"%@\"%@%@", (long)[qid integerValue], Str(node[@"title"]) ?: @"", title, ss.shuffle ? @", shuffled" : @"", ss.repeat ? @", repeating" : @"");
            [ss sendPlay:[NSString stringWithFormat:@"plex://{\"playqueue_id\": %ld}", (long)[qid integerValue]] type:@"music" title:title];
        });
    }] resume];
}

- (void)sendPlay:(NSString *)contentId type:(NSString *)type title:(NSString *)title {
    NSDictionary *node = @{@"media_content_id": contentId ?: @"", @"media_content_type": type ?: @"music", @"title": title ?: @""};
    NSArray *targets = Arr(self.spec[@"targets"]);
    NSInteger i = self.targets ? self.targets.selectedSegmentIndex : 0;
    id entity = (i >= 0 && i < (NSInteger)targets.count) ? Dict(targets[i])[@"entity"] : [self browseEntity];
    NSString *tname = (i >= 0 && i < (NSInteger)targets.count) ? Str(Dict(targets[i])[@"name"]) : @"speaker";
    if (!entity || !Str(node[@"media_content_id"])) return;
    // Only send to speakers HA can reach; say how many that is, so "All speakers" isn't silently "Bedroom".
    NSArray *wanted = Str(entity) ? @[entity] : Arr(entity);
    NSMutableArray *online = [NSMutableArray array];
    for (NSString *e in wanted) if (![Str(self.states[e][@"state"]) ?: @"unavailable" isEqualToString:@"unavailable"]) [online addObject:e];
    if (!online.count) { self.status.text = [NSString stringWithFormat:@"%@ is offline in Home Assistant", tname]; return; }
    [self.host card:self callService:@"media_player.play_media" data:@{@"entity_id": online.count == 1 ? online[0] : online,
                                                                      @"media_content_id": node[@"media_content_id"],
                                                                      @"media_content_type": Str(node[@"media_content_type"]) ?: @"music"}];
    NSString *count = wanted.count > 1 ? [NSString stringWithFormat:@" (%lu of %lu online)", (unsigned long)online.count, (unsigned long)wanted.count] : @"";
    self.status.text = [NSString stringWithFormat:@"▶︎  %@ → %@%@", Str(node[@"title"]) ?: @"", tname, count];
    HALog(@"play_media %@ -> %@", Str(node[@"title"]) ?: @"", [online componentsJoinedByString:@","]);
    HA_SetPendingPlay(online, Str(node[@"title"]) ?: @"");   // other cards show "Starting…" until the speaker reports playing
}

@end

#pragma mark - Weather detail (drawer): 10-day list + per-day deep look with hourly graph
// { "type":"weather_detail", "entity":"weather.forecast_home", "days":10 }

@interface HAWeatherDetailCard : HACard
@property (nonatomic, copy) NSString *entity;
@property (nonatomic, strong) NSArray *daily, *hourly;
@property (nonatomic, strong) NSDictionary *current, *units;
@property (nonatomic, strong) UIScrollView *list;
@property (nonatomic, strong) NSMutableArray *dayRows;
@property (nonatomic, strong) UIView *detail;
@property (nonatomic, strong) UILabel *dIcon, *dTitle, *dCond, *dTemps, *hourCaption;
@property (nonatomic, strong) NSMutableArray *facts;   // UILabel pairs
@property (nonatomic, strong) HAGraphView *graph;
@property (nonatomic, strong) UIScrollView *hours;
@property (nonatomic, assign) NSInteger selected;
@property (nonatomic, strong) NSDate *lastLoad;
@end

@implementation HAWeatherDetailCard

- (instancetype)initWithSpec:(NSDictionary *)spec host:(id<HACardHost>)host {
    if ((self = [super initWithSpec:spec host:host])) {
        _entity = Str(spec[@"entity"]) ?: @"weather.forecast_home";
        if (!Str(spec[@"title"])) self.titleLabel.text = @"FORECAST";
        _list = [[UIScrollView alloc] init];
        [self addSubview:_list];
        _dayRows = [NSMutableArray array];
        _detail = [[UIView alloc] init];
        [self addSubview:_detail];
        _dIcon = [self lbl:64 w:0 c:HA_TEXT()];
        _dTitle = [self lbl:15 w:0.4 c:HA_DIM()];
        _dCond = [self lbl:26 w:0.3 c:HA_TEXT()];
        _dTemps = [self lbl:22 w:0 c:HA_TEXT()];
        _hourCaption = [self lbl:13 w:0.4 c:HA_DIM()];
        _facts = [NSMutableArray array];
        _graph = [[HAGraphView alloc] init];
        [_detail addSubview:_graph];
        _hours = [[UIScrollView alloc] init];
        _hours.showsHorizontalScrollIndicator = NO;
        [_detail addSubview:_hours];
    }
    return self;
}

- (UILabel *)lbl:(CGFloat)s w:(CGFloat)w c:(UIColor *)c {
    UILabel *l = [[UILabel alloc] init];
    l.font = HA_FONT(s, w); l.textColor = c; l.adjustsFontSizeToFitWidth = YES; l.minimumScaleFactor = 0.5;
    [self.detail addSubview:l];
    return l;
}

- (NSArray *)entityIds { return @[self.entity]; }
- (void)updateStates:(NSDictionary *)states { if (states[self.entity]) self.current = states[self.entity]; }

- (void)reload { self.lastLoad = nil; [self tick]; }

- (void)tick {
    if (!self.active || (self.lastLoad && [[NSDate date] timeIntervalSinceDate:self.lastLoad] < 900)) return;
    self.lastLoad = [NSDate date];
    __weak HAWeatherDetailCard *ws = self;
    // Preferred source: /local/hapanel/forecast.json (10 days daily + hourly, written by Home Assistant from
    // Open-Meteo, see ha/hapanel/fetch_forecast.py). If it's missing, fall back to the weather entity.
    [[HAClient shared] fetchPanelFile:@"forecast.json" completion:^(NSData *data, NSError *error) {
        HAWeatherDetailCard *ss = ws;
        NSDictionary *f = data ? Dict([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]) : nil;
        NSArray *daily = HA_CleanList(Arr(f[@"daily"]));
        if (daily.count) {
            ss.units = Dict(f[@"units"]);
            ss.daily = [daily subarrayWithRange:NSMakeRange(0, MIN(daily.count, (NSUInteger)MAX(1, Int(ss.spec[@"days"], 10))))];
            ss.hourly = HA_CleanList(Arr(f[@"hourly"]));
            [ss buildList];
            [ss showDay:ss.selected animated:NO];
            return;
        }
        [ss loadFromEntity];
    }];
}

- (void)loadFromEntity {
    __weak HAWeatherDetailCard *ws = self;
    for (NSString *type in @[@"daily", @"hourly"]) {
        [[HAClient shared] callServiceWithResponse:@"weather" service:@"get_forecasts" data:@{@"entity_id": self.entity, @"type": type} completion:^(id json, NSError *e) {
            HAWeatherDetailCard *ss = ws;
            NSArray *fc = HA_CleanList(Arr(Dict(Dict(Dict(json)[@"service_response"])[ss.entity])[@"forecast"]));
            if ([type isEqualToString:@"daily"]) { ss.daily = [fc subarrayWithRange:NSMakeRange(0, MIN(fc.count, (NSUInteger)MAX(1, Int(ss.spec[@"days"], 10))))]; [ss buildList]; }
            else ss.hourly = fc;
            [ss showDay:ss.selected animated:NO];
        }];
    }
}

- (NSString *)dayName:(NSDictionary *)d index:(NSUInteger)i full:(BOOL)lng {
    if (i == 0) return @"Today";
    if (i == 1 && lng) return @"Tomorrow";
    NSDate *date = HA_ParseISO(Str(d[@"datetime"]));
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = lng ? @"EEEE, MMMM d" : @"EEE d";
    return date ? [f stringFromDate:date] : @"";
}

- (void)buildList {
    for (UIView *v in self.dayRows) [v removeFromSuperview];
    [self.dayRows removeAllObjects];
    for (NSUInteger i = 0; i < self.daily.count; i++) {
        NSDictionary *d = Dict(self.daily[i]);
        UIButton *row = [UIButton buttonWithType:UIButtonTypeCustom];
        row.tag = i;
        row.layer.cornerRadius = 12;
        [row addTarget:self action:@selector(rowTapped:) forControlEvents:UIControlEventTouchUpInside];
        NSArray *texts = @[[self dayName:d index:i full:NO], HA_WeatherGlyph(Str(d[@"condition"])),
                           [NSString stringWithFormat:@"%.0f°", [d[@"temperature"] doubleValue]],
                           d[@"templow"] ? [NSString stringWithFormat:@"%.0f°", [d[@"templow"] doubleValue]] : @"",
                           [d[@"precipitation_probability"] respondsToSelector:@selector(intValue)] ? [NSString stringWithFormat:@"%d%%", [d[@"precipitation_probability"] intValue]] : @""];
        for (NSUInteger k = 0; k < texts.count; k++) {
            UILabel *l = [[UILabel alloc] init];
            l.text = texts[k]; l.tag = 9010 + k; l.userInteractionEnabled = NO;
            l.font = HA_FONT(k == 1 ? 26 : 17, k == 0 || k == 2 ? 0.3 : 0);
            l.textColor = (k == 3 || k == 4) ? HA_DIM() : HA_TEXT();
            if (k == 4) l.textColor = HA_COOL();
            [row addSubview:l];
        }
        [self.list addSubview:row];
        [self.dayRows addObject:row];
    }
    [self setNeedsLayout];
}

- (void)rowTapped:(UIButton *)b { [self showDay:b.tag animated:YES]; }

static NSString *Compass(double deg) {
    NSArray *dirs = @[@"N", @"NE", @"E", @"SE", @"S", @"SW", @"W", @"NW"];
    return dirs[(NSInteger)floor(fmod(deg + 22.5 + 360, 360) / 45) % 8];
}

- (void)showDay:(NSInteger)i animated:(BOOL)animated {
    if (i < 0 || i >= (NSInteger)self.daily.count) return;
    self.selected = i;
    for (UIButton *r in self.dayRows) r.backgroundColor = r.tag == i ? HA_OFF() : [UIColor clearColor];
    NSDictionary *d = Dict(self.daily[i]);
    NSDictionary *ca = Dict(self.current[@"attributes"]);
    if (animated) {
        CATransition *t = [CATransition animation];
        t.type = kCATransitionFade; t.duration = 0.25;
        [self.detail.layer addAnimation:t forKey:@"day"];
    }
    self.dIcon.text = HA_WeatherGlyph(Str(d[@"condition"]));
    self.dTitle.text = [[self dayName:d index:i full:YES] uppercaseString];
    self.dCond.text = HA_WeatherText(Str(d[@"condition"]));
    self.dTemps.text = [NSString stringWithFormat:@"High %.0f°  ·  Low %@", [d[@"temperature"] doubleValue],
                        d[@"templow"] ? [NSString stringWithFormat:@"%.0f°", [d[@"templow"] doubleValue]] : @"--"];

    // facts: whatever this provider includes
    NSString *wu = Str(self.units[@"wind_speed"]) ?: Str(ca[@"wind_speed_unit"]) ?: @"", *pu = Str(self.units[@"precipitation"]) ?: Str(ca[@"precipitation_unit"]) ?: @"", *bu = Str(ca[@"pressure_unit"]) ?: @"";
    // drop JSON nulls so a missing value can never end up as nil inside an array literal
    NSMutableDictionary *clean = [NSMutableDictionary dictionary];
    [d enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) { if (v != [NSNull null]) clean[k] = v; }];
    d = clean;
    NSMutableDictionary *cleanA = [NSMutableDictionary dictionary];
    [ca enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) { if (v != [NSNull null]) cleanA[k] = v; }];
    ca = cleanA;
    NSMutableArray *pairs = [NSMutableArray array];
    if (d[@"precipitation_probability"]) [pairs addObject:@[@"Chance of rain", [NSString stringWithFormat:@"%@%%", d[@"precipitation_probability"]]]];
    if (d[@"precipitation"]) [pairs addObject:@[@"Precipitation", [NSString stringWithFormat:@"%@ %@", d[@"precipitation"], pu]]];
    if (d[@"wind_speed"]) [pairs addObject:@[@"Wind", [NSString stringWithFormat:@"%.0f %@%@", [d[@"wind_speed"] doubleValue], wu,
                                                       d[@"wind_bearing"] ? [@" " stringByAppendingString:Compass([d[@"wind_bearing"] doubleValue])] : @""]]];
    if (d[@"wind_gust_speed"]) [pairs addObject:@[@"Gusts", [NSString stringWithFormat:@"%.0f %@", [d[@"wind_gust_speed"] doubleValue], wu]]];
    id hum = d[@"humidity"] ?: (i == 0 ? ca[@"humidity"] : nil);
    if (hum) [pairs addObject:@[@"Humidity", [NSString stringWithFormat:@"%@%%", hum]]];
    if (d[@"cloud_coverage"]) [pairs addObject:@[@"Cloud cover", [NSString stringWithFormat:@"%@%%", d[@"cloud_coverage"]]]];
    if (Str(d[@"uv_index"])) [pairs addObject:@[@"UV index", Str(d[@"uv_index"])]];
    if (Str(d[@"sunrise"]) && Str(d[@"sunset"])) {
        NSDateFormatter *sf = [[NSDateFormatter alloc] init]; sf.dateFormat = @"h:mm a";
        NSDate *up = HA_ParseISO(d[@"sunrise"]), *down = HA_ParseISO(d[@"sunset"]);
        if (up) [pairs addObject:@[@"Sunrise", [sf stringFromDate:up]]];
        if (down) [pairs addObject:@[@"Sunset", [sf stringFromDate:down]]];
    }
    if (d[@"dew_point"]) [pairs addObject:@[@"Dew point", [NSString stringWithFormat:@"%.0f°", [d[@"dew_point"] doubleValue]]]];
    id press = d[@"pressure"] ?: (i == 0 ? ca[@"pressure"] : nil);
    if (press) [pairs addObject:@[@"Pressure", [NSString stringWithFormat:@"%.0f %@", [press doubleValue], bu]]];
    if (i == 0 && ca[@"temperature"]) [pairs insertObject:@[@"Right now", [NSString stringWithFormat:@"%.0f°", [ca[@"temperature"] doubleValue]]] atIndex:0];
    for (NSArray *pair in self.facts) for (UILabel *l in pair) [l removeFromSuperview];   // facts holds [name, value] pairs
    [self.facts removeAllObjects];
    for (NSArray *p in pairs) {
        UILabel *k = [self lbl:14 w:0 c:HA_DIM()]; k.text = p[0];
        UILabel *v = [self lbl:20 w:0.3 c:HA_TEXT()]; v.text = p[1];
        [self.facts addObject:@[k, v]];
    }

    // hourly for this calendar day
    NSDate *dayDate = HA_ParseISO(Str(d[@"datetime"])) ?: [NSDate date];
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSMutableArray *hrs = [NSMutableArray array], *pts = [NSMutableArray array];
    for (NSDictionary *h in self.hourly) {
        NSDate *t = HA_ParseISO(Str(Dict(h)[@"datetime"]));
        if (t && [cal isDate:t inSameDayAsDate:(i == 0 ? [NSDate date] : dayDate)]) {
            [hrs addObject:h];
            if ([h[@"temperature"] respondsToSelector:@selector(doubleValue)]) [pts addObject:@[t, h[@"temperature"]]];
        }
    }
    for (UIView *v in self.hours.subviews) [v removeFromSuperview];
    NSDateFormatter *hf = [[NSDateFormatter alloc] init]; hf.dateFormat = @"ha";
    CGFloat x = 0;
    for (NSDictionary *h in hrs) {
        NSDate *t = HA_ParseISO(Str(h[@"datetime"]));
        NSArray *vals = @[[[hf stringFromDate:t] lowercaseString], HA_WeatherGlyph(Str(h[@"condition"])),
                          [NSString stringWithFormat:@"%.0f°", [h[@"temperature"] doubleValue]],
                          [h[@"precipitation_probability"] respondsToSelector:@selector(intValue)] ? [NSString stringWithFormat:@"%d%%", [h[@"precipitation_probability"] intValue]]
                              : ([h[@"precipitation"] doubleValue] > 0 ? [NSString stringWithFormat:@"%@", h[@"precipitation"]] : @"")];
        for (NSUInteger k = 0; k < vals.count; k++) {
            UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(x, k == 0 ? 0 : (k == 1 ? 20 : (k == 2 ? 54 : 76)), 56, k == 1 ? 32 : 20)];
            l.text = vals[k]; l.textAlignment = NSTextAlignmentCenter;
            l.font = HA_FONT(k == 1 ? 24 : 14, k == 2 ? 0.3 : 0);
            l.textColor = k == 3 ? HA_COOL() : (k == 0 ? HA_DIM() : HA_TEXT());
            [self.hours addSubview:l];
        }
        x += 60;
    }
    self.hours.contentSize = CGSizeMake(x, 96);
    self.graph.temps = pts; self.graph.targets = nil; self.graph.actions = nil;
    if (pts.count > 1) { self.graph.start = [pts.firstObject firstObject]; self.graph.end = [pts.lastObject firstObject]; }
    else { self.graph.start = nil; self.graph.end = nil; }
    self.graph.hidden = pts.count < 2;
    self.hourCaption.text = hrs.count ? @"HOUR BY HOUR" : @"Hourly detail is only available for the next couple of days";
    [self.graph setNeedsDisplay];
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect c = [self contentRect];
    CGFloat lw = MIN(330, c.size.width * 0.38);
    self.list.frame = CGRectMake(c.origin.x, c.origin.y, lw, c.size.height);
    CGFloat rowH = MAX(52, floor(c.size.height / MAX((NSUInteger)1, self.dayRows.count)));   // fewer days -> taller rows fill the height
    for (UIButton *r in self.dayRows) {
        r.frame = CGRectMake(0, r.tag * rowH, lw, rowH - 4);
        [r viewWithTag:9010].frame = CGRectMake(12, 0, 90, rowH - 4);
        [r viewWithTag:9011].frame = CGRectMake(100, 0, 40, rowH - 4);
        [r viewWithTag:9012].frame = CGRectMake(150, 0, 50, rowH - 4);
        [r viewWithTag:9013].frame = CGRectMake(200, 0, 50, rowH - 4);
        [r viewWithTag:9014].frame = CGRectMake(lw - 60, 0, 50, rowH - 4);
    }
    self.list.contentSize = CGSizeMake(lw, self.dayRows.count * rowH);
    CGFloat dx = c.origin.x + lw + 24, dw = CGRectGetMaxX(c) - dx;
    self.detail.frame = CGRectMake(dx, c.origin.y, dw, c.size.height);
    self.dIcon.frame = CGRectMake(0, 0, 80, 76);
    self.dTitle.frame = CGRectMake(92, 4, dw - 92, 18);
    self.dCond.frame = CGRectMake(92, 22, dw - 92, 32);
    self.dTemps.frame = CGRectMake(92, 52, dw - 92, 28);
    CGFloat y = 92, colW = dw / 3;
    for (NSUInteger i = 0; i < self.facts.count; i++) {
        CGFloat fx = (i % 3) * colW, fy = y + (i / 3) * 50;
        ((UILabel *)self.facts[i][0]).frame = CGRectMake(fx, fy, colW - 8, 18);
        ((UILabel *)self.facts[i][1]).frame = CGRectMake(fx, fy + 18, colW - 8, 26);
    }
    y += ((self.facts.count + 2) / 3) * 50 + 10;
    self.hourCaption.frame = CGRectMake(0, y, dw, 16);
    y += 20;
    CGFloat hoursH = 96, graphH = MAX(80, self.detail.bounds.size.height - y - hoursH - 12);
    self.graph.frame = CGRectMake(0, y, dw, self.graph.hidden ? 0 : graphH);
    self.hours.frame = CGRectMake(0, y + (self.graph.hidden ? 0 : graphH + 12), dw, hoursH);
    [self.graph setNeedsDisplay];
}

@end

#import "PanelViewController.h"
#import "HAClient.h"
#import "Cards.h"
#import "Presence.h"
#import <AudioToolbox/AudioToolbox.h>

extern NSString *const HAUserActivityNotification;
static NSString *Str(id v) { return [v isKindOfClass:[NSString class]] ? v : nil; }
static const CGFloat kRailW = 88;

// One slide-out drawer opened from the sidebar rail.
@interface HADrawer : NSObject
@property (nonatomic, strong) NSDictionary *spec;
@property (nonatomic, strong) UIView *view;
@property (nonatomic, strong) UIButton *railButton;
@property (nonatomic, strong) NSMutableArray *cards;       // the cards showing: all of them, or the selected tab's
// "tabs": [ { "name": "Lights", "cards": [...], "columns": 1, ... } ] puts several sections in one drawer
@property (nonatomic, strong) NSArray *tabs;
@property (nonatomic, strong) NSMutableArray *tabCards;    // one card list per tab
@property (nonatomic, strong) NSArray *allCards;
@property (nonatomic, strong) UIView *tabBar;
@property (nonatomic, assign) NSInteger tabIndex;
@end
@implementation HADrawer @end

// Pages of the main grid. Swipes that start on a button still turn the page; sliders keep their touch.
// Only mostly-horizontal drags start a page turn, so a slightly sloppy tap is still a tap.
@interface HAPagesScroll : UIScrollView
@end
@implementation HAPagesScroll
- (BOOL)touchesShouldCancelInContentView:(UIView *)view { return !([view isKindOfClass:[UISlider class]] || view.tag == 9901); }   // 9901: thermostat dial
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (g == self.panGestureRecognizer) {
        CGPoint v = [self.panGestureRecognizer velocityInView:self];
        return fabs(v.x) > fabs(v.y) * 1.3;
    }
    return [super gestureRecognizerShouldBegin:g];
}
@end

@interface PanelViewController () <HACardHost, UIScrollViewDelegate, UITableViewDataSource, UITableViewDelegate>
// header
@property (nonatomic, strong) UILabel *clockLabel, *dateLabel, *wxIcon, *wxTemp, *wxText, *statusLabel;
@property (nonatomic, strong) NSMutableArray *wxDays;      // two mini columns: @[dayLabel, iconLabel, tempsLabel]
@property (nonatomic, strong) UIControl *wxTap;            // invisible button over the weather area
@property (nonatomic, strong) NSDate *lastForecast, *lastBattery;
@property (nonatomic, strong) UIButton *gearButton;
// layout
@property (nonatomic, strong) NSData *layoutData, *homeData;
@property (nonatomic, strong) NSDictionary *layout, *homeSpec;
@property (nonatomic, strong) NSMutableArray *cards;
@property (nonatomic, strong) NSMutableDictionary *states;
@property (nonatomic, copy) NSString *weatherEntity;
@property (nonatomic, copy) NSString *layoutError, *serviceError;
// sidebar
@property (nonatomic, strong) UIView *rail;
@property (nonatomic, strong) NSMutableArray *drawers;
@property (nonatomic, strong) HADrawer *openDrawer;
@property (nonatomic, assign) BOOL usingStarter;   // showing the built-in first layout (no file in Home Assistant yet)
@property (nonatomic, strong) NSDate *demoUntil;   // debug: sample states stay on screen until then
@property (nonatomic, strong) NSMutableDictionary *tabMemory;   // drawer name -> tab last shown
@property (nonatomic, strong) UIControl *scrim;
@property (nonatomic, strong) NSDate *lastTouch;
// presence / dimming
@property (nonatomic, strong) Presence *presence;
@property (nonatomic, strong) UIControl *dimOverlay;
@property (nonatomic, assign) NSInteger idleMode;            // 0 dashboard, 1 photo frame, 2 blank
@property (nonatomic, assign) NSTimeInterval dimAfter, blankAfter, photoInterval;
@property (nonatomic, assign) CGFloat savedBrightness;       // -1 when not blanked
@property (nonatomic, strong) NSDate *lastSeen, *lastPhoto, *ignorePresenceUntil;
@property (nonatomic, copy) NSString *lastReason, *photoURL;
@property (nonatomic, strong) UIControl *frameView;
@property (nonatomic, strong) UIImageView *frameFront, *frameBack;
@property (nonatomic, strong) UILabel *frameClock;
// alerts
@property (nonatomic, strong) NSMutableDictionary *watchPrev;
@property (nonatomic, strong) UIView *alertView;
@property (nonatomic, copy) NSString *alertKind, *alertCamera;
@property (nonatomic, strong) NSDate *alertStarted;
@property (nonatomic, assign) NSInteger alertTicks;
// camera pop-up on a detection (alerts.detections in the layout)
@property (nonatomic, copy) NSString *alertURL;               // snapshot address shown in the alert
@property (nonatomic, assign) NSTimeInterval alertSeconds;    // how long a detection pop-up stays up
@property (nonatomic, assign) BOOL detectBusy, alertImageBusy;
@property (nonatomic, strong) NSMutableSet *seenDetections;   // event ids already handled
@property (nonatomic, strong) NSMutableDictionary *detectLast; // camera -> time of its last pop-up
// misc
@property (nonatomic, strong) UIView *setupOverlay;
@property (nonatomic, strong) UIView *themeView;
// layout editor
@property (nonatomic, assign) BOOL editing;
@property (nonatomic, strong) NSMutableDictionary *editLayout;
@property (nonatomic, strong) UIView *editBar;
@property (nonatomic, strong) UILabel *editTitle;
@property (nonatomic, strong) NSMutableArray *editOverlays;   // one per main card, placed above it (not inside)
@property (nonatomic, assign) NSInteger mainRows;          // rows used by the main grid at the last layout pass
@property (nonatomic, assign) CGPoint dragStartCenter;
@property (nonatomic, strong) NSMutableArray *editCells;      // outlines of the free cells
@property (nonatomic, copy) NSString *editNote;               // one-off message shown in the edit bar
@property (nonatomic, strong) UIView *pickerView;             // "+ Widget" list
@property (nonatomic, strong) NSDictionary *pickerPreset;
@property (nonatomic, strong) NSArray *pickerEntities;
// screens (pages) of the main grid
@property (nonatomic, strong) UIScrollView *pagesScroll;
@property (nonatomic, strong) UIPageControl *pageDots;
@property (nonatomic, strong) NSMutableArray *pageViews, *pageCards;   // per screen: container view, list of cards
@property (nonatomic, assign) NSInteger page;
@property (nonatomic, assign) CGRect gridRect;                // grid of the visible screen, in its container's coordinates
@property (nonatomic, assign) CGFloat gridGap;
@property (nonatomic, strong) NSArray *gridEdges;             // top of each row, plus one past the last
@property (nonatomic, strong) NSTimer *pollTimer, *secondTimer;
@property (nonatomic, assign) NSInteger seconds;
@end

@implementation PanelViewController

- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }

- (UILabel *)label:(CGFloat)size weight:(CGFloat)w color:(UIColor *)c in:(UIView *)parent {
    UILabel *l = [[UILabel alloc] init];
    l.font = HA_FONT(size, w); l.textColor = c; l.backgroundColor = [UIColor clearColor];
    l.adjustsFontSizeToFitWidth = YES; l.minimumScaleFactor = 0.5;
    [parent addSubview:l];
    return l;
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = HA_BG();
    self.cards = [NSMutableArray array];
    self.drawers = [NSMutableArray array];
    self.states = [NSMutableDictionary dictionary];
    self.lastSeen = self.lastTouch = [NSDate date];
    self.savedBrightness = -1;
    self.watchPrev = [NSMutableDictionary dictionary];
    self.blankAfter = 1800; self.photoInterval = 45;

    self.clockLabel = [self label:72 weight:-0.6 color:HA_TEXT() in:self.view];
    self.dateLabel = [self label:22 weight:0 color:HA_DIM() in:self.view];
    self.wxIcon = [self label:52 weight:0 color:HA_TEXT() in:self.view];
    self.wxIcon.textAlignment = NSTextAlignmentRight;
    self.wxTemp = [self label:54 weight:-0.4 color:HA_TEXT() in:self.view];
    self.wxText = [self label:20 weight:0 color:HA_DIM() in:self.view];
    self.wxText.textAlignment = NSTextAlignmentRight;
    // next two days beside the current conditions; tapping the weather area opens the "Forecast" drawer
    self.wxDays = [NSMutableArray array];
    for (int i = 0; i < 2; i++) {
        UILabel *d = [self label:15 weight:0.4 color:HA_DIM() in:self.view], *ic = [self label:30 weight:0 color:HA_TEXT() in:self.view], *t = [self label:16 weight:0.2 color:HA_TEXT() in:self.view];
        for (UILabel *l in @[d, ic, t]) l.textAlignment = NSTextAlignmentCenter;
        [self.wxDays addObject:@[d, ic, t]];
    }
    self.wxTap = [[UIControl alloc] init];
    [self.wxTap addTarget:self action:@selector(weatherTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.wxTap];
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    self.statusLabel = [self label:13 weight:0 color:HA_DIM() in:self.view];
    self.gearButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.gearButton setTitle:@"⚙︎" forState:UIControlStateNormal];
    [self.gearButton setTitleColor:HA_DIM() forState:UIControlStateNormal];
    self.gearButton.titleLabel.font = HA_FONT(26, 0);
    [self.gearButton addTarget:self action:@selector(gearTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.gearButton];

    self.pageViews = [NSMutableArray array];
    self.pageCards = [NSMutableArray array];
    self.pagesScroll = [[HAPagesScroll alloc] init];
    self.pagesScroll.pagingEnabled = YES;
    self.pagesScroll.showsHorizontalScrollIndicator = self.pagesScroll.showsVerticalScrollIndicator = NO;
    self.pagesScroll.delaysContentTouches = NO;
    self.pagesScroll.scrollsToTop = NO;
    self.pagesScroll.delegate = self;
    [self.view insertSubview:self.pagesScroll atIndex:0];
    self.pageDots = [[UIPageControl alloc] init];
    self.pageDots.userInteractionEnabled = NO;
    self.pageDots.hidden = YES;
    [self.view addSubview:self.pageDots];

    // Scrim behind an open drawer; tapping it closes the drawer.
    self.scrim = [[UIControl alloc] init];
    self.scrim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    self.scrim.alpha = 0;
    self.scrim.hidden = YES;
    [self.scrim addTarget:self action:@selector(closeDrawer) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.scrim];

    self.rail = [[UIView alloc] init];
    self.rail.backgroundColor = RGB(20, 20, 22);
    [self.view addSubview:self.rail];

    self.setupOverlay = [[UIView alloc] init];
    self.setupOverlay.backgroundColor = [HA_BG() colorWithAlphaComponent:0.96];
    UILabel *msg = [self label:22 weight:0 color:HA_TEXT() in:self.setupOverlay];
    msg.numberOfLines = 0; msg.textAlignment = NSTextAlignmentCenter; msg.tag = 7;
    msg.text = @"Not connected to Home Assistant yet.\n\nEnter its address and a long-lived access token\n(Home Assistant: your profile, Security).";
    UIButton *connect = HA_Chip(@"Connect…", self, @selector(showConnectionForm));
    connect.titleLabel.font = HA_FONT(24, 0.3);
    connect.backgroundColor = HA_ACCENT();
    [connect setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    connect.tag = 8;
    [self.setupOverlay addSubview:connect];
    [self.view addSubview:self.setupOverlay];

    // Photo frame shown while nobody's around (Immich Kiosk /image). Touch wakes it.
    self.frameView = [[UIControl alloc] init];
    self.frameView.backgroundColor = [UIColor blackColor];
    self.frameView.clipsToBounds = YES;
    self.frameView.alpha = 0;
    self.frameView.hidden = YES;
    [self.frameView addTarget:self action:@selector(wake) forControlEvents:UIControlEventTouchDown];
    for (int i = 0; i < 2; i++) {
        UIImageView *iv = [[UIImageView alloc] init];
        iv.contentMode = UIViewContentModeScaleAspectFill;
        iv.userInteractionEnabled = NO;
        [self.frameView addSubview:iv];
        if (i == 0) self.frameFront = iv; else self.frameBack = iv;
    }
    self.frameClock = [self label:44 weight:-0.4 color:[UIColor whiteColor] in:self.frameView];
    self.frameClock.textAlignment = NSTextAlignmentRight;
    self.frameClock.shadowColor = [UIColor colorWithWhite:0 alpha:0.7];
    self.frameClock.shadowOffset = CGSizeMake(0, 1);
    [self.view addSubview:self.frameView];

    // Black overlay used for "screen off". Any touch wakes it.
    self.dimOverlay = [[UIControl alloc] init];
    self.dimOverlay.backgroundColor = [UIColor blackColor];
    self.dimOverlay.alpha = 0;
    self.dimOverlay.userInteractionEnabled = NO;
    [self.dimOverlay addTarget:self action:@selector(wake) forControlEvents:UIControlEventTouchDown];
    [self.view addSubview:self.dimOverlay];

    self.presence = [[Presence alloc] init];
    __weak PanelViewController *ws = self;
    self.presence.onPresence = ^(NSString *reason) { [ws sawSomeone:reason]; };

    [self loadCached];
    [self tickSecond];
    self.secondTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(tickSecond) userInfo:nil repeats:YES];
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:3 target:self selector:@selector(poll) userInfo:nil repeats:YES];
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(appActive) name:UIApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:self selector:@selector(appInactive) name:UIApplicationWillResignActiveNotification object:nil];
    [nc addObserver:self selector:@selector(userTouched) name:HAUserActivityNotification object:nil];
    [self appActive];
}

- (void)appActive {
    [[HAClient shared] reloadConfig];
    [self fetchLayout];
    [self wake];
    [self applyPresenceConfig];
    [self poll];
    [self refreshBadges];
}

- (void)appInactive {
    [self.presence stop];
    if (self.savedBrightness >= 0) { [UIScreen mainScreen].brightness = self.savedBrightness; self.savedBrightness = -1; }
}

- (void)userTouched {
    self.lastTouch = [NSDate date];
    self.lastSeen = self.lastTouch;
}

#pragma mark - Layout loading

- (NSString *)cacheKey { return [@"layout." stringByAppendingString:[HAClient shared].panel ?: @"default"]; }

- (void)loadCached {
    [[HAClient shared] reloadConfig];
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSData *home = [d dataForKey:@"home.json"];
    if (home) { self.homeData = home; self.homeSpec = [NSJSONSerialization JSONObjectWithData:home options:0 error:nil]; }
    NSData *lay = [d dataForKey:[self cacheKey]];
    if (lay) [self applyLayoutData:lay];
}

- (void)fetchLayout {
    HAClient *ha = [HAClient shared];
    if (![ha isConfigured]) return;
    // shared Home drawer config first, then this iPad's layout
    [ha fetchPanelFile:@"home.json" completion:^(NSData *home, NSError *herr) {
        BOOL homeChanged = NO;
        if (home && ![home isEqualToData:self.homeData]) {
            id spec = [NSJSONSerialization JSONObjectWithData:home options:0 error:nil];
            if ([spec isKindOfClass:[NSDictionary class]]) {
                self.homeData = home; self.homeSpec = spec; homeChanged = YES;
                [[NSUserDefaults standardUserDefaults] setObject:home forKey:@"home.json"];
            }
        }
        [ha fetchLayout:^(NSData *data, NSError *error) {
            if (error.code == 404 && [error.domain isEqualToString:@"HA"]) { [self buildStarterLayout]; return; }
            if (error) { self.layoutError = error.localizedDescription; [self updateStatus]; return; }
            self.usingStarter = NO;
            if ([data isEqualToData:self.layoutData] && !homeChanged) { self.layoutError = nil; [self updateStatus]; return; }
            [self applyLayoutData:data];
        }];
    }];
}

// No layout file for this panel yet: make a first screen from what Home Assistant has (weather, the
// first lights, a thermostat, the speakers), so a new install shows something useful straight away.
// Nothing is written to Home Assistant until the layout is saved from the editor.
- (void)buildStarterLayout {
    if (self.usingStarter || self.editing) return;
    [[HAClient shared] getJSON:@"/api/states" completion:^(id json, NSError *e) {
        if (![json isKindOfClass:[NSArray class]]) { self.layoutError = e.localizedDescription ?: @"could not read Home Assistant states"; [self updateStatus]; return; }
        NSMutableDictionary *first = [NSMutableDictionary dictionary];   // domain -> entity ids
        for (NSDictionary *s in json) {
            NSString *eid = Str(s[@"entity_id"]), *st = Str(s[@"state"]);
            if (!eid || [st isEqualToString:@"unavailable"]) continue;
            NSString *dom = [eid componentsSeparatedByString:@"."][0];
            if (!first[dom]) first[dom] = [NSMutableArray array];
            // light groups first: they are the "room" switches
            if ([dom isEqualToString:@"light"] && [s[@"attributes"][@"entity_id"] isKindOfClass:[NSArray class]]) [first[dom] insertObject:s atIndex:0];
            else [first[dom] addObject:s];
        }
        NSMutableArray *cards = [NSMutableArray array];
        for (NSDictionary *s in [first[@"light"] subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)2, [first[@"light"] count]))])
            [cards addObject:@{@"type": @"light", @"members": @NO, @"entity": s[@"entity_id"], @"title": Str(s[@"attributes"][@"friendly_name"]) ?: s[@"entity_id"]}];
        NSMutableArray *players = [NSMutableArray array];
        for (NSDictionary *s in first[@"media_player"]) if (players.count < 6) [players addObject:s[@"entity_id"]];
        [cards addObject:@{@"type": @"context", @"players": players}];
        if ([first[@"climate"] count]) [cards addObject:@{@"type": @"climate", @"entity": first[@"climate"][0][@"entity_id"], @"title": @"Thermostat", @"h": @2}];
        if ([first[@"timer"] count]) [cards addObject:@{@"type": @"timer", @"entity": first[@"timer"][0][@"entity_id"]}];
        NSMutableDictionary *lay = [NSMutableDictionary dictionaryWithDictionary:@{@"title": @"Home", @"columns": @3, @"rows": @3, @"cards": cards}];
        if ([first[@"weather"] count]) lay[@"weather"] = first[@"weather"][0][@"entity_id"];
        self.usingStarter = YES;
        self.layoutError = @"starter layout: tap the gear, then Edit layout, to make it yours";
        self.layoutData = [NSJSONSerialization dataWithJSONObject:lay options:0 error:nil];   // what the editor starts from
        [self applyLayoutDict:lay animated:YES];
        [self updateStatus];
        [self poll];
    }];
}

// Address, access token and panel name, typed on the iPad. The token field is left empty to keep the
// stored one; it is never shown again.
- (void)showConnectionForm {
    HAClient *ha = [HAClient shared];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Home Assistant"
        message:@"Address as you open it on your network (http, not https).\nToken: Home Assistant, your profile, Security, Long-lived access tokens.\nPanel: a short name for this iPad, for example kitchen."
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.placeholder = @"http://192.168.1.10:8123"; f.text = [ha isConfigured] ? ha.baseURL : @"http://";
        f.keyboardType = UIKeyboardTypeURL; f.autocorrectionType = UITextAutocorrectionTypeNo; f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.placeholder = [ha isConfigured] ? @"Access token (empty = keep the current one)" : @"Access token";
        f.secureTextEntry = YES; f.autocorrectionType = UITextAutocorrectionTypeNo; f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.placeholder = @"Panel name"; f.text = [ha.panel isEqualToString:@"default"] ? @"" : ha.panel;
        f.autocorrectionType = UITextAutocorrectionTypeNo; f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    __weak UIAlertController *wac = ac;
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSArray *f = wac.textFields;
        NSMutableString *panel = [NSMutableString string];   // file-name safe: letters, digits, _ and -
        for (NSUInteger i = 0; i < [[f[2] text] length]; i++) {
            unichar ch = [[[f[2] text] lowercaseString] characterAtIndex:i];
            if ((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == '-') [panel appendFormat:@"%C", ch];
        }
        if (![[HAClient shared] saveURL:[f[0] text] token:[f[1] text] panel:panel]) { self.serviceError = @"could not save the connection settings"; [self updateStatus]; return; }
        self.serviceError = nil; self.layoutError = nil; self.usingStarter = NO;
        self.layoutData = nil; self.homeData = nil;
        [self fetchLayout]; [self poll];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (NSMutableArray *)buildCards:(NSArray *)specs into:(UIView *)parent {
    NSMutableArray *out = [NSMutableArray array];
    for (id spec in specs) {
        if (![spec isKindOfClass:[NSDictionary class]]) continue;
        HACard *card = [HACard cardWithSpec:spec host:self];
        if (!card) continue;
        if (parent == self.view) [self.view insertSubview:card belowSubview:self.scrim];
        else [parent addSubview:card];
        [out addObject:card];
    }
    return out;
}

- (void)applyLayoutData:(NSData *)data {
    NSError *jerr = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jerr];
    if (![json isKindOfClass:[NSDictionary class]]) {
        self.layoutError = [NSString stringWithFormat:@"layout JSON error: %@", jerr.localizedDescription ?: @"not an object"];
        [self updateStatus];
        return;   // keep showing the previous layout
    }
    if (self.editing) return;   // keep the layout stable while the editor is open
    self.layoutError = nil;
    self.layoutData = data;
    [[NSUserDefaults standardUserDefaults] setObject:data forKey:[self cacheKey]];
    [self applyLayoutDict:json animated:YES];
}

- (void)applyLayoutDict:(NSDictionary *)json animated:(BOOL)animated {
    self.layout = json;
    [self applyTheme];

    // main grid
    [self closeDrawerAnimated:NO];
    for (NSArray *list in self.pageCards) for (HACard *c in list) [c removeFromSuperview];
    for (UIView *v in self.pageViews) [v removeFromSuperview];
    [self.pageCards removeAllObjects];
    [self.pageViews removeAllObjects];
    for (NSDictionary *pg in [self pageSpecsOf:json]) {
        UIView *pv = [[UIView alloc] init];
        [self.pagesScroll addSubview:pv];
        [self.pageViews addObject:pv];
        [self.pageCards addObject:[self buildCards:([pg[@"cards"] isKindOfClass:[NSArray class]] ? pg[@"cards"] : @[]) into:pv]];
    }
    [self showPage:self.page];

    // sidebar drawers: this iPad's own, then the shared Home drawer
    for (HADrawer *d in self.drawers) { [d.view removeFromSuperview]; [d.railButton removeFromSuperview]; }
    [self.drawers removeAllObjects];
    NSMutableArray *specs = [NSMutableArray array];
    for (id s in ([json[@"sidebar"] isKindOfClass:[NSArray class]] ? json[@"sidebar"] : @[])) if ([s isKindOfClass:[NSDictionary class]]) [specs addObject:s];
    if (!json[@"home"] || [json[@"home"] boolValue]) {
        NSMutableDictionary *homeCard = [NSMutableDictionary dictionaryWithDictionary:self.homeSpec ?: @{}];
        homeCard[@"type"] = @"home";
        [specs addObject:@{@"name": Str(self.homeSpec[@"name"]) ?: @"Home", @"icon": Str(self.homeSpec[@"icon"]) ?: @"\U0001F3E0",
                           @"width": self.homeSpec[@"width"] ?: @0.94, @"cards": @[homeCard]}];
    }
    for (NSDictionary *s in specs) {
        HADrawer *d = [[HADrawer alloc] init];
        d.spec = s;
        d.view = [[UIView alloc] init];
        d.view.backgroundColor = [self shade:HA_BG() by:0.03];
        d.view.hidden = YES;
        d.view.layer.shadowColor = [UIColor blackColor].CGColor;
        d.view.layer.shadowOpacity = 0.6;
        d.view.layer.shadowRadius = 18;
        [self.view insertSubview:d.view belowSubview:self.rail];
        NSMutableArray *tabs = [NSMutableArray array];
        for (id t in ([s[@"tabs"] isKindOfClass:[NSArray class]] ? s[@"tabs"] : @[])) if ([t isKindOfClass:[NSDictionary class]]) [tabs addObject:t];
        if (tabs.count) {
            d.tabs = tabs;
            d.tabCards = [NSMutableArray array];
            NSMutableArray *all = [NSMutableArray array];
            for (NSDictionary *t in tabs) {
                NSMutableArray *list = [self buildCards:[self withHomeSpec:t[@"cards"]] into:d.view];
                [d.tabCards addObject:list];
                [all addObjectsFromArray:list];
            }
            d.allCards = all;
            d.tabIndex = MAX(0, MIN((NSInteger)tabs.count - 1, [self.tabMemory[Str(s[@"name"]) ?: @""] integerValue]));
            d.cards = d.tabCards[d.tabIndex];
            d.tabBar = [[UIView alloc] init];
            for (NSUInteger i = 0; i < tabs.count; i++) {
                NSString *icon = Str(tabs[i][@"icon"]), *name = Str(tabs[i][@"name"]) ?: @"";
                UIButton *tb = HA_Chip(icon.length ? [NSString stringWithFormat:@"%@  %@", icon, name] : name, self, @selector(drawerTabTapped:));
                tb.titleLabel.font = HA_FONT(17, 0.3);
                tb.tag = i;
                [d.tabBar addSubview:tb];
            }
            [d.view addSubview:d.tabBar];
            [self applyTabs:d];
        } else {
            d.cards = [self buildCards:[self withHomeSpec:s[@"cards"]] into:d.view];
            d.allCards = d.cards;
        }
        for (HACard *c in d.allCards) c.active = NO;

        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.titleLabel.numberOfLines = 2;
        b.titleLabel.textAlignment = NSTextAlignmentCenter;
        NSString *icon = Str(s[@"icon"]) ?: @"•";
        NSString *name = Str(s[@"name"]) ?: @"";
        NSMutableAttributedString *t = [[NSMutableAttributedString alloc] initWithString:icon attributes:@{NSFontAttributeName: HA_FONT(30, 0), NSForegroundColorAttributeName: HA_TEXT()}];
        [t appendAttributedString:[[NSAttributedString alloc] initWithString:[@"\n" stringByAppendingString:name] attributes:@{NSFontAttributeName: HA_FONT(12, 0.3), NSForegroundColorAttributeName: HA_DIM()}]];
        [b setAttributedTitle:t forState:UIControlStateNormal];
        b.layer.cornerRadius = 14;
        [b addTarget:self action:@selector(railTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.rail addSubview:b];
        d.railButton = b;
        [self.drawers addObject:d];
        for (HACard *c in d.allCards) [c reload];
    }
    for (HACard *c in self.cards) [c reload];
    // cards ease in one after another (classic springboard-style entrance)
    for (NSUInteger i = 0; animated && i < self.cards.count; i++) {
        HACard *c = self.cards[i];
        c.alpha = 0;
        c.transform = CGAffineTransformMakeScale(0.96, 0.96);
        [UIView animateWithDuration:0.4 delay:0.05 + i * 0.06 usingSpringWithDamping:0.8 initialSpringVelocity:0.3
                            options:UIViewAnimationOptionAllowUserInteraction animations:^{ c.alpha = 1; c.transform = CGAffineTransformIdentity; } completion:nil];
    }

    self.weatherEntity = Str(json[@"weather"]);
    self.wxIcon.hidden = self.wxTemp.hidden = self.wxText.hidden = self.wxTap.hidden = (self.weatherEntity == nil);
    for (NSArray *col in self.wxDays) for (UILabel *l in col) l.hidden = (self.weatherEntity == nil);
    self.lastForecast = nil;
    [self applyPresenceConfig];
    [self.view setNeedsLayout];
    [self updateStatus];
    [self poll];
    if (!self.editing) [self refreshBadges];   // the rail buttons were rebuilt: put their badges back
}

// A { "type": "home" } card without its own settings uses the shared home.json.
- (NSArray *)withHomeSpec:(id)cards {
    NSMutableArray *out = [NSMutableArray array];
    for (id c in ([cards isKindOfClass:[NSArray class]] ? cards : @[])) {
        if ([c isKindOfClass:[NSDictionary class]] && [c[@"type"] isEqual:@"home"] && !c[@"domains"]) {
            NSMutableDictionary *m = [NSMutableDictionary dictionaryWithDictionary:self.homeSpec ?: @{}];
            [m addEntriesFromDictionary:c];
            [out addObject:m];
        } else [out addObject:c];
    }
    return out;
}

// Show the selected tab of a tabbed drawer: its cards visible and live, the others hidden and idle.
- (void)applyTabs:(HADrawer *)d {
    if (!d.tabs) return;
    for (NSUInteger i = 0; i < d.tabCards.count; i++) {
        BOOL sel = (NSInteger)i == d.tabIndex;
        for (HACard *c in d.tabCards[i]) { c.hidden = !sel; c.active = sel && d == self.openDrawer; }
    }
    for (UIButton *b in d.tabBar.subviews) {
        BOOL sel = b.tag == d.tabIndex;
        HA_SetBG(b, sel ? HA_ACCENT() : HA_OFF());
        [b setTitleColor:sel ? [UIColor blackColor] : HA_TEXT() forState:UIControlStateNormal];
    }
}

- (void)selectTab:(NSInteger)i ofDrawer:(HADrawer *)d {
    if (!d.tabs || i < 0 || i >= (NSInteger)d.tabCards.count) return;
    d.tabIndex = i;
    d.cards = d.tabCards[i];
    if (!self.tabMemory) self.tabMemory = [NSMutableDictionary dictionary];
    self.tabMemory[Str(d.spec[@"name"]) ?: @""] = @(i);
    [self applyTabs:d];
    self.lastTouch = [NSDate date];
    if (d == self.openDrawer) {
        for (HACard *c in d.cards) { HA_Fade(c, 0.18); [c reload]; }
        [self poll];
    }
}

- (void)drawerTabTapped:(UIButton *)b {
    for (HADrawer *d in self.drawers) if (d.tabBar == b.superview) [self selectTab:b.tag ofDrawer:d];
}

- (void)applyPresenceConfig {
    NSDictionary *p = [self.layout[@"presence"] isKindOfClass:[NSDictionary class]] ? self.layout[@"presence"] : nil;
    BOOL enabled = p && (p[@"enabled"] == nil || [p[@"enabled"] boolValue]);
    self.dimAfter = [p[@"dim_after"] respondsToSelector:@selector(doubleValue)] ? MAX(10, [p[@"dim_after"] doubleValue]) : 60;
    NSString *sens = Str(p[@"sensitivity"]) ?: @"medium";
    self.presence.sensitivity = [sens isEqualToString:@"high"] ? 2 : ([sens isEqualToString:@"low"] ? 8 : 4);
    // idle: "photos" shows photo_url as a slideshow after dim_after; blank_after (default 30 min) goes fully black
    self.blankAfter = [p[@"blank_after"] respondsToSelector:@selector(doubleValue)] ? MAX(self.dimAfter, [p[@"blank_after"] doubleValue]) : 1800;
    self.photoInterval = [p[@"photo_interval"] respondsToSelector:@selector(doubleValue)] ? MAX(10, [p[@"photo_interval"] doubleValue]) : 45;
    self.photoURL = [Str(p[@"idle"]) isEqualToString:@"photos"] ? Str(p[@"photo_url"]) : nil;
    self.presence.landscapeLeft = (self.interfaceOrientation == UIInterfaceOrientationLandscapeLeft);
    if (enabled && [UIApplication sharedApplication].applicationState == UIApplicationStateActive) [self.presence start];
    if (!enabled) { [self.presence stop]; [self wake]; }
}

#pragma mark - Layout

// Where every card goes: one @[row, col, w, h] per spec. A card with "col" and "row" keeps that cell
// when it is free (the layout editor pins every card this way, which is what leaves gaps where a
// card was removed); the others flow into the first gap that fits, in order, like a CSS grid.
- (NSArray *)placementsForSpecs:(NSArray *)specs columns:(NSInteger)cols usedRows:(NSInteger *)usedRows {
    cols = MAX(1, cols);
    NSMutableSet *taken = [NSMutableSet set];
    NSMutableArray *places = [NSMutableArray array];
    NSInteger maxRow = 0;
    BOOL (^isFree)(NSInteger, NSInteger, NSInteger, NSInteger) = ^BOOL(NSInteger r, NSInteger c, NSInteger w, NSInteger h) {
        if (c < 0 || r < 0 || c + w > cols) return NO;
        for (NSInteger rr = r; rr < r + h; rr++) for (NSInteger cc = c; cc < c + w; cc++) if ([taken containsObject:@(rr * 100 + cc)]) return NO;
        return YES;
    };
    void (^take)(NSInteger, NSInteger, NSInteger, NSInteger) = ^(NSInteger r, NSInteger c, NSInteger w, NSInteger h) {
        for (NSInteger rr = r; rr < r + h; rr++) for (NSInteger cc = c; cc < c + w; cc++) [taken addObject:@(rr * 100 + cc)];
    };
    for (int pass = 0; pass < 2; pass++) {       // pinned cards first, then the rest
        for (NSUInteger i = 0; i < specs.count; i++) {
            NSDictionary *spec = [specs[i] isKindOfClass:[NSDictionary class]] ? specs[i] : @{};
            NSInteger w = MIN(cols, MAX(1, HA_Int(spec[@"w"], 1))), h = MIN(12, MAX(1, HA_Int(spec[@"h"], 1)));
            if (pass == 0) {
                [places addObject:[NSNull null]];
                BOOL pinned = [spec[@"col"] respondsToSelector:@selector(integerValue)] && [spec[@"row"] respondsToSelector:@selector(integerValue)];
                NSInteger c = MIN(cols - w, MAX(0, HA_Int(spec[@"col"], 0))), r = MIN(40, MAX(0, HA_Int(spec[@"row"], 0)));
                if (pinned && isFree(r, c, w, h)) { take(r, c, w, h); places[i] = @[@(r), @(c), @(w), @(h)]; maxRow = MAX(maxRow, r + h); }
            } else if (places[i] == [NSNull null]) {
                for (NSInteger r = 0; places[i] == [NSNull null]; r++)
                    for (NSInteger c = 0; c + w <= cols; c++)
                        if (isFree(r, c, w, h)) { take(r, c, w, h); places[i] = @[@(r), @(c), @(w), @(h)]; maxRow = MAX(maxRow, r + h); break; }
            }
        }
    }
    if (usedRows) *usedRows = maxRow;
    return places;
}

// Lays the cards out in rect. rows > 0 keeps at least that many rows, so a short card doesn't stretch
// and empty rows stay empty. weights (e.g. [1, 1, 0.6]) sets relative row heights; missing rows weigh 1.
// Returns the number of rows; edges gets the top of every row plus one entry past the last.
- (NSInteger)placeCards:(NSArray *)cards inRect:(CGRect)rect columns:(NSInteger)cols rows:(NSInteger)minRows weights:(NSArray *)weights gap:(CGFloat)gap edges:(NSArray **)outEdges {
    cols = MAX(1, cols);
    NSMutableArray *specs = [NSMutableArray array];
    for (HACard *card in cards) [specs addObject:card.spec ?: @{}];
    NSInteger used = 0;
    NSArray *places = [self placementsForSpecs:specs columns:cols usedRows:&used];
    NSInteger maxRow = MAX(used, minRows);
    if (outEdges) *outEdges = @[];
    if (!maxRow) return 0;
    CGFloat cellW = (rect.size.width - (cols - 1) * gap) / cols, total = 0;
    NSMutableArray *rowW = [NSMutableArray array];
    for (NSInteger r = 0; r < maxRow; r++) {
        id wv = r < (NSInteger)weights.count ? weights[r] : nil;
        double w = [wv respondsToSelector:@selector(doubleValue)] ? MAX(0.1, [wv doubleValue]) : 1;
        [rowW addObject:@(w)];
        total += w;
    }
    CGFloat avail = rect.size.height - (maxRow - 1) * gap;
    NSMutableArray *edges = [NSMutableArray arrayWithObject:@(rect.origin.y)];
    for (NSInteger r = 0; r < maxRow; r++) [edges addObject:@([edges[r] doubleValue] + avail * [rowW[r] doubleValue] / total + gap)];
    for (NSUInteger i = 0; i < cards.count; i++) {
        NSArray *pl = places[i];
        NSInteger r = [pl[0] integerValue], c = [pl[1] integerValue], w = [pl[2] integerValue], h = [pl[3] integerValue];
        CGFloat y = [edges[r] doubleValue];
        CGRect f = CGRectMake(rect.origin.x + c * (cellW + gap), y, w * cellW + (w - 1) * gap, [edges[r + h] doubleValue] - y - gap);
        HACard *card = cards[i];
        // bounds + center (not frame) so entrance transforms in flight aren't distorted
        card.bounds = CGRectMake(0, 0, f.size.width, f.size.height);
        card.center = CGPointMake(CGRectGetMidX(f), CGRectGetMidY(f));
    }
    if (outEdges) *outEdges = edges;
    return maxRow;
}

- (BOOL)hasRail { return self.drawers.count > 0; }

- (CGRect)drawerFrame:(HADrawer *)d open:(BOOL)open {
    CGFloat W = self.view.bounds.size.width, H = self.view.bounds.size.height;
    CGFloat frac = [d.spec[@"width"] respondsToSelector:@selector(doubleValue)] ? [d.spec[@"width"] doubleValue] : 0.55;
    CGFloat w = MAX(300, MIN(W - kRailW, (W - kRailW) * frac));
    return CGRectMake(open ? kRailW : kRailW - w - 30, 0, w, H);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat W = self.view.bounds.size.width, H = self.view.bounds.size.height, m = 20, gap = 16;
    CGFloat left = [self hasRail] ? kRailW : 0;

    self.rail.hidden = ![self hasRail];
    self.rail.frame = CGRectMake(0, 0, kRailW, H);
    CGFloat by = 24;
    NSInteger railCount = 0;   // buttons above Home: squeeze them together when there are many
    for (HADrawer *d in self.drawers)
        if (![d.spec[@"hidden"] boolValue] && !((d == self.drawers.lastObject) && [((HACard *)d.cards.firstObject).spec[@"type"] isEqual:@"home"])) railCount++;
    CGFloat railStep = MIN(88, (H - 24 - 104) / MAX(1, railCount)), railH = MIN(76, railStep - 4);
    for (HADrawer *d in self.drawers) {
        BOOL isHome = (d == self.drawers.lastObject) && [((HACard *)d.cards.firstObject).spec[@"type"] isEqual:@"home"];
        BOOL hidden = [d.spec[@"hidden"] boolValue];   // opened only from a card's "opens"
        d.railButton.hidden = hidden;
        CGFloat y = isHome ? H - 24 - 76 : by;   // Home sits at the bottom of the rail
        d.railButton.frame = CGRectMake(8, y, kRailW - 16, isHome ? 76 : railH);
        if (!isHome && !hidden) by += railStep;
        d.view.frame = [self drawerFrame:d open:(d == self.openDrawer)];
        d.view.layer.shadowPath = [UIBezierPath bezierPathWithRect:d.view.bounds].CGPath;   // no offscreen shadow pass
        CGRect inner = CGRectInset(d.view.bounds, 16, 16);
        if (d.tabs) {   // tab buttons along the top, each tab laid out with its own grid settings
            NSInteger nt = d.tabBar.subviews.count;
            CGFloat tw = MIN(190, (inner.size.width - (nt - 1) * 10) / MAX(1, nt));
            d.tabBar.frame = CGRectMake(inner.origin.x, inner.origin.y, inner.size.width, 46);
            for (UIButton *b in d.tabBar.subviews) b.frame = CGRectMake(b.tag * (tw + 10), 0, tw, 46);
            inner.origin.y += 58; inner.size.height -= 58;
            for (NSUInteger i = 0; i < d.tabCards.count; i++) {
                NSDictionary *t = d.tabs[i];
                CGRect area = inner;   // "width": 0.5 keeps a narrow section to half of the drawer
                if ([t[@"width"] respondsToSelector:@selector(doubleValue)]) area.size.width = inner.size.width * MAX(0.2, MIN(1, [t[@"width"] doubleValue]));
                [self placeCards:d.tabCards[i] inRect:area columns:HA_Int(t[@"columns"], 1) rows:HA_Int(t[@"rows"], 0)
                         weights:[t[@"row_heights"] isKindOfClass:[NSArray class]] ? t[@"row_heights"] : nil gap:gap edges:NULL];
            }
        } else {
            [self placeCards:d.cards inRect:inner
                     columns:[d.spec[@"columns"] respondsToSelector:@selector(integerValue)] ? [d.spec[@"columns"] integerValue] : 1
                        rows:[d.spec[@"rows"] respondsToSelector:@selector(integerValue)] ? [d.spec[@"rows"] integerValue] : 0
                     weights:[d.spec[@"row_heights"] isKindOfClass:[NSArray class]] ? d.spec[@"row_heights"] : nil gap:gap edges:NULL];
        }
    }
    self.scrim.frame = self.view.bounds;

    self.clockLabel.frame = CGRectMake(left + m + 4, 10, 340, 80);
    self.dateLabel.frame = CGRectMake(left + m + 8, 86, 420, 26);
    self.gearButton.frame = CGRectMake(W - m - 44, 16, 44, 44);
    // read left to right: today (icon, temperature), tomorrow, the day after
    CGFloat wxR = W - m - 44 - 8, dayW = 84, daysW = self.wxDays.count * dayW;
    self.wxIcon.frame = CGRectMake(wxR - daysW - 232, 12, 76, 70);
    self.wxTemp.frame = CGRectMake(wxR - daysW - 150, 12, 140, 70);
    self.wxText.frame = CGRectMake(wxR - 470, 82, 470, 26);
    for (NSUInteger i = 0; i < self.wxDays.count; i++) {
        CGFloat x = wxR - daysW + i * dayW;
        NSArray *col = self.wxDays[i];
        ((UILabel *)col[0]).frame = CGRectMake(x, 12, 80, 18);
        ((UILabel *)col[1]).frame = CGRectMake(x, 30, 80, 34);
        ((UILabel *)col[2]).frame = CGRectMake(x, 64, 80, 20);
    }
    self.wxTap.frame = CGRectMake(wxR - daysW - 232, 0, daysW + 232, 112);   // tapping anywhere on it opens the Forecast drawer
    self.statusLabel.frame = CGRectMake(left + m + 8, 110, 420, 14);   // under the date, clear of the weather
    self.setupOverlay.frame = self.view.bounds;
    [self.setupOverlay viewWithTag:7].frame = CGRectMake(120, self.view.bounds.size.height / 2 - 170, self.view.bounds.size.width - 240, 180);
    [self.setupOverlay viewWithTag:8].frame = CGRectMake(self.view.bounds.size.width / 2 - 130, self.view.bounds.size.height / 2 + 30, 260, 64);
    self.dimOverlay.frame = self.view.bounds;
    self.frameView.frame = self.view.bounds;
    for (UIImageView *iv in @[self.frameFront, self.frameBack]) {   // bounds/center: Ken Burns transform may be running
        iv.bounds = self.view.bounds;
        iv.center = CGPointMake(W / 2, H / 2);
    }
    self.frameClock.frame = CGRectMake(W - 260, H - 76, 236, 56);

    // main grid: one container per screen, side by side inside the paging scroll view
    CGFloat top = 124, pw = W - left, ph = H - top;
    NSArray *pgs = [self pageSpecsOf:self.layout];
    CGRect sf = CGRectMake(left, top, pw, ph);
    if (!CGRectEqualToRect(self.pagesScroll.frame, sf)) self.pagesScroll.frame = sf;
    self.pagesScroll.contentSize = CGSizeMake(pw * MAX(1, (NSInteger)self.pageViews.count), ph);
    self.pagesScroll.scrollEnabled = !self.editing && self.pageViews.count > 1;
    if (!self.pagesScroll.dragging && !self.pagesScroll.decelerating) self.pagesScroll.contentOffset = CGPointMake(self.page * pw, 0);
    for (NSUInteger i = 0; i < self.pageViews.count; i++) {
        ((UIView *)self.pageViews[i]).frame = CGRectMake(i * pw, 0, pw, ph);
        NSDictionary *pg = i < pgs.count ? pgs[i] : @{};
        CGRect gr = CGRectMake(m, 0, pw - 2 * m, ph - m);
        NSArray *edges = nil;
        NSInteger used = [self placeCards:self.pageCards[i] inRect:gr columns:HA_Int(pg[@"columns"], 3) rows:HA_Int(pg[@"rows"], 0)
                                  weights:[pg[@"row_heights"] isKindOfClass:[NSArray class]] ? pg[@"row_heights"] : nil gap:gap edges:&edges];
        if ((NSInteger)i == self.page) { self.mainRows = used; self.gridRect = gr; self.gridGap = gap; self.gridEdges = edges; }
    }
    self.pageDots.frame = CGRectMake(left, H - 19, pw, 16);
    self.editBar.frame = CGRectMake(left, 0, W - left, top - 4);
    self.themeView.frame = self.view.bounds;
}

#pragma mark - Drawers

- (void)railTapped:(UIButton *)b {
    HADrawer *target = nil;
    for (HADrawer *d in self.drawers) if (d.railButton == b) target = d;
    if (!target) return;
    if (self.openDrawer == target) { [self closeDrawer]; return; }
    [self closeDrawerAnimated:NO];
    [self openDrawer:target];
}

- (void)openDrawer:(HADrawer *)d {
    self.openDrawer = d;
    self.lastTouch = [NSDate date];
    d.view.frame = [self drawerFrame:d open:NO];
    d.view.hidden = NO;
    [self.view insertSubview:self.scrim belowSubview:d.view];
    self.scrim.hidden = NO;
    [self applyTabs:d];
    for (HACard *c in d.cards) { c.active = YES; [c reload]; }
    HA_SetBG(d.railButton, HA_OFF());
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    // slide out with a little spring, cards inside drift in just behind it
    [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.86 initialSpringVelocity:0.5
                        options:UIViewAnimationOptionAllowUserInteraction animations:^{
        d.view.frame = [self drawerFrame:d open:YES];
        self.scrim.alpha = 1;
    } completion:nil];
    for (NSUInteger i = 0; i < d.cards.count; i++) {
        HACard *c = d.cards[i];
        c.alpha = 0;
        c.transform = CGAffineTransformMakeTranslation(-24, 0);
        [UIView animateWithDuration:0.35 delay:0.08 + i * 0.05 options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseOut
                         animations:^{ c.alpha = 1; c.transform = CGAffineTransformIdentity; } completion:nil];
    }
    [self poll];
}

- (void)closeDrawer { [self closeDrawerAnimated:YES]; }

- (void)closeDrawerAnimated:(BOOL)animated {
    HADrawer *d = self.openDrawer;
    if (!d) return;
    self.openDrawer = nil;
    for (HACard *c in d.cards) c.active = NO;
    HA_SetBG(d.railButton, [UIColor clearColor]);
    void (^anim)(void) = ^{ d.view.frame = [self drawerFrame:d open:NO]; self.scrim.alpha = 0; };
    void (^done)(BOOL) = ^(BOOL f) { if (self.openDrawer != d) d.view.hidden = YES; if (!self.openDrawer) self.scrim.hidden = YES; };
    if (animated) [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:anim completion:done];
    else { anim(); done(YES); }
}

#pragma mark - Timers

- (NSArray *)liveCards {
    NSMutableArray *all = [NSMutableArray arrayWithArray:self.cards];
    if (self.openDrawer) [all addObjectsFromArray:self.openDrawer.cards];
    return all;
}

- (void)tickSecond {
    static NSDateFormatter *tf, *df;
    if (!tf) {
        tf = [[NSDateFormatter alloc] init]; tf.dateFormat = @"h:mm";
        df = [[NSDateFormatter alloc] init]; df.dateFormat = @"EEEE, MMMM d";
    }
    NSDate *now = [NSDate date];
    self.clockLabel.text = [tf stringFromDate:now];
    self.dateLabel.text = [df stringFromDate:now];
    for (HACard *c in self.cards) [c tick];
    for (HADrawer *d in self.drawers) for (HACard *c in d.cards) [c tick];

    self.seconds++;
    if (self.seconds % 60 == 0) [self fetchLayout];
    if (self.seconds % 600 == 0) for (HACard *c in self.cards) [c reload];

    if (self.openDrawer && [now timeIntervalSinceDate:self.lastTouch] > 90) [self closeDrawer];
    if (self.editing) self.lastSeen = now;   // never dim while the editor is open
    NSTimeInterval idle = [now timeIntervalSinceDate:self.lastSeen];
    if (self.presence.running) {
        if (self.idleMode == 0 && idle > self.dimAfter) [self enterIdle];
        else if (self.idleMode == 1 && idle > self.blankAfter) [self enterBlank];
    }
    if (self.idleMode == 1) {
        self.frameClock.text = [tf stringFromDate:now];
        if ([now timeIntervalSinceDate:self.lastPhoto] > self.photoInterval) [self nextPhoto];
    }
    [self alertTick];
    if (self.seconds % 3 == 0) [self pollDetections];
    [self runDebugCommands];
    if (self.seconds % 300 == 5) [self refreshBadges];
    if (self.weatherEntity && (!self.lastForecast || [now timeIntervalSinceDate:self.lastForecast] > 1800)) [self loadHeaderForecast];
    if (!self.lastBattery || [now timeIntervalSinceDate:self.lastBattery] > 300) [self reportBattery];
}

- (void)poll {
    HAClient *ha = [HAClient shared];
    self.setupOverlay.hidden = [ha isConfigured];
    if (![ha isConfigured]) return;
    // doorbell / timer are watched even while the photo frame or blank screen is showing
    NSMutableOrderedSet *ids = [NSMutableOrderedSet orderedSetWithArray:[self watchedEntities]];
    NSSet *watched = [NSSet setWithArray:[self watchedEntities]];
    if (self.idleMode == 0) {
        for (HACard *c in [self liveCards]) [ids addObjectsFromArray:[c entityIds]];
        if (self.weatherEntity) [ids addObject:self.weatherEntity];
    }
    for (NSString *eid in ids) {
        [ha getState:eid completion:^(NSDictionary *s, NSError *e) {
            if (e.code == 401) { self.serviceError = @"token rejected (HTTP 401)"; [self updateStatus]; }
            if (!s) return;
            self.states[eid] = s;
            if ([watched containsObject:eid]) [self checkAlerts:eid state:s];
            if (self.idleMode != 0) return;
            if (self.demoUntil && [self.demoUntil timeIntervalSinceNow] > 0) return;
            for (HACard *c in [self liveCards]) if ([[c entityIds] containsObject:eid]) [c updateStates:self.states];
            if ([eid isEqualToString:self.weatherEntity]) [self applyWeather:s];
        }];
    }
}

#pragma mark - Header forecast, battery

- (BOOL)screenAwake { return self.idleMode == 0; }

- (void)weatherTapped { [self card:nil openDrawer:@"Forecast"]; }

// Next two days for the header (refreshed every 30 min): forecast.json if Home Assistant provides it,
// otherwise the weather entity's daily forecast.
- (void)loadHeaderForecast {
    self.lastForecast = [NSDate date];
    NSString *ent = self.weatherEntity;
    [[HAClient shared] fetchPanelFile:@"forecast.json" completion:^(NSData *data, NSError *error) {
        id f = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSArray *daily = [f isKindOfClass:[NSDictionary class]] ? HA_CleanList(f[@"daily"]) : nil;
        if (daily.count >= 2) { [self applyHeaderForecast:daily]; return; }
        [[HAClient shared] callServiceWithResponse:@"weather" service:@"get_forecasts" data:@{@"entity_id": ent, @"type": @"daily"} completion:^(id json, NSError *e) {
            [self applyHeaderForecast:HA_CleanList(json[@"service_response"][ent][@"forecast"])];
        }];
    }];
}

- (void)applyHeaderForecast:(NSArray *)fc {
    if (fc.count < 2) return;
    NSDateFormatter *f = [[NSDateFormatter alloc] init]; f.dateFormat = @"EEE";
    // skip entries dated today or earlier, then show the next two days
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSMutableArray *next = [NSMutableArray array];
    for (NSDictionary *d in fc) {
        NSDate *date = HA_ParseISO(d[@"datetime"]);
        if (date && [cal compareDate:date toDate:[NSDate date] toUnitGranularity:NSCalendarUnitDay] == NSOrderedDescending) [next addObject:d];
    }
    if (next.count < 1) next = [[fc subarrayWithRange:NSMakeRange(1, fc.count - 1)] mutableCopy];
    for (NSUInteger i = 0; i < self.wxDays.count && i < next.count; i++) {
        NSDictionary *d = next[i];
        NSArray *col = self.wxDays[i];
        NSDate *date = HA_ParseISO(d[@"datetime"]);
        ((UILabel *)col[0]).text = i == 0 ? @"TOMORROW" : [[f stringFromDate:date ?: [NSDate date]] uppercaseString];
        ((UILabel *)col[1]).text = HA_WeatherGlyph(d[@"condition"]);
        ((UILabel *)col[2]).text = d[@"templow"] ? [NSString stringWithFormat:@"%.0f° / %.0f°", [d[@"temperature"] doubleValue], [d[@"templow"] doubleValue]]
                                                 : [NSString stringWithFormat:@"%.0f°", [d[@"temperature"] doubleValue]];
    }
}

// Reports battery level + charging to HA as sensor.<panel>_ipad_battery, so an automation can switch a
// smart plug on/off and keep the battery between two levels (old iOS has no charge limit of its own).
- (void)reportBattery {
    self.lastBattery = [NSDate date];
    HAClient *ha = [HAClient shared];
    if (![ha isConfigured]) return;
    UIDevice *dev = [UIDevice currentDevice];
    float level = dev.batteryLevel;
    if (level < 0) return;   // unknown
    UIDeviceBatteryState st = dev.batteryState;
    NSString *charging = st == UIDeviceBatteryStateCharging ? @"charging" : (st == UIDeviceBatteryStateFull ? @"full" : @"unplugged");
    NSString *panel = [[ha.panel lowercaseString] stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    NSString *path = [NSString stringWithFormat:@"/api/states/sensor.%@_ipad_battery", panel];
    NSDictionary *body = @{ @"state": [NSString stringWithFormat:@"%.0f", level * 100],
                            @"attributes": @{ @"unit_of_measurement": @"%", @"device_class": @"battery", @"state_class": @"measurement",
                                              @"charging": charging, @"friendly_name": [NSString stringWithFormat:@"%@ iPad battery", [ha.panel capitalizedString]] } };
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[ha.baseURL stringByAppendingString:path]]];
    r.HTTPMethod = @"POST";
    [r setValue:[NSString stringWithFormat:@"Bearer %@", ha.token] forHTTPHeaderField:@"Authorization"];
    [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    r.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [[[NSURLSession sharedSession] dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *resp, NSError *err) {
        NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
        if (err || code >= 300) HALog(@"battery report failed: %ld %@", (long)code, err.localizedDescription ?: @"");
    }] resume];
}

- (void)applyWeather:(NSDictionary *)s {
    NSDictionary *a = s[@"attributes"];
    NSString *unit = Str(a[@"temperature_unit"]) ?: @"°";
    self.wxIcon.text = HA_WeatherGlyph(Str(s[@"state"]));
    self.wxTemp.text = [NSString stringWithFormat:@"%.0f%@", [a[@"temperature"] doubleValue], [unit hasPrefix:@"°"] ? @"°" : unit];
    self.wxText.text = [NSString stringWithFormat:@"%@ · Humidity %@%%", HA_WeatherText(Str(s[@"state"])), a[@"humidity"] ?: @"--"];
}

- (void)updateStatus {
    NSString *msg = self.layoutError ?: self.serviceError ?: self.presence.problem;
    self.statusLabel.text = msg ? [@"⚠︎ " stringByAppendingString:msg] : @"";
}

#pragma mark - HACardHost

- (void)card:(HACard *)card callService:(NSString *)service data:(NSDictionary *)data {
    NSArray *parts = [service componentsSeparatedByString:@"."];
    if (parts.count != 2) return;
    [[HAClient shared] callService:parts[0] service:parts[1] data:data completion:^(id json, NSError *e) {
        self.serviceError = e ? [NSString stringWithFormat:@"%@: %@", service, e.localizedDescription] : nil;
        [self updateStatus];
        if (e) HALog(@"%@ failed: %@", service, e.localizedDescription);
        // Cast/Zigbee state lands a moment after the call returns: look again at 0.6 s and 2 s
        for (NSNumber *delay in @[@0.6, @2.0])
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self poll]; });
    }];
}

- (void)cardWantsRefresh:(HACard *)card { [self poll]; }

- (void)card:(HACard *)card openDrawer:(NSString *)name {
    for (HADrawer *d in self.drawers) {
        if ([[Str(d.spec[@"name"]) lowercaseString] isEqualToString:[name lowercaseString]]) {
            if (self.openDrawer == d) return;
            [self closeDrawerAnimated:NO];
            [self openDrawer:d];
            return;
        }
    }
    for (HADrawer *d in self.drawers) {   // or a tab of that name inside a drawer
        for (NSUInteger i = 0; i < d.tabs.count; i++) {
            if (![[Str(d.tabs[i][@"name"]) lowercaseString] isEqualToString:[name lowercaseString]]) continue;
            [self selectTab:i ofDrawer:d];
            if (self.openDrawer != d) { [self closeDrawerAnimated:NO]; [self openDrawer:d]; }
            return;
        }
    }
}

#pragma mark - Theme

- (UIColor *)shade:(UIColor *)c by:(CGFloat)amount {
    CGFloat r = 0, g = 0, b = 0, a = 1;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) { [c getWhite:&r alpha:&a]; g = b = r; }
    CGFloat lum = 0.3 * r + 0.59 * g + 0.11 * b;
    CGFloat k = lum > 0.5 ? -amount : amount;   // lighten dark themes, darken light ones
    return [UIColor colorWithRed:MAX(0, MIN(1, r + k)) green:MAX(0, MIN(1, g + k)) blue:MAX(0, MIN(1, b + k)) alpha:a];
}

// defaults <- layout "theme" <- colours picked on this iPad (Settings -> Colors)
- (void)applyTheme {
    NSMutableDictionary *t = [NSMutableDictionary dictionary];
    if ([self.layout[@"theme"] isKindOfClass:[NSDictionary class]]) [t addEntriesFromDictionary:self.layout[@"theme"]];
    NSDictionary *mine = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"theme"];
    if (mine) [t addEntriesFromDictionary:mine];
    HA_SetTheme(t);
    self.view.backgroundColor = HA_BG();
    self.rail.backgroundColor = [self shade:HA_BG() by:0.05];
    self.clockLabel.textColor = self.wxIcon.textColor = self.wxTemp.textColor = HA_TEXT();
    self.dateLabel.textColor = self.wxText.textColor = self.statusLabel.textColor = HA_DIM();
    [self.gearButton setTitleColor:HA_DIM() forState:UIControlStateNormal];
}

- (NSArray *)themeRows {
    return @[ @[@"accent", @"Lights / on"], @[@"media", @"Media"], @[@"cool", @"Cooling"], @[@"heat", @"Heating"],
              @[@"background", @"Background"], @[@"card", @"Cards"], @[@"button", @"Buttons (off)"],
              @[@"text", @"Text"], @[@"dim", @"Secondary text"] ];
}

- (NSArray *)palette {
    return @[ @"#FFB340", @"#FF9500", @"#FF453A", @"#FF375F", @"#BF5AF2", @"#5E5CE6", @"#0A84FF", @"#32ADE6",
              @"#30D158", @"#66D4CF", @"#FFFFFF", @"#C7C7CC", @"#8E8E93", @"#3A3A3C", @"#1C1C1E", @"#0A0A0C" ];
}

- (void)showThemePicker {
    [self.themeView removeFromSuperview];
    UIView *bg = [[UIView alloc] initWithFrame:self.view.bounds];
    bg.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 820, 600)];
    panel.center = CGPointMake(bg.bounds.size.width / 2, bg.bounds.size.height / 2);
    panel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    panel.backgroundColor = HA_CARD();
    panel.layer.cornerRadius = 20;
    [bg addSubview:panel];
    UILabel *title = [self label:24 weight:0.3 color:HA_TEXT() in:panel];
    title.text = @"Colors";
    title.frame = CGRectMake(24, 18, 300, 30);
    NSDictionary *current = HA_DefaultTheme();
    NSMutableDictionary *merged = [current mutableCopy];
    if ([self.layout[@"theme"] isKindOfClass:[NSDictionary class]]) [merged addEntriesFromDictionary:self.layout[@"theme"]];
    NSDictionary *mine = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"theme"];
    if (mine) [merged addEntriesFromDictionary:mine];
    NSArray *rows = [self themeRows], *pal = [self palette];
    CGFloat y = 64;
    for (NSUInteger r = 0; r < rows.count; r++) {
        UILabel *l = [self label:16 weight:0.2 color:HA_TEXT() in:panel];
        l.text = rows[r][1];
        l.frame = CGRectMake(24, y, 150, 40);
        NSString *sel = [[Str(merged[rows[r][0]]) uppercaseString] stringByReplacingOccurrencesOfString:@"#" withString:@""];
        for (NSUInteger i = 0; i < pal.count; i++) {
            UIButton *sw = [UIButton buttonWithType:UIButtonTypeCustom];
            sw.frame = CGRectMake(180 + i * 38, y + 4, 32, 32);
            sw.backgroundColor = HA_ColorFromHex(pal[i]);
            sw.layer.cornerRadius = 16;
            sw.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:0.6].CGColor;
            sw.layer.borderWidth = 1;
            if ([[pal[i] stringByReplacingOccurrencesOfString:@"#" withString:@""] isEqualToString:sel]) {
                sw.layer.borderColor = HA_TEXT().CGColor;
                sw.layer.borderWidth = 3;
            }
            sw.tag = r * 100 + i;
            [sw addTarget:self action:@selector(swatchTapped:) forControlEvents:UIControlEventTouchUpInside];
            [panel addSubview:sw];
        }
        y += 52;
    }
    UIButton *reset = HA_Chip(@"Reset to defaults", self, @selector(themeReset));
    reset.frame = CGRectMake(24, 540, 200, 44);
    UIButton *done = HA_Chip(@"Done", self, @selector(themeDone));
    done.frame = CGRectMake(820 - 24 - 140, 540, 140, 44);
    done.backgroundColor = HA_ACCENT();
    [done setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    [panel addSubview:reset]; [panel addSubview:done];
    self.themeView = bg;
    [self.view addSubview:bg];
}

- (void)swatchTapped:(UIButton *)sw {
    NSArray *row = [self themeRows][sw.tag / 100];
    NSString *hex = [self palette][sw.tag % 100];
    NSMutableDictionary *mine = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"theme"] mutableCopy] ?: [NSMutableDictionary dictionary];
    mine[row[0]] = hex;
    [[NSUserDefaults standardUserDefaults] setObject:mine forKey:@"theme"];
    [self rebuildForTheme];
    [self showThemePicker];
}

- (void)themeReset {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"theme"];
    [self rebuildForTheme];
    [self showThemePicker];
}

- (void)themeDone { [self.themeView removeFromSuperview]; self.themeView = nil; }

- (void)rebuildForTheme {
    if (self.layoutData) [self applyLayoutData:self.layoutData];
    else [self applyTheme];
    [self.view setNeedsLayout];
}

#pragma mark - Presence / dimming

// Idle states: 0 = dashboard, 1 = photo frame (nobody seen for dim_after), 2 = blank (nobody for blank_after).
// Brightness is left to iOS; it's only forced to 0 while blank and restored afterwards.

- (void)sawSomeone:(NSString *)reason {
    // ignore the camera reacting to our own screen changing (photo cross-fades, entering the frame)
    if (self.idleMode != 0 && self.ignorePresenceUntil && [self.ignorePresenceUntil timeIntervalSinceNow] > 0) return;
    self.lastSeen = [NSDate date];
    self.lastReason = reason;
    if (self.idleMode != 0) [self wake];
}

- (void)enterIdle {
    [self closeDrawerAnimated:NO];
    if (self.photoURL.length) [self showFrame];
    else [self enterBlank];
}

- (void)showFrame {
    self.idleMode = 1;
    self.ignorePresenceUntil = [NSDate dateWithTimeIntervalSinceNow:3];
    self.frameView.hidden = NO;
    self.frameView.userInteractionEnabled = YES;
    [UIView animateWithDuration:1.2 animations:^{ self.frameView.alpha = 1; }];
    [self nextPhoto];
}

- (void)nextPhoto {
    self.lastPhoto = [NSDate date];
    __weak PanelViewController *ws = self;
    [[HAClient shared] fetchImageURL:self.photoURL auth:NO maxSide:1024 completion:^(UIImage *img) {
        PanelViewController *ss = ws;
        if (!img || ss.idleMode != 1) return;
        ss.ignorePresenceUntil = [NSDate dateWithTimeIntervalSinceNow:3];
        UIImageView *front = ss.frameFront, *back = ss.frameBack;
        [back.layer removeAllAnimations];
        back.transform = CGAffineTransformIdentity;
        back.image = img;
        back.alpha = 0;
        [ss.frameView insertSubview:back aboveSubview:front];
        // cross-fade, then a slow Ken Burns drift for the rest of the interval
        [UIView animateWithDuration:1.5 animations:^{ back.alpha = 1; } completion:^(BOOL f) { front.alpha = 0; }];
        CGFloat dx = (arc4random_uniform(2) ? 1 : -1) * 18, dy = (arc4random_uniform(2) ? 1 : -1) * 12;
        [UIView animateWithDuration:ss.photoInterval + 3 delay:0 options:UIViewAnimationOptionCurveLinear | UIViewAnimationOptionAllowUserInteraction animations:^{
            back.transform = CGAffineTransformTranslate(CGAffineTransformMakeScale(1.08, 1.08), dx, dy);
        } completion:nil];
        ss.frameFront = back; ss.frameBack = front;
    }];
}

- (void)enterBlank {
    self.idleMode = 2;
    if (self.savedBrightness < 0) self.savedBrightness = [UIScreen mainScreen].brightness;
    self.dimOverlay.userInteractionEnabled = YES;
    [UIView animateWithDuration:1.5 animations:^{ self.dimOverlay.alpha = 1; } completion:^(BOOL f) {
        if (self.idleMode == 2) { self.frameView.hidden = YES; self.frameView.alpha = 0; }
    }];
    [UIScreen mainScreen].brightness = 0;
}

- (void)wake {
    self.lastSeen = [NSDate date];
    if (self.idleMode == 0) return;
    self.idleMode = 0;
    self.ignorePresenceUntil = nil;
    if (self.savedBrightness >= 0) { [UIScreen mainScreen].brightness = self.savedBrightness; self.savedBrightness = -1; }
    self.dimOverlay.userInteractionEnabled = NO;
    self.frameView.userInteractionEnabled = NO;
    [UIView animateWithDuration:0.25 animations:^{ self.dimOverlay.alpha = 0; self.frameView.alpha = 0; }
                     completion:^(BOOL f) { if (self.idleMode == 0) self.frameView.hidden = YES; }];
    [self poll];
}

#pragma mark - Alerts (doorbell, timer) and rail badges

- (NSArray *)watchedEntities {
    NSDictionary *al = [self.layout[@"alerts"] isKindOfClass:[NSDictionary class]] ? self.layout[@"alerts"] : nil;
    NSMutableArray *ids = [NSMutableArray array];
    NSDictionary *db = [al[@"doorbell"] isKindOfClass:[NSDictionary class]] ? al[@"doorbell"] : nil;
    if (Str(db[@"trigger"])) [ids addObject:db[@"trigger"]];
    if (Str(al[@"timer"])) [ids addObject:al[@"timer"]];
    return ids;
}

- (void)checkAlerts:(NSString *)eid state:(NSDictionary *)s {
    NSDictionary *al = self.layout[@"alerts"];
    NSDictionary *db = [al[@"doorbell"] isKindOfClass:[NSDictionary class]] ? al[@"doorbell"] : nil;
    NSString *st = Str(s[@"state"]) ?: @"";
    NSDictionary *prev = self.watchPrev[eid];
    self.watchPrev[eid] = @{@"state": st, @"finishes_at": Str(s[@"attributes"][@"finishes_at"]) ?: @""};
    if (!prev || [st isEqualToString:@"unavailable"] || [st isEqualToString:@"unknown"]) return;   // first sighting: just remember
    if ([eid isEqualToString:Str(db[@"trigger"])]) {
        BOOL isEvent = [eid hasPrefix:@"event."];
        BOOL rang = isEvent ? ![st isEqualToString:prev[@"state"]] : ([st isEqualToString:@"on"] && ![prev[@"state"] isEqualToString:@"on"]);
        if (rang) [self showAlert:@"doorbell" title:Str(db[@"title"]) ?: @"Someone's at the door" camera:Str(db[@"camera"])];
    } else if ([eid isEqualToString:Str(al[@"timer"])]) {
        NSDate *was = HA_ParseISO(prev[@"finishes_at"]);
        if ([prev[@"state"] isEqualToString:@"active"] && [st isEqualToString:@"idle"] && was && [was timeIntervalSinceNow] < 4)
            [self showAlert:@"timer" title:@"Timer done" camera:nil];
    }
}

- (void)showAlert:(NSString *)kind title:(NSString *)title camera:(NSString *)camera { [self showAlert:kind title:title camera:camera url:nil]; }

// camera: a Home Assistant camera entity; url: a snapshot address fetched directly (go2rtc, Frigate)
- (void)showAlert:(NSString *)kind title:(NSString *)title camera:(NSString *)camera url:(NSString *)url {
    [self wake];
    [self dismissAlert];
    self.alertKind = kind;
    self.alertCamera = camera;
    self.alertURL = url;
    self.alertImageBusy = NO;
    BOOL detection = [kind isEqualToString:@"detection"];
    if (url && !camera) camera = url;   // either one gives the alert a picture
    UIView *bg = [[UIView alloc] initWithFrame:self.view.bounds];
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    bg.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];
    CGFloat W = bg.bounds.size.width, H = bg.bounds.size.height;
    UILabel *t = [self label:44 weight:0.3 color:HA_TEXT() in:bg];
    t.text = [NSString stringWithFormat:@"%@  %@", [kind isEqualToString:@"timer"] ? @"⏰" : (detection ? @"\U0001F464" : @"\U0001F514"), title];
    t.textAlignment = NSTextAlignmentCenter;
    t.frame = CGRectMake(40, camera ? 24 : H / 2 - 120, W - 80, 60);
    if (camera) {
        UIImageView *iv = [[UIImageView alloc] initWithFrame:detection ? CGRectMake(24, 92, W - 48, H - 92 - 100) : CGRectMake(80, 96, W - 160, H - 96 - 120)];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.backgroundColor = [UIColor blackColor];
        iv.layer.cornerRadius = 16; iv.clipsToBounds = YES;
        iv.tag = 77;
        [bg addSubview:iv];
        UILabel *wait = [self label:18 weight:0 color:HA_DIM() in:iv];
        wait.text = @"Loading camera…"; wait.textAlignment = NSTextAlignmentCenter;
        wait.frame = iv.bounds; wait.tag = 78;
    }
    UIButton *dismiss = HA_Chip(@"Dismiss", self, @selector(dismissAlert));
    dismiss.titleLabel.font = HA_FONT(24, 0.3);
    dismiss.frame = detection ? CGRectMake((W - 300) / 2, H - 84, 300, 60) : CGRectMake((W - 300) / 2, H - 100, 300, 70);
    dismiss.layer.cornerRadius = 20;
    HA_SetBG(dismiss, HA_ACCENT());
    [dismiss setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    [bg addSubview:dismiss];
    bg.alpha = 0;
    bg.transform = CGAffineTransformMakeScale(1.06, 1.06);
    [self.view addSubview:bg];
    [UIView animateWithDuration:0.3 animations:^{ bg.alpha = 1; bg.transform = CGAffineTransformIdentity; }];
    self.alertView = bg;
    self.alertStarted = [NSDate date];
    self.alertTicks = 0;
    [self alertTick];
}

// called every second while an alert is up: sound, camera refresh, auto-dismiss
- (void)alertTick {
    if (!self.alertView) return;
    NSTimeInterval age = -[self.alertStarted timeIntervalSinceNow];
    BOOL timer = [self.alertKind isEqualToString:@"timer"], detection = [self.alertKind isEqualToString:@"detection"];
    if ((timer && age > 180) || (detection && age > self.alertSeconds) || (!timer && age > 90)) { [self dismissAlert]; return; }
    self.lastSeen = [NSDate date];
    if (detection ? self.alertTicks == 0 : (timer ? (self.alertTicks % 3 == 0 && self.alertTicks < 60) : (self.alertTicks == 0 || self.alertTicks == 4)))
        AudioServicesPlaySystemSound(timer ? 1005 : 1007);
    if (self.alertURL && !self.alertImageBusy) {   // live view: a fresh snapshot every second, never two at once
        __weak UIView *bg = self.alertView;
        __weak PanelViewController *ws = self;
        self.alertImageBusy = YES;
        [[HAClient shared] fetchImageURL:self.alertURL auth:NO maxSide:1024 completion:^(UIImage *img) {
            ws.alertImageBusy = NO;
            UIImageView *iv = (UIImageView *)[bg viewWithTag:77];
            if (img) { [iv viewWithTag:78].hidden = YES; iv.image = img; }
            else if (!iv.image) ((UILabel *)[iv viewWithTag:78]).text = @"No camera image available";
        }];
    }
    if (self.alertCamera && !self.alertURL && self.alertTicks % 2 == 0) {
        __weak UIView *bg = self.alertView;
        [[HAClient shared] fetchImageURL:[@"/api/camera_proxy/" stringByAppendingString:self.alertCamera] auth:YES maxSide:1024 completion:^(UIImage *img) {
            UIImageView *iv = (UIImageView *)[bg viewWithTag:77];
            if (img) { [iv viewWithTag:78].hidden = YES; HA_Fade(iv, 0.2); iv.image = img; }
            else ((UILabel *)[iv viewWithTag:78]).text = @"No camera image available";
        }];
    }
    self.alertTicks++;
}

- (void)dismissAlert {
    UIView *v = self.alertView;
    self.alertView = nil;
    if (v) [UIView animateWithDuration:0.2 animations:^{ v.alpha = 0; } completion:^(BOOL f) { [v removeFromSuperview]; }];
}

#pragma mark - Camera pop-up on a detection

// "alerts": { "detections": { "frigate": "http://192.168.1.61:5000", "labels": ["person"], "seconds": 20,
//     "cooldown": 60, "quiet": { "after": "23:00", "before": "06:00" },
//     "cameras": { "front_yard": { "name": "Front Yard", "url": "http://.../api/frame.jpeg?src=front_yard&width=960" } } } }
// Every 3 seconds the panel asks Frigate for the detections in progress. A new one wakes the screen
// and shows that camera full screen, refreshed every second, for "seconds". Each camera then stays
// quiet for "cooldown" seconds. Nothing goes through Home Assistant.
- (NSDictionary *)detectConfig {
    NSDictionary *al = [self.layout[@"alerts"] isKindOfClass:[NSDictionary class]] ? self.layout[@"alerts"] : nil;
    NSDictionary *d = [al[@"detections"] isKindOfClass:[NSDictionary class]] ? al[@"detections"] : nil;
    return Str(d[@"frigate"]).length ? d : nil;
}

- (NSString *)detectBase:(NSDictionary *)cfg {
    NSString *b = Str(cfg[@"frigate"]) ?: @"";
    while ([b hasSuffix:@"/"]) b = [b substringToIndex:b.length - 1];
    return b;
}

- (void)pollDetections {
    NSDictionary *cfg = [self detectConfig];
    if (!cfg || self.detectBusy || self.editing) return;
    // everything that started in the last 40 s; whether it is still going on is decided in handleDetections
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/api/events?after=%.0f&limit=10", [self detectBase:cfg], [[NSDate date] timeIntervalSince1970] - 40]];
    if (!url) return;
    self.detectBusy = YES;
    NSURLRequest *r = [NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:6];
    [[[NSURLSession sharedSession] dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.detectBusy = NO;
            if ([json isKindOfClass:[NSArray class]]) [self handleDetections:json config:cfg];
        });
    }] resume];
}

static NSInteger Minutes(NSString *hhmm) {
    NSArray *p = [hhmm componentsSeparatedByString:@":"];
    return p.count == 2 ? [p[0] integerValue] * 60 + [p[1] integerValue] : -1;
}

- (void)handleDetections:(NSArray *)events config:(NSDictionary *)cfg {
    if (!self.seenDetections) { self.seenDetections = [NSMutableSet set]; self.detectLast = [NSMutableDictionary dictionary]; }
    if (self.seenDetections.count > 400) [self.seenDetections removeAllObjects];
    NSArray *labels = [cfg[@"labels"] isKindOfClass:[NSArray class]] ? cfg[@"labels"] : @[@"person"];
    NSTimeInterval cooldown = [cfg[@"cooldown"] respondsToSelector:@selector(doubleValue)] ? [cfg[@"cooldown"] doubleValue] : 60;
    NSDictionary *quiet = [cfg[@"quiet"] isKindOfClass:[NSDictionary class]] ? cfg[@"quiet"] : nil;
    NSDateComponents *dc = [[NSCalendar currentCalendar] components:NSCalendarUnitHour | NSCalendarUnitMinute fromDate:[NSDate date]];
    NSInteger nowMin = dc.hour * 60 + dc.minute, qa = Minutes(Str(quiet[@"after"]) ?: @""), qb = Minutes(Str(quiet[@"before"]) ?: @"");
    BOOL isQuiet = qa >= 0 && qb >= 0 && (qa <= qb ? (nowMin >= qa && nowMin < qb) : (nowMin >= qa || nowMin < qb));
    for (id e in events) {
        if (![e isKindOfClass:[NSDictionary class]]) continue;
        NSString *eid = Str(e[@"id"]), *cam = Str(e[@"camera"]), *label = Str(e[@"label"]);
        if (!eid || !cam || [self.seenDetections containsObject:eid]) continue;
        [self.seenDetections addObject:eid];
        if (![labels containsObject:label ?: @""]) continue;
        if ([e[@"end_time"] respondsToSelector:@selector(doubleValue)] && [e[@"end_time"] doubleValue] < [[NSDate date] timeIntervalSince1970]) continue;   // already over
        if ([e[@"start_time"] respondsToSelector:@selector(doubleValue)] && [[NSDate date] timeIntervalSince1970] - [e[@"start_time"] doubleValue] > 45) continue;   // old news (app just started)
        NSDate *last = self.detectLast[cam];
        if ((last && -[last timeIntervalSinceNow] < cooldown) || isQuiet || self.alertView) continue;
        self.detectLast[cam] = [NSDate date];
        NSDictionary *cc = [cfg[@"cameras"] isKindOfClass:[NSDictionary class]] && [cfg[@"cameras"][cam] isKindOfClass:[NSDictionary class]] ? cfg[@"cameras"][cam] : nil;
        NSString *name = Str(cc[@"name"]) ?: [[cam stringByReplacingOccurrencesOfString:@"_" withString:@" "] capitalizedString];
        NSString *url = Str(cc[@"url"]) ?: [NSString stringWithFormat:@"%@/api/%@/latest.jpg?h=600", [self detectBase:cfg], cam];
        self.alertSeconds = [cfg[@"seconds"] respondsToSelector:@selector(doubleValue)] ? MAX(5, [cfg[@"seconds"] doubleValue]) : 20;
        HALog(@"detection: %@ on %@", label, cam);
        [self showAlert:@"detection" title:[NSString stringWithFormat:@"%@ \u00B7 %@", [label capitalizedString], name] camera:nil url:url];
        return;
    }
}

// Rail badges: a drawer with "badge": "updates" shows how many updates are waiting.
- (void)refreshBadges {
    BOOL want = NO;
    for (HADrawer *d in self.drawers) if ([Str(d.spec[@"badge"]) isEqualToString:@"updates"]) want = YES;
    if (!want || ![[HAClient shared] isConfigured]) return;
    [[HAClient shared] renderTemplate:@"{\"n\": {{ states.update | selectattr('state', 'eq', 'on') | list | count }}}" completion:^(id json, NSError *e) {
        if (![json isKindOfClass:[NSDictionary class]]) return;
        NSInteger n = [json[@"n"] integerValue];
        for (HADrawer *d in self.drawers) {
            if (![Str(d.spec[@"badge"]) isEqualToString:@"updates"]) continue;
            UILabel *b = (UILabel *)[d.railButton viewWithTag:55];
            if (!b) {
                b = [[UILabel alloc] init];
                b.tag = 55; b.textAlignment = NSTextAlignmentCenter; b.textColor = [UIColor whiteColor];
                b.font = HA_FONT(13, 0.4); b.backgroundColor = RGB(255, 59, 48);
                b.layer.cornerRadius = 11; b.clipsToBounds = YES;
                [d.railButton addSubview:b];
            }
            BOOL changed = b.hidden != (n == 0) || ![b.text isEqualToString:[@(n) stringValue]];
            b.text = [@(n) stringValue];
            b.frame = CGRectMake(d.railButton.bounds.size.width - 26, 2, MAX(22, 10 + 8 * b.text.length), 22);
            b.hidden = n == 0;
            if (changed && n) {   // classic springboard badge "pop"
                b.transform = CGAffineTransformMakeScale(0.3, 0.3);
                [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.5 initialSpringVelocity:0.8 options:0
                                 animations:^{ b.transform = CGAffineTransformIdentity; } completion:nil];
            }
        }
    }];
}

#pragma mark - Screens (pages)

// A layout holds one or more screens, swiped left and right like the iPad's own home screen.
// Screen 1 is the top level of the JSON ("cards", "columns", "rows", "row_heights"); further
// screens use the same keys inside "pages": [ {...}, ... ].
- (NSArray *)pageSpecsOf:(NSDictionary *)layout {
    NSMutableArray *out = [NSMutableArray arrayWithObject:layout ?: @{}];
    for (id p in ([layout[@"pages"] isKindOfClass:[NSArray class]] ? layout[@"pages"] : @[]))
        if ([p isKindOfClass:[NSDictionary class]]) [out addObject:p];
    return out;
}

- (void)showPage:(NSInteger)p {
    p = MAX(0, MIN((NSInteger)self.pageCards.count - 1, p));
    BOOL changed = (p != self.page);
    self.page = p;
    self.cards = self.pageCards.count ? self.pageCards[p] : [NSMutableArray array];
    for (NSUInteger i = 0; i < self.pageCards.count; i++)
        for (HACard *c in self.pageCards[i]) c.active = ((NSInteger)i == p);
    self.pageDots.numberOfPages = self.pageCards.count;
    self.pageDots.currentPage = p;
    self.pageDots.hidden = self.pageCards.count < 2;
    CGFloat pw = self.pagesScroll.bounds.size.width;
    if (pw > 0) self.pagesScroll.contentOffset = CGPointMake(p * pw, 0);
    if (changed) { for (HACard *c in self.cards) [c reload]; [self poll]; }
    [self.view setNeedsLayout];
}

- (void)pageSettled {
    CGFloat pw = self.pagesScroll.bounds.size.width;
    if (pw <= 0) return;
    [self showPage:lround(self.pagesScroll.contentOffset.x / pw)];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)sv { if (sv == self.pagesScroll) [self pageSettled]; }
- (void)scrollViewDidEndDragging:(UIScrollView *)sv willDecelerate:(BOOL)decelerate { if (sv == self.pagesScroll && !decelerate) [self pageSettled]; }

#pragma mark - Layout editor

// Edit the screens on the iPad itself. Every card sits in a grid cell ("col", "row") and stays
// there: drag a card to any free cell (or onto another card to swap), resize it, hide it (the
// cell stays empty), add widgets from a list, add or remove screens. Save writes <panel>.json in
// Home Assistant through shell_command.hapanel_save (ha/hapanel/save_layout.py keeps the
// previous 10 versions). Sidebar drawers are still edited in the JSON file.

- (NSMutableDictionary *)editPageAt:(NSInteger)i {
    if (i <= 0) return self.editLayout;
    NSArray *pages = self.editLayout[@"pages"];
    return (i - 1 < (NSInteger)pages.count) ? pages[i - 1] : nil;
}
- (NSInteger)editPageCount { return 1 + (NSInteger)[(NSArray *)self.editLayout[@"pages"] count]; }
- (NSMutableDictionary *)editPage { return [self editPageAt:self.page] ?: self.editLayout; }
- (NSMutableArray *)editCards {
    NSMutableDictionary *pg = [self editPage];
    if (![pg[@"cards"] isKindOfClass:[NSMutableArray class]]) pg[@"cards"] = [NSMutableArray array];
    return pg[@"cards"];
}
- (NSInteger)editColumns { return MAX(1, HA_Int([self editPage][@"columns"], 3)); }
- (NSInteger)editRows { return MAX(1, HA_Int([self editPage][@"rows"], 1)); }
- (NSMutableArray *)editHidden {
    if (![self.editLayout[@"hidden_cards"] isKindOfClass:[NSMutableArray class]]) self.editLayout[@"hidden_cards"] = [NSMutableArray array];
    return self.editLayout[@"hidden_cards"];
}

// Give every card of a screen a fixed cell (where it sits right now) and the screen a fixed row count.
- (void)pinPage:(NSMutableDictionary *)pg {
    NSMutableArray *cards = [NSMutableArray array];
    for (id s in ([pg[@"cards"] isKindOfClass:[NSArray class]] ? pg[@"cards"] : @[]))
        if ([s isKindOfClass:[NSMutableDictionary class]]) [cards addObject:s];
    pg[@"cards"] = cards;
    NSInteger cols = MAX(1, MIN(6, HA_Int(pg[@"columns"], 3))), used = 0;
    NSArray *pl = [self placementsForSpecs:cards columns:cols usedRows:&used];
    for (NSUInteger i = 0; i < cards.count; i++) {
        NSMutableDictionary *s = cards[i];
        s[@"row"] = pl[i][0]; s[@"col"] = pl[i][1]; s[@"w"] = pl[i][2]; s[@"h"] = pl[i][3];
    }
    pg[@"columns"] = @(cols);
    pg[@"rows"] = @(MAX(1, MAX(used, HA_Int(pg[@"rows"], 0))));
}

- (void)toggleEditMode {
    if (self.editing) { [self endEditingRestore:YES]; return; }
    if (!self.layout) return;
    NSData *d = [NSJSONSerialization dataWithJSONObject:self.layout options:0 error:nil];
    self.editLayout = d ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil] : nil;
    if (![self.editLayout isKindOfClass:[NSMutableDictionary class]]) { self.editLayout = nil; return; }
    NSMutableArray *pages = [NSMutableArray array];
    for (id p in ([self.editLayout[@"pages"] isKindOfClass:[NSArray class]] ? self.editLayout[@"pages"] : @[]))
        if ([p isKindOfClass:[NSMutableDictionary class]]) [pages addObject:p];
    if (pages.count) self.editLayout[@"pages"] = pages; else [self.editLayout removeObjectForKey:@"pages"];
    for (NSInteger i = 0; i < [self editPageCount]; i++) [self pinPage:[self editPageAt:i]];
    [self closeDrawerAnimated:NO];
    self.editing = YES;
    [self refreshEditor];
}

- (void)endEditingRestore:(BOOL)restore {
    self.editing = NO;
    [self closePicker];
    [self.editBar removeFromSuperview]; self.editBar = nil;
    for (UIView *ov in self.editOverlays) [ov removeFromSuperview];
    for (UIView *v in self.editCells) [v removeFromSuperview];
    self.editOverlays = nil; self.editCells = nil;
    self.editLayout = nil; self.editNote = nil;
    if (restore && self.layoutData) {
        id json = [NSJSONSerialization JSONObjectWithData:self.layoutData options:0 error:nil];
        if ([json isKindOfClass:[NSDictionary class]]) [self applyLayoutDict:json animated:NO];
    }
    [self.view setNeedsLayout];
}

static NSInteger SpecW(NSDictionary *s) { return MAX(1, HA_Int(s[@"w"], 1)); }
static NSInteger SpecH(NSDictionary *s) { return MAX(1, HA_Int(s[@"h"], 1)); }

// Is the w x h block at (col, row) inside the grid and clear of every other card on this screen?
- (BOOL)canPlace:(NSDictionary *)spec col:(NSInteger)c row:(NSInteger)r w:(NSInteger)w h:(NSInteger)h ignoring:(NSDictionary *)other {
    if (c < 0 || r < 0 || c + w > [self editColumns] || r + h > [self editRows]) return NO;
    for (NSDictionary *o in [self editCards]) {
        if (o == spec || o == other) continue;
        NSInteger oc = HA_Int(o[@"col"], 0), orow = HA_Int(o[@"row"], 0);
        if (c < oc + SpecW(o) && oc < c + w && r < orow + SpecH(o) && orow < r + h) return NO;
    }
    return YES;
}

// First free block that fits, scanning rows then columns; adds a row (up to 6) when the screen is full.
- (BOOL)placeInFirstGap:(NSMutableDictionary *)spec {
    NSInteger w = MIN([self editColumns], SpecW(spec)), h = MIN(6, SpecH(spec));
    spec[@"w"] = @(w); spec[@"h"] = @(h);
    for (;;) {
        for (NSInteger r = 0; r + h <= [self editRows]; r++)
            for (NSInteger c = 0; c + w <= [self editColumns]; c++)
                if ([self canPlace:spec col:c row:r w:w h:h ignoring:nil]) { spec[@"col"] = @(c); spec[@"row"] = @(r); return YES; }
        if ([self editRows] >= 6) return NO;
        [self editPage][@"rows"] = @([self editRows] + 1);
    }
}

- (NSMutableDictionary *)editSpecOfCard:(NSUInteger)i {
    if (i >= self.cards.count) return nil;
    NSUInteger idx = [[self editCards] indexOfObjectIdenticalTo:((HACard *)self.cards[i]).spec];
    return idx == NSNotFound ? nil : [self editCards][idx];
}

// Rebuild the screen from editLayout and put the editing controls on top of every card.
- (void)refreshEditor {
    [self applyLayoutDict:self.editLayout animated:NO];
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    for (UIView *old in self.editOverlays) [old removeFromSuperview];
    for (UIView *old in self.editCells) [old removeFromSuperview];
    self.editOverlays = [NSMutableArray array];
    self.editCells = [NSMutableArray array];
    UIView *pv = self.page < (NSInteger)self.pageViews.count ? self.pageViews[self.page] : nil;
    if (!pv) return;

    // outline every free cell, so it is clear where a card can be dropped
    NSInteger cols = [self editColumns], rows = [self editRows];
    CGFloat gap = self.gridGap, cellW = (self.gridRect.size.width - (cols - 1) * gap) / cols;
    for (NSInteger r = 0; r < rows && r + 1 < (NSInteger)self.gridEdges.count; r++) {
        for (NSInteger c = 0; c < cols; c++) {
            if (![self canPlace:nil col:c row:r w:1 h:1 ignoring:nil]) continue;
            CGFloat y = [self.gridEdges[r] doubleValue];
            UIView *cell = [[UIView alloc] initWithFrame:CGRectMake(self.gridRect.origin.x + c * (cellW + gap), y, cellW, [self.gridEdges[r + 1] doubleValue] - y - gap)];
            cell.layer.borderColor = [HA_DIM() colorWithAlphaComponent:0.35].CGColor;
            cell.layer.borderWidth = 1.5; cell.layer.cornerRadius = 18;
            cell.userInteractionEnabled = NO;
            UILabel *l = [self label:14 weight:0 color:[HA_DIM() colorWithAlphaComponent:0.6] in:cell];
            l.text = @"empty"; l.textAlignment = NSTextAlignmentCenter; l.frame = cell.bounds;
            [pv insertSubview:cell atIndex:0];
            [self.editCells addObject:cell];
        }
    }

    for (NSUInteger i = 0; i < self.cards.count; i++) {
        HACard *card = self.cards[i];
        // The overlay is a sibling above the card, so nothing the card adds later can cover it
        // and none of the card's own controls can be tapped while editing.
        UIView *ov = [[UIView alloc] initWithFrame:card.frame];
        ov.tag = 9600 + i;
        ov.backgroundColor = [HA_BG() colorWithAlphaComponent:0.78];
        ov.layer.borderColor = HA_BLUE().CGColor; ov.layer.borderWidth = 2; ov.layer.cornerRadius = 18;
        ov.clipsToBounds = YES;   // on a small tile the buttons that do not fit are cut off, not spilled over its neighbours
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(editPan:)];
        [ov addGestureRecognizer:pan];
        NSDictionary *spec = card.spec;
        NSString *what = Str(spec[@"title"]).length ? Str(spec[@"title"]) : [(Str(spec[@"type"]) ?: @"card") capitalizedString];
        UILabel *name = [self label:17 weight:0.3 color:HA_TEXT() in:ov];
        name.text = [NSString stringWithFormat:@"%@  ·  %ld wide × %ld tall", what, (long)SpecW(spec), (long)SpecH(spec)];
        name.textAlignment = NSTextAlignmentCenter;
        name.adjustsFontSizeToFitWidth = YES; name.minimumScaleFactor = 0.6;
        name.frame = CGRectMake(8, 8, ov.bounds.size.width - 16, 22);
        NSArray *titles = @[@"Narrower", @"Wider", @"Shorter", @"Taller", @"Hide"];
        CGFloat bw = 84, bh = 40, g = 8, maxW = ov.bounds.size.width - 16;
        NSInteger perRow = MAX(1, (NSInteger)((maxW + g) / (bw + g)));
        CGFloat rowW = MIN((NSInteger)titles.count, perRow) * (bw + g) - g;
        for (NSUInteger k = 0; k < titles.count; k++) {
            UIButton *b = HA_Chip(titles[k], self, @selector(editButton:));
            b.tag = i * 10 + k;
            b.frame = CGRectMake(8 + (maxW - rowW) / 2 + (k % perRow) * (bw + g), 36 + (k / perRow) * (bh + g), bw, bh);
            if (k == 4) [b setTitleColor:RGB(255, 99, 88) forState:UIControlStateNormal];
            [ov addSubview:b];
        }
        UILabel *hint = [self label:13 weight:0 color:HA_DIM() in:ov];
        hint.text = @"drag to move";
        hint.textAlignment = NSTextAlignmentCenter;
        hint.frame = CGRectMake(8, ov.bounds.size.height - 24, ov.bounds.size.width - 16, 16);
        hint.hidden = ov.bounds.size.height < 150;
        [pv addSubview:ov];
        [self.editOverlays addObject:ov];
    }
    [self buildEditBar];
}

- (void)buildEditBar {
    [self.editBar removeFromSuperview];
    UIView *bar = [[UIView alloc] init];
    bar.backgroundColor = HA_BG();
    CGFloat left = [self hasRail] ? kRailW : 0, W = self.view.bounds.size.width - left;
    bar.frame = CGRectMake(left, 0, W, 120);
    self.editTitle = [self label:20 weight:0.3 color:self.editNote ? HA_HEAT() : HA_TEXT() in:bar];
    self.editTitle.text = self.editNote ?: [NSString stringWithFormat:@"Screen %ld of %ld", (long)self.page + 1, (long)[self editPageCount]];
    self.editTitle.adjustsFontSizeToFitWidth = YES; self.editTitle.minimumScaleFactor = 0.5;
    self.editTitle.numberOfLines = 2;
    self.editNote = nil;

    // first line, right to left: Save, Cancel, Restore hidden, remove/add screen, add widget
    NSMutableArray *items = [NSMutableArray arrayWithArray:@[@[@"Save", @90, @"editSave"], @[@"Cancel", @90, @"editCancel"]]];
    NSUInteger hidden = [self.editLayout[@"hidden_cards"] isKindOfClass:[NSArray class]] ? [(NSArray *)self.editLayout[@"hidden_cards"] count] : 0;
    if (hidden) [items addObject:@[[NSString stringWithFormat:@"Restore (%lu)", (unsigned long)hidden], @110, @"editRestore"]];
    if ([self editPageCount] > 1) [items addObject:@[@"− Screen", @96, @"editRemovePage"]];
    [items addObject:@[@"+ Screen", @96, @"editAddPage"]];
    [items addObject:@[@"+ Widget", @100, @"showPicker"]];
    CGFloat x = W - 24;
    for (NSArray *it in items) {
        UIButton *b = HA_Chip(it[0], self, NSSelectorFromString(it[2]));
        x -= [it[1] doubleValue];
        b.frame = CGRectMake(x, 12, [it[1] doubleValue], 44);
        x -= 8;
        if ([it[2] isEqualToString:@"editSave"]) { b.backgroundColor = HA_ACCENT(); [b setTitleColor:[UIColor blackColor] forState:UIControlStateNormal]; }
        if ([it[2] isEqualToString:@"showPicker"]) { b.backgroundColor = HA_BLUE(); [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal]; }
        [bar addSubview:b];
    }
    CGFloat tx = 24;
    if ([self editPageCount] > 1) {   // previous / next screen
        for (int k = 0; k < 2; k++) {
            UIButton *b = HA_Chip(k ? @"›" : @"‹", self, @selector(editPageStep:));
            b.titleLabel.font = HA_FONT(24, 0.3);
            b.tag = k;
            b.frame = CGRectMake(tx, 12, 40, 44);
            [bar addSubview:b];
            tx += 46;
        }
    }
    self.editTitle.frame = CGRectMake(tx + 2, 10, MAX(60, x - tx - 4), 48);

    // second line: columns, rows, then one height control per row (as many as fit)
    x = 24; CGFloat y = 68;
    NSMutableArray *groups = [NSMutableArray arrayWithArray:@[@[[NSString stringWithFormat:@"Columns %ld", (long)[self editColumns]], @100],
                                                              @[[NSString stringWithFormat:@"Rows %ld", (long)[self editRows]], @110]]];
    NSArray *weights = [[self editPage][@"row_heights"] isKindOfClass:[NSArray class]] ? [self editPage][@"row_heights"] : @[];
    for (NSInteger r = 0; r < [self editRows]; r++) {
        double w = r < (NSInteger)weights.count ? [weights[r] doubleValue] : 1;
        [groups addObject:@[[NSString stringWithFormat:@"Row %ld  %.0f%%", (long)r + 1, w * 100], @(200 + r * 10)]];
    }
    for (NSArray *g in groups) {
        UILabel *l = [self label:13 weight:0.2 color:HA_DIM() in:bar];
        l.text = g[0];
        CGFloat lw = [l.text sizeWithAttributes:@{NSFontAttributeName: l.font}].width + 4;
        if (x + lw + 4 + 76 > W - 16) { [l removeFromSuperview]; break; }
        l.frame = CGRectMake(x, y, lw, 40);
        x += lw + 4;
        for (int k = 0; k < 2; k++) {
            UIButton *b = HA_Chip(k ? @"+" : @"−", self, @selector(editBarButton:));
            b.titleLabel.font = HA_FONT(20, 0.3);
            b.tag = [g[1] integerValue] + k;
            b.frame = CGRectMake(x, y, 36, 40);
            [bar addSubview:b];
            x += 40;
        }
        x += 10;
    }
    self.editBar = bar;
    [self.view insertSubview:bar belowSubview:self.rail];
}

- (void)editButton:(UIButton *)b {
    NSUInteger k = b.tag % 10;
    NSMutableDictionary *spec = [self editSpecOfCard:b.tag / 10];
    if (!spec) return;
    NSInteger w = SpecW(spec), h = SpecH(spec), c = HA_Int(spec[@"col"], 0), r = HA_Int(spec[@"row"], 0);
    if (k == 0) w = MAX(1, w - 1);
    else if (k == 2) h = MAX(1, h - 1);
    else if (k == 1 || k == 3) {
        NSInteger nw = w + (k == 1), nh = h + (k == 3);
        if ([self canPlace:spec col:c row:r w:nw h:nh ignoring:nil]) { w = nw; h = nh; }
        else if (k == 1 && [self canPlace:spec col:c - 1 row:r w:nw h:nh ignoring:nil]) { w = nw; spec[@"col"] = @(c - 1); }   // grow to the left instead
        else if (k == 3 && [self canPlace:spec col:c row:r - 1 w:nw h:nh ignoring:nil]) { h = nh; spec[@"row"] = @(r - 1); }   // grow upwards instead
        else self.editNote = k == 1 ? @"No room to widen: free the cell beside it or add a column" : @"No room to grow: free the cell below it or add a row";
    } else if (k == 4) {   // hide: kept in "hidden_cards" so it can be restored later; its cells stay empty
        [[self editHidden] addObject:spec];
        [[self editCards] removeObjectIdenticalTo:spec];
        [self refreshEditor];
        return;
    }
    spec[@"w"] = @(w); spec[@"h"] = @(h);
    [self refreshEditor];
}

- (void)editBarButton:(UIButton *)b {
    NSInteger tag = b.tag, delta = (tag % 10) ? 1 : -1;
    NSMutableDictionary *pg = [self editPage];
    if (tag / 100 == 1) {
        BOOL isRows = (tag % 100) / 10 == 1;
        NSInteger now = isRows ? [self editRows] : [self editColumns], want = MAX(1, MIN(6, now + delta));
        BOOL blocked = NO;
        for (NSDictionary *s in [self editCards])
            if ((isRows ? HA_Int(s[@"row"], 0) + SpecH(s) : HA_Int(s[@"col"], 0) + SpecW(s)) > want) blocked = YES;
        if (blocked) self.editNote = isRows ? @"Move or shrink the cards in the last row first" : @"Move or shrink the cards in the last column first";
        else pg[isRows ? @"rows" : @"columns"] = @(want);
    } else {
        NSInteger row = (tag - 200) / 10;
        NSMutableArray *weights = [NSMutableArray array];
        NSArray *old = [pg[@"row_heights"] isKindOfClass:[NSArray class]] ? pg[@"row_heights"] : @[];
        for (NSInteger r = 0; r < MAX([self editRows], row + 1); r++) [weights addObject:r < (NSInteger)old.count ? old[r] : @1];
        double w = MAX(0.3, MIN(3.0, [weights[row] doubleValue] + delta * 0.1));
        weights[row] = @(round(w * 100) / 100);
        pg[@"row_heights"] = weights;
    }
    [self refreshEditor];
}

- (void)editRestore {
    NSMutableArray *hidden = [self editHidden];
    NSMutableDictionary *spec = hidden.lastObject;
    if (![spec isKindOfClass:[NSMutableDictionary class]]) { [hidden removeLastObject]; [self refreshEditor]; return; }
    if ([self placeInFirstGap:spec]) { [[self editCards] addObject:spec]; [hidden removeLastObject]; }
    else self.editNote = @"This screen is full: make room or add a screen";
    if (!hidden.count) [self.editLayout removeObjectForKey:@"hidden_cards"];
    [self refreshEditor];
}

- (void)editPageStep:(UIButton *)b {
    self.page = MAX(0, MIN([self editPageCount] - 1, self.page + (b.tag ? 1 : -1)));
    [self refreshEditor];
}

- (void)editAddPage {
    if ([self editPageCount] >= 8) { self.editNote = @"8 screens is the limit"; [self refreshEditor]; return; }
    NSMutableArray *pages = [self.editLayout[@"pages"] isKindOfClass:[NSMutableArray class]] ? self.editLayout[@"pages"] : [NSMutableArray array];
    [pages addObject:[@{@"cards": [NSMutableArray array], @"columns": @([self editColumns]), @"rows": @([self editRows])} mutableCopy]];
    self.editLayout[@"pages"] = pages;
    self.page = [self editPageCount] - 1;
    [self refreshEditor];
}

// Removes the screen being edited. Its cards go to the hidden list, so nothing is lost.
- (void)editRemovePage {
    if ([self editPageCount] < 2) return;
    NSArray *cards = [[self editCards] copy];
    if (cards.count) [[self editHidden] addObjectsFromArray:cards];
    NSMutableArray *pages = self.editLayout[@"pages"];
    if (self.page == 0) {   // the next screen becomes screen 1 (the top level of the file)
        NSDictionary *next = pages[0];
        for (NSString *k in @[@"cards", @"columns", @"rows", @"row_heights"]) {
            if (next[k]) self.editLayout[k] = next[k]; else [self.editLayout removeObjectForKey:k];
        }
        [pages removeObjectAtIndex:0];
    } else {
        [pages removeObjectAtIndex:self.page - 1];
    }
    if (!pages.count) [self.editLayout removeObjectForKey:@"pages"];
    self.page = MIN(self.page, [self editPageCount] - 1);
    if (cards.count) self.editNote = [NSString stringWithFormat:@"Screen removed: its %lu cards are under Restore", (unsigned long)cards.count];
    [self refreshEditor];
}

// Move a card to the cell (col, row); onto another card, the two swap places when both fit.
- (BOOL)moveSpec:(NSMutableDictionary *)spec toCol:(NSInteger)c row:(NSInteger)r onto:(NSMutableDictionary *)other {
    NSInteger w = SpecW(spec), h = SpecH(spec);
    c = MAX(0, MIN([self editColumns] - w, c)); r = MAX(0, MIN([self editRows] - h, r));
    if ([self canPlace:spec col:c row:r w:w h:h ignoring:nil]) { spec[@"col"] = @(c); spec[@"row"] = @(r); return YES; }
    if (!other || other == spec) return NO;
    NSInteger mc = HA_Int(spec[@"col"], 0), mr = HA_Int(spec[@"row"], 0), ow = SpecW(other), oh = SpecH(other);
    NSInteger oc = MAX(0, MIN([self editColumns] - w, HA_Int(other[@"col"], 0))), orow = MAX(0, MIN([self editRows] - h, HA_Int(other[@"row"], 0)));
    NSInteger nc = MAX(0, MIN([self editColumns] - ow, mc)), nr = MAX(0, MIN([self editRows] - oh, mr));
    BOOL overlap = oc < nc + ow && nc < oc + w && orow < nr + oh && nr < orow + h;
    if (overlap || ![self canPlace:spec col:oc row:orow w:w h:h ignoring:other] || ![self canPlace:other col:nc row:nr w:ow h:oh ignoring:spec]) return NO;
    spec[@"col"] = @(oc); spec[@"row"] = @(orow);
    other[@"col"] = @(nc); other[@"row"] = @(nr);
    return YES;
}

// Drag a card to any free cell, or onto another card to swap with it.
- (void)editPan:(UIPanGestureRecognizer *)pan {
    NSUInteger from = pan.view.tag - 9600;
    if (from >= self.cards.count) return;
    HACard *card = self.cards[from];
    UIView *pv = card.superview;
    if (pan.state == UIGestureRecognizerStateBegan) {
        self.dragStartCenter = card.center;
        [pv bringSubviewToFront:card];
        [pv bringSubviewToFront:pan.view];
        [UIView animateWithDuration:0.15 animations:^{ card.alpha = 0.85; pan.view.alpha = 0.9; }];
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [pan translationInView:self.view];
        card.center = CGPointMake(self.dragStartCenter.x + t.x, self.dragStartCenter.y + t.y);
        pan.view.center = card.center;
    } else if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        NSMutableDictionary *spec = [self editSpecOfCard:from];
        if (pan.state == UIGestureRecognizerStateEnded && spec && self.gridEdges.count > 1) {
            NSInteger cols = [self editColumns], rows = [self editRows];
            CGFloat cellW = (self.gridRect.size.width - (cols - 1) * self.gridGap) / cols;
            CGPoint o = card.frame.origin, p = [pan locationInView:pv];
            NSInteger c = lround((o.x - self.gridRect.origin.x) / (cellW + self.gridGap)), r = 0;
            CGFloat best = CGFLOAT_MAX;
            for (NSInteger i = 0; i < rows && i < (NSInteger)self.gridEdges.count; i++) {
                CGFloat d = fabs([self.gridEdges[i] doubleValue] - o.y);
                if (d < best) { best = d; r = i; }
            }
            NSMutableDictionary *other = nil;
            for (NSUInteger i = 0; i < self.cards.count; i++) {
                HACard *oc = self.cards[i];
                if (oc != card && CGRectContainsPoint(oc.frame, p)) { other = [self editSpecOfCard:i]; break; }
            }
            if (![self moveSpec:spec toCol:c row:r onto:other]) self.editNote = @"No room there: drop it on an empty cell, or on a card of the same size to swap";
        }
        [self refreshEditor];
    }
}

- (void)editCancel { [self endEditingRestore:YES]; }

- (void)editSave {
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.editLayout options:0 error:nil];
    HAClient *ha = [HAClient shared];
    if (!data || !ha.panel.length) return;
    NSString *b64 = [data base64EncodedStringWithOptions:0];
    self.editTitle.text = @"Saving…";
    [ha callServiceWithResponse:@"shell_command" service:@"hapanel_save" data:@{@"panel": ha.panel, @"layout_b64": b64} completion:^(id json, NSError *e) {
        NSDictionary *resp = [json isKindOfClass:[NSDictionary class]] ? json[@"service_response"] : nil;
        BOOL ok = !e && [resp isKindOfClass:[NSDictionary class]] && [resp[@"returncode"] integerValue] == 0;
        if (!ok) {
            NSString *why = e.localizedDescription ?: Str(resp[@"stderr"]) ?: @"Home Assistant did not confirm the save";
            HALog(@"layout save failed: %@", why);
            self.editTitle.text = @"Not saved";
            UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Could not save" message:why preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:ac animated:YES completion:nil];
            return;
        }
        HALog(@"layout saved: %@", Str(resp[@"stdout"]) ?: @"");
        NSDictionary *saved = [self.editLayout copy];
        [self endEditingRestore:NO];
        self.layoutData = nil;                 // the file in HA is now pretty-printed; re-fetch it as the new baseline
        [self applyLayoutDict:saved animated:NO];
        [self fetchLayout];
    }];
}

#pragma mark - Add a widget

// Standard widgets offered by "+ Widget". "domains" asks for an entity of that kind; "clone" copies
// the settings of a card of the same type that already exists anywhere in this layout.
- (NSArray *)widgetPresets {
    return @[ @{@"name": @"Light", @"type": @"light", @"domains": @[@"light"]},
              @{@"name": @"Thermostat", @"type": @"climate", @"domains": @[@"climate"], @"w": @2},
              @{@"name": @"Music player", @"type": @"media", @"domains": @[@"media_player"], @"w": @2},
              @{@"name": @"Now playing", @"type": @"context", @"domains": @[@"media_player"], @"w": @2, @"clone": @YES},
              @{@"name": @"Cameras", @"type": @"cameras", @"clone": @YES, @"w": @3},
              @{@"name": @"Forecast", @"type": @"forecast", @"domains": @[@"weather"], @"w": @3},
              @{@"name": @"Timer", @"type": @"timer", @"domains": @[@"timer"], @"w": @2, @"h": @2, @"clone": @YES},
              @{@"name": @"Button", @"type": @"buttons", @"domains": @[@"scene", @"script", @"switch", @"input_boolean", @"fan"]},
              @{@"name": @"Sensor", @"type": @"sensors", @"domains": @[@"sensor", @"binary_sensor"]},
              @{@"name": @"Tesla", @"type": @"tesla", @"clone": @YES, @"w": @2, @"h": @2},
              @{@"name": @"Updates", @"type": @"updates", @"h": @2},
              @{@"name": @"Ad block", @"type": @"adblock", @"clone": @YES},
              @{@"name": @"Internet", @"type": @"network", @"clone": @YES},
              @{@"name": @"Batteries", @"type": @"batteries", @"h": @2, @"clone": @YES},
              @{@"name": @"Freeze dryer", @"type": @"freeze_dryer", @"clone": @YES},
              @{@"name": @"Camera alerts", @"type": @"detections", @"w": @3, @"h": @2, @"clone": @YES} ];
}

// A card of this type from anywhere in the layout being edited: screens, sidebar drawers, hidden cards.
- (NSDictionary *)existingSpecOfType:(NSString *)type {
    NSMutableArray *lists = [NSMutableArray array];
    for (NSInteger i = 0; i < [self editPageCount]; i++) [lists addObject:[self editPageAt:i][@"cards"] ?: @[]];
    for (id d in ([self.editLayout[@"sidebar"] isKindOfClass:[NSArray class]] ? self.editLayout[@"sidebar"] : @[]))
        if ([d isKindOfClass:[NSDictionary class]] && [d[@"cards"] isKindOfClass:[NSArray class]]) [lists addObject:d[@"cards"]];
    [lists addObject:self.editLayout[@"hidden_cards"] ?: @[]];
    for (NSArray *l in lists) {
        if (![l isKindOfClass:[NSArray class]]) continue;
        for (id s in l) if ([s isKindOfClass:[NSDictionary class]] && [s[@"type"] isEqual:type]) return s;
    }
    return nil;
}

- (void)showPicker {
    [self closePicker];
    UIView *v = [[UIView alloc] initWithFrame:self.view.bounds];
    v.backgroundColor = [HA_BG() colorWithAlphaComponent:0.97];
    self.pickerView = v;
    [self.view addSubview:v];
    [self buildPickerMenu];
}

- (void)closePicker {
    [self.pickerView removeFromSuperview];
    self.pickerView = nil; self.pickerPreset = nil; self.pickerEntities = nil;
}

- (void)pickerHeader:(NSString *)title back:(BOOL)back {
    for (UIView *s in [self.pickerView.subviews copy]) [s removeFromSuperview];
    CGFloat W = self.pickerView.bounds.size.width;
    UILabel *t = [self label:28 weight:0.3 color:HA_TEXT() in:self.pickerView];
    t.text = title;
    t.frame = CGRectMake(60, 40, W - 360, 40);
    UIButton *cancel = HA_Chip(@"Cancel", self, @selector(closePicker));
    cancel.frame = CGRectMake(W - 60 - 120, 38, 120, 44);
    [self.pickerView addSubview:cancel];
    if (back) {
        UIButton *b = HA_Chip(@"Back", self, @selector(buildPickerMenu));
        b.frame = CGRectMake(W - 60 - 120 - 12 - 120, 38, 120, 44);
        [self.pickerView addSubview:b];
    }
}

- (void)buildPickerMenu {
    [self pickerHeader:@"Add a widget to this screen" back:NO];
    CGFloat W = self.pickerView.bounds.size.width, gap = 16, bw = (W - 120 - 3 * gap) / 4, bh = 96;
    NSArray *presets = [self widgetPresets];
    for (NSUInteger i = 0; i < presets.count; i++) {
        NSDictionary *p = presets[i];
        BOOL needsExisting = [@[@"cameras", @"tesla", @"detections"] containsObject:p[@"type"]] && ![self existingSpecOfType:p[@"type"]];   // these need details from the layout file
        UIButton *b = HA_Chip(p[@"name"], self, @selector(pickerPresetTapped:));
        b.titleLabel.font = HA_FONT(20, 0.3);
        b.tag = i;
        b.layer.cornerRadius = 16;
        b.frame = CGRectMake(60 + (i % 4) * (bw + gap), 120 + (i / 4) * (bh + gap), bw, bh);
        if (needsExisting) { b.enabled = NO; b.alpha = 0.35; }
        [self.pickerView addSubview:b];
    }
    UILabel *hint = [self label:15 weight:0 color:HA_DIM() in:self.pickerView];
    hint.numberOfLines = 0;
    hint.text = @"The widget lands in the first free cell; drag it wherever you like afterwards.\nGreyed-out widgets need their details in the layout file first (camera addresses, car names).";
    hint.frame = CGRectMake(60, 120 + ((presets.count + 3) / 4) * (bh + gap) + 8, W - 120, 60);
}

- (void)pickerPresetTapped:(UIButton *)b {
    NSArray *presets = [self widgetPresets];
    if (b.tag < 0 || b.tag >= (NSInteger)presets.count) return;
    [self choosePreset:presets[b.tag] entity:nil];
}

// entity: used by the remote debug channel to skip the list.
- (void)choosePreset:(NSDictionary *)p entity:(NSString *)entity {
    NSDictionary *existing = [p[@"clone"] boolValue] ? [self existingSpecOfType:p[@"type"]] : nil;
    if (existing) {
        NSData *d = [NSJSONSerialization dataWithJSONObject:existing options:0 error:nil];
        NSMutableDictionary *spec = d ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil] : nil;
        if (spec) {
            [spec removeObjectsForKeys:@[@"col", @"row"]];
            if (!spec[@"w"] && p[@"w"]) spec[@"w"] = p[@"w"];
            if (!spec[@"h"] && p[@"h"]) spec[@"h"] = p[@"h"];
            [self addWidget:spec];
            return;
        }
    }
    if (!p[@"domains"]) { [self addWidget:[self specForPreset:p entity:nil name:nil]]; return; }
    if (entity) { [self addWidget:[self specForPreset:p entity:entity name:nil]]; return; }
    self.pickerPreset = p;
    self.pickerEntities = nil;
    [self pickerHeader:[NSString stringWithFormat:@"%@: choose what it controls", p[@"name"]] back:YES];
    UILabel *wait = [self label:18 weight:0 color:HA_DIM() in:self.pickerView];
    wait.text = @"Loading from Home Assistant…";
    wait.frame = CGRectMake(60, 120, 600, 30);
    NSArray *domains = p[@"domains"];
    [[HAClient shared] getJSON:@"/api/states" completion:^(id json, NSError *e) {
        if (self.pickerPreset != p || !self.pickerView) return;
        if (![json isKindOfClass:[NSArray class]]) { wait.text = [NSString stringWithFormat:@"Could not load the list: %@", e.localizedDescription ?: @"unexpected answer"]; return; }
        NSMutableArray *rows = [NSMutableArray array];
        for (NSDictionary *s in json) {
            NSString *eid = [s isKindOfClass:[NSDictionary class]] ? Str(s[@"entity_id"]) : nil;
            if (!eid || ![domains containsObject:[eid componentsSeparatedByString:@"."].firstObject]) continue;
            NSString *name = [s[@"attributes"] isKindOfClass:[NSDictionary class]] ? Str(s[@"attributes"][@"friendly_name"]) : nil;
            [rows addObject:@{@"id": eid, @"name": name.length ? name : eid, @"state": Str(s[@"state"]) ?: @""}];
        }
        [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b2) { return [a[@"name"] caseInsensitiveCompare:b2[@"name"]]; }];
        self.pickerEntities = rows;
        if (!rows.count) { wait.text = @"Home Assistant has nothing of that kind."; return; }
        [wait removeFromSuperview];
        CGRect r = self.pickerView.bounds;
        UITableView *tv = [[UITableView alloc] initWithFrame:CGRectMake(60, 110, r.size.width - 120, r.size.height - 130) style:UITableViewStylePlain];
        tv.backgroundColor = [UIColor clearColor];
        tv.separatorColor = [HA_DIM() colorWithAlphaComponent:0.25];
        tv.indicatorStyle = UIScrollViewIndicatorStyleWhite;
        tv.rowHeight = 60;
        tv.dataSource = self; tv.delegate = self;
        [self.pickerView addSubview:tv];
    }];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { return self.pickerEntities.count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"e"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"e"];
        cell.backgroundColor = [UIColor clearColor];
        cell.textLabel.textColor = HA_TEXT(); cell.textLabel.font = HA_FONT(19, 0.2);
        cell.detailTextLabel.textColor = HA_DIM(); cell.detailTextLabel.font = HA_FONT(13, 0);
        UIView *sel = [[UIView alloc] init]; sel.backgroundColor = HA_OFF();
        cell.selectedBackgroundView = sel;
    }
    NSDictionary *e = self.pickerEntities[ip.row];
    cell.textLabel.text = e[@"name"];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@  ·  %@", e[@"id"], e[@"state"]];
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.row >= (NSInteger)self.pickerEntities.count || !self.pickerPreset) return;
    NSDictionary *e = self.pickerEntities[ip.row];
    [self addWidget:[self specForPreset:self.pickerPreset entity:e[@"id"] name:e[@"name"]]];
}

- (NSMutableDictionary *)specForPreset:(NSDictionary *)p entity:(NSString *)eid name:(NSString *)name {
    NSString *type = p[@"type"];
    name = name ?: eid ?: @"";
    NSMutableDictionary *s = [@{@"type": type} mutableCopy];
    if ([type isEqualToString:@"light"]) { s[@"entity"] = eid; s[@"title"] = name; }
    else if ([type isEqualToString:@"climate"]) { s[@"entity"] = eid; s[@"title"] = @"Thermostat"; }
    else if ([type isEqualToString:@"media"]) s[@"players"] = @[@{@"entity": eid, @"name": name}];
    else if ([type isEqualToString:@"context"]) { s[@"players"] = @[eid]; s[@"player_names"] = @{eid: name}; }
    else if ([type isEqualToString:@"forecast"]) { s[@"entity"] = eid; s[@"days"] = @7; s[@"title"] = @""; }
    else if ([type isEqualToString:@"timer"]) s[@"entity"] = eid;
    else if ([type isEqualToString:@"buttons"]) { s[@"title"] = @""; s[@"columns"] = @1; s[@"buttons"] = @[@{@"name": name, @"entity": eid}]; }
    else if ([type isEqualToString:@"sensors"]) { s[@"title"] = @""; s[@"entities"] = @[@{@"entity": eid, @"name": name}]; }
    else if ([type isEqualToString:@"adblock"]) s[@"pause_minutes"] = @[@10, @60];
    if (p[@"w"]) s[@"w"] = p[@"w"];
    if (p[@"h"]) s[@"h"] = p[@"h"];
    return s;
}

- (void)addWidget:(NSMutableDictionary *)spec {
    if (!self.editing || !spec) return;
    if ([self placeInFirstGap:spec]) [[self editCards] addObject:spec];
    else self.editNote = @"This screen is full: make room or add a screen";
    [self closePicker];
    [self refreshEditor];
}


#pragma mark - Remote debug channel
// Write commands (one per line) to /var/mobile/Library/HAPanel/cmd over SSH; the app runs them within a
// second and deletes the file. Used for development: see the screen and drive the UI without touching it.
//   snap              save a screenshot to /var/mobile/Library/HAPanel/snap.jpg
//   wake              leave the photo frame / blank screen
//   stay:<seconds>    keep the dashboard awake that long (presence timer is pushed forward)
//   drawer:<name>     open a sidebar drawer        close   close it
//   reload            re-fetch the layout          edit    toggle layout edit mode
//   page:<n>          show screen n (0 = first)   detect:<camera>   simulate a person detection
- (void)runDebugCommands {
    NSString *path = @"/var/mobile/Library/HAPanel/cmd";
    NSString *txt = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!txt) return;
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    for (NSString *raw in [txt componentsSeparatedByString:@"\n"]) {
        NSString *c = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!c.length) continue;
        HALog(@"cmd: %@", c);
        if ([c isEqualToString:@"snap"]) [self saveScreenshot];
        else if ([c isEqualToString:@"wake"]) [self wake];
        else if ([c hasPrefix:@"stay:"]) { [self wake]; self.lastSeen = [NSDate dateWithTimeIntervalSinceNow:[[c substringFromIndex:5] doubleValue]]; self.lastTouch = self.lastSeen; }
        else if ([c hasPrefix:@"drawer:"]) [self card:nil openDrawer:[c substringFromIndex:7]];
        else if ([c isEqualToString:@"close"]) [self closeDrawerAnimated:NO];
        else if ([c isEqualToString:@"reload"]) { self.usingStarter = NO; self.layoutData = nil; self.homeData = nil; [self fetchLayout]; }
        else if ([c isEqualToString:@"edit"]) [self toggleEditMode];
        else if ([c isEqualToString:@"starter"]) { self.usingStarter = NO; [self buildStarterLayout]; }   // preview the first-run layout ("reload" brings the real one back)
        else if ([c isEqualToString:@"connect"]) [self showConnectionForm];
        else if ([c hasPrefix:@"page:"]) [self showPage:[[c substringFromIndex:5] integerValue]];
        else if ([c hasPrefix:@"tap:"]) {   // tap:<card type>:<selector>[:<times>]  press a card's button on the visible screen, e.g. tap:climate:minusTapped:7
            NSArray *a = [c componentsSeparatedByString:@":"];
            for (HACard *card in self.cards) {
                if (a.count < 3 || ![card.spec[@"type"] isEqual:a[1]] || ![card respondsToSelector:NSSelectorFromString(a[2])]) continue;
                for (NSInteger k = 0; k < MAX(1, a.count > 3 ? [a[3] integerValue] : 1); k++) ((void (*)(id, SEL))[card methodForSelector:NSSelectorFromString(a[2])])(card, NSSelectorFromString(a[2]));
                break;
            }
        }
        else if ([c isEqualToString:@"demo:music"]) {   // show the now-playing face of the context card until the next poll (follow with snap)
            self.demoUntil = [NSDate dateWithTimeIntervalSinceNow:8];
            for (HACard *card in self.cards) {
                NSString *p = [card.spec[@"players"] isKindOfClass:[NSArray class]] ? Str([card.spec[@"players"] firstObject]) : nil;
                if (![card.spec[@"type"] isEqual:@"context"] || !p) continue;
                [card updateStates:@{p: @{@"state": @"playing", @"attributes": @{@"media_title": @"A fairly long song title", @"media_artist": @"Some Artist", @"volume_level": @0.4,
                                                                                         @"media_content_id": @"/library/metadata/54898"}}}];
                [card layoutIfNeeded];
            }
        }
        else if ([c hasPrefix:@"dump:"]) {   // dump:<entity prefix>  write the matching states to dump.json (tokens removed)
            NSString *prefix = [c substringFromIndex:5];
            [[HAClient shared] getJSON:@"/api/states" completion:^(id json, NSError *e) {
                NSMutableArray *out = [NSMutableArray array];
                for (NSDictionary *s in ([json isKindOfClass:[NSArray class]] ? json : @[])) if ([Str(s[@"entity_id"]) hasPrefix:prefix]) [out addObject:s];
                NSData *d = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
                NSString *txt = [[NSString alloc] initWithData:d ?: [NSData data] encoding:NSUTF8StringEncoding];
                txt = [[NSRegularExpression regularExpressionWithPattern:@"(token=)[A-Za-z0-9_\\-]+" options:0 error:nil]
                       stringByReplacingMatchesInString:txt options:0 range:NSMakeRange(0, txt.length) withTemplate:@"$1x"];
                [txt writeToFile:@"/var/mobile/Library/HAPanel/dump.json" atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }];
        }
        else if ([c hasPrefix:@"detect:"]) {   // detect:<camera>  pretend Frigate just reported a person there
            NSDictionary *cfg = [self detectConfig] ?: @{@"frigate": @"http://none"};
            [self handleDetections:@[@{@"id": [[NSUUID UUID] UUIDString], @"camera": [c substringFromIndex:7], @"label": @"person"}] config:cfg];
        }
        else if ([c hasPrefix:@"edit:"] && self.editing) {
            // edit:card:<card*10+button>  edit:bar:<tag>  edit:place:<card>:<col>:<row>  edit:add:<preset>[:<entity>]
            // edit:screen:add|remove|next|prev  edit:restore  edit:save  edit:cancel
            NSArray *a = [c componentsSeparatedByString:@":"];
            UIButton *fake = [UIButton buttonWithType:UIButtonTypeCustom];
            fake.tag = a.count > 2 ? [a[2] integerValue] : 0;
            if ([a[1] isEqualToString:@"card"]) [self editButton:fake];
            else if ([a[1] isEqualToString:@"bar"]) [self editBarButton:fake];
            else if ([a[1] isEqualToString:@"restore"]) [self editRestore];
            else if ([a[1] isEqualToString:@"save"]) [self editSave];
            else if ([a[1] isEqualToString:@"cancel"]) [self editCancel];
            else if ([a[1] isEqualToString:@"peek"]) { for (UIView *ov in self.editOverlays) ov.hidden = !ov.hidden; }   // show the cards without the editing controls
            else if ([a[1] isEqualToString:@"picker"]) {   // edit:picker[:<preset>] shows the widget list (or one preset's entity list)
                [self showPicker];
                if (a.count > 2 && fake.tag < (NSInteger)[self widgetPresets].count) [self choosePreset:[self widgetPresets][fake.tag] entity:nil];
            }
            else if ([a[1] isEqualToString:@"place"] && a.count > 4) {
                NSMutableDictionary *spec = [self editSpecOfCard:[a[2] integerValue]];
                if (spec && ![self moveSpec:spec toCol:[a[3] integerValue] row:[a[4] integerValue] onto:nil]) self.editNote = @"No room there";
                [self refreshEditor];
            } else if ([a[1] isEqualToString:@"add"] && a.count > 2) {
                NSArray *presets = [self widgetPresets];
                if ([a[2] integerValue] < (NSInteger)presets.count) [self choosePreset:presets[[a[2] integerValue]] entity:a.count > 3 ? a[3] : nil];
            } else if ([a[1] isEqualToString:@"screen"] && a.count > 2) {
                if ([a[2] isEqualToString:@"add"]) [self editAddPage];
                else if ([a[2] isEqualToString:@"remove"]) [self editRemovePage];
                else { fake.tag = [a[2] isEqualToString:@"next"]; [self editPageStep:fake]; }
            }
        }
    }
}

- (void)saveScreenshot {
    UIView *v = self.view.window ?: self.view;
    v = self.view;
    UIGraphicsBeginImageContextWithOptions(v.bounds.size, YES, 1);
    // renderInContext (not drawViewHierarchy): works even when the display is asleep or locked
    [v.layer renderInContext:UIGraphicsGetCurrentContext()];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    [UIImageJPEGRepresentation(img, 0.8) writeToFile:@"/var/mobile/Library/HAPanel/snap.jpg" atomically:YES];
    HALog(@"snap: app state %ld, idle mode %ld, brightness %.2f", (long)[UIApplication sharedApplication].applicationState, (long)self.idleMode, [UIScreen mainScreen].brightness);
}

#pragma mark - Settings

- (void)gearTapped {
    HAClient *ha = [HAClient shared];
    [ha reloadConfig];
    NSString *pres = self.presence.running ? [NSString stringWithFormat:@"on (dims after %.0fs, last: %@ %.0fs ago)", self.dimAfter, self.lastReason ?: @"touch", -[self.lastSeen timeIntervalSinceNow]] : (self.presence.problem ?: @"off");
    NSString *msg = [NSString stringWithFormat:@"Server: %@\nPanel: %@\nToken: %@\nCards: %lu · Sidebar: %lu\nPresence: %@",
                     ha.baseURL, ha.panel, [ha isConfigured] ? @"configured" : @"missing", (unsigned long)self.cards.count, (unsigned long)self.drawers.count, pres];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Home panel" message:msg preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Colors…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self showThemePicker]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Edit layout\u2026" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { if (!self.editing) [self toggleEditMode]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Reload layout" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        self.usingStarter = NO; self.layoutData = nil; self.homeData = nil; [self fetchLayout]; [self poll];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Connection\u2026" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self showConnectionForm]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end

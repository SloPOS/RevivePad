#import <UIKit/UIKit.h>

// ---- Shared style ----
#define RGB(r,g,b) [UIColor colorWithRed:(r)/255.0 green:(g)/255.0 blue:(b)/255.0 alpha:1]
// Theme keys: background, card, button, text, dim, accent, media, heat, cool
UIColor *HA_BG(void);       // screen background
UIColor *HA_CARD(void);     // card background
UIColor *HA_OFF(void);      // buttons that are off
UIColor *HA_TEXT(void);     // primary text
UIColor *HA_DIM(void);      // secondary text
UIColor *HA_ACCENT(void);   // things that are on (lights, toggles)
UIColor *HA_BLUE(void);     // media controls
UIColor *HA_HEAT(void);     // heating
UIColor *HA_COOL(void);     // cooling
UIColor *HA_ColorFromHex(NSString *hex);
NSString *HA_HexFromColor(UIColor *c);
void HA_SetTheme(NSDictionary *hexByKey);  // merged theme; missing keys use defaults
NSDictionary *HA_DefaultTheme(void);
UIFont  *HA_FONT(CGFloat size, CGFloat weight);
NSString *HA_WeatherGlyph(NSString *condition);
NSString *HA_WeatherText(NSString *condition);

@class HACard;

// The panel implements this; cards use it to talk to Home Assistant.
@protocol HACardHost <NSObject>
- (void)card:(HACard *)card callService:(NSString *)service data:(NSDictionary *)data;   // service = "light.turn_on"
- (void)cardWantsRefresh:(HACard *)card;
- (void)card:(HACard *)card openDrawer:(NSString *)name;   // opens the sidebar drawer with that "name"
@optional
- (BOOL)screenAwake;                                       // NO while the photo frame / blank screen is up
@end

// Base card. Built from one entry of the layout JSON "cards" array.
@interface HACard : UIView
@property (nonatomic, strong, readonly) NSDictionary *spec;
@property (nonatomic, weak) id<HACardHost> host;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, assign) BOOL active;      // NO while the card sits in a closed drawer

+ (HACard *)cardWithSpec:(NSDictionary *)spec host:(id<HACardHost>)host;   // nil for unknown types
- (instancetype)initWithSpec:(NSDictionary *)spec host:(id<HACardHost>)host;
- (NSArray *)entityIds;                       // entities this card wants polled
- (void)updateStates:(NSDictionary *)states;  // entity_id -> state object
- (void)tick;                                 // called once per second
- (void)reload;                               // called on layout load and every 10 min
// helpers for subclasses
- (UILabel *)addLabel:(CGFloat)size weight:(CGFloat)w color:(UIColor *)c;
- (UIButton *)addButton:(NSString *)title size:(CGFloat)size action:(SEL)action;
- (CGRect)contentRect;                        // area below the title
@end

// Small shared helpers
NSString *HA_Str(id v);
NSInteger HA_Int(id v, NSInteger def);
NSDate *HA_ParseISO(NSString *s);             // HA timestamps, with or without fractional seconds
NSArray *HA_CleanList(NSArray *list);         // copies of the dicts with JSON nulls removed
NSString *HA_PictureOf(NSDictionary *state);
// Artwork for what a speaker is playing: its own picture, else the Plex cover of the track it reports
// (needs the Plex server id, "plex_server" in the card), else the Plex session's picture when that
// session is on the same track.
NSString *HA_NowPlayingPicture(NSDictionary *speaker, NSDictionary *plexSession, NSString *plexServer);
// "Starting…" feedback between tapping a track and the speaker reporting that it plays (Cast takes a few seconds).
// Where a player is in its track right now, in seconds (-1 when it does not say), and "m:ss" text.
NSTimeInterval HA_MediaPosition(NSDictionary *state);
NSString *HA_Clock(NSTimeInterval seconds);
// The Plex play queue last started from the library card: { keys, base, token, server, repeat }.
// Cast speakers playing Plex offer no "next track" through Home Assistant, so skipping is done by
// starting the same queue again at the neighbouring track. Returns NO when the speaker can skip by
// itself or the current track is not in the remembered queue (then use the normal service).
void HA_QueueRemember(NSDictionary *queue);
BOOL HA_QueueSkip(NSInteger delta, NSString *entity, NSDictionary *state, HACard *card);
void HA_SetPendingPlay(id entity, NSString *title);
NSString *HA_PendingPlayLabel(NSString *entity);  // entity_picture_local, else entity_picture
NSString *HA_ISO(NSDate *d);                  // UTC ISO-8601, URL-safe ("+" encoded)
UIButton *HA_Chip(NSString *title, id target, SEL action);

// NOTE on tags: -viewWithTag: checks the receiver itself first. Tiles use their index as tag
// (0, 1, 2...), so subviews inside a tile must use tags >= 9000 or tile #N would find itself.

// ---- Animation helpers (cheap Core Animation, fine on an A5) ----
void HA_AddPress(UIButton *b);                          // shrink to 95% while pressed, spring back
void HA_SetBG(UIView *v, UIColor *c);                   // animate background colour only when it changes
void HA_Fade(UIView *v, CFTimeInterval duration);       // cross-dissolve the next content change
void HA_Push(UIView *v, BOOL up);                       // slide the next content change up/down (number roll)

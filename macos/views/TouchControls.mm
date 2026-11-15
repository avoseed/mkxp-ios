/*
 ** TouchControls.mm
 **
 ** iOS-only. A UIKit overlay styled after the Super Famicom pad, drawn on top of
 ** SDL's GL view: a black D-pad, the red/yellow/blue/green
 ** A/B/X/Y diamond, grey L/R shoulders and a START-style speed-up button. Each
 ** control writes directly into EventThread::keyStates[] — the same array Input
 ** snapshots every frame — so the existing keyboard bindings are fully reused:
 **   A = C (use), B = X (back), X = Z (menu), Y = D (special),
 **   L = A (jump up), R = S (jump down), speed-up = Q.
 **
 ** Buttons carry a small caption with what they do in the game (결정, 취소, …),
 ** and the pad is laid out inside the black bars beside the 4:3 picture.
 */

#include <TargetConditionals.h>

#if TARGET_OS_IPHONE

#import <UIKit/UIKit.h>
#import <SDL.h>
#import <SDL_syswm.h>
#import <SDL_scancode.h>

#include "eventthread.h"

#include <atomic>
#include <arpa/inet.h>
#include <execinfo.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdarg.h>
#include <unistd.h>

#import "port_save_sync.h"   // C linkage (port_save_sync.m is Objective-C)

extern "C" void mkxp_ios_setGamePaused(int reason, int on);   // eventthread.cpp
extern "C" int mkxp_ios_mixOtherAudio(void);                   // audiosession-ios.mm
extern "C" void mkxp_ios_setMixOtherAudio(int on);
extern "C" const char *mkxp_ios_dataRoot(void);                // filesystemImplApple.mm
extern "C" const char *mkxp_ios_gameImportDir(void);

/* Why the game is paused (mkxp_ios_setGamePaused): README section 10. */
enum { kPauseInactive = 1, kPauseSettings = 2, kPauseEditor = 4 };

static void pressKey(int sc, bool down) {
    EventThread::keyStates[sc] = down;
    /* A tap can go down and up between two game frames; latch it so Input sees it. */
    if (down)
        EventThread::keyStatesLatch[sc] = true;
}

static UIColor *rgb(int r, int g, int b, CGFloat a = 1.0) {
    return [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a];
}

/* Super Famicom palette. */
static UIColor *padBlack()  { return rgb(38, 38, 42); }

/* ------------------------------------------------------------------------- */

/* Overlay that only intercepts touches that land on a control; everything else
 * falls through to SDL's GL view underneath. */
@interface MKXPTouchOverlay : UIView <UIDocumentPickerDelegate>
- (void)showToast:(NSString *)text;
@end

/* ------------------------------------------------------------------------- */

/* A round (or capsule) button: coloured, slightly domed, with a letter or symbol
 * and an optional caption under it. */
@interface MKXPPadButton : UIView
- (instancetype)initWithScancode:(int)sc glyph:(NSString *)glyph symbol:(NSString *)symbol
                         caption:(NSString *)caption color:(UIColor *)color ink:(UIColor *)ink;
@property (nonatomic) BOOL capsule;
@property (nonatomic) BOOL editing;   // layout editor: ignore presses
- (void)releaseAll;
@end

@implementation MKXPPadButton {
    int _scancode;
    BOOL _down;
    UIView *_face;
    CAGradientLayer *_dome;
    UILabel *_glyph;
    UIImageView *_symbol;
    UILabel *_caption;
    UIImpactFeedbackGenerator *_haptic;
}

- (instancetype)initWithScancode:(int)sc glyph:(NSString *)glyph symbol:(NSString *)symbol
                         caption:(NSString *)caption color:(UIColor *)color ink:(UIColor *)ink {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _scancode = sc;
    self.multipleTouchEnabled = YES;

    _face = [[UIView alloc] init];
    _face.userInteractionEnabled = NO;
    _face.backgroundColor = color;
    _face.layer.borderWidth = 1;
    _face.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.35].CGColor;
    _face.layer.shadowColor = UIColor.blackColor.CGColor;
    _face.layer.shadowOpacity = 0.5;
    _face.layer.shadowRadius = 1.5;
    _face.layer.shadowOffset = CGSizeMake(0, 2);
    [self addSubview:_face];

    /* Light from above: a highlight fading into a darker lower edge. */
    _dome = [CAGradientLayer layer];
    _dome.colors = @[(id)[UIColor colorWithWhite:1 alpha:0.38].CGColor,
                     (id)[UIColor colorWithWhite:1 alpha:0.0].CGColor,
                     (id)[UIColor colorWithWhite:0 alpha:0.18].CGColor];
    _dome.locations = @[@0.0, @0.5, @1.0];
    _dome.masksToBounds = YES;
    [_face.layer addSublayer:_dome];

    if (symbol) {
        _symbol = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
        _symbol.tintColor = ink;
        _symbol.contentMode = UIViewContentModeScaleAspectFit;
        [_face addSubview:_symbol];
    } else {
        _glyph = [[UILabel alloc] init];
        _glyph.text = glyph;
        _glyph.textColor = ink;
        _glyph.textAlignment = NSTextAlignmentCenter;
        [_face addSubview:_glyph];
    }

    if (caption) {
        _caption = [[UILabel alloc] init];
        _caption.text = caption;
        _caption.textColor = [ink colorWithAlphaComponent:0.85];
        _caption.textAlignment = NSTextAlignmentCenter;
        [_face addSubview:_caption];
    }

    _haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    return self;
}

/* Glyph centred on the face, or raised with the caption tucked under it. */
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat w = b.size.width, h = b.size.height, s = MIN(w, h);
    /* bounds + center rather than frame: the face carries a press transform. */
    _face.bounds = b;
    _face.center = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
    _face.layer.cornerRadius = self.capsule ? h / 2 : s / 2;
    _dome.frame = _face.bounds;
    _dome.cornerRadius = _face.layer.cornerRadius;
    CGFloat glyphY = _caption ? h * 0.40 : h * 0.5;
    if (_glyph) {
        _glyph.font = [UIFont systemFontOfSize:s * (_caption ? 0.40 : self.capsule ? 0.5 : 0.46)
                                        weight:UIFontWeightHeavy];
        _glyph.frame = CGRectMake(0, glyphY - h * 0.3, w, h * 0.6);
    }
    if (_symbol) {
        CGFloat g = s * (_caption ? 0.34 : 0.42);
        _symbol.frame = CGRectMake((w - g) / 2, glyphY - g / 2, g, g);
    }
    if (_caption) {
        _caption.font = [UIFont systemFontOfSize:MAX(9, s * 0.18) weight:UIFontWeightBold];
        _caption.frame = CGRectMake(0, h * 0.64, w, h * 0.2);
    }
}

- (void)setDown:(BOOL)down {
    if (down == _down) return;
    _down = down;
    pressKey(_scancode, down);
    if (down) [_haptic impactOccurred];
    [UIView animateWithDuration:0.05 animations:^{
        /* Pressed in: sinks a little, loses its shadow and highlight. */
        self->_face.transform = down ? CGAffineTransformMakeTranslation(0, 1.5) : CGAffineTransformIdentity;
        self->_face.layer.shadowOpacity = down ? 0.1 : 0.5;
        self->_face.alpha = down ? 0.82 : 1.0;
    }];
}

- (void)releaseAll { [self setDown:NO]; }

- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    if (!self.editing) [self setDown:YES];
}
- (void)touchesMoved:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    if (self.editing) return;
    /* Slide off to release, like a real button; generous slop for thumbs. */
    CGPoint p = [t.anyObject locationInView:self];
    [self setDown:CGRectContainsPoint(CGRectInset(self.bounds, -16, -16), p)];
}
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self setDown:NO]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self setDown:NO]; }
@end

/* ------------------------------------------------------------------------- */

/* A black plus-shaped D-pad. Tracks one finger and picks the dominant axis from
 * its position, so you can slide between directions without lifting. */
@interface MKXPDPad : UIView
@property (nonatomic) BOOL editing;   // layout editor: ignore presses
- (void)releaseAll;
@end

@implementation MKXPDPad {
    int _active;   // currently-held SDL scancode, or 0
    CAShapeLayer *_cross;
    CAShapeLayer *_highlight;
    CAShapeLayer *_dimple;
    NSArray<UIImageView *> *_arrows;   // up, down, left, right
    UIImpactFeedbackGenerator *_haptic;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _cross = [CAShapeLayer layer];
    _cross.fillColor = padBlack().CGColor;
    /* Outlined so the black cross still reads against the black bars. */
    _cross.strokeColor = rgb(120, 120, 130).CGColor;
    _cross.lineWidth = 1.5;
    _cross.shadowColor = UIColor.blackColor.CGColor;
    _cross.shadowOpacity = 0.5;
    _cross.shadowRadius = 2;
    _cross.shadowOffset = CGSizeMake(0, 2);
    [self.layer addSublayer:_cross];

    _highlight = [CAShapeLayer layer];
    _highlight.fillColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
    [self.layer addSublayer:_highlight];

    /* The shallow round dip in the middle of the cross. */
    _dimple = [CAShapeLayer layer];
    _dimple.fillColor = rgb(28, 28, 31).CGColor;
    [self.layer addSublayer:_dimple];

    NSMutableArray *arrows = [NSMutableArray array];
    for (NSString *name in @[@"arrowtriangle.up.fill", @"arrowtriangle.down.fill",
                             @"arrowtriangle.left.fill", @"arrowtriangle.right.fill"]) {
        UIImageView *v = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:name]];
        v.tintColor = rgb(92, 92, 100);
        v.contentMode = UIViewContentModeScaleAspectFit;
        [self addSubview:v];
        [arrows addObject:v];
    }
    _arrows = arrows;
    _haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    return self;
}

/* Arm rect for a direction (0 up, 1 down, 2 left, 3 right). */
- (CGRect)armRect:(int)dir {
    CGFloat s = MIN(self.bounds.size.width, self.bounds.size.height), w = s / 3;
    switch (dir) {
    case 0: return CGRectMake(w, 0, w, w);
    case 1: return CGRectMake(w, 2 * w, w, w);
    case 2: return CGRectMake(0, w, w, w);
    default: return CGRectMake(2 * w, w, w, w);
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat s = MIN(self.bounds.size.width, self.bounds.size.height), w = s / 3, r = w * 0.2;
    UIBezierPath *cross = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(w, 0, w, s) cornerRadius:r];
    [cross appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, w, s, w) cornerRadius:r]];
    _cross.path = cross.CGPath;
    _cross.frame = self.bounds;
    _highlight.frame = self.bounds;
    _dimple.path = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(CGRectMake(w, w, w, w), w * 0.2, w * 0.2)].CGPath;
    CGFloat g = w * 0.36;
    for (int i = 0; i < 4; i++) {
        CGRect a = [self armRect:i];
        _arrows[i].frame = CGRectMake(CGRectGetMidX(a) - g / 2, CGRectGetMidY(a) - g / 2, g, g);
    }
    [self updateHighlight];
}

- (void)updateHighlight {
    int dir = _active == SDL_SCANCODE_UP ? 0 : _active == SDL_SCANCODE_DOWN ? 1 :
              _active == SDL_SCANCODE_LEFT ? 2 : _active == SDL_SCANCODE_RIGHT ? 3 : -1;
    CGFloat w = MIN(self.bounds.size.width, self.bounds.size.height) / 3;
    _highlight.path = dir < 0 ? nil
        : [UIBezierPath bezierPathWithRoundedRect:CGRectInset([self armRect:dir], 1, 1)
                                     cornerRadius:w * 0.2].CGPath;
}

- (void)hold:(int)sc {
    if (sc == _active) return;
    if (_active) pressKey(_active, false);
    if (sc) { pressKey(sc, true); [_haptic impactOccurred]; }
    _active = sc;
    [self updateHighlight];
}

- (void)track:(UITouch *)t {
    CGPoint p = [t locationInView:self];
    CGFloat cx = self.bounds.size.width / 2, cy = self.bounds.size.height / 2;
    CGFloat dx = p.x - cx, dy = p.y - cy;
    CGFloat dead = MIN(cx, cy) * 0.22;   // center dead zone
    int sc = 0;
    if (dx * dx + dy * dy >= dead * dead) {
        if (fabs(dx) > fabs(dy)) sc = (dx < 0) ? SDL_SCANCODE_LEFT : SDL_SCANCODE_RIGHT;
        else                     sc = (dy < 0) ? SDL_SCANCODE_UP   : SDL_SCANCODE_DOWN;
    }
    [self hold:sc];
}

- (void)releaseAll { [self hold:0]; }

- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { if (!self.editing) [self track:t.anyObject]; }
- (void)touchesMoved:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { if (!self.editing) [self track:t.anyObject]; }
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self hold:0]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self hold:0]; }
@end

/* ------------------------------------------------------------------------- */

/* Layout editor state, kept in NSUserDefaults: per control, a centre as a
 * fraction of the screen and a size multiplier; plus the overlay opacity. */
static NSString *const kLayoutKey = @"mkxpTouchLayout";
static NSString *const kAlphaKey = @"mkxpTouchAlpha";
static NSString *const kPowerSaveKey = @"mkxpPowerSave";

/* Frame rate for games that ask to sync to the display (see Graphics::Graphics):
 * 60, or 40 in power-save mode. Read by the RGSS thread every frame. */
static std::atomic<int> g_targetFps{0};

extern "C" int mkxp_ios_targetFrameRate(void) {
    int fps = g_targetFps.load();
    if (fps == 0) {
        fps = [NSUserDefaults.standardUserDefaults boolForKey:kPowerSaveKey] ? 40 : 60;
        g_targetFps.store(fps);
    }
    return fps;
}

/* ------------------------------------------------------------------------- */
/* The app's log and crash record, for "PC로 진단 보내기" (README section 10).
 * stdout and stderr (the engine's Debug(), Ruby's output and errors, the port's
 * own lines) go to <data root>/mkxp.log; the previous run's log is kept as
 * mkxp-prev.log. A crash (signal or Objective-C exception) is written to
 * crash-pending.txt; the next launch turns it into crash-last.txt (with the
 * end of the log before it) and sends it to the PC if one answers. */

static NSString *dataRoot(void) { return @(mkxp_ios_dataRoot()); }

static NSString *appVersion(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    return [NSString stringWithFormat:@"v%@ (빌드 %@)", info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"]];
}

static void portLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void portLog(NSString *format, ...) {
    va_list ap;
    va_start(ap, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    fprintf(stderr, "mkxp-z: %s\n", line.UTF8String);
}

/* The last `limit` bytes of a text file, or nil. */
static NSString *fileTail(NSString *path, NSUInteger limit) {
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d.length) return nil;
    if (d.length > limit) d = [d subdataWithRange:NSMakeRange(d.length - limit, limit)];
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]
        ?: [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];
}

static char g_crashPath[1024];

static void writeAll(int fd, const char *s) {
    size_t n = strlen(s);
    while (n > 0) {
        ssize_t w = write(fd, s, n);
        if (w <= 0) return;
        s += w;
        n -= (size_t)w;
    }
}

/* Async-signal-safe enough: open/write/backtrace_symbols_fd, no allocation. */
static void crashSignal(int sig) {
    char head[32] = "signal ";
    int i = 7;
    if (sig >= 10) head[i++] = '0' + (sig / 10) % 10;
    head[i++] = '0' + sig % 10;
    head[i++] = '\n';
    head[i] = 0;
    void *frames[64];
    int count = backtrace(frames, 64);
    int fd = open(g_crashPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        writeAll(fd, head);
        backtrace_symbols_fd(frames, count, fd);
        close(fd);
    }
    writeAll(2, "mkxp-z: crash, ");
    writeAll(2, head);
    backtrace_symbols_fd(frames, count, 2);
    signal(sig, SIG_DFL);
    raise(sig);
}

static void crashException(NSException *e) {
    NSString *t = [NSString stringWithFormat:@"exception %@: %@\n%@\n", e.name, e.reason,
                   [e.callStackSymbols componentsJoinedByString:@"\n"]];
    [t writeToFile:@(g_crashPath) atomically:NO encoding:NSUTF8StringEncoding error:nil];
    fprintf(stderr, "mkxp-z: crash, %s", t.UTF8String);
}

/* Set when the game's config is read (mkxp_ios_syncSavesAtStart): the save
 * folder, where Essentials also writes errorlog.txt. */
static NSString *g_saveDir;

/* Version, device, the crash record (given, or the last one), Essentials'
 * errorlog.txt and the end of this run's log. */
static NSString *diagText(NSString *crash) {
    NSString *root = dataRoot();
    UIDevice *dev = UIDevice.currentDevice;
    NSMutableString *t = [NSMutableString stringWithFormat:@"AnotherRed %@, %@ iOS %@\n", appVersion(), dev.model,
                          dev.systemVersion];
    NSString *last = crash ?: [NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"crash-last.txt"]
                                                       encoding:NSUTF8StringEncoding error:nil];
    if (last.length) [t appendFormat:@"\n==== crash record\n%@\n", last];
    if (g_saveDir) {
        NSString *err = fileTail([g_saveDir stringByAppendingPathComponent:@"errorlog.txt"], 256 * 1024);
        if (err.length) [t appendFormat:@"\n==== errorlog.txt (game script errors)\n%@\n", err];
    }
    if (!crash) {
        NSString *log = fileTail([root stringByAppendingPathComponent:@"mkxp.log"], 1u << 20);
        if (log.length) [t appendFormat:@"\n==== mkxp.log\n%@", log];
    }
    return t;
}

/* The order "PC에서 받기" tries first: the last address that worked, then the usual ones. */
static NSArray<NSString *> *diagHosts(void) {
    NSMutableArray<NSString *> *hosts = [NSMutableArray array];
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:@"wifiImportAddress"];
    for (NSString *a in @[ saved ?: @"", @"192.168.0.2:8765", @"100.99.113.123:8765" ]) {
        NSString *h = [a stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([h hasPrefix:@"http://"]) h = [h substringFromIndex:7];
        while ([h hasSuffix:@"/"]) h = [h substringToIndex:h.length - 1];
        if (h.length && ![h containsString:@":"]) h = [h stringByAppendingString:@":8765"];
        if (h.length && ![hosts containsObject:h]) [hosts addObject:h];
    }
    return hosts;
}

/* POST /api/diag/AnotherRed/<name> (the server keeps it in logs\diag\AnotherRed).
 * Blocking, off the main thread; returns the host that took it, or nil. */
static NSString *diagPost(NSString *text, NSString *name, double timeout) {
    NSData *body = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.connectionProxyDictionary = @{};   // the PC is on the LAN: never through a VPN / proxy app
    config.timeoutIntervalForRequest = timeout;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    NSString *took = nil;
    for (NSString *host in diagHosts()) {
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@/api/diag/AnotherRed/%@", host, name]];
        if (!url) continue;
        NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:url];
        rq.HTTPMethod = @"POST";
        [rq setValue:@"text/plain; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
        __block NSInteger code = 0;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [[session uploadTaskWithRequest:rq fromData:body completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            code = e ? 0 : [(NSHTTPURLResponse *)r statusCode];
            dispatch_semaphore_signal(done);
        }] resume];
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
        if (code == 200) { took = host; break; }
    }
    [session finishTasksAndInvalidate];
    return took;
}

/* Called first thing in main(). */
extern "C" void mkxp_ios_startLog(void) {
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *root = dataRoot();
        NSString *log = [root stringByAppendingPathComponent:@"mkxp.log"];
        NSString *prev = [root stringByAppendingPathComponent:@"mkxp-prev.log"];
        [fm removeItemAtPath:prev error:nil];
        [fm moveItemAtPath:log toPath:prev error:nil];
        int fd = open(log.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) {
            dup2(fd, 1);
            dup2(fd, 2);
            close(fd);
            setvbuf(stdout, NULL, _IOLBF, 0);
            setvbuf(stderr, NULL, _IONBF, 0);
        }
        UIDevice *dev = UIDevice.currentDevice;
        portLog(@"Another Red %@, %@ iOS %@", appVersion(), dev.model, dev.systemVersion);

        /* The last run crashed: keep the record with the log before it, and send it. */
        NSString *pending = [root stringByAppendingPathComponent:@"crash-pending.txt"];
        NSString *lastPath = [root stringByAppendingPathComponent:@"crash-last.txt"];
        NSString *unsent = [root stringByAppendingPathComponent:@"crash-unsent"];
        NSString *crash = [NSString stringWithContentsOfFile:pending encoding:NSUTF8StringEncoding error:nil];
        if (crash.length) {
            NSString *before = fileTail(prev, 256 * 1024) ?: @"";
            NSString *record = [NSString stringWithFormat:@"%@\n==== the log before the crash (mkxp-prev.log)\n%@",
                                crash, before];
            [record writeToFile:lastPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [fm createFileAtPath:unsent contents:nil attributes:nil];
            portLog(@"the last run crashed; record kept in crash-last.txt");
        }
        [fm removeItemAtPath:pending error:nil];
        if ([fm fileExistsAtPath:unsent]) {
            NSString *record = [NSString stringWithContentsOfFile:lastPath encoding:NSUTF8StringEncoding error:nil];
            if (record.length) {
                NSString *text = diagText(record);
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    NSString *host = diagPost(text, @"crash.txt", 1.5);
                    if (host) {
                        [NSFileManager.defaultManager removeItemAtPath:unsent error:nil];
                        portLog(@"crash record sent to %@", host);
                    } else {
                        portLog(@"crash record not sent (no PC); tried again next launch");
                    }
                });
            } else {
                [fm removeItemAtPath:unsent error:nil];
            }
        }

        snprintf(g_crashPath, sizeof g_crashPath, "%s", pending.fileSystemRepresentation);
        static const int sigs[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP };
        for (int sig : sigs)
            signal(sig, crashSignal);
        NSSetUncaughtExceptionHandler(crashException);
    }
}

/* A black window over everything, for what has to happen before the game
 * starts (main() calls these before the SDL window exists, on the UIKit main
 * thread or not). present gets its view controller and calls finish when done. */
typedef void (^PortFinish)(void);
static void runBlockingWindow(NSString *message, void (^present)(UIViewController *vc, PortFinish finish)) {
    __block BOOL finished = NO;
    __block UIWindow *window = nil;
    void (^show)(void) = ^{
        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = UIColor.blackColor;
        UILabel *label = [[UILabel alloc] init];
        label.text = message;
        label.numberOfLines = 0;
        label.textAlignment = NSTextAlignmentCenter;
        label.textColor = [UIColor colorWithWhite:1 alpha:0.8];
        label.font = [UIFont systemFontOfSize:15];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [vc.view addSubview:label];
        [NSLayoutConstraint activateConstraints:@[
            [label.centerXAnchor constraintEqualToAnchor:vc.view.centerXAnchor],
            [label.centerYAnchor constraintEqualToAnchor:vc.view.centerYAnchor],
            [label.widthAnchor constraintLessThanOrEqualToAnchor:vc.view.widthAnchor constant:-48],
        ]];
        window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        window.rootViewController = vc;
        [window makeKeyAndVisible];
        present(vc, ^{ finished = YES; });
    };
    void (^hide)(void) = ^{
        window.hidden = YES;
        window = nil;
    };
    if (NSThread.isMainThread) {
        show();
        while (!finished)
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
        hide();
    } else {
        dispatch_sync(dispatch_get_main_queue(), show);
        while (!finished)
            usleep(50 * 1000);
        dispatch_sync(dispatch_get_main_queue(), hide);
    }
}

/* ------------------------------------------------------------------------- */
/* Saves shared between devices (README section 4, port_save_sync.m): a folder
 * picked in the Files app and / or the PC. The paths are the save folder's from
 * the data root ("Pokemon Another Red/Game.rxdata"), the same folder name as
 * the PC game's %APPDATA%\Pokemon Another Red, so a PC save put in
 * E:\ios-ports\saves\AnotherRed\Pokemon Another Red comes down as it is. */

static NSString *g_pendingToast;   // shown once the pad overlay is up

static void askSyncConflict(UIViewController *vc, void (^answer)(int resolve)) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"세이브가 양쪽에서 바뀌었습니다"
        message:@"이 기기와 다른 기기(공유 폴더·PC)에서 같은 세이브가 각각 바뀌었습니다. 어느 쪽을 쓸까요?\n"
                @"(바뀌는 쪽의 이전 세이브는 이 기기의 save-backup, PC의 .history에 남습니다.)"
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"이 기기 세이브" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) { answer(1); }]];
    [a addAction:[UIAlertAction actionWithTitle:@"다른 기기 세이브" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) { answer(-1); }]];
    [a addAction:[UIAlertAction actionWithTitle:@"나중에" style:UIAlertActionStyleCancel
                                        handler:^(UIAlertAction *x) { answer(0); }]];
    [vc presentViewController:a animated:YES completion:nil];
}

static void syncAtStartStep(UIViewController *vc, int resolve, PortFinish finish) {
    port_sync_run_start(resolve, ^(NSString *summary, BOOL conflict, BOOL changed) {
        portLog(@"save sync (start): %@", summary);
        if ([summary containsString:@"PC 세이브는 확인 못 함"])
            g_pendingToast = @"PC 세이브는 확인 못 함";
        if (!conflict) { finish(); return; }
        askSyncConflict(vc, ^(int r) {
            if (r) syncAtStartStep(vc, r, finish);
            else finish();
        });
    });
}

/* main(), once the config (and so the save folder) is known, before the game
 * starts. Also: leaving the app sends new saves up (nothing is written here
 * then; the game is paused while the app is inactive). */
extern "C" void mkxp_ios_syncSavesAtStart(const char *saveDir) {
    @autoreleasepool {
        NSString *root = dataRoot();
        g_saveDir = @(saveDir);
        NSString *rel = g_saveDir.lastPathComponent;
        if ([g_saveDir hasPrefix:[root stringByAppendingString:@"/"]])
            rel = [g_saveDir substringFromIndex:root.length + 1];
        /* Not shared: Essentials' errorlog.txt, mkxp's per-device mkxp.json and
         * keybindings.mkxp1 (pad bindings differ between iOS and the PC). */
        port_sync_configure(@"AnotherRed", root, @[ rel ], @[ @"log", @"txt", @"json", @"mkxp1" ]);
        portLog(@"save folder: %@ (shared as %@)", g_saveDir, rel);

        static BOOL observing;
        if (!observing) {
            observing = YES;
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification
                object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
                if (!port_sync_configured()) return;
                UIApplication *app = UIApplication.sharedApplication;
                __block UIBackgroundTaskIdentifier task = [app beginBackgroundTaskWithExpirationHandler:^{
                    [app endBackgroundTask:task];
                    task = UIBackgroundTaskInvalid;
                }];
                port_sync_run(0, YES, ^(NSString *summary, BOOL conflict, BOOL changed) {
                    portLog(@"save sync (background): %@", summary);
                    if (task != UIBackgroundTaskInvalid) {
                        [app endBackgroundTask:task];
                        task = UIBackgroundTaskInvalid;
                    }
                });
            }];
        }

        if (!port_sync_configured())
            return;
        runBlockingWindow(@"세이브를 다른 기기와 맞추는 중…", ^(UIViewController *vc, PortFinish finish) {
            syncAtStartStep(vc, 0, finish);
        });
    }
}

@implementation MKXPTouchOverlay {
    MKXPDPad *_dpad;
    MKXPPadButton *_a, *_b, *_x, *_y, *_l, *_r, *_speed;
    UILabel *_speedLabel;
    NSDictionary<NSString *, UIView *> *_controls;   // id -> control
    NSMutableDictionary<NSString *, NSDictionary *> *_custom;   // id -> {x, y, s}
    CGFloat _alpha;

    UIButton *_gear;
    BOOL _editing;
    UIView *_selected;
    CGFloat _pinchStart;
    UIView *_toolbar;
    UISlider *_alphaSlider;
    UILabel *_hint;

    /* Settings panel (the gear), README section 10 order. */
    UIView *_settings;
    UIButton *_syncFolderButton;
    UISwitch *_syncPCSwitch;
    UILabel *_syncStatus;
    UIButton *_diagButton;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.multipleTouchEnabled = YES;

    UIColor *white = UIColor.whiteColor, *dark = rgb(60, 60, 66), *brown = rgb(92, 64, 10);

    _dpad =[[MKXPDPad alloc] initWithFrame:CGRectZero];
    _a = [[MKXPPadButton alloc] initWithScancode:SDL_SCANCODE_C glyph:@"A" symbol:nil caption:@"결정"
                                           color:rgb(206, 36, 44) ink:white];
    _b = [[MKXPPadButton alloc] initWithScancode:SDL_SCANCODE_X glyph:@"B" symbol:nil caption:@"취소"
                                           color:rgb(244, 192, 30) ink:brown];
    _x = [[MKXPPadButton alloc] initWithScancode:SDL_SCANCODE_Z glyph:@"X" symbol:nil caption:@"메뉴"
                                           color:rgb(44, 76, 166) ink:white];
    _y = [[MKXPPadButton alloc] initWithScancode:SDL_SCANCODE_D glyph:@"Y" symbol:nil caption:@"등록"
                                           color:rgb(30, 142, 72) ink:white];
    _l = [[MKXPPadButton alloc] initWithScancode:SDL_SCANCODE_A glyph:@"L" symbol:nil caption:nil
                                           color:rgb(178, 178, 188) ink:dark];
    _r = [[MKXPPadButton alloc] initWithScancode:SDL_SCANCODE_S glyph:@"R" symbol:nil caption:nil
                                           color:rgb(178, 178, 188) ink:dark];
    /* Speed-up as a START/SELECT-style slanted pill, labelled under it. */
    _speed = [[MKXPPadButton alloc] initWithScancode:SDL_SCANCODE_Q glyph:nil symbol:@"forward.fill"
                                             caption:nil color:rgb(84, 84, 94) ink:rgb(210, 210, 218)];
    _l.capsule = _r.capsule = _speed.capsule = YES;
    _speed.transform = CGAffineTransformMakeRotation(-25.0 * M_PI / 180.0);
    _speedLabel = [[UILabel alloc] init];
    _speedLabel.text = @"배속";
    _speedLabel.textColor = rgb(170, 170, 180);
    _speedLabel.textAlignment = NSTextAlignmentCenter;
    _speedLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];

    for (UIView *v in @[_dpad, _a, _b, _x, _y, _l, _r, _speed, _speedLabel])
        [self addSubview:v];

    _controls = @{ @"dpad": _dpad, @"a": _a, @"b": _b, @"x": _x, @"y": _y,
                   @"l": _l, @"r": _r, @"speed": _speed };
    NSUserDefaults *defs = NSUserDefaults.standardUserDefaults;
    _custom = [([defs dictionaryForKey:kLayoutKey] ?: @{}) mutableCopy];
    _alpha = [defs objectForKey:kAlphaKey] ? [defs doubleForKey:kAlphaKey] : 1.0;

    for (UIView *v in _controls.allValues) {
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragged:)];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped:)];
        pan.enabled = tap.enabled = NO;
        [v addGestureRecognizer:pan];
        [v addGestureRecognizer:tap];
    }
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinched:)];
    pinch.enabled = NO;
    [self addGestureRecognizer:pinch];

    _gear = [UIButton buttonWithType:UIButtonTypeSystem];
    [_gear setImage:[UIImage systemImageNamed:@"gearshape.fill"] forState:UIControlStateNormal];
    _gear.tintColor = rgb(150, 150, 160);
    [_gear addTarget:self action:@selector(showSettings) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_gear];

    [self buildToolbar];
    [self applyAlpha];
    return self;
}

- (UIButton *)toolButton:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    b.tintColor = UIColor.whiteColor;
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.15];
    b.layer.cornerRadius = 8;
    b.contentEdgeInsets = UIEdgeInsetsMake(6, 12, 6, 12);
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)buildToolbar {
    _toolbar = [[UIView alloc] init];
    _toolbar.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.9];
    _toolbar.layer.cornerRadius = 14;
    _toolbar.hidden = YES;

    UILabel *alphaLabel = [[UILabel alloc] init];
    alphaLabel.text = @"투명도";
    alphaLabel.textColor = UIColor.whiteColor;
    alphaLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    _alphaSlider = [[UISlider alloc] init];
    _alphaSlider.minimumValue = 0.2;
    _alphaSlider.maximumValue = 1.0;
    [_alphaSlider addTarget:self action:@selector(alphaChanged:) forControlEvents:UIControlEventValueChanged];
    [_alphaSlider.widthAnchor constraintEqualToConstant:110].active = YES;

    /* (절전 모드 moved to the settings panel, 화면.) */
    UIStackView *top = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self toolButton:@"크기 −" action:@selector(shrink)],
        [self toolButton:@"크기 +" action:@selector(grow)],
        alphaLabel, _alphaSlider,
    ]];
    UIStackView *bottom = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self toolButton:@"초기화" action:@selector(resetLayout)],
        [self toolButton:@"완료" action:@selector(stopEditing)],
    ]];
    for (UIStackView *s in @[top, bottom]) {
        s.spacing = 10;
        s.alignment = UIStackViewAlignmentCenter;
    }
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[top, bottom]];
    row.axis = UILayoutConstraintAxisVertical;
    row.spacing = 8;
    row.alignment = UIStackViewAlignmentCenter;
    row.translatesAutoresizingMaskIntoConstraints = NO;

    _hint = [[UILabel alloc] init];
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    _hint.text = [NSString stringWithFormat:
        @"버튼을 끌어서 옮기고, 고른 버튼을 두 손가락으로 벌리거나 오므려 크기를 바꾸세요.   v%@ (%@)",
        info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"]];
    _hint.textColor = [UIColor colorWithWhite:1 alpha:0.75];
    _hint.font = [UIFont systemFontOfSize:12];
    _hint.textAlignment = NSTextAlignmentCenter;
    _hint.translatesAutoresizingMaskIntoConstraints = NO;

    [_toolbar addSubview:row];
    [_toolbar addSubview:_hint];
    [NSLayoutConstraint activateConstraints:@[
        [row.topAnchor constraintEqualToAnchor:_toolbar.topAnchor constant:10],
        [row.centerXAnchor constraintEqualToAnchor:_toolbar.centerXAnchor],
        [_hint.topAnchor constraintEqualToAnchor:row.bottomAnchor constant:6],
        [_hint.leadingAnchor constraintEqualToAnchor:_toolbar.leadingAnchor constant:10],
        [_hint.trailingAnchor constraintEqualToAnchor:_toolbar.trailingAnchor constant:-10],
    ]];
    [self addSubview:_toolbar];
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    /* While editing, keep the touch so pinches anywhere resize the selected control. */
    if (hit == self)
        return _editing ? self : nil;
    return hit;
}

/* ---- Layout editor ---- */

- (void)setEditing:(BOOL)editing {
    _editing = editing;
    /* The game waits while the pad is being laid out. */
    mkxp_ios_setGamePaused(kPauseEditor, editing ? 1 : 0);
    for (UIView *v in _controls.allValues) {
        [(id)v setEditing:editing];
        if (editing) [(id)v releaseAll];
        for (UIGestureRecognizer *g in v.gestureRecognizers)
            g.enabled = editing;
    }
    for (UIGestureRecognizer *g in self.gestureRecognizers)
        g.enabled = editing;
    _toolbar.hidden = !editing;
    _gear.hidden = editing;
    _alphaSlider.value = _alpha;
    [self select:editing ? _dpad : nil];
    [self applyAlpha];
}

- (void)startEditing { [self setEditing:YES]; }

- (void)stopEditing {
    [self setEditing:NO];
    [self save];
}

- (void)select:(UIView *)v {
    _selected.layer.borderWidth = 0;
    _selected = v;
    v.layer.borderWidth = 2;
    v.layer.borderColor = rgb(255, 214, 10).CGColor;
    v.layer.cornerRadius = 8;
}

- (NSString *)idOf:(UIView *)v {
    return [_controls allKeysForObject:v].firstObject;
}

/* Current centre/scale of a control, in the stored (fractional) form. */
- (NSMutableDictionary *)entryFor:(UIView *)v {
    NSString *key = [self idOf:v];
    NSMutableDictionary *e = [(_custom[key] ?: @{}) mutableCopy];
    CGSize sz = self.bounds.size;
    e[@"x"] = @(v.center.x / sz.width);
    e[@"y"] = @(v.center.y / sz.height);
    if (!e[@"s"]) e[@"s"] = @1.0;
    return e;
}

- (void)setScale:(CGFloat)s of:(UIView *)v {
    if (!v) return;
    NSMutableDictionary *e = [self entryFor:v];
    e[@"s"] = @(MIN(MAX(s, 0.6), 2.2));
    _custom[[self idOf:v]] = e;
    [self setNeedsLayout];
}

- (CGFloat)scaleOf:(UIView *)v {
    NSNumber *s = _custom[[self idOf:v]][@"s"];
    return s ? s.doubleValue : 1.0;
}

- (void)dragged:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    [self select:v];
    CGPoint t = [g translationInView:self];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:self];
    _custom[[self idOf:v]] = [self entryFor:v];
    if (v == _speed) [self placeSpeedLabel];
    if (g.state == UIGestureRecognizerStateEnded) [self setNeedsLayout];
}

- (void)tapped:(UITapGestureRecognizer *)g { [self select:g.view]; }

- (void)pinched:(UIPinchGestureRecognizer *)g {
    if (!_selected) return;
    if (g.state == UIGestureRecognizerStateBegan) _pinchStart = [self scaleOf:_selected];
    [self setScale:_pinchStart * g.scale of:_selected];
}

- (void)shrink { [self setScale:[self scaleOf:_selected] - 0.1 of:_selected]; }
- (void)grow { [self setScale:[self scaleOf:_selected] + 0.1 of:_selected]; }

- (void)powerSaveChanged:(UISwitch *)s {
    [NSUserDefaults.standardUserDefaults setBool:s.on forKey:kPowerSaveKey];
    g_targetFps.store(s.on ? 40 : 60);
}

/* ---- Settings panel: title, 세이브 공유, 다른 앱 소리와 함께, 화면, 패드,
 * PC로 진단 보내기, 도움말, 닫기 (README section 10). The game is paused
 * while it is open. ---- */

- (UIViewController *)presenter {
    UIViewController *vc = self.window.rootViewController;
    while (vc.presentedViewController)
        vc = vc.presentedViewController;
    return vc;
}

- (UILabel *)panelLabel:(NSString *)text size:(CGFloat)size color:(UIColor *)color {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.numberOfLines = 0;
    l.textColor = color;
    l.font = [UIFont systemFontOfSize:size weight:UIFontWeightSemibold];
    return l;
}

- (UIButton *)panelButton:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    b.titleLabel.numberOfLines = 0;
    b.tintColor = UIColor.whiteColor;
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    b.layer.cornerRadius = 9;
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    b.contentEdgeInsets = UIEdgeInsetsMake(9, 14, 9, 14);
    [b.heightAnchor constraintGreaterThanOrEqualToConstant:42].active = YES;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UIView *)panelSwitch:(NSString *)title on:(BOOL)on action:(SEL)action made:(UISwitch **)made {
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = on;
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    UILabel *l = [self panelLabel:title size:16 color:UIColor.whiteColor];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[ l, sw ]];
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 10;
    row.layoutMargins = UIEdgeInsetsMake(4, 14, 4, 8);
    row.layoutMarginsRelativeArrangement = YES;
    if (made) *made = sw;
    return row;
}

- (NSString *)syncFolderTitle {
    NSString *name = port_sync_folder_name();
    return [NSString stringWithFormat:@"공유 폴더 · %@", name ?: @"없음"];
}

- (void)showSettings {
    if (_settings) return;
    for (UIView *v in _controls.allValues)
        [(id)v releaseAll];
    mkxp_ios_setGamePaused(kPauseSettings, 1);

    UIView *panel = [[UIView alloc] initWithFrame:self.bounds];
    panel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    panel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];

    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.97];
    card.layer.cornerRadius = 14;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [panel addSubview:card];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    [card addSubview:scroll];

    UIColor *dim = [UIColor colorWithWhite:1 alpha:0.6];
    NSMutableArray<UIView *> *rows = [NSMutableArray array];
    NSString *name = NSBundle.mainBundle.infoDictionary[@"CFBundleDisplayName"] ?: @"Another Red";
    [rows addObject:[self panelLabel:[NSString stringWithFormat:@"%@ %@", name, appVersion()] size:18
                               color:UIColor.whiteColor]];

    [rows addObject:[self panelLabel:@"세이브 공유" size:13 color:dim]];
    _syncFolderButton = [self panelButton:[self syncFolderTitle] action:@selector(syncFolderTapped)];
    [rows addObject:_syncFolderButton];
    UISwitch *pc = nil;
    [rows addObject:[self panelSwitch:@"PC와 공유" on:port_sync_pc() action:@selector(syncPCChanged:) made:&pc]];
    _syncPCSwitch = pc;
    [rows addObject:[self panelButton:@"지금 맞추기" action:@selector(syncNowTapped)]];
    _syncStatus = [self panelLabel:@"게임 시작 전과 앱을 나갈 때 맞춥니다." size:12 color:dim];
    [rows addObject:_syncStatus];

    [rows addObject:[self panelLabel:@"소리" size:13 color:dim]];
    [rows addObject:[self panelSwitch:@"다른 앱 소리와 함께" on:mkxp_ios_mixOtherAudio() != 0
                               action:@selector(mixChanged:) made:nil]];

    [rows addObject:[self panelLabel:@"화면" size:13 color:dim]];
    [rows addObject:[self panelSwitch:@"절전 모드 · 40fps" on:mkxp_ios_targetFrameRate() == 40
                               action:@selector(powerSaveChanged:) made:nil]];

    [rows addObject:[self panelLabel:@"패드" size:13 color:dim]];
    [rows addObject:[self panelButton:@"패드 배치 · 크기 · 투명도" action:@selector(editLayoutTapped)]];

    [rows addObject:[self panelLabel:@"" size:6 color:dim]];
    _diagButton = [self panelButton:@"PC로 진단 보내기" action:@selector(diagTapped)];
    [rows addObject:_diagButton];
    [rows addObject:[self panelButton:@"도움말" action:@selector(helpTapped)]];
    UIButton *close = [self panelButton:@"닫기" action:@selector(hideSettings)];
    close.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    [rows addObject:close];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:rows];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];

    NSLayoutConstraint *wantW = [card.widthAnchor constraintEqualToConstant:440];
    wantW.priority = UILayoutPriorityDefaultHigh;
    NSLayoutConstraint *wantH = [card.heightAnchor constraintEqualToAnchor:stack.heightAnchor constant:32];
    wantH.priority = UILayoutPriorityDefaultHigh;
    UILayoutGuide *safe = panel.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        [card.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-24],
        [card.heightAnchor constraintLessThanOrEqualToAnchor:safe.heightAnchor constant:-16],
        wantW, wantH,
        [scroll.topAnchor constraintEqualToAnchor:card.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:16],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-16],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-16],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-32],
    ]];

    _settings = panel;
    [self addSubview:panel];
}

- (void)hideSettings {
    if (!_settings) return;
    [_settings removeFromSuperview];
    _settings = nil;
    _syncFolderButton = nil;
    _syncPCSwitch = nil;
    _syncStatus = nil;
    _diagButton = nil;
    mkxp_ios_setGamePaused(kPauseSettings, 0);
}

- (void)editLayoutTapped {
    [self setEditing:YES];   // pauses for the editor before the panel lets go
    [self hideSettings];
}

- (void)mixChanged:(UISwitch *)s {
    mkxp_ios_setMixOtherAudio(s.on ? 1 : 0);
}

/* While the game is paused: a save that comes down replaces the file; the game
 * shows it the next time its load screen reads the save. */
- (void)syncNow:(int)resolve {
    if (!port_sync_configured()) {
        _syncStatus.text = @"공유 폴더를 고르거나 'PC와 공유'를 켜세요.";
        return;
    }
    _syncStatus.text = @"세이브 맞추는 중…";
    port_sync_run(resolve, NO, ^(NSString *summary, BOOL conflict, BOOL changed) {
        portLog(@"save sync: %@", summary);
        self->_syncStatus.text = summary;
        if (conflict)
            askSyncConflict([self presenter], ^(int r) { if (r) [self syncNow:r]; });
    });
}

- (void)syncNowTapped { [self syncNow:0]; }

- (void)syncPCChanged:(UISwitch *)s {
    port_sync_set_pc(s.on);
    if (s.on) [self syncNow:0];
}

- (void)syncFolderTapped {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"세이브 공유 폴더"
        message:@"'파일' 앱의 iCloud Drive 폴더를 하나 고르면, 같은 폴더를 고른 다른 기기와 세이브를 맞춥니다."
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"폴더 고르기" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) { [self pickSyncFolder]; }]];
    if (port_sync_folder_name())
        [a addAction:[UIAlertAction actionWithTitle:@"공유 끄기" style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *x) {
            port_sync_set_folder(nil);
            [self->_syncFolderButton setTitle:[self syncFolderTitle] forState:UIControlStateNormal];
        }]];
    [a addAction:[UIAlertAction actionWithTitle:@"취소" style:UIAlertActionStyleCancel handler:nil]];
    [[self presenter] presentViewController:a animated:YES completion:nil];
}

- (void)pickSyncFolder {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    /* (initForOpeningContentTypes: needs UniformTypeIdentifiers; this works on iOS 14 too.) */
    UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc]
        initWithDocumentTypes:@[ @"public.folder" ] inMode:UIDocumentPickerModeOpen];
#pragma clang diagnostic pop
    p.delegate = self;
    [[self presenter] presentViewController:p animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    if (!port_sync_set_folder(url)) {
        _syncStatus.text = @"그 폴더는 쓸 수 없습니다.";
        return;
    }
    [_syncFolderButton setTitle:[self syncFolderTitle] forState:UIControlStateNormal];
    [self syncNow:0];
}

- (void)diagTapped {
    _diagButton.enabled = NO;
    [_diagButton setTitle:@"PC로 진단 보내기 · 보내는 중…" forState:UIControlStateNormal];
    UIButton *button = _diagButton;
    NSString *text = diagText(nil);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *host = diagPost(text, @"diag.txt", 4);
        portLog(@"diagnostics %@", host ? [@"sent to " stringByAppendingString:host] : @"not sent (no PC)");
        dispatch_async(dispatch_get_main_queue(), ^{
            button.enabled = YES;
            [button setTitle:host ? [@"PC로 진단 보내기 · 보냄 " stringByAppendingString:host]
                                  : @"PC로 진단 보내기 · PC를 못 찾음 (받기 서버 켜기)"
                    forState:UIControlStateNormal];
        });
    });
}

- (void)helpTapped {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"도움말"
        message:@"조작: A 결정 · B 취소 · X 메뉴 · Y 등록한 도구 · L/R · ▶▶ 누르는 동안 배속.\n"
                @"블루투스 패드를 연결하면 화면 버튼이 숨겨집니다.\n\n"
                @"세이브: '파일' 앱의 Another Red › Pokemon Another Red 폴더. PC판의 "
                @"%APPDATA%\\Pokemon Another Red와 같은 파일이라 서로 복사해 이어 할 수 있습니다.\n\n"
                @"세이브 공유: iCloud Drive 폴더를 고르거나 'PC와 공유'를 켜면 게임 시작 전과 앱을 나갈 때 "
                @"다른 기기와 맞춥니다. PC는 'PC에서-받기-서버'가 켜져 있어야 합니다.\n\n"
                @"설정이나 패드 배치가 열려 있는 동안과 앱을 잠시 나간 동안 게임이 멈춥니다."
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"확인" style:UIAlertActionStyleCancel handler:nil]];
    [[self presenter] presentViewController:a animated:YES completion:nil];
}

/* A short note at the bottom of the screen that fades by itself. */
- (void)showToast:(NSString *)text {
    UILabel *l = [[UILabel alloc] init];
    l.text = [NSString stringWithFormat:@"  %@  ", text];
    l.font = [UIFont boldSystemFontOfSize:14];
    l.textColor = UIColor.whiteColor;
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.65];
    l.layer.cornerRadius = 8;
    l.clipsToBounds = YES;
    [l sizeToFit];
    l.bounds = CGRectMake(0, 0, l.bounds.size.width, l.bounds.size.height + 12);
    l.center = CGPointMake(self.bounds.size.width / 2, self.bounds.size.height - 40);
    l.userInteractionEnabled = NO;
    [self addSubview:l];
    [UIView animateWithDuration:0.4 delay:2.5 options:0 animations:^{ l.alpha = 0; }
                     completion:^(BOOL f) { [l removeFromSuperview]; }];
}

- (void)alphaChanged:(UISlider *)s {
    _alpha = s.value;
    [self applyAlpha];
}

- (void)applyAlpha {
    for (UIView *v in _controls.allValues)
        v.alpha = _alpha;
    _speedLabel.alpha = _alpha;
}

- (void)resetLayout {
    [_custom removeAllObjects];
    _alpha = 1.0;
    _alphaSlider.value = _alpha;
    [self applyAlpha];
    [self setNeedsLayout];
}

- (void)save {
    NSUserDefaults *defs = NSUserDefaults.standardUserDefaults;
    [defs setObject:_custom forKey:kLayoutKey];
    [defs setDouble:_alpha forKey:kAlphaKey];
}

/* Default size/centre, then the player's override from the editor. */
- (void)place:(UIView *)v size:(CGSize)size center:(CGPoint)c {
    NSDictionary *e = _custom[[self idOf:v]];
    CGFloat s = e[@"s"] ? [e[@"s"] doubleValue] : 1.0;
    if (e[@"x"] && e[@"y"])
        c = CGPointMake([e[@"x"] doubleValue] * self.bounds.size.width,
                        [e[@"y"] doubleValue] * self.bounds.size.height);
    v.bounds = CGRectMake(0, 0, size.width * s, size.height * s);
    v.center = c;
}

- (void)placeSpeedLabel {
    _speedLabel.bounds = CGRectMake(0, 0, 80, 14);
    _speedLabel.center = CGPointMake(_speed.center.x, _speed.center.y + _speed.bounds.size.height / 2 + 14);
}

/* Sized from the screen: inside the bars beside the 4:3 game picture when they
 * are wide enough (phones in landscape), otherwise over the picture's edges. */
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    UIEdgeInsets safe = self.safeAreaInsets;
    /* The landscape notch only covers the middle of the side edge; the controls sit
     * in the corners, so only keep clear of the rounded screen corners. */
    safe.left = MIN(safe.left, 20);
    safe.right = MIN(safe.right, 20);
    CGFloat W = b.size.width, H = b.size.height;
    CGFloat bar = MAX((W - H * 4.0 / 3.0) / 2.0, 0);
    CGFloat leftW = MAX(bar - safe.left, 0), rightW = MAX(bar - safe.right, 0);
    CGFloat avail = MIN(leftW, rightW);
    CGFloat m = 10;   // margin from the screen edges
    /* Horizontal centres of the left and right control columns. */
    CGFloat lcx = safe.left + (leftW >= 100 ? leftW / 2 : 70);
    CGFloat rcx = W - safe.right - (rightW >= 100 ? rightW / 2 : 76);
    CGFloat bottomY = H - MAX(safe.bottom, m) - 6;

    /* D-pad: bottom-left. */
    CGFloat pad = MIN(MAX(avail * 0.86, 116), MIN(H * 0.4, 164));
    /* Never cover the game picture when the bars have room for a usable pad. */
    if (leftW >= 100)
        pad = MIN(pad, leftW - 8);
    CGFloat pcy = bottomY - pad / 2;
    [self place:_dpad size:CGSizeMake(pad, pad) center:CGPointMake(lcx, pcy)];

    /* A/B/X/Y diamond, Super Famicom layout (A right, B bottom, X top, Y left),
     * level with the D-pad. */
    CGFloat d = MIN(MAX(pad * 0.34, 44), 58);
    if (rightW >= 100)
        d = MIN(d, (rightW - 8) / 2.96);   // diamond is 2 * off + d wide
    CGFloat off = d * 0.98;
    CGSize face = CGSizeMake(d, d);
    [self place:_a size:face center:CGPointMake(rcx + off, pcy)];
    [self place:_b size:face center:CGPointMake(rcx, pcy + off)];
    [self place:_x size:face center:CGPointMake(rcx, pcy - off)];
    [self place:_y size:face center:CGPointMake(rcx - off, pcy)];

    /* Shoulders along the top; the speed-up pill under R, slanted like START. */
    CGFloat sw = MIN(MAX(avail * 0.8, 72), 120), sh = 32;
    CGFloat top = MAX(safe.top, m);
    [self place:_l size:CGSizeMake(sw, sh) center:CGPointMake(lcx, top + sh / 2)];
    [self place:_r size:CGSizeMake(sw, sh) center:CGPointMake(rcx, top + sh / 2)];
    [self place:_speed size:CGSizeMake(54, 22) center:CGPointMake(rcx, top + sh + 29)];
    [self placeSpeedLabel];

    /* Layout editor: gear under L, toolbar over the top of the game picture. */
    _gear.frame = CGRectMake(lcx - 18, top + sh + 10, 36, 36);
    /* Over the game picture only, so L/R stay reachable for dragging. */
    CGSize tb = CGSizeMake(MIN(MAX(W - 2 * bar - 8, 500), W - 24), 122);
    _toolbar.frame = CGRectMake((W - tb.width) / 2, top, tb.width, tb.height);
}
@end

/* ------------------------------------------------------------------------- */

static MKXPTouchOverlay *g_overlay = nil;
/* Set before the overlay exists when a pad is already connected at launch. */
static BOOL g_touchControlsHidden = NO;

/* Called from the event thread when a game controller connects/disconnects:
 * the overlay only gets in the way while playing on a Bluetooth pad. */
extern "C" void mkxp_ios_setTouchControlsHidden(int hidden) {
    dispatch_async(dispatch_get_main_queue(), ^{
        g_touchControlsHidden = hidden ? YES : NO;
        g_overlay.hidden = g_touchControlsHidden;
    });
}

extern "C" void mkxp_ios_initTouchControls(SDL_Window *win) {
    /* SDL runs SDL_main (the engine's main) on a secondary thread on iOS, so this
     * is NOT the UIKit main thread. All UIKit access — including reading the
     * window/view from SDL — must happen on the main queue. */
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            SDL_SysWMinfo info;
            SDL_VERSION(&info.version);
            if (!SDL_GetWindowWMInfo(win, &info))
                return;

            UIWindow *uiwin = info.info.uikit.window;
            UIView *root = uiwin.rootViewController.view ?: uiwin;
            if (root == nil || g_overlay != nil)
                return;

            g_overlay = [[MKXPTouchOverlay alloc] initWithFrame:root.bounds];
            g_overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            g_overlay.hidden = g_touchControlsHidden;
            [root addSubview:g_overlay];

            /* The game waits while the app is inactive (Control Center, a call,
             * the app switcher) and in the background. */
            NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
            [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil
                             queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
                mkxp_ios_setGamePaused(kPauseInactive, 1);
            }];
            [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
                             queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
                mkxp_ios_setGamePaused(kPauseInactive, 0);
            }];
            /* (No pause from the state at this point: under LiveContainer the
             * first DidBecomeActive may already have gone by.) */

            if (g_pendingToast) {
                NSString *text = g_pendingToast;
                g_pendingToast = nil;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ [g_overlay showToast:text]; });
            }
        }
    });
}

/* ------------------------------------------------------------------------- */
/* "PC에서 받기": shown by main() when there is no game yet. Fetches the game
 * from the PC (E:\ios-ports\tools\serve-games.py) over Wi-Fi straight into the
 * game folder, file by file, skipping files already there so an interrupted
 * transfer resumes. Protocol: GET /api/manifest/<App> -> {total, files: [{p, s}]},
 * GET /api/file/<App>/<p>. */

extern "C" const char *mkxp_ios_gameImportDir(void);   // filesystemImplApple.mm

static NSString *const kImportAddressKey = @"wifiImportAddress";

@interface MKXPImporter : NSObject <UITextFieldDelegate>
@property (nonatomic, copy) void (^finished)(BOOL ok);
/* Update: start right away from this PC (no search). */
@property (nonatomic, copy) NSString *autoAddress;
- (void)show;
- (void)hide;
@end

@implementation MKXPImporter {
    UIWindow *_window;
    UITextField *_field;
    UIButton *_button;
    UIProgressView *_bar;
    UILabel *_status;
    UIButton *_skip;
    BOOL _busy;   // a transfer is running
    NSString *_app;
    NSString *_dest;
}

- (void)show {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    _app = info[@"PortDataFolder"] ?: @"Game";
    _dest = @(mkxp_ios_gameImportDir());

    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = UIColor.blackColor;

    UILabel *label = [[UILabel alloc] init];
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont systemFontOfSize:15];
    /* A game already here: an update that is starting or was cut short. */
    BOOL haveGame = [NSFileManager.defaultManager fileExistsAtPath:[_dest stringByAppendingPathComponent:@"Game.ini"]];
    if (haveGame)
        label.text = @"PC에서 새 게임 파일을 받습니다. 끊기면 다시 누르면 이어서 받습니다.";
    else
        label.text = [NSString stringWithFormat:
            @"게임 파일이 없습니다.\nPC에서 'PC에서-받기-서버'를 켠 뒤 아래 버튼을 누르세요. PC는 자동으로 찾습니다.\n"
            @"또는 '파일' 앱의 %@ › game 폴더에 PC판 게임 폴더를 복사한 뒤 다시 실행하세요.", _app];

    _field = [[UITextField alloc] init];
    _field.placeholder = @"PC 주소 (비워 두면 자동으로 찾음)";
    _field.text = [NSUserDefaults.standardUserDefaults stringForKey:kImportAddressKey];
    _field.borderStyle = UITextBorderStyleRoundedRect;
    _field.keyboardType = UIKeyboardTypeURL;
    _field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _field.autocorrectionType = UITextAutocorrectionTypeNo;
    _field.delegate = self;
    [_field.widthAnchor constraintEqualToConstant:300].active = YES;

    _button = [UIButton buttonWithType:UIButtonTypeSystem];
    [_button setTitle:@"PC에서 받기" forState:UIControlStateNormal];
    _button.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [_button addTarget:self action:@selector(start) forControlEvents:UIControlEventTouchUpInside];

    _bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _bar.hidden = YES;
    [_bar.widthAnchor constraintEqualToConstant:300].active = YES;

    _status = [[UILabel alloc] init];
    _status.numberOfLines = 0;
    _status.textAlignment = NSTextAlignmentCenter;
    _status.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    _status.font = [UIFont systemFontOfSize:13];
    _status.text = [NSString stringWithFormat:@"v%@ (%@)", info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"]];

    NSMutableArray<UIView *> *items = [@[label, _field, _button, _bar, _status] mutableCopy];
    if (haveGame) {
        _skip = [UIButton buttonWithType:UIButtonTypeSystem];
        [_skip setTitle:@"건너뛰고 게임 시작" forState:UIControlStateNormal];
        _skip.titleLabel.font = [UIFont systemFontOfSize:15];
        [_skip addTarget:self action:@selector(skipUpdate) forControlEvents:UIControlEventTouchUpInside];
        [items insertObject:_skip atIndex:3];
    }
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:items];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [vc.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:vc.view.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:vc.view.centerYAnchor],
        [stack.widthAnchor constraintLessThanOrEqualToAnchor:vc.view.widthAnchor constant:-48],
    ]];

    _window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    _window.rootViewController = vc;
    [_window makeKeyAndVisible];
    if (self.autoAddress)
        [self start];
}

/* README section 9: the update's marker goes, the game as it is starts. Files
 * already replaced stay (each is whole: written to a temp file, then moved). */
- (void)skipUpdate {
    if (_busy) return;
    [NSFileManager.defaultManager removeItemAtPath:[_dest stringByAppendingPathComponent:@".pcimport-incomplete"]
                                             error:nil];
    portLog(@"update skipped");
    if (self.finished) self.finished(NO);
}

- (void)hide {
    _window.hidden = YES;
    _window = nil;
}

- (BOOL)textFieldShouldReturn:(UITextField *)field {
    [self start];
    return YES;
}

- (void)setStatus:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{ self->_status.text = text; });
}

/* ---- Finding the PC: no address needed ---- */

static NSData *fetchData(NSURLSession *s, NSURL *url, NSInteger *status, NSError **err);

static NSURL *addressURL(NSString *address) {
    NSString *text = [address containsString:@"://"] ? address : [@"http://" stringByAppendingString:address];
    NSURL *url = [NSURL URLWithString:text];
    return url.host ? url : nil;
}

/* serve-games answers "/" with {"apps": [...]}; true if it offers `app`. */
static BOOL probeAddress(NSURLSession *s, NSString *address, NSString *app) {
    NSURL *url = addressURL(address);
    if (!url) return NO;
    NSInteger code = 0;
    NSData *data = fetchData(s, url, &code, NULL);
    if (code != 200 || !data) return NO;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [json isKindOfClass:NSDictionary.class] && [json[@"apps"] containsObject:app];
}

/* "a.b.c.d:port" for every other host on the Wi-Fi (en*) IPv4 subnet, limited
 * to the phone's /24 when the subnet is larger than a /22. */
static NSArray<NSString *> *subnetHosts(int port) {
    NSMutableArray *hosts = [NSMutableArray array];
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return hosts;
    for (struct ifaddrs *ifa = list; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || !ifa->ifa_netmask || ifa->ifa_addr->sa_family != AF_INET ||
            strncmp(ifa->ifa_name, "en", 2) != 0)
            continue;
        uint32_t ip = ntohl(((struct sockaddr_in *)ifa->ifa_addr)->sin_addr.s_addr);
        uint32_t mask = ntohl(((struct sockaddr_in *)ifa->ifa_netmask)->sin_addr.s_addr);
        if (__builtin_popcount(mask) < 22) mask = 0xFFFFFF00;
        if (~mask < 2) continue;
        uint32_t net = ip & mask;
        for (uint32_t i = 1; i < ~mask; i++) {
            uint32_t h = net | i;
            if (h != ip)
                [hosts addObject:[NSString stringWithFormat:@"%u.%u.%u.%u:%d",
                                  h >> 24, (h >> 16) & 255, (h >> 8) & 255, h & 255, port]];
        }
    }
    freeifaddrs(list);
    return hosts;
}

/* Blocking: the given addresses, the PC this was set up with (LAN, Tailscale),
 * then every host on the subnet, 64 at a time. Nil if no PC answers. */
- (NSString *)discoverPreferring:(NSArray<NSString *> *)preferred {
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest = 1.5;
    config.connectionProxyDictionary = @{};   // the PC is on the LAN: never via a VPN/proxy app
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    NSMutableOrderedSet<NSString *> *first = [NSMutableOrderedSet orderedSet];
    for (NSString *a in [preferred arrayByAddingObjectsFromArray:@[@"192.168.0.2:8765", @"100.99.113.123:8765"]])
        if (a.length) [first addObject:a];
    for (NSString *a in first)
        if (probeAddress(session, a, _app)) return a;

    NSArray<NSString *> *hosts = subnetHosts(8765);
    __block NSString *found = nil;
    NSObject *lock = [[NSObject alloc] init];
    for (NSUInteger start = 0; start < hosts.count && !found; start += 64) {
        dispatch_group_t group = dispatch_group_create();
        for (NSUInteger i = start; i < MIN(start + 64, hosts.count); i++) {
            NSString *host = hosts[i];
            dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                @synchronized (lock) { if (found) return; }
                if (probeAddress(session, host, self->_app))
                    @synchronized (lock) { if (!found) found = host; }
            });
        }
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    }
    [session finishTasksAndInvalidate];
    return found;
}

- (void)start {
    if (_busy) return;
    NSString *typed = [_field.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:kImportAddressKey] ?: @"";
    NSString *direct = self.autoAddress;   // an update: the PC that just answered
    self.autoAddress = nil;
    _busy = YES;
    _skip.enabled = NO;
    [_field resignFirstResponder];
    _button.enabled = NO;
    _bar.hidden = NO;
    _status.text = @"같은 와이파이에서 PC를 찾는 중…";
    UIApplication.sharedApplication.idleTimerDisabled = YES;   // don't sleep mid-transfer
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *address = direct ?: [self discoverPreferring:@[typed, saved]];
        NSString *error = nil;
        if (!address) {
            error = @"PC를 찾지 못했습니다. '로컬 네트워크' 허용 창이 떴다면 허용한 뒤 다시 누르세요.\n"
                    @"그래도 안 되면 확인해 주세요:\n"
                    @"① PC에서 'PC에서-받기-서버.cmd'가 켜져 있나요?\n"
                    @"② 휴대폰이 PC와 같은 와이파이에 있나요? (셀룰러·VPN 끄기)\n"
                    @"③ 설정 › 개인정보 보호 및 보안 › 로컬 네트워크에서 LiveContainer(또는 이 앱)가 켜져 있나요?";
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_field.text = address;
                self->_status.text = [address stringByAppendingString:@"에 연결했습니다."];
            });
            [NSUserDefaults.standardUserDefaults setObject:address forKey:kImportAddressKey];
            error = [self runFrom:addressURL(address)];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            UIApplication.sharedApplication.idleTimerDisabled = NO;
            self->_busy = NO;
            self->_skip.enabled = YES;
            if (error) {
                self->_status.text = [error stringByAppendingString:@"\n다시 누르면 이어서 받습니다."];
                self->_button.enabled = YES;
            } else if (self.finished) {
                self.finished(YES);
            }
        });
    });
}

/* Blocking fetch helper for the worker threads. */
static NSData *fetchData(NSURLSession *s, NSURL *url, NSInteger *status, NSError **err) {
    __block NSData *out = nil;
    __block NSError *error = nil;
    __block NSInteger code = 0;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[s dataTaskWithURL:url completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        out = d;
        code = [(NSHTTPURLResponse *)r statusCode];
        error = e;
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    *status = code;
    if (err) *err = error;
    return out;
}

/* Returns nil on success, else a message for the player. */
- (NSString *)runFrom:(NSURL *)base {
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.defaultSessionConfiguration;
    config.timeoutIntervalForRequest = 30;
    config.HTTPMaximumConnectionsPerHost = 4;
    config.connectionProxyDictionary = @{};
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    NSFileManager *fm = NSFileManager.defaultManager;

    NSInteger code = 0;
    NSError *err = nil;
    NSURL *manifestURL = [[base URLByAppendingPathComponent:@"api/manifest"] URLByAppendingPathComponent:_app];
    NSData *data = fetchData(session, manifestURL, &code, &err);
    if (!data || code != 200)
        return err ? [NSString stringWithFormat:@"PC에 연결하지 못했습니다: %@", err.localizedDescription]
                   : [NSString stringWithFormat:@"PC가 %ld 오류를 보냈습니다 (목록).", (long)code];
    NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSArray<NSDictionary *> *files = manifest[@"files"];
    long long total = [manifest[@"total"] longLongValue];

    /* Until every file is here main() must not start the game (see
     * mkxp_ios_importIncomplete); removed only after a complete download. */
    [fm createDirectoryAtPath:_dest withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *marker = [_dest stringByAppendingPathComponent:@".pcimport-incomplete"];
    [fm createFileAtPath:marker contents:nil attributes:nil];

    NSMutableArray<NSDictionary *> *todo = [NSMutableArray array];
    long long have = 0;
    for (NSDictionary *f in files) {
        NSString *path = [_dest stringByAppendingPathComponent:f[@"p"]];
        long long want = [f[@"s"] longLongValue];
        NSNumber *size = [fm attributesOfItemAtPath:path error:nil][NSFileSize];
        if (size && size.longLongValue == want) have += want;
        else [todo addObject:f];
    }

    __block long long done = have;
    __block NSString *failure = nil;
    NSObject *lock = [[NSObject alloc] init];
    NSOperationQueue *queue = [[NSOperationQueue alloc] init];
    queue.maxConcurrentOperationCount = 4;

    void (^report)(void) = ^{
        long long d;
        @synchronized (lock) { d = done; }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_bar.progress = total > 0 ? (float)((double)d / (double)total) : 0;
            self->_status.text = [NSString stringWithFormat:@"받는 중 %.2f / %.2f GB", d / 1e9, total / 1e9];
        });
    };
    report();

    for (NSDictionary *f in todo) {
        [queue addOperationWithBlock:^{
            @synchronized (lock) { if (failure) return; }
            NSString *rel = f[@"p"];
            NSURL *url = [[base URLByAppendingPathComponent:@"api/file"] URLByAppendingPathComponent:self->_app];
            for (NSString *part in [rel componentsSeparatedByString:@"/"])
                url = [url URLByAppendingPathComponent:part];
            NSString *target = [self->_dest stringByAppendingPathComponent:rel];

            __block NSString *problem = nil;
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            [[session downloadTaskWithURL:url completionHandler:^(NSURL *tmp, NSURLResponse *r, NSError *e) {
                NSInteger status = [(NSHTTPURLResponse *)r statusCode];
                if (e || status != 200) {
                    problem = e ? e.localizedDescription : [NSString stringWithFormat:@"%ld (%@)", (long)status, rel];
                } else {
                    /* The temp file is gone once this handler returns: move it now. */
                    [fm createDirectoryAtPath:target.stringByDeletingLastPathComponent
                  withIntermediateDirectories:YES attributes:nil error:nil];
                    [fm removeItemAtPath:target error:nil];
                    NSError *moveErr = nil;
                    if (![fm moveItemAtURL:tmp toURL:[NSURL fileURLWithPath:target] error:&moveErr])
                        problem = moveErr.localizedDescription;
                }
                dispatch_semaphore_signal(sem);
            }] resume];
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

            @synchronized (lock) {
                if (problem) { if (!failure) failure = problem; return; }
                done += [f[@"s"] longLongValue];
            }
            report();
        }];
    }
    [queue waitUntilAllOperationsAreFinished];
    [session finishTasksAndInvalidate];
    if (failure)
        return [@"받다가 실패했습니다: " stringByAppendingString:failure];
    [fm removeItemAtPath:marker error:nil];
    return nil;
}
@end

/* True while a "PC에서 받기" hasn't finished: main() then shows the importer
 * (which resumes) instead of starting a half-copied game. */
extern "C" int mkxp_ios_importIncomplete(void) {
    @autoreleasepool {
        NSString *marker = [@(mkxp_ios_gameImportDir()) stringByAppendingPathComponent:@".pcimport-incomplete"];
        return [NSFileManager.defaultManager fileExistsAtPath:marker] ? 1 : 0;
    }
}

/* Blocks until the player has fetched the game (returns 1). main() calls this
 * before the SDL window exists; it may run on the UIKit main thread or not. */
static int runImporter(NSString *autoAddress) {
    __block BOOL finished = NO;
    __block MKXPImporter *importer = nil;
    void (^present)(void) = ^{
        importer = [[MKXPImporter alloc] init];
        importer.finished = ^(BOOL ok) { finished = YES; };
        importer.autoAddress = autoAddress;
        [importer show];
    };
    if (NSThread.isMainThread) {
        present();
        while (!finished)
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
        [importer hide];
    } else {
        dispatch_sync(dispatch_get_main_queue(), present);
        while (!finished)
            usleep(50 * 1000);
        dispatch_sync(dispatch_get_main_queue(), ^{ [importer hide]; });
    }
    return 1;
}

/* Blocks until the player has fetched the game (returns 1). main() calls this
 * before the SDL window exists; it may run on the UIKit main thread or not. */
extern "C" int mkxp_ios_importGame(void) {
    return runImporter(nil);
}

/* "업데이트 받기" (README section 9): with the game already here, ask only the
 * last PC that answered (or the usual address) for its list, for at most 1.5 s.
 * New files or files of another size there (a patch added on the PC later) are
 * offered; "받기" fetches just those (the importer skips files of the same size
 * and keeps the marker until all are in), "건너뛰고 게임 시작" starts the game
 * as it is. */
extern "C" void mkxp_ios_offerUpdate(void) {
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *dest = @(mkxp_ios_gameImportDir());
        /* Only a game laid out as the PC sends it (not one unzipped a folder deeper). */
        if (![fm fileExistsAtPath:[dest stringByAppendingPathComponent:@"Game.ini"]])
            return;
        NSString *app = NSBundle.mainBundle.infoDictionary[@"PortDataFolder"] ?: @"Game";
        NSString *address = [NSUserDefaults.standardUserDefaults stringForKey:kImportAddressKey];
        if (!address.length)
            address = @"192.168.0.2:8765";
        NSURL *base = addressURL(address);
        if (!base)
            return;

        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.timeoutIntervalForRequest = 1.5;
        config.connectionProxyDictionary = @{};
        NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
        NSInteger code = 0;
        NSData *data = fetchData(session, [[base URLByAppendingPathComponent:@"api/manifest"]
                                              URLByAppendingPathComponent:app], &code, NULL);
        [session finishTasksAndInvalidate];
        id manifest = (code == 200 && data) ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![manifest isKindOfClass:NSDictionary.class]) {
            portLog(@"update check: no PC at %@", address);
            return;
        }
        id files = manifest[@"files"];
        if (![files isKindOfClass:NSArray.class])
            return;
        NSUInteger count = 0;
        long long bytes = 0;
        for (NSDictionary *f in files) {
            if (![f isKindOfClass:NSDictionary.class] || ![f[@"p"] isKindOfClass:NSString.class])
                continue;
            long long want = [f[@"s"] longLongValue];
            NSNumber *size = [fm attributesOfItemAtPath:[dest stringByAppendingPathComponent:f[@"p"]] error:nil][NSFileSize];
            if (!size || size.longLongValue != want) {
                count++;
                bytes += want;
            }
        }
        if (!count) {
            portLog(@"update check: up to date (%@)", address);
            return;
        }
        portLog(@"update check: %lu new or changed files on %@", (unsigned long)count, address);

        __block BOOL fetch = NO;
        runBlockingWindow(@"", ^(UIViewController *vc, PortFinish finish) {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"PC에 새 게임 파일이 있습니다"
                message:[NSString stringWithFormat:@"새 파일이나 바뀐 파일 %lu개 (%.1f MB). 지금 받을까요?",
                                                   (unsigned long)count, bytes / 1e6]
                preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"받기" style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *x) { fetch = YES; finish(); }]];
            [a addAction:[UIAlertAction actionWithTitle:@"건너뛰고 게임 시작" style:UIAlertActionStyleCancel
                                                handler:^(UIAlertAction *x) { finish(); }]];
            /* Once the window is on screen. */
            dispatch_async(dispatch_get_main_queue(), ^{ [vc presentViewController:a animated:YES completion:nil]; });
        });
        if (fetch)
            runImporter(address);
        else
            portLog(@"update declined");
    }
}

#endif

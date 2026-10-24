/*
 ** TouchControls.mm
 **
 ** iOS-only. A UIKit overlay (D-pad, A/B/menu/special face buttons, L/R and a
 ** battle speed-up button) drawn on top of SDL's GL view. Each control writes
 ** directly into EventThread::keyStates[] — the same array Input snapshots every
 ** frame — so the existing keyboard bindings are fully reused:
 **   A = C (use), B = X (back), menu = Z (action), special = D,
 **   L = A (jump up), R = S (jump down), speed-up = Q.
 **
 ** Buttons are labelled by what they do in the game (A/B like a Game Boy, icons
 ** for the rest, a small caption under each) rather than by keyboard key, and are
 ** laid out inside the black bars beside the 4:3 game picture when there's room.
 */

#include <TargetConditionals.h>

#if TARGET_OS_IPHONE

#import <UIKit/UIKit.h>
#import <SDL.h>
#import <SDL_syswm.h>
#import <SDL_scancode.h>

#include "eventthread.h"

static void pressKey(int sc, bool down) {
    EventThread::keyStates[sc] = down;
    /* A tap can go down and up between two game frames; latch it so Input sees it. */
    if (down)
        EventThread::keyStatesLatch[sc] = true;
}

static UIColor *fillColor(CGFloat alpha) { return [UIColor colorWithWhite:0.08 alpha:alpha]; }
static UIColor *strokeColor() { return [UIColor colorWithWhite:1.0 alpha:0.32]; }
static UIColor *glyphColor() { return [UIColor colorWithWhite:1.0 alpha:0.92]; }

/* ------------------------------------------------------------------------- */

/* Overlay that only intercepts touches that land on a control; everything else
 * falls through to SDL's GL view underneath. */
@interface MKXPTouchOverlay : UIView
@end

/* ------------------------------------------------------------------------- */

/* A round (or capsule) button with a glyph and a small caption underneath. */
@interface MKXPPadButton : UIView
- (instancetype)initWithScancode:(int)sc glyph:(NSString *)glyph symbol:(NSString *)symbol
                         caption:(NSString *)caption tint:(UIColor *)tint;
@property (nonatomic) BOOL capsule;
@end

@implementation MKXPPadButton {
    int _scancode;
    BOOL _down;
    UIColor *_tint;
    UIView *_face;
    UILabel *_glyph;
    UIImageView *_symbol;
    UILabel *_caption;
    UIImpactFeedbackGenerator *_haptic;
}

- (instancetype)initWithScancode:(int)sc glyph:(NSString *)glyph symbol:(NSString *)symbol
                         caption:(NSString *)caption tint:(UIColor *)tint {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _scancode = sc;
    _tint = tint;
    self.multipleTouchEnabled = YES;

    _face = [[UIView alloc] init];
    _face.userInteractionEnabled = NO;
    _face.layer.borderWidth = 1.5;
    _face.layer.borderColor = strokeColor().CGColor;
    [self addSubview:_face];

    if (symbol) {
        _symbol = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
        _symbol.tintColor = glyphColor();
        _symbol.contentMode = UIViewContentModeScaleAspectFit;
        [_face addSubview:_symbol];
    } else {
        _glyph = [[UILabel alloc] init];
        _glyph.text = glyph;
        _glyph.textColor = glyphColor();
        _glyph.textAlignment = NSTextAlignmentCenter;
        [_face addSubview:_glyph];
    }

    if (caption) {
        _caption = [[UILabel alloc] init];
        _caption.text = caption;
        _caption.textColor = [UIColor colorWithWhite:1.0 alpha:0.75];
        _caption.textAlignment = NSTextAlignmentCenter;
        [_face addSubview:_caption];
    }

    _haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [self refresh];
    return self;
}

/* Glyph centred on the face, or raised with the caption tucked under it. */
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat w = b.size.width, h = b.size.height, s = MIN(w, h);
    /* bounds + center rather than frame: the face carries a scale transform. */
    _face.bounds = b;
    _face.center = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
    _face.layer.cornerRadius = self.capsule ? h / 2 : s / 2;
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

- (void)refresh {
    UIColor *base = _tint ?: fillColor(0.42);
    _face.backgroundColor = _down ? [UIColor colorWithWhite:1.0 alpha:0.38] : base;
    _face.transform = _down ? CGAffineTransformMakeScale(0.9, 0.9) : CGAffineTransformIdentity;
}

- (void)setDown:(BOOL)down {
    if (down == _down) return;
    _down = down;
    pressKey(_scancode, down);
    if (down) [_haptic impactOccurred];
    [UIView animateWithDuration:0.06 animations:^{ [self refresh]; }];
}

- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self setDown:YES]; }
- (void)touchesMoved:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    /* Slide off to release, like a real button; generous slop for thumbs. */
    CGPoint p = [t.anyObject locationInView:self];
    [self setDown:CGRectContainsPoint(CGRectInset(self.bounds, -16, -16), p)];
}
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self setDown:NO]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self setDown:NO]; }
@end

/* ------------------------------------------------------------------------- */

/* A plus-shaped D-pad. Tracks one finger and picks the dominant axis from its
 * position, so you can slide between directions without lifting. */
@interface MKXPDPad : UIView
@end

@implementation MKXPDPad {
    int _active;   // currently-held SDL scancode, or 0
    CAShapeLayer *_cross;
    CAShapeLayer *_highlight;
    NSArray<UIImageView *> *_arrows;   // up, down, left, right
    UIImpactFeedbackGenerator *_haptic;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _cross = [CAShapeLayer layer];
    _cross.fillColor = fillColor(0.42).CGColor;
    _cross.strokeColor = strokeColor().CGColor;
    _cross.lineWidth = 1.5;
    [self.layer addSublayer:_cross];

    _highlight = [CAShapeLayer layer];
    _highlight.fillColor = [UIColor colorWithWhite:1.0 alpha:0.32].CGColor;
    [self.layer addSublayer:_highlight];

    NSMutableArray *arrows = [NSMutableArray array];
    for (NSString *name in @[@"arrowtriangle.up.fill", @"arrowtriangle.down.fill",
                             @"arrowtriangle.left.fill", @"arrowtriangle.right.fill"]) {
        UIImageView *v = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:name]];
        v.tintColor = [UIColor colorWithWhite:1.0 alpha:0.75];
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
    CGFloat s = MIN(self.bounds.size.width, self.bounds.size.height), w = s / 3, r = w * 0.28;
    UIBezierPath *cross = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(w, 0, w, s) cornerRadius:r];
    [cross appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, w, s, w) cornerRadius:r]];
    _cross.path = cross.CGPath;
    _cross.fillRule = kCAFillRuleNonZero;
    _cross.frame = self.bounds;
    _highlight.frame = self.bounds;
    CGFloat g = w * 0.38;
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
        : [UIBezierPath bezierPathWithRoundedRect:CGRectInset([self armRect:dir], 2, 2)
                                     cornerRadius:w * 0.24].CGPath;
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

- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self track:t.anyObject]; }
- (void)touchesMoved:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self track:t.anyObject]; }
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self hold:0]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self hold:0]; }
@end

/* ------------------------------------------------------------------------- */

@implementation MKXPTouchOverlay {
    MKXPDPad *_dpad;
    MKXPPadButton *_a, *_b, *_menu, *_special, *_l, *_r, *_speed;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.multipleTouchEnabled = YES;

    UIColor *red = [UIColor colorWithRed:0.86 green:0.19 blue:0.20 alpha:0.62];
    UIColor *slate = [UIColor colorWithRed:0.25 green:0.33 blue:0.62 alpha:0.6];

    _dpad = [[MKXPDPad alloc] initWithFrame:CGRectZero];
    _a = [[MKXPPadButton alloc] initWithScancode:SDL_SCANCODE_C glyph:@"A" symbol:nil caption:@"결정" tint:red];
    _b = [[MKXPPadButton alloc] initWithScancode:SDL_SCANCODE_X glyph:@"B" symbol:nil caption:@"취소" tint:slate];
    _menu = [[MKXPPadButton alloc] initWithScancode:SDL_SCANCODE_Z glyph:nil
                                             symbol:@"line.horizontal.3" caption:@"메뉴" tint:nil];
    _special = [[MKXPPadButton alloc] initWithScancode:SDL_SCANCODE_D glyph:nil
                                                symbol:@"star.fill" caption:@"등록" tint:nil];
    _l = [[MKXPPadButton alloc] initWithScancode:SDL_SCANCODE_A glyph:@"L" symbol:nil caption:nil tint:nil];
    _r = [[MKXPPadButton alloc] initWithScancode:SDL_SCANCODE_S glyph:@"R" symbol:nil caption:nil tint:nil];
    _speed = [[MKXPPadButton alloc] initWithScancode:SDL_SCANCODE_Q glyph:nil
                                              symbol:@"forward.fill" caption:@"배속" tint:nil];
    _l.capsule = _r.capsule = YES;

    for (UIView *v in @[_dpad, _a, _b, _menu, _special, _l, _r, _speed])
        [self addSubview:v];
    return self;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
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
    CGFloat lcx = safe.left + MAX(leftW / 2, 70), rcx = W - safe.right - MAX(rightW / 2, 76);

    /* D-pad: bottom-left. */
    CGFloat pad = MIN(MAX(avail * 0.92, 120), MIN(H * 0.44, 180));
    CGFloat bottomY = H - MAX(safe.bottom, m) - 6;
    _dpad.frame = CGRectMake(lcx - pad / 2, bottomY - pad, pad, pad);

    /* Face buttons: a diamond at the bottom-right, A on the right like a Game Boy
     * (A right, B bottom, menu top, special left), bottom-aligned with the D-pad. */
    CGFloat d = MIN(MAX(pad * 0.36, 46), 62);
    CGFloat off = d * 0.98;
    CGFloat cy = bottomY - off - d / 2;
    _a.frame = CGRectMake(rcx + off - d / 2, cy - d / 2, d, d);
    _b.frame = CGRectMake(rcx - d / 2, cy + off - d / 2, d, d);
    _menu.frame = CGRectMake(rcx - d / 2, cy - off - d / 2, d, d);
    _special.frame = CGRectMake(rcx - off - d / 2, cy - d / 2, d, d);

    /* Shoulders along the top, speed-up under R. */
    CGFloat sw = MIN(MAX(avail * 0.8, 72), 120), sh = 34;
    CGFloat top = MAX(safe.top, m);
    _l.frame = CGRectMake(lcx - sw / 2, top, sw, sh);
    _r.frame = CGRectMake(rcx - sw / 2, top, sw, sh);
    CGFloat s = d * 0.86;
    _speed.frame = CGRectMake(rcx - s / 2, top + sh + 10, s, s);
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
        }
    });
}

#endif

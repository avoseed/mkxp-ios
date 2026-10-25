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
#include <ifaddrs.h>
#include <netinet/in.h>

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
@interface MKXPTouchOverlay : UIView
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
    UISwitch *_powerSave;
    UILabel *_hint;
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
    [_gear addTarget:self action:@selector(startEditing) forControlEvents:UIControlEventTouchUpInside];
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

    UILabel *powerLabel = [[UILabel alloc] init];
    powerLabel.text = @"절전 모드 (40fps)";
    powerLabel.textColor = UIColor.whiteColor;
    powerLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    _powerSave = [[UISwitch alloc] init];
    _powerSave.on = mkxp_ios_targetFrameRate() == 40;
    [_powerSave addTarget:self action:@selector(powerSaveChanged:) forControlEvents:UIControlEventValueChanged];

    UIStackView *top = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self toolButton:@"크기 −" action:@selector(shrink)],
        [self toolButton:@"크기 +" action:@selector(grow)],
        alphaLabel, _alphaSlider,
    ]];
    UIStackView *bottom = [[UIStackView alloc] initWithArrangedSubviews:@[
        powerLabel, _powerSave,
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
- (void)show;
- (void)hide;
@end

@implementation MKXPImporter {
    UIWindow *_window;
    UITextField *_field;
    UIButton *_button;
    UIProgressView *_bar;
    UILabel *_status;
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

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[label, _field, _button, _bar, _status]];
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
    NSString *typed = [_field.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:kImportAddressKey] ?: @"";
    [_field resignFirstResponder];
    _button.enabled = NO;
    _bar.hidden = NO;
    _status.text = @"같은 와이파이에서 PC를 찾는 중…";
    UIApplication.sharedApplication.idleTimerDisabled = YES;   // don't sleep mid-transfer
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *address = [self discoverPreferring:@[typed, saved]];
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
    return failure ? [@"받다가 실패했습니다: " stringByAppendingString:failure] : nil;
}
@end

/* Blocks until the player has fetched the game (returns 1). main() calls this
 * before the SDL window exists; it may run on the UIKit main thread or not. */
extern "C" int mkxp_ios_importGame(void) {
    __block BOOL finished = NO;
    __block MKXPImporter *importer = nil;
    void (^present)(void) = ^{
        importer = [[MKXPImporter alloc] init];
        importer.finished = ^(BOOL ok) { finished = YES; };
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

#endif

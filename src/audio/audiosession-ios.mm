/*
 ** audiosession-ios.mm
 **
 ** iOS-only. Configures an AVAudioSession before OpenAL (OpenAL-soft on iOS
 ** routes through CoreAudio, which needs an active audio session). Must be
 ** called before alcOpenDevice().
 **
 ** Playback, so the game is heard with the ring/silent switch on. "다른 앱 소리와
 ** 함께" (settings, on by default) adds MixWithOthers: music from another app
 ** keeps playing, and while it does the game's BGM steps aside (audio.cpp reads
 ** mkxp_ios_musicMuted) while its sound effects stay. E:\ios-ports\README.md
 ** section 10. SDL's audio subsystem is never initialised (main.cpp), so SDL
 ** doesn't set the category; main() applies it again after alcOpenDevice anyway
 ** and the log shows what the session ended up with.
 */

#include <TargetConditionals.h>

#if TARGET_OS_IPHONE

#import <AVFoundation/AVFoundation.h>

#include <atomic>
#include <stdarg.h>
#include <stdio.h>

/* To stderr, which TouchControls.mm sends to the app's log file (mkxp.log). */
static void alog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void alog(NSString *format, ...) {
    va_list ap;
    va_start(ap, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    fprintf(stderr, "mkxp-z: %s\n", line.UTF8String);
}

static NSString *const kMixAudioKey = @"mixOtherAudio";
static std::atomic<int> g_musicMuted{0};

/* Read by the BGM watch thread (audio.cpp) every few milliseconds. */
extern "C" int mkxp_ios_musicMuted(void) { return g_musicMuted.load(); }

extern "C" int mkxp_ios_mixOtherAudio(void) {
    [NSUserDefaults.standardUserDefaults registerDefaults:@{ kMixAudioKey: @YES }];
    return [NSUserDefaults.standardUserDefaults boolForKey:kMixAudioKey] ? 1 : 0;
}

static void refreshMusicMute(void) {
    BOOL other = mkxp_ios_mixOtherAudio() && AVAudioSession.sharedInstance.secondaryAudioShouldBeSilencedHint;
    g_musicMuted.store(other ? 1 : 0);
}

/* (Re)applies the category and options; logs what the session ended up with. */
extern "C" void mkxp_ios_applyAudioMix(const char *when) {
    @autoreleasepool {
        AVAudioSession *session = AVAudioSession.sharedInstance;
        BOOL mix = mkxp_ios_mixOtherAudio();
        NSError *err = nil;
        if (![session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault
                          options:mix ? AVAudioSessionCategoryOptionMixWithOthers : 0 error:&err])
            alog(@"AVAudioSession setCategory failed: %@", err);
        err = nil;
        if (![session setActive:YES error:&err])
            alog(@"AVAudioSession setActive failed: %@", err);
        refreshMusicMute();
        alog(@"audio (%s): category %@, options %lu, mixed with other apps %d, another app playing %d",
              when ? when : "", session.category, (unsigned long)session.categoryOptions, (int)mix,
              (int)session.secondaryAudioShouldBeSilencedHint);
    }
}

extern "C" void mkxp_ios_setMixOtherAudio(int on) {
    [NSUserDefaults.standardUserDefaults setBool:on ? YES : NO forKey:kMixAudioKey];
    mkxp_ios_applyAudioMix("setting changed");
}

extern "C" void mkxp_ios_initAudioSession(void) {
    mkxp_ios_applyAudioMix("start");

    static BOOL observing;
    if (observing) return;
    observing = YES;
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:AVAudioSessionSilenceSecondaryAudioHintNotification object:nil
                     queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        refreshMusicMute();
        alog(@"audio: another app playing %d", g_musicMuted.load());
    }];
    /* After a call or Siri the session has to be made active again. */
    [nc addObserverForName:AVAudioSessionInterruptionNotification object:nil
                     queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        NSUInteger type = [n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
        if (type == AVAudioSessionInterruptionTypeEnded)
            mkxp_ios_applyAudioMix("interruption ended");
    }];
}

#endif

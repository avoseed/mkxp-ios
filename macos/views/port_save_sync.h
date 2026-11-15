// Save sync between devices for a sideloaded port app (no iCloud entitlement): a folder picked once in the Files
// app (iCloud Drive or any provider) and / or the PC transfer server. See port_save_sync.m.
#import <Foundation/Foundation.h>

// (mkxp-ios: C linkage when included from Objective-C++, e.g. TouchControls.mm; otherwise as in wog3-ios.)
#ifdef __cplusplus
extern "C" {
#endif

// key: the app's PortDataFolder (the name on the server and in the folder); root: the data root; dirs: the
// folders under it that hold saves (e.g. @[ @"save" ]); skip: file extensions that are not saves (logs, dumps),
// and entries with a slash: folders under the root left out (e.g. @"save/Chps/", a game's scratch files).
void port_sync_configure(NSString *key, NSString *root, NSArray<NSString *> *dirs, NSArray<NSString *> *skip);

BOOL port_sync_set_folder(NSURL *url);            // nil: forget it
NSString *port_sync_folder_name(void);            // nil: none picked
BOOL port_sync_pc(void);
void port_sync_set_pc(BOOL on);
BOOL port_sync_configured(void);

// One run, off the main thread; done on the main thread.
//   resolve     where a save changed on both sides: > 0 this device's is kept, < 0 the other's, 0 neither (conflict)
//   uploadOnly  nothing is written here (the game is running)
// summary: one line for the player; conflict: some save changed on both sides and was left alone;
// changedLocal: saves here were replaced (their old versions are under <root>/save-backup/<time>).
typedef void (^PortSyncDone)(NSString *summary, BOOL conflict, BOOL changedLocal);
void port_sync_run(int resolve, BOOL uploadOnly, PortSyncDone done);
// Before the game starts: the same, but the PC is asked only at the last address that answered, for 1.5 s; no
// answer (away from home) skips the PC and the summary says "PC 세이브는 확인 못 함" (README section 4).
void port_sync_run_start(int resolve, PortSyncDone done);

#ifdef __cplusplus
}
#endif

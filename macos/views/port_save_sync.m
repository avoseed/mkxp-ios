// Save sync between devices, without any iCloud entitlement (the app is sideloaded). The same layout and server
// routes as the other port apps (E:\ios-ports\README.md, section 4):
//   folder  a folder the player picked once in the Files app (iCloud Drive, or any provider there); kept as a
//           bookmark, read and written through file coordination so undownloaded files are fetched.
//           <folder>/<key>/<path> and <folder>/<key>/manifest.json { "files": { path: { hash, size, mtime, device } } }
//   pc      the transfer server: GET /api/sync/<key>/manifest, GET / POST /api/sync/<key>/file/<path>
//           (it keeps them under saves\<key>; saves put there by hand from the PC game come down the same way)
// A path is the save file's path from the data root. Per file: what changed only here goes up, what changed only
// there comes down (the replaced file is kept under save-backup), and when both changed the caller is told
// (conflict) and decides which side wins. "Changed" is against the hash at the last sync with that remote
// (<root>/sync-state-<remote>.json); a file never synced counts as changed.
#import <UIKit/UIKit.h>
#include <CommonCrypto/CommonDigest.h>
#import "port_save_sync.h"

static NSString *const kFolderKey = @"sync.folder", *const kPCKey = @"sync.pc", *const kAddressKey = @"wifiImportAddress";
static NSString *g_key, *g_root;
static NSArray<NSString *> *g_dirs, *g_skip;

void port_sync_configure(NSString *key, NSString *root, NSArray<NSString *> *dirs, NSArray<NSString *> *skip) {
    g_key = [key copy]; g_root = [root copy]; g_dirs = [dirs copy]; g_skip = [skip copy];
}

static NSString *sha256_hex(NSData *d) {
    unsigned char h[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(d.bytes, (CC_LONG)d.length, h);
    NSMutableString *s = [NSMutableString stringWithCapacity:64];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [s appendFormat:@"%02x", h[i]];
    return s;
}

static NSDictionary *json_dict(NSData *d) {
    id o = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    return [o isKindOfClass:NSDictionary.class] ? o : nil;
}

// the save files here: path from the data root -> modification time
static NSDictionary<NSString *, NSNumber *> *local_files(void) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *dir in g_dirs) {
        NSString *base = [g_root stringByAppendingPathComponent:dir];
        for (NSString *rel in [fm enumeratorAtPath:base]) {
            NSString *path = [base stringByAppendingPathComponent:rel];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:path isDirectory:&isDir] || isDir) continue;
            BOOL hidden = NO;
            for (NSString *part in rel.pathComponents) if ([part hasPrefix:@"."]) hidden = YES;
            if (hidden || [g_skip containsObject:rel.pathExtension.lowercaseString]) continue;
            NSString *full = [dir stringByAppendingPathComponent:rel];
            BOOL under = NO;                         // a skip entry with a slash: a folder (from the data root) left out
            for (NSString *k in g_skip)
                if ([k containsString:@"/"] && [full.lowercaseString hasPrefix:k.lowercaseString]) under = YES;
            if (under) continue;
            NSDate *m = [fm attributesOfItemAtPath:path error:nil][NSFileModificationDate];
            out[[dir stringByAppendingPathComponent:rel]] = @(m.timeIntervalSince1970);
        }
    }
    return out;
}

// ---------------------------------------------------------------- the two remotes

@protocol PortSyncRemote
- (NSString *)name;                                                   // names its state file
- (NSDictionary *)files;                                              // path -> { hash, size, mtime }; nil: not reachable
- (NSData *)read:(NSString *)rel;
- (BOOL)write:(NSString *)rel data:(NSData *)data mtime:(double)mtime;
@end

// -- a folder from the Files app
@interface PortSyncFolder : NSObject <PortSyncRemote>
@property(nonatomic) NSURL *base;
@end
@implementation PortSyncFolder
- (NSString *)name { return @"folder"; }
- (NSURL *)url:(NSString *)rel { return [[_base URLByAppendingPathComponent:g_key isDirectory:YES] URLByAppendingPathComponent:rel]; }
- (NSData *)coordinatedRead:(NSURL *)url {
    __block NSData *d = nil;
    NSError *err = nil;
    [[NSFileCoordinator new] coordinateReadingItemAtURL:url options:0 error:&err byAccessor:^(NSURL *u) {
        d = [NSData dataWithContentsOfURL:u];
    }];
    return d;
}
- (BOOL)coordinatedWrite:(NSURL *)url data:(NSData *)data {
    [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    __block BOOL ok = NO;
    NSError *err = nil;
    [[NSFileCoordinator new] coordinateWritingItemAtURL:url options:NSFileCoordinatorWritingForReplacing error:&err byAccessor:^(NSURL *u) {
        ok = [data writeToURL:u atomically:YES];
    }];
    return ok;
}
- (NSDictionary *)files {
    BOOL isDir = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:_base.path isDirectory:&isDir] || !isDir) return nil;
    NSDictionary *files = json_dict([self coordinatedRead:[self url:@"manifest.json"]])[@"files"];
    return [files isKindOfClass:NSDictionary.class] ? files : @{};
}
- (NSData *)read:(NSString *)rel { return [self coordinatedRead:[self url:rel]]; }
- (BOOL)write:(NSString *)rel data:(NSData *)data mtime:(double)mtime {
    if (![self coordinatedWrite:[self url:rel] data:data]) return NO;
    NSMutableDictionary *files = [([self files] ?: @{}) mutableCopy];           // the list is ours to keep
    files[rel] = @{ @"hash" : sha256_hex(data), @"size" : @(data.length), @"mtime" : @(mtime),
                    @"device" : UIDevice.currentDevice.name ?: @"" };
    NSData *m = [NSJSONSerialization dataWithJSONObject:@{ @"files" : files } options:NSJSONWritingPrettyPrinted error:nil];
    return m && [self coordinatedWrite:[self url:@"manifest.json"] data:m];
}
@end

// -- the transfer server on the PC
@interface PortSyncPC : NSObject <PortSyncRemote>
@property(nonatomic, copy) NSString *host;                            // "address:port" that answered
@property(nonatomic) BOOL quick;                                      // before the game starts: one address, 1.5 s
@end
@implementation PortSyncPC
- (NSString *)name { return @"pc"; }
+ (NSData *)request:(NSString *)method url:(NSURL *)url body:(NSData *)body mtime:(double)mtime timeout:(double)timeout {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{                                           // not through a VPN / proxy app
        NSURLSessionConfiguration *c = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        c.connectionProxyDictionary = @{};
        session = [NSURLSession sessionWithConfiguration:c];
    });
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:timeout];
    req.HTTPMethod = method;
    if (body) {
        req.HTTPBody = body;
        [req setValue:@"application/octet-stream" forHTTPHeaderField:@"Content-Type"];
        [req setValue:[NSString stringWithFormat:@"%.3f", mtime] forHTTPHeaderField:@"X-Mtime"];
    }
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSData *out = nil;
    __block NSInteger status = 0;
    [[session dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (!e && [r isKindOfClass:NSHTTPURLResponse.class]) { status = ((NSHTTPURLResponse *)r).statusCode; out = d; }
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout + (timeout < 2 ? 0.1 : 2)) * NSEC_PER_SEC)));
    return status == 200 ? out : nil;
}
- (NSURL *)url:(NSString *)path {
    NSString *enc = [path stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    return [NSURL URLWithString:[NSString stringWithFormat:@"http://%@/api/sync/%@/%@", _host, g_key, enc]];
}
// the address the game was received from, then the usual ones (README section 9), 1.5 s each. Before the game
// starts (quick) only the last address that answered (or the usual first one) is asked: away from home the
// start is not held up (README section 4).
- (NSData *)manifest {
    if (_host) return [PortSyncPC request:@"GET" url:[self url:@"manifest"] body:nil mtime:0 timeout:6];
    NSMutableArray<NSString *> *hosts = [NSMutableArray array];
    for (NSString *a in @[ [NSUserDefaults.standardUserDefaults stringForKey:kAddressKey] ?: @"", @"192.168.0.2:8765", @"100.99.113.123:8765" ]) {
        NSString *h = [a stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([h hasPrefix:@"http://"]) h = [h substringFromIndex:7];
        while ([h hasSuffix:@"/"]) h = [h substringToIndex:h.length - 1];
        if (h.length && ![h containsString:@":"]) h = [h stringByAppendingString:@":8765"];
        if (h.length && ![hosts containsObject:h]) [hosts addObject:h];
    }
    if (_quick && hosts.count > 1) [hosts removeObjectsInRange:NSMakeRange(1, hosts.count - 1)];
    for (NSString *h in hosts) {
        _host = h;
        NSData *d = [PortSyncPC request:@"GET" url:[self url:@"manifest"] body:nil mtime:0 timeout:1.5];
        if (d) return d;
    }
    _host = nil;
    return nil;
}
- (NSDictionary *)files {
    NSDictionary *files = json_dict([self manifest])[@"files"];
    return [files isKindOfClass:NSDictionary.class] ? files : nil;
}
- (NSData *)read:(NSString *)rel {
    return [PortSyncPC request:@"GET" url:[self url:[@"file/" stringByAppendingString:rel]] body:nil mtime:0 timeout:20];
}
- (BOOL)write:(NSString *)rel data:(NSData *)data mtime:(double)mtime {
    return [PortSyncPC request:@"POST" url:[self url:[@"file/" stringByAppendingString:rel]] body:data mtime:mtime timeout:20] != nil;
}
@end

// ---------------------------------------------------------------- settings

static NSURL *folder_url(void) {
    NSData *mark = [NSUserDefaults.standardUserDefaults dataForKey:kFolderKey];
    if (!mark) return nil;
    BOOL stale = NO;
    return [NSURL URLByResolvingBookmarkData:mark options:0 relativeToURL:nil bookmarkDataIsStale:&stale error:nil];
}

BOOL port_sync_set_folder(NSURL *url) {
    if (!url) { [NSUserDefaults.standardUserDefaults removeObjectForKey:kFolderKey]; return YES; }
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSData *mark = [url bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:nil];
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!mark) return NO;
    [NSUserDefaults.standardUserDefaults setObject:mark forKey:kFolderKey];
    return YES;
}
NSString *port_sync_folder_name(void) { return folder_url().lastPathComponent; }
BOOL port_sync_pc(void) { return [NSUserDefaults.standardUserDefaults boolForKey:kPCKey]; }
void port_sync_set_pc(BOOL on) { [NSUserDefaults.standardUserDefaults setBool:on forKey:kPCKey]; }
BOOL port_sync_configured(void) { return port_sync_pc() || [NSUserDefaults.standardUserDefaults dataForKey:kFolderKey] != nil; }

// ---------------------------------------------------------------- one remote

typedef struct { int up, down, failed, conflict, waiting; BOOL unreachable; } Tally;

static void sync_remote(id<PortSyncRemote> remote, int resolve, BOOL uploadOnly, NSString *backup, Tally *t) {
    NSDictionary *theirs = [remote files];
    if (!theirs) { t->unreachable = YES; return; }
    NSDictionary<NSString *, NSNumber *> *mine = local_files();
    NSString *statePath = [g_root stringByAppendingPathComponent:[NSString stringWithFormat:@"sync-state-%@.json", remote.name]];
    NSMutableDictionary *state = [(json_dict([NSData dataWithContentsOfFile:statePath]) ?: @{}) mutableCopy];   // path -> hash at the last sync
    NSMutableSet<NSString *> *all = [NSMutableSet setWithArray:mine.allKeys];
    [all addObjectsFromArray:theirs.allKeys];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *rel in [all.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
        NSDictionary *r = [theirs[rel] isKindOfClass:NSDictionary.class] ? theirs[rel] : nil;
        NSString *rh = [r[@"hash"] isKindOfClass:NSString.class] ? r[@"hash"] : nil;
        NSString *path = [g_root stringByAppendingPathComponent:rel];
        NSData *ld = mine[rel] ? [NSData dataWithContentsOfFile:path] : nil;
        NSString *lh = ld ? sha256_hex(ld) : nil, *sh = [state[rel] isKindOfClass:NSString.class] ? state[rel] : nil;
        if (!lh && !rh) continue;
        if (lh && rh && [lh isEqualToString:rh]) { state[rel] = lh; continue; }
        BOOL here = lh && !(sh && [lh isEqualToString:sh]);
        BOOL there = rh && !(sh && [rh isEqualToString:sh]);
        if (here && there) {
            if (resolve > 0) there = NO;
            else if (resolve < 0) here = NO;
            else { t->conflict++; continue; }
        }
        if (here) {
            if ([remote write:rel data:ld mtime:mine[rel].doubleValue]) { state[rel] = lh; t->up++; }
            else t->failed++;
        } else if (there) {
            if (uploadOnly) { t->waiting++; continue; }
            NSData *d = [remote read:rel];
            if (!d || ![sha256_hex(d) isEqualToString:rh]) { t->failed++; continue; }        // half-arrived: not written
            if (ld) {                                                 // what is replaced can be brought back
                NSString *old = [backup stringByAppendingPathComponent:rel];
                [fm createDirectoryAtPath:old.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
                [ld writeToFile:old atomically:YES];
            }
            [fm createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
            if (![d writeToFile:path atomically:YES]) { t->failed++; continue; }
            double m = [r[@"mtime"] doubleValue];
            if (m > 0) [fm setAttributes:@{ NSFileModificationDate : [NSDate dateWithTimeIntervalSince1970:m] } ofItemAtPath:path error:nil];
            state[rel] = rh;
            t->down++;
        }
    }
    [[NSJSONSerialization dataWithJSONObject:state options:0 error:nil] writeToFile:statePath atomically:YES];
}

// ---------------------------------------------------------------- a run

static void run(int resolve, BOOL uploadOnly, BOOL quick, PortSyncDone done) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("port.sync", DISPATCH_QUEUE_SERIAL); });
    dispatch_async(queue, ^{
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        NSMutableArray<id<PortSyncRemote>> *remotes = [NSMutableArray array];
        NSURL *folder = folder_url();
        BOOL scoped = folder && [folder startAccessingSecurityScopedResource];
        if (folder) { PortSyncFolder *f = [PortSyncFolder new]; f.base = folder; [remotes addObject:f]; }
        if (port_sync_pc()) { PortSyncPC *pc = [PortSyncPC new]; pc.quick = quick; [remotes addObject:pc]; }
        NSDateFormatter *df = [NSDateFormatter new];
        df.dateFormat = @"yyyyMMdd-HHmmss";
        NSString *backup = [[g_root stringByAppendingPathComponent:@"save-backup"] stringByAppendingPathComponent:[df stringFromDate:NSDate.date]];
        BOOL conflict = NO, changed = NO;
        for (id<PortSyncRemote> remote in remotes) {
            Tally t = { 0 };
            if (g_key && g_root) sync_remote(remote, resolve, uploadOnly, backup, &t);
            else t.unreachable = YES;
            NSString *who = [remote.name isEqualToString:@"pc"] ? @"PC" : @"폴더";
            if (t.unreachable) {
                [lines addObject:quick && [remote.name isEqualToString:@"pc"] ? @"PC 세이브는 확인 못 함" : [who stringByAppendingString:@" 연결 안 됨"]];
                continue;
            }
            if (t.conflict) conflict = YES;
            if (t.down) changed = YES;
            NSMutableString *s = [NSMutableString stringWithFormat:@"%@: 받음 %d, 보냄 %d", who, t.down, t.up];
            if (t.waiting) [s appendFormat:@", 다음 시작 때 받을 것 %d", t.waiting];
            if (t.failed) [s appendFormat:@", 실패 %d", t.failed];
            if (t.conflict) [s appendFormat:@", 양쪽에서 바뀜 %d", t.conflict];
            [lines addObject:s];
        }
        if (scoped) [folder stopAccessingSecurityScopedResource];
        NSString *summary = remotes.count ? [lines componentsJoinedByString:@"   "] : @"세이브 공유가 설정되지 않았습니다.";
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(summary, conflict, changed); });
    });
}
void port_sync_run(int resolve, BOOL uploadOnly, PortSyncDone done) { run(resolve, uploadOnly, NO, done); }
void port_sync_run_start(int resolve, PortSyncDone done) { run(resolve, NO, YES, done); }

//
//  FCOfflineQueue.h
//  By Marco Arment. See included LICENSE file for BSD license.
//
//  Requires FMDB (https://github.com/ccgus/fmdb) and linking to SQLite.

#import <Foundation/Foundation.h>
#import "FCReachability.h"

// You must subclass FCOfflineQueue. Do not use it directly.

@interface FCOfflineQueue : NSOperationQueue

- (instancetype)initWithReachabilityHostname:(NSString *)reachabilityHostname allowCellular:(BOOL)allowCellular launchDelay:(double)delayInSeconds;

- (void)enqueueOfflineOperation:(int64_t)opcode userInfo:(NSDictionary *)userInfoOrNil;

// Merlin-style variant: priority is a BOOL.
// Priority is only enforced in the current running app, not persisted to the database for later runs.
// It's mostly just so you can e.g. run a sync operation immediately when a bunch of tasks are ahead of it.
- (void)enqueueOfflineOperation:(int64_t)opcode userInfo:(NSDictionary *)userInfoOrNil highPriority:(BOOL)highPriority;


// Subclasses must override this method. It will be called on a background queue.
// Within it, execute the task synchronously.
//
// Return:
//      YES to delete the current task, considering it complete, and proceed with queue execution
//       NO to suspend the queue and attempt to resume later, starting with retrying this task
//
// Examples of why you'd return NO: offline internet connection, refused password, user is logged out, etc.
- (BOOL)executeOperation:(int64_t)opcode userInfo:(NSDictionary *)userInfo;

// Subclasses may override: (no need to call super)
- (void)didLaunch;
- (void)didPause;
- (BOOL)shouldResume;
- (void)didResume;

@property (nonatomic, readonly) FCReachability *reachability;

@end


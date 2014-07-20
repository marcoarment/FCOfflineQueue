//
//  FCOfflineQueue.m
//  By Marco Arment. See included LICENSE file for BSD license.
//

#import "FCOfflineQueue.h"
#import "FMDatabaseQueue.h"
#import "FMDatabase.h"

@interface FCQueueOperation : NSOperation
@property (nonatomic, assign) int64_t opcode;
@property (nonatomic, strong) void (^actionBlock)(void);
@end

@implementation FCQueueOperation
- (void)main
{
    if (self.isCancelled) return;
    _actionBlock();
}
@end

@interface FCOfflineQueue ()
@property (nonatomic) FMDatabaseQueue *databaseQueue;
@property (nonatomic) FCReachability *reachability;
@end

@implementation FCOfflineQueue

+ (NSString *)expandQuery:(NSString *)query { return [query stringByReplacingOccurrencesOfString:@"$T" withString:NSStringFromClass(self)]; }

- (void)tryToResume:(NSNotification *)n
{
    [self setSuspended:NO];
}

- (instancetype)initWithReachabilityHostname:(NSString *)reachabilityHostname allowCellular:(BOOL)allowCellular launchDelay:(double)delayInSeconds
{
    if ( (self = [super init]) ) {
        [self setMaxConcurrentOperationCount:1];
        [self setName:NSStringFromClass(self.class)];
        
        self.reachability = [[FCReachability alloc] initWithHostname:reachabilityHostname allowCellular:allowCellular];
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(tryToResume:) name:UIApplicationDidBecomeActiveNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(tryToResume:) name:FCReachabilityOnlineNotification object:self.reachability];
        
        NSString *dbPath = [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByAppendingPathComponent:NSStringFromClass(self.class)];
        self.databaseQueue = [FMDatabaseQueue databaseQueueWithPath:dbPath];
        [[NSURL fileURLWithPath:dbPath] setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:NULL];
        
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
        dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
            [self addOperationWithBlock:^{
                [self.databaseQueue inDatabase:^(FMDatabase *db) {
                    [db executeUpdate:[self.class expandQuery:
                        @"CREATE TABLE IF NOT EXISTS $T ("
                        @"    opcode INTEGER NOT NULL,"
                        @"    userinfo BLOB"
                        @");"
                    ]];
                    [db executeUpdate:[self.class expandQuery:@"CREATE INDEX IF NOT EXISTS opcode_index ON $T (opcode);"]];
                
                    FMResultSet *rs = [db executeQuery:[self.class expandQuery:@"SELECT rowid, opcode, userinfo FROM $T ORDER BY rowid"]];
                    while ([rs next]) {
                        NSData *data = [rs dataNoCopyForColumnIndex:2];
                        NSDictionary *userinfo = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL] : nil;
                        [self _enqueueOperationForID:[rs longLongIntForColumnIndex:0] opcode:[rs longLongIntForColumnIndex:1] userInfo:userinfo highPriority:NO];
                    }
                    [rs close];
                }];
                
                [self didLaunch];
            }];
        });
    }
    return self;
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self name:FCReachabilityOnlineNotification object:self.reachability];
    [NSNotificationCenter.defaultCenter removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)cancelAllOperations
{
    [self.databaseQueue inDatabase:^(FMDatabase *db) {
        [db executeUpdate:[self.class expandQuery:@"DELETE FROM $T"]];
    }];
    [super cancelAllOperations];
}

- (void)enqueueOfflineOperation:(int64_t)opcode userInfo:(NSDictionary *)userInfo
{
    [self enqueueOfflineOperation:opcode userInfo:userInfo highPriority:NO];
}

- (void)enqueueOfflineOperation:(int64_t)opcode userInfo:(NSDictionary *)userInfo highPriority:(BOOL)highPriority
{
    __block int64_t rowID = 0;
    if ([self.class operationPersistsBetweenLaunches:opcode]) {
        [self.databaseQueue inDatabase:^(FMDatabase *db) {
            NSNumber *opcodeNumber = @(opcode);

            if (! [self.class operationAllowsMultipleEntries:opcode]) {
                if ([self.class operationPersistsBetweenLaunches:opcode]) {
                    [db executeUpdate:[self.class expandQuery:@"DELETE FROM $T WHERE opcode = ?"], opcodeNumber];
                }

                [[self operations] enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
                    if ([obj isKindOfClass:[FCQueueOperation class]] && ((FCQueueOperation *)obj).opcode == opcode) {
                        [((FCQueueOperation *)obj) cancel];
                    }
                }];
            }
            
            [db executeUpdate:
                [self.class expandQuery:@"INSERT INTO $T (opcode, userinfo) VALUES (?, ?)"],
                opcodeNumber,
                userInfo ? [NSPropertyListSerialization dataWithPropertyList:userInfo format:NSPropertyListBinaryFormat_v1_0 options:NSPropertyListImmutable error:NULL] : [NSNull null]
            ];
            rowID = [db lastInsertRowId];
        }];
    }
    
    [self _enqueueOperationForID:rowID opcode:opcode userInfo:userInfo highPriority:highPriority];
    [self tryToResume:nil];
}

- (void)_enqueueOperationForID:(int64_t)rowID opcode:(int64_t)opcode userInfo:(NSDictionary *)userInfo highPriority:(BOOL)highPriority
{
    FCQueueOperation *op = [[FCQueueOperation alloc] init];
    op.opcode = opcode;
    op.queuePriority = highPriority ? NSOperationQueuePriorityVeryHigh : NSOperationQueuePriorityNormal;
    op.actionBlock = ^{
        BOOL success = [self executeOperation:opcode userInfo:userInfo];
        if (success) {
            if (rowID) {
                [self.databaseQueue inDatabase:^(FMDatabase *db) {
                    [db executeUpdate:[self.class expandQuery:@"DELETE FROM $T WHERE rowid = ?"], @(rowID)];
                }];
            }
        } else {
            [self setSuspended:YES];
        }
    };
    [self addOperation:op];
}

- (void)setSuspended:(BOOL)b
{
    if ([self isSuspended] == b) return;
    
    if (! b) {
        [super setSuspended:b];
    } else {
        // Resume
        if (! [self shouldResume]) return;
        [super setSuspended:b];
        [self didResume];
    }
}

#pragma mark - For subclasses to override

- (BOOL)executeOperation:(int64_t)opcode userInfo:(NSDictionary *)userInfo
{
    [[NSException exceptionWithName:NSGenericException reason:@"FCOfflineQueues must implement executeOperation:userInfo: and not call super" userInfo:nil] raise];
    return NO;
}

- (void)didLaunch { }
- (void)didResume { }
- (void)didPause  { }
- (BOOL)shouldResume { return YES; }

+ (BOOL)operationPersistsBetweenLaunches:(int64_t)opcode { return YES; }
+ (BOOL)operationAllowsMultipleEntries:(int64_t)opcode   { return YES; }

@end




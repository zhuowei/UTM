//
// Copyright © 2022 osy. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#import "UTMQemuManager.h"
#import "UTMJSONStream.h"
#import "UTMLogging.h"
#import "qapi-commands.h"
#import "qapi-emit-events.h"
#import "qapi-events.h"
#import "error.h"

extern NSString *const kUTMErrorDomain;
const int64_t kRPCTimeout = (int64_t)10*NSEC_PER_SEC;

static void utm_shutdown_handler(bool guest, ShutdownCause reason, void *ctx) {
    UTMQemuManager *self = (__bridge UTMQemuManager *)ctx;
    [self.delegate qemuWillQuit:self guest:guest reason:reason];
}

static void utm_powerdown_handler(void *ctx) {
    
}

static void utm_reset_handler(bool guest, ShutdownCause reason, void *ctx) {
    UTMQemuManager *self = (__bridge UTMQemuManager *)ctx;
    [self.delegate qemuHasReset:self guest:guest reason:reason];
}

static void utm_stop_handler(void *ctx) {
    UTMQemuManager *self = (__bridge UTMQemuManager *)ctx;
    [self.delegate qemuHasStopped:self];
}

static void utm_resume_handler(void *ctx) {
    UTMQemuManager *self = (__bridge UTMQemuManager *)ctx;
    [self.delegate qemuHasResumed:self];
}

static void utm_suspend_handler(void *ctx) {
    UTMQemuManager *self = (__bridge UTMQemuManager *)ctx;
    [self.delegate qemuHasSuspended:self];
}

static void utm_suspend_disk_handler(void *ctx) {
    
}

static void utm_wakeup_handler(void *ctx) {
    UTMQemuManager *self = (__bridge UTMQemuManager *)ctx;
    [self.delegate qemuHasWakeup:self];
}

static void utm_watchdog_handler(WatchdogAction action, void *ctx) {
    
}

static void utm_guest_panicked_handler(GuestPanicAction action, bool has_info, GuestPanicInformation *info, void *ctx) {
    UTMQemuManager *self = (__bridge UTMQemuManager *)ctx;
    [self.delegate qemuError:self error:NSLocalizedString(@"Guest panic", @"UTMQemuManager")];
}

static void utm_block_image_corrupted_handler(const char *device, bool has_node_name, const char *node_name, const char *msg, bool has_offset, int64_t offset, bool has_size, int64_t size, bool fatal, void *ctx) {
    UTMQemuManager *self = (__bridge UTMQemuManager *)ctx;
    if (fatal) {
        [self.delegate qemuError:self error:[NSString stringWithFormat:@"%s, %s: %s", device, node_name, msg]];
    }
}

static void utm_block_io_error_handler(const char *device, bool has_node_name, const char *node_name, IoOperationType operation, BlockErrorAction action, bool has_nospace, bool nospace, const char *reason, void *ctx) {
    UTMQemuManager *self = (__bridge UTMQemuManager *)ctx;
    [self.delegate qemuError:self error:[NSString stringWithFormat:@"%s, %s: %s", device, node_name, reason]];
}

static void utm_spice_connected_handler(SpiceBasicInfo *server, SpiceBasicInfo *client, void *ctx) {
    
}

static void utm_spice_initialized_handler(SpiceServerInfo *server, SpiceChannel *client, void *ctx) {
    
}

static void utm_spice_disconnected_handler(SpiceBasicInfo *server, SpiceBasicInfo *client, void *ctx) {
    
}

static void utm_spice_migrate_completed_handler(void *ctx) {
    
}

static void utm_migration_handler(MigrationStatus status, void *ctx) {
    
}

static void utm_migration_pass_handler(int64_t pass, void *ctx) {
    
}

typedef void(^rpcCompletionHandler_t)(NSDictionary *, NSError *);

@interface UTMQemuManager ()

@property (nonatomic, readwrite) BOOL isConnected;
@property (nonatomic, nullable) rpcCompletionHandler_t rpcCallback;
@property (nonatomic) UTMJSONStream *jsonStream;
@property (nonatomic) dispatch_semaphore_t cmdLock;

@end

@implementation UTMQemuManager

void qmp_rpc_call(CFDictionaryRef args, CFDictionaryRef *ret, Error **err, void *ctx) {
    UTMQemuManager *self = (__bridge UTMQemuManager *)ctx;
    dispatch_semaphore_t rpc_sema = dispatch_semaphore_create(0);
    __block NSDictionary *dict;
    __block NSError *nserr;
    __weak typeof(self) _self = self;
    dispatch_semaphore_wait(self.cmdLock, DISPATCH_TIME_FOREVER);
    self.rpcCallback = ^(NSDictionary *ret_dict, NSError *ret_err){
        NSCAssert(ret_dict || ret_err, @"Both dict and err are null");
        nserr = ret_err;
        dict = ret_dict;
        _self.rpcCallback = nil;
        dispatch_semaphore_signal(rpc_sema); // copy to avoid race condition
    };
    if (![self.jsonStream sendDictionary:(__bridge NSDictionary *)args error:&nserr] && self.rpcCallback) {
        self.rpcCallback(nil, nserr);
    }
    if (dispatch_semaphore_wait(rpc_sema, dispatch_time(DISPATCH_TIME_NOW, kRPCTimeout)) != 0) {
        // possible race between this timeout and the callback being triggered
        self.rpcCallback = ^(NSDictionary *ret_dict, NSError *ret_err){
            _self.rpcCallback = nil;
        };
        nserr = [NSError errorWithDomain:kUTMErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Timed out waiting for RPC.", "UTMQemuManager")}];
    }
    if (ret) {
        *ret = CFBridgingRetain(dict);
    }
    dict = nil;
    if (nserr) {
        if (err) {
            error_setg(err, "%s", [nserr.localizedDescription cStringUsingEncoding:NSUTF8StringEncoding]);
        }
        UTMLog(@"RPC: %@", nserr);
    }
    dispatch_semaphore_signal(self.cmdLock);
}

- (instancetype)initWithPort:(CSPort *)port {
    self = [super init];
    if (self) {
        self.jsonStream = [[UTMJSONStream alloc] initWithPort:port];
        self.jsonStream.delegate = self;
        self.cmdLock = dispatch_semaphore_create(1);
    }
    return self;
}

- (void)dealloc {
    if (self.rpcCallback) {
        self.rpcCallback(nil, [NSError errorWithDomain:kUTMErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Manager being deallocated, killing pending RPC.", "UTMQemuManager")}]);
    }
}

- (void)jsonStream:(UTMJSONStream *)stream connected:(BOOL)connected {
    UTMLog(@"QMP %@", connected ? @"connected" : @"disconnected");
    if (!connected) {
        self.isConnected = NO;
    }
}

- (void)jsonStream:(UTMJSONStream *)stream seenError:(NSError *)error {
    UTMLog(@"QMP stream error seen: %@", error);
    if (self.rpcCallback) {
        self.rpcCallback(nil, error);
    }
}

- (void)jsonStream:(UTMJSONStream *)stream receivedDictionary:(NSDictionary *)dict {
    [dict enumerateKeysAndObjectsUsingBlock:^(id key, id val, BOOL *stop) {
        if ([key isEqualToString:@"return"]) {
            if (self.rpcCallback) {
                self.rpcCallback(dict, nil);
            } else {
                UTMLog(@"Got unexpected 'return' response: %@", dict);
            }
            *stop = YES;
        } else if ([key isEqualToString:@"error"]) {
            if (self.rpcCallback) {
                self.rpcCallback(nil, [NSError errorWithDomain:kUTMErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: dict[@"error"][@"desc"]}]);
            } else {
                UTMLog(@"Got unexpected 'error' response: %@", dict);
            }
            *stop = YES;
        } else if ([key isEqualToString:@"event"]) {
            const char *event = [dict[@"event"] cStringUsingEncoding:NSASCIIStringEncoding];
            qapi_event_dispatch(event, (__bridge CFTypeRef)dict, (__bridge void *)self);
            *stop = YES;
        } else if ([key isEqualToString:@"QMP"]) {
            UTMLog(@"Got QMP handshake: %@", dict);
            NSError *error;
            BOOL success = [self qmpEnterCommandModeWithError:&error];
            if (success) {
                [self.delegate qemuQmpDidConnect:self];
            } else {
                [self.delegate qemuError:self error:error.localizedDescription];
            }
            *stop = YES;
        }
    }];
}

- (__autoreleasing NSError *)errorForQerror:(Error *)qerr {
    return [NSError errorWithDomain:kUTMErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithCString:error_get_pretty(qerr) encoding:NSASCIIStringEncoding]}];
}

- (BOOL)qmpEnterCommandModeWithError:(NSError * _Nullable __autoreleasing *)error {
    NSDictionary *cmd = @{
        @"execute": @"qmp_capabilities"
    };
    Error *qerr = NULL;
    qmp_rpc_call((__bridge CFDictionaryRef)cmd, NULL, &qerr, (__bridge void *)self);
    if (qerr != NULL) {
        if (error) {
            *error = [self errorForQerror:qerr];
            error_free(qerr);
        }
        return NO;
    } else {
        self.isConnected = YES;
        return YES;
    }
}

- (BOOL)continueBootWithError:(NSError * _Nullable __autoreleasing *)error {
    Error *qerr = NULL;
    qmp_cont(&qerr, (__bridge void *)self);
    if (qerr != NULL) {
        if (error) {
            *error = [self errorForQerror:qerr];
            error_free(qerr);
        }
        self.isConnected = NO;
        return NO;
    } else {
        return YES;
    }
}

- (void)qmpPowerCommand:(NSString *)command completion:(void (^ _Nullable)(NSError * _Nullable))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        Error *qerr = NULL;
        NSError *err;
        NSDictionary *cmd = @{
            @"execute": command
        };
        qmp_rpc_call((__bridge CFDictionaryRef)cmd, NULL, &qerr, (__bridge void *)self);
        if (qerr) {
            err = [self errorForQerror:qerr];
            error_free(qerr);
        }
        if (completion) {
            completion(err);
        }
    });
}

- (void)qmpHmpCommand:(NSString *)cmd completion:(void (^)(NSString * _Nullable, NSError * _Nullable))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        Error *qerr = NULL;
        NSError *err;
        NSString *result;
        char *res;
        res = qmp_human_monitor_command([cmd cStringUsingEncoding:NSASCIIStringEncoding], false, 0, &qerr, (__bridge void *)self);
        if (res) {
            result = [NSString stringWithCString:res encoding:NSASCIIStringEncoding];
            g_free(res);
        }
        if (qerr) {
            err = [self errorForQerror:qerr];
            error_free(qerr);
        }
        if (completion) {
            completion(result, err);
        }
    });
}

- (void)qemuPowerDownWithCompletion:(void (^ _Nullable)(NSError * _Nullable))completion {
    [self qmpPowerCommand:@"system_powerdown" completion:completion];
}

- (void)qemuResetWithCompletion:(void (^ _Nullable)(NSError * _Nullable))completion {
    [self qmpPowerCommand:@"system_reset" completion:completion];
}

- (void)qemuStopWithCompletion:(void (^ _Nullable)(NSError * _Nullable))completion {
    [self qmpPowerCommand:@"stop" completion:completion];
}

- (void)qemuResumeWithCompletion:(void (^ _Nullable)(NSError * _Nullable))completion {
    [self qmpPowerCommand:@"cont" completion:completion];
}

- (void)qemuQuitWithCompletion:(void (^ _Nullable)(NSError * _Nullable))completion {
    [self qmpPowerCommand:@"quit" completion:completion];
}

- (void)qemuSaveStateWithCompletion:(void (^)(NSString * _Nullable, NSError * _Nullable))completion snapshotName:(NSString *)name {
    NSString *cmd = [NSString stringWithFormat:@"savevm %@", name];
    [self qmpHmpCommand:cmd completion:completion];
}

- (void)qemuDeleteStateWithCompletion:(void (^)(NSString * _Nullable, NSError * _Nullable))completion snapshotName:(NSString *)name {
    NSString *cmd = [NSString stringWithFormat:@"delvm %@", name];
    [self qmpHmpCommand:cmd completion:completion];
}

- (void)mouseIndexForAbsolute:(BOOL)absolute withCompletion:(void (^)(int64_t, NSError * _Nullable))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        MouseInfoList *info = NULL;
        Error *qerr = NULL;
        int64_t index = -1;
        NSError *err;
        info = qmp_query_mice(&qerr, (__bridge void *)self);
        if (qerr) {
            err = [self errorForQerror:qerr];
            error_free(qerr);
        }
        if (info) {
            for (MouseInfoList *list = info; list; list = list->next) {
                if (list->value->absolute == absolute) {
                    index = list->value->index;
                    break;
                }
            }
            qapi_free_MouseInfoList(info);
        }
        if (completion) {
            completion(index, err);
        }
    });
}

- (void)mouseSelect:(int64_t)index withCompletion:(void (^)(NSString * _Nullable, NSError * _Nullable))completion {
    NSString *cmd = [NSString stringWithFormat:@"mouse_set %lld", index];
    [self qmpHmpCommand:cmd completion:completion];
}

@end

qapi_enum_handler_registry qapi_enum_handler_registry_data = {
    .qapi_shutdown_handler = utm_shutdown_handler,
    .qapi_powerdown_handler = utm_powerdown_handler,
    .qapi_reset_handler = utm_reset_handler,
    .qapi_stop_handler = utm_stop_handler,
    .qapi_resume_handler = utm_resume_handler,
    .qapi_suspend_handler = utm_suspend_handler,
    .qapi_suspend_disk_handler = utm_suspend_disk_handler,
    .qapi_wakeup_handler = utm_wakeup_handler,
    .qapi_watchdog_handler = utm_watchdog_handler,
    .qapi_guest_panicked_handler = utm_guest_panicked_handler,
    .qapi_block_image_corrupted_handler = utm_block_image_corrupted_handler,
    .qapi_block_io_error_handler = utm_block_io_error_handler,
    .qapi_spice_connected_handler = utm_spice_connected_handler,
    .qapi_spice_initialized_handler = utm_spice_initialized_handler,
    .qapi_spice_disconnected_handler = utm_spice_disconnected_handler,
    .qapi_spice_migrate_completed_handler = utm_spice_migrate_completed_handler,
    .qapi_migration_handler = utm_migration_handler,
    .qapi_migration_pass_handler = utm_migration_pass_handler,
};

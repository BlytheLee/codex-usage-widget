#import <Cocoa/Cocoa.h>
#import <CoreServices/CoreServices.h>

static NSString *const UsageURL = @"https://chatgpt.com/backend-api/wham/usage";
static NSString *const ResetCreditsURL = @"https://chatgpt.com/backend-api/wham/rate-limit-reset-credits";
static NSString *const ConsumeResetURL = @"https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume";

typedef NS_ENUM(NSInteger, CodexActivity) {
    CodexActivityTaskRunning,
    CodexActivityForegroundIdle,
    CodexActivityBackgroundIdle,
    CodexActivityClosed,
};

static void SessionEventsCallback(ConstFSEventStreamRef streamRef, void *clientCallBackInfo, size_t numEvents, void *eventPaths, const FSEventStreamEventFlags eventFlags[], const FSEventStreamEventId eventIds[]);

@interface UsageAppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(nonatomic, retain) NSStatusItem *statusItem;
@property(nonatomic, retain) NSMenuItem *fiveHourItem;
@property(nonatomic, retain) NSMenuItem *weeklyItem;
@property(nonatomic, retain) NSMenuItem *resetCreditItem;
@property(nonatomic, retain) NSMenuItem *useResetItem;
@property(nonatomic, retain) NSMenuItem *resetModuleLeadingSeparator;
@property(nonatomic, retain) NSMenuItem *statusItemInMenu;
@property(nonatomic, retain) NSMenuItem *syncPolicyItem;
@property(nonatomic, retain) NSDictionary *soonestResetCredit;
@property(nonatomic, retain) NSTimer *refreshTimer;
@property(nonatomic, retain) NSDate *lastRefreshStartedAt;
@property(nonatomic) FSEventStreamRef sessionEvents;
@property(nonatomic) BOOL isRefreshing;
@end

@implementation UsageAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"Codex …";
    self.statusItem.button.toolTip = @"Codex 使用额度";

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Codex 使用额度"];
    menu.delegate = self;
    self.statusItemInMenu = [self disabledItem:@"正在读取本机 Codex 额度…"];
    self.fiveHourItem = [self disabledItem:@"五小时额度：暂无数据"];
    self.weeklyItem = [self disabledItem:@"剩余额度：暂无数据"];
    self.resetCreditItem = [self disabledItem:@"主动重置机会：暂无数据"];
    self.useResetItem = [[NSMenuItem alloc] initWithTitle:@"使用重置" action:@selector(confirmAndConsumeReset:) keyEquivalent:@""];
    self.useResetItem.target = self;
    self.useResetItem.hidden = YES;

    [menu addItem:self.statusItemInMenu];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:self.fiveHourItem];
    [menu addItem:self.weeklyItem];
    self.resetModuleLeadingSeparator = [NSMenuItem separatorItem];
    [menu addItem:self.resetModuleLeadingSeparator];
    [menu addItem:self.resetCreditItem];
    [menu addItem:self.useResetItem];
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *refreshItem = [[NSMenuItem alloc] initWithTitle:@"刷新" action:@selector(refresh:) keyEquivalent:@"r"];
    refreshItem.target = self;
    [menu addItem:refreshItem];
    self.syncPolicyItem = [self disabledItem:@"同步策略：正在判断 Codex 状态…"];
    [menu addItem:self.syncPolicyItem];
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"退出 Codex Usage" action:@selector(terminate:) keyEquivalent:@"q"];
    quitItem.target = NSApp;
    [menu addItem:quitItem];

    self.statusItem.menu = menu;
    [self observeCodexApplication];
    [self observeSessionWrites];
    [self scheduleNextRefresh];
    [self refresh:nil];
}

- (NSMenuItem *)disabledItem:(NSString *)title {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    item.enabled = NO;
    return item;
}

- (void)menuWillOpen:(NSMenu *)menu {
    [self refresh:nil];
}

- (void)observeCodexApplication {
    NSNotificationCenter *workspaceNotifications = NSWorkspace.sharedWorkspace.notificationCenter;
    for (NSNotificationName name in @[
        NSWorkspaceDidLaunchApplicationNotification,
        NSWorkspaceDidTerminateApplicationNotification,
        NSWorkspaceDidActivateApplicationNotification,
        NSWorkspaceDidDeactivateApplicationNotification
    ]) {
        [workspaceNotifications addObserver:self selector:@selector(codexApplicationChanged:) name:name object:nil];
    }
}

- (void)codexApplicationChanged:(NSNotification *)notification {
    NSRunningApplication *application = notification.userInfo[NSWorkspaceApplicationKey];
    if ([application.bundleIdentifier isEqualToString:@"com.openai.codex"]) {
        [self refresh:nil];
    }
}

- (void)observeSessionWrites {
    NSString *sessionsPath = [NSHomeDirectory() stringByAppendingPathComponent:@".codex/sessions"];
    FSEventStreamContext context = {0, self, NULL, NULL, NULL};
    self.sessionEvents = FSEventStreamCreate(NULL, SessionEventsCallback, &context, (__bridge CFArrayRef)@[sessionsPath], kFSEventStreamEventIdSinceNow, 1.0, kFSEventStreamCreateFlagFileEvents);
    FSEventStreamSetDispatchQueue(self.sessionEvents, dispatch_get_main_queue());
    FSEventStreamStart(self.sessionEvents);
}

- (void)sessionFilesChanged {
    if ([self currentActivity] == CodexActivityTaskRunning) {
        if (!self.lastRefreshStartedAt || -[self.lastRefreshStartedAt timeIntervalSinceNow] >= 30) {
            [self refresh:nil];
        } else {
            [self scheduleNextRefresh];
        }
    }
}

- (void)scheduleNextRefresh {
    CodexActivity activity = [self currentActivity];
    NSTimeInterval interval = [self refreshIntervalForActivity:activity];
    [self.refreshTimer invalidate];
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:interval target:self selector:@selector(refresh:) userInfo:nil repeats:NO];
    self.syncPolicyItem.title = [NSString stringWithFormat:@"同步策略：%@", [self descriptionForActivity:activity]];
}

- (CodexActivity)currentActivity {
    NSRunningApplication *codex = nil;
    for (NSRunningApplication *application in NSWorkspace.sharedWorkspace.runningApplications) {
        if ([application.bundleIdentifier isEqualToString:@"com.openai.codex"]) {
            codex = application;
            break;
        }
    }
    if (!codex) return CodexActivityClosed;
    if ([self hasRecentSessionWrite]) return CodexActivityTaskRunning;
    return codex.active ? CodexActivityForegroundIdle : CodexActivityBackgroundIdle;
}

- (BOOL)hasRecentSessionWrite {
    NSURL *sessionsURL = [[NSFileManager defaultManager].homeDirectoryForCurrentUser URLByAppendingPathComponent:@".codex/sessions"];
    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtURL:sessionsURL includingPropertiesForKeys:@[NSURLContentModificationDateKey, NSURLIsRegularFileKey] options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
    NSDate *threshold = [NSDate dateWithTimeIntervalSinceNow:-90];
    for (NSURL *url in enumerator) {
        NSNumber *isRegularFile = nil;
        NSDate *modifiedAt = nil;
        [url getResourceValue:&isRegularFile forKey:NSURLIsRegularFileKey error:nil];
        if (!isRegularFile.boolValue) continue;
        [url getResourceValue:&modifiedAt forKey:NSURLContentModificationDateKey error:nil];
        if ([modifiedAt compare:threshold] == NSOrderedDescending) return YES;
    }
    return NO;
}

- (NSTimeInterval)refreshIntervalForActivity:(CodexActivity)activity {
    switch (activity) {
        case CodexActivityTaskRunning: return 30;
        case CodexActivityForegroundIdle: return 60;
        case CodexActivityBackgroundIdle: return 600;
        case CodexActivityClosed: return 18000;
    }
}

- (NSString *)descriptionForActivity:(CodexActivity)activity {
    switch (activity) {
        case CodexActivityTaskRunning: return @"任务进行中，30s更新一次";
        case CodexActivityForegroundIdle: return @"客户端前台运行中，1分钟更新一次";
        case CodexActivityBackgroundIdle: return @"客户端后台运行中，10分钟更新一次";
        case CodexActivityClosed: return @"客户端已关闭，5小时更新一次";
    }
}

- (void)refresh:(id)sender {
    if (self.isRefreshing) return;
    self.isRefreshing = YES;
    self.lastRefreshStartedAt = [NSDate date];
    self.statusItemInMenu.title = @"正在同步…";

    NSError *error = nil;
    NSDictionary *auth = [self localAuth:&error];
    if (!auth) {
        [self showError:error.localizedDescription ?: @"未找到本机 Codex 登录状态"];
        return;
    }

    NSURLRequest *usageRequest = [self requestForURL:UsageURL auth:auth body:nil];
    [[[NSURLSession sharedSession] dataTaskWithRequest:usageRequest completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (networkError || ![http isKindOfClass:[NSHTTPURLResponse class]] || http.statusCode < 200 || http.statusCode >= 300) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self showError:[self messageForHTTPResponse:http]]; });
            return;
        }

        NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *rateLimit = [payload isKindOfClass:[NSDictionary class]] ? payload[@"rate_limit"] : nil;
        NSDictionary *primary = rateLimit[@"primary_window"];
        NSDictionary *secondary = rateLimit[@"secondary_window"];
        BOOL hasFiveHour = [self isValidLimitWindow:primary] && [self isValidLimitWindow:secondary];
        NSDictionary *fiveHour = hasFiveHour ? primary : nil;
        NSDictionary *weekly = hasFiveHour ? secondary : primary;
        if (![self isValidLimitWindow:weekly]) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self showError:@"未收到可展示的额度数据"]; });
            return;
        }

        NSURLRequest *creditsRequest = [self requestForURL:ResetCreditsURL auth:auth body:nil];
        [[[NSURLSession sharedSession] dataTaskWithRequest:creditsRequest completionHandler:^(NSData *creditsData, NSURLResponse *creditsResponse, NSError *creditsError) {
            NSHTTPURLResponse *creditsHTTP = (NSHTTPURLResponse *)creditsResponse;
            NSDictionary *credits = (!creditsError && creditsHTTP.statusCode >= 200 && creditsHTTP.statusCode < 300) ? [NSJSONSerialization JSONObjectWithData:creditsData options:0 error:nil] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                self.fiveHourItem.hidden = !hasFiveHour;
                if (hasFiveHour) {
                    self.fiveHourItem.title = [self titleForLimit:fiveHour label:@"五小时额度"];
                }
                self.weeklyItem.title = [self titleForLimit:weekly label:@"剩余额度"];
                NSNumber *used = hasFiveHour ? fiveHour[@"used_percent"] : weekly[@"used_percent"];
                NSInteger remaining = MAX(0, MIN(100, 100 - used.integerValue));
                self.statusItem.button.title = [NSString stringWithFormat:@"Codex 剩 %ld%%", (long)remaining];
                [self updateResetCredits:credits];
                [self scheduleNextRefresh];
                self.statusItemInMenu.title = [NSString stringWithFormat:@"已同步 · %@", [NSDateFormatter localizedStringFromDate:[NSDate date] dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterShortStyle]];
                self.isRefreshing = NO;
            });
        }] resume];
    }] resume];
}

- (BOOL)isValidLimitWindow:(NSDictionary *)window {
    if (![window isKindOfClass:[NSDictionary class]] || ![window[@"used_percent"] isKindOfClass:[NSNumber class]]) return NO;
    return [window[@"reset_at"] isKindOfClass:[NSNumber class]] || [window[@"reset_after_seconds"] isKindOfClass:[NSNumber class]];
}

- (void)updateResetCredits:(NSDictionary *)payload {
    NSArray *credits = [payload[@"credits"] isKindOfClass:[NSArray class]] ? payload[@"credits"] : @[];
    NSMutableArray *available = [NSMutableArray array];
    for (NSDictionary *credit in credits) {
        if ([credit isKindOfClass:[NSDictionary class]] && [credit[@"status"] isEqual:@"available"] && [credit[@"id"] isKindOfClass:[NSString class]]) {
            [available addObject:credit];
        }
    }
    [available sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[@"expires_at"] compare:right[@"expires_at"]];
    }];

    self.soonestResetCredit = available.firstObject;
    if (!self.soonestResetCredit) {
        self.resetModuleLeadingSeparator.hidden = YES;
        self.resetCreditItem.hidden = YES;
        self.useResetItem.hidden = YES;
        return;
    }

    NSDate *expiresAt = [self dateFromISO8601:self.soonestResetCredit[@"expires_at"]];
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"zh_CN"];
    formatter.dateFormat = @"M月d日";
    self.resetModuleLeadingSeparator.hidden = NO;
    self.resetCreditItem.hidden = NO;
    self.resetCreditItem.title = expiresAt ? [NSString stringWithFormat:@"主动重置机会最早到期时间%@", [formatter stringFromDate:expiresAt]] : @"主动重置机会最早到期时间未知";
    self.useResetItem.hidden = NO;
    self.useResetItem.enabled = YES;
}

- (void)confirmAndConsumeReset:(id)sender {
    if (!self.soonestResetCredit) return;

    NSAlert *alert = [NSAlert new];
    alert.messageText = @"使用赠送重置？";
    alert.informativeText = @"这会消耗 1 次赠送重置额度，并立即向 Codex 提交重置请求。此操作无法撤销。";
    [alert addButtonWithTitle:@"使用重置"];
    [alert addButtonWithTitle:@"取消"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    NSError *error = nil;
    NSDictionary *auth = [self localAuth:&error];
    if (!auth) {
        [self showError:error.localizedDescription ?: @"未找到本机 Codex 登录状态"];
        return;
    }

    NSDictionary *body = @{
        @"credit_id": self.soonestResetCredit[@"id"],
        @"redeem_request_id": NSUUID.UUID.UUIDString
    };
    NSURLRequest *request = [self requestForURL:ConsumeResetURL auth:auth body:body];
    self.isRefreshing = YES;
    self.statusItemInMenu.title = @"正在使用赠送重置…";
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.isRefreshing = NO;
            if (networkError || ![http isKindOfClass:[NSHTTPURLResponse class]] || http.statusCode < 200 || http.statusCode >= 300) {
                [self showError:[self messageForHTTPResponse:http]];
                return;
            }
            self.statusItemInMenu.title = @"重置请求已提交，正在刷新额度…";
            [self refresh:nil];
        });
    }] resume];
}

- (NSURLRequest *)requestForURL:(NSString *)url auth:(NSDictionary *)auth body:(NSDictionary *)body {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    [request setValue:[@"Bearer " stringByAppendingString:auth[@"access_token"]] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"codex-1" forHTTPHeaderField:@"OpenAI-Beta"];
    [request setValue:@"Codex Desktop" forHTTPHeaderField:@"originator"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    if (auth[@"account_id"]) [request setValue:auth[@"account_id"] forHTTPHeaderField:@"ChatGPT-Account-ID"];
    if (body) {
        request.HTTPMethod = @"POST";
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    }
    return request;
}

- (NSDictionary *)localAuth:(NSError **)error {
    NSURL *authURL = [[[NSFileManager defaultManager] homeDirectoryForCurrentUser] URLByAppendingPathComponent:@".codex/auth.json"];
    NSData *data = [NSData dataWithContentsOfURL:authURL options:0 error:error];
    if (!data) return nil;

    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    NSDictionary *tokens = [json isKindOfClass:[NSDictionary class]] ? json[@"tokens"] : nil;
    NSString *accessToken = tokens[@"access_token"];
    if (![accessToken isKindOfClass:[NSString class]] || accessToken.length == 0) return nil;

    NSMutableDictionary *auth = [@{ @"access_token": accessToken } mutableCopy];
    if ([tokens[@"account_id"] isKindOfClass:[NSString class]]) auth[@"account_id"] = tokens[@"account_id"];
    return auth;
}

- (NSString *)titleForLimit:(NSDictionary *)limit label:(NSString *)label {
    NSInteger used = [limit[@"used_percent"] integerValue];
    NSInteger remaining = MAX(0, MIN(100, 100 - used));
    NSTimeInterval reset = [limit[@"reset_at"] doubleValue];
    if (reset <= 0) reset = NSDate.date.timeIntervalSince1970 + [limit[@"reset_after_seconds"] doubleValue];
    NSInteger seconds = MAX(0, (NSInteger)(reset - NSDate.date.timeIntervalSince1970));
    NSInteger days = seconds / 86400;
    NSInteger hours = (seconds % 86400) / 3600;
    NSString *countdown = days > 0 ? [NSString stringWithFormat:@"%ld天%ld小时", (long)days, (long)hours] : [NSString stringWithFormat:@"%ld小时", (long)MAX(1, (seconds + 3599) / 3600)];
    return [NSString stringWithFormat:@"%@：%ld%%，%@后重置", label, (long)remaining, countdown];
}

- (NSDate *)dateFromISO8601:(NSString *)value {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    NSDate *date = [formatter dateFromString:value];
    if (date) return date;
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    return [formatter dateFromString:value];
}

- (NSString *)messageForHTTPResponse:(NSHTTPURLResponse *)response {
    if (response.statusCode == 401 || response.statusCode == 403) return @"Codex 登录已失效，请重新登录";
    return @"额度服务暂时不可用";
}

- (void)showError:(NSString *)message {
    self.statusItem.button.title = @"Codex !";
    self.statusItemInMenu.title = message;
    self.isRefreshing = NO;
    [self scheduleNextRefresh];
}

@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        application.delegate = [UsageAppDelegate new];
        [application run];
    }
    return 0;
}

static void SessionEventsCallback(ConstFSEventStreamRef streamRef, void *clientCallBackInfo, size_t numEvents, void *eventPaths, const FSEventStreamEventFlags eventFlags[], const FSEventStreamEventId eventIds[]) {
    UsageAppDelegate *delegate = (UsageAppDelegate *)clientCallBackInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate sessionFilesChanged];
    });
}

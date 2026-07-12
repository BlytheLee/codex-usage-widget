#import <Cocoa/Cocoa.h>

static NSString *const UsageURL = @"https://chatgpt.com/backend-api/wham/usage";
static NSString *const ResetCreditsURL = @"https://chatgpt.com/backend-api/wham/rate-limit-reset-credits";
static NSString *const ConsumeResetURL = @"https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume";

@interface UsageAppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(nonatomic, retain) NSStatusItem *statusItem;
@property(nonatomic, retain) NSMenuItem *fiveHourItem;
@property(nonatomic, retain) NSMenuItem *weeklyItem;
@property(nonatomic, retain) NSMenuItem *resetCreditItem;
@property(nonatomic, retain) NSMenuItem *useResetItem;
@property(nonatomic, retain) NSMenuItem *statusItemInMenu;
@property(nonatomic, retain) NSDictionary *soonestResetCredit;
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
    self.weeklyItem = [self disabledItem:@"周额度：暂无数据"];
    self.resetCreditItem = [self disabledItem:@"赠送重置：暂无数据"];
    self.useResetItem = [[NSMenuItem alloc] initWithTitle:@"使用重置" action:@selector(confirmAndConsumeReset:) keyEquivalent:@""];
    self.useResetItem.target = self;
    self.useResetItem.hidden = YES;

    [menu addItem:self.statusItemInMenu];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:self.fiveHourItem];
    [menu addItem:self.weeklyItem];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:self.resetCreditItem];
    [menu addItem:self.useResetItem];
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *refreshItem = [[NSMenuItem alloc] initWithTitle:@"刷新" action:@selector(refresh:) keyEquivalent:@"r"];
    refreshItem.target = self;
    [menu addItem:refreshItem];
    [menu addItem:[self disabledItem:@"打开菜单时立即刷新 · 每 60 秒同步"]];
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"退出 Codex Usage" action:@selector(terminate:) keyEquivalent:@"q"];
    quitItem.target = NSApp;
    [menu addItem:quitItem];

    self.statusItem.menu = menu;
    [self refresh:nil];
    [NSTimer scheduledTimerWithTimeInterval:60 target:self selector:@selector(refresh:) userInfo:nil repeats:YES];
}

- (NSMenuItem *)disabledItem:(NSString *)title {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    item.enabled = NO;
    return item;
}

- (void)menuWillOpen:(NSMenu *)menu {
    [self refresh:nil];
}

- (void)refresh:(id)sender {
    if (self.isRefreshing) return;
    self.isRefreshing = YES;
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
        NSDictionary *fiveHour = rateLimit[@"primary_window"];
        NSDictionary *weekly = rateLimit[@"secondary_window"];
        if (![fiveHour isKindOfClass:[NSDictionary class]] || ![weekly isKindOfClass:[NSDictionary class]]) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self showError:@"未收到可展示的额度数据"]; });
            return;
        }

        NSURLRequest *creditsRequest = [self requestForURL:ResetCreditsURL auth:auth body:nil];
        [[[NSURLSession sharedSession] dataTaskWithRequest:creditsRequest completionHandler:^(NSData *creditsData, NSURLResponse *creditsResponse, NSError *creditsError) {
            NSHTTPURLResponse *creditsHTTP = (NSHTTPURLResponse *)creditsResponse;
            NSDictionary *credits = (!creditsError && creditsHTTP.statusCode >= 200 && creditsHTTP.statusCode < 300) ? [NSJSONSerialization JSONObjectWithData:creditsData options:0 error:nil] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                self.fiveHourItem.title = [self titleForLimit:fiveHour label:@"五小时额度"];
                self.weeklyItem.title = [self titleForLimit:weekly label:@"周额度"];
                NSNumber *used = fiveHour[@"used_percent"];
                NSInteger remaining = MAX(0, MIN(100, 100 - used.integerValue));
                self.statusItem.button.title = [NSString stringWithFormat:@"Codex %ld%%", (long)remaining];
                [self updateResetCredits:credits];
                self.statusItemInMenu.title = [NSString stringWithFormat:@"已同步 · %@", [NSDateFormatter localizedStringFromDate:[NSDate date] dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterShortStyle]];
                self.isRefreshing = NO;
            });
        }] resume];
    }] resume];
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
        self.resetCreditItem.title = @"赠送重置：无可用次数";
        self.useResetItem.hidden = YES;
        return;
    }

    NSDate *expiresAt = [self dateFromISO8601:self.soonestResetCredit[@"expires_at"]];
    NSTimeInterval hours = expiresAt ? MAX(0, ceil([expiresAt timeIntervalSinceNow] / 3600.0)) : 0;
    if (hours <= 24) {
        self.resetCreditItem.title = [NSString stringWithFormat:@"提醒：赠送重置将在约 %.0f 小时后到期", hours];
        self.useResetItem.hidden = NO;
        self.useResetItem.enabled = YES;
    } else {
        self.resetCreditItem.title = [NSString stringWithFormat:@"赠送重置：%lu 次可用 · 最近约 %.0f 小时后到期", (unsigned long)available.count, hours];
        self.useResetItem.hidden = YES;
    }
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
    NSInteger minutes = (seconds % 3600) / 60;
    NSString *countdown = days > 0 ? [NSString stringWithFormat:@"%ld 天 %ld 小时", (long)days, (long)hours] : (hours > 0 ? [NSString stringWithFormat:@"%ld 小时 %ld 分钟", (long)hours, (long)minutes] : [NSString stringWithFormat:@"%ld 分钟", (long)minutes]);
    return [NSString stringWithFormat:@"%@：%ld%% 剩余 · %@ 后重置", label, (long)remaining, countdown];
}

- (NSDate *)dateFromISO8601:(NSString *)value {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
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

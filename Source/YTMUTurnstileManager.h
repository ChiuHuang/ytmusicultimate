#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

@interface YTMUTurnstileManager : NSObject <WKScriptMessageHandler>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, copy) NSString *jwtToken;
@property (nonatomic, strong) NSMutableArray *completionHandlers;
+ (instancetype)sharedManager;
- (void)getJWTTokenWithCompletion:(void(^)(NSString *token))completion;
@end

@implementation YTMUTurnstileManager

+ (instancetype)sharedManager {
    static YTMUTurnstileManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[YTMUTurnstileManager alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        self.completionHandlers = [NSMutableArray array];
        
        WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
        [config.userContentController addScriptMessageHandler:self name:@"turnstile"];
        
        self.webView = [[WKWebView alloc] initWithFrame:CGRectMake(-1000, -1000, 300, 300) configuration:config];
        self.webView.hidden = YES;
        
        // Add to key window so it can render if needed
        dispatch_async(dispatch_get_main_queue(), ^{
            UIWindow *window = [UIApplication sharedApplication].keyWindow;
            if (window) {
                [window addSubview:self.webView];
            }
        });
    }
    return self;
}

- (void)getJWTTokenWithCompletion:(void(^)(NSString *token))completion {
    if (self.jwtToken) {
        completion(self.jwtToken);
        return;
    }
    
    [self.completionHandlers addObject:[completion copy]];
    
    if (self.completionHandlers.count == 1) {
        // First request, start the process
        NSString *html = @"<html><body style='margin:0;padding:0;'><iframe id='tframe' src='https://lyrics.api.dacubeking.com/challenge' style='width:100%;height:100%;border:none;'></iframe><script>window.addEventListener('message', function(e) { if(e.data && e.data.type) { window.webkit.messageHandlers.turnstile.postMessage(e.data); } });</script></body></html>";
        [self.webView loadHTMLString:html baseURL:[NSURL URLWithString:@"https://lyrics.api.dacubeking.com/"]];
    }
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if ([message.name isEqualToString:@"turnstile"]) {
        NSDictionary *data = message.body;
        NSString *type = data[@"type"];
        
        if ([type isEqualToString:@"turnstile-token"]) {
            NSString *token = data[@"token"];
            NSLog(@"[YTMU-Turnstile] Got token: %@", token);
            [self verifyTurnstileToken:token];
        } else if ([type isEqualToString:@"turnstile-error"] || [type isEqualToString:@"turnstile-timeout"]) {
            NSLog(@"[YTMU-Turnstile] Error: %@", data);
            [self resolveHandlersWithToken:nil];
        }
    }
}

- (void)verifyTurnstileToken:(NSString *)token {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://lyrics.api.dacubeking.com/verify-turnstile"]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *body = @{@"turnstileToken": token};
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (json[@"jwtToken"]) {
                self.jwtToken = json[@"jwtToken"];
                NSLog(@"[YTMU-Turnstile] Got JWT!");
                [self resolveHandlersWithToken:self.jwtToken];
                return;
            }
        }
        [self resolveHandlersWithToken:nil];
    }] resume];
}

- (void)resolveHandlersWithToken:(NSString *)token {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray *handlers = [self.completionHandlers copy];
        [self.completionHandlers removeAllObjects];
        for (void(^handler)(NSString *) in handlers) {
            handler(token);
        }
    });
}
@end

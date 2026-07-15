#import <Foundation/Foundation.h>

// 你指定的 Log Server 網址
#define LOG_SERVER_URL @"https://ytmtranslate.chiuhuang.dev/log"

// 輔助函數：將攔截到的資料非同步發送到我們的 Python 伺服器
static void sendLogToServer(NSString *type, NSString *url, NSString *body, NSString *response) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:LOG_SERVER_URL]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    
    NSDictionary *dict = @{
        @"type": type ?: @"",
        @"url": url ?: @"",
        @"request_body": body ?: @"",
        @"response_body": response ?: @""
    };
    
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dict options:0 error:&error];
    if (jsonData) {
        req.HTTPBody = jsonData;
        // 使用 sharedSession 發送 Log，不處理回應
        [[[NSURLSession sharedSession] dataTaskWithRequest:req] resume];
    }
}

%hook NSURLSession

// Hook 1: 攔截帶有 CompletionHandler 的請求 (很多現代 API 走這個)
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    
    NSString *urlString = request.URL.absoluteString;
    
    // 只攔截 youtubei 的 API
    if ([urlString containsString:@"youtubei/v1"]) {
        NSString *requestBody = @"";
        if (request.HTTPBody) {
            requestBody = [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding];
        }
        
        // 替換原本的 completionHandler 以攔截回傳 (Response) 的資料
        void (^customCompletion)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
            
            NSString *responseData = @"";
            if (data) {
                responseData = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                // YouTube 有時候會回傳 Protobuf (二進位格式)，這時用 UTF8 會解不出來
                if (!responseData) {
                    responseData = [NSString stringWithFormat:@"[解析失敗可能是二進位或 Protobuf, 檔案大小: %lu bytes]", (unsigned long)data.length];
                }
            }
            
            // 把 Request 跟 Response 都送到我們的伺服器
            sendLogToServer(@"completionHandler", urlString, requestBody, responseData);
            
            // 執行官方原本的 Callback，確保 App 正常運作
            if (completionHandler) {
                completionHandler(data, response, error);
            }
        };
        
        return %orig(request, customCompletion);
    }
    
    return %orig(request, completionHandler);
}

// Hook 2: 攔截使用 Delegate 的請求 (舊版或 Streaming API 可能走這個)
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    NSString *urlString = request.URL.absoluteString;
    if ([urlString containsString:@"youtubei/v1"]) {
        NSString *requestBody = @"";
        if (request.HTTPBody) {
            requestBody = [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding];
        }
        // 如果是 delegate，我們很難在這裡直接攔截 response，但至少先把 request 送過去
        sendLogToServer(@"delegate", urlString, requestBody, @"[這筆請求走 Delegate 模式，無法直接在此取得 Response]");
    }
    return %orig;
}

%end

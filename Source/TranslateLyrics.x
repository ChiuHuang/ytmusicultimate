#import <Foundation/Foundation.h>

// 定義我們要攔截的伺服器位址
// 測試時請改成你電腦的區域網路 IP (例如 http://192.168.1.100:3000/lyrics)
// 或者如果你架設在雲端，就換成你的雲端伺服器網址
#define PROXY_SERVER_URL @"http://192.168.137.1:3000/lyrics"

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error))completionHandler {
    
    NSMutableURLRequest *mutableRequest = [request mutableCopy];
    NSString *urlString = mutableRequest.URL.absoluteString;
    
    // YouTube Music 通常透過 /youtubei/v1/browse 來請求歌詞 (browseId 通常是 FEmusic_lyrics...)
    if ([urlString containsString:@"youtubei/v1/browse"]) {
        
        if (mutableRequest.HTTPBody) {
            NSString *bodyString = [[NSString alloc] initWithData:mutableRequest.HTTPBody encoding:NSUTF8StringEncoding];
            
            // 檢查 request body 是否包含請求歌詞的特徵
            if ([bodyString containsString:@"music_lyrics"] || [bodyString containsString:@"FEmusic_lyrics"]) {
                NSLog(@"[YTMusicUltimate] 成功攔截歌詞請求！轉發至: %@", PROXY_SERVER_URL);
                
                // 把原本的目標網址改寫為我們的代理伺服器
                mutableRequest.URL = [NSURL URLWithString:PROXY_SERVER_URL];
                
                // 注意：這裡我們保留了原本的 HTTPBody，裡面包含了 Youtube 的認證與影片 ID (videoId 等等)。
                // 所以你的 Python/Node.js 伺服器收到的時候，可以直接從 Body 解析出目前正在播哪首歌。
            }
        }
    }
    
    // 呼叫原本的實現，並將攔截並修改後的 Request 傳遞進去
    return %orig(mutableRequest, completionHandler);
}

%end

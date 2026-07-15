#import <UIKit/UIKit.h>

@interface YTPlayerViewController : UIViewController
@property (readonly, nonatomic) NSString *currentVideoID;
@end

@interface YTFormattedStringLabel : UILabel
@end
@interface YTMLightweightMusicDescriptionShelfCell : UIView
@property (retain, nonatomic) UITextView *lyrics;
@end

// 為了建立測試按鈕需要的介面
@interface YTMAccountButton : UIButton
- (id)initWithTitle:(id)arg1 identifier:(id)arg2 icon:(id)arg3 actionBlock:(void (^)(BOOL finished))arg4;
@end

@interface UIView (Private)
- (id)_viewControllerForAncestor;
@end

static NSString *g_currentVideoID = nil;
static NSMutableDictionary *g_lyricsCache = nil;

// 輔助工具：把除錯訊息傳給你的 Python 伺服器，讓我們知道哪裡卡住了
static void sendDebugLog(NSString *msg) {
    NSString *encodedMsg = [msg stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *serverURL = [NSString stringWithFormat:@"https://ytmtranslate.chiuhuang.dev/api/lyrics?v=DEBUG_%@", encodedMsg];
    [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:serverURL]] resume];
}

%hook YTPlayerViewController
- (void)playbackController:(id)arg1 didActivateVideo:(id)arg2 withPlaybackData:(id)arg3 {
    %orig;
    if (self.currentVideoID) {
        g_currentVideoID = self.currentVideoID;
        sendDebugLog([NSString stringWithFormat:@"播放影片: %@", g_currentVideoID]);
    } else {
        sendDebugLog(@"播放影片但抓不到 currentVideoID");
    }
}
%end

// 因為我們不確定新版 YTMusic 是不是換了歌詞的 UI 類別，
// 這次我們直接 Hook 所有顯示 YT 格式字串的 Label！
%hook YTFormattedStringLabel

- (void)setAttributedText:(NSAttributedString *)text {
    if (!text || !g_currentVideoID) {
        %orig(text);
        return;
    }
    
    NSString *plainText = text.string;
    
    // 簡單判斷：如果這個 Label 的文字大於 50 字，而且包含超過 5 個換行符號
    // 我們就大膽假設它就是「歌詞本體」！
    NSArray *lines = [plainText componentsSeparatedByString:@"\n"];
    if (plainText.length > 50 && lines.count > 5) {
        
        // 為了確認我們抓到了歌詞，先送一個通知給伺服器
        // sendDebugLog(@"成功攔截到疑似歌詞的 UI！準備替換...");
        
        if (!g_lyricsCache) {
            g_lyricsCache = [[NSMutableDictionary alloc] init];
        }
        
        NSString *videoID = g_currentVideoID;
        
        // 如果已經有快取，直接替換
        if (g_lyricsCache[videoID]) {
            NSString *translatedText = g_lyricsCache[videoID];
            // 替換字串並保留原始字型/顏色設定
            NSMutableAttributedString *newAttrStr = [text mutableCopy];
            [newAttrStr.mutableString setString:translatedText];
            %orig(newAttrStr);
            return;
        }
        
        // 發送請求去抓新歌詞
        NSString *serverURL = [NSString stringWithFormat:@"https://ytmtranslate.chiuhuang.dev/api/lyrics?v=%@", videoID];
        NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:serverURL]];
        
        [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (!error && data) {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if (json && json[@"translated_lyrics"]) {
                    NSString *newLyrics = json[@"translated_lyrics"];
                    g_lyricsCache[videoID] = newLyrics;
                    
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if ([g_currentVideoID isEqualToString:videoID]) {
                            // 觸發 UI 重新更新
                            NSMutableAttributedString *newAttrStr = [text mutableCopy];
                            [newAttrStr.mutableString setString:newLyrics];
                            self.attributedText = newAttrStr; // 這裡會再呼叫一次 setAttributedText
                        }
                    });
                }
            }
        }] resume];
        
        // 第一次還沒抓到資料前，先顯示原始歌詞 (或是顯示載入中)
        %orig(text);
        return;
    }
    
    %orig(text);
}

%end

// Hook 3: 在帳號選單中加入一個「測試按鈕」方便除錯
%hook YTMAvatarAccountView

- (void)setAccountMenuUpperButtons:(id)arg1 lowerButtons:(id)arg2 {
    
    // 建立測試按鈕
    YTMAccountButton *testButton = [[%c(YTMAccountButton) alloc] initWithTitle:@"[Debug] 測試歌詞伺服器連線" identifier:@"test_lyrics_proxy" icon:nil actionBlock:^(BOOL finished) {
        
        // 彈出測試中的提示框
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"測試連線中" message:@"正在呼叫 ytmtranslate.chiuhuang.dev..." preferredStyle:UIAlertControllerStyleAlert];
        [self._viewControllerForAncestor presentViewController:alert animated:YES completion:nil];
        
        NSString *videoID = g_currentVideoID ?: @"NO_VIDEO_PLAYING";
        NSString *serverURL = [NSString stringWithFormat:@"https://ytmtranslate.chiuhuang.dev/api/lyrics?v=MANUAL_TEST_%@", videoID];
        
        // 發送測試連線
        [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:serverURL] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            
            dispatch_async(dispatch_get_main_queue(), ^{
                [alert dismissViewControllerAnimated:YES completion:^{
                    NSString *resultMsg;
                    if (error) {
                        resultMsg = [NSString stringWithFormat:@"❌ 連線失敗:\n%@", error.localizedDescription];
                    } else {
                        // 成功收到資料，顯示出來
                        NSString *responseString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                        resultMsg = [NSString stringWithFormat:@"✅ 伺服器有回應！\n\n內容:\n%@", responseString];
                    }
                    
                    UIAlertController *resultAlert = [UIAlertController alertControllerWithTitle:@"測試結果" message:resultMsg preferredStyle:UIAlertControllerStyleAlert];
                    [resultAlert addAction:[UIAlertAction actionWithTitle:@"太棒了" style:UIAlertActionStyleDefault handler:nil]];
                    [self._viewControllerForAncestor presentViewController:resultAlert animated:YES completion:nil];
                }];
            });
            
        }] resume];
    }];
    
    // 將按鈕加入選單的下方
    NSMutableArray *arrDown = [[NSMutableArray alloc] init];
    [arrDown addObjectsFromArray:arg2];
    [arrDown addObject:testButton];
    
    %orig(arg1, arrDown);
}

%end

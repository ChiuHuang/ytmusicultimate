#import <UIKit/UIKit.h>

// 宣告在 YTPlayerViewController 裡我們會用到的屬性
@interface YTPlayerViewController : UIViewController
@property (readonly, nonatomic) NSString *currentVideoID;
@end

// 宣告在 YTMLightweightMusicDescriptionShelfCell 裡會用到的東西
@interface YTFormattedStringLabel : UILabel
@end
@interface YTMLightweightMusicDescriptionShelfCell : UIView
@property (retain, nonatomic) UITextView *lyrics;
@end

// 全域變數，用來記錄目前正在播放的影片 ID 與歌詞快取
static NSString *g_currentVideoID = nil;
static NSMutableDictionary *g_lyricsCache = nil;

// Hook 1: 當歌曲開始播放時，攔截影片 ID
%hook YTPlayerViewController
- (void)playbackController:(id)arg1 didActivateVideo:(id)arg2 withPlaybackData:(id)arg3 {
    %orig;
    if (self.currentVideoID) {
        g_currentVideoID = self.currentVideoID;
    }
}
%end

// Hook 2: 攔截歌詞顯示的 Cell
%hook YTMLightweightMusicDescriptionShelfCell

- (void)setRenderer:(id)renderer {
    %orig; // 先讓官方跑完原本的邏輯 (這時畫面會顯示原始歌詞)
    
    YTFormattedStringLabel *descriptionLabel = [self valueForKey:@"_descriptionLabel"];
    if (!descriptionLabel) return;
    
    // 初始化快取
    if (!g_lyricsCache) {
        g_lyricsCache = [[NSMutableDictionary alloc] init];
    }
    
    NSString *videoID = g_currentVideoID;
    if (!videoID) return; // 如果不知道現在播什麼歌，就先放棄
    
    // 如果快取裡已經有這首歌的翻譯歌詞，直接替換
    if (g_lyricsCache[videoID]) {
        NSString *translatedText = g_lyricsCache[videoID];
        descriptionLabel.text = translatedText;
        
        // 如果你有開啟 selectableLyrics，連同那個隱藏的 UITextView 也一起改
        if ([self respondsToSelector:@selector(lyrics)] && self.lyrics) {
            self.lyrics.text = translatedText;
        }
        return;
    }
    
    // 如果還沒抓過，偷偷發請求給你的伺服器
    // 假設你的 Python 伺服器未來會有 /api/lyrics?v=... 的路徑
    NSString *serverURL = [NSString stringWithFormat:@"https://ytmtranslate.chiuhuang.dev/api/lyrics?v=%@", videoID];
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:serverURL]];
    
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && data) {
            // 嘗試解析伺服器回傳的 JSON
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            
            // 假設你伺服器回傳的格式是 {"translated_lyrics": "雙語歌詞內容..."}
            if (json && json[@"translated_lyrics"]) {
                NSString *newLyrics = json[@"translated_lyrics"];
                
                // 存入快取，下次切回來就不用重抓
                g_lyricsCache[videoID] = newLyrics;
                
                // 必須切換回 Main Thread (主執行緒) 才能更新 UI 畫面
                dispatch_async(dispatch_get_main_queue(), ^{
                    // 再次確認當前播放的歌還是一樣的，避免網路太慢，切歌了歌詞才回來
                    if ([g_currentVideoID isEqualToString:videoID]) {
                        descriptionLabel.text = newLyrics;
                        
                        if ([self respondsToSelector:@selector(lyrics)] && self.lyrics) {
                            self.lyrics.text = newLyrics;
                        }
                        
                        // 告訴視圖需要重繪以適應新的文字長度
                        [self setNeedsLayout];
                    }
                });
            }
        }
    }] resume];
}

%end

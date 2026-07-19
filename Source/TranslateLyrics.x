#import <UIKit/UIKit.h>
#import "YTMUTurnstileManager.h"

@interface YTPlayerViewController : UIViewController
@property (readonly, nonatomic) NSString *currentVideoID;
- (double)currentMediaTime;
@end

@interface YTFormattedStringLabel : UILabel
@end

@interface YTMLightweightMusicDescriptionShelfCell : UIView
@property (retain, nonatomic) UITextView *lyrics;
@end

static NSString *g_currentVideoID = nil;
static __weak YTPlayerViewController *g_activePlayer = nil;
static NSMutableDictionary *g_lyricsCache = nil;

// 輔助工具：把除錯訊息傳給你的 Python 伺服器
static void sendDebugLog(NSString *msg) {
    NSString *encodedMsg = [msg stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *serverURL = [NSString stringWithFormat:@"https://ytmtranslate.chiuhuang.dev/api/lyrics?v=DEBUG_%@", encodedMsg];
    [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:serverURL]] resume];
}



%hook YTPlayerViewController
- (void)playbackController:(id)arg1 didActivateVideo:(id)arg2 withPlaybackData:(id)arg3 {
    %orig;
    g_activePlayer = self;
    if (self.currentVideoID) {
        if (![self.currentVideoID isEqualToString:g_currentVideoID]) {
            g_currentVideoID = self.currentVideoID;
            [[NSNotificationCenter defaultCenter] postNotificationName:@"YTMUSongDidChange" object:g_currentVideoID];
        }
    }
}
%end

// Hook 2: 攔截靜態歌詞的 Cell (如果還存在的話)
%hook YTMLightweightMusicDescriptionShelfCell

- (void)setRenderer:(id)renderer {
    %orig; 
    
    sendDebugLog(@"✅ 成功進入歌詞 Cell (YTMLightweightMusicDescriptionShelfCell)");
    
    UILabel *descriptionLabel = [self valueForKey:@"_descriptionLabel"];
    if (!descriptionLabel) {
        sendDebugLog(@"⚠️ 找不到 _descriptionLabel");
        return;
    }
    
    if (!g_lyricsCache) {
        g_lyricsCache = [[NSMutableDictionary alloc] init];
    }
    
    NSString *videoID = g_currentVideoID;
    if (!videoID) return;
    
    if (g_lyricsCache[videoID]) {
        NSString *translatedText = g_lyricsCache[videoID];
        descriptionLabel.text = translatedText;
        
        if ([self respondsToSelector:@selector(lyrics)] && self.lyrics) {
            self.lyrics.text = translatedText;
        }
        return;
    }
    
    sendDebugLog([NSString stringWithFormat:@"準備向伺服器要歌詞: %@", videoID]);
    
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
                        descriptionLabel.text = newLyrics;
                        
                        if ([self respondsToSelector:@selector(lyrics)] && self.lyrics) {
                            self.lyrics.text = newLyrics;
                        }
                        [self setNeedsLayout];
                    }
                });
            }
        }
    }] resume];
}

%end



#import <objc/runtime.h>

@interface YTMULyricsViewController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray *lyrics;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) NSInteger currentIndex;
@property (nonatomic, assign) BOOL isLoading;
@property (nonatomic, copy) NSString *loadingVideoID;
- (void)updateLyrics:(NSArray *)newLyrics;
- (void)fetchLyricsForVideo:(NSString *)videoID;
@end

@implementation YTMULyricsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.view.backgroundColor = [UIColor clearColor];
    self.currentIndex = -1;
    
    // Setup UITableView
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.contentInset = UIEdgeInsetsMake(120, 0, 180, 0);
    self.tableView.showsVerticalScrollIndicator = NO;
    
    [self.view addSubview:self.tableView];
    
    self.lyrics = @[
        @{@"text": @"✨ Loading lyrics...", @"translated": @"正在載入歌詞...", @"time": @0}
    ];
    
    // Listen for song changes
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleSongChange:) name:@"YTMUSongDidChange" object:nil];
    
    // Start display link for auto-highlight
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(updatePlaybackTime)];
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.displayLink invalidate];
}

- (void)handleSongChange:(NSNotification *)notif {
    NSString *videoID = notif.object;
    if (videoID) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.currentIndex = -1;
            [self updateLyrics:@[@{@"text": @"✨ Loading lyrics...", @"translated": @"正在載入歌詞...", @"time": @0}]];
            [self fetchLyricsForVideo:videoID];
        });
    }
}

- (void)fetchLyricsForVideo:(NSString *)videoID {
    if (!g_lyricsCache) {
        g_lyricsCache = [[NSMutableDictionary alloc] init];\
    }
    
    // Check Cache first — instant return
    if (g_lyricsCache[videoID]) {
        [self updateLyrics:g_lyricsCache[videoID]];
        return;
    }
    
    // Dedup: if already loading this exact video, do nothing
    if (self.isLoading && [self.loadingVideoID isEqualToString:videoID]) {
        return;
    }
    self.isLoading = YES;
    self.loadingVideoID = videoID;
    
    // Fetch JWT (cached after first time), then fetch lyrics
    [self updateLyrics:@[@{@"text": @"✨ Getting lyrics...", @"translated": @"驗證中...", @"time": @0}]];
    [[YTMUTurnstileManager sharedManager] getJWTTokenWithCompletion:^(NSString *jwt) {
        // Don't fetch if user already switched songs
        if (![self.loadingVideoID isEqualToString:videoID]) {
            self.isLoading = NO;
            return;
        }
        
        NSString *serverURL = [NSString stringWithFormat:@"https://ytmtranslate.chiuhuang.dev/api/lyrics?v=%@", videoID];
        if (jwt) {
            serverURL = [serverURL stringByAppendingFormat:@"&jwt=%@", jwt];
        }
        
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:serverURL]];
        req.HTTPMethod = @"GET";
        
        [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.isLoading = NO;
                if (![self.loadingVideoID isEqualToString:videoID]) return; // stale
                
                if (error) {
                    [self updateLyrics:@[@{@"text": @"⚠️ 網路連線錯誤", @"translated": error.localizedDescription, @"time": @0}]];
                    return;
                }
                if (data) {
                    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    if (dict && dict[@"lyrics"]) {
                        g_lyricsCache[videoID] = dict[@"lyrics"]; // Save to Cache
                        [self updateLyrics:dict[@"lyrics"]];
                    } else {
                        [self updateLyrics:@[@{@"text": @"⚠️ 找不到歌詞", @"translated": @"No lyrics found", @"time": @0}]];
                    }
                }
            });
        }] resume];
    }];
}

- (void)updatePlaybackTime {
    if (!g_activePlayer || self.lyrics.count == 0 || self.lyrics.count == 1) return;
    
    double currentTime = 0;
    
    // Attempt to get current media time
    if ([g_activePlayer respondsToSelector:@selector(currentMediaTime)]) {
        currentTime = [g_activePlayer currentMediaTime];
    } else if ([g_activePlayer respondsToSelector:@selector(currentTime)]) {
        // Fallback for some player architectures
        currentTime = ((double (*)(id, SEL))objc_msgSend)(g_activePlayer, @selector(currentTime));
    }
    
    if (currentTime <= 0) return;
    
    NSInteger newIndex = -1;
    for (NSInteger i = 0; i < self.lyrics.count; i++) {
        NSDictionary *lyric = self.lyrics[i];
        double time = [lyric[@"time"] doubleValue];
        
        if (currentTime >= time) {
            newIndex = i;
        } else {
            break; // Since it's sorted, we can stop early
        }
    }
    
    if (newIndex != self.currentIndex && newIndex != -1) {
        NSInteger oldIndex = self.currentIndex;
        self.currentIndex = newIndex;
        
        // Reload rows to update highlighting
        NSMutableArray *rowsToReload = [NSMutableArray array];
        if (oldIndex >= 0 && oldIndex < self.lyrics.count) {
            [rowsToReload addObject:[NSIndexPath indexPathForRow:oldIndex inSection:0]];
        }
        if (newIndex >= 0 && newIndex < self.lyrics.count) {
            [rowsToReload addObject:[NSIndexPath indexPathForRow:newIndex inSection:0]];
        }
        
        if (rowsToReload.count > 0) {
            [self.tableView reloadRowsAtIndexPaths:rowsToReload withRowAnimation:UITableViewRowAnimationFade];
        }
        
        // Auto-scroll to the active lyric
        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:newIndex inSection:0];
        [self.tableView scrollToRowAtIndexPath:indexPath atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
    }
}

- (void)updateLyrics:(NSArray *)newLyrics {
    self.lyrics = newLyrics;
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.lyrics.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewAutomaticDimension;
}

- (CGFloat)tableView:(UITableView *)tableView estimatedHeightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 80;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"LyricCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"LyricCell"];
        cell.backgroundColor = [UIColor clearColor];
        
        // Main lyrics text
        cell.textLabel.font = [UIFont boldSystemFontOfSize:26];
        cell.textLabel.numberOfLines = 0;
        cell.textLabel.textAlignment = NSTextAlignmentLeft;
        
        // Translation text
        cell.detailTextLabel.font = [UIFont boldSystemFontOfSize:18];
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.textAlignment = NSTextAlignmentLeft;
        
        // Tap highlight
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        UIView *bgView = [[UIView alloc] init];
        bgView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.1];
        bgView.layer.cornerRadius = 12;
        cell.selectedBackgroundView = bgView;
    }
    
    NSDictionary *lyric = self.lyrics[indexPath.row];
    cell.textLabel.text = lyric[@"text"] ?: @"";
    
    NSString *translated = lyric[@"translated"];
    if (translated && [translated length] > 0) {
        cell.detailTextLabel.text = translated;
    } else {
        cell.detailTextLabel.text = nil;
    }
    
    // Highlighting logic
    if (indexPath.row == self.currentIndex) {
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.detailTextLabel.textColor = [UIColor whiteColor];
        cell.textLabel.alpha = 1.0;
        cell.detailTextLabel.alpha = 1.0;
        cell.transform = CGAffineTransformMakeScale(1.05, 1.05); // Slight pop effect
    } else {
        cell.textLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.5];
        cell.detailTextLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.3];
        cell.transform = CGAffineTransformIdentity;
    }
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    NSDictionary *lyric = self.lyrics[indexPath.row];
    NSNumber *time = lyric[@"time"];
    
    if (time && [time doubleValue] > 0) {
        NSLog(@"[YTMU-Seek] Seeking to time: %@", time);
        [[NSNotificationCenter defaultCenter] postNotificationName:@"YTMUSeekToTime" object:time];
    }
}

@end

%hook YTEngagementPanelViewControllerImpl

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    
    UIViewController *vc = (UIViewController *)self;
    id obj = (id)self;
    
    id model = nil;
    if ([obj respondsToSelector:@selector(model)]) {
        model = [obj performSelector:@selector(model)];
    }
    
    if (model && [[model description] containsString:@"PAmusic_watch_lyrics_panel"]) {
        UIView *contentContainer = nil;
        for (UIView *sub in vc.view.subviews) {
            if (![NSStringFromClass([sub class]) isEqualToString:@"YTEngagementPanelHeaderView"]) {
                contentContainer = sub;
                break;
            }
        }
        
        if (contentContainer) {
            for (UIView *sub in contentContainer.subviews) {
                if (sub.tag != 9999) {
                    sub.hidden = YES;
                }
            }
            
            UIView *lyricsView = [contentContainer viewWithTag:9999];
            YTMULyricsViewController *lyricsVC = objc_getAssociatedObject(contentContainer, @selector(lyricsVC));
            
            if (!lyricsView || !lyricsVC) {
                lyricsVC = [[YTMULyricsViewController alloc] init];
                lyricsVC.view.tag = 9999;
                lyricsVC.view.frame = contentContainer.bounds;
                lyricsVC.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                [contentContainer addSubview:lyricsVC.view];
                
                // Keep strong reference
                objc_setAssociatedObject(contentContainer, @selector(lyricsVC), lyricsVC, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            
            lyricsVC.view.frame = contentContainer.bounds;
            [contentContainer bringSubviewToFront:lyricsVC.view];
            
            if (g_currentVideoID) {
                [lyricsVC fetchLyricsForVideo:g_currentVideoID];
            } else {
                [lyricsVC updateLyrics:@[@{@"text": @"⚠️ 無法取得 Video ID", @"translated": @"請嘗試暫停再重新播放歌曲", @"time": @0}]];
            }
        }
    }
}

- (void)viewDidLayoutSubviews {
    %orig;
    
    UIViewController *vc = (UIViewController *)self;
    id obj = (id)self;
    
    id model = nil;
    if ([obj respondsToSelector:@selector(model)]) {
        model = [obj performSelector:@selector(model)];
    }
    
    if (model && [[model description] containsString:@"PAmusic_watch_lyrics_panel"]) {
        UIView *contentContainer = nil;
        for (UIView *sub in vc.view.subviews) {
            if (![NSStringFromClass([sub class]) isEqualToString:@"YTEngagementPanelHeaderView"]) {
                contentContainer = sub;
                break;
            }
        }
        
        if (contentContainer) {
            UIView *lyricsView = [contentContainer viewWithTag:9999];
            if (lyricsView) {
                [contentContainer bringSubviewToFront:lyricsView];
                lyricsView.frame = contentContainer.bounds;
                for (UIView *sub in contentContainer.subviews) {
                    if (sub.tag != 9999) {
                        sub.hidden = YES;
                    }
                }
            }
        }
    }
}

%end

@interface YTPlayerViewController (YTMU)
- (void)seekToTime:(double)time;
- (void)seekToTime:(double)time toleranceBefore:(double)before toleranceAfter:(double)after;
@end

%hook YTPlayerViewController

- (void)viewDidLoad {
    %orig;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ytmu_handleSeek:) name:@"YTMUSeekToTime" object:nil];
}

%new
- (void)ytmu_handleSeek:(NSNotification *)notif {
    NSNumber *timeObj = notif.object;
    if (!timeObj) return;
    
    double time = [timeObj doubleValue];
    NSLog(@"[YTMU-Seek] Attempting to seek to: %f", time);
    
    if ([self respondsToSelector:@selector(seekToTime:)]) {
        [self seekToTime:time];
    } else if ([self respondsToSelector:@selector(seekToTime:toleranceBefore:toleranceAfter:)]) {
        [self seekToTime:time toleranceBefore:0 toleranceAfter:0];
    } else {
        NSLog(@"[YTMU-Seek] ERROR: YTPlayerViewController does not respond to standard seek methods.");
    }
}

%end

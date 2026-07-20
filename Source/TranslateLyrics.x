#import <UIKit/UIKit.h>
#import "YTMUTurnstileManager.h"

@interface YTPlayerViewController : UIViewController
@property (readonly, nonatomic) NSString *currentVideoID;
- (double)currentMediaTime;
@end

// Global current time updated by player hook
static double g_currentPlaybackTime = 0.0;

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
    g_currentPlaybackTime = 0.0;
    if (self.currentVideoID) {
        if (![self.currentVideoID isEqualToString:g_currentVideoID]) {
            g_currentVideoID = self.currentVideoID;
            [[NSNotificationCenter defaultCenter] postNotificationName:@"YTMUSongDidChange" object:g_currentVideoID];
        } else {
            // Re-broadcast so panel loads on restore
            [[NSNotificationCenter defaultCenter] postNotificationName:@"YTMUSongDidChange" object:g_currentVideoID];
        }
    }
}

// Hook playback time updates — YTMusic calls this every ~0.1s
- (void)playbackController:(id)arg1 didReceivePlaybackPositionTime:(double)time {
    %orig;
    g_currentPlaybackTime = time;
}
%end

%hook YTAppDelegate
- (BOOL)application:(id)app didFinishLaunchingWithOptions:(id)options {
    BOOL result = %orig;
    // Pre-warm the JWT token in background at launch
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [[YTMUTurnstileManager sharedManager] getJWTTokenWithCompletion:nil];
    });
    return result;
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
    self.tableView.showsVerticalScrollIndicator = NO;
    
    // Header for top spacing and status label
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 120)];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UILabel *statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 80, self.view.bounds.size.width, 40)];
    statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    statusLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.7];
    statusLabel.textAlignment = NSTextAlignmentCenter;
    statusLabel.font = [UIFont systemFontOfSize:14];
    statusLabel.tag = 8888;
    [header addSubview:statusLabel];
    self.tableView.tableHeaderView = header;
    
    // Footer for bottom spacing
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 180)];
    self.tableView.tableFooterView = footer;
    
    [self.view addSubview:self.tableView];
    
    self.lyrics = @[];
    
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
            // Reset index but keep lyrics array intact for smooth transition
            if (![self.loadingVideoID isEqualToString:videoID]) {
                self.currentIndex = -1;
                UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
                statusLabel.text = @"✨ Loading lyrics...";
                self.lyrics = @[];
                [self.tableView reloadData];
            }
            [self fetchLyricsForVideo:videoID];
        });
    }
}

- (void)fetchLyricsForVideo:(NSString *)videoID {
    if (!g_lyricsCache) {
        g_lyricsCache = [[NSMutableDictionary alloc] init];
    }
    
    // Check Cache first
    if (g_lyricsCache[videoID]) {
        UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
        statusLabel.text = @""; // Clear indicator
        [self updateLyrics:g_lyricsCache[videoID]];
        return;
    }
    
    if (self.isLoading && [self.loadingVideoID isEqualToString:videoID]) {
        return;
    }
    self.isLoading = YES;
    self.loadingVideoID = videoID;
    
    UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
    statusLabel.text = @"🔍 Finding Live Lyrics...";
    
    // Step 1: Fast Request (LRCLIB + GTX)
    NSString *fastURL = [NSString stringWithFormat:@"https://ytmtranslate.chiuhuang.dev/api/lyrics?v=%@&fast=1", videoID];
    [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:fastURL] completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self.loadingVideoID isEqualToString:videoID]) return;
            if (data && !err) {
                NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if (dict && dict[@"lyrics"]) {
                    // Show fast lyrics, keep pro indicator
                    statusLabel.text = @"⚡️ Fast Lyrics loaded. Finding Pro...";
                    [self updateLyrics:dict[@"lyrics"]];
                }
            }
            
            // Step 2: Full Request (Cubey + Cohere) using JWT
            [[YTMUTurnstileManager sharedManager] getJWTTokenWithCompletion:^(NSString *jwt) {
                if (![self.loadingVideoID isEqualToString:videoID]) {
                    self.isLoading = NO;
                    return;
                }
                
                NSString *fullURL = [NSString stringWithFormat:@"https://ytmtranslate.chiuhuang.dev/api/lyrics?v=%@", videoID];
                if (jwt) {
                    fullURL = [fullURL stringByAppendingFormat:@"&jwt=%@", jwt];
                }
                
                [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:fullURL] completionHandler:^(NSData *fullData, NSURLResponse *fullRes, NSError *fullErr) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        self.isLoading = NO;
                        if (![self.loadingVideoID isEqualToString:videoID]) return;
                        
                        if (fullData && !fullErr) {
                            NSDictionary *fullDict = [NSJSONSerialization JSONObjectWithData:fullData options:0 error:nil];
                            if (fullDict && fullDict[@"lyrics"]) {
                                statusLabel.text = @""; // Clear indicator
                                g_lyricsCache[videoID] = fullDict[@"lyrics"];
                                [self updateLyrics:fullDict[@"lyrics"]];
                            } else if (!g_lyricsCache[videoID]) {
                                statusLabel.text = @"⚠️ 找不到歌詞 / No lyrics found";
                                self.lyrics = @[];
                                [self.tableView reloadData];
                            }
                        }
                    });
                }] resume];
            }];
        });
    }] resume];
}

- (void)updatePlaybackTime {
    if (self.lyrics.count <= 1) return;
    
    double currentTime = g_currentPlaybackTime;
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

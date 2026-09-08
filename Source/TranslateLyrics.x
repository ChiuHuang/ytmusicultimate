#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "YTMUTurnstileManager.h"
#import "Headers/YTPlayerViewController.h"
#import "Headers/YTIButtonRenderer.h"
#import "Headers/YTMNowPlayingViewController.h"
#import "Headers/ELMNodeController.h"

@interface UIView ()
- (UIViewController *)_viewControllerForAncestor;
@end

@interface ELMTouchCommandPropertiesHandler : NSObject
- (void)handleTap;
@end

@interface YTIButtonRenderer ()
- (BOOL)isDisabled;
@end

@interface YTPlayerViewController (YTMUExt)
- (double)currentMediaTime;
- (void)seekToTime:(double)time toleranceBefore:(double)before toleranceAfter:(double)after;
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
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIView *darkOverlay;
@property (nonatomic, assign) BOOL isModal;
- (void)updateLyrics:(NSArray *)newLyrics;
- (void)fetchLyricsForVideo:(NSString *)videoID;
- (void)forceReloadLyrics;
- (void)dismissModal;
@end

@interface YTPlayerViewController (YTMU_Lyrics)
- (CGFloat)currentVideoMediaTime;
@end

static __weak id g_activeEngagementPanelContainer = nil;
static void openLyricsFromViewController(UIViewController *parentVC);

@implementation YTMULyricsViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.currentIndex = -1;
    self.view.backgroundColor = [UIColor clearColor];

    // Background: dark blur effect matching YouTube Music
    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    self.blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    self.blurView.frame = self.view.bounds;
    self.blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view insertSubview:self.blurView atIndex:0];

    self.darkOverlay = [[UIView alloc] initWithFrame:self.view.bounds];
    self.darkOverlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.4];
    self.darkOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view insertSubview:self.darkOverlay aboveSubview:self.blurView];

    // Setup UITableView
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.showsVerticalScrollIndicator = NO;
    // Disabling estimated heights avoids content offset recalculation jumping to top during scroll
    self.tableView.estimatedRowHeight = 0;
    self.tableView.estimatedSectionHeaderHeight = 0;
    self.tableView.estimatedSectionFooterHeight = 0;

    // Header for top spacing and status label
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 50)];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UILabel *statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 10, self.view.bounds.size.width, 36)];
    statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    statusLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.7];
    statusLabel.textAlignment = NSTextAlignmentCenter;
    statusLabel.font = [UIFont systemFontOfSize:14];
    statusLabel.tag = 8888;
    [header addSubview:statusLabel];

    UIButton *reloadBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    reloadBtn.frame = CGRectMake(self.view.bounds.size.width - 105, 10, 85, 34);
    reloadBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [reloadBtn setTitle:@"🔄 Reload" forState:UIControlStateNormal];
    [reloadBtn setTitleColor:[[UIColor whiteColor] colorWithAlphaComponent:0.9] forState:UIControlStateNormal];
    reloadBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    reloadBtn.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
    reloadBtn.layer.cornerRadius = 17;
    [reloadBtn addTarget:self action:@selector(forceReloadLyrics) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:reloadBtn];

    if (self.isModal || self.presentingViewController) {
        UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        closeBtn.frame = CGRectMake(16, 10, 36, 36);
        [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
        [closeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:18];
        closeBtn.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
        closeBtn.layer.cornerRadius = 18;
        [closeBtn addTarget:self action:@selector(dismissModal) forControlEvents:UIControlEventTouchUpInside];
        [header addSubview:closeBtn];
    }

    self.tableView.tableHeaderView = header;

    // Footer for generous bottom spacing so the bottom lines can comfortably center
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 240)];
    self.tableView.tableFooterView = footer;

    [self.view addSubview:self.tableView];

    self.lyrics = @[];

    // Listen for song changes
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleSongChange:) name:@"YTMUSongDidChange" object:nil];

    // Start display link for real-time auto-highlight and word-by-word karaoke
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(updatePlaybackTime)];
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)dismissModal {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.displayLink invalidate];
}

- (void)handleSongChange:(NSNotification *)notif {
    NSString *videoID = notif.object;
    if (videoID) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self.loadingVideoID isEqualToString:videoID]) {
                self.currentIndex = -1;
                UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
                statusLabel.text = @"";
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

    if (g_lyricsCache[videoID]) {
        UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
        statusLabel.text = @"";
        [self updateLyrics:g_lyricsCache[videoID]];
        return;
    }

    if (self.isLoading && [self.loadingVideoID isEqualToString:videoID]) {
        return;
    }
    self.isLoading = YES;
    self.loadingVideoID = videoID;

    UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
    statusLabel.text = @"";

    // Fast Request (LRCLIB + GTX)
    NSString *fastURL = [NSString stringWithFormat:@"https://ytmtranslate.chiuhuang.dev/api/lyrics?v=%@&fast=1", videoID];
    [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:fastURL] completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self.loadingVideoID isEqualToString:videoID]) return;
            if (data && !err) {
                NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if (dict && dict[@"lyrics"]) {
                    statusLabel.text = @"";
                    [self updateLyrics:dict[@"lyrics"]];
                }
            }

            // Full Request (Cubey + Cohere) using JWT
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
                                statusLabel.text = @"";
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
    if (self.lyrics.count == 0) return;

    double currentTime = 0;
    if (g_activePlayer && [g_activePlayer respondsToSelector:@selector(currentVideoMediaTime)]) {
        currentTime = [g_activePlayer currentVideoMediaTime];
        g_currentPlaybackTime = currentTime;
    } else {
        currentTime = g_currentPlaybackTime;
    }

    if (currentTime <= 0) return;

    NSInteger newIndex = -1;
    for (NSInteger i = 0; i < self.lyrics.count; i++) {
        NSDictionary *lyric = self.lyrics[i];
        double time = [lyric[@"time"] doubleValue];

        if (currentTime >= time) {
            newIndex = i;
        } else {
            break;
        }
    }

    if (newIndex != self.currentIndex && newIndex != -1) {
        NSInteger oldIndex = self.currentIndex;
        self.currentIndex = newIndex;

        // Directly re-style old and new cells without calling reloadRowsAtIndexPaths
        // (reloadRows causes UITableView to recalculate heights and reset contentOffset to top!)
        if (oldIndex >= 0 && oldIndex < self.lyrics.count) {
            UITableViewCell *oldCell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:oldIndex inSection:0]];
            if (oldCell) {
                [self configureCell:oldCell atIndex:oldIndex isActive:NO currentTime:currentTime];
            }
        }

        if (newIndex >= 0 && newIndex < self.lyrics.count) {
            UITableViewCell *newCell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:newIndex inSection:0]];
            if (newCell) {
                [self configureCell:newCell atIndex:newIndex isActive:YES currentTime:currentTime];
            }

            // Smooth auto-scroll to the middle of the screen
            NSIndexPath *indexPath = [NSIndexPath indexPathForRow:newIndex inSection:0];
            [self.tableView scrollToRowAtIndexPath:indexPath atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
        }
    } else if (self.currentIndex >= 0 && self.currentIndex < self.lyrics.count) {
        // Line didn't change: update word-by-word karaoke synchronization for the active line
        NSDictionary *currLyric = self.lyrics[self.currentIndex];
        NSArray *parts = currLyric[@"parts"];
        if (parts && parts.count > 0) {
            UITableViewCell *currCell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:self.currentIndex inSection:0]];
            if (currCell) {
                [self applyWordSyncToCell:currCell lyric:currLyric currentTime:currentTime];
            }
        }
    }
}

- (void)forceReloadLyrics {
    if (!g_currentVideoID) return;

    if (g_lyricsCache) {
        [g_lyricsCache removeObjectForKey:g_currentVideoID];
    }
    self.lyrics = @[];
    [self.tableView reloadData];

    UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
    statusLabel.text = @"🔄 Force Reloading & Retranslating...";

    self.isLoading = YES;
    self.loadingVideoID = g_currentVideoID;

    [[YTMUTurnstileManager sharedManager] getJWTTokenWithCompletion:^(NSString *jwt) {
        if (![self.loadingVideoID isEqualToString:g_currentVideoID]) {
            self.isLoading = NO;
            return;
        }

        NSString *fullURL = [NSString stringWithFormat:@"https://ytmtranslate.chiuhuang.dev/api/lyrics?v=%@&force=1", g_currentVideoID];
        if (jwt) {
            fullURL = [fullURL stringByAppendingFormat:@"&jwt=%@", jwt];
        }

        [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:fullURL] completionHandler:^(NSData *fullData, NSURLResponse *fullRes, NSError *fullErr) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.isLoading = NO;
                if (![self.loadingVideoID isEqualToString:g_currentVideoID]) return;

                if (fullData && !fullErr) {
                    NSDictionary *fullDict = [NSJSONSerialization JSONObjectWithData:fullData options:0 error:nil];
                    if (fullDict && fullDict[@"lyrics"]) {
                        statusLabel.text = @"";
                        if (!g_lyricsCache) g_lyricsCache = [[NSMutableDictionary alloc] init];
                        g_lyricsCache[g_currentVideoID] = fullDict[@"lyrics"];
                        [self updateLyrics:fullDict[@"lyrics"]];
                    } else {
                        statusLabel.text = @"⚠️ 重譯失敗 / Force failed";
                    }
                } else {
                    statusLabel.text = @"⚠️ 網路錯誤 / Network error";
                }
            });
        }] resume];
    }];
}

- (void)updateLyrics:(NSArray *)newLyrics {
    self.lyrics = newLyrics;
    [self.tableView reloadData];

    if (newLyrics.count > 0) {
        self.view.hidden = NO;
        UIView *contentContainer = self.view.superview;
        if (contentContainer) {
            [contentContainer bringSubviewToFront:self.view];
            for (UIView *sub in contentContainer.subviews) {
                if (sub.tag != 9999) sub.hidden = YES;
            }
        }
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.lyrics.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewAutomaticDimension;
}

- (void)applyWordSyncToCell:(UITableViewCell *)cell lyric:(NSDictionary *)lyric currentTime:(double)currentTime {
    NSArray *parts = lyric[@"parts"];
    if (!parts || parts.count == 0) return;

    double currentMs = currentTime * 1000.0;
    UIFont *font = [UIFont boldSystemFontOfSize:26];
    UIColor *sungColor = [UIColor whiteColor];
    UIColor *unsungColor = [[UIColor whiteColor] colorWithAlphaComponent:0.42];

    NSMutableAttributedString *attrStr = [[NSMutableAttributedString alloc] init];

    for (NSDictionary *part in parts) {
        double wordStartMs = [part[@"startTimeMs"] doubleValue];
        NSString *w = part[@"words"] ?: @"";
        if (w.length == 0) continue;

        BOOL isSung = (currentMs >= wordStartMs);
        UIColor *col = isSung ? sungColor : unsungColor;

        NSDictionary *attrs = @{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: col
        };
        [attrStr appendAttributedString:[[NSAttributedString alloc] initWithString:w attributes:attrs]];
    }

    cell.textLabel.attributedText = attrStr;
}

- (void)configureCell:(UITableViewCell *)cell atIndex:(NSInteger)index isActive:(BOOL)isActive currentTime:(double)currentTime {
    if (index < 0 || index >= self.lyrics.count) return;

    NSDictionary *lyric = self.lyrics[index];
    NSArray *parts = lyric[@"parts"];

    if (isActive) {
        if (parts && parts.count > 0) {
            [self applyWordSyncToCell:cell lyric:lyric currentTime:currentTime];
        } else {
            cell.textLabel.attributedText = nil;
            cell.textLabel.text = lyric[@"text"] ?: @"";
            cell.textLabel.textColor = [UIColor whiteColor];
        }

        // Soft white glow / shadow on active line
        cell.textLabel.layer.shadowColor = [UIColor colorWithWhite:1.0 alpha:0.75].CGColor;
        cell.textLabel.layer.shadowOffset = CGSizeZero;
        cell.textLabel.layer.shadowRadius = 8.0;
        cell.textLabel.layer.shadowOpacity = 0.85;
        cell.textLabel.layer.masksToBounds = NO;

        cell.detailTextLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.95];
        cell.transform = CGAffineTransformMakeScale(1.03, 1.03);
    } else {
        cell.textLabel.attributedText = nil;
        cell.textLabel.text = lyric[@"text"] ?: @"";
        cell.textLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.45];
        cell.textLabel.layer.shadowOpacity = 0.0;

        cell.detailTextLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.30];
        cell.transform = CGAffineTransformIdentity;
    }

    NSString *translated = lyric[@"translated"];
    if (translated && translated.length > 0) {
        cell.detailTextLabel.text = translated;
    } else {
        cell.detailTextLabel.text = nil;
    }
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
        cell.detailTextLabel.font = [UIFont boldSystemFontOfSize:17];
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.textAlignment = NSTextAlignmentLeft;

        // Tap highlight
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        UIView *bgView = [[UIView alloc] init];
        bgView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.1];
        bgView.layer.cornerRadius = 12;
        cell.selectedBackgroundView = bgView;
    }

    double currentTime = 0;
    if (g_activePlayer && [g_activePlayer respondsToSelector:@selector(currentVideoMediaTime)]) {
        currentTime = [g_activePlayer currentVideoMediaTime];
    } else {
        currentTime = g_currentPlaybackTime;
    }

    BOOL isActive = (indexPath.row == self.currentIndex);
    [self configureCell:cell atIndex:indexPath.row isActive:isActive currentTime:currentTime];

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSDictionary *lyric = self.lyrics[indexPath.row];
    NSNumber *time = lyric[@"time"];

    if (time && [time doubleValue] >= 0) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"YTMUSeekToTime" object:time];

        NSInteger oldIndex = self.currentIndex;
        self.currentIndex = indexPath.row;
        g_currentPlaybackTime = [time doubleValue];

        if (oldIndex >= 0 && oldIndex < self.lyrics.count && oldIndex != indexPath.row) {
            UITableViewCell *oldCell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:oldIndex inSection:0]];
            if (oldCell) {
                [self configureCell:oldCell atIndex:oldIndex isActive:NO currentTime:g_currentPlaybackTime];
            }
        }
        UITableViewCell *newCell = [self.tableView cellForRowAtIndexPath:indexPath];
        if (newCell) {
            [self configureCell:newCell atIndex:indexPath.row isActive:YES currentTime:g_currentPlaybackTime];
        }
    }
}

@end


static void openLyricsFromViewController(UIViewController *parentVC) {
    // 1. Try opening native engagement panel if available
    if (g_activeEngagementPanelContainer) {
        if ([g_activeEngagementPanelContainer respondsToSelector:@selector(showEngagementPanelWithIdentifier:animated:)]) {
            [g_activeEngagementPanelContainer performSelector:@selector(showEngagementPanelWithIdentifier:animated:) withObject:@"PAmusic_watch_lyrics_panel" withObject:(id)kCFBooleanTrue];
            return;
        } else if ([g_activeEngagementPanelContainer respondsToSelector:@selector(showEngagementPanelWithIdentifier:)]) {
            [g_activeEngagementPanelContainer performSelector:@selector(showEngagementPanelWithIdentifier:) withObject:@"PAmusic_watch_lyrics_panel"];
            return;
        } else if ([g_activeEngagementPanelContainer respondsToSelector:@selector(openEngagementPanelWithIdentifier:animated:)]) {
            [g_activeEngagementPanelContainer performSelector:@selector(openEngagementPanelWithIdentifier:animated:) withObject:@"PAmusic_watch_lyrics_panel" withObject:(id)kCFBooleanTrue];
            return;
        }
    }

    // 2. Fallback: present YTMULyricsViewController directly as a bottom modal sheet
    if (parentVC) {
        YTMULyricsViewController *lyricsVC = [[YTMULyricsViewController alloc] init];
        lyricsVC.isModal = YES;
        lyricsVC.modalPresentationStyle = UIModalPresentationPageSheet;
        if (@available(iOS 15.0, *)) {
            UISheetPresentationController *sheet = lyricsVC.sheetPresentationController;
            sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
            sheet.prefersGrabberVisible = YES;
        }
        if (g_currentVideoID) {
            [lyricsVC fetchLyricsForVideo:g_currentVideoID];
        }
        [parentVC presentViewController:lyricsVC animated:YES completion:nil];
    }
}


%hook YTEngagementPanelContainerViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    g_activeEngagementPanelContainer = self;
}

- (void)viewDidLoad {
    %orig;
    g_activeEngagementPanelContainer = self;
}

%end


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
            UIView *lyricsView = [contentContainer viewWithTag:9999];
            YTMULyricsViewController *lyricsVC = objc_getAssociatedObject(contentContainer, @selector(lyricsVC));

            if (!lyricsView || !lyricsVC) {
                lyricsVC = [[YTMULyricsViewController alloc] init];
                lyricsVC.view.tag = 9999;
                lyricsVC.view.frame = contentContainer.bounds;
                lyricsVC.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                lyricsVC.view.hidden = YES;
                [contentContainer addSubview:lyricsVC.view];
                objc_setAssociatedObject(contentContainer, @selector(lyricsVC), lyricsVC, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }

            lyricsVC.view.frame = contentContainer.bounds;

            if (g_currentVideoID) {
                [lyricsVC fetchLyricsForVideo:g_currentVideoID];
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
            if (lyricsView && !lyricsView.hidden) {
                [contentContainer bringSubviewToFront:lyricsView];
                lyricsView.frame = contentContainer.bounds;
                for (UIView *sub in contentContainer.subviews) {
                    if (sub.tag != 9999) {
                        sub.hidden = YES;
                    }
                }
            } else if (lyricsView) {
                lyricsView.frame = contentContainer.bounds;
            }
        }
    }
}

%end


// Unlock lyrics button when YTM has no native lyrics
%hook YTIButtonRenderer

- (BOOL)isDisabled {
    // Check if this renderer represents the lyrics button
    if (self.icon) {
        NSString *iconDesc = [self.icon description];
        if ([iconDesc containsString:@"lyrics"] ||
            [iconDesc containsString:@"format_quote"] ||
            [iconDesc containsString:@"queue_music"]) {
            return NO;
        }
    }
    if (self.text) {
        NSString *textDesc = [self.text description];
        if ([textDesc containsString:@"歌詞"] || [textDesc containsString:@"Lyrics"]) {
            return NO;
        }
    }
    return %orig;
}

%end


// Unlock lyrics button tap in Elements (ELM)
%hook ELMTouchCommandPropertiesHandler

- (void)handleTap {
    if (class_getInstanceVariable([self class], "_controller") != NULL) {
        id node = [self valueForKey:@"_controller"];
        if ([node respondsToSelector:@selector(key)]) {
            NSString *key = [node performSelector:@selector(key)];
            if (key && [key containsString:@"lyric"]) {
                if (class_getInstanceVariable([self class], "_tapRecognizer") != NULL) {
                    UIGestureRecognizer *tapRecognizer = [self valueForKey:@"_tapRecognizer"];
                    UIViewController *vc = [tapRecognizer.view _viewControllerForAncestor];
                    openLyricsFromViewController(vc);
                    return;
                }
            }
        }
    }
    %orig;
}

%end


// Make the "沒有歌詞" bottom view in Now Playing clickable to open our lyrics
%hook YTMNowPlayingViewController

- (void)viewDidLayoutSubviews {
    %orig;

    // Search view hierarchy for any bottom view displaying "沒有歌詞" or "歌詞"
    for (UIView *sub in self.view.subviews) {
        [self ytmu_makeLyricsViewClickable:sub];
    }
}

%new
- (void)ytmu_makeLyricsViewClickable:(UIView *)v {
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *lbl = (UILabel *)v;
        if ([lbl.text containsString:@"沒有歌詞"] || [lbl.text containsString:@"歌詞"] || [lbl.text containsString:@"Lyrics"]) {
            UIView *container = lbl.superview;
            if (container && container.gestureRecognizers.count == 0) {
                container.userInteractionEnabled = YES;
                UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(ytmu_didTapLyricsBar:)];
                [container addGestureRecognizer:tap];
            }
        }
    }
    for (UIView *child in v.subviews) {
        [self ytmu_makeLyricsViewClickable:child];
    }
}

%new
- (void)ytmu_didTapLyricsBar:(UITapGestureRecognizer *)gesture {
    openLyricsFromViewController((UIViewController *)self);
}

%end

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

#import "YTMWatchViewController.h"

@interface YTMNowPlayingViewController : UIViewController
@property (nonatomic, weak, readwrite) YTMWatchViewController *parentViewController;

- (void)didTapNextButton;
- (void)didTapPrevButton;
- (void)didTapSeekForwardButton;
- (void)didTapSeekBackwardButton;
- (void)longPressPrev:(UILongPressGestureRecognizer *)gesture;
- (void)longPressNext:(UILongPressGestureRecognizer *)gesture;
- (void)ytmu_keepLyricsButtonActive;
- (void)ytmu_makeLyricsViewClickable:(UIView *)v;
- (void)ytmu_didTapLyricsButtonAction:(id)sender;
- (void)ytmu_didTapLyricsBar:(UITapGestureRecognizer *)gesture;
@end
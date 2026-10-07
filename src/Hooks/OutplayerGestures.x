//
//  OutplayerGestures.x
//  NeoFreeBird
//
//  Outplayer-style scrubbing for the immersive video player.
//
//  A one-finger horizontal drag on the video surface seeks the video live and
//  muted (the picture keeps moving under your finger) while a small badge in
//  the corner shows the current position. When the video is paused, small
//  horizontal drags step the video one frame at a time instead.
//

#import "HookHelpers.h"

static const void* kNFBOutplayerPanKey = &kNFBOutplayerPanKey;
static const void* kNFBOutplayerDelegateKey = &kNFBOutplayerDelegateKey;
static const void* kNFBOutplayerBadgeKey = &kNFBOutplayerBadgeKey;
static const void* kNFBOutplayerBaselineKey = &kNFBOutplayerBaselineKey;
static const void* kNFBOutplayerWasMutedKey = &kNFBOutplayerWasMutedKey;
static const void* kNFBOutplayerFrameStepKey = &kNFBOutplayerFrameStepKey;
static const void* kNFBOutplayerSteppedKey = &kNFBOutplayerSteppedKey;

// MARK: - Player lookup

// The immersive video page view owns the player in its "player" ivar.
static TAVPlayer* NFBPageViewPlayer(UIView* pageView) {
    if (!pageView) {
        return nil;
    }
    Ivar playerIvar = class_getInstanceVariable([pageView class], "player");
    return playerIvar ? object_getIvar(pageView, playerIvar) : nil;
}

// TAVPlayer is Twitter's AVPlayer wrapper and does not expose its seek API.
// Dig out the AVPlayer (or AVPlayerLayer) it holds and drive AVFoundation
// directly so we are not tied to a private method signature.
static AVPlayer* NFBUnderlyingAVPlayer(TAVPlayer* player) {
    if (!player) {
        return nil;
    }

    for (NSString* key in @[ @"avPlayer", @"player", @"_player", @"videoPlayer",
                             @"underlyingPlayer", @"avPlayerLayer" ]) {
        @try {
            id value = [player valueForKey:key];
            if ([value isKindOfClass:[AVPlayer class]]) {
                return value;
            }
            if ([value isKindOfClass:[AVPlayerLayer class]]) {
                return [(AVPlayerLayer*)value player];
            }
        } @catch (__unused NSException* exception) {
        }
    }

    AVPlayer* found = nil;
    for (Class cls = [player class]; cls && !found; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar* ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char* encoding = ivar_getTypeEncoding(ivars[i]);
            if (!encoding || encoding[0] != '@') {
                continue;
            }
            id value = object_getIvar(player, ivars[i]);
            if ([value isKindOfClass:[AVPlayer class]]) {
                found = value;
                break;
            }
            if ([value isKindOfClass:[AVPlayerLayer class]]) {
                found = [(AVPlayerLayer*)value player];
                break;
            }
        }
        free(ivars);
    }
    return found;
}

static NSTimeInterval NFBPlayerDuration(AVPlayer* player) {
    AVPlayerItem* item = player.currentItem;
    NSTimeInterval duration = CMTimeGetSeconds(item.duration);
    if (!isfinite(duration) || duration <= 0.0) {
        duration = CMTimeGetSeconds(item.asset.duration);
    }
    return (isfinite(duration) && duration > 0.0) ? duration : 0.0;
}

// Full-width sweep scales with the clip length, clamped to a sane range.
static NSTimeInterval NFBSweepSeconds(NSTimeInterval duration) {
    if (duration <= 0.0) {
        return 90.0;
    }
    return MIN(MAX(duration * 0.15, 30.0), 180.0);
}

static NSString* NFBFormatTime(NSTimeInterval seconds) {
    if (!isfinite(seconds) || seconds < 0.0) {
        seconds = 0.0;
    }
    long total = (long)llround(seconds);
    long hours = total / 3600;
    long minutes = (total % 3600) / 60;
    long secs = total % 60;
    if (hours > 0) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld", hours, minutes, secs];
    }
    return [NSString stringWithFormat:@"%ld:%02ld", minutes, secs];
}

// MARK: - Position badge

static UILabel* NFBBadge(UIView* host, BOOL create) {
    UILabel* badge = objc_getAssociatedObject(host, kNFBOutplayerBadgeKey);
    if (badge || !create) {
        return badge;
    }

    badge = [[UILabel alloc] initWithFrame:CGRectZero];
    badge.font = [UIFont monospacedDigitSystemFontOfSize:14.0 weight:UIFontWeightSemibold];
    badge.textColor = UIColor.whiteColor;
    badge.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.6];
    badge.textAlignment = NSTextAlignmentCenter;
    badge.layer.cornerRadius = 8.0;
    badge.layer.masksToBounds = YES;
    badge.userInteractionEnabled = NO;
    badge.hidden = YES;
    [host addSubview:badge];
    objc_setAssociatedObject(host, kNFBOutplayerBadgeKey, badge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return badge;
}

static void NFBUpdateBadge(UIView* host, NSTimeInterval position, NSTimeInterval duration) {
    UILabel* badge = NFBBadge(host, YES);
    badge.text = duration > 0.0
        ? [NSString stringWithFormat:@"%@ / %@", NFBFormatTime(position), NFBFormatTime(duration)]
        : NFBFormatTime(position);
    [badge sizeToFit];

    UIEdgeInsets insets = host.safeAreaInsets;
    CGFloat width = badge.bounds.size.width + 24.0;
    CGFloat height = MAX(badge.bounds.size.height + 10.0, 30.0);
    badge.frame = CGRectMake(insets.left + 16.0, insets.top + 16.0, width, height);
    badge.hidden = NO;
}

// MARK: - Gesture delegate

@interface NFBOutplayerPanDelegate : NSObject <UIGestureRecognizerDelegate>
@end

@implementation NFBOutplayerPanDelegate

// Only take over for clearly horizontal drags so the vertical card pan
// (video paging / swipe-to-dismiss) keeps working.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer*)gestureRecognizer {
    if (![gestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]]) {
        return YES;
    }
    UIPanGestureRecognizer* pan = (UIPanGestureRecognizer*)gestureRecognizer;
    CGPoint velocity = [pan velocityInView:pan.view];
    return fabs(velocity.x) > fabs(velocity.y) * 1.25;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer*)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer*)otherGestureRecognizer {
    return YES;
}

@end

// MARK: - Hooks

%hook _TtC14T1TwitterSwift22ImmersiveVideoPageView

- (void)didMoveToWindow {
    %orig;

    if (!self.window || ![BHTSettings boolForKey:@"outplayer_gestures"] ||
        objc_getAssociatedObject(self, kNFBOutplayerPanKey)) {
        return;
    }

    UIPanGestureRecognizer* pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(nfb_outplayerPan:)];
    pan.maximumNumberOfTouches = 1;
    pan.cancelsTouchesInView = NO;

    NFBOutplayerPanDelegate* delegate = [NFBOutplayerPanDelegate new];
    pan.delegate = delegate;
    objc_setAssociatedObject(self, kNFBOutplayerDelegateKey, delegate,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [self addGestureRecognizer:pan];
    objc_setAssociatedObject(self, kNFBOutplayerPanKey, pan, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%new
- (void)nfb_outplayerPan:(UIPanGestureRecognizer*)pan {
    if (![BHTSettings boolForKey:@"outplayer_gestures"]) {
        return;
    }

    TAVPlayer* player = NFBPageViewPlayer(self);
    AVPlayer* avPlayer = NFBUnderlyingAVPlayer(player);
    if (!avPlayer) {
        static BOOL loggedMissingPlayer = NO;
        if (!loggedMissingPlayer) {
            loggedMissingPlayer = YES;
            NSLog(@"[NFB] OutplayerGestures: could not locate an AVPlayer under %@",
                  player ? NSStringFromClass([player class]) : @"(nil TAVPlayer)");
        }
        return;
    }

    CGFloat width = self.bounds.size.width;
    if (width <= 0.0) {
        return;
    }

    NSTimeInterval duration = NFBPlayerDuration(avPlayer);
    BOOL frameStep = [objc_getAssociatedObject(self, kNFBOutplayerFrameStepKey) boolValue];

    switch (pan.state) {
        case UIGestureRecognizerStateBegan: {
            BOOL paused = player.playbackState.timeControlStatus == 0;
            BOOL useFrameStep = paused && [BHTSettings boolForKey:@"outplayer_frame_step"];
            objc_setAssociatedObject(self, kNFBOutplayerBaselineKey,
                                     @(CMTimeGetSeconds(avPlayer.currentTime)),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, kNFBOutplayerWasMutedKey, @(avPlayer.muted),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, kNFBOutplayerFrameStepKey, @(useFrameStep),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, kNFBOutplayerSteppedKey, @(0.0),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            avPlayer.muted = YES;
            NFBUpdateBadge(self, CMTimeGetSeconds(avPlayer.currentTime), duration);
            break;
        }

        case UIGestureRecognizerStateChanged: {
            CGPoint translation = [pan translationInView:self];

            if (frameStep) {
                // ~8pt of travel advances one frame.
                double targetFrames = translation.x / 8.0;
                double stepped = [objc_getAssociatedObject(self, kNFBOutplayerSteppedKey) doubleValue];
                NSInteger delta = (NSInteger)floor(targetFrames - stepped);
                if (delta != 0) {
                    [avPlayer.currentItem stepByCount:delta];
                    objc_setAssociatedObject(self, kNFBOutplayerSteppedKey,
                                             @(stepped + delta), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
            } else {
                NSTimeInterval baseline =
                    [objc_getAssociatedObject(self, kNFBOutplayerBaselineKey) doubleValue];
                NSTimeInterval target =
                    baseline + ((NSTimeInterval)translation.x / width) * NFBSweepSeconds(duration);
                if (duration > 0.0) {
                    target = MIN(MAX(target, 0.0), duration);
                }
                [avPlayer seekToTime:CMTimeMakeWithSeconds(target, NSEC_PER_SEC)
                     toleranceBefore:CMTimeMake(1, 30)
                      toleranceAfter:CMTimeMake(1, 30)];
            }

            NFBUpdateBadge(self, CMTimeGetSeconds(avPlayer.currentTime), duration);
            break;
        }

        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            if (!frameStep) {
                CGPoint translation = [pan translationInView:self];
                NSTimeInterval baseline =
                    [objc_getAssociatedObject(self, kNFBOutplayerBaselineKey) doubleValue];
                NSTimeInterval target =
                    baseline + ((NSTimeInterval)translation.x / width) * NFBSweepSeconds(duration);
                if (duration > 0.0) {
                    target = MIN(MAX(target, 0.0), duration);
                }
                [avPlayer seekToTime:CMTimeMakeWithSeconds(target, NSEC_PER_SEC)
                     toleranceBefore:kCMTimeZero
                      toleranceAfter:kCMTimeZero];
            }

            avPlayer.muted = [objc_getAssociatedObject(self, kNFBOutplayerWasMutedKey) boolValue];
            NFBBadge(self, NO).hidden = YES;
            break;
        }

        default:
            break;
    }
}

%end

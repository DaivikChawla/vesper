//
//  VesperObjectiveCExceptionCatcher.h
//  leanring-buddy
//
//  AVAudioEngine reports some failures (a tap installed with a format the
//  hardware no longer matches, a node connected twice, a buffer scheduled
//  on a player that isn't attached) by raising an Objective-C NSException.
//  Swift can't catch those: raised inside a Swift task, AppKit swallows the
//  exception, the task never finishes, and the app crashes minutes later
//  (seen with Bluetooth headphones switching sample rate as the mic opened).
//
//  This runs a block inside @try/@catch and hands the exception back, so
//  the Swift side can turn it into an ordinary thrown error.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `blockThatMightRaise` and returns the NSException it raised, or nil
/// if it finished normally. Keep the block to the raising call itself: an
/// exception unwinding through Swift code skips that code's cleanup.
FOUNDATION_EXPORT NSException * _Nullable VesperCatchObjectiveCException(NS_NOESCAPE void (^blockThatMightRaise)(void));

NS_ASSUME_NONNULL_END

//
//  VesperObjectiveCExceptionCatcher.m
//  leanring-buddy
//
//  See the header for why this exists.
//

#import "VesperObjectiveCExceptionCatcher.h"

NSException * _Nullable VesperCatchObjectiveCException(NS_NOESCAPE void (^blockThatMightRaise)(void)) {
    @try {
        blockThatMightRaise();
        return nil;
    } @catch (NSException *raisedException) {
        return raisedException;
    }
}

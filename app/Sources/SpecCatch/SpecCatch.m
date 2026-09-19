#import "SpecCatch.h"

BOOL NSException_blockCatch(NS_NOESCAPE void (^block)(void),
                            NSString **outName,
                            NSString **outReason) {
    @try {
        block();
        return NO;
    } @catch (NSException *exc) {
        if (outName)  *outName  = exc.name ?: @"unknown";
        if (outReason) *outReason = [NSString stringWithFormat:@"%@ userInfo=%@",
                                       exc.reason ?: @"(no reason)",
                                       exc.userInfo.description ?: @"(none)"];
        return YES;
    }
}

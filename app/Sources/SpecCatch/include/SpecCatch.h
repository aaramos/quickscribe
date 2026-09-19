#ifndef SPECCATCH_H
#define SPECCATCH_H

#import <Foundation/Foundation.h>

/// Executes `block`; if an Objective-C exception is raised, captures its
/// name/reason and returns YES. Swift cannot catch NSException directly —
/// this is the bridge (t_220b8507: AVAudioEngine raises, do/catch misses).
BOOL NSException_blockCatch(NS_NOESCAPE void (^block)(void),
                            NSString **outName,
                            NSString **outReason);

#endif

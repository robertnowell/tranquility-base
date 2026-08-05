#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs the block, catching any Objective-C exception thrown inside it.
/// Returns nil on success, the exception on failure.
///
/// Swift's `try`/`catch` only sees Swift errors. AVFoundation (and other ObjC
/// frameworks) throw NSExceptions for precondition failures — AVAudioEngine's
/// `installTap` throws `IsFormatSampleRateAndChannelCountValid` when the input
/// format is mid route-change. An NSException that unwinds through a dispatched
/// main-queue block leaves the queue permanently wedged: timers keep firing but
/// no queued block ever runs again, which presents as the whole app going dead
/// while the main thread samples as idle. This firewall is how AVFoundation
/// calls are kept from ever unwinding that far.
NSException *_Nullable VDCatchObjCException(void(NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END

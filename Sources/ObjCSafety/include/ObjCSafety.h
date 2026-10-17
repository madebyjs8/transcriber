#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, catching Objective-C exceptions (which Swift cannot catch). Apple's audio
/// frameworks report some device problems this way; uncaught, they terminate the app.
/// Returns the exception's reason, or nil when the block finished normally.
NSString *_Nullable TRCatchObjCException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END

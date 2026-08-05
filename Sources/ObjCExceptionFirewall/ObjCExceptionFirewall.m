#import "include/ObjCExceptionFirewall.h"

NSException *_Nullable VDCatchObjCException(void(NS_NOESCAPE ^block)(void)) {
    @try {
        block();
    } @catch (NSException *exception) {
        return exception;
    }
    return nil;
}

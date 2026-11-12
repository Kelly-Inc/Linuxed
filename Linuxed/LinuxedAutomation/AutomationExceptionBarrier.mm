// SPDX-License-Identifier: GPL-2.0-or-later

#import "AutomationExceptionBarrier.h"

NSException* LinuxedAutomationCatchException(NS_NOESCAPE void (^body)(void)) {
    @try {
        body();
    } @catch (NSException* exception) {
        return exception;
    } @catch (id object) {
        return [NSException exceptionWithName:NSGenericException
                                       reason:[object description]
                                     userInfo:nil];
    }
    return nil;
}

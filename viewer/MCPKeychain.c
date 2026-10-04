#include "MCPKeychain.h"
#include <Security/Security.h>
#include <pthread.h>

/* This ad-hoc-signed viewer uses the legacy login Keychain, like its VNC
 * password storage. LAContext / kSecUseNoAuthenticationUI are not a reliable
 * no-dialog boundary for legacy items. Keep the deprecated but supported
 * interaction guard here, rather than exposing legacy types throughout Swift.
 * All application Keychain calls are main-thread-only; none can interleave
 * while this synchronous operation temporarily disables Keychain UI. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
OSStatus sd_mcp_keychain_write(CFDictionaryRef query, CFDataRef data, bool creating)
{
    if (!pthread_main_np() || !query || !data) {
        return errSecParam;
    }

    /* Add needs the complete item; update needs only the replacement value.
     * The original query still selects which existing item to update. */
    CFMutableDictionaryRef write_attributes;
    if (creating) {
        write_attributes = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, query);
    } else {
        write_attributes = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
                                                     &kCFTypeDictionaryKeyCallBacks,
                                                     &kCFTypeDictionaryValueCallBacks);
    }
    if (!write_attributes) {
        return errSecAllocate;
    }
    CFDictionarySetValue(write_attributes, kSecValueData, data);

    Boolean previous_interaction_allowed;
    OSStatus status = SecKeychainGetUserInteractionAllowed(&previous_interaction_allowed);
    if (status != errSecSuccess) {
        CFRelease(write_attributes);
        return status;
    }

    status = SecKeychainSetUserInteractionAllowed(false);
    if (status != errSecSuccess) {
        (void)SecKeychainSetUserInteractionAllowed(previous_interaction_allowed);
        CFRelease(write_attributes);
        return status;
    }

    OSStatus write_status;
    if (creating) {
        write_status = SecItemAdd(write_attributes, NULL);
    } else {
        write_status = SecItemUpdate(query, write_attributes);
    }
    OSStatus restore_status = SecKeychainSetUserInteractionAllowed(previous_interaction_allowed);
    CFRelease(write_attributes);

    /* Report a write failure first. If the write succeeded, restoration can
     * still fail, so a non-success result does not prove that nothing changed. */
    if (write_status != errSecSuccess) {
        return write_status;
    }
    return restore_status;
}
#pragma clang diagnostic pop

#ifndef SHAREDESK_MCP_KEYCHAIN_H
#define SHAREDESK_MCP_KEYCHAIN_H

#include <CoreFoundation/CoreFoundation.h>
#include <Security/SecBase.h>
#include <stdbool.h>

/* Main-thread-only, synchronous write to the legacy macOS Keychain.
 * The caller owns query and data for the duration of the call.
 *
 * When creating is true, add an item using query's attributes and data.
 * Otherwise, update the value of the item selected by query.
 *
 * No authentication UI is allowed. Restore the previous interaction setting
 * before returning when possible. Return the write error first; otherwise,
 * return the restoration status. An error can therefore follow a saved write. */
OSStatus sd_mcp_keychain_write(CFDictionaryRef query, CFDataRef data, bool creating);

#endif

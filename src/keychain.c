// The macOS Keychain, as three functions.
//
// A shim in C rather than the same calls written in Zig, because every one of
// them is CoreFoundation: dictionaries of typed constants, retained strings,
// CFData wrappers. Done through FFI that is a lot of ceremony around three
// operations, and the ceremony is where the mistakes live. Here it is
// mechanical and readable, and Zig sees three functions taking bytes.
//
// WHAT THIS PROTECTS, precisely, because the usual assumption is wrong for this
// app. The login keychain is encrypted, so a copied home directory, a Time
// Machine backup or a stolen disk yield nothing without the login password.
// That is a real improvement on a 0600 file, which all three of those hand over.
//
// WHAT IT DOES NOT PROTECT: another process running as the same user. A keychain
// item's ACL is bound to the creating application's designated requirement, and
// an AD-HOC signature has none: there is no Team ID to bind to. Measured rather
// than assumed, with two ad-hoc binaries and the `security` tool:
//
//   $ ./spikeA write && ./spikeB read      # different cdhash
//   read: OSStatus=0 bytes=32
//   $ security find-generic-password -s com.zignostr.plaza.spike -w
//   0123456789abcdef0123456789abcdef
//
// An unrelated Apple-signed tool read the secret with no prompt at all. So this
// is at-rest encryption, and the app must not claim app-level isolation it
// measurably does not have. Getting that would mean a Developer ID and the
// `keychain-access-groups` entitlement, which is what Damus does and what this
// project's ad-hoc, reproducible-build position deliberately gives up.

#include <Security/Security.h>
#include <string.h>

static CFMutableDictionaryRef query_for(const char *service, const char *account) {
  CFStringRef svc = CFStringCreateWithCString(NULL, service, kCFStringEncodingUTF8);
  CFStringRef acc = CFStringCreateWithCString(NULL, account, kCFStringEncodingUTF8);
  CFMutableDictionaryRef q = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                       &kCFTypeDictionaryValueCallBacks);
  CFDictionarySetValue(q, kSecClass, kSecClassGenericPassword);
  CFDictionarySetValue(q, kSecAttrService, svc);
  CFDictionarySetValue(q, kSecAttrAccount, acc);
  CFRelease(svc);
  CFRelease(acc);
  return q;
}

// Stores `len` bytes, replacing whatever was there. 0 on success.
int plaza_keychain_set(const char *service, const char *account, const unsigned char *data,
                       unsigned long len) {
  CFMutableDictionaryRef q = query_for(service, account);
  // Delete first rather than branching on errSecDuplicateItem: an update path
  // that only sometimes runs is a path that is only sometimes right.
  SecItemDelete(q);
  CFDataRef payload = CFDataCreate(NULL, data, (CFIndex)len);
  CFDictionarySetValue(q, kSecValueData, payload);
  // The item is wanted while this Mac is unlocked and nowhere else: not synced
  // to iCloud, and not readable before first unlock after a boot.
  CFDictionarySetValue(q, kSecAttrAccessible, kSecAttrAccessibleWhenUnlockedThisDeviceOnly);
  OSStatus st = SecItemAdd(q, NULL);
  CFRelease(payload);
  CFRelease(q);
  return (int)st;
}

// Reads into `out`. 0 on success and `*out_len` set; nonzero otherwise, and
// `out` is untouched on every failing path.
int plaza_keychain_get(const char *service, const char *account, unsigned char *out,
                       unsigned long out_cap, unsigned long *out_len) {
  CFMutableDictionaryRef q = query_for(service, account);
  CFDictionarySetValue(q, kSecReturnData, kCFBooleanTrue);
  CFDictionarySetValue(q, kSecMatchLimit, kSecMatchLimitOne);
  CFTypeRef found = NULL;
  OSStatus st = SecItemCopyMatching(q, &found);
  CFRelease(q);
  if (st != errSecSuccess || found == NULL) return (int)(st == errSecSuccess ? -1 : st);

  CFDataRef data = (CFDataRef)found;
  CFIndex n = CFDataGetLength(data);
  if (n < 0 || (unsigned long)n > out_cap) {
    CFRelease(found);
    return -2;
  }
  memcpy(out, CFDataGetBytePtr(data), (size_t)n);
  *out_len = (unsigned long)n;
  CFRelease(found);
  return 0;
}

// Removes the item. 0 when it is gone, including when it was not there.
int plaza_keychain_delete(const char *service, const char *account) {
  CFMutableDictionaryRef q = query_for(service, account);
  OSStatus st = SecItemDelete(q);
  CFRelease(q);
  if (st == errSecItemNotFound) return 0;
  return (int)st;
}

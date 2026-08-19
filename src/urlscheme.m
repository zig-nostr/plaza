/* Receiving a `plaza://` link.
 *
 * Registering the scheme is the SDK's job and it does it: `.url_schemes` in
 * app.zon becomes CFBundleURLTypes in the packaged Info.plist, so macOS routes
 * a `plaza://` click to this app and launches or focuses it.
 *
 * Delivering the URL is nobody's job yet. The macOS host implements no
 * `application:openURLs:` and no Apple Event handler, and every `openURL` in the
 * SDK is outbound (asking the OS to open something else). So without this file a
 * click on a plaza:// link opens Plaza and drops the link on the floor, which is
 * the worst of the three possible behaviours: it looks like it worked.
 *
 * So Plaza installs its own handler. `setEventHandler:` registers on any object,
 * not just the app delegate, so this needs no cooperation from the SDK and
 * conflicts with nothing, precisely because the SDK handles the event nowhere.
 *
 * DELETE THIS when the SDK grows an inbound URL event. It is filed upstream. The
 * Zig side reads through one function, so removing this means changing one call.
 */

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <string.h>

/* The last URL macOS handed us, and a lock, because the Apple Event arrives on
 * the main thread while the app's tick may read from another. One slot and not a
 * queue: a person clicks one link at a time, and if two arrive between ticks the
 * newer one is the one they meant. */
static NSLock *g_url_lock = nil;
static char g_pending_url[2048];
static size_t g_pending_len = 0;

@interface PlazaUrlHandler : NSObject
- (void)handleGetURL:(NSAppleEventDescriptor *)event
      withReplyEvent:(NSAppleEventDescriptor *)reply;
@end

@implementation PlazaUrlHandler
- (void)handleGetURL:(NSAppleEventDescriptor *)event
      withReplyEvent:(NSAppleEventDescriptor *)reply {
  (void)reply;
  NSString *url =
      [[event paramDescriptorForKeyword:keyDirectObject] stringValue];
  if (url == nil) return;
  const char *utf8 = [url UTF8String];
  if (utf8 == NULL) return;
  size_t len = strlen(utf8);
  /* Truncated rather than refused, and the Zig side validates anyway: a link
   * longer than this is not one somebody typed. */
  if (len >= sizeof(g_pending_url)) len = sizeof(g_pending_url) - 1;
  [g_url_lock lock];
  memcpy(g_pending_url, utf8, len);
  g_pending_len = len;
  [g_url_lock unlock];
}
@end

static PlazaUrlHandler *g_handler = nil;

/* Called once at startup, as early as possible: on a COLD launch macOS sends the
 * Apple Event just after the app finishes launching, so a handler registered
 * late misses the very link that started the app. */
void plaza_url_scheme_install(void) {
  if (g_handler != nil) return;
  g_url_lock = [[NSLock alloc] init];
  g_handler = [[PlazaUrlHandler alloc] init];
  [[NSAppleEventManager sharedAppleEventManager]
      setEventHandler:g_handler
          andSelector:@selector(handleGetURL:withReplyEvent:)
        forEventClass:kInternetEventClass
           andEventID:kAEGetURL];
}

/* Moves the pending URL into `out` and clears it, returning its length. Zero
 * when there is nothing waiting. Taking rather than peeking is what stops one
 * link being applied twice. */
size_t plaza_url_scheme_take(char *out, size_t cap) {
  if (g_url_lock == nil || out == NULL || cap == 0) return 0;
  [g_url_lock lock];
  size_t n = g_pending_len;
  if (n > cap) n = cap;
  if (n > 0) memcpy(out, g_pending_url, n);
  g_pending_len = 0;
  [g_url_lock unlock];
  return n;
}

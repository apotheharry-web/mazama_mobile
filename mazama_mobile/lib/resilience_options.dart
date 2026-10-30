// Build-time knobs for the offline-resilience behavior lib/sync/center_stock.dart implements (see that file's
// own comment for what each step does and why) and the cart's selling limits (cart_page.dart). Meant to be constructed exactly once, in main.dart, before
// MazamaApp is ever created - not a runtime settings screen a worker can reach - and threaded down from there
// through every SelectCenterPage and CartPage this app opens: MazamaApp -> SignInPage/SelectCenterPage ->
// CartPage -> (switching centers) back to a new SelectCenterPage, all carrying the exact same instance along.
//
// A build that never constructs one of these (every existing call site, including every existing test) gets
// `const ResilienceOptions()` - today's behavior exactly, unchanged by this file's own existence.

/// How old the cart's stock may be before a sale reads it from the state again (SM-25, SM-D20: 5 minutes):
/// rules.yaml sale_check.recheck_after_minutes (test/sale_check_vectors_test.dart holds this to the vendored rules).
const defaultStockRecheckAge = Duration(minutes: 5);

class ResilienceOptions {
  /// Whether the cart's CenterStock (lib/sync/center_stock.dart) ever tries its step 2 (a direct, authenticated call to
  /// the real state system's own GetPackagedProducts) when step 1 (Mazama's server and the state together) got
  /// nothing. True by default - the whole point of that step. A build that should never talk to
  /// psilocybin.oregon.gov on its own behalf, even as a fallback - say, a demo build with no real worker credentials
  /// behind it - sets this false, which skips straight from a failed step 1 to step 3 (the stock kept), exactly as
  /// if no session were available at all.
  final bool enableStateFallback;

  /// How old the cart's stock may be before the cart refuses to sell from it (Q3, owner 2026-10-28: stock kept on the
  /// phone is shown at any age, with its age; selling from it stops past this, cart_page.dart's stockTooOld). Three
  /// days by default, same window this app shipped with before this became configurable.
  final Duration cacheMaxAge;

  /// Before a sale is sent, the cart's stock is read from the state system again when it was read longer ago than
  /// this, and a line that is gone or can't be sold any more is refused (SM-25). [defaultStockRecheckAge] by default.
  final Duration stockRecheckAge;

  const ResilienceOptions({
    this.enableStateFallback = true,
    this.cacheMaxAge = const Duration(days: 3),
    this.stockRecheckAge = defaultStockRecheckAge,
  });
}

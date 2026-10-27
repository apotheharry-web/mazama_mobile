// Demo mode's banner (specs/demo-mode DM-D3, DM-R5): "Demo: nothing here is real" above every page while the demo
// is open. It sits in MaterialApp.builder (main.dart), above the Navigator, so every page, dialog and sheet reached
// from the demo shows it without each one knowing about the demo. SelectCenterPage.demo turns it on; the sign-in
// page turns it off (signing out of the demo lands there, DM-D6).
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

const demoBannerText = 'Demo: nothing here is real';

/// Whether the demo is open. Read by [demoBannerBuilder]; set with [setDemoMode].
final ValueNotifier<bool> demoModeOn = ValueNotifier<bool>(false);

/// Turns the banner on or off after the current frame (a page calls this from initState, mid-build).
void setDemoMode(bool on) {
  if (demoModeOn.value == on) return;
  SchedulerBinding.instance.addPostFrameCallback((_) => demoModeOn.value = on);
}

/// MaterialApp.builder: the banner strip above the app while [demoModeOn]. The tree keeps the same shape either way
/// (a strip, then the app), so turning it on or off never rebuilds the Navigator and its pages.
Widget demoBannerBuilder(BuildContext context, Widget? child) => ValueListenableBuilder<bool>(
      valueListenable: demoModeOn,
      builder: (context, on, app) => Column(
        children: [
          if (on)
            Material(
              key: const ValueKey('demo-banner'),
              color: Colors.amber.shade700,
              child: SafeArea(
                bottom: false,
                child: SizedBox(
                  width: double.infinity,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: Text(
                      demoBannerText,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ),
            )
          else
            const SizedBox.shrink(key: ValueKey('demo-banner-off')),
          Expanded(child: MediaQuery.removePadding(context: context, removeTop: on, child: app ?? const SizedBox.shrink())),
        ],
      ),
      child: child,
    );

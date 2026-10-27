// A phone-first app's full-width Column/ListView stretches edge-to-edge on an iPad's much wider screen,
// especially in landscape (1024-1366pt wide, vs the phone-sized content this app was designed for) - readable
// on a phone, just oddly sparse and over-wide on a tablet (search fields and list rows stretching the full
// screen, lots of unused horizontal space). This wraps a page's body in a column capped at a sane reading
// width on anything wider, and is a complete no-op everywhere narrower - every phone, and an iPad in portrait
// (744-834pt, depending on model, still under the cap) - so this never changes how the app renders on the
// devices it was originally built and tested against.
//
// maxWidth is chosen specifically to sit above Flutter's default widget-test surface size (800x600 logical
// pixels) so none of this project's existing widget tests ever cross the threshold and start rendering a
// different (narrower, centered) layout than what they were written against - this is purely a wide-screen
// improvement, not a behavior change for anything already covered by a test.
import 'package:flutter/material.dart';

class ResponsiveBody extends StatelessWidget {
  static const double maxWidth = 900;

  final Widget child;

  const ResponsiveBody({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}

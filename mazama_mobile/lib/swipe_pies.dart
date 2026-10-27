// One spot for several pie cards, shown one at a time (the owner's rule for the stock page's units / mg pies and a
// picked strain's Quantity / mg size pies, and the Mazama inventory page's By strain / By type pies): a horizontal
// swipe on it, or a tap on the dots under it, shows another. The swipe only claims a drag the cards can follow, so a
// swipe past either end is left to the page view around the page (center_home_page.dart) and moves the pages
// instead; vertical scrolling is untouched.
//
// It must claim its drag before the page view does. A RawGestureDetector doesn't pass the device's gesture settings
// to its recognizers, so this one used Flutter's default 18-pixel touch slop while the page view used the phone's own
// (about 8 on Android): a finger moving a few pixels at a time reached the page view's slop first and the whole
// screen moved instead of the pie. So the recognizer takes the device settings, and claims a mostly sideways drag
// at half their slop: always before the page view, which needs the whole slop.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

class SwipePies extends StatefulWidget {
  const SwipePies({
    super.key,
    required this.index,
    required this.onIndex,
    required this.dots,
    required this.build,
  });

  /// The card showing, 0-based; the parent keeps it, so it survives rebuilds and data reloads.
  final int index;

  /// Asked to show card [i] (already within range).
  final ValueChanged<int> onIndex;

  /// One per card, in order: the dot's key and what a screen reader says for it ("Units pie").
  final List<({Key key, String label})> dots;

  /// Builds card [i].
  final Widget Function(int i) build;

  @override
  State<SwipePies> createState() => _SwipePiesState();
}

class _SwipePiesState extends State<SwipePies> {
  double _drag = 0;

  int get _count => widget.dots.length;
  int get _index => widget.index.clamp(0, _count - 1);

  bool _canSwipe(double dx) => dx < 0 ? _index < _count - 1 : _index > 0;

  void _show(int i) {
    setState(() => _drag = 0);
    final target = i.clamp(0, _count - 1);
    if (target != widget.index) widget.onIndex(target);
  }

  void _end(double velocity) {
    if (_drag < -40 || velocity < -300) {
      _show(_index + 1);
    } else if (_drag > 40 || velocity > 300) {
      _show(_index - 1);
    } else {
      _show(_index);
    }
  }

  @override
  Widget build(BuildContext context) {
    final index = _index;
    final card = widget.build(index);
    if (_count < 2) return card;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: {
            _PieSwipeRecognizer: GestureRecognizerFactoryWithHandlers<_PieSwipeRecognizer>(
              () => _PieSwipeRecognizer(canSwipe: _canSwipe),
              (r) => r
                ..gestureSettings = MediaQuery.maybeGestureSettingsOf(context)
                ..canSwipe = _canSwipe
                ..onStart = ((_) => setState(() => _drag = 0))
                ..onUpdate = ((d) => setState(() => _drag = (_drag + (d.primaryDelta ?? 0)).clamp(-160.0, 160.0)))
                ..onEnd = ((d) => _end(d.primaryVelocity ?? 0))
                ..onCancel = (() => _show(_index)),
            ),
          },
          child: Transform.translate(
            offset: Offset(_drag, 0),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: KeyedSubtree(key: ValueKey('swipe-pie-$index'), child: card),
            ),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final (i, dot) in widget.dots.indexed)
              Semantics(
                button: true,
                selected: i == index,
                label: dot.label,
                child: InkWell(
                  key: dot.key,
                  customBorder: const CircleBorder(),
                  onTap: () => _show(i),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i == index ? scheme.primary : scheme.outlineVariant,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// A horizontal drag that only claims a swipe the cards can follow (towards the next card, or back), and claims it
/// at half the touch slop, once it is more sideways than up or down: before the page view and the vertical scroll
/// around it, which each wait for the whole slop.
class _PieSwipeRecognizer extends HorizontalDragGestureRecognizer {
  _PieSwipeRecognizer({required this.canSwipe});

  /// Whether the cards can move for a drag that has gone [dx] so far (negative: leftwards, towards the next card).
  bool Function(double dx) canSwipe;

  double _dx = 0;
  double _dy = 0;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _dx = 0;
    _dy = 0;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      _dx += event.delta.dx;
      _dy += event.delta.dy;
    }
    super.handleEvent(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(PointerDeviceKind pointerDeviceKind, double? deviceTouchSlop) =>
      _dx.abs() > computeHitSlop(pointerDeviceKind, gestureSettings) / 2 && _dx.abs() > _dy.abs() && canSwipe(_dx);
}

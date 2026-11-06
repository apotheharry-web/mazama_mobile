// The center home's menu (center_home_page.dart): Change service center and Sign out, on every tab. Leaving a center
// can throw away unsold carts, so the page that knows what is unsold (the cart, cart_page.dart) does both and attaches
// them here; the home shows the menu while they are attached.
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

class CenterMenu extends ChangeNotifier {
  Future<void> Function()? _switchCenter;
  Future<void> Function()? _signOut;
  String? _signedInAs;
  Object? _owner;

  /// True while a page has attached the menu's actions.
  bool get ready => _switchCenter != null && _signOut != null;

  /// Who is signed in, shown in the menu; null when not known.
  String? get signedInAs => _signedInAs;

  /// [owner] does Change service center and Sign out from now on (the last to attach wins).
  void attach(Object owner,
      {required Future<void> Function() switchCenter, required Future<void> Function() signOut, String? signedInAs}) {
    _owner = owner;
    _switchCenter = switchCenter;
    _signOut = signOut;
    _signedInAs = signedInAs;
    _changed();
  }

  /// [owner] stops doing them; a later owner's actions stay.
  void detach(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _switchCenter = null;
    _signOut = null;
    _signedInAs = null;
    _changed();
  }

  /// Tells the center bar. The cart attaches while it is being built and detaches while it is taken down, when the
  /// bar can't be rebuilt: then it is told once the frame is done.
  void _changed() {
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle || phase == SchedulerPhase.postFrameCallbacks) {
      notifyListeners();
    } else {
      SchedulerBinding.instance.addPostFrameCallback((_) => notifyListeners());
    }
  }

  Future<void> switchCenter() async => _switchCenter?.call();
  Future<void> signOut() async => _signOut?.call();
}

// specs/app-updates AU-R10, AU-R13, AU-D10: the offer of a newer release, as a card (never a dialog) on the license
// picker (SelectCenterPage) and above the tabs of the center home (CenterHomePage), only while no cart holds a line: on
// the center home, the draft cart showing and every saved cart of that center; on the picker, every saved cart of every
// listed center (a sale only runs on a cart's lines, so none runs either). One attempt at a time: a second tap on
// Install does nothing; a card that is gone, or a cancel, hands nothing over. Never inside the Cart page, never in demo
// mode (the pages don't build it there), and only on Android (the checker offers nothing elsewhere).
//
// "Version x.y.z is ready to install", Install and Later. Nothing is downloaded until Install. Install: the carts are
// checked again; with "install unknown apps" off the card says so and opens Android's setting, installing nothing;
// otherwise the APK is downloaded (GitHub, then the server's copy, app_update_download.dart) with its progress and a
// Cancel, checked, and, if the carts are still empty, handed to Android's installer, which asks the worker to confirm.
// Failures after Install show here in fixed words; a refused APK says so once and that build is not offered again.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'app_installer.dart';
import 'app_update_check.dart';
import 'app_update_download.dart';
import 'cart_slots.dart';
import 'cart_store.dart';

/// The card's words while "install unknown apps" is off for the app.
const installPermissionWords =
    "Turn on \"Install unknown apps\" for Mazama in Android's settings, then tap Install again.";

/// Whether every cart of center [centerId] is empty (what the phone keeps for its carts).
Future<bool> centerCartsEmpty(int centerId, {Directory Function()? dataDir}) async {
  try {
    final slots = await CartSlotsStore(dataDir: dataDir).load(centerId) ?? CartSlots.initial();
    for (final cart in slots.carts) {
      final lines = await CartStore(dataDir: dataDir).load(centerId, cartId: cart.id);
      if (lines != null && lines.isNotEmpty) return false;
    }
    return true;
  } catch (_) {
    return false; // can't tell: don't offer
  }
}

enum _Phase { offer, downloading, permission, failed, refused }

class AppUpdateCard extends StatefulWidget {
  const AppUpdateCard({
    super.key,
    required this.checker,
    required this.cartsEmpty,
    this.cacheDir,
    this.downloadClient,
    this.serverHttp,
    this.prepare,
  });

  final AppUpdateChecker checker;

  /// Whether no cart (of the center showing) holds a line: checked when the card is built and again just before the
  /// hand-over to Android's installer.
  final Future<bool> Function() cartsEmpty;

  /// Where the APK is downloaded to (`updates/` under it); the app's cache folder by default.
  final Future<Directory> Function()? cacheDir;

  /// The clients the download uses (tests); GitHub's plain one and the server link by default.
  final http.Client? downloadClient;
  final http.Client? serverHttp;

  /// Downloads and checks [offer]'s APK for [app] and returns its path (app_update_download.dart's prepareUpdate into
  /// the cache folder by default; tests pass a fake). Throws UpdateDownloadError.
  final Future<String> Function(UpdateOffer offer, InstalledApp app, void Function(int got) progress, Future<void> cancel)?
      prepare;

  @override
  State<AppUpdateCard> createState() => _AppUpdateCardState();
}

class _AppUpdateCardState extends State<AppUpdateCard> with WidgetsBindingObserver {
  _Phase _phase = _Phase.offer;
  bool _empty = false;
  int _got = 0;
  String _message = '';
  Completer<void>? _cancel;
  int _checkSeq = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.checker.addListener(_changed);
    _recheckCarts();
  }

  @override
  void didUpdateWidget(AppUpdateCard old) {
    super.didUpdateWidget(old);
    if (!identical(old.checker, widget.checker)) {
      old.checker.removeListener(_changed);
      widget.checker.addListener(_changed);
    }
    _recheckCarts();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.checker.removeListener(_changed);
    _cancelDownload();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _recheckCarts() async {
    final seq = ++_checkSeq;
    final empty = await widget.cartsEmpty();
    if (!mounted || seq != _checkSeq) return;
    if (empty != _empty) setState(() => _empty = empty);
  }

  /// Downloads and checks into this attempt's own file (app_update_download.dart); the start-up clean-up empties the
  /// folder, so nothing here clears another attempt's file.
  Future<String> _prepareDefault(
      UpdateOffer offer, InstalledApp app, void Function(int got) progress, Future<void> cancel) async {
    final dir = await (widget.cacheDir ?? getTemporaryDirectory)();
    final file = await prepareUpdate(offer.file,
        cacheDir: dir,
        installer: widget.checker.installer,
        app: app,
        store: widget.checker.store,
        client: widget.downloadClient,
        progress: progress,
        cancel: cancel,
        fromServer: true,
        serverHttp: widget.serverHttp);
    return file.path;
  }

  /// True from the tap on Install until that attempt ends: set before anything is awaited, so a second tap does
  /// nothing (review I1).
  bool _busy = false;

  /// The APK handed to Android's installer, waiting for a refusal Android may still report (review M4).
  bool _handedOver = false;

  Future<void> _install() async {
    final offer = widget.checker.offer;
    if (offer == null || _busy) return;
    _busy = true;
    try {
      await _attempt(offer);
    } finally {
      _busy = false;
    }
  }

  Future<void> _attempt(UpdateOffer offer) async {
    if (!await widget.cartsEmpty()) {
      if (mounted) setState(() => _empty = false);
      return;
    }
    if (!mounted) return;
    final installer = widget.checker.installer;
    String? path;
    try {
      final app = await installer.installed();
      if (!mounted) return;
      if (!app.canInstall) {
        setState(() => _phase = _Phase.permission);
        await installer.openInstallSettings();
        return;
      }
      final cancel = Completer<void>();
      _cancel = cancel;
      setState(() {
        _phase = _Phase.downloading;
        _got = 0;
      });
      path = await (widget.prepare ?? _prepareDefault)(offer, app, (got) {
        if (mounted) setState(() => _got = got);
      }, cancel.future);
      _cancel = null;
      // review I2: a card gone (its page left) or a cancel during the last step hands nothing over
      if (!mounted || cancel.isCompleted) {
        deleteUpdateFile(path);
        if (mounted) setState(() => _phase = _Phase.offer);
        return;
      }
      // AU-R13: a cart line added during the download stops the hand-over
      if (!await widget.cartsEmpty() || !mounted) {
        deleteUpdateFile(path);
        if (mounted) {
          setState(() {
            _phase = _Phase.offer;
            _empty = false;
          });
        }
        return;
      }
      // Android copies (and hashes) the bytes into its session, which takes a while; the carts and the card are
      // checked again before the session is committed (review N3)
      final staged = await installer.stage(path, sha256: offer.file.sha256, size: offer.file.size);
      deleteUpdateFile(path); // the session holds its own copy of the bytes
      if (staged.startsWith('refused:')) {
        if (mounted) {
          setState(() {
            _phase = _Phase.failed;
            _message = staged.substring('refused:'.length);
          });
        }
        return;
      }
      final session = int.parse(staged.substring('staged:'.length));
      if (!mounted || cancel.isCompleted || !await widget.cartsEmpty() || !mounted) {
        await installer.abandon(session);
        if (mounted) {
          setState(() {
            _phase = _Phase.offer;
            _empty = false;
          });
          unawaited(_recheckCarts());
        }
        return;
      }
      final answer = await installer.commit(session);
      if (!mounted) return;
      setState(() {
        if (answer.startsWith('refused:')) {
          _phase = _Phase.failed;
          _message = answer.substring('refused:'.length);
        } else {
          _phase = _Phase.offer;
          _handedOver = true;
        }
      });
    } on UpdateDownloadError catch (e) {
      _cancel = null;
      if (path != null) deleteUpdateFile(path);
      if (e.refused) await widget.checker.refused(offer.build);
      if (!mounted) return;
      setState(() {
        if (e.refused) {
          _phase = _Phase.refused;
        } else if (e.cancelled) {
          _phase = _Phase.offer;
        } else {
          _phase = _Phase.failed;
          _message = e.message;
        }
      });
    } on AppInstallerError catch (e) {
      _cancel = null;
      if (path != null) deleteUpdateFile(path);
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _message = e.message;
      });
    }
  }

  /// Back from Android's installer: a refusal it reported after the hand-over is shown in its words (review M4).
  Future<void> _afterHandOver() async {
    if (!_handedOver) return;
    final words = await widget.checker.installer.takeStatus();
    if (words == null || !mounted) return;
    setState(() {
      _handedOver = false;
      _phase = _Phase.failed;
      _message = words;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_afterHandOver());
  }

  void _later() {
    setState(() => _phase = _Phase.offer);
    widget.checker.later();
  }

  @override
  Widget build(BuildContext context) {
    if (_phase == _Phase.refused) {
      return _card(
        const Text(cantInstallWords),
        [TextButton(onPressed: () => setState(() => _phase = _Phase.offer), child: const Text('OK'))],
      );
    }
    final offer = widget.checker.offer;
    if (offer == null || !_empty) return const SizedBox.shrink();
    final title = Text('Version ${offer.version} is ready to install',
        style: Theme.of(context).textTheme.titleMedium);
    final installLater = <Widget>[
      TextButton(onPressed: _later, child: const Text('Later')),
      FilledButton(onPressed: _install, child: const Text('Install')),
    ];
    if (_phase == _Phase.downloading) {
      return _card(
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          title,
          const SizedBox(height: 8),
          LinearProgressIndicator(value: offer.file.size > 0 ? _got / offer.file.size : null),
        ]),
        [TextButton(onPressed: _cancelDownload, child: const Text('Cancel'))],
      );
    }
    if (_phase == _Phase.permission) {
      return _card(
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [title, const Text(installPermissionWords)]),
          installLater);
    }
    if (_phase == _Phase.failed) {
      return _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [title, Text(_message)]), installLater);
    }
    return _card(title, installLater);
  }

  void _cancelDownload() {
    final c = _cancel;
    if (c != null && !c.isCompleted) c.complete();
  }

  Widget _card(Widget content, List<Widget> actions) => Card(
        key: const ValueKey('app-update-card'),
        margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              content,
              Row(mainAxisAlignment: MainAxisAlignment.end, children: actions),
            ],
          ),
        ),
      );
}

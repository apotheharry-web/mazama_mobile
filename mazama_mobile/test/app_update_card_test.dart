// specs/app-updates AU-R10, AU-R13, AU-D10: the update card (app_update_card.dart) and where it shows. The checker's
// installer is a fake (no Android here), its offer a TEST-signed release file (app_release_signing.dart), and the
// download a fake `prepare`, so nothing is fetched or written.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/app_installer.dart';
import 'package:mazama_mobile/app_update_card.dart';
import 'package:mazama_mobile/app_update_check.dart';
import 'package:mazama_mobile/app_update_download.dart';
import 'package:mazama_mobile/app_update_store.dart';
import 'package:mazama_mobile/center_home_page.dart';
import 'package:mazama_mobile/licenses_client.dart';

import 'app_release_signing.dart';

const _signer = 'aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11';

class _FakeInstaller extends AppInstaller {
  _FakeInstaller();
  bool canInstall = true;
  final handedOver = <String>[];
  var settingsOpened = 0;

  @override
  Future<InstalledApp> installed() async => InstalledApp(
      versionName: '0.2.3', versionCode: 26102901, sdkInt: 30, signers: const {_signer}, canInstall: canInstall);

  @override
  Future<void> openInstallSettings() async {
    settingsOpened++;
  }

  final hashes = <(String, int)>[];
  String? status;

  final staged = <int, String>{};
  final abandoned = <int>[];

  /// Runs while Android copies the bytes into its session (tests add a cart line here).
  void Function()? whileStaging;

  @override
  Future<String> stage(String path, {required String sha256, required int size}) async {
    hashes.add((sha256, size));
    whileStaging?.call();
    final id = staged.length + 1;
    staged[id] = path;
    return 'staged:$id';
  }

  /// The paths of the sessions committed: what was handed to Android's installer.
  @override
  Future<String> commit(int session) async {
    handedOver.add(staged[session]!);
    return 'started';
  }

  @override
  Future<void> abandon(int session) async => abandoned.add(session);

  @override
  Future<String?> takeStatus() async {
    final s = status;
    status = null;
    return s;
  }
}

void main() {
  late Directory tempDir;
  late _FakeInstaller installer;
  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('mazama_app_update_card_test_');
    installer = _FakeInstaller();
  });
  tearDown(() => tempDir.deleteSync(recursive: true));

  Future<AppUpdateChecker> offering(WidgetTester tester, {bool android = true}) async {
    final checker = AppUpdateChecker(
      store: AppUpdateStore(dataDir: () => Directory('${tempDir.path}/data'), publicKey: testPublicKey),
      installer: installer,
      fetchLatest: (_) => signedRelease(build: 26103001, version: '0.2.4'),
      isAndroid: android,
      isDemo: () => false,
      featureOn: () => true,
    );
    await tester.runAsync(() => checker.check());
    return checker;
  }

  Widget host(Widget card) => MaterialApp(home: Scaffold(body: Column(children: [card])));

  testWidgets('the offer: its version, Install and Later', (tester) async {
    final checker = await offering(tester);
    await tester.pumpWidget(host(AppUpdateCard(checker: checker, cartsEmpty: () async => true)));
    await tester.pumpAndSettle();
    expect(find.text('Version 0.2.4 is ready to install'), findsOneWidget);
    expect(find.text('Install'), findsOneWidget);
    expect(find.text('Later'), findsOneWidget);
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('app-update-card')), findsNothing);
  });

  testWidgets('no card on iOS (no offer)', (tester) async {
    final checker = await offering(tester, android: false);
    await tester.pumpWidget(host(AppUpdateCard(checker: checker, cartsEmpty: () async => true)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('app-update-card')), findsNothing);
  });

  testWidgets('a cart line hides the card', (tester) async {
    final checker = await offering(tester);
    await tester.pumpWidget(host(AppUpdateCard(checker: checker, cartsEmpty: () async => false)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('app-update-card')), findsNothing);
  });

  testWidgets('a cart line added during the download stops the hand-over', (tester) async {
    final checker = await offering(tester);
    var empty = true;
    final done = Completer<String>();
    await tester.pumpWidget(host(AppUpdateCard(
      checker: checker,
      cartsEmpty: () async => empty,
      prepare: (offer, app, progress, cancel) => done.future,
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Cancel'), findsOneWidget);
    empty = false; // a line is added while it downloads
    done.complete('/cache/updates/26103001.apk');
    await tester.pumpAndSettle();
    expect(installer.handedOver, isEmpty);
    expect(find.byKey(const ValueKey('app-update-card')), findsNothing);
  });

  testWidgets('with the carts still empty, the checked file is handed to the installer', (tester) async {
    final checker = await offering(tester);
    await tester.pumpWidget(host(AppUpdateCard(
      checker: checker,
      cartsEmpty: () async => true,
      prepare: (offer, app, progress, cancel) async => '/cache/updates/${offer.build}.apk',
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();
    expect(installer.handedOver, ['/cache/updates/26103001.apk']);
    expect(installer.hashes.single, ('ab12' * 16, 1000)); // the signed hash and size go along to Android
  });

  testWidgets('install unknown apps off: says so and opens the setting, installs nothing', (tester) async {
    installer.canInstall = false;
    final checker = await offering(tester);
    var prepared = 0;
    await tester.pumpWidget(host(AppUpdateCard(
      checker: checker,
      cartsEmpty: () async => true,
      prepare: (offer, app, progress, cancel) async {
        prepared++;
        return '/x';
      },
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();
    expect(find.text(installPermissionWords), findsOneWidget);
    expect(installer.settingsOpened, 1);
    expect(prepared, 0);
    expect(installer.handedOver, isEmpty);
  });

  testWidgets("a refused APK: 'This update can't be installed on this phone.' once", (tester) async {
    final checker = await offering(tester);
    await tester.pumpWidget(host(AppUpdateCard(
      checker: checker,
      cartsEmpty: () async => true,
      prepare: (offer, app, progress, cancel) async => throw const UpdateDownloadError(cantInstallWords, refused: true),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();
    expect(find.text(cantInstallWords), findsOneWidget);
    expect(checker.offer, isNull);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('app-update-card')), findsNothing);
  });

  testWidgets('download progress shows, and Cancel stops it with nothing handed over', (tester) async {
    final checker = await offering(tester);
    late void Function(int) tell;
    await tester.pumpWidget(host(AppUpdateCard(
      checker: checker,
      cartsEmpty: () async => true,
      prepare: (offer, app, progress, cancel) {
        tell = progress;
        return cancel.then<String>((_) => throw const UpdateDownloadError(downloadCancelledWords, cancelled: true));
      },
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install'));
    await tester.pump();
    await tester.pump();
    tell(500);
    await tester.pump();
    final bar = tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
    expect(bar.value, closeTo(500 / 1000, 1e-9));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(installer.handedOver, isEmpty);
    expect(find.text('Version 0.2.4 is ready to install'), findsOneWidget); // back to the offer
  });

  testWidgets('a failed download says so in fixed words and offers Install again', (tester) async {
    final checker = await offering(tester);
    await tester.pumpWidget(host(AppUpdateCard(
      checker: checker,
      cartsEmpty: () async => true,
      prepare: (offer, app, progress, cancel) async => throw const UpdateDownloadError(downloadFailedWords),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();
    expect(find.text(downloadFailedWords), findsOneWidget);
    expect(find.text('Install'), findsOneWidget);
  });

  testWidgets('a second tap on Install starts nothing more (review I1)', (tester) async {
    final checker = await offering(tester);
    var prepared = 0;
    final done = Completer<String>();
    await tester.pumpWidget(host(AppUpdateCard(
      checker: checker,
      cartsEmpty: () async => true,
      prepare: (offer, app, progress, cancel) {
        prepared++;
        return done.future;
      },
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install'));
    await tester.tap(find.text('Install')); // before anything was awaited
    await tester.pump();
    await tester.pump();
    expect(prepared, 1);
    done.complete('/cache/updates/26103001-a.apk');
    await tester.pumpAndSettle();
    expect(installer.handedOver, hasLength(1));
  });

  testWidgets('a card that is gone hands nothing over (review I2)', (tester) async {
    final checker = await offering(tester);
    final done = Completer<String>();
    await tester.pumpWidget(host(AppUpdateCard(
      checker: checker,
      cartsEmpty: () async => true,
      prepare: (offer, app, progress, cancel) => done.future,
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install'));
    await tester.pump();
    await tester.pump();
    await tester.pumpWidget(const SizedBox()); // the page is left while it downloads
    done.complete('/cache/updates/26103001-a.apk');
    await tester.pumpAndSettle();
    expect(installer.handedOver, isEmpty);
  });

  testWidgets("Android's refusal after the hand-over is shown in its words (review M4)", (tester) async {
    final checker = await offering(tester);
    await tester.pumpWidget(host(AppUpdateCard(
      checker: checker,
      cartsEmpty: () async => true,
      prepare: (offer, app, progress, cancel) async => '/cache/updates/26103001-a.apk',
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();
    expect(installer.handedOver, hasLength(1));
    installer.status = 'INSTALL_FAILED_INSUFFICIENT_STORAGE';
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('INSTALL_FAILED_INSUFFICIENT_STORAGE'), findsOneWidget);
  });

  testWidgets('a cart line added while Android copies the bytes stops the commit (review N3)', (tester) async {
    final checker = await offering(tester);
    var empty = true;
    installer.whileStaging = () => empty = false;
    await tester.pumpWidget(host(AppUpdateCard(
      checker: checker,
      cartsEmpty: () async => empty,
      prepare: (offer, app, progress, cancel) async => '/cache/updates/26103001-a.apk',
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();
    expect(installer.staged, hasLength(1));
    expect(installer.handedOver, isEmpty);
    expect(installer.abandoned, [1]);
    expect(find.byKey(const ValueKey('app-update-card')), findsNothing);
  });

  testWidgets("a staging refused by Android's side shows its words and commits nothing", (tester) async {
    final checker = await offering(tester);
    final refusing = _RefusingInstaller();
    final c = AppUpdateChecker(
      store: AppUpdateStore(dataDir: () => Directory('${tempDir.path}/data2'), publicKey: testPublicKey),
      installer: refusing,
      fetchLatest: (_) => signedRelease(build: 26103001, version: '0.2.4'),
      isAndroid: true,
      isDemo: () => false,
      featureOn: () => true,
    );
    await tester.runAsync(() => c.check());
    await tester.pumpWidget(host(AppUpdateCard(
      checker: c,
      cartsEmpty: () async => true,
      prepare: (offer, app, progress, cancel) async => '/cache/updates/26103001-a.apk',
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();
    expect(find.text('The downloaded update changed before it could be installed.'), findsOneWidget);
    expect(refusing.committed, 0);
    expect(checker.offer, isNotNull); // the other checker is untouched
  });

  group('the center home', () {
    final center = License(id: 231, licenseId: 'L-231', licenseName: 'Bendable Service Center', licenseType: 'ServiceCenter');

    Widget home(AppUpdateChecker checker, {required int draftCount}) => MaterialApp(
          home: CenterHomePage(
            center: center,
            buildMazama: () => const Scaffold(body: Text('mazama')),
            buildStock: () => const Scaffold(body: Text('stock')),
            buildCart: (onCount) {
              WidgetsBinding.instance.addPostFrameCallback((_) => onCount(draftCount));
              return const Scaffold(body: Text('cart'));
            },
            buildSales: () => const Scaffold(body: Text('sales')),
            buildUpdateCard: (n) => AppUpdateCard(checker: checker, cartsEmpty: () async => n == 0),
          ),
        );

    testWidgets('the card shows above the tabs with every cart empty', (tester) async {
      final checker = await offering(tester);
      await tester.pumpWidget(home(checker, draftCount: 0));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('app-update-card')), findsOneWidget);
      expect(find.text('Stock'), findsOneWidget);
    });

    testWidgets('a draft cart line hides it', (tester) async {
      final checker = await offering(tester);
      await tester.pumpWidget(home(checker, draftCount: 2));
      await tester.pumpAndSettle();
      expect(find.text('Cart (2)'), findsOneWidget);
      expect(find.byKey(const ValueKey('app-update-card')), findsNothing);
    });

    testWidgets('no card without a builder (tests, the demo)', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: CenterHomePage(
          center: center,
          buildMazama: () => const Scaffold(body: Text('mazama')),
          buildStock: () => const Scaffold(body: Text('stock')),
          buildCart: (onCount) => const Scaffold(body: Text('cart')),
          buildSales: () => const Scaffold(body: Text('sales')),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('app-update-card')), findsNothing);
    });
  });

  test('centerCartsEmpty: true with nothing kept', () async {
    expect(await centerCartsEmpty(231, dataDir: () => Directory('${tempDir.path}/data')), isTrue);
  });
}

class _RefusingInstaller extends _FakeInstaller {
  int committed = 0;

  @override
  Future<String> stage(String path, {required String sha256, required int size}) async =>
      'refused:The downloaded update changed before it could be installed.';

  @override
  Future<String> commit(int session) async {
    committed++;
    return 'started';
  }
}

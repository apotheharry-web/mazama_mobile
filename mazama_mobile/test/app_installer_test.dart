// specs/app-updates AU-R12, AU-R13: the Dart side of the `mazama/app_installer` channel (app_installer.dart), against
// a mock channel (AppInstaller.kt is Android's side).
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/app_installer.dart';

const _channel = MethodChannel('mazama/app_installer_test');
const _sig = 'aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  Object? Function(MethodCall call) answer = (_) => null;

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      final a = answer(call);
      if (a is PlatformException) throw a;
      return a;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
    answer = (_) => null;
  });

  final installer = AppInstaller(channel: _channel);

  test('the app channel is mazama/app_installer', () => expect(appInstallerChannel.name, 'mazama/app_installer'));

  test('installed maps the reply; malformed signers are dropped', () async {
    answer = (_) => {
          'versionName': '0.2.3',
          'versionCode': 26102901,
          'sdkInt': 34,
          'signers': [_sig, 'not hex', 7],
          'canInstall': true,
        };
    final app = await installer.installed();
    expect(calls.single.method, 'installed');
    expect([app.versionName, app.versionCode, app.sdkInt, app.signers, app.canInstall],
        ['0.2.3', 26102901, 34, {_sig}, true]);
  });

  test('a malformed installed reply is an error', () async {
    answer = (_) => {'versionName': '0.2.3'};
    expect(installer.installed(), throwsA(isA<AppInstallerError>()));
  });

  test('inspect sends the path and maps the reply', () async {
    answer = (_) => {'package': appPackageName, 'versionCode': 26103001, 'versionName': '0.2.4', 'signers': [_sig]};
    final info = await installer.inspect('/cache/updates/26103001.apk');
    expect(calls.single.method, 'inspect');
    expect(calls.single.arguments, {'path': '/cache/updates/26103001.apk'});
    expect([info.package, info.versionCode, info.versionName, info.signers], [appPackageName, 26103001, '0.2.4', {_sig}]);
  });

  test('stage sends the signed hash and size and answers staged:<id> or refused:<words>', () async {
    answer = (_) => 'staged:12';
    expect(await installer.stage('/p', sha256: 'ab' * 32, size: 7), 'staged:12');
    expect(calls.last.method, 'stage');
    expect(calls.last.arguments, {'path': '/p', 'sha256': 'ab' * 32, 'size': 7}); // Android hashes the bytes it copies
    answer = (_) => 'refused:Android said no';
    expect(await installer.stage('/p', sha256: 'ab' * 32, size: 7), 'refused:Android said no');
    for (final odd in ['started', 'staged:', 'staged:x', 'maybe']) {
      answer = (_) => odd;
      await expectLater(installer.stage('/p', sha256: 'ab' * 32, size: 7), throwsA(isA<AppInstallerError>()), reason: odd);
    }
  });

  test('commit answers started or refused:<words>; abandon never throws', () async {
    answer = (_) => 'started';
    expect(await installer.commit(12), 'started');
    expect(calls.last.method, 'commit');
    expect(calls.last.arguments, {'session': 12});
    answer = (_) => 'refused:no';
    expect(await installer.commit(12), 'refused:no');
    answer = (_) => 'staged:1';
    await expectLater(installer.commit(12), throwsA(isA<AppInstallerError>()));
    answer = (_) => PlatformException(code: 'failed');
    await installer.abandon(12);
    expect(calls.last.method, 'abandon');
    expect(calls.last.arguments, {'session': 12});
  });

  test('openInstallSettings calls through', () async {
    await installer.openInstallSettings();
    expect(calls.single.method, 'openInstallSettings');
  });

  test('a PlatformException becomes fixed words', () async {
    answer = (_) => PlatformException(code: 'failed', message: 'java.lang.SecurityException: secret detail');
    for (final call in [installer.installed, () => installer.inspect('/p'),
      () => installer.stage('/p', sha256: 'ab' * 32, size: 7), () => installer.commit(1),
      installer.openInstallSettings]) {
      try {
        await call();
        fail('expected an AppInstallerError');
      } on AppInstallerError catch (e) {
        expect(e.message, isNot(contains('secret')));
      }
    }
  });

  test('no channel at all (not Android) is fixed words', () async {
    final none = AppInstaller(channel: const MethodChannel('mazama/no_such_channel'));
    await expectLater(none.installed(), throwsA(isA<AppInstallerError>()));
  });

  test("takeStatus gives Android's words once, and null on anything else", () async {
    answer = (_) => 'INSTALL_FAILED_CONFLICTING_PROVIDER';
    expect(await installer.takeStatus(), 'INSTALL_FAILED_CONFLICTING_PROVIDER');
    expect(calls.last.method, 'takeStatus');
    answer = (_) => null;
    expect(await installer.takeStatus(), isNull);
    answer = (_) => PlatformException(code: 'failed');
    expect(await installer.takeStatus(), isNull);
  });
}

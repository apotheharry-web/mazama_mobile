import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/server_link.dart';
import 'package:mazama_mobile/session_store.dart';

/// Call at the top of a test file's `main()` when the code under test can reach a store through its default data
/// folder (CartPage's default stores, the app's server link, the device id): for each test the default folder
/// ([defaultSessionDataDir]) and the app's server link are a fresh temp folder, put back afterwards. Without it
/// those tests write `mazama.db` and friends into the real `~/.local/share/mazama_mobile`, sharing state across
/// files, runs and (in CI's bundle) the one isolate. There is no guard test; the
/// way to find a leak is to run a test file with `XDG_DATA_HOME` pointed at an empty folder and look inside.
void useTempAppDataDir() {
  late Directory dir;
  late ServerLink link;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('mazama_app_data_');
    setAppDataDirForTest(dir);
    link = ServerLink.standard(dataDir: () => dir, rememberOffline: false);
    useServerLink(link);
  });
  tearDown(() {
    releaseServerLink(link);
    try {
      link.dispose();
    } catch (_) {}
    setAppDataDirForTest(null);
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });
}

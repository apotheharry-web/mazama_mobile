// What every manufacturer /p/ route of Mazama's server shares on the phone (specs/manufacturer-phone MP-D3): the
// pair the owner approves for a manufacturer, the worker's email and this install's id, sent on a read as the
// X-Worker-Email and X-Device-Id headers (a write carries them in its JSON body as workerEmail and deviceId), and the
// error a manufacturer request fails with. A pair the owner has not approved is refused with 403 and the server's own
// words, shown to the worker as they are.
import 'device_id.dart';
import 'server_error.dart';
import 'session.dart';
import 'session_store.dart';

/// The worker signed in on this phone and this install's id: the pair a manufacturer route answers only once the
/// owner has approved it.
class DeviceIdentity {
  const DeviceIdentity({required this.workerEmail, required this.deviceId});

  final String workerEmail;
  final String deviceId;
}

/// Where a manufacturer request's pair comes from, asked for each request ([appIdentity] in the app; a fixed pair in
/// tests).
typedef DeviceIdentitySource = Future<DeviceIdentity> Function();

/// The headers a manufacturer read carries its pair in.
Map<String, String> manufacturerHeaders(DeviceIdentity identity) =>
    {'X-Worker-Email': identity.workerEmail, 'X-Device-Id': identity.deviceId};

/// A manufacturer request that failed; [message] is the server's own `detail` when it sent one (the 403's "This
/// phone isn't approved for &lt;name&gt; yet.", the 404's "No such manufacturer."). [unreachable]: the server couldn't be
/// reached (server_error.dart's rule).
class ManufacturerError extends ServerFailure {
  ManufacturerError(super.message, {super.status, super.unreachable});
}

/// The app's pair: the email of the session saved on this phone and this install's id (device_id.dart), each from
/// its store in the app's own folder unless [sessions] or [devices] is given. Throws [ManufacturerError] when no
/// session is saved: nothing is sent without a worker to name.
Future<DeviceIdentity> appIdentity({SessionStore? sessions, DeviceIdStore? devices}) async {
  final session = Session.fromJson(await (sessions ?? const SessionStore()).load());
  final email = session?.email.trim() ?? '';
  if (email.isEmpty) throw ManufacturerError('No one is signed in on this phone - sign in again.');
  return DeviceIdentity(workerEmail: email, deviceId: await (devices ?? const DeviceIdStore()).idOrCreate());
}

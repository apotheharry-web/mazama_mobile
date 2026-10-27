// Finds which service center(s) (and manufacturer licenses, though this app only cares about the former) the
// signed-in worker's own state-system account can act for - confirmed from a real captured HAR: right after
// login, the state's own portal calls this exact endpoint with the bearer token to learn which "license"
// entries (a ServiceCenter or a Manufacturer, each with its own state-system id) that account has access to,
// then lets the worker switch between them. That `id` is the same serviceCenterId/state_id that
// packages_client.dart's /p/packages/{state_id} and selling.dart's buildSale (via item.serviceCenterId) need -
// so the app asks the real state system for it directly, the same way its own portal does, rather than
// Mazama's server trying to know it on the app's behalf. One account can have more than one ServiceCenter
// license (seen in the real capture: three, for one login) - a worker whose account only has one never sees a
// picker; a worker whose account has several does.
//
// Runs state_client.dart's fetchStateFlow with the applicable_licenses flow from ../../mazama_modules/flows/state_reads.yaml
// rather than its own hand-rolled GET - the same request shape as before (Authorization, Accept, Referer,
// Origin; confirmed against a real captured HAR), now coming from the one spec mazama_sales' state/client.py
// also runs. See state_client.dart's own file comment for why a 401 here isn't retried the way
// StateSession.get() retries one.
import 'package:http/http.dart' as http;

import 'state_client.dart';
import 'state_records.dart';

class LicensesError implements Exception {
  final String message;
  LicensesError(this.message);
  @override
  String toString() => message;
}

const _serviceCenter = 'ServiceCenter';
const _manufacturer = 'Manufacturer';

class License {
  final int id;
  final String licenseId;
  final String licenseName;
  final String licenseType; // "ServiceCenter" or "Manufacturer"

  License({required this.id, required this.licenseId, required this.licenseName, required this.licenseType});

  bool get isServiceCenter => licenseType == _serviceCenter;
  bool get isManufacturer => licenseType == _manufacturer;

  /// Tolerant of the state's odd values, as the server is (SM-21): an id that isn't a whole number becomes 0
  /// (never a center, see [serviceCenters]); names and license ids are trimmed.
  factory License.fromJson(Map<String, Object?> j) => License(
        id: wholeNumber(j['id']) ?? 0,
        licenseId: textOrNull(j['licenseId']) ?? '',
        licenseName: textOrNull(j['licenseName']) ?? '',
        licenseType: j['licenseType'] is String ? j['licenseType'] as String : '',
      );
}

/// Every entry of a GetApplicableLicenses answer that is an object, as a [License]; anything else is skipped.
List<License> licensesFromJson(List<Object?> body) => [
      for (final e in body)
        if (e is Map) License.fromJson(Map<String, Object?>.from(e))
    ];

/// The service centers in [licenses], by the server's own rule (directory.service_centers, SM-21): licenseType
/// exactly ServiceCenter, an id above 0, the first entry for an id, and a blank name shown as "Service center <id>".
List<License> serviceCenters(Iterable<License> licenses) {
  final seen = <int>{};
  final out = <License>[];
  for (final l in licenses) {
    if (!l.isServiceCenter || l.id <= 0 || !seen.add(l.id)) continue;
    out.add(l.licenseName.isEmpty
        ? License(id: l.id, licenseId: l.licenseId, licenseName: 'Service center ${l.id}', licenseType: l.licenseType)
        : l);
  }
  return out;
}

/// GETs the real state system's GetApplicableLicenses with [accessToken] (from login.yaml/renew) and returns
/// every license the signed-in account can act for. Pass it to [serviceCenters] for the ids
/// packages_client.dart/selling.dart need - most accounts will have exactly one; some, as seen in a real
/// capture, have several and need the worker to pick.
Future<List<License>> fetchApplicableLicenses(String accessToken, {http.Client? client}) async {
  Object? body;
  try {
    body = await fetchStateFlow('applicable_licenses', const {}, accessToken: accessToken, client: client);
  } on StateReadError catch (ex) {
    throw LicensesError(ex.message);
  }
  if (body is! List) {
    throw LicensesError('the state system did not answer with JSON');
  }
  return licensesFromJson(body);
}

// A direct call to the real Oregon state system's own GetPackagedProducts, bypassing Mazama's server entirely -
// the emergency fallback for when Mazama's own /p/packages/{state_id} (packages_client.dart) can't be reached
// at all, not just a slow or flaky request. The worker is ALREADY signed in to the state system directly for
// selling (session.dart/selling.dart) - this reuses that exact same access token and header shape
// (licenses_client.dart's own fetchApplicableLicenses, itself mirroring StateSession.get() in
// mazama_sales/src/mazama_sales/state/client.py) to read the one other thing a center's own login can see:
// its current packaged products (mazama_sales' state/client.py's own packaged_products('center', state_id) ->
// GetPackagedProducts/{state_id}/ServiceCenter, confirmed from client.py's DATASETS/fetch and _who()).
//
// IMPORTANT - this is a DEGRADED view, not a substitute for Mazama's own enrichment:
//   - strain is only the one written in the package's name (product_names.dart: the shared core reads it the way
//     the server's names.py does, with the built-in spellings; '' when the name has none). The server's
//     strain (web/stock_pages.py's public_packages) can also come from its certificate folder and the Strains
//     page's own spellings (stockdata.py's strain_of/canonical) - data this phone can't see from the state alone.
//   - tpeMg is only ceil(weightPerUnit x analyteWeight) - the state's own raw potency figure, with no chance to
//     use a COA's own (possibly higher) TPE reading the way stockdata.py's mg_of does when Mazama's own sync
//     has one on file. In the ordinary case (no COA override needed) this is the exact same number; the one
//     case it can read LOW is a package whose only known-good potency comes from a lab result that hasn't
//     reached the state system's own analyteWeight field yet - worth knowing about if this screen's numbers
//     ever look suspiciously low during an outage, but not something this endpoint alone can fix.
// Both gaps are a direct, documented trade for working at all when Mazama's server is unreachable - resilient_
// inventory.dart's own file comment explains how this fits into the three-tier fallback, and
// stock_page.dart/cart_page.dart mark a result that came from here so a worker is never shown a confident-
// looking number without knowing what it is: unless figures kept on the phone fill it in (enrichment_store.dart), a
// package from here is shown as "mg psilocybin", never "mg TPE" (SM-D31, Package.mgFigure).
//
// Runs state_client.dart's fetchStateFlow with the packaged_products flow from ../../mazama_modules/flows/state_reads.yaml
// rather than its own hand-rolled GET - the same request shape as before, now coming from the one spec
// mazama_sales' state/client.py also runs. See state_client.dart's own file comment for why a 401 here isn't
// retried the way StateSession.get() retries one.
import 'package:http/http.dart' as http;

import 'dose.dart';
import 'mazama_core.dart';
import 'package_ids.dart';
import 'packages_client.dart';
import 'product_names.dart';
import 'sellability.dart';
import 'state_records.dart';
import 'state_client.dart';

class StatePackagesError implements Exception {
  final String message;
  StatePackagesError(this.message);
  @override
  String toString() => message;
}

/// GETs GetPackagedProducts/{stateId}/ServiceCenter directly against the real state system and returns the
/// RAW records exactly as the state answered them - no mapping into [Package] at all. This is what
/// inventory_upload_client.dart's uploadInventorySnapshot posts straight back to mazama_sales' own
/// POST /p/inventory/{stateId} (item 3a): that endpoint's own mapper (mazama_sales' state/mapping.py,
/// reused via sync.run_sync) expects exactly this shape, the same one fetchPackagesFromState below already
/// reads fields out of - sending the SAME records, unreshaped, means this app never has to keep its own
/// re-encoding of the state's wire format in sync with the server's.
Future<List<Object?>> fetchRawPackagesFromState(int stateId, {required String accessToken, http.Client? client}) async {
  Object? body;
  try {
    body = await fetchStateFlow('packaged_products', {'state_id': stateId, 'holder': 'ServiceCenter'},
        accessToken: accessToken, client: client);
  } on StateReadError catch (ex) {
    throw StatePackagesError(ex.message);
  }
  if (body is! List) {
    throw StatePackagesError('the state system did not answer with JSON');
  }
  return body;
}

/// The pure mapping step fetchPackagesFromState below runs right after fetchRawPackagesFromState - split out
/// so a caller that already has the raw records (merged_inventory.dart's fetchMergedInventory, which also
/// needs them unmapped for inventory_upload_client.dart's uploadInventorySnapshot) can map them without a
/// second network round trip.
///
/// [core] reads each name's strain (SM-19); it defaults to this app's ([MazamaCore.instance]).
List<Package> mapRawPackagesFromState(List<Object?> body, {CoreFunctions? core}) {
  final reader = core ?? MazamaCore.instance;
  final out = <Package>[];
  for (final e in body) {
    if (e is! Map) continue;
    final r = Map<String, Object?>.from(e);
    // SM-21: a record the server's own mapping skips (no whole-number id, no PKPR) is skipped here too.
    final key = packagedProductKey(r);
    // SM-10: the server's own sale rule (sellability.dart), the same one /p/packages applies on the normal path -
    // not just "in stock": a locked, flagged or pending-transfer package is left out too.
    if (key == null || !isSellable(r)) continue;
    final weightPerUnit = (r['weightPerUnit'] as num?)?.toDouble() ?? 0;
    final analyteWeight = (r['analyteWeight'] as num?)?.toDouble() ?? 0;
    // The state's own wire shape carries the batch/lot id this package was made from - free with this response,
    // no extra round trip (see coa_data_client.dart's own file comment on why the adhoc-COA flow needs it). Only
    // an id the server accepts counts (SM-09, the same rule as its stockdata.product_source): anything else would
    // just be refused by /p/coa-data/parse.
    final lotGuid = packageSource(r);
    out.add(Package(
      productGuid: key.pkpr,
      productType: r['productType'] as String? ?? '',
      id: key.stateId,
      strain: strainFromName(r['description'] as String?, reader),
      weightPerUnit: weightPerUnit,
      analyteWeight: analyteWeight,
      tpeMg: unitTpeMg(weightPerUnit, analyteWeight, null) ?? 0, // SM-04: the state's figure, rounded up (dose.dart)
      quantity: (r['quantity'] as num?)?.toInt() ?? 0,
      exactQuantity: r['quantity'] is num ? r['quantity'] as num : null,
      lotGuid: lotGuid,
    ));
  }
  return out;
}

/// Maps fetchRawPackagesFromState's result into plain [Package]s - strain from the name only, tpeMg a
/// ceil(weightPerUnit x analyteWeight) estimate, see this file's own comment for why. Throws
/// [StatePackagesError] on anything but a clean 200 JSON list, the same shape licenses_client.dart's
/// fetchApplicableLicenses already throws on.
Future<List<Package>> fetchPackagesFromState(int stateId, {required String accessToken, http.Client? client}) async {
  return mapRawPackagesFromState(await fetchRawPackagesFromState(stateId, accessToken: accessToken, client: client));
}

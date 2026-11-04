// A plain, unauthenticated GET against the Mazama server's own public endpoint - not a shared/flows/*.yaml spec,
// because there's no multi-step choreography here worth replaying identically in two languages, just "fetch
// some JSON" (see src/mazama_sales/web/stock_pages.py's public_packages route, server-side: "just enough for a
// phone app to match a scanned label and build a sale - no login, no quantity, nothing a worker's own
// state-system session wouldn't already show on the label itself"). The app never authenticates as a worker
// with the server - it only ever sends the whole-app shared secret every /p/ call sends (see
// app_api_key.dart), never a per-worker credential.
import 'package:http/http.dart' as http;

import 'api_contract.g.dart';
import 'mazama_core.dart';
import 'server_request.dart';
import 'stock_summary.dart';

class PackagesError implements Exception {
  final String message;

  /// The server's HTTP status when it answered (404: no such service center there), null when it couldn't be reached.
  final int? status;
  PackagesError(this.message, {this.status});
  @override
  String toString() => message;
}

/// Which figure a package's [Package.tpeMg] is: its mg TPE (the server's, or one kept on the phone, from the
/// server or from the phone's own mazama_core reading of the lab report), or - for a package read from the state system
/// with neither - only the state's psilocybin (weightPerUnit x analyteWeight, rounded up), which the screens must call
/// "mg psilocybin", never "mg TPE".
enum MgFigure { tpe, psilocybin }

/// How a screen names [f]: "mg TPE" or "mg psilocybin".
String mgFigureLabel(MgFigure f) => f == MgFigure.psilocybin ? 'mg psilocybin' : 'mg TPE';

/// Where the figures filled into a state-system read came from (sync/enrichment.dart): Mazama's server's last answer
/// for the package, or this phone's own mazama_core reading of the package's lab report (phone_label.dart).
enum EnrichmentSource { server, phone }

/// One row of /p/packages/{state_id}: a packaged product this service center can sell, matched by its state
/// system productGuid (the same id a scanned label shows). No price - that's typed on-device (see pricing.dart).
/// quantity is the mirror's own count as of the server's last sync (same figure /c/{slug}/inventory shows) -
/// a quick sanity check against what the worker's physical count says, not the source of truth at the moment
/// of sale: the worker's own state-system session (and the packages actually in front of them) still decides
/// what really gets sold.
///
/// analyteWeight is the state system's own raw field - mg PER GRAM of psilocybin potency (a concentration), NOT
/// a per-unit dose - kept here only because buildSale (selling.dart) sends it verbatim as part of a real sale
/// record's payload, field-for-field the same as the real web app. It must never be shown to a worker as "mg
/// TPE" on its own, and must never be the figure a per-mg price is multiplied against - that's tpeMg's job: the
/// server's own mazama_sales/src/mazama_sales/stock/stockdata.py Stock.mg_of (weightPerUnit x the best known
/// potency), rounded UP to the nearest whole mg, is this package's real per-unit dose. strain is this package's
/// canonical strain name ('' when the server couldn't determine one).
class Package {
  final String productGuid;
  final String productType;
  final int id;
  final double weightPerUnit;
  final double analyteWeight;
  final String strain;
  final int tpeMg;

  /// Whole units, for the cart and the sale (a fraction is dropped). The stock page counts [exactQuantity].
  final int quantity;

  /// The quantity exactly as the server or the state sent it (a number, not always whole), as the server's stock
  /// pages count it; [quantity] when it wasn't given.
  num get exactQuantity => _exactQuantity ?? quantity;
  final num? _exactQuantity;

  /// The batch/lot id this package was made from (HB-/PL-...), when known - the adhoc-COA flow's own lookup key
  /// (coa_data_client.dart's fetchCoaDataBatch/uploadCoaParse) for an unconfigured center's packages. Mazama's
  /// own /p/packages/{state_id} doesn't send these today (display-only fields like strain/tpeMg already stand
  /// in for whatever a batch/lot id would tell a worker there), but the state system's raw GetPackagedProducts
  /// reply always carries them (see state_packages_client.dart's fetchPackagesFromState) - the same place that
  /// worker's own sync populated packaged_product's columns from in the first place.
  final String? lotGuid;

  /// Whether mazama_sales already has, respectively, a certificate and a compact label on file for this lot's
  /// own PKPR - the server's own coaAvailable/labelAvailable fields (web/stock_pages.py's public_packages),
  /// added once mazama_sales stopped auto-syncing every 12 hours: CartPage reads these (see its own
  /// _ensureCoaForCartLine) to decide, right when a line is added to the cart, whether it needs to go find and
  /// submit this lot's own lab report itself (coa_data_client.dart's uploadCoaParse - the SAME "already built
  /// function" the adhoc flow for an unconfigured center already uses) rather than waiting for a worker to
  /// notice later. Default true/true (never false-flag an older cached Package, written before these fields
  /// existed, as needing work it may already be done for) - callers that actually care always come from a
  /// fresh server response, where these are always present.
  final bool coaAvailable;
  final bool labelAvailable;

  /// This record's expiry date (/p/packages' `expires`: the date in its name, else its certificate's date + shelf
  /// life), or null when not known - a reply without it, or a package read straight from the state system.
  /// A sale draws from the record that expires first ([drawOrder]).
  final DateTime? expires;

  /// Made by Mazama as the server decides it (Stock.made_by_us), expired as of the server's
  /// today, the exact mg TPE of one unit the charts use (null when unknown; tpeMg is the rounded-up dose),
  /// and the product's name, which carries its serving size. False / null / '' when the server doesn't send them.
  final bool mazama;
  final bool expired;
  final double? unitMgTpe;
  final String description;

  /// The kind code the server's charts read for it (FD, DH, HG, CH, GM, HN, ...; '' unknown): what makes it an edible,
  /// counted under its product. null when the server doesn't send it: the stock rules read it from the name.
  final String? type;

  /// Set only on a package read straight from the state system (lib/sync/center_stock.dart) whose strain, tpeMg
  /// and expires were filled in from what Mazama's server last sent for this very package (sync/enrichment.dart):
  /// when that server answer was received. Null everywhere else, including on every row the server itself sends.
  final DateTime? enrichedAt;

  /// Who [enrichedAt]'s figures came from: Mazama's server, or this phone's reading of the lab report. Null
  /// when [enrichedAt] is.
  final EnrichmentSource? enrichedBy;

  /// True only on a package read straight from the state system that could NOT be filled in from figures kept on the
  /// phone (sync/enrichment.dart): its strain is only what its name says and its tpeMg is only the state's psilocybin
  /// (state_packages_client.dart), which the screens call mg psilocybin ([mgFigure]). False everywhere else.
  final bool stateEstimate;

  /// Which figure [tpeMg] is: only the state's psilocybin for a [stateEstimate] package, its mg TPE otherwise.
  MgFigure get mgFigure => stateEstimate ? MgFigure.psilocybin : MgFigure.tpe;

  /// True only on a record only the state listed, in a read where Mazama's server answered and
  /// joined another record of the same product (sync/stock_merge.dart). Its [tpeMg] is only the state's psilocybin, but
  /// it is not a [stateEstimate]: its product is shown and priced by its first lot's figure (its cap counts the lots a
  /// sale draws, each its own figures), and only notes these units and their own figure ([PkprGroup.stateOnlyNote]).
  final bool stateOnly;

  /// Mazama_core's LabelInput for this record as the server builds it for its own labels (/p/packages'
  /// `labelInput`), without `today`. phone_label.dart draws the label from it with no call to the state system. Null when
  /// the server has no certificate for the lot, when the server doesn't send it, and for a record only the state system sent.
  final Map<String, Object?>? labelInput;

  /// False only on a row /p/packages marks unconfirmed - its figures are only an approved
  /// phone's upload, which the server's own sync hasn't seen. Before a sale the phone reads every lot the sale draws from
  /// the state again whenever any of them is unconfirmed, whatever the age of its stock. True everywhere else (a state
  /// read, a reply without it).
  final bool confirmed;

  /// What a sale record copies of this record (productGuid, productType, id, weightPerUnit,
  /// analyteWeight), exactly as it was received - a whole-number weight stays 1, never 1.0, and a value that is missing
  /// stays missing, so the core refuses the sale instead of sending "" or 0. Kept through CartStore ('sale');
  /// a saved draft without it has its typed values used instead ([toSaleItem]).
  final Map<String, Object?>? saleValues;

  Package({
    required this.productGuid,
    required this.productType,
    required this.id,
    required this.weightPerUnit,
    required this.analyteWeight,
    this.strain = '',
    this.tpeMg = 0,
    this.quantity = 0,
    num? exactQuantity,
    this.lotGuid,
    this.coaAvailable = true,
    this.labelAvailable = true,
    this.expires,
    this.mazama = false,
    this.expired = false,
    this.unitMgTpe,
    this.description = '',
    this.type,
    this.enrichedAt,
    EnrichmentSource? enrichedBy,
    this.stateEstimate = false,
    this.stateOnly = false,
    this.labelInput,
    this.confirmed = true,
    this.saleValues,
  })  : _exactQuantity = exactQuantity,
        enrichedBy = enrichedAt == null ? null : (enrichedBy ?? EnrichmentSource.server);

  factory Package.fromJson(Map<String, Object?> j) => Package(
        productGuid: j['productGuid'] as String? ?? '',
        productType: j['productType'] as String? ?? '',
        id: (j['id'] as num?)?.toInt() ?? 0,
        weightPerUnit: (j['weightPerUnit'] as num?)?.toDouble() ?? 0,
        analyteWeight: (j['analyteWeight'] as num?)?.toDouble() ?? 0,
        strain: j['strain'] as String? ?? '',
        tpeMg: (j['tpeMg'] as num?)?.toInt() ?? 0,
        quantity: (j['quantity'] as num?)?.toInt() ?? 0,
        exactQuantity: j['quantity'] as num?,
        lotGuid: j['lotGuid'] as String?,
        coaAvailable: j['coaAvailable'] as bool? ?? true,
        labelAvailable: j['labelAvailable'] as bool? ?? true,
        expires: _dateOrNull(j['expires']),
        mazama: j['mazama'] == true,
        expired: j['expired'] == true,
        unitMgTpe: (j['unitMgTpe'] as num?)?.toDouble(),
        description: j['description'] as String? ?? '',
        type: j['type'] as String?,
        enrichedAt: j['enrichedAtMs'] is num
            ? DateTime.fromMillisecondsSinceEpoch((j['enrichedAtMs'] as num).toInt(), isUtc: true)
            : null,
        enrichedBy: j['enrichedBy'] == 'phone' ? EnrichmentSource.phone : null,
        stateEstimate: j['stateEstimate'] == true,
        stateOnly: j['stateOnly'] == true,
        labelInput: j['labelInput'] is Map ? Map<String, Object?>.from(j['labelInput'] as Map) : null,
        confirmed: j['confirmed'] != false,
        saleValues: j['sale'] is Map ? Map<String, Object?>.from(j['sale'] as Map) : saleValuesOf(j),
      );

  /// This package as the stock rules see it (stock_summary.dart): the server's own figures.
  StockRow toStockRow() => StockRow(
        productGuid: productGuid,
        id: id,
        quantity: exactQuantity,
        mazama: mazama,
        expired: expired,
        strain: strain,
        description: description,
        unitMgTpe: unitMgTpe,
        weightPerUnit: weightPerUnit,
        analyteWeight: analyteWeight,
        type: type,
      );

  /// The shape buildSale (selling.dart) expects as its `item` argument - exactly the fields a real sale record
  /// needs (the state system's own wire shape), so strain/tpeMg (this app's own display-only additions) are
  /// deliberately left out, same as quantity already was.
  Map<String, Object?> toSaleItem() => saleValues != null
      ? Map<String, Object?>.from(saleValues!)
      : {
          'productGuid': productGuid,
          'productType': productType,
          'id': id,
          'weightPerUnit': weightPerUnit,
          'analyteWeight': analyteWeight,
        };

  /// The exact inverse of fromJson, including `quantity` (toSaleItem above deliberately leaves that out - this
  /// one doesn't, since it's meant to round-trip through CartStore, not describe a sale record). Not the same
  /// shape the server's /p/packages/{state_id} itself returns by coincidence - it's reusing that shape on
  /// purpose, so a package written here reads back through the same fromJson used for the real server response.
  Map<String, Object?> toJson() => {
        'productGuid': productGuid,
        'productType': productType,
        'id': id,
        'weightPerUnit': weightPerUnit,
        'analyteWeight': analyteWeight,
        'strain': strain,
        'tpeMg': tpeMg,
        'quantity': exactQuantity,
        if (lotGuid != null) 'lotGuid': lotGuid,
        'coaAvailable': coaAvailable,
        'labelAvailable': labelAvailable,
        if (expires != null) 'expires': _dayText(expires!),
        'mazama': mazama,
        'expired': expired,
        'unitMgTpe': unitMgTpe,
        'description': description,
        if (type != null) 'type': type,
        // Provenance of a state-only read (sync/enrichment.dart), kept so a cached copy still says where its strain
        // and TPE came from. Never sent by the server; written only when set.
        if (enrichedAt != null) 'enrichedAtMs': enrichedAt!.millisecondsSinceEpoch,
        if (enrichedAt != null && enrichedBy == EnrichmentSource.phone) 'enrichedBy': 'phone',
        if (stateEstimate) 'stateEstimate': true,
        if (stateOnly) 'stateOnly': true,
        if (labelInput != null) 'labelInput': labelInput,
        if (!confirmed) 'confirmed': false,
        if (saleValues != null) 'sale': saleValues,
      };
}

/// What a sale record copies of a state record, as received: only the keys it has.
const saleKeys = ['productGuid', 'productType', 'id', 'weightPerUnit', 'analyteWeight'];

/// [r]'s [saleKeys], exactly as they are in it.
Map<String, Object?> saleValuesOf(Map<Object?, Object?> r) => {
      for (final k in saleKeys)
        if (r.containsKey(k)) k: r[k],
    };

/// GETs [apiBaseUrl]/p/packages/{stateId} (routes.yaml) and returns this service center's current
/// packaged products. Throws PackagesError on anything but a clean 200 JSON list - including a 404 (no such
/// service center), which is the server's answer for a wrong/unconfigured stateId, not a network problem.
Future<List<Package>> fetchPackages(int stateId, {String baseUrl = apiBaseUrl, http.Client? client}) =>
    serverRequest('$baseUrl${packagesPath(stateId)}',
        error: _packagesError, ok: (status) => status == 200 || status == 404, client: client, read: (resp) {
      if (resp.statusCode == 404) throw PackagesError('no service center with id $stateId', status: 404);
      final list = serverJson(resp, _packagesError) as List<Object?>;
      return list.map((e) => Package.fromJson(e as Map<String, Object?>)).toList();
    });

// A PackagesError keeps only the status: it says nothing of its own about the server being unreachable.
PackagesError _packagesError(String message, {int? status, bool unreachable = false}) =>
    PackagesError(message, status: status);

/// One PKPR as a worker should ever see it. /p/packages/{stateId} sends one row per underlying state-system
/// lot/transfer (see mazama_sales' public_packages docstring - its own "shared id" tag on /c/{slug}/inventory
/// is the server-side view of the same thing) - several rows can share the same productGuid when a center has
/// more than one lot of it on hand. This merges those into the one view every screen in this app actually
/// shows: a single quantity, added up across every lot. `lots` (kept sorted ascending by quantity) exists only
/// so a sale can be split across them when one line's own quantity needs more than the smallest lot alone has -
/// see mazama_mobile's cart_page.dart. Nothing in this app's UI ever shows a lot's own id or quantity by
/// itself, only a group's merged productGuid/productType/quantity - a lot is bookkeeping, not something a
/// worker picking a PKPR off a label needs to know exists.
DateTime? _dateOrNull(Object? v) {
  if (v is! String) return null;
  final d = DateTime.tryParse(v);
  return d == null ? null : DateTime(d.year, d.month, d.day);
}

String _dayText(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// The records ("lots") of one product in the order a sale draws units from them: a lot only the state
/// lists ([Package.stateOnly], which the server's rows never are) after every lot with a server figure, so a product's
/// figure ([PkprGroup.tpeMg]), price and dose cap are always its lab lot's ("lab lot first");
/// then the earliest [Package.expires], a lot with no known date after every dated one, the fewer units, the lower id.
/// The shared core's rule (mazama_core::selling::cart::allocate), the server's selling.draw_order
/// too; held to assets/shared/selling/vectors/allocate.json and pricing_cases.json (test/lot_draw_vectors_test.dart).
/// Throws StateError when the core can't order them (it can't be sold from a list it couldn't order).
List<Package> drawOrder(List<Package> lots, {CoreFunctions? core}) {
  final got = _draw(lots, 0, core);
  if (got == null) throw StateError("mazama_core couldn't order these lots");
  return [for (final i in got.order) lots[i]];
}

/// [qty] units drawn from [lots] in [drawOrder]: (lot, units from it) for each lot that gives any, or null when the lots
/// hold fewer than [qty] - refused, never put on the last lot (the core's allocate) - or when the core can't answer.
List<(Package, int)>? allocateLots(List<Package> lots, int qty, {CoreFunctions? core}) => _draw(lots, qty, core)?.takes;

/// The core's draw over [lots], by position in [lots]; null when it can't answer or answers in the wrong shape.
({List<int> order, List<(Package, int)>? takes})? _draw(List<Package> lots, int qty, CoreFunctions? core) {
  try {
    final reply = (core ?? MazamaCore.instance).sellingAllocate({
      'lots': [
        for (final l in lots)
          {'id': l.id, 'quantity': l.quantity, 'expires': l.expires == null ? null : _dayText(l.expires!), 'state_only': l.stateOnly},
      ],
      'qty': qty,
    });
    final positions = reply['positions'];
    if (positions is! List || positions.length != lots.length || positions.any((i) => i is! int || i < 0 || i >= lots.length) ||
        positions.toSet().length != lots.length) {
      return null;
    }
    final order = List<int>.from(positions);
    final takes = reply['takes'];
    final at = reply['take_positions'];
    if (takes == null) return at == null ? (order: order, takes: null) : null;
    if (takes is! List || at is! List || takes.length != at.length) return null;
    final out = <(Package, int)>[];
    for (var k = 0; k < takes.length; k++) {
      final t = takes[k];
      final i = at[k];
      if (t is! List || t.length != 2 || i is! int || i < 0 || i >= lots.length || t[0] != lots[i].id) return null;
      final n = t[1];
      if (n is! int || n <= 0 || n > lots[i].quantity) return null;
      out.add((lots[i], n));
    }
    if (out.fold<int>(0, (a, x) => a + x.$2) != (qty < 0 ? 0 : qty)) return null;
    return (order: order, takes: out);
  } catch (_) {
    return null; // StateError (no core loaded), MazamaCoreError, or anything else
  }
}

class PkprGroup {
  /// The product's records, in [drawOrder]; as given when the core couldn't order them ([drawRefused]).
  final List<Package> lots;

  /// True when the shared core couldn't order this product's lots ([drawOrder] threw): the product is still listed, so
  /// one lot the core refuses never takes down a whole screen (the scan lookup, the autocomplete, the stock page), but
  /// it can't be sold - the cart refuses to add it, and its draw ([allocateLots], [allocateBulkSales]) refuses too.
  final bool drawRefused;

  factory PkprGroup(List<Package> lots) {
    try {
      return PkprGroup._(drawOrder(lots), false);
    } on StateError {
      return PkprGroup._(List<Package>.of(lots), true);
    }
  }

  PkprGroup._(this.lots, this.drawRefused) {
    if (lots.isEmpty) throw ArgumentError('a PkprGroup needs at least one lot');
  }

  String get productGuid => lots.first.productGuid;
  String get productType => lots.first.productType;
  double get weightPerUnit => lots.first.weightPerUnit;
  double get analyteWeight => lots.first.analyteWeight;
  String get strain => lots.first.strain;
  int get tpeMg => lots.first.tpeMg;

  /// The server's label input of the first record, in draw order, that has one (null when none has): what
  /// the phone draws this product's label from without its lab report.
  Map<String, Object?>? get labelInput {
    for (final l in lots) {
      if (l.labelInput != null) return l.labelInput;
    }
    return null;
  }

  /// Which figure [tpeMg] is: only the state's psilocybin when any lot's is (sync/enrichment.dart's
  /// applyEnrichment then leaves every lot of the product on the state's figures), mg TPE otherwise.
  MgFigure get mgFigure => lots.any((l) => l.mgFigure == MgFigure.psilocybin) ? MgFigure.psilocybin : MgFigure.tpe;

  /// "mg TPE" or "mg psilocybin" ([mgFigure]), for every screen that shows [tpeMg].
  String get mgLabel => mgFigureLabel(mgFigure);

  /// When some of this product's lots are known only by the state
  /// ([Package.stateOnly]), how many units they hold and their own figure, the state's psilocybin - "includes 2 unit(s)
  /// known only by the state: 6 mg psilocybin each" ("5 or 6 mg" when they differ). Null when there are none. A note
  /// only: [tpeMg] and the price stay the first lot's, which is never one of these ([drawOrder]); the dose cap counts
  /// whichever lots a sale draws, these included, each its own figures.
  String? get stateOnlyNote {
    final only = lots.where((l) => l.stateOnly).toList();
    if (only.isEmpty) return null;
    final units = only.fold<int>(0, (sum, l) => sum + l.quantity);
    final figures = (only.map((l) => l.tpeMg).toSet().toList()..sort()).join(' or ');
    return 'includes $units unit(s) known only by the state: $figures ${mgFigureLabel(MgFigure.psilocybin)} each';
  }

  int get quantity => lots.fold(0, (sum, l) => sum + l.quantity);

  /// Whether EVERY lot behind this PKPR already has a certificate/label on file - a sale can draw from more
  /// than one lot (see this class's own comment on why `lots` is kept), so this is the conservative answer:
  /// if even one lot backing this group still needs a COA, there is still work for CartPage to do for this
  /// PKPR, even though some other lot of it already has one.
  bool get coaAvailable => lots.every((l) => l.coaAvailable);
  bool get labelAvailable => lots.every((l) => l.labelAvailable);
}

/// Why a product whose lots the shared core couldn't order ([PkprGroup.drawRefused]) isn't sold.
String drawRefusedText(String productGuid) => "$productGuid can't be sold here: the shared core couldn't order its lots.";

/// Groups a /p/packages/{stateId} response by productGuid - see PkprGroup's own comment for why. Every group
/// in the result has at least one lot (an empty productGuid bucket can't happen: a row only ever contributes to
/// the bucket keyed by its own productGuid).
List<PkprGroup> groupByPkpr(List<Package> inventory) {
  final byGuid = <String, List<Package>>{};
  for (final p in inventory) {
    byGuid.putIfAbsent(p.productGuid, () => []).add(p);
  }
  return [for (final lots in byGuid.values) PkprGroup(lots)];
}

/// Grouped (groupByPkpr) and sorted by product type, then strain, then serving size (weightPerUnit)
/// decreasing - the one sort order every screen that lists a center's whole inventory uses (StockPage,
/// ReconcilePage), so a worker sees PKPRs in the exact same order wherever this inventory is shown, whatever
/// screen they're on.
List<PkprGroup> sortedPkprGroups(List<Package> inventory) {
  return groupByPkpr(inventory)..sort((a, b) {
      final byType = a.productType.compareTo(b.productType);
      if (byType != 0) return byType;
      final byStrain = a.strain.compareTo(b.strain);
      if (byStrain != 0) return byStrain;
      return b.weightPerUnit.compareTo(a.weightPerUnit);
    });
}

// What Mazama's server last said about each package it sent (strain, tpeMg, expires), kept on the device so that a
// later read straight from the state system (lib/sync/center_stock.dart: Mazama's server unreachable) can show
// the server's figures again instead of the state-only degraded ones (state_packages_client.dart) - but only for a
// package whose inputs have not changed since. Since specs/phone-sync phase 3 it is the sync engine's enrichment
// dataset (one copy, key '', the same JSON the document held) in the data folder's database, under
// session_store.dart's defaultSessionDataDir; the document an older build kept (enrichment.json) is moved there
// (sync_migration.dart's migrateStockCaches).
//
// What is kept, per package, and why only this:
//   - strain: the server's canonical name (its certificate folder and Strains page spellings), which the state alone
//     can't give. A property of the product, not of the center or the moment.
//   - tpeMg: the server's per-unit dose (stockdata.py mg_of, rounded up, SM-D17). Reused ONLY as the exact number the
//     server sent, never rescaled or worked out again on the phone (SM-D15), and only under the rule in
//     [applyEnrichment].
//   - expires: the date in the product's name, else its certificate's date + shelf life - what a sale draws the
//     earliest of first (SM-17, SM-D29). A property of the product record, not of its weight or potency.
//   - the inputs the server's tpeMg was worked out from: weightPerUnit and the state's analyteWeight as the server had
//     them (the server's own row, never the cart's merged row, whose weights are the state's fresher ones).
// Deliberately NOT kept: coaAvailable/labelAvailable (what the server's folders hold now - only the server can say, and
// acting on them needs the server anyway), expired (as of the server's today), quantity (the state's live count always
// wins), unitMgTpe/mazama/description/type (the stock charts' fields; the stock charts have their own offline path,
// stock_rows.dart).
//
// The phone's own reading of a lab report (SM-D31, amending SM-D15): whenever phone_label.dart draws a label from
// mazama_core's reading of the state's accepted potency report for a package's lot, the TPE mazama_core gave (LabelSpec
// tpe_mg_per_g: mazama_core::tpe to 2 places, the server's coa.tpe figure), the psilocin per unit, and the per-unit mg
// TPE = unit weight x that TPE rounded up (dose.dart's unitTpeMg, SM-D16/SM-D17 - the number /p/packages sends as
// tpeMg, never the label's printed dose, which prefers the name's) are kept here too, marked
// [EnrichmentSource.phone], with the weightPerUnit and analyteWeight they apply to ([EnrichmentStore.rememberPhone]).
// The TPE itself is never worked out in Dart. Precedence: the server's figures replace the phone's whenever they
// arrive ([EnrichmentStore.remember]); the phone's never replace server figures that are still for the same inputs.
// The same rule as the server's ([applyEnrichment]) decides whether either is used.
//
// Kept across centers, keyed by the package's own state-system identity (productGuid + record id, the same key
// merged_inventory.dart joins on): a state record id names one record system-wide, its strain and potency don't
// depend on which center is looking, and a worker who covers two centers keeps what they saw at both. Bounded:
// entries older than [EnrichmentStore.maxAge] are dropped and at most [EnrichmentStore.maxEntries] are kept (newest
// first), so the file stays small whatever the device has seen.
import 'dart:convert';
import 'dart:io';

import 'local_store.dart';
import 'packages_client.dart';
import 'session_store.dart' show defaultSessionDataDir;
import 'sync/sync_datasets.dart' show Dataset, Datasets, sourceServer;

/// What the server last sent for one package, or what the phone read from its lab report, and the inputs it applies to.
class PackageEnrichment {
  final String productGuid;
  final int id;
  final double weightPerUnit;
  final double analyteWeight;
  final String strain;
  final int tpeMg;
  final DateTime? expires;

  /// When the server's answer holding these figures was received, or when the phone read the lab report (UTC).
  final DateTime seenAt;

  /// Who these figures are from: Mazama's server ([EnrichmentSource.server], every entry written before SM-D31) or the
  /// phone's mazama_core reading of the lab report ([EnrichmentSource.phone]).
  final EnrichmentSource source;

  /// The phone's reading only (null from the server): mazama_core's TPE in mg/g, and its psilocin in mg per unit.
  final double? tpeMgPerG;
  final double? psilocinMg;

  /// README R64: the server's label input for the package (Package.labelInput), so a label can still be drawn without
  /// the lab report from a read of the state system alone. Null from the phone's own reading, an entry kept before R64,
  /// or a server row that had none.
  final Map<String, Object?>? labelInput;

  PackageEnrichment({
    required this.productGuid,
    required this.id,
    required this.weightPerUnit,
    required this.analyteWeight,
    required this.strain,
    required this.tpeMg,
    required this.expires,
    required this.seenAt,
    this.source = EnrichmentSource.server,
    this.tpeMgPerG,
    this.psilocinMg,
    this.labelInput,
  });

  /// The store's key for [p]: the package's own state-system identity.
  static String keyOf(Package p) => enrichmentKey(p.productGuid, p.id);

  String get key => enrichmentKey(productGuid, id);

  Map<String, Object?> toJson() => {
        'productGuid': productGuid,
        'id': id,
        'weightPerUnit': weightPerUnit,
        'analyteWeight': analyteWeight,
        'strain': strain,
        'tpeMg': tpeMg,
        if (expires != null) 'expires': _isoDate(expires!),
        'seenAtMs': seenAt.millisecondsSinceEpoch,
        if (source == EnrichmentSource.phone) 'source': 'phone',
        if (tpeMgPerG != null) 'tpeMgPerG': tpeMgPerG,
        if (psilocinMg != null) 'psilocinMg': psilocinMg,
        if (labelInput != null) 'labelInput': labelInput,
      };

  /// Null when [j] isn't a complete entry this class wrote (an older or damaged file): such an entry is skipped.
  static PackageEnrichment? fromJson(Object? j) {
    if (j is! Map) return null;
    final guid = j['productGuid'], id = j['id'], wpu = j['weightPerUnit'], aw = j['analyteWeight'];
    final strain = j['strain'], tpe = j['tpeMg'], seen = j['seenAtMs'], exp = j['expires'];
    if (guid is! String || id is! num || wpu is! num || aw is! num || strain is! String || tpe is! num || seen is! num) {
      return null;
    }
    final expDate = exp is String ? DateTime.tryParse(exp) : null;
    final tpePerG = j['tpeMgPerG'], psilocin = j['psilocinMg'];
    return PackageEnrichment(
      productGuid: guid,
      id: id.toInt(),
      weightPerUnit: wpu.toDouble(),
      analyteWeight: aw.toDouble(),
      strain: strain,
      tpeMg: tpe.toInt(),
      expires: expDate == null ? null : DateTime(expDate.year, expDate.month, expDate.day),
      seenAt: DateTime.fromMillisecondsSinceEpoch(seen.toInt(), isUtc: true),
      source: j['source'] == 'phone' ? EnrichmentSource.phone : EnrichmentSource.server,
      tpeMgPerG: tpePerG is num ? tpePerG.toDouble() : null,
      psilocinMg: psilocin is num ? psilocin.toDouble() : null,
      labelInput: j['labelInput'] is Map ? Map<String, Object?>.from(j['labelInput'] as Map) : null,
    );
  }
}

/// productGuid + record id, the key merged_inventory.dart joins the server's and the state's rows on.
String enrichmentKey(String productGuid, int id) => '$productGuid#$id';

String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class EnrichmentStore {
  /// Overridable for tests, so a test never reads or writes the real app-data directory - same pattern as
  /// InventoryCacheStore.dataDir.
  final Directory Function() dataDir;

  /// At most this many packages are kept (the most recently seen); the rest are dropped on the next [remember].
  final int maxEntries;

  /// An entry older than this is dropped on [remember] and never handed back by [load].
  final Duration maxAge;

  const EnrichmentStore({
    Directory Function()? dataDir,
    this.maxEntries = 2000,
    this.maxAge = const Duration(days: 30),
  }) : dataDir = dataDir ?? defaultSessionDataDir;

  static const _name = 'enrichment.json';

  /// Records [serverRows] - Mazama's server's own rows, exactly as /p/packages sent them - received at [at]. A row
  /// replaces what was kept for the same package; other packages already kept stay (until too old or too many). A row
  /// with no known potency (tpeMg 0) is not kept: there is nothing in it worth reusing.
  ///
  /// Synchronous LocalStore calls and no awaits (as cart_store.dart), so the write has finished when this returns even
  /// when the caller doesn't await it.
  Future<void> remember(List<Package> serverRows, DateTime at) async {
    final kept = _read();
    for (final p in serverRows) {
      if (p.tpeMg <= 0) continue;
      final e = PackageEnrichment(
        productGuid: p.productGuid,
        id: p.id,
        weightPerUnit: p.weightPerUnit,
        analyteWeight: p.analyteWeight,
        strain: p.strain,
        tpeMg: p.tpeMg,
        expires: p.expires,
        seenAt: at.toUtc(),
        labelInput: p.labelInput,
      );
      kept[e.key] = e;
    }
    _write(kept, at);
  }

  /// Records [readings] - the phone's own mazama_core readings of lab reports ([EnrichmentSource.phone], phone_label.dart),
  /// made at [at] (SM-D31). A reading replaces what was kept for the same package unless that is the server's and was
  /// worked out from the same weightPerUnit and analyteWeight: the server's figures win while they still apply. A
  /// reading with no mg TPE (tpeMg 0) is not kept. Synchronous I/O, as [remember].
  Future<void> rememberPhone(List<PackageEnrichment> readings, DateTime at) async {
    final kept = _read();
    for (final e in readings) {
      if (e.tpeMg <= 0) continue;
      final old = kept[e.key];
      if (old != null &&
          old.source == EnrichmentSource.server &&
          old.weightPerUnit == e.weightPerUnit &&
          old.analyteWeight == e.analyteWeight) {
        continue;
      }
      kept[e.key] = e;
    }
    _write(kept, at);
  }

  void _write(Map<String, PackageEnrichment> kept, DateTime at) {
    final fresh = [for (final e in kept.values) if (!_tooOld(e, at)) e]
      ..sort((a, b) => b.seenAt.compareTo(a.seenAt));
    final bounded = fresh.length > maxEntries ? fresh.sublist(0, maxEntries) : fresh;
    Datasets.forDir(dataDir).put(
        Dataset.enrichment,
        '',
        jsonEncode({
          'version': 1,
          'entries': [for (final e in bounded) e.toJson()],
        }),
        source: sourceServer,
        at: at);
  }

  /// Every package kept and not older than [maxAge] as of [now], by [enrichmentKey]. Empty when nothing is stored or
  /// what is kept can't be read back (nothing yet, a partial write from an older build, another format).
  Future<Map<String, PackageEnrichment>> load(DateTime now) async {
    final kept = _read();
    kept.removeWhere((_, e) => _tooOld(e, now));
    return kept;
  }

  Future<void> clear() async {
    // nothing kept is exactly the state this call is meant to produce; an older build's document goes too
    Datasets.forDir(dataDir).remove(Dataset.enrichment, key: '');
    LocalStore.forDir(dataDir()).delete(_name);
  }

  bool _tooOld(PackageEnrichment e, DateTime now) => now.difference(e.seenAt) > maxAge;

  Map<String, PackageEnrichment> _read() {
    try {
      final text = Datasets.forDir(dataDir).read(Dataset.enrichment, '')?.body;
      if (text == null) return {};
      final decoded = jsonDecode(text);
      if (decoded is! Map || decoded['version'] != 1) return {};
      final entries = decoded['entries'];
      if (entries is! List) return {};
      final out = <String, PackageEnrichment>{};
      for (final raw in entries) {
        final e = PackageEnrichment.fromJson(raw);
        if (e != null) out[e.key] = e;
      }
      return out;
    } on FileSystemException {
      return {};
    } on FormatException {
      return {};
    }
  }
}

/// [statePackages] - read straight from the state system, Mazama's server unreachable - with the figures kept on the
/// phone (the server's last strain, tpeMg and expires, or the phone's own mazama_core reading of the lab report, SM-D31)
/// filled in where that is safe, every package marked:
///   - filled ([Package.enrichedAt] set to when the figures were received or read, [Package.enrichedBy] who from,
///     [Package.stateEstimate] false) only when [known] holds an entry for the same package (productGuid + id) whose
///     weightPerUnit AND analyteWeight equal the state's current ones exactly, and whose tpeMg is not below the state's
///     own figure for this package (the TPE rule, AD-18 as amended by SM-D14, never gives less than the state's
///     psilocybin; a lower remembered figure means something is off, so it isn't trusted), AND every other record of the
///     same product (productGuid) in [statePackages] can be filled too. The remembered tpeMg is used exactly as kept:
///     nothing is rescaled or worked out again on the phone.
///   - left exactly as the state read gave it otherwise, and marked [Package.stateEstimate]: strain only from the name,
///     tpeMg only the state's psilocybin, shown as "mg psilocybin" ([Package.mgFigure], SM-D31). A package nothing was
///     kept for, or whose weight or the state's potency changed since (the old TPE may be wrong then). A product with any
///     such record has every record's mg left at the state's psilocybin (a record that could be filled still gets its
///     kept strain and expiry), so the one figure the cart shows and prices it by (PkprGroup.tpeMg) is always the
///     figure it is labelled as.
/// Quantity, lot id and the COA/label flags are always the state read's own.
List<Package> applyEnrichment(List<Package> statePackages, Map<String, PackageEnrichment> known) {
  final usable = [for (final p in statePackages) _usable(p, known[PackageEnrichment.keyOf(p)])];
  final stateOnly = {
    for (var i = 0; i < statePackages.length; i++)
      if (usable[i] == null) statePackages[i].productGuid,
  };
  return [
    for (var i = 0; i < statePackages.length; i++)
      if (usable[i] case final e? when !stateOnly.contains(statePackages[i].productGuid))
        _filled(statePackages[i], e)
      else if (usable[i] case final e?)
        // a record that could be filled, of a product that can't be as a whole: its strain and expiry (what a sale
        // draws the earliest of first, SM-D29) are still the kept ones; its mg is the state's psilocybin, as the rest
        copyPackage(statePackages[i],
            strain: e.strain.isNotEmpty ? e.strain : statePackages[i].strain,
            expires: e.expires ?? statePackages[i].expires,
            labelInput: e.labelInput ?? statePackages[i].labelInput,
            stateEstimate: true,
            enrichedAt: null)
      else
        copyPackage(statePackages[i], stateEstimate: true, enrichedAt: null),
  ];
}

/// [e] when it may fill [p] (applyEnrichment's per-package rule), else null.
PackageEnrichment? _usable(Package p, PackageEnrichment? e) {
  if (e == null ||
      e.weightPerUnit != p.weightPerUnit ||
      e.analyteWeight != p.analyteWeight ||
      e.tpeMg <= 0 ||
      e.tpeMg < p.tpeMg) {
    return null;
  }
  return e;
}

Package _filled(Package p, PackageEnrichment e) => copyPackage(
      p,
      strain: e.strain.isNotEmpty ? e.strain : p.strain,
      tpeMg: e.tpeMg,
      expires: e.expires ?? p.expires,
      labelInput: e.labelInput ?? p.labelInput,
      stateEstimate: false,
      enrichedAt: e.seenAt,
      enrichedBy: e.source,
    );

/// [p] with the given display fields replaced; every other field copied as it is. [enrichedAt] and [enrichedBy] are
/// always replaced (pass the old values to keep them; [enrichedBy] defaults to the server when [enrichedAt] is set).
Package copyPackage(
  Package p, {
  String? strain,
  int? tpeMg,
  DateTime? expires,
  Map<String, Object?>? labelInput,
  required bool stateEstimate,
  required DateTime? enrichedAt,
  EnrichmentSource? enrichedBy,
}) =>
    Package(
      productGuid: p.productGuid,
      productType: p.productType,
      id: p.id,
      weightPerUnit: p.weightPerUnit,
      analyteWeight: p.analyteWeight,
      strain: strain ?? p.strain,
      tpeMg: tpeMg ?? p.tpeMg,
      quantity: p.quantity,
      exactQuantity: p.exactQuantity,
      lotGuid: p.lotGuid,
      coaAvailable: p.coaAvailable,
      labelAvailable: p.labelAvailable,
      expires: expires ?? p.expires,
      mazama: p.mazama,
      expired: p.expired,
      unitMgTpe: p.unitMgTpe,
      description: p.description,
      type: p.type,
      enrichedAt: enrichedAt,
      enrichedBy: enrichedBy,
      stateEstimate: stateEstimate,
      stateOnly: p.stateOnly,
      labelInput: labelInput ?? p.labelInput,
    );

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// A worker-facing date ("Oct 21, 2026"), on the device's own calendar.
String formatEnrichmentDate(DateTime at) {
  final d = at.toLocal();
  return '${_months[d.month - 1]} ${d.day}, ${d.year}';
}

/// Whether any lot behind [g] is a state-only estimate ([Package.stateEstimate]): then so is the group as shown, and its
/// figure is only the state's psilocybin (PkprGroup.mgFigure).
bool groupIsEstimate(PkprGroup g) => g.lots.any((l) => l.stateEstimate);

/// The oldest [Package.enrichedAt] of [g]'s lots, or null when none was filled in from Mazama's last answer.
DateTime? groupEnrichedAt(PkprGroup g) {
  DateTime? oldest;
  for (final l in g.lots) {
    final at = l.enrichedAt;
    if (at != null && (oldest == null || at.isBefore(oldest))) oldest = at;
  }
  return oldest;
}

/// Who the figures filled into [g]'s lots came from: the phone when any lot's are the phone's reading, the server when
/// every filled lot's are the server's, null when none was filled in.
EnrichmentSource? groupEnrichedBy(PkprGroup g) {
  EnrichmentSource? by;
  for (final l in g.lots) {
    if (l.enrichedBy == EnrichmentSource.phone) return EnrichmentSource.phone;
    by ??= l.enrichedBy;
  }
  return by;
}

/// What a stock row adds after its "Nmg TPE each" / "Nmg psilocybin each" (PkprGroup.mgLabel) so a figure that isn't
/// Mazama's live one never looks like it is: " (the state's figure; no TPE known)" for a state-only product (SM-D31),
/// " (Mazama's figure from Oct 21, 2026)" for one filled in from Mazama's last answer, " (this phone's reading of the
/// lab report on Oct 21, 2026)" for one filled in from the phone's own reading, '' for Mazama's live figure.
String tpeProvenanceNote(PkprGroup g) {
  if (groupIsEstimate(g)) return " (the state's figure; no TPE known)";
  final at = groupEnrichedAt(g);
  if (at == null) return '';
  return groupEnrichedBy(g) == EnrichmentSource.phone
      ? " (this phone's reading of the lab report on ${formatEnrichmentDate(at)})"
      : " (Mazama's figure from ${formatEnrichmentDate(at)})";
}

// A package's label drawn on the phone, for when Mazama's server has none on file (the cart's compare popup and
// edit dialog, cart_page.dart). The same chain the "COA → label" debug page runs step by step
// (debug_coa_label_page.dart), without the page: the package's own state record, its lot's newest accepted potency
// report from the state, the report's text (pdfium), coa_core's lot finder and label spec (coa_core_ffi.dart). Every
// number comes from coa_core, the same rules the server's labels use (labelspec.py); the phone only gathers the
// input. Drawn by LabelPreview (label_preview.dart): black text on white, like the server's label for a package
// Mazama didn't make (AD-L18).
//
// README R64: when /p/packages sent the package's `labelInput` (Package.labelInput: coa_core's LabelInput exactly as the
// server builds it for its own labels, its shelf life, subtype and strain included), the label is drawn from that with
// the phone's own today and nothing else: no call to the state system, no lab report, nothing kept. The chain below runs
// only for a package the server has no certificate for.
//
// What the phone can't know the way the server does: the server's configured shelf life (default.nix's 12 / 24
// months are used here), its certificate subtype (the name's type code decides instead, as on the debug page) and
// its strain alias table (the strain the server's COA data gave the package is passed when there is one). Only the
// best-by of a package whose name carries no date depends on the shelf life.
//
// What the phone keeps from it (SM-D31, amending SM-D15): once coa_core has read the lot's report and given a label,
// every record of this product at the center on the same lot gets coa_core's own label answer for its own weight and
// state figure, and its TPE (LabelSpec tpe_mg_per_g: coa_core::tpe to 2 places, the server's coa.tpe figure), psilocin
// per unit and per-unit mg TPE (unit weight x that TPE rounded up, dose.dart - what /p/packages sends as tpeMg; never
// the label's printed dose, which prefers the name's) are saved in the enrichment store (enrichment_store.dart's
// rememberPhone), so a later read from the state system alone can show them. Nothing is saved when no label can be
// drawn, and a failed save never stops the label.
import 'dart:typed_data';

import 'coa_core_ffi.dart';
import 'dose.dart';
import 'enrichment_store.dart';
import 'package_ids.dart';
import 'packages_client.dart' show EnrichmentSource;
import 'pdf_text.dart';
import 'select_documents.dart';
import 'state_client.dart';
import 'state_document_client.dart' as state_document_client;
import 'state_packages_client.dart' as state_packages_client;
import 'state_records.dart';

/// Why no label could be drawn on the phone, in words for the worker.
class PhoneLabelError implements Exception {
  final String message;
  PhoneLabelError(this.message);
  @override
  String toString() => message;
}

/// default.nix's shelfLifeMonths / shelfLifeFdMonths (the server's settings aren't sent to the phone).
const phoneLabelSettings = {'shelf_months': 12, 'fd_months': 24, 'shelf_days': null, 'fd_days': null};

String _isoDay(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// The label spec coa_core gives for [pkpr] at the center [stateId] (its LabelSpec: strain, dose_mg_tpe, net_wt_g,
/// per_unit_mg, best_by, pkpr, ...), ready for LabelPreview. Throws PhoneLabelError with the reason when there can
/// be none: the shared library isn't in this build (iOS today), the package or its lot can't be found, the lot has
/// no lab report on file, the report doesn't name the lot, or coa_core blocks the label (every reason, joined).
/// [strain] is the strain the server already knows for the package (its COA data), used before the name's.
/// [enrichment] is where the phone's reading is kept (see this file's comment; CartPage passes its own store); null
/// keeps nothing. [labelInput] is the server's (README R64): when given, the label comes from it alone, with no state
/// call, no report and nothing kept.
Future<Map<String, Object?>> drawPhoneLabelSpec(
  int stateId,
  String pkpr, {
  required String accessToken,
  String strain = '',
  DateTime Function()? now,
  CoaCore? Function() loadCore = CoaCore.tryLoad,
  Future<List<Object?>> Function(int stateId, {required String accessToken}) fetchRawPackages =
      state_packages_client.fetchRawPackagesFromState,
  Future<Object?> Function(int packageId, {required String accessToken})? fetchProductInfo,
  Future<Uint8List> Function(int docId, {required String accessToken}) downloadDocument =
      state_document_client.downloadStateDocument,
  Future<Map<String, Object?>> Function(Uint8List pdf) extractText = extractCoaText,
  EnrichmentStore? enrichment,
  Map<String, Object?>? labelInput,
}) async {
  // first, so a build without the library answers at once, without fetching anything
  final core = loadCore();
  if (core == null) throw PhoneLabelError(coaCoreMissingMessage);
  final today = (now ?? DateTime.now)();
  if (labelInput != null) return _specOf(core.labelSpec({...labelInput, 'today': _isoDay(today)}));
  final productInfo = fetchProductInfo ??
      ((id, {required accessToken}) => fetchStateFlow('packaged_product_info', {'package_id': id}, accessToken: accessToken));

  Map<String, Object?>? record;
  int? packageId;
  String? recordPkpr;
  // every record of this product at the center, for what the phone keeps from the reading
  final siblings = <(Map<String, Object?>, int)>[];
  for (final e in await fetchRawPackages(stateId, accessToken: accessToken)) {
    if (e is! Map) continue;
    final r = Map<String, Object?>.from(e);
    final key = packagedProductKey(r);
    if (key != null && key.pkpr.toUpperCase() == pkpr.toUpperCase()) {
      siblings.add((r, key.stateId));
      if (record == null) {
        (record, packageId, recordPkpr) = (r, key.stateId, key.pkpr);
      }
    }
  }
  if (record == null || packageId == null) throw PhoneLabelError("$pkpr isn't in this center's inventory at the state");
  final lot = packageSource(record);
  if (lot == null) throw PhoneLabelError('$pkpr names no batch or lot to find its lab report by');
  final analyteWeight = (record['analyteWeight'] as num?)?.toDouble() ?? 0;

  final docs = selectPotencyDocuments(await productInfo(packageId, accessToken: accessToken));
  if (docs.isEmpty) throw PhoneLabelError('lot $lot has no accepted lab report on file at the state yet');
  final doc = docs.first;
  final pdf = await downloadDocument(doc.docId, accessToken: accessToken);
  final text = await extractText(pdf);

  // AD-19: the lot's own UID, else the batch its report's request pairs it with, else the state's psilocybin
  final reply = core.findLot(text, lot, statePsilocybin: analyteWeight > 0 ? analyteWeight : null);
  final sections = (((reply['result'] as Map?) ?? const {})['sections'] as List? ?? const []);
  final found = reply['found'];
  final at = found is Map ? found['section'] : null;
  if (at is! int || at < 0 || at >= sections.length) throw PhoneLabelError("lot $lot's lab report doesn't name it");

  Map<String, Object?> labelFor(Map<String, Object?> r) => core.labelSpec({
        'package': {
          'pkpr': recordPkpr ?? pkpr, // as the state writes it
          'description': '${r['description'] ?? ''}',
          'weight_per_unit': (r['weightPerUnit'] as num?)?.toDouble() ?? 0,
          'product_type': '${r['productType'] ?? ''}',
          'analyte_weight': (r['analyteWeight'] as num?)?.toDouble() ?? 0.0,
          'lot': lot,
          if (strain.trim().isNotEmpty) 'strain': strain.trim(),
        },
        'section': sections[at],
        'settings': phoneLabelSettings,
        'today': _isoDay(today),
        // SM-D18, as the server: best-by counts from the state's test-completed date
        if (doc.date != null) 'test_date': doc.date,
      });
  final result = _specOf(labelFor(record));

  final store = enrichment;
  if (store != null) {
    try {
      final readings = <PackageEnrichment>[];
      for (final (r, id) in siblings) {
        if (packageSource(r) != lot) continue; // another lot's report says nothing about this one
        final s = identical(r, record) ? result : (labelFor(r)['spec'] as Map?)?.cast<String, Object?>();
        final reading = s == null ? null : phoneReading(r, id, s, today);
        if (reading != null) readings.add(reading);
      }
      if (readings.isNotEmpty) await store.rememberPhone(readings, today);
    } catch (_) {
      // nothing kept this time; the label stands
    }
  }
  return result;
}

/// coa_core's label answer [out] as the spec, or PhoneLabelError with every reason it gives none.
Map<String, Object?> _specOf(Map<String, Object?> out) {
  final blocked = out['blocked'];
  if (blocked is List) throw PhoneLabelError(blocked.join('; '));
  final error = out['error'];
  if (error != null) throw PhoneLabelError('$error');
  final spec = out['spec'];
  if (spec is! Map) throw PhoneLabelError('the label rules gave no answer');
  return spec.cast<String, Object?>();
}

/// What the phone keeps (SM-D31) from coa_core's label [spec] for the state [record] whose record id is [id], read at
/// [at]; null when coa_core gave no TPE or the record has no unit weight. The TPE is coa_core's own (tpe_mg_per_g);
/// tpeMg is the unit's mg TPE as the server works it out (weight x TPE, rounded up: dose.dart, SM-D16/SM-D17).
PackageEnrichment? phoneReading(Map<String, Object?> record, int id, Map<String, Object?> spec, DateTime at) {
  final key = packagedProductKey(record);
  final tpe = spec['tpe_mg_per_g'];
  final weight = (record['weightPerUnit'] as num?)?.toDouble() ?? 0;
  if (key == null || tpe is! num || weight <= 0) return null;
  final tpeMg = unitTpeMg(weight, null, tpe.toDouble());
  if (tpeMg == null || tpeMg <= 0) return null;
  final psilocin = ((spec['per_unit_mg'] as Map?) ?? const {})['psilocin'];
  // only a date written in the product's name: a best-by worked out from the phone's built-in shelf life may not be
  // the server's
  final bestBy = spec['best_by_from'] == 'name' ? DateTime.tryParse('${spec['best_by'] ?? ''}') : null;
  return PackageEnrichment(
    productGuid: key.pkpr,
    id: id,
    weightPerUnit: weight,
    analyteWeight: (record['analyteWeight'] as num?)?.toDouble() ?? 0,
    strain: '${spec['strain'] ?? ''}',
    tpeMg: tpeMg,
    expires: bestBy == null ? null : DateTime(bestBy.year, bestBy.month, bestBy.day),
    seenAt: at.toUtc(),
    source: EnrichmentSource.phone,
    tpeMgPerG: tpe.toDouble(),
    psilocinMg: psilocin is num ? psilocin.toDouble() : null,
  );
}

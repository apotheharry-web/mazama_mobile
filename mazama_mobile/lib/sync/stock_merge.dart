// The one rule that builds a center's stock (the `center_stock` dataset) from the newest state
// read, the newest server reply and the figures kept on the phone, wherever each came from. Its cases are held in
// test/sync/stock_merge_test.dart:
//
//   - a configured center, both answered: the state's records, joined to the server's rows by PKPR and record id. Quantity, the weights and the lot id are the state's (its live count always wins; a
//     locked, flagged or pending-transfer record isn't sellable and is left out by the state mapping); strain,
//     mg TPE, expiry, the COA/label flags, the stock page's fields and the label input are the server's row's. A record
//     only the state lists keeps the state's figures and is marked as having no COA or label known (the server was
//     never asked about it), and as the state's estimate (stateEstimate) unless another record of its product was
//     joined (then it is marked stateOnly instead: the product is shown and priced by its first lot's figure, its
//     cap counting the lots a sale draws, and notes these units and their own figure, PkprGroup.stateOnlyNote). A row
//     only the server lists is gone from the state: not carried.
//   - only the state answered: the state's records (no COA or label known), filled from a kept figure where it still
//     applies, every other record marked [Package.stateEstimate] (enrichment.dart's applyEnrichment: same weight
//     per unit and state potency exactly).
//   - an unconfigured center (center_status: Mazama's server doesn't track it): the state's records, with the lab
//     figures the batch lookup found (coaData, by lot) folded in as coa_data_resolver.dart does; no server rows.
// [readStock] runs a configured center's two reads at once (the stock page's load and a debug page; the cart's CenterStock
// runs its own with its fallbacks) and joins them with [mergeStock].
// [StockMergeResult.remember] is what to keep for later fills: the server's own rows (never the joined ones, whose
// weights are the state's). [StockMergeResult.serverKeys] says which rows the server sent (the background uploader
// queues only those).
//
// mergeStock is pure: no I/O and no clock; the state's records are mapped through the shared core (state_packages_client.dart's
// mapRawPackagesFromState, the sale rule included).
import '../coa_data_client.dart' show CoaData;
import '../dose.dart' show unitTpeMg;
import 'enrichment.dart';
import '../mazama_core.dart' show CoreFunctions;
import '../packages_client.dart';
import '../state_packages_client.dart' show mapRawPackagesFromState;

/// Where a merged stock came from (the `center_stock` dataset's source).
const stockFromBoth = 'merged', stockFromState = 'state', stockFromServer = 'server';

/// Neither source answered: there is nothing to build a stock from.
class StockMergeError implements Exception {
  StockMergeError(this.message);
  final String message;
  @override
  String toString() => message;
}

class StockMergeResult {
  const StockMergeResult({required this.packages, required this.source, this.remember = const [], this.serverKeys});

  final List<Package> packages;

  /// [stockFromBoth], [stockFromState] or [stockFromServer].
  final String source;

  /// The server's own rows, to keep for a later read the server doesn't answer (enrichment.dart's
  /// rememberServerFigures); empty when the server didn't answer.
  final List<Package> remember;

  /// The [stockRowKey]s of the rows the server sent; null when it didn't answer.
  final Set<String>? serverKeys;
}

/// One read of a configured center's stock from both sides ([readStock]): the server's rows and the state's raw records,
/// each null when that side failed, with its error.
class StockRead {
  const StockRead({this.serverRows, this.stateRecords, this.serverError, this.stateError});

  /// /p/packages's rows; null when the server didn't answer ([serverError]).
  final List<Package>? serverRows;

  /// The state's raw GetPackagedProducts records; null when the state didn't answer ([stateError]).
  final List<Object?>? stateRecords;
  final Object? serverError;
  final Object? stateError;

  bool get serverOk => serverRows != null;
  bool get stateOk => stateRecords != null;

  /// The two joined by [mergeStock] (a configured center, nothing kept to fill from); throws [StockMergeError] when
  /// neither answered.
  StockMergeResult merged({CoreFunctions? core}) =>
      mergeStock(stateRecords: stateRecords, serverRows: serverRows, enrichment: const {}, configured: true, core: core);
}

/// Runs [fetchServer] (/p/packages) and [fetchState] (the state's raw records) at once; neither failing throws.
Future<StockRead> readStock({
  required Future<List<Package>> Function() fetchServer,
  required Future<List<Object?>> Function() fetchState,
}) async {
  List<Package>? server;
  List<Object?>? state;
  Object? serverError, stateError;
  await Future.wait<void>([
    Future(() async {
      try {
        server = await fetchServer();
      } catch (e) {
        serverError = e;
      }
    }),
    Future(() async {
      try {
        state = await fetchState();
      } catch (e) {
        stateError = e;
      }
    }),
  ]);
  return StockRead(serverRows: server, stateRecords: state, serverError: serverError, stateError: stateError);
}

/// One row's key, as the merge joins the server's rows to the state's: PKPR and record id.
String stockRowKey(Package p) => '${p.productGuid}#${p.id}';

/// The merge rule (the file comment). [stateRecords] is the state's raw read (GetPackagedProducts) or null when it didn't
/// answer; [serverRows] /p/packages's rows or null; [enrichment] the figures kept on the phone, by enrichmentKey, as
/// enrichment.dart's keptEnrichment gives them; [configured] whether Mazama's server tracks the center; [coaData] the batch
/// lookup's figures by lot id, for an unconfigured center. Throws [StockMergeError] when there is nothing to build from.
StockMergeResult mergeStock({
  required List<Object?>? stateRecords,
  required List<Package>? serverRows,
  required Map<String, PackageEnrichment> enrichment,
  required bool configured,
  Map<String, CoaData> coaData = const {},
  CoreFunctions? core,
}) {
  if (!configured) {
    final records = stateRecords;
    if (records == null) throw StockMergeError("the state system didn't answer");
    final byLot = {for (final e in coaData.entries) e.key.toLowerCase(): e.value};
    return StockMergeResult(
      packages: [
        for (final p in mapRawPackagesFromState(records, core: core))
          if (byLot[p.lotGuid?.toLowerCase()] case final data?) _withCoaData(p, data) else p,
      ],
      source: stockFromState,
    );
  }

  final server = serverRows;
  if (stateRecords == null) {
    if (server == null) throw StockMergeError("neither the state system nor Mazama's server answered");
    return StockMergeResult(
        packages: server, source: stockFromServer, remember: server, serverKeys: {for (final p in server) stockRowKey(p)});
  }
  final state = mapRawPackagesFromState(stateRecords, core: core);
  if (server == null) {
    return StockMergeResult(packages: applyEnrichment([for (final p in state) _noCoaOrLabelKnown(p)], enrichment), source: stockFromState);
  }
  final byKey = {for (final p in server) stockRowKey(p): p};
  // A record only the state lists shows the state's own figure, marked as such (Package.stateEstimate: "mg
  // psilocybin") - unless another record of the same product was joined, whose server figure the product is shown and
  // priced by (PkprGroup takes its first lot's): marking that product would put the word "psilocybin" on a TPE figure.
  // Such a record is marked stateOnly instead, which only adds a note to its product (PkprGroup.stateOnlyNote).
  final joinedProducts = {for (final sp in state) if (byKey.containsKey(stockRowKey(sp))) sp.productGuid};
  return StockMergeResult(
    packages: [
      for (final sp in state)
        if (byKey[stockRowKey(sp)] case final mp?)
          _joined(sp, mp)
        else if (joinedProducts.contains(sp.productGuid))
          _noCoaOrLabelKnown(sp, stateOnly: true)
        else
          copyPackage(_noCoaOrLabelKnown(sp), stateEstimate: true, enrichedAt: null),
    ],
    source: stockFromBoth,
    remember: server,
    serverKeys: byKey.keys.toSet(),
  );
}

/// The state's record [sp] with the server's row [mp]'s figures.
Package _joined(Package sp, Package mp) => Package(
      productGuid: sp.productGuid,
      productType: sp.productType,
      id: sp.id,
      weightPerUnit: sp.weightPerUnit,
      analyteWeight: sp.analyteWeight,
      saleValues: sp.saleValues,
      quantity: sp.quantity,
      exactQuantity: sp.exactQuantity,
      lotGuid: sp.lotGuid ?? mp.lotGuid,
      strain: mp.strain,
      tpeMg: mp.tpeMg,
      coaAvailable: mp.coaAvailable,
      labelAvailable: mp.labelAvailable,
      expires: mp.expires, // only the server knows a record's expiry; the sale draws the earliest first
      mazama: mp.mazama, // the server's own word on these; only the quantity (above) is the state's
      expired: mp.expired,
      unitMgTpe: mp.unitMgTpe,
      description: mp.description,
      type: mp.type, // the server's kind code
      labelInput: mp.labelInput, // the server's, for a label drawn without the lab report
      lotTpe: mp.lotTpe, // the certificate's TPE, as the server has it
    );

/// A record only the state knows this time: its own figures, and no COA or label known (not known to be missing, but
/// the server was never asked).
Package _noCoaOrLabelKnown(Package p, {bool stateOnly = false}) => Package(
      productGuid: p.productGuid,
      productType: p.productType,
      id: p.id,
      weightPerUnit: p.weightPerUnit,
      analyteWeight: p.analyteWeight,
      saleValues: p.saleValues,
      quantity: p.quantity,
      exactQuantity: p.exactQuantity,
      lotGuid: p.lotGuid,
      strain: p.strain,
      tpeMg: p.tpeMg,
      coaAvailable: false,
      labelAvailable: false,
      expires: p.expires,
      mazama: p.mazama,
      expired: p.expired,
      unitMgTpe: p.unitMgTpe,
      description: p.description,
      type: p.type,
      stateOnly: stateOnly,
    );

/// [p] with the batch lookup's [data] folded in (coa_data_resolver.dart's _applyCoaData): its strain, and the mg per
/// unit from the server's TPE rounded up; with no TPE the state's mg stays (none worked out here).
Package _withCoaData(Package p, CoaData data) {
  final tpePerG = data.tpe;
  return Package(
    productGuid: p.productGuid,
    productType: p.productType,
    id: p.id,
    weightPerUnit: p.weightPerUnit,
    analyteWeight: p.analyteWeight,
    saleValues: p.saleValues,
    strain: data.strain.isNotEmpty ? data.strain : p.strain,
    tpeMg: tpePerG == null ? p.tpeMg : unitTpeMg(p.weightPerUnit, null, tpePerG) ?? 0, // the core's (dose.dart)
    quantity: p.quantity,
    lotGuid: p.lotGuid,
    confirmed: p.confirmed,
    lotTpe: tpePerG, // the lab report's TPE; none when the lookup has none (never the state's figure)
  );
}

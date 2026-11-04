// The dose rules: the shared core's (mazama_core::dose), the same rule the server asks through its Python binding (mazama_sales' dose.py). Nothing of the rule is
// written here; these are the phone's names over it, held to the vectors (mazama_modules/dose/vectors/ and
// selling/vectors/dose_limits.json; test/dose_test.dart, test/dose_limits_test.dart).
//
// - unit mg: the mg TPE in one unit, rounded up (unitTpeMg, ceilMg): where the phone works it out itself, the
//   state-only path (state_packages_client.dart) and a lab result's TPE from the server (coa_data_resolver.dart,
//   sync/stock_merge.dart, phone_label.dart). Null when unknown, and when the core can't answer.
// - the strongest lot (highestLot): the lot a line its lots can't cover is counted on for the cap.
// - the cap (saleLimits): a sale's raw psilocybin, the state's weightPerUnit x analyteWeight summed exactly over the
//   units it draws, each lot its own figures, at most 50 mg, and the minimum session length; a bulk sell checks
//   every copy's own draw (bulkSaleLimits). It fails closed: no core, a core error or a reply of the
//   wrong shape refuses the sale with [doseCoreFailedReason]. Every sale's lines go to the core in one call.
import 'package:flutter/foundation.dart' show debugPrint;

import 'mazama_core.dart';
import 'packages_client.dart' show Package;

/// Why a sale is refused when this phone's core can't check its psilocybin.
const doseCoreFailedReason = "this phone can't check this sale's psilocybin limit (its shared core failed), so it can't be "
    'sold here';

/// The mg TPE in one unit, rounded up to a whole mg: the lot's [tpe] when known, else the state's psilocybin figure (0 or
/// null = none), times [weightPerUnit]; null when no potency is known, the product isn't finite or fits no 64-bit
/// integer, or the core can't answer. [core] defaults to this app's ([MazamaCore.instance]).
int? unitTpeMg(double weightPerUnit, double? statePsilocybin, double? tpe, {CoreFunctions? core}) {
  try {
    final reply = (core ?? MazamaCore.instance).doseUnitMg({
      'units': [
        {'record': {'weightPerUnit': weightPerUnit, 'analyteWeight': statePsilocybin}, 'tpe': tpe},
      ],
    });
    if (reply.length != 1) return null;
    final answer = reply.single;
    if (answer is! Map) return null;
    final mg = answer['tpe_mg'];
    return mg is int ? mg : null;
  } catch (e) {
    // StateError (no core loaded), MazamaCoreError, a figure jsonEncode can't write (NaN, infinite): unknown
    debugPrint('dose: the core could not work out a unit mg ($e)');
    return null;
  }
}

/// [x] rounded up to a whole mg by the core (only float noise of a billionth of a mg is forgiven); null when it
/// isn't finite, fits no 64-bit integer, or the core can't answer.
int? ceilMg(double x, {CoreFunctions? core}) {
  try {
    final reply = (core ?? MazamaCore.instance).doseCeilMg({
      'xs': [x],
    });
    if (reply.length != 1) return null;
    final mg = reply.single;
    return mg is int ? mg : null;
  } catch (e) {
    debugPrint('dose: the core could not round an mg figure ($e)');
    return null;
  }
}

/// A client's session as it is timed: its length in minutes, the core's (null: none, over the
/// cap or a figure not known), whether any of it was a secondary dose ("w/ booster"), and [unknown]: the core couldn't
/// answer, so it is timed by the longest session ([failedSessionMinutes]).
typedef SessionDose = ({int? minutes, bool booster, bool unknown});

/// The session a timer runs when the core can't work its length out: the longest there is, 6 hours (the
/// last row of rules.yaml dose.session_minutes). Never a rule's answer, only a timer's fallback.
const failedSessionMinutes = 360;

/// How [limits] is timed for a client: its session length (all of it, "w/ booster"), or the longest one when the core
/// couldn't answer.
SessionDose sessionDoseOf(SaleLimits limits, {required bool booster}) => identical(limits, SaleLimits.failed)
    ? (minutes: failedSessionMinutes, booster: booster, unknown: true)
    : (minutes: limits.sessionMinutes, booster: booster, unknown: false);

/// One line of a sale as the cap reads it: a lot's figures (only weightPerUnit and analyteWeight), the units drawn from
/// it, and the dose ('initial' or 'secondary').
typedef SaleLimitLine = ({Map<String, Object?> record, int qty, String dose});

/// The figures of [lot] the cap reads.
Map<String, Object?> doseFigures(Package lot) => {'weightPerUnit': lot.weightPerUnit, 'analyteWeight': lot.analyteWeight};

/// A figure of a lot as the core reads it: a number, or, when it isn't finite (JSON has no NaN or infinity), its text,
/// which the core counts as a figure it can't use.
Object _figureJson(double x) => x.isFinite ? x : x.toString();

/// The index of the lot of [lots] a line its lots can't cover is counted on, so it is never counted lower than any lot
/// it could draw: the core's dose.highest_lot (a figure it can't use first, then unknown potency, then the largest
/// weightPerUnit x analyteWeight, the earlier lot on a tie). Null when there are no lots or the core can't answer.
int? highestLot(List<Package> lots, {CoreFunctions? core}) {
  try {
    final i = (core ?? MazamaCore.instance).doseHighestLot({
      'lots': [
        for (final l in lots) {'weightPerUnit': _figureJson(l.weightPerUnit), 'analyteWeight': _figureJson(l.analyteWeight)},
      ],
    })['index'];
    return i is int && i >= 0 && i < lots.length ? i : null;
  } catch (e) {
    debugPrint('dose: the core could not pick the strongest lot ($e)');
    return null;
  }
}

/// Every copy's lines as the cap counts them, from a draw ([perSale]: for each copy, for each cart
/// line, the (lot, units) it takes, allocateBulkSales) and each cart line's dose ([doses], in the cart's order): one
/// line per lot drawn, with that lot's own figures. Pure.
List<List<SaleLimitLine>> drawnSaleLimitLines(List<List<List<(Package, int)>>> perSale, List<String> doses) => [
      for (final sale in perSale)
        [
          for (var i = 0; i < sale.length; i++)
            for (final (lot, take) in sale[i]) (record: doseFigures(lot), qty: take, dose: doses[i]),
        ],
    ];

/// One sale's answer from the core: its raw psilocybin as exact decimal text (null when refused for a figure), whether it
/// may be sold, why not (the core's words, or [doseCoreFailedReason]), and the minimum session length, minutes, for all
/// of it and for the initial dose alone (null when refused).
class SaleLimits {
  final String? psilocybinMg;
  final bool allowed;
  final String? error;
  final int? sessionMinutes;
  final int? sessionMinutesInitial;

  const SaleLimits({
    required this.psilocybinMg,
    required this.allowed,
    required this.error,
    required this.sessionMinutes,
    required this.sessionMinutesInitial,
  });

  /// The core couldn't answer, so the sale is refused.
  static const failed = SaleLimits(
      psilocybinMg: null, allowed: false, error: doseCoreFailedReason, sessionMinutes: null, sessionMinutesInitial: null);

  /// [psilocybinMg] as a number for display (never compared against a limit here); null when refused.
  double? get psilocybinMgValue {
    final mg = psilocybinMg;
    return mg == null ? null : double.tryParse(mg);
  }

  /// The minimum session length for all of the sale ("w/ booster"), or null.
  Duration? get session => sessionMinutes == null ? null : Duration(minutes: sessionMinutes!);

  /// The minimum session length for the initial dose alone, or null.
  Duration? get sessionInitial => sessionMinutesInitial == null ? null : Duration(minutes: sessionMinutesInitial!);

  /// This answer refused for [why] (a bulk sell's other copies), its figures kept.
  SaleLimits refusedFor(String why) => SaleLimits(
      psilocybinMg: psilocybinMg, allowed: false, error: why, sessionMinutes: sessionMinutes, sessionMinutesInitial: sessionMinutesInitial);

  /// The answer as the dose replay writes a verdict (G3b).
  Map<String, Object?> toVerdict() =>
      {'total': psilocybinMg, 'error': error, 'minutes': sessionMinutes, 'minutes_initial': sessionMinutesInitial};

  /// The core's answer [a] for one sale, or null when it isn't of the right shape.
  static SaleLimits? _read(Object? a) {
    if (a is! Map) return null;
    final mg = a['psilocybin_mg'], allowed = a['allowed'], error = a['error'];
    final minutes = a['session_minutes'], initial = a['session_minutes_initial'];
    if (mg != null && mg is! String) return null;
    if (allowed is! bool || (error != null && error is! String)) return null;
    if ((minutes != null && minutes is! int) || (initial != null && initial is! int)) return null;
    if (allowed != (error == null) || (allowed && mg == null)) return null;
    return SaleLimits(
        psilocybinMg: mg as String?,
        allowed: allowed,
        error: error as String?,
        sessionMinutes: minutes as int?,
        sessionMinutesInitial: initial as int?);
  }
}

/// The core's answer for each of [sales] (each its lines), in one call to [core] (default: this app's,
/// [MazamaCore.instance]). Never throws: when the call fails or answers the wrong way, each sale is asked alone, and a
/// sale the core still can't answer is [SaleLimits.failed], refused.
List<SaleLimits> saleLimits(List<List<SaleLimitLine>> sales, {CoreFunctions? core}) {
  if (sales.isEmpty) return const [];
  final all = _ask(sales, core);
  if (all != null) return all;
  debugPrint('dose: the core could not check ${sales.length} sale(s) together; checking each alone');
  if (sales.length == 1) return const [SaleLimits.failed];
  return [for (final s in sales) _ask([s], core)?.single ?? SaleLimits.failed];
}

List<SaleLimits>? _ask(List<List<SaleLimitLine>> sales, CoreFunctions? core) {
  try {
    final reply = (core ?? MazamaCore.instance).doseSaleLimits({
      'sales': [
        for (final lines in sales)
          {
            'lines': [
              for (final l in lines) {'record': l.record, 'qty': l.qty, 'dose': l.dose},
            ],
          },
      ],
    });
    if (reply.length != sales.length) return null;
    final out = <SaleLimits>[];
    for (final a in reply) {
      final read = SaleLimits._read(a);
      if (read == null) return null;
      out.add(read);
    }
    return out;
  } catch (_) {
    // StateError (no core loaded), MazamaCoreError, a figure jsonEncode can't write, or anything else: no answer
    return null;
  }
}

/// A bulk sell's copies ([copies], each its own draw's lines), each checked on its own draw in one call; when
/// any copy is refused, every other copy is refused too, naming the first refused copy ("copy 2 of 3 is refused: ...").
List<SaleLimits> bulkSaleLimits(List<List<SaleLimitLine>> copies, {CoreFunctions? core}) {
  final verdicts = saleLimits(copies, core: core);
  if (verdicts.length < 2) return verdicts;
  final first = verdicts.indexWhere((v) => !v.allowed);
  if (first < 0) return verdicts;
  final why = 'copy ${first + 1} of ${verdicts.length} is refused: ${verdicts[first].error}';
  return [for (final v in verdicts) v.allowed ? v.refusedFor(why) : v];
}

/// The core's answer for a dose kept only as its total mg ([psilocybinMg], a double), for timing it: worked
/// out as one 1 g unit holding it, rounded UP to 6 decimal places first (the most a figure may have), so its
/// session is never shorter than the total's own. [SaleLimits.failed] for a total that isn't a number of 0 or more.
SaleLimits keptMgLimits(double psilocybinMg, {CoreFunctions? core}) {
  if (psilocybinMg.isNaN || psilocybinMg.isInfinite || psilocybinMg < 0) return SaleLimits.failed;
  final micro = (psilocybinMg * 1000000).ceil();
  final lines = <SaleLimitLine>[
    if (micro > 0) (record: {'weightPerUnit': 1, 'analyteWeight': micro / 1000000}, qty: 1, dose: 'initial'),
  ];
  return saleLimits([lines], core: core).single;
}

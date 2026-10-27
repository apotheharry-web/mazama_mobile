// The compact label drawn on the phone from a LabelSpec (coa_core's build_label_spec through lib/coa_core_ffi.dart),
// for the COA → label debug page (plan 08 Task 8) and the cart's label compare when the server has no label on file
// (phone_label.dart). The layout follows specs/labels/04-label-spec.md "Printed
// layout (compact variant)" and the server's labeler.py: strain and "<dose> mg Equiv" turned a quarter turn on the
// left, a rule, then Lot / Best By / Net wt / Psilocin / Psilocybin and the optional alkaloids above 0.01 mg, in
// the lab's spellings (AD-L11). System font and no art layer: a preview of the figures, never a printable label.
import 'package:flutter/material.dart';

/// The optional alkaloid lines, in the printed order.
const _optional = [
  ('baeocystin', 'Baeocystin'),
  ('norbaeocystin', 'Norbaeocystin'),
  ('norpsilocin', 'Norpsilocin'),
  ('aeruginascin', 'Aeruginascin'),
];

double _num(Object? v) => v is num ? v.toDouble() : 0;

/// The right column's lines for [spec], exactly as the label prints them.
List<String> labelPreviewLines(Map<String, Object?> spec) {
  final mg = (spec['per_unit_mg'] as Map?)?.cast<String, Object?>() ?? const {};
  final pkpr = '${spec['pkpr'] ?? ''}';
  final hex = (pkpr.toUpperCase().startsWith('PKPR-') ? pkpr.substring(5) : pkpr).toLowerCase();
  return [
    'Lot: $hex',
    'Best By: ${spec['best_by'] ?? ''}',
    'Net wt: ${_num(spec['net_wt_g']).toStringAsFixed(2)} g',
    'Psilocin: ${_num(mg['psilocin']).toStringAsFixed(2)} mg',
    'Psilocybin: ${_num(mg['psilocybin']).toStringAsFixed(2)} mg',
    for (final (key, name) in _optional)
      if (_num(mg[key]) > 0.01) '$name: ${_num(mg[key]).toStringAsFixed(2)} mg',
  ];
}

class LabelPreview extends StatelessWidget {
  final Map<String, Object?> spec;

  /// The line above the label, saying what the picture is.
  final String note;
  const LabelPreview({super.key, required this.spec, this.note = 'PREVIEW, not a printable label'});

  @override
  Widget build(BuildContext context) {
    final lines = labelPreviewLines(spec);
    // seven lines fill the printed label; more get smaller, as labeler.py does
    final size = lines.length > 7 ? 13.0 * 7 / lines.length : 13.0;
    const ink = TextStyle(color: Colors.black);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: Colors.amber.shade100,
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          child: Text(note, textAlign: TextAlign.center),
        ),
        Container(
          height: 160,
          decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Colors.black26)),
          padding: const EdgeInsets.all(6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 84,
                child: RotatedBox(
                  quarterTurns: 3,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('${spec['strain'] ?? ''}', style: ink.copyWith(fontSize: 26, fontWeight: FontWeight.bold)),
                        Text('${spec['dose_mg_tpe'] ?? ''} mg Equiv', style: ink.copyWith(fontSize: 14)),
                      ],
                    ),
                  ),
                ),
              ),
              Container(width: 1.5, color: Colors.black, margin: const EdgeInsets.symmetric(horizontal: 8)),
              Expanded(
                // scaled down to the label's height whatever the device's font, as the printed label shrinks its lines
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final l in lines)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: Text(l, style: ink.copyWith(fontSize: size)),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// A single, shared place for "what icon goes with this productType" - used by both stock_page.dart and
// reconcile_page.dart, which both show the same type-then-strain-grouped PKPR list and want it to look
// identical. Split out to its own file (rather than defined on one of those two pages and imported by the
// other) specifically so neither page needs to import the other just to borrow this one function.
import 'package:flutter/material.dart';

/// A small icon hinting at what kind of product a PKPR group is, from nothing but its own productType string
/// (the state system's own field - see packages_client.dart's Package class comment for why there's no
/// separate, more specific "form" field to key off instead). Matched by keyword, case-insensitive, so it still
/// picks something sensible whatever exact wording the state uses ("Chocolate Edible", "Infused Honey", etc.)
/// rather than requiring an exact string match against a fixed list. Icons.inventory_2_outlined is the
/// fallback for anything this doesn't recognize - still a real icon, just not a specific one.
IconData iconForProductType(String productType) {
  final t = productType.toLowerCase();
  if (t.contains('chocolate')) return Icons.cookie_outlined;
  if (t.contains('honey')) return Icons.water_drop_outlined;
  if (t.contains('capsule') || t.contains('pill')) return Icons.medication_outlined;
  if (t.contains('gumm') || t.contains('candy') || t.contains('edible')) return Icons.icecream_outlined;
  if (t.contains('extract') || t.contains('tincture')) return Icons.science_outlined;
  if (t.contains('freeze')) return Icons.ac_unit_outlined;
  if (t.contains('dehydrat') || t.contains('dried')) return Icons.grain_outlined;
  if (t.contains('homogeni')) return Icons.blender_outlined;
  return Icons.inventory_2_outlined;
}

// The PKPR keypad's entry point (specs/hex-keypad, FR-11): the cart's PKPR input, which the cart uses in place of its
// own keyboard field while this feature is on for the center's license (in debug builds only until it is released).
import 'package:flutter/widgets.dart';

import '../../feature_entry.dart';
import 'hex_keypad.dart';

const FeatureEntry entry = FeatureEntry(pkprInput: _input);

Widget _input(BuildContext context, PkprInputArgs args) => HexKeypadInput(args: args);

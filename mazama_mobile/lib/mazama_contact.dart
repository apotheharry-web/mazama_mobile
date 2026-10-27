// specs/mazama-inventory MI-D19: the Mazama page's Contact button, at the top left across from Order. It opens a sheet
// with two ways to reach Mazama: its guest login site in the browser and a Signal message (no email address: the owner
// publishes none, specs/public-app PA-D6). Each opens
// outside the app (the browser, Signal, the mail app); a link that can't be opened says so.
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// The guest login to Mazama's site (owner, 2026-10-22: a shared guest account, given out on purpose).
final mazamaGuestLogin = Uri.parse('https://guest:ahealingjourney@login.mazamamushrooms.com');

/// Mazama's Signal username link.
final mazamaSignal = Uri.parse('https://signal.me/#eu/Mazama.01');


/// Opens [uri] outside the app; false when nothing could open it.
typedef OpenLink = Future<bool> Function(Uri uri);

Future<bool> _openOutside(Uri uri) async {
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

/// The Contact button. [open] is for tests; the app opens links outside itself.
class MazamaContactButton extends StatelessWidget {
  const MazamaContactButton({super.key, this.open});

  final OpenLink? open;

  @override
  Widget build(BuildContext context) => TextButton.icon(
        key: const ValueKey('contact-button'),
        onPressed: () => showMazamaContact(context, open: open ?? _openOutside),
        icon: const Icon(Icons.support_agent),
        label: const Text('Contact'),
      );
}

/// The contact sheet: one line per way to reach Mazama. Picking one closes the sheet and opens the link.
Future<void> showMazamaContact(BuildContext context, {required OpenLink open}) {
  final messenger = ScaffoldMessenger.of(context);
  Future<void> go(BuildContext sheet, Uri uri, String what) async {
    Navigator.of(sheet).pop();
    if (!await open(uri)) messenger.showSnackBar(SnackBar(content: Text("Couldn't open $what.")));
  }

  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('Contact Mazama', style: Theme.of(sheet).textTheme.titleMedium),
          ),
          ListTile(
            key: const ValueKey('contact-login'),
            leading: const Icon(Icons.public),
            title: const Text('Mazama website'),
            subtitle: const Text('login.mazamamushrooms.com, signed in as guest'),
            trailing: const Icon(Icons.open_in_new),
            onTap: () => go(sheet, mazamaGuestLogin, 'the Mazama website'),
          ),
          ListTile(
            key: const ValueKey('contact-signal'),
            leading: const Icon(Icons.chat_bubble_outline),
            title: const Text('Message on Signal'),
            subtitle: const Text('Mazama.01'),
            trailing: const Icon(Icons.open_in_new),
            onTap: () => go(sheet, mazamaSignal, 'Signal'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

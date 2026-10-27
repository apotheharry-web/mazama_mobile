// The sign-in page's link to this app's published source (specs/public-app PA-R6): a worker about to type their state
// password can read, or have someone check, exactly where it goes (SIGN-IN-SECURITY.md in that repository). Opens
// outside the app, in the phone's browser; it carries nothing typed on the page.
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Where this app's source and its sign-in security claims are published.
final openSourceUrl = Uri.parse('https://github.com/apotheharry-web/mazama_mobile');

const openSourceLabel = 'Open source: see where your sign-in goes';
const openSourceAddress = 'github.com/apotheharry-web/mazama_mobile';
const openSourceFailedMessage = "Couldn't open $openSourceAddress. Type it into your browser instead.";

Future<bool> _openOutside(Uri uri) async {
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

/// A small link to [openSourceUrl]. [open] is for tests; the app opens it outside itself.
class OpenSourceLink extends StatelessWidget {
  const OpenSourceLink({super.key, this.open});

  final Future<bool> Function(Uri uri)? open;

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    return TextButton(
      key: const ValueKey('open-source-link'),
      onPressed: () async {
        final opened = await (open ?? _openOutside)(openSourceUrl);
        if (!opened && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text(openSourceFailedMessage)));
        }
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(openSourceLabel, style: small, textAlign: TextAlign.center),
          Text(openSourceAddress, style: small?.copyWith(decoration: TextDecoration.underline), textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

/// The app's privacy policy, published with its source (specs/public-app PA-R8).
final privacyPolicyUrl = Uri.parse('https://github.com/apotheharry-web/mazama_mobile/blob/main/PRIVACY.md');

const privacyPolicyLabel = 'Privacy policy';
const privacyPolicyFailedMessage = "Couldn't open the privacy policy. It is PRIVACY.md at $openSourceAddress.";

/// A small link to [privacyPolicyUrl], under [OpenSourceLink]. [open] is for tests.
class PrivacyPolicyLink extends StatelessWidget {
  const PrivacyPolicyLink({super.key, this.open});

  final Future<bool> Function(Uri uri)? open;

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    return TextButton(
      key: const ValueKey('privacy-policy-link'),
      onPressed: () async {
        final opened = await (open ?? _openOutside)(privacyPolicyUrl);
        if (!opened && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text(privacyPolicyFailedMessage)));
        }
      },
      child: Text(privacyPolicyLabel, style: small?.copyWith(decoration: TextDecoration.underline)),
    );
  }
}

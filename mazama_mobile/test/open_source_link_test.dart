import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mazama_mobile/open_source_link.dart';

Widget _host(Future<bool> Function(Uri) open) =>
    MaterialApp(home: Scaffold(body: Center(child: OpenSourceLink(open: open))));

void main() {
  test('it points at the public repository, over https', () {
    expect(openSourceUrl.toString(), 'https://github.com/apotheharry-web/mazama_mobile');
    expect(openSourceAddress, '${openSourceUrl.host}${openSourceUrl.path}');
  });

  testWidgets('tapping it opens that address and nothing else', (tester) async {
    final opened = <Uri>[];
    await tester.pumpWidget(_host((u) async {
      opened.add(u);
      return true;
    }));
    expect(find.text(openSourceLabel), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('open-source-link')));
    await tester.pump();
    expect(opened, [openSourceUrl]);
    expect(find.text(openSourceFailedMessage), findsNothing);
  });

  testWidgets('when nothing can open it, it says so and gives the address to type', (tester) async {
    await tester.pumpWidget(_host((u) async => false));
    await tester.tap(find.byKey(const ValueKey('open-source-link')));
    await tester.pump();
    expect(find.text(openSourceFailedMessage), findsOneWidget);
    expect(openSourceFailedMessage, contains(openSourceAddress));
  });

  testWidgets('the privacy policy link opens PRIVACY.md in the public repository', (tester) async {
    final opened = <Uri>[];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: PrivacyPolicyLink(open: (u) async {
      opened.add(u);
      return true;
    })))));
    expect(find.text(privacyPolicyLabel), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('privacy-policy-link')));
    await tester.pump();
    expect(opened, [Uri.parse('https://github.com/apotheharry-web/mazama_mobile/blob/main/PRIVACY.md')]);
  });

  testWidgets('when the privacy policy cannot be opened, it says where to find it', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: PrivacyPolicyLink(open: (u) async => false)))));
    await tester.tap(find.byKey(const ValueKey('privacy-policy-link')));
    await tester.pump();
    expect(find.text(privacyPolicyFailedMessage), findsOneWidget);
  });
}

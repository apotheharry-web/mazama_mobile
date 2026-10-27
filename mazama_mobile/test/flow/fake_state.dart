// An emulated B2C + product-tracking server, standing in for the real state system in tests - the Dart twin of
// mazama_sales/tests/state_fake.py's FakeState. Deliberately kept close to that file's shape and behaviour so the
// two test suites are proving the same thing about the same spec.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

const tenant = 'oregonpsilocybinprodb2c';
const policy = 'b2c_1_oha_ph_psilocybin_prod_susi';
const clientId = '4dd36aed-93b7-41a6-a17a-5c367fe71f31';
const b2cHost = 'https://$tenant.b2clogin.com';
const site = 'https://psilocybin.oregon.gov/';

class FakeState {
  FakeState({this.mfaCode});

  final List<(String, String)> log = [];
  String? challenge;
  final Map<String, String> codes = {}; // code -> challenge
  final Set<String> tokens = {};
  bool refreshOk = true;
  int refreshes = 0;
  int logins = 0;
  int tokenN = 0;
  bool rejectLogin = false;
  final String csrf = 'CSRF123';
  String? pageHtml; // replaces the authorize page body, to test a page the spec doesn't expect
  int pageStatus = 200; // the status the authorize page answers with (503 = the sign-in site is down)
  int confirmedStatus = 302; // 200 answers an HTML page instead of the code redirect
  int selfAssertedStatus = 200; // the status SelfAsserted answers with (429/503 = B2C throttling or down)
  String? selfAssertedHtml; // a non-JSON body for SelfAsserted to answer with (status 200)
  int? refreshExpiresIn; // added to token bodies as refresh_token_expires_in when set
  final Map<String, dynamic> data = {};               // API path -> canned JSON response, for a write/read test
  final List<(String, dynamic)> posted = [];           // (path, decoded JSON body) of every write to the API
  // API path -> what to do instead of answering from `data`, after the write is recorded in `posted`: throw a
  // transport error, never answer, answer with a status of the test's choosing. The twin of state_fake.py's
  // own `override`.
  final Map<String, Future<http.Response> Function(http.Request)> override = {};
  // SL-R13: when set, a good email/password answers {"status": "200", "mfa": true}; a second SelfAsserted must carry
  // this as form field `code` before `confirmed` hands out the code redirect (state_fake.py's mfa_code).
  String? mfaCode;
  bool mfaPassed = false;

  http.Client client() => http_testing.MockClient(_handle);

  http.Response _token() {
    tokenN += 1;
    final t = 'ACCESS-$tokenN';
    tokens.add(t);
    final body = <String, dynamic>{'access_token': t, 'expires_in': 3600, 'refresh_token': 'REFRESH-$tokenN'};
    if (refreshExpiresIn != null) body['refresh_token_expires_in'] = refreshExpiresIn;
    return http.Response(jsonEncode(body), 200);
  }

  Future<http.Response> _handle(http.Request req) async {
    final u = req.url;
    log.add((req.method, u.path));
    final q = u.queryParameters;

    if (u.path.endsWith('/oauth2/v2.0/authorize')) {
      challenge = q['code_challenge'];
      if (q['code_challenge_method'] != 'S256' || q['client_id'] != clientId) {
        return http.Response('', 400);
      }
      final html = pageHtml ?? 'var SETTINGS = {"csrf":"$csrf","transId":"StateProperties=abc","policy":"$policy"};';
      // Real B2C sets FOUR session cookies here that SelfAsserted below checks for, not two - confirmed against
      // a real captured HAR from the actual state system, which is what caught flow_runner.dart's cookie regex
      // only being able to handle `\w`-only cookie names. Real B2C names two of them `x-ms-cpim-sso:<tenant
      // domain>_0` and `x-ms-cpim-cache|<id>_0` - the `:` and `|` are the exact characters that regex missed,
      // so these two are included here specifically to keep that bug from coming back unnoticed. The
      // comma-joined multi-cookie value (plus one cookie with its own Expires attribute, itself containing a
      // comma) mirrors exactly what package:http's IOClient produces from multiple real Set-Cookie response
      // headers (see flow_runner.dart's own comment on _mergeSetCookies for why that's the awkward case).
      return http.Response(html, pageStatus, headers: {
        'set-cookie': 'x-ms-cpim-sso:oregonpsilocybinprodb2c.onmicrosoft.com_0=SSO1; path=/; secure; httponly, '
            'x-ms-cpim-trans=TRANS1; path=/; secure; httponly, '
            'x-ms-cpim-cache|be7xvbawu0spqk0ivbh1fq_0=CACHE1; path=/; secure; httponly, '
            'x-ms-cpim-csrf=CSRF-COOKIE; expires=Wed, 21 Oct 2026 07:28:00 GMT; path=/; secure; httponly',
      });
    }
    if (u.path.endsWith('/SelfAsserted')) {
      final cookie = req.headers['cookie'] ?? '';
      if (!cookie.contains('x-ms-cpim-trans=TRANS1') ||
          !cookie.contains('x-ms-cpim-csrf=CSRF-COOKIE') ||
          !cookie.contains('x-ms-cpim-sso:oregonpsilocybinprodb2c.onmicrosoft.com_0=SSO1') ||
          !cookie.contains('x-ms-cpim-cache|be7xvbawu0spqk0ivbh1fq_0=CACHE1')) {
        return http.Response('', 403);
      }
      if (req.headers['x-csrf-token'] != csrf || req.headers['origin'] != b2cHost) return http.Response('', 403);
      final form = Uri.splitQueryString(req.body);
      if (selfAssertedStatus != 200) return http.Response('<html>busy</html>', selfAssertedStatus);
      final selfAssertedBody = selfAssertedHtml;
      if (selfAssertedBody != null) return http.Response(selfAssertedBody, 200);
      if (form.containsKey('code')) {
        // the MFA round
        if (mfaCode != null && form['code'] == mfaCode) {
          mfaPassed = true;
          return http.Response(jsonEncode({'status': '200'}), 200);
        }
        return http.Response(jsonEncode({'status': '400', 'message': 'wrong code ${form['code']}'}), 200);
      }
      final ok = form['email'] == fakeEmail && form['password'] == fakePassword && !rejectLogin;
      if (ok && mfaCode != null) {
        mfaPassed = false;
        return http.Response(jsonEncode({'status': '200', 'mfa': true}), 200);
      }
      return http.Response(jsonEncode({'status': ok ? '200' : '400', 'message': 'bad password ${form['password']}'}), 200);
    }
    if (u.path.endsWith('/CombinedSigninAndSignup/confirmed')) {
      if (q['csrf_token'] != csrf) return http.Response('', 403);
      if (confirmedStatus == 200) return http.Response('<html>signed in</html>', 200);
      if (mfaCode != null && !mfaPassed) return http.Response('<html>the code step was not done</html>', 400);
      final code = 'CODE${codes.length + 1}';
      codes[code] = challenge!;
      return http.Response('', 302, headers: {'location': '$site#code=$code&state=x'});
    }
    if (u.path.endsWith('/oauth2/v2.0/token')) {
      final form = Uri.splitQueryString(req.body);
      if (form['grant_type'] == 'authorization_code') {
        final digest = base64Url.encode(sha256.convert(utf8.encode(form['code_verifier']!)).bytes).replaceAll('=', '');
        if (codes[form['code']] != digest) return http.Response(jsonEncode({'error': 'invalid_grant'}), 400);
        logins += 1;
        return _token();
      }
      refreshes += 1;
      if (!refreshOk) return http.Response(jsonEncode({'error': 'invalid_grant'}), 400);
      return _token();
    }
    // The Dart twin of state_fake.py's own /api/private/ProductTracking/ branch, kept just as generic: a bearer
    // check, every write recorded for the test to inspect, and a canned response from `data` keyed by the path
    // after the prefix - enough to test sale.yaml's `sale` flow (POST CreateSalesRecords/false) the same way
    // the Python side already could, without a sale-specific fake of its own.
    if (u.path.startsWith('/api/private/ProductTracking/')) {
      final auth = req.headers['authorization'] ?? '';
      final token = auth.startsWith('Bearer ') ? auth.substring(7) : auth;
      if (!tokens.contains(token)) return http.Response('', 401);
      final path = u.path.replaceFirst('/api/private/ProductTracking/', '');
      if (req.method == 'POST') {
        posted.add((path, jsonDecode(req.body)));
      }
      final scripted = override[path];
      if (scripted != null) return scripted(req);
      if (!data.containsKey(path)) return http.Response('', 404);
      return http.Response(jsonEncode(data[path]), 200);
    }
    return http.Response('unexpected ${u.path}', 500);
  }
}

const fakeEmail = 'pts-user@example.org';
const fakePassword = 'p@ss w0rd/secret';

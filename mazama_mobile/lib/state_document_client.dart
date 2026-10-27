// A direct, authenticated, binary GET against the real state system's own DownloadDocument endpoint - the one
// state-system read the shared get_json flow (state_client.dart/../mazama_modules/flows/state_reads.yaml)
// deliberately leaves out, because it answers with a PDF's raw bytes, not JSON (see state_reads.yaml's own file
// comment on why this stays hand-written in each language). Mirrors mazama_sales' own
// state/client.py:StateSession.download_document field for field: same URL shape, same headers, same streamed
// read with a hard size cap so a hostile or just enormous response can't be buffered into memory unbounded.
//
// Used by coa_data_resolver.dart's own miss path: once GetPackagedProductInfo (an ordinary JSON read, already
// covered by fetchStateJson) names the document id of a lot's newest accepted Potency-test PDF, this is what
// actually fetches it, before handing the bytes to coa_data_client.dart's uploadCoaParse.
import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'flow/flow_runner.dart' show defaultRequestTimeout, redirectRules;
import 'flow/flow_spec.dart';
import 'login_hosts_store.dart' show currentAllowedHosts;
import 'select_documents.dart';
import 'state_client.dart' show stateReadsSpec;

/// At most this many redirects are followed for one document.
const maxDocumentRedirects = 5;

class StateDocumentError implements Exception {
  final String message;
  StateDocumentError(this.message);
  @override
  String toString() => message;
}

/// GETs DownloadDocument/{docId} against the real state system and returns the raw bytes - almost always a lab
/// report PDF, in this app's own use (coa_data_resolver.dart). Refuses anything over [limit] bytes (default a
/// touch above mazama_sales' adhoc-COA upload cap - PDF_PARSE_MAX in web/stock_pages.py - so a document that
/// would just be rejected by the upload isn't fully downloaded first for nothing) by aborting the stream rather
/// than buffering an unbounded response into memory. Throws [StateDocumentError] on a network problem, a 401
/// (session expired - this call does not retry, the same policy state_client.dart's fetchStateJson already
/// documents for every other state-system read in this app), any other non-200 status, exceeding [limit], or
/// going quiet for [timeout] - no answer, or no data part way through (SM-12/SM-D1: the same 60 s as every
/// flow-spec request; a limit on silence rather than on the whole download, so a slow but moving PDF still
/// arrives).
///
/// The API base, Referer, Origin and User-Agent are state_reads.yaml's `api`, `site`, `site_origin` and
/// `user_agent` (SM-20), the same values every shared read sends; [spec] overrides the cached
/// assets/flows/state_reads.yaml parse, mainly for tests.
Future<Uint8List> downloadStateDocument(int docId,
    {required String accessToken,
    int limit = labReportMaxBytes, // SM-D23: the one 2 MB cap, the same as the server's
    http.Client? client,
    Duration timeout = defaultRequestTimeout,
    FlowSpec? spec,
    Iterable<String>? allowedHosts}) async {
  final c = client ?? http.Client();
  final shouldClose = client == null;
  try {
    final vars = (spec ?? await stateReadsSpec()).vars;
    var uri = Uri.parse('${vars['api']}DownloadDocument/$docId');
    // The session's token goes only to an allowed host (the shared allowlist, SL-R8/SL-R18), and on a redirect only
    // to the origin first asked (the same scheme, host and port): the redirects are followed here, not by
    // package:http, so a hop to another host (a storage service, say) or another port never carries the Authorization
    // header.
    if (!hostAllowedUrl(uri.toString(), allowed: allowedHosts ?? currentAllowedHosts())) {
      throw StateDocumentError('refusing to send the session to ${uri.host}: not an allowed state host');
    }
    final first = uri;
    bool sameOrigin(Uri u) => u.scheme == first.scheme && u.host == first.host && u.port == first.port;
    http.StreamedResponse resp;
    var hops = 0;
    while (true) {
      final req = http.Request('GET', uri)
        ..followRedirects = false
        ..headers['Referer'] = vars['site']!
        ..headers['Origin'] = vars['site_origin']!
        ..headers['User-Agent'] = vars['user_agent']!;
      if (sameOrigin(uri)) req.headers['Authorization'] = 'Bearer $accessToken';
      try {
        resp = await c.send(req).timeout(timeout);
      } on TimeoutException {
        throw StateDocumentError('no answer from ${uri.host} within ${timeout.inSeconds} s');
      } catch (ex) {
        throw StateDocumentError('cannot reach ${uri.host}: ${ex.runtimeType}');
      }
      final location = resp.headers['location'];
      if (!redirectRules(resp.statusCode, 'GET') || location == null || location.isEmpty) break;
      try {
        await resp.stream.drain<void>().timeout(timeout);
      } catch (_) {
        // the redirect's own body doesn't matter
      }
      hops += 1;
      if (hops > maxDocumentRedirects) {
        throw StateDocumentError('DownloadDocument/$docId was redirected more than $maxDocumentRedirects times');
      }
      final next = uri.resolve(location);
      if (next.scheme != 'https') {
        throw StateDocumentError('DownloadDocument/$docId was redirected to a non-https address');
      }
      uri = next;
    }
    if (resp.statusCode == 401) {
      throw StateDocumentError('the state system no longer accepts this session - sign in again');
    }
    if (resp.statusCode != 200) {
      throw StateDocumentError('DownloadDocument/$docId failed: HTTP ${resp.statusCode}');
    }
    final buf = BytesBuilder(copy: false);
    try {
      await for (final chunk in resp.stream.timeout(timeout)) {
        buf.add(chunk);
        if (buf.length > limit) {
          throw StateDocumentError('DownloadDocument/$docId is larger than $limit bytes');
        }
      }
    } on StateDocumentError {
      rethrow;
    } on TimeoutException {
      throw StateDocumentError('DownloadDocument/$docId stopped arriving for ${timeout.inSeconds} s');
    } catch (ex) {
      throw StateDocumentError('cannot reach ${uri.host}: ${ex.runtimeType}');
    }
    return buf.toBytes();
  } finally {
    if (shouldClose) c.close();
  }
}

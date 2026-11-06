// A debug-only look at the state system's transport manifests: type a service center's state id and read
// GetManifests/<id>/ServiceCenter directly (state_client.dart's generic read), then download a manifest's
// uploaded PDF (state_document_client.dart's DownloadDocument) and show it with pdfrx - the same reads the app
// makes elsewhere, run here on their own, and for a center this account may not even hold a license for (the
// same convenience debug_launch_cart_page.dart already offers for the cart).
//
// A manifest list entry is the state system's own: an id, the departure date, and its documents - one of them
// the signed PDF a transfer uploaded (AddTransportManifest, "Manifest<id>.pdf"). "Newest" is the latest
// departure date (an entry with no readable date sorts oldest); the button fetches the newest manifest that
// actually carries a PDF, and any other row can be tapped to fetch that one instead.
//
// Only ever reachable from a kDebugMode build - see debug_tools_page.dart, which is what links to this. Every
// failure (a bad id, a 401, an empty list, a manifest with no PDF) is shown plainly, never swallowed or fatal.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import 'session.dart';
import 'state_client.dart' show fetchStateJson;
import 'state_document_client.dart' show downloadStateDocument;

/// How a center's manifest list is fetched: `GetManifests/<stateId>/ServiceCenter` by default (state_client.dart).
typedef ManifestFetch = Future<Object?> Function(int stateId, {required String accessToken});

/// How one document's bytes are fetched: `DownloadDocument/<docId>` by default (state_document_client.dart).
typedef DocumentFetch = Future<Uint8List> Function(int docId, {required String accessToken});

/// How a fetched PDF is shown: pdfrx's viewer by default (the app's own PDF view).
typedef PdfView = Widget Function(Uint8List pdf);

/// The size cap for a manifest PDF - well above the lab-report one: a manifest is a few pages, but a generous
/// cap avoids a confusing "larger than N bytes" failure over nothing.
const manifestPdfMaxBytes = 20 << 20;

/// The app's PDF view for a manifest: pdfrx's viewer. Kept here rather than reusing the review page's own
/// pdfrxView, because this page is copied into the public app, which leaves that unreleased feature out.
Widget manifestPdfView(Uint8List pdf) => PdfViewer.data(pdf, sourceName: 'transport-manifest.pdf');

/// One document attached to a manifest (the state's own fields: an id, a name, an extension).
class ManifestDocument {
  final int id;
  final String? name;
  final bool isPdf;
  const ManifestDocument(this.id, this.name, this.isPdf);
}

/// One manifest in a center's list: its id, the date shown and sorted on, and its documents.
class Manifest {
  final int id;
  final String? date;
  final List<ManifestDocument> documents;
  const Manifest(this.id, this.date, this.documents);

  /// The document to download: the first that looks like the uploaded PDF, or - defensively - the only
  /// document there is, when the reply names none as a PDF but clearly carries one.
  ManifestDocument? get pdfDocument {
    for (final d in documents) {
      if (d.isPdf) return d;
    }
    return documents.length == 1 ? documents.first : null;
  }
}

/// Parses a GetManifests reply (a JSON list) into manifests, newest first. Throws [FormatException] on a shape
/// it can't read (not a list, or an entry without a numeric id), which the page shows plainly.
List<Manifest> parseManifests(Object? body) {
  if (body is! List) throw const FormatException('GetManifests did not answer a list');
  final out = <Manifest>[];
  for (final raw in body) {
    if (raw is! Map) throw const FormatException('a manifest entry was not an object');
    final id = raw['id'];
    if (id is! int) throw const FormatException('a manifest entry had no numeric id');
    out.add(Manifest(id, _dateOf(raw), _documentsOf(raw)));
  }
  out.sort((a, b) {
    final byDate = (b.date ?? '').compareTo(a.date ?? ''); // newest date first; no date sorts last
    return byDate != 0 ? byDate : b.id.compareTo(a.id);
  });
  return out;
}

/// The date to show and sort a manifest on: its departure, else its arrival, else when it was created.
String? _dateOf(Map raw) {
  for (final key in const ['dateOfDeparture', 'dateOfArrival', 'dateCreated']) {
    final v = raw[key];
    if (v is String && v.isNotEmpty) return v;
  }
  return null;
}

List<ManifestDocument> _documentsOf(Map raw) {
  final docs = raw['documents'];
  if (docs is! List) return const [];
  final out = <ManifestDocument>[];
  for (final d in docs) {
    if (d is! Map) continue;
    final id = d['id'];
    if (id is! int) continue;
    final name = d['name'] is String ? d['name'] as String : null;
    out.add(ManifestDocument(id, name, _looksPdf(d, name)));
  }
  return out;
}

/// Whether a document entry is the PDF: its extension (either spelling the state uses) or its name says so.
bool _looksPdf(Map d, String? name) {
  for (final key in const ['extension', 'extenstion', 'fileExtension']) {
    final v = d[key];
    if (v is String && v.toLowerCase().replaceAll('.', '').endsWith('pdf')) return true;
  }
  return name != null && name.toLowerCase().endsWith('.pdf');
}

class DebugTransportManifestPage extends StatefulWidget {
  final Session session;

  /// Pre-fills the state-id field, same convenience as every other debug page's own initialStateId.
  final int? initialStateId;

  /// Overridable for tests. Defaults to the real GetManifests read (state_client.dart).
  final ManifestFetch fetchManifests;

  /// Overridable for tests. Defaults to the real DownloadDocument read (state_document_client.dart).
  final DocumentFetch fetchDocument;

  /// Overridable for tests. Defaults to pdfrx's viewer; a test passes a plain widget so it never starts pdfium.
  final PdfView pdfView;

  DebugTransportManifestPage({
    super.key,
    required this.session,
    this.initialStateId,
    ManifestFetch? fetchManifests,
    DocumentFetch? fetchDocument,
    PdfView? pdfView,
  })  : fetchManifests = fetchManifests ?? _stateManifests,
        fetchDocument = fetchDocument ?? _stateDocument,
        pdfView = pdfView ?? manifestPdfView;

  static Future<Object?> _stateManifests(int stateId, {required String accessToken}) =>
      fetchStateJson('GetManifests/$stateId/ServiceCenter', accessToken: accessToken);

  static Future<Uint8List> _stateDocument(int docId, {required String accessToken}) =>
      downloadStateDocument(docId, accessToken: accessToken, limit: manifestPdfMaxBytes);

  @override
  State<DebugTransportManifestPage> createState() => _DebugTransportManifestPageState();
}

class _DebugTransportManifestPageState extends State<DebugTransportManifestPage> {
  late final _stateIdController = TextEditingController(text: widget.initialStateId?.toString() ?? '');

  bool _busy = false;
  List<Manifest>? _manifests;
  String? _error;
  Uint8List? _pdf;

  /// The manifest the shown [pdf] came from, for the heading above it.
  int? _pdfManifestId;

  @override
  void dispose() {
    _stateIdController.dispose();
    super.dispose();
  }

  int? get _stateId => int.tryParse(_stateIdController.text.trim());

  Future<void> _findNewest() async {
    final stateId = _stateId;
    if (stateId == null) {
      setState(() {
        _error = 'Enter a numeric state id first.';
        _manifests = null;
        _pdf = null;
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _manifests = null;
      _pdf = null;
      _pdfManifestId = null;
    });
    try {
      final body = await widget.fetchManifests(stateId, accessToken: widget.session.accessToken);
      final manifests = parseManifests(body);
      if (!mounted) return;
      setState(() => _manifests = manifests);
      final withPdf = manifests.where((m) => m.pdfDocument != null).toList();
      if (withPdf.isEmpty) {
        setState(() => _error = manifests.isEmpty
            ? 'That center has no manifests.'
            : 'None of these manifests carries a PDF document.');
        return;
      }
      await _download(withPdf.first);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download(Manifest manifest) async {
    final doc = manifest.pdfDocument;
    if (doc == null) {
      setState(() => _error = 'Manifest ${manifest.id} has no PDF document.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _pdf = null;
    });
    try {
      final bytes = await widget.fetchDocument(doc.id, accessToken: widget.session.accessToken);
      if (!mounted) return;
      setState(() {
        _pdf = bytes;
        _pdfManifestId = manifest.id;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final manifests = _manifests;
    return Scaffold(
      appBar: AppBar(title: const Text('Transport manifest (debug)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Service center state id', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text("Reads GetManifests/<id>/ServiceCenter from the state system, then downloads the newest "
              "manifest's PDF (DownloadDocument) and shows it. Tap any other row to fetch its PDF instead."),
          const SizedBox(height: 8),
          TextField(
            controller: _stateIdController,
            decoration: const InputDecoration(labelText: 'Service center state id', border: OutlineInputBorder()),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _busy ? null : _findNewest,
            child: Text(_busy ? 'Fetching...' : 'Fetch newest manifest PDF'),
          ),
          if (_error != null) _errorText(_error!),
          if (manifests != null) ..._manifestList(context, manifests),
          if (_pdf != null) ...[
            const Divider(height: 32),
            Text('PDF for manifest $_pdfManifestId (${_pdf!.length} bytes)',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SizedBox(height: 420, child: widget.pdfView(_pdf!)),
          ],
        ],
      ),
    );
  }

  List<Widget> _manifestList(BuildContext context, List<Manifest> manifests) => [
        const Divider(height: 32),
        Text('${manifests.length} manifest(s), newest first.', style: Theme.of(context).textTheme.bodySmall),
        if (manifests.isEmpty) const Text('No manifests for this center.'),
        for (final m in manifests)
          ListTile(
            dense: true,
            title: Text('Manifest ${m.id}${m.date != null ? ' - ${m.date}' : ''}'),
            subtitle: Text('${m.documents.length} document(s)'
                '${m.pdfDocument != null ? ', PDF ${m.pdfDocument!.id}' : ', no PDF'}'),
            enabled: !_busy && m.pdfDocument != null,
            onTap: m.pdfDocument == null ? null : () => _download(m),
          ),
      ];

  Widget _errorText(String text) =>
      Padding(padding: const EdgeInsets.only(top: 8), child: Text(text, style: TextStyle(color: Colors.red[800])));
}

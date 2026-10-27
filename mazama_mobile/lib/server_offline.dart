// What the phone does with Mazama's own pages while Mazama's server can't be reached (it can be down for days):
//   - reads (par levels, the stock page's product information sheets, Mazama's own stock) show the copy kept on the
//     phone from the last successful read, with when that was, under a notice that doesn't block the page
//     ([readWithCache], [ServerOfflineNotice]); with no copy kept, the error as before;
//   - writes (saving par levels, placing an order) are never queued: the worker is told to try again later, and the
//     page keeps what they typed so they can ([serverTryLater]).
// "Can't be reached" is server_error.dart's one rule (isServerUnreachable): no connection, no answer in time, or a
// 5xx. A 4xx (a bad app key, an unknown center, a refused value) is still shown as the error it is.
//
// No age limit on the copy shown: nothing is sold from these pages, the copy always says when it is from, and a
// write it might lead to can't go through until the server answers again. An old figure with its date is more use
// to a worker than an error.
import 'package:flutter/material.dart';

import 'server_error.dart';

/// A read of one of Mazama's pages: the server's reply, or ([fromCache]) the copy kept on the phone because the
/// server couldn't be reached, with when the server sent it ([cachedAt]; null when a copy kept by an older build
/// didn't record it).
class ServerRead<T> {
  const ServerRead(this.value)
      : fromCache = false,
        cachedAt = null;

  const ServerRead.cached(this.value, this.cachedAt) : fromCache = true;

  final T value;
  final bool fromCache;
  final DateTime? cachedAt;
}

/// Reads with [fetch]; on success keeps the reply with [save] (stamped [now], in UTC; best effort) and returns it.
/// When the server can't be reached ([isServerUnreachable]) returns the copy [load] gives back instead; with none
/// kept, or for any other failure, the fetch's own error is thrown.
Future<ServerRead<T>> readWithCache<T>({
  required Future<T> Function() fetch,
  required Future<void> Function(T value, DateTime at) save,
  required Future<ServerRead<T>?> Function() load,
  DateTime Function() now = DateTime.now,
}) async {
  final T value;
  try {
    value = await fetch();
  } catch (e) {
    if (!isServerUnreachable(e)) rethrow;
    ServerRead<T>? kept;
    try {
      kept = await load();
    } catch (_) {
      kept = null; // an unreadable copy counts as none
    }
    if (kept == null) rethrow;
    return kept;
  }
  try {
    await save(value, now().toUtc());
  } catch (_) {
    // the copy for later is best effort; the reply itself is good
  }
  return ServerRead(value);
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// [at] in the phone's own time, as the notice writes it: "Oct 21, 2026 at 6:05 AM".
String formatAsOf(DateTime at) {
  final t = at.toLocal();
  final hour = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final minute = t.minute.toString().padLeft(2, '0');
  return '${_months[t.month - 1]} ${t.day}, ${t.year} at $hour:$minute ${t.hour < 12 ? 'AM' : 'PM'}';
}

/// The start of every message about Mazama's server being down.
const serverUnreachable = "Mazama's server can't be reached";

/// The notice over a page showing the copy kept on the phone.
String serverOfflineNotice(DateTime? at) =>
    at == null ? '$serverUnreachable - showing what it last sent.' : '$serverUnreachable - showing what it last sent on ${formatAsOf(at)}.';

/// What a write that couldn't reach the server says (after "Par levels were not saved: ", "The order was not sent: ").
const serverTryLater = '$serverUnreachable - try again later.';

/// The banner over a page showing the copy kept on the phone: the page stays usable under it. [onRetry] adds a Retry.
class ServerOfflineNotice extends StatelessWidget {
  const ServerOfflineNotice({super.key, required this.cachedAt, this.extra, this.onRetry});

  final DateTime? cachedAt;

  /// A sentence after the notice, for what the page can't do meanwhile.
  final String? extra;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = extra == null ? serverOfflineNotice(cachedAt) : '${serverOfflineNotice(cachedAt)} $extra';
    return Container(
      key: const ValueKey('server-offline-notice'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(color: scheme.tertiaryContainer, borderRadius: BorderRadius.circular(8)),
      child: Row(
        children: [
          Icon(Icons.cloud_off, size: 20, color: scheme.onTertiaryContainer),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(color: scheme.onTertiaryContainer))),
          if (onRetry != null) TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

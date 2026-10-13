import 'dart:js_interop';
import 'package:web/web.dart' as web;
import '../services.dart';

/// Preserve the dashboard's plain-HTTP clipboard fallback and bounded wait.
Future<String> copyTextOrDownload(
  String text,
  String filename, {
  String copied = 'Copied.',
  String downloaded = 'Clipboard unavailable over HTTP; downloaded instead.',
  Future<void> Function(String)? copy,
  Future<void> Function(String, String)? download,
}) async {
  try {
    await (copy ?? _copy)(text).timeout(const Duration(seconds: 3));
    return copied;
  } catch (_) {
    try {
      await (download ?? downloadText)(text, filename);
      return downloaded;
    } catch (_) {
      return 'Copy and download failed. Select the text to copy it manually.';
    }
  }
}

Future<void> _copy(String value) =>
    web.window.navigator.clipboard.writeText(value).toDart;

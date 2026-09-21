/// Web delivery — a real browser download, the web POS `downloadCsv` flow
/// (UTF-8 BOM so Excel opens it clean).
library;

import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

Future<bool> exportCsv(String filename, String text) async {
  final doc = web.document;
  final anchor = doc.createElement('a') as web.HTMLAnchorElement;
  final bytes = utf8.encode('\uFEFF$text');
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: 'text/csv;charset=utf-8'),
  );
  anchor.href = web.URL.createObjectURL(blob);
  anchor.download = filename;
  doc.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();
  return true;
}

/// CSV export — the Flutter half of the web POS `lib/csv.js` +
/// `lib/purchaseExport.js` (ReportsView's Today/Month CSV, PurchasesView's
/// export). RFC-4180 quoting, UTF-8 BOM so Excel opens it clean.
///
/// Web delivers a browser download; native copies to the clipboard (the
/// share/save targets come with release signing work — the data is
/// identical either way).
library;

export 'csv_delivery_stub.dart'
    if (dart.library.js_interop) 'csv_delivery_web.dart'
    if (dart.library.io) 'csv_delivery_io.dart' show exportCsv;

/// RFC-4180 cell: quote anything with a comma, quote or newline.
String csvCell(dynamic v) {
  final s = v == null ? '' : '$v';
  if (s.contains(',') || s.contains('"') || s.contains('\n') || s.contains('\r')) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}

/// Build CSV text from [headers] + [rows].
String toCsv(List<String> headers, List<List<dynamic>> rows) {
  final buf = StringBuffer();
  buf.writeln(headers.map(csvCell).join(','));
  for (final row in rows) {
    buf.writeln(row.map(csvCell).join(','));
  }
  return buf.toString();
}

/* exportCsv lives in the platform-delivery files */

/// Purchases export rows — one CSV line per purchased item line, the web
/// `purchaseExport.js` shape (date, supplier, item, qty, unit, line cost,
/// total, paid, method, notes).
List<List<dynamic>> purchaseRows(List<dynamic> purchases) {
  final rows = <List<dynamic>>[];
  for (final p in purchases) {
    final lines = p.lines as List;
    if (lines.isEmpty) {
      rows.add([
        p.date ?? '', p.supplierName, '—', '', '', 0, p.total, p.paid,
        p.paymentMethod ?? '', p.notes,
      ]);
      continue;
    }
    for (final l in lines) {
      rows.add([
        p.date ?? '', p.supplierName, l.name, l.qty, l.unit, l.totalCost,
        p.total, p.paid, p.paymentMethod ?? '', p.notes,
      ]);
    }
  }
  return rows;
}

/// Filename for the purchases export — `purchases-YYYY-MM-DD.csv`.
String purchaseExportName(DateTime now) =>
    'purchases-${now.year.toString().padLeft(4, '0')}-'
    '${now.month.toString().padLeft(2, '0')}-'
    '${now.day.toString().padLeft(2, '0')}.csv';

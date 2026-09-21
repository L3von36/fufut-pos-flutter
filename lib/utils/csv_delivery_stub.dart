/// Stub delivery — overridden per platform by the conditional export in
/// csv.dart (web = browser download, native = clipboard).
library;

Future<bool> exportCsv(String filename, String text) async => false;

/// Native delivery — the CSV text lands on the clipboard (with the toast
/// the caller shows); share/save targets arrive with release-signing work.
library;

import 'package:flutter/services.dart';

Future<bool> exportCsv(String filename, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  return false;
}

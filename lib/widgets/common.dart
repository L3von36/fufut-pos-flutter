import 'package:flutter/material.dart';

/// Small shared helpers for the POS screens.

/// Shows an error snackbar — used everywhere an action fails and the message
/// came from the server (which writes them to be human-readable).
void showError(BuildContext context, Object error) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text('$error'),
    backgroundColor: const Color(0xFFB3261E),
    duration: const Duration(seconds: 4),
  ));
}

void showInfo(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(message),
    backgroundColor: const Color(0xFF0F7B78),
    duration: const Duration(seconds: 2),
  ));
}

/// Captured-messenger variants. An async action that pops its own sheet
/// cannot use a BuildContext afterwards — the messenger state is the safe
/// handle: captured before the await, used after it, no mounted dance needed.
void showErrorOn(ScaffoldMessengerState messenger, Object error) {
  messenger.showSnackBar(SnackBar(
    content: Text('$error'),
    backgroundColor: const Color(0xFFB3261E),
    duration: const Duration(seconds: 4),
  ));
}

void showInfoOn(ScaffoldMessengerState messenger, String message) {
  messenger.showSnackBar(SnackBar(
    content: Text(message),
    backgroundColor: const Color(0xFF0F7B78),
    duration: const Duration(seconds: 2),
  ));
}

/// The till displays the last 4 characters of an order id ("Order #abc123").
/// Empty ids render as an empty tag rather than "#".
String shortId(String id) =>
    id.isEmpty ? '' : '#${id.substring(id.length >= 4 ? id.length - 4 : 0)}';

/// Status pill colors shared between Orders and the detail sheet.
Color statusColor(String status) {
  switch (status.toLowerCase()) {
    case 'new':
      return const Color(0xFF42A5F5);
    case 'preparing':
      return const Color(0xFFFFB74D);
    case 'ready':
      return const Color(0xFF66BB6A);
    case 'served':
    case 'completed':
      return const Color(0xFF9E9E9E);
    case 'cancelled':
      return const Color(0xFFEF5350);
    default:
      return const Color(0xFF78909C);
  }
}

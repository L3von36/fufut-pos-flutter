/// The "Ask for the Bill" sheet — the floor's request with the guest's
/// intended payment method attached.
///
/// Why the method travels with the request (owner's friend, 2026-09-25):
/// the cashier who receives a bill request had no way to know whether the
/// guest is waiting to hand over cash or is about to send a telebirr
/// transfer — and no way to see WHERE the money should go. The sheet fixes
/// the handoff on both ends:
///
///   * the waiter picks what the guest said (cash / telebirr / CBE / bank /
///     card / other) — it lands on the table's open checks so the cashier's
///     settle queue opens knowing cash vs transfer;
///   * for a transfer, the sheet shows the venue's receiving accounts
///     (settings key `payments.channels`) so the waiter can tell the guest
///     exactly which number to send the money to — no more walking to the
///     till to ask for the telebirr number.
///
/// Manager note: empty channels are hidden; fill `payments.channels` in
/// Settings (PUT /api/settings/payments.channels) to add the real numbers.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';

/// The methods the floor can declare, in tap order. Mirrors the till's
/// method grid (checkout_sheet) so a request always maps onto a settle.
const List<(String, String, IconData)> _kBillMethods = [
  ('cash', 'Cash', Icons.payments_outlined),
  ('telebirr', 'Telebirr', Icons.phone_android),
  ('cbe', 'CBE Birr', Icons.grid_view_outlined),
  ('bank', 'Bank', Icons.account_balance_outlined),
  ('card', 'Card', Icons.credit_card),
  ('other', 'Other', Icons.more_horiz_rounded),
];

const Set<String> _kDigital = {'telebirr', 'cbe', 'bank', 'mobile', 'card'};

/// Opens the sheet; returns the chosen method, or null when dismissed.
Future<String?> showBillRequestSheet(BuildContext context, WidgetRef ref) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Pal.of(context).surface,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (_) => const _BillRequestSheet(),
  );
}

class _BillRequestSheet extends ConsumerStatefulWidget {
  const _BillRequestSheet();

  @override
  ConsumerState<_BillRequestSheet> createState() => _BillRequestSheetState();
}

class _BillRequestSheetState extends ConsumerState<_BillRequestSheet> {
  String _method = 'cash';
  List<PaymentChannel>? _channels;

  @override
  void initState() {
    super.initState();
    _loadChannels();
  }

  Future<void> _loadChannels() async {
    final app = ref.read(appStateProvider);
    final rows = await app.api.venuePaymentChannels();
    if (mounted) setState(() => _channels = rows);
  }

  PaymentChannel? get _matchingChannel {
    final rows = _channels;
    if (rows == null) return null;
    for (final c in rows) {
      if (c.method == _method) return c;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final digital = _kDigital.contains(_method);
    final PaymentChannel? channel = _matchingChannel;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Ask for the bill',
                style: T.screenTitle.copyWith(color: pal.heading)),
            const SizedBox(height: 4),
            Text(
                'How will the guest pay? The till sees it the moment the '
                'request lands.',
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 12, color: pal.muted)),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (value, label, icon) in _kBillMethods)
                  _MethodChip(
                    icon: icon,
                    label: label,
                    active: _method == value,
                    onTap: () => setState(() => _method = value),
                  ),
              ],
            ),
            if (digital) ...[
              const SizedBox(height: 14),
              _ChannelsBox(
                  method: _method, channel: channel, channels: _channels),
            ],
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12)),
                    child: Text('Cancel',
                        style: TextStyle(
                            fontFamily: kFontBody, color: pal.body)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: () => Navigator.pop(context, _method),
                    icon: const Icon(Icons.request_quote_rounded, size: 17),
                    label: Text('Request the bill · ${_methodCapitalized()}',
                        style: const TextStyle(fontFamily: kFontBody)),
                    style: FilledButton.styleFrom(
                        backgroundColor: pal.primary,
                        padding: const EdgeInsets.symmetric(vertical: 12)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _methodCapitalized() {
    final m = _method;
    if (m.isEmpty) return m;
    return m[0].toUpperCase() + m.substring(1);
  }
}

class _MethodChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _MethodChip({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: active ? pal.primary : pal.sunken,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: active ? pal.primary : pal.border, width: active ? 1.4 : 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 15, color: active ? Colors.white : pal.muted),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 12.5,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    color: active ? Colors.white : pal.body)),
          ],
        ),
      ),
    );
  }
}

/// The venue's receiving accounts for the chosen digital method — the answer
/// to "which number do I tell the guest to send to?" (owner's friend,
/// 2026-09-25). Falls back to an honest hint when the venue has not filled
/// the channel in yet.
class _ChannelsBox extends StatelessWidget {
  final String method;
  final PaymentChannel? channel;
  final List<PaymentChannel>? channels;

  const _ChannelsBox({required this.method, this.channel, this.channels});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final ch = channel;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: pal.tintBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: pal.border),
      ),
      child: ch == null
          ? Row(
              children: [
                Icon(Icons.info_outline, size: 14, color: pal.muted),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    channels == null
                        ? 'Loading receiving accounts…'
                        : 'No $method account on file yet — a manager can add '
                            'it under Settings → payments.channels. The '
                            'cashier will collect the details at the till.',
                    style: TextStyle(
                        fontFamily: kFontBody, fontSize: 11.5, color: pal.muted),
                  ),
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Send the money to',
                    style: TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                        color: pal.muted)),
                const SizedBox(height: 5),
                Row(
                  children: [
                    Icon(Icons.copy_all_rounded,
                        size: 13, color: pal.primary),
                    const SizedBox(width: 6),
                    Text(ch.account,
                        style: T.mono.copyWith(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w800,
                            color: pal.heading)),
                    if (ch.holder.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(ch.holder,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 11.5,
                                color: pal.muted)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                    'Tell the guest to keep the confirmation SMS — the '
                    'cashier matches it before confirming the money.',
                    style: TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 10.5,
                        color: pal.faint)),
              ],
            ),
    );
  }
}

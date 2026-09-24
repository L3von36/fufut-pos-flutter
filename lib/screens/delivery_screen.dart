/// Delivery run list — the web POS `DeliveryView.vue`, native.
///
/// The driver's jobs, newest first, each with the order behind it (what is in
/// the bag, what it comes to, whether it is paid) and one action to move it
/// along: assign → pick up → delivered. Status labels mirror the server's
/// delivery pipeline.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/dashboard.dart';

class DeliveryScreen extends StatefulWidget {
  const DeliveryScreen({super.key});

  @override
  State<DeliveryScreen> createState() => _DeliveryScreenState();
}

class _DeliveryScreenState extends State<DeliveryScreen> {
  List<DeliveryJob> _jobs = [];
  bool _loading = true;
  Object? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 45), (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    final app = context.read<AppState>();
    if (!quiet) setState(() { _loading = true; _error = null; });
    try {
      final jobs = await app.api.deliveries();
      if (!mounted) return;
      setState(() { _jobs = jobs; _loading = false; });
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.isAuthError) {
        await app.sessionExpired();
        return;
      }
      setState(() { _loading = false; _error = e; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e; });
    }
  }

  Future<void> _advance(DeliveryJob j) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final to = _next(j.status);
    if (to == null) return;
    try {
      await app.api.advanceDelivery(j.id, to);
      showInfoOn(messenger, 'Job → ${_label(to)}');
      await _load(quiet: true);
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  /// The pipeline the server accepts for a driver's taps.
  static String? _next(String status) {
    switch (status) {
      case 'new': case 'confirmed': case 'preparing': case 'ready':
        return 'assigned';
      case 'assigned':
        return 'out-for-delivery';
      case 'out-for-delivery':
        return 'delivered';
      default:
        return null;
    }
  }

  static String _label(String s) {
    switch (s) {
      case 'assigned': return 'Assigned to me';
      case 'out-for-delivery': return 'Out for delivery';
      case 'delivered': return 'Delivered';
      default: return s;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _jobs.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _jobs.isEmpty) {
      return LoadError(error: _error!, onRetry: () => _load());
    }
    // Live work first, finished last.
    final open = _jobs.where((j) {
      final s = j.status;
      return s != 'delivered' && s != 'settled' && s != 'cancelled';
    }).toList();
    final done = _jobs.where((j) {
      final s = j.status;
      return s == 'delivered' || s == 'settled';
    }).toList();

    return RefreshIndicator(
      onRefresh: () => _load(quiet: true),
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const GreetingHeader(),
          const SizedBox(height: 12),
          if (open.isEmpty)
            const EmptyState(
              icon: Icons.local_shipping_outlined,
              title: 'No jobs on the run',
              hint: 'New delivery orders appear here as the till sends them',
            )
          else ...[
            Text('MY RUN (${open.length})',
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    color: Pal.of(context).muted)),
            const SizedBox(height: 8),
            for (final j in open)
              _JobCard(job: j, onAdvance: () => _advance(j)),
          ],
          if (done.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text('DELIVERED (${done.length})',
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    color: Pal.of(context).muted)),
            const SizedBox(height: 8),
            for (final j in done.take(8))
              _JobCard(job: j, onAdvance: null),
          ],
        ],
      ),
    );
  }
}

class _JobCard extends StatelessWidget {
  final DeliveryJob job;
  final Future<void> Function()? onAdvance;

  const _JobCard({required this.job, required this.onAdvance});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final s = job.status;
    final active = onAdvance != null;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: pal.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text(job.customer?.isNotEmpty == true ? job.customer! : 'Customer',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: pal.heading)),
            ),
            Text(money(job.total),
                style: TextStyle(
                    fontFamily: kFontMono,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: pal.heading)),
          ]),
          if (job.address?.isNotEmpty == true) ...[
            const SizedBox(height: 3),
            Row(children: [
              Icon(Icons.location_on_outlined, size: 12, color: pal.faint),
              const SizedBox(width: 4),
              Expanded(
                child: Text(job.address!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontFamily: kFontBody, fontSize: 11.5, color: pal.muted)),
              ),
            ]),
          ],
          if (job.itemsRaw?.isNotEmpty == true) ...[
            const SizedBox(height: 3),
            Text(job.itemsRaw!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 10.5, color: pal.faint)),
          ],
          const SizedBox(height: 8),
          Row(children: [
            StatusBadge(status: s),
            const SizedBox(width: 6),
            if (job.phone?.isNotEmpty == true) ...[
              Icon(Icons.phone_outlined, size: 12, color: pal.faint),
              const SizedBox(width: 3),
              Expanded(
                child: Text(job.phone!,
                    style: TextStyle(
                        fontFamily: kFontMono, fontSize: 10.5, color: pal.muted)),
              ),
            ] else
              const Spacer(),
            if (job.isPaid)
              const PayBadge(paid: true)
            else
              const PayBadge(paid: false),
          ]),
          if (active && s != 'delivered') ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              height: 32,
              child: AsyncButton(
                onPressed: onAdvance!,
                label: _nextLabel(s),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _nextLabel(String s) {
    switch (s) {
      case 'new': case 'confirmed': case 'preparing': case 'ready':
        return 'Take this job';
      case 'assigned':
        return 'Start delivery';
      case 'out-for-delivery':
        return 'Mark delivered';
      default:
        return s;
    }
  }
}

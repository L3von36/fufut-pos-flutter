/// Delivery run list — the web POS `DeliveryView.vue`, native.
///
/// The driver's jobs, newest first, each with the order behind it (what is in
/// the bag, what it comes to, whether it is paid) and one action to move it
/// along: assign → pick up → delivered. Status labels mirror the server's
/// delivery pipeline. The list is the shared [deliveriesProvider] — the
/// driver's dashboard reads the same feed — and the minute clock stands in
/// for the old 45s poll.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../state/catalog_providers.dart';
import '../state/clock.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/dashboard.dart';

class DeliveryScreen extends ConsumerStatefulWidget {
  const DeliveryScreen({super.key});

  @override
  ConsumerState<DeliveryScreen> createState() => _DeliveryScreenState();
}

class _DeliveryScreenState extends ConsumerState<DeliveryScreen> {
  void _reload() => ref.invalidate(deliveriesProvider);

  Future<void> _advance(DeliveryJob j) async {
    final app = ref.read(appStateProvider);
    final messenger = ScaffoldMessenger.of(context);
    final to = _next(j.status);
    if (to == null) return;
    try {
      await app.api.advanceDelivery(j.id, to);
      showInfoOn(messenger, 'Job → ${_label(to)}');
      _reload();
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
    // The old 45s poll; the shared feed refetches on the minute.
    ref.listen(minuteClockProvider, (_, __) => _reload());
    final jobsAsync = ref.watch(deliveriesProvider);
    final jobs = jobsAsync.value ?? const <DeliveryJob>[];
    if (jobsAsync.isLoading && jobs.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (jobsAsync.hasError && jobs.isEmpty) {
      return LoadError(error: jobsAsync.error!, onRetry: _reload);
    }
    // Live work first, finished last.
    final open = jobs.where((j) {
      final s = j.status;
      return s != 'delivered' && s != 'settled' && s != 'cancelled';
    }).toList();
    final done = jobs.where((j) {
      final s = j.status;
      return s == 'delivered' || s == 'settled';
    }).toList();

    return RefreshIndicator(
      onRefresh: () async => _reload(),
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

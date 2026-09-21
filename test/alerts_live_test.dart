import 'package:flutter_test/flutter_test.dart';
import 'package:fufut_pos/models/models.dart';
import 'package:fufut_pos/services/alerts_live.dart';

OpsAlert alert({
  required String id,
  String severity = 'warning',
  String ruleId = 'order-new-unaccepted',
  String created = '2026-09-21T12:00:00.000Z',
  String status = 'open',
}) =>
    OpsAlert(
      id: id,
      severity: severity,
      ruleId: ruleId,
      created: created,
      status: status,
      message: 'Table 4 waiting 6 min',
    );

void main() {
  group('AlertsLive sound sync (web syncSound parity)', () {
    test('first snapshot is not a ping baseline but criticals DO chime',
        () {
      final live = AlertsLive();
      final sync = live.apply([
        alert(id: 'a1'),
        alert(id: 'a2', ruleId: 'order-ready-now'),
      ]);
      // A warning alone is silent.
      expect(sync.freshCriticals, 0);
      // An existing ping was raised before this tablet opened — no chime.
      expect(sync.freshPing, false);
      expect(live.armed, true);
    });

    test('criticals chime from the very first snapshot, once each', () {
      final live = AlertsLive();
      final sync = live.apply([
        alert(id: 'c1', severity: 'critical'),
        alert(id: 'c2', severity: 'critical'),
      ]);
      expect(sync.freshCriticals, 2);
      expect(sync.hasSound, true);
      // Re-push of the same list (reconnect, poll) is silent.
      final again = live.apply([
        alert(id: 'c1', severity: 'critical'),
        alert(id: 'c2', severity: 'critical'),
      ]);
      expect(again.freshCriticals, 0);
      expect(again.hasSound, false);
    });

    test('a ping arriving after the baseline chimes exactly once', () {
      final live = AlertsLive();
      live.apply([alert(id: 'a1')]); // baseline — arms the engine
      final sync = live.apply([
        alert(id: 'p1', ruleId: 'order-ready-now'),
      ]);
      expect(sync.freshPing, true);
      // Same ping still open on the next poll — no re-chime.
      final again = live.apply([
        alert(id: 'p1', ruleId: 'order-ready-now'),
      ]);
      expect(again.freshPing, false);
    });

    test('a NEW ping chimes again (each ready order gets one chime)', () {
      final live = AlertsLive();
      live.apply([alert(id: 'p1', ruleId: 'order-ready-now')]);
      expect(live.apply([alert(id: 'p1', ruleId: 'order-ready-now')]).freshPing,
          false);
      expect(live.apply([alert(id: 'p2', ruleId: 'order-ready-now')]).freshPing,
          true);
    });

    test('mixed snapshot: new critical + fresh ping together', () {
      final live = AlertsLive();
      live.apply([alert(id: 'seed')]);
      final sync = live.apply([
        alert(id: 'c9', severity: 'critical'),
        alert(id: 'p9', ruleId: 'order-ready-now'),
      ]);
      expect(sync.freshCriticals, 1);
      expect(sync.freshPing, true);
    });

    test('reset re-baselines everything', () {
      final live = AlertsLive();
      live.apply([alert(id: 'c1', severity: 'critical')]);
      live.reset();
      final sync = live.apply([alert(id: 'c1', severity: 'critical')]);
      expect(sync.freshCriticals, 1);
      expect(live.armed, true);
    });
  });

  group('OpsAlert parsing + ranking', () {
    test('parses the SSE payload row shape', () {
      final a = OpsAlert.fromJson({
        'id': 'vd31dbc04',
        'rule_id': 'order-new-unaccepted',
        'severity': 'warning',
        'entity_type': 'order',
        'entity_id': 'ORD-1',
        'entity_label': 'Table 4',
        'message': 'Table 4 waiting 6 min — nobody has accepted it',
        'status': 'open',
        'created': '2026-09-21T12:19:31.910Z',
      });
      expect(a.id, 'vd31dbc04');
      expect(a.ruleId, 'order-new-unaccepted');
      expect(a.entityLabel, 'Table 4');
      expect(a.isOpen, true);
    });

    test('rank: critical first, then oldest first', () {
      final rows = [
        alert(id: 'w1', created: '2026-09-21T10:00:00Z'),
        alert(id: 'c1', severity: 'critical', created: '2026-09-21T13:00:00Z'),
        alert(id: 'c2', severity: 'critical', created: '2026-09-21T11:00:00Z'),
      ];
      final sorted = [...rows]..sort(OpsAlert.rank);
      expect(sorted.map((a) => a.id).toList(), ['c2', 'c1', 'w1']);
    });
  });

  group('CafeTable capacity fallback', () {
    test('parses the server shape (capacity, not seats)', () {
      final t = CafeTable.fromJson({
        'id': 'T8',
        'number': 8,
        'capacity': 2,
        'section': 'Window',
        'status': 'occupied',
        'bill_requested_at': '2026-09-21T12:12:40.652Z',
      });
      expect(t.seats, 2);
      expect(t.billRequested, true);
      expect(t.status, 'occupied');
    });

    test('still honors an explicit seats field', () {
      final t = CafeTable.fromJson({'id': 'T1', 'number': 1, 'seats': 4});
      expect(t.seats, 4);
      expect(t.billRequested, false);
    });
  });
}

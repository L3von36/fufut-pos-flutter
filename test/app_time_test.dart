/// The one clock, pinned — every stamp the app prints must read the venue's
/// wall, whatever wall the test machine has. Fixtures build stamps from the
/// local calendar (never from a hardcoded UTC hour) so the suite is
/// timezone-robust: it passes on a UTC CI box and on a device in Addis
/// (UTC+3) alike.
library;

import 'package:flutter_test/flutter_test.dart';
// Deliberate alongside app_time: pins the promise that models.dart keeps
// exporting `dayKey` (now the re-export) for every existing call site.
// ignore: unnecessary_import
import 'package:fufut_pos/models/models.dart';
import 'package:fufut_pos/state/app_time.dart';

void main() {
  group('parseStamp — the two server shapes', () {
    test('naive local wall-clock keeps its fields (it IS local)', () {
      final d = parseStamp('2026-08-06 01:55:46')!;
      expect(d.isUtc, isFalse);
      expect(d.year, 2026);
      expect(d.month, 8);
      expect(d.day, 6);
      expect(d.hour, 1);
      expect(d.minute, 55);
    });

    test('UTC ISO converts to local preserving the absolute instant', () {
      final d = parseStamp('2026-09-25T07:12:33.000Z')!;
      expect(d.isUtc, isFalse);
      expect(d.millisecondsSinceEpoch,
          DateTime.utc(2026, 9, 25, 7, 12, 33).millisecondsSinceEpoch);
    });

    test('absent and unparseable stamps read null', () {
      expect(parseStamp(null), isNull);
      expect(parseStamp(''), isNull);
      expect(parseStamp('   '), isNull);
      expect(parseStamp('not-a-date'), isNull);
    });
  });

  group('day keys — one local calendar', () {
    test('fmtDay pads the local date', () {
      expect(fmtDay(DateTime(2026, 9, 7, 5, 3)), '2026-09-07');
      expect(fmtDay(DateTime(2026, 1, 30, 23, 59)), '2026-01-30');
    });

    test('todayKey / yesterdayKey walk the local calendar', () {
      final now = DateTime(2026, 9, 25, 13, 5);
      expect(todayKey(now), '2026-09-25');
      expect(yesterdayKey(now), '2026-09-24');
      // Month and year rollovers.
      expect(yesterdayKey(DateTime(2026, 3, 1)), '2026-02-28');
      expect(yesterdayKey(DateTime(2026, 1, 1)), '2025-12-31');
    });

    test('stampDayKey reads a naive stamp straight onto the local day', () {
      expect(stampDayKey('2026-09-25 10:30:00'), '2026-09-25');
      expect(stampDayKey('2026-09-25T07:12:33.000Z'), isNotNull);
      expect(stampDayKey(''), isNull);
      expect(stampDayKey(null), isNull);
      expect(stampDayKey('not-a-date'), isNull);
    });

    test('models.dayKey (the re-export) matches the naive prefix', () {
      expect(dayKey('2026-09-25 10:30:00'), '2026-09-25');
      expect(dayKey(''), '');
      expect(dayKey(null), '');
    });

    test('a UTC stamp lands on the local day, not the UTC day', () {
      // Noon local — guaranteed to be the same local date, whatever the
      // machine's offset, while a raw prefix could disagree near midnight.
      final localNoon = DateTime(2026, 9, 25, 12, 0, 0);
      final utcStamp = DateTime.utc(2026, 9, 25, 12, 0, 0)
          .subtract(const Duration(hours: 3))
          .toIso8601String();
      expect(stampDayKey(utcStamp), fmtDay(localNoon));
    });
  });

  group('the one format per shape', () {
    test('fmtClock is 24-hour HH:mm', () {
      expect(fmtClock(DateTime(2026, 9, 25, 9, 5)), '09:05');
      expect(fmtClock(DateTime(2026, 9, 25, 23, 59)), '23:59');
    });

    test('fmtClockStamp: blank, bare clock text, full stamps', () {
      expect(fmtClockStamp(null), '');
      expect(fmtClockStamp(''), '');
      expect(fmtClockStamp(null, blank: '—'), '—');
      // Shift rows feed bare "HH:mm" text through the same pipe.
      expect(fmtClockStamp('08:00'), '08:00');
      final localNoon = DateTime.now();
      final stamp =
          '${localNoon.year}-${localNoon.month.toString().padLeft(2, '0')}-'
          '${localNoon.day.toString().padLeft(2, '0')} 12:34:56';
      expect(fmtClockStamp(stamp), '12:34');
    });

    test('fmtDayClock is dd/MM HH:mm', () {
      expect(fmtDayClock(DateTime(2026, 9, 25, 10, 7)), '25/09 10:07');
    });

    test('fmtWhenStamp: HH:mm today, dd/MM HH:mm otherwise', () {
      final n = DateTime.now();
      final todayStamp =
          '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')} 12:34:56';
      expect(fmtWhenStamp(todayStamp), '12:34');
      expect(fmtWhenStamp('2024-01-05 09:15:00'), '05/01 09:15');
      expect(fmtWhenStamp(null, blank: '—'), '—');
      expect(fmtWhenStamp('garbage'), 'garbage');
    });

    test('fmtLongDate reads like the topbar always has', () {
      expect(fmtLongDate(DateTime(2026, 9, 25)), 'Fri, Sep 25, 2026');
      expect(fmtLongDate(DateTime(2026, 1, 1)), 'Thu, Jan 1, 2026');
    });

    test('fmtDur is the KPI shape: Xm under an hour, XhYYm over', () {
      expect(fmtDur(const Duration(minutes: 42)), '42m');
      expect(fmtDur(const Duration(minutes: 7)), '7m');
      expect(fmtDur(const Duration(minutes: 60)), '1h00m');
      expect(fmtDur(const Duration(minutes: 67)), '1h07m');
      expect(fmtDur(const Duration(hours: 3, minutes: 5)), '3h05m');
    });

    test('timeAgo — the web POS coarse buckets', () {
      final now = DateTime(2026, 9, 25, 13, 0);
      expect(timeAgo('2026-09-25 12:59:40', now: now), 'just now');
      expect(timeAgo('2026-09-25 12:30:00', now: now), '30m ago');
      expect(timeAgo('2026-09-25 10:00:00', now: now), '3h ago');
      expect(timeAgo('2026-09-23 13:00:00', now: now), '2d ago');
      expect(timeAgo(null), '');
      expect(timeAgo(''), '');
      expect(timeAgo('garbage'), 'garbage');
    });
  });

  group('the same stamp reads the same everywhere', () {
    test('the log clock and the table card agree on a UTC stamp', () {
      // The bug this library killed: the Order Log printed the venue hour
      // while the table card printed the server's UTC hour. One parser, one
      // clock — both must equal fmtClock of the same local instant.
      final stamp = '2026-09-25T07:12:33.000Z';
      final local = parseStamp(stamp)!;
      expect(fmtClockStamp(stamp), fmtClock(local));
    });

    test('a journal epoch and a server stamp land on the same minute', () {
      final local = DateTime(2026, 9, 25, 10, 30, 0);
      final epochMs = local.millisecondsSinceEpoch;
      final fromEpoch =
          DateTime.fromMillisecondsSinceEpoch(epochMs);
      expect(fmtClock(fromEpoch), '10:30');
      expect(fmtDay(fromEpoch), '2026-09-25');
    });
  });
}

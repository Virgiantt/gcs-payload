import 'dart:io';
import 'dart:math' as math;

import '../models/telemetry.dart';

enum AlertLevel { normal, warning, critical }

/// Asal alert, untuk pengelompokan di kotak peringatan & log.
enum AlertSource { telemetry, command, power, thermal, gps }

extension AlertSourceLabel on AlertSource {
  String get label => switch (this) {
        AlertSource.telemetry => 'TELEMETRY',
        AlertSource.command => 'COMMAND',
        AlertSource.power => 'POWER',
        AlertSource.thermal => 'THERMAL',
        AlertSource.gps => 'GPS',
      };
}

class Alert {
  final String id; // kunci unik per jenis alert
  final AlertLevel level;
  final String title;
  final String detail;
  final AlertSource source;
  final String? value; // nilai aktual, mis. "6.10 V"
  final String? limit; // batas yang dilanggar, mis. "< 6.80 V"
  final String? hint; // saran tindakan untuk operator
  final DateTime? since; // sejak kapan aktif (diisi AlertService)

  const Alert(
    this.id,
    this.level,
    this.title,
    this.detail, {
    this.source = AlertSource.telemetry,
    this.value,
    this.limit,
    this.hint,
    this.since,
  });

  Alert withSince(DateTime t) => Alert(id, level, title, detail,
      source: source, value: value, limit: limit, hint: hint, since: t);
}

/// Catatan transisi: alert muncul / naik level / kembali normal.
class AlertEvent {
  final DateTime time;
  final AlertLevel level; // level saat kejadian (normal = cleared)
  final String title;
  final String detail;
  final bool cleared;
  const AlertEvent(this.time, this.level, this.title, this.detail,
      {this.cleared = false});
}

/// Satu "kejadian" utuh: dari alert muncul sampai pulih.
/// Inilah yang ditampilkan di Alert log (status ACTIVE / RESOLVED, durasi, dst).
class AlertIncident {
  final String id;
  final AlertSource source;
  final DateTime startedAt;
  final int occurrence; // kejadian ke-berapa untuk jenis alert ini

  String title;
  String detail;
  String? value;
  String? limit;
  String? hint;
  AlertLevel level; // level saat ini
  AlertLevel peak; // level tertinggi selama kejadian
  DateTime? endedAt; // null = masih aktif

  AlertIncident({
    required this.id,
    required this.source,
    required this.startedAt,
    required this.occurrence,
    required this.title,
    required this.detail,
    required this.level,
    required this.peak,
    this.value,
    this.limit,
    this.hint,
  });

  bool get active => endedAt == null;
  Duration duration(DateTime now) => (endedAt ?? now).difference(startedAt);
}

/// Ambang batas alert. SESUAIKAN dengan hardware CanSat kamu.
class AlertThresholds {
  const AlertThresholds._();

  // --- Baterai: jumlah sel dideteksi otomatis dari tegangan ---
  // (<= 4.25 V = 1S, <= 8.5 V = 2S, dst). Ambang dihitung PER SEL.
  static const double cellWarn = 3.60;
  static const double cellCrit = 3.40;
  static const double cellMax = 4.25;

  /// Ambang lama (1S). Dipertahankan karena mungkin dipakai widget lain.
  static const double battWarn = 3.70;
  static const double battCrit = 3.50;

  static int cellsFor(double volt) => math.max(1, (volt / cellMax).ceil());

  // Suhu (°C)
  static const double tempWarn = 50;
  static const double tempCrit = 65;

  // Selisih altitude GPS vs barometer (m)
  static const double gpsAltDiffWarn = 50;

  // Keterlambatan paket (detik sejak paket terakhir)
  static const double delayWarnSec = 3;
  static const double delayCritSec = 10;

  // Packet loss: dihitung dari N paket terakhir di history
  static const int lossWindow = 10;

  // Jangan alarm "link down" saat aplikasi baru start
  static const Duration startupGrace = Duration(seconds: 5);
}

/// Menghitung daftar alert aktif dari data telemetri + status koneksi.
/// Panggil [update] tiap ada paket baru DAN tiap ~1 detik (supaya
/// "telemetry delay" tetap naik walaupun tidak ada paket masuk).
class AlertService {
  final DateTime _started = DateTime.now();
  final Map<String, Alert> _prev = {};
  final Map<String, AlertIncident> _open = {};
  final Map<String, int> _counts = {};

  /// Alert aktif, urut dari level tertinggi (lalu yang paling lama aktif).
  List<Alert> active = const [];

  /// Riwayat transisi (terlama -> terbaru), maksimal 200.
  final List<AlertEvent> events = [];

  /// Riwayat kejadian utuh (terlama -> terbaru), maksimal 200.
  final List<AlertIncident> incidents = [];

  String? lastExportPath;
  String? exportError;

  AlertLevel get level =>
      active.isEmpty ? AlertLevel.normal : active.first.level;

  void update({
    required Telemetry? latest,
    required List<Telemetry> history,
    required DateTime? lastPacketAt,
    required bool telemetryLinkUp,
    required bool commandLinkUp,
    required DateTime now,
    String? telemetryTarget, // mis. "192.168.43.201:9999"
    String? telemetryStatus, // mis. service.statusMessage
  }) {
    final out = <Alert>[];
    final inGrace = now.difference(_started) < AlertThresholds.startupGrace;

    // ---- koneksi ----
    if (!inGrace && !telemetryLinkUp) {
      final target = telemetryTarget ?? 'sumber telemetri';
      final why = (telemetryStatus != null && telemetryStatus.isNotEmpty)
          ? ' Status: $telemetryStatus'
          : '';
      out.add(Alert(
        'link',
        AlertLevel.critical,
        'TELEMETRY LINK DOWN',
        'Tidak tersambung ke $target.$why',
        source: AlertSource.telemetry,
        value: 'OFFLINE',
        hint: 'Pastikan laptop satu WiFi dengan receiver, IP/port benar, '
            'dan token AUTH cocok. Lihat panel LoRa LOG di tab Maps.',
      ));
    }
    if (!inGrace && !commandLinkUp) {
      out.add(const Alert(
        'cmd_link',
        AlertLevel.warning,
        'COMMAND LINK DOWN',
        'Perintah (separate / release / launch) tidak dapat dikirim.',
        source: AlertSource.command,
        value: 'OFFLINE',
        hint: 'Cek koneksi ke port command dan pastikan receiver mendukungnya.',
      ));
    }

    // ---- terhubung tapi belum ada paket sama sekali ----
    if (!inGrace && telemetryLinkUp && lastPacketAt == null) {
      out.add(const Alert(
        'no_data',
        AlertLevel.warning,
        'NO TELEMETRY DATA',
        'Terhubung ke receiver, tetapi belum ada paket yang diterima.',
        source: AlertSource.telemetry,
        hint: 'Cek transmitter menyala, antena terpasang, serta frekuensi '
            'dan sync word LoRa sama di kedua sisi.',
      ));
    }

    // ---- telemetry delay ----
    if (lastPacketAt != null) {
      final age = now.difference(lastPacketAt).inMilliseconds / 1000.0;
      final crit = age >= AlertThresholds.delayCritSec;
      if (crit || age >= AlertThresholds.delayWarnSec) {
        final lim =
            crit ? AlertThresholds.delayCritSec : AlertThresholds.delayWarnSec;
        out.add(Alert(
          'delay',
          crit ? AlertLevel.critical : AlertLevel.warning,
          'TELEMETRY DELAY',
          'Paket terakhir diterima ${age.toStringAsFixed(1)} detik lalu.',
          source: AlertSource.telemetry,
          value: '${age.toStringAsFixed(1)} s',
          limit: '≥ ${lim.toStringAsFixed(0)} s',
          hint: 'Cek jarak, antena, dan daya transmitter LoRa.',
        ));
      }
    }

    // ---- berdasarkan isi paket terakhir ----
    final t = latest;
    if (t != null) {
      // Baterai (jumlah sel otomatis)
      final cells = AlertThresholds.cellsFor(t.voltage);
      final perCell = t.voltage / cells;
      final critV = AlertThresholds.cellCrit * cells;
      final warnV = AlertThresholds.cellWarn * cells;
      final vDetail = 'Tegangan ${t.voltage.toStringAsFixed(2)} V '
          '(${cells}S, ${perCell.toStringAsFixed(2)} V per sel).';
      if (t.voltage < critV) {
        out.add(Alert(
          'battery',
          AlertLevel.critical,
          'BATTERY CRITICAL',
          vDetail,
          source: AlertSource.power,
          value: '${t.voltage.toStringAsFixed(2)} V',
          limit: '< ${critV.toStringAsFixed(2)} V',
          hint: 'Baterai hampir habis. Pertimbangkan mengakhiri misi / '
              'ganti baterai.',
        ));
      } else if (t.voltage < warnV) {
        out.add(Alert(
          'battery',
          AlertLevel.warning,
          'BATTERY LOW',
          vDetail,
          source: AlertSource.power,
          value: '${t.voltage.toStringAsFixed(2)} V',
          limit: '< ${warnV.toStringAsFixed(2)} V',
          hint: 'Baterai mulai menipis, pantau terus tegangannya.',
        ));
      }

      // Suhu
      final tDetail = 'Suhu payload ${t.temperature.toStringAsFixed(1)} °C.';
      if (t.temperature > AlertThresholds.tempCrit) {
        out.add(Alert(
          'temp',
          AlertLevel.critical,
          'OVER TEMPERATURE',
          tDetail,
          source: AlertSource.thermal,
          value: '${t.temperature.toStringAsFixed(1)} °C',
          limit: '> ${AlertThresholds.tempCrit.toStringAsFixed(0)} °C',
          hint: 'Suhu berbahaya bagi komponen. Cek sumber panas / ventilasi.',
        ));
      } else if (t.temperature > AlertThresholds.tempWarn) {
        out.add(Alert(
          'temp',
          AlertLevel.warning,
          'HIGH TEMPERATURE',
          tDetail,
          source: AlertSource.thermal,
          value: '${t.temperature.toStringAsFixed(1)} °C',
          limit: '> ${AlertThresholds.tempWarn.toStringAsFixed(0)} °C',
          hint: 'Suhu mulai tinggi, pantau tren kenaikannya.',
        ));
      }

      // GPS
      final noFix = t.gpsLat == 0 && t.gpsLon == 0;
      if (noFix) {
        out.add(const Alert(
          'gps_nofix',
          AlertLevel.warning,
          'GPS NO FIX',
          'Koordinat dilaporkan 0, 0 — GPS belum mengunci satelit.',
          source: AlertSource.gps,
          value: '0, 0',
          hint: 'Pastikan antena GPS menghadap langit terbuka dan tunggu lock.',
        ));
      } else {
        final diff = (t.gpsAlt - t.altitude).abs();
        if (diff > AlertThresholds.gpsAltDiffWarn) {
          out.add(Alert(
            'gps_alt',
            AlertLevel.warning,
            'GPS SIGNAL WEAK',
            'Altitude GPS ${t.gpsAlt.toStringAsFixed(0)} m berbeda dari '
                'barometer ${t.altitude.toStringAsFixed(0)} m.',
            source: AlertSource.gps,
            value: 'Δ ${diff.toStringAsFixed(0)} m',
            limit: '> ${AlertThresholds.gpsAltDiffWarn.toStringAsFixed(0)} m',
            hint: 'Sinyal GPS kemungkinan lemah. Bandingkan dengan barometer.',
          ));
        }
      }
    }

    // ---- packet loss (celah nomor paket pada N paket terakhir) ----
    final missed = missedPackets(history);
    if (missed > 0) {
      final n = math.min(history.length, AlertThresholds.lossWindow);
      final pct = missed / (n + missed) * 100;
      out.add(Alert(
        'pkt_loss',
        AlertLevel.warning,
        'PACKET LOSS',
        'Hilang $missed paket dari ${n + missed} paket terakhir '
            '(${pct.toStringAsFixed(0)}%).',
        source: AlertSource.telemetry,
        value: '${pct.toStringAsFixed(0)} %',
        limit: '> 0 %',
        hint: 'Sinyal LoRa lemah atau terganggu. Cek antena, jarak, dan RSSI.',
      ));
    }

    _recordEvents(out, now);

    final withSince = [
      for (final a in out) a.withSince(_open[a.id]?.startedAt ?? now),
    ]..sort((a, b) {
        final c = b.level.index.compareTo(a.level.index);
        if (c != 0) return c;
        return (a.since ?? now).compareTo(b.since ?? now);
      });
    active = withSince;
  }

  /// Jumlah paket yang hilang (celah nomor paket) pada N paket terakhir.
  static int missedPackets(List<Telemetry> history) {
    if (history.length < 2) return 0;
    final w = history.length > AlertThresholds.lossWindow
        ? history.sublist(history.length - AlertThresholds.lossWindow)
        : history;
    var missed = 0;
    for (var i = 1; i < w.length; i++) {
      final d = (w[i].packetCount - w[i - 1].packetCount).toInt();
      if (d > 1) missed += d - 1; // d <= 0 = counter reset, abaikan
    }
    return missed;
  }

  void _recordEvents(List<Alert> now, DateTime time) {
    final current = {for (final a in now) a.id: a};

    // ---- transisi (events) ----
    for (final a in now) {
      final before = _prev[a.id];
      if (before == null || before.level != a.level) {
        events.add(AlertEvent(time, a.level, a.title, a.detail));
      }
    }
    for (final old in _prev.values) {
      if (!current.containsKey(old.id)) {
        events.add(AlertEvent(
            time, AlertLevel.normal, old.title, 'Back to normal',
            cleared: true));
      }
    }
    if (events.length > 200) events.removeRange(0, events.length - 200);

    // ---- kejadian utuh (incidents) ----
    for (final a in now) {
      final inc = _open[a.id];
      if (inc == null) {
        final n = (_counts[a.id] ?? 0) + 1;
        _counts[a.id] = n;
        final created = AlertIncident(
          id: a.id,
          source: a.source,
          startedAt: time,
          occurrence: n,
          title: a.title,
          detail: a.detail,
          level: a.level,
          peak: a.level,
          value: a.value,
          limit: a.limit,
          hint: a.hint,
        );
        _open[a.id] = created;
        incidents.add(created);
      } else {
        inc
          ..title = a.title
          ..detail = a.detail
          ..value = a.value
          ..limit = a.limit
          ..hint = a.hint
          ..level = a.level;
        if (a.level.index > inc.peak.index) inc.peak = a.level;
      }
    }
    for (final id in _open.keys.toList()) {
      if (!current.containsKey(id)) {
        _open.remove(id)!.endedAt = time;
      }
    }
    if (incidents.length > 200) {
      incidents.removeRange(0, incidents.length - 200);
    }

    _prev
      ..clear()
      ..addAll(current);
  }

  /// Simpan semua kejadian ke CSV (Documents/CanSat_GCS_Logs/alerts_*.csv).
  /// Mengembalikan path file, atau null kalau gagal (lihat [exportError]).
  String? exportCsv() {
    try {
      final sep = Platform.pathSeparator;
      final home = Platform.environment['USERPROFILE'] ??
          Platform.environment['HOME'] ??
          Directory.current.path;
      final docs = Directory('$home${sep}Documents');
      final base = docs.existsSync() ? docs.path : home;
      final dir = Directory('$base${sep}CanSat_GCS_Logs')
        ..createSync(recursive: true);

      final n = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final stamp = '${n.year}${two(n.month)}${two(n.day)}_'
          '${two(n.hour)}${two(n.minute)}${two(n.second)}';
      final file = File('${dir.path}${sep}alerts_$stamp.csv');

      String q(String? s) => '"${(s ?? '').replaceAll('"', '""')}"';
      final b =
          StringBuffer('START,END,DURATION_S,STATUS,LEVEL,PEAK,SOURCE,ID,TITLE,'
              'OCCURRENCE,VALUE,LIMIT,DETAIL,HINT\r\n');
      final now = DateTime.now();
      for (final i in incidents) {
        b.write([
          i.startedAt.toIso8601String(),
          i.endedAt?.toIso8601String() ?? '',
          i.duration(now).inSeconds,
          i.active ? 'ACTIVE' : 'RESOLVED',
          i.level.name.toUpperCase(),
          i.peak.name.toUpperCase(),
          i.source.label,
          i.id,
          q(i.title),
          i.occurrence,
          q(i.value),
          q(i.limit),
          q(i.detail),
          q(i.hint),
        ].join(','));
        b.write('\r\n');
      }
      file.writeAsStringSync(b.toString(), flush: true);
      lastExportPath = file.path;
      exportError = null;
      return file.path;
    } catch (e) {
      exportError = '$e';
      return null;
    }
  }
}

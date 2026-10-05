import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/telemetry.dart';

enum ConnectionStatus { disconnected, connecting, connected }

class TelemetryService extends ChangeNotifier {
  final String host;
  final int port;

  /// Token handshake untuk receiver LoRa (ESP32). Dikirim sebagai
  /// "AUTH <token>\n" tepat setelah TCP tersambung. null = tanpa AUTH
  /// (mis. simulator embedded).
  final String? authToken;

  TelemetryService({
    this.host = '127.0.0.1',
    this.port = 9999,
    this.authToken,
  });

  /// Dipanggil untuk setiap kejadian penting (koneksi, AUTH, paket masuk,
  /// paket invalid). Dipakai main.dart untuk panel "LoRa LOG".
  void Function(String msg)? onLog;

  void _log(String m) {
    debugPrint('[TEL] $m');
    onLog?.call(m);
  }

  Socket? _socket;
  StreamSubscription? _sub;
  Timer? _reconnectTimer;
  bool _manuallyStopped = false;

  ConnectionStatus _status = ConnectionStatus.disconnected;
  ConnectionStatus get status => _status;

  Telemetry? _latest;
  Telemetry? get latest => _latest;

  final List<Telemetry> _history = [];
  List<Telemetry> get history => List.unmodifiable(_history);
  static const int maxHistory = 300;

  // ---- field yang tidak ada di model Telemetry (format paket baru) ----
  /// Arus (A) dari paket terakhir. NaN kalau tidak ada / sensor error.
  double _latestCurrent = double.nan;
  double get latestCurrent => _latestCurrent;

  /// Riwayat arus, sejajar 1:1 dengan [history].
  final List<double> _currentHistory = [];
  List<double> get currentHistory => List.unmodifiable(_currentHistory);

  /// Nama field yang NaN (sensor error) pada paket terakhir.
  List<String> _invalidFields = const [];
  List<String> get invalidFields => _invalidFields;

  /// Jumlah paket ditolak karena checksum salah.
  int checksumErrors = 0;

  /// Total paket yang pernah diterima sejak aplikasi jalan (terus naik,
  /// tidak dibatasi maxHistory). Dipakai sebagai nomor sampel di sumbu X chart.
  int _totalReceived = 0;
  int get totalReceived => _totalReceived;

  String _statusMessage = 'Waiting for receiver...';
  String get statusMessage => _statusMessage;

  Future<void> connect() async {
    _manuallyStopped = false;
    await _disconnectSocket();
    _setStatus(ConnectionStatus.connecting, 'Menghubungkan ke $host:$port ...');
    _log('Connecting to $host:$port');

    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 5),
      );
      _socket = socket;
      socket.setOption(SocketOption.tcpNoDelay, true);
      _log(
          'TCP connected: ${socket.remoteAddress.address}:${socket.remotePort}');

      // allowMalformed: byte rusak dari LoRa tidak boleh memutus koneksi
      _sub = socket
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(
            _handleLine,
            onDone: () => _handleDisconnect(),
            onError: (e) => _handleDisconnect(e.toString()),
            cancelOnError: true,
          );

      // Handshake (listen dulu, baru AUTH, supaya balasan tidak terlewat)
      final token = authToken;
      if (token != null && token.isNotEmpty) {
        socket.write('AUTH $token\n');
        await socket.flush();
        _log('AUTH sent');
      }

      _setStatus(ConnectionStatus.connected, 'Connected to $host:$port');
    } catch (e) {
      _log('Connection failed: $e');
      _setStatus(ConnectionStatus.disconnected, 'Koneksi gagal: $e');
      _scheduleReconnect();
    }
  }

  /// Masukkan satu baris CSV dari sumber lain.
  void ingestLine(String line) => _handleLine(line);

  /// Set status koneksi dari sumber eksternal.
  void markExternal(ConnectionStatus s, String msg) => _setStatus(s, msg);

  // =========================================================
  // FORMAT PAKET
  // =========================================================
  // BARU (tx.py / rx.py), 14 field:
  //  0 MISSION_TIME  1 PACKET_ID  2 TEAM_ID  3 PRESSURE  4 ALTITUDE
  //  5 VOLTAGE  6 CURRENT  7 STATE(0-4)  8 LAT  9 LON
  //  10 ROLL  11 PITCH  12 YAW  13 CHECKSUM (XOR hex)
  //
  // LAMA (simulator embedded / model Telemetry), 14 field:
  //  TEAM_ID,MISSION_TIME,PACKET_COUNT,ALTITUDE,PRESSURE,TEMPERATURE,
  //  VOLTAGE,ROLL,PITCH,YAW,GPS_LAT,GPS_LON,GPS_ALT,STATE
  //
  // Paket baru diubah ke bentuk LAMA supaya Telemetry.fromCsv tidak perlu
  // diubah. TEMPERATURE & GPS_ALT tidak ada di paket baru -> NaN.
  static final RegExp _timeRe = RegExp(r'^\d{1,3}:\d{2}:\d{2}$');
  static const List<String> _stateNames = [
    'LAUNCH_PAD',
    'ASCENT',
    'APOGEE',
    'DESCENT',
    'LANDED',
  ];

  static bool _isNewFormat(List<String> p) =>
      p.length == 14 && _timeRe.hasMatch(p[0].trim());

  static String _checksum(String s) {
    var c = 0;
    for (final b in utf8.encode(s)) {
      c ^= b;
    }
    return c.toRadixString(16).toUpperCase().padLeft(2, '0');
  }

  static bool _checksumOk(String line) {
    final i = line.lastIndexOf(',');
    if (i < 0) return false;
    final body = line.substring(0, i);
    final sent = line.substring(i + 1).trim().toUpperCase();
    return _checksum(body) == sent;
  }

  /// "nan" / kosong / tidak terbaca -> "NaN" (bisa di-parse Dart).
  static String _num(String s) {
    final v = double.tryParse(s.trim());
    return (v == null || !v.isFinite) ? 'NaN' : s.trim();
  }

  static bool _isNan(String s) {
    final v = double.tryParse(s.trim());
    return v == null || !v.isFinite;
  }

  void _handleLine(String line) {
    final text = line.trim();
    if (text.isEmpty) return;
    debugPrint('[TCP LINE] $text');

    // Header CSV (format lama diawali TEAM_ID, format baru MISSION_TIME)
    final up = text.toUpperCase();
    if (up.startsWith('TEAM_ID') || up.startsWith('MISSION_TIME')) {
      _log('CSV header received');
      return;
    }

    // Pesan kontrol dari receiver (mis. "AUTH OK") — bukan paket telemetri
    if (!text.contains(',')) {
      _log('Receiver: $text');
      return;
    }

    var csv = text;
    var current = double.nan;
    var invalid = <String>[];

    final p = text.split(',').map((e) => e.trim()).toList();
    if (_isNewFormat(p)) {
      if (!_checksumOk(text)) {
        checksumErrors++;
        _log('Checksum salah (#$checksumErrors): '
            '${text.length > 70 ? '${text.substring(0, 70)}...' : text}');
        return;
      }

      final si = int.tryParse(p[7]);
      final state = (si != null && si >= 0 && si < _stateNames.length)
          ? _stateNames[si]
          : 'UNKNOWN';

      csv = [
        p[2], // TEAM_ID
        p[0], // MISSION_TIME
        int.tryParse(p[1])?.toString() ?? '0', // PACKET_COUNT ("0801" -> 801)
        _num(p[4]), // ALTITUDE
        _num(p[3]), // PRESSURE
        'NaN', // TEMPERATURE (tidak dikirim)
        _num(p[5]), // VOLTAGE
        _num(p[10]), // ROLL
        _num(p[11]), // PITCH
        _num(p[12]), // YAW
        _num(p[8]), // GPS_LAT
        _num(p[9]), // GPS_LON
        'NaN', // GPS_ALT (tidak dikirim)
        state,
      ].join(',');

      final cv = double.tryParse(p[6]);
      current = (cv != null && cv.isFinite) ? cv : double.nan;

      // Field yang seharusnya ada tapi NaN = sensor error
      // (lat/lon ditangani alert GPS NO FIX, jadi tidak dihitung di sini)
      if (_isNan(p[3])) invalid.add('Pressure');
      if (_isNan(p[4])) invalid.add('Altitude');
      if (_isNan(p[5])) invalid.add('Voltage');
      if (_isNan(p[6])) invalid.add('Current');
      if (_isNan(p[10])) invalid.add('Roll');
      if (_isNan(p[11])) invalid.add('Pitch');
      if (_isNan(p[12])) invalid.add('Yaw');
      if (state == 'UNKNOWN') invalid.add('State');
    }

    final t = Telemetry.fromCsv(csv);
    if (t == null) {
      final short = text.length > 90 ? '${text.substring(0, 90)}...' : text;
      _log('Invalid packet: $short');
      return;
    }

    _latest = t;
    _latestCurrent = current;
    _invalidFields = invalid;
    _history.add(t);
    _currentHistory.add(current);
    _totalReceived++;
    if (_history.length > maxHistory) {
      _history.removeAt(0);
      _currentHistory.removeAt(0);
    }

    final nanNote = invalid.isEmpty ? '' : ' | NaN: ${invalid.join(',')}';
    _log('RX #${t.packetCount} | ${t.state} | '
        'ALT ${t.altitude.isFinite ? t.altitude.toStringAsFixed(1) : 'NaN'} m'
        '$nanNote');
    notifyListeners();
  }

  void _handleDisconnect([String? reason]) {
    _log(reason != null
        ? 'Socket error: $reason'
        : 'Connection closed by receiver');
    _setStatus(
      ConnectionStatus.disconnected,
      reason != null ? 'Terputus: $reason' : 'Terputus dari receiver',
    );
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_manuallyStopped) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      if (!_manuallyStopped) connect();
    });
  }

  Future<void> _disconnectSocket() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await _socket?.close();
    } catch (_) {}
    _socket = null;
  }

  void _setStatus(ConnectionStatus s, String msg) {
    _status = s;
    _statusMessage = msg;
    notifyListeners();
  }

  Future<void> reconnect() async {
    _reconnectTimer?.cancel();
    await connect();
  }

  @override
  void dispose() {
    _manuallyStopped = true;
    _reconnectTimer?.cancel();
    _disconnectSocket();
    super.dispose();
  }
}

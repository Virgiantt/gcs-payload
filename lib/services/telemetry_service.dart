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

  void _handleLine(String line) {
    final text = line.trim();
    if (text.isEmpty) return;
    debugPrint('[TCP LINE] $text');

    // Header CSV
    if (text.toUpperCase().startsWith('TEAM_ID')) {
      _log('CSV header received');
      return;
    }

    // Pesan kontrol dari receiver (mis. "AUTH OK") — bukan paket telemetri
    if (!text.contains(',')) {
      _log('Receiver: $text');
      return;
    }

    final t = Telemetry.fromCsv(text);
    if (t == null) {
      final short = text.length > 90 ? '${text.substring(0, 90)}...' : text;
      _log('Invalid packet: $short');
      return;
    }

    _latest = t;
    _history.add(t);
    _totalReceived++;
    if (_history.length > maxHistory) {
      _history.removeAt(0);
    }
    _log('RX #${t.packetCount} | ${t.state} | '
        'ALT ${t.altitude.toStringAsFixed(1)} m');
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

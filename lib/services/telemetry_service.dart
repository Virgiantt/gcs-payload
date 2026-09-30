import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/telemetry.dart';

enum ConnectionStatus { disconnected, connecting, connected }

class TelemetryService extends ChangeNotifier {
  final String host;
  final int port;

  TelemetryService({this.host = '127.0.0.1', this.port = 9999});

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

  String _statusMessage = 'Waiting for simulator...';
  String get statusMessage => _statusMessage;

  Future<void> connect() async {
    _manuallyStopped = false;
    await _disconnectSocket();
    _setStatus(ConnectionStatus.connecting, 'Menghubungkan ke $host:$port ...');

    try {
      _socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 5),
      );
      _setStatus(ConnectionStatus.connected, 'Connected to $host:$port');

      _sub = _socket!
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            _handleLine,
            onDone: () => _handleDisconnect(),
            onError: (e) => _handleDisconnect(e.toString()),
            cancelOnError: true,
          );
    } catch (e) {
      _setStatus(ConnectionStatus.disconnected, 'Koneksi gagal: $e');
      _scheduleReconnect();
    }
  }

  void _handleLine(String line) {
    if (line.trim().isEmpty) return;
    // Skip CSV header
    if (line.toUpperCase().startsWith('TEAM_ID')) return;

    final t = Telemetry.fromCsv(line);
    if (t == null) return;

    _latest = t;
    _history.add(t);
    _totalReceived++;
    if (_history.length > maxHistory) {
      _history.removeAt(0);
    }
    notifyListeners();
  }

  void _handleDisconnect([String? reason]) {
    _setStatus(
      ConnectionStatus.disconnected,
      reason != null ? 'Terputus: $reason' : 'Terputus dari simulator',
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

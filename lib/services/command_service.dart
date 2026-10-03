import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

enum CmdChannelStatus { disconnected, connecting, connected }

enum CmdState { sent, ack, nack, timeout, failed, rejected }

class CmdLogEntry {
  final int id;
  final String name;
  final DateTime time;
  CmdState state;
  String detail;

  CmdLogEntry(this.id, this.name, this.time,
      {this.state = CmdState.sent, this.detail = ''});
}

class CommandService extends ChangeNotifier {
  final String host;
  final int port;
  final String teamId;

  CommandService({required this.host, this.port = 9998, this.teamId = '1064'});

  static const Set<String> criticalNames = {
    'SEPARATE_1',
    'SEPARATE_2',
    'PAYLOAD_RELEASE',
  };
  static const Duration armDuration = Duration(seconds: 15);
  static const Duration ackTimeout = Duration(seconds: 3);

  CmdChannelStatus status = CmdChannelStatus.disconnected;
  final List<CmdLogEntry> log = [];

  Socket? _socket;
  Timer? _retry;
  Timer? _armTimer;
  DateTime? _armedUntil;
  int _seq = 0;
  bool _disposed = false;
  final Map<int, Timer> _pending = {};

  bool get connected => status == CmdChannelStatus.connected;
  bool get armed =>
      _armedUntil != null && DateTime.now().isBefore(_armedUntil!);
  int get armedSecondsLeft => armed
      ? (_armedUntil!.difference(DateTime.now()).inMilliseconds / 1000).ceil()
      : 0;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // ---------------- koneksi ----------------
  void start() {
    connect();
    _retry ??= Timer.periodic(const Duration(seconds: 3), (_) {
      if (status == CmdChannelStatus.disconnected) connect();
    });
  }

  Future<void> connect() async {
    if (_disposed || status != CmdChannelStatus.disconnected) return;
    status = CmdChannelStatus.connecting;
    _notify();
    try {
      final s =
          await Socket.connect(host, port, timeout: const Duration(seconds: 2));
      s.setOption(SocketOption.tcpNoDelay, true);
      _socket = s;
      status = CmdChannelStatus.connected;
      _notify();
      s
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            _onLine,
            onDone: _onClosed,
            onError: (_) => _onClosed(),
            cancelOnError: true,
          );
    } catch (_) {
      status = CmdChannelStatus.disconnected;
      _notify();
    }
  }

  void _onClosed() {
    _socket?.destroy();
    _socket = null;
    status = CmdChannelStatus.disconnected;
    disarm();
    _notify();
  }

  void _onLine(String line) {
    final p = line.trim().split(',');
    if (p.length < 3) return;
    final kind = p[0];
    if (kind != 'ACK' && kind != 'NACK') return;
    final id = int.tryParse(p[1]);
    if (id == null) return;
    final idx = log.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    final e = log[idx];
    _pending.remove(id)?.cancel();
    if (kind == 'ACK') {
      e.state = CmdState.ack;
      e.detail = 'Diterima';
    } else {
      e.state = CmdState.nack;
      e.detail = p.length > 3 ? p.sublist(3).join(',') : 'Ditolak';
    }
    _notify();
  }

  // ---------------- arm / disarm ----------------
  void arm() {
    if (!connected) return;
    _armedUntil = DateTime.now().add(armDuration);
    _armTimer?.cancel();
    _armTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!armed) {
        t.cancel();
        _armedUntil = null;
      }
      _notify();
    });
    _notify();
  }

  void disarm() {
    _armedUntil = null;
    _armTimer?.cancel();
    _armTimer = null;
    _notify();
  }

  // ---------------- kirim perintah ----------------
  void send(String rawName) {
    final name =
        rawName.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9_]'), '_');
    if (name.isEmpty) return;

    final entry = CmdLogEntry(++_seq, name, DateTime.now());
    log.insert(0, entry);
    if (log.length > 100) log.removeLast();

    final critical = criticalNames.contains(name);
    if (critical && !armed) {
      entry.state = CmdState.rejected;
      entry.detail = 'Sistem belum ARMED';
      _notify();
      return;
    }
    if (!connected || _socket == null) {
      entry.state = CmdState.failed;
      entry.detail = 'Command link tidak terhubung';
      _notify();
      return;
    }

    try {
      _socket!.write('CMD,$teamId,${entry.id},$name\r\n');
    } catch (e) {
      entry.state = CmdState.failed;
      entry.detail = '$e';
      _notify();
      return;
    }

    if (critical) disarm(); // satu kali ARM = satu perintah kritis

    _pending[entry.id] = Timer(ackTimeout, () {
      if (entry.state == CmdState.sent) {
        entry.state = CmdState.timeout;
        entry.detail = 'Tidak ada ACK';
      }
      _pending.remove(entry.id);
      _notify();
    });
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _armTimer?.cancel();
    for (final t in _pending.values) {
      t.cancel();
    }
    _socket?.destroy();
    super.dispose();
  }
}

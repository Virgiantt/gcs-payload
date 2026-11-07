import 'dart:async';
import 'dart:typed_data';

import 'package:dart_periphery/dart_periphery.dart';
import 'package:flutter/foundation.dart';

import '../models/telemetry.dart';
import 'lora_protocol.dart';

/// disconnected = merah  : serial/GPIO tidak ada atau modul tidak menjawab
/// connecting   = kuning : modul sehat, menunggu transmitter (START)
/// connected    = hijau  : handshake selesai dan ACK dikirim
enum ConnectionStatus { disconnected, connecting, connected }

/// Menerima frame biner dari transmitter ESP32 lewat modul E220 (UART),
/// menjawab START_ACK dan GPS_ACK, lalu mengubah paket GPS menjadi [Telemetry].
///
/// Perilaku transmitter yang dipakai sebagai acuan:
/// - START dikirim tiap 2 detik sampai ada START_ACK.
/// - Paket GPS dikirim tiap 2 detik, wajib dijawab GPS_ACK dengan seq sama
///   dalam 1,5 detik. Tiga ACK hilang berturut-turut membuat link putus.
/// - Nomor seq dipakai bersama oleh START dan GPS, bertambah 1 tiap frame.
/// - Tanpa fix, transmitter tetap mengirim paket dengan lat/lon 0 dan
///   flag fix = 0.
class TelemetryService extends ChangeNotifier {
  TelemetryService({
    this.portPath = '/dev/serial0',
    this.baud = 9600,
    this.m0Line = 22,
    this.m1Line = 27,
    this.auxLine = 17,
    this.gpioChip = 0,
    this.teamId = '1064',
  });

  final String portPath;
  final int baud;
  final int m0Line;
  final int m1Line;
  final int auxLine;
  final int gpioChip;
  final String teamId;

  /// Transmitter dianggap diam kalau tidak ada frame selama ini
  /// (interval kirim transmitter 2 detik).
  static const Duration linkTimeout = Duration(seconds: 10);
  static const int maxHistory = 300;

  void Function(String msg)? onLog;

  void _log(String m) {
    debugPrint('[TEL] $m');
    onLog?.call(m);
  }

  Serial? _serial;
  GPIO? _m0;
  GPIO? _m1;
  GPIO? _aux;
  Timer? _pollTimer;
  Timer? _watchdog;
  Timer? _retryTimer;
  bool _stopped = false;

  final FrameParser _parser = FrameParser();
  bool _linked = false;
  DateTime? _lastFrameAt;
  DateTime? _firstGpsAt;

  // Nomor urut: seq transmitter hanya 8 bit, jadi di-unwrap menjadi
  // hitungan yang terus naik. Frame START ikut memakai seq, tetapi tidak
  // dihitung sebagai paket data.
  bool _haveSeq = false;
  int _lastSeq = 0;
  int _unwrapped = 0;
  int _rxCount = 0;

  ConnectionStatus _status = ConnectionStatus.disconnected;
  ConnectionStatus get status => _status;

  String _statusMessage = 'Menunggu modul LoRa...';
  String get statusMessage => _statusMessage;

  Telemetry? _latest;
  Telemetry? get latest => _latest;

  final List<Telemetry> _history = [];
  List<Telemetry> get history => List.unmodifiable(_history);

  int _totalReceived = 0;
  int get totalReceived => _totalReceived;

  // Transmitter GPS-only tidak mengirim arus.
  double _latestCurrent = double.nan;
  double get latestCurrent => _latestCurrent;
  final List<double> _currentHistory = [];
  List<double> get currentHistory => List.unmodifiable(_currentHistory);
  List<String> get invalidFields => const [];

  double latestSpeedKmh = double.nan;
  int latestSats = 0;

  int get checksumErrors => _parser.crcErrors;

  // =========================================================
  // KONEKSI
  // =========================================================
  Future<void> connect() async {
    _stopped = false;
    _retryTimer?.cancel();
    _closeHardware();
    _setStatus(ConnectionStatus.connecting, 'Membuka $portPath ...');

    try {
      _m0 = GPIO(m0Line, GPIOdirection.gpioDirOut, gpioChip);
      _m1 = GPIO(m1Line, GPIOdirection.gpioDirOut, gpioChip);
      _aux = GPIO(auxLine, GPIOdirection.gpioDirIn, gpioChip);
      _serial = Serial(portPath, Baudrate.b9600);
    } catch (e) {
      _fail('Serial/GPIO tidak tersedia: $e');
      return;
    }

    try {
      if (!await _readConfig()) return;
      await _setMode(0);
    } catch (e) {
      _fail('Gagal menyiapkan modul: $e');
      return;
    }

    _parser.reset();
    _linked = false;
    _lastFrameAt = null;
    _pollTimer =
        Timer.periodic(const Duration(milliseconds: 20), (_) => _poll());
    _watchdog = Timer.periodic(const Duration(seconds: 1), (_) => _checkLink());
    _setStatus(ConnectionStatus.connecting,
        'Modul siap. Menunggu START dari transmitter ...');
    _log('Modul siap, mode normal. Menunggu START.');
  }

  Future<void> reconnect() async {
    _retryTimer?.cancel();
    await connect();
  }

  void _fail(String msg) {
    _log(msg);
    _closeHardware();
    _setStatus(ConnectionStatus.disconnected, msg);
    if (_stopped) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 3), () {
      if (!_stopped) connect();
    });
  }

  void _closeHardware() {
    _pollTimer?.cancel();
    _watchdog?.cancel();
    _pollTimer = null;
    _watchdog = null;
    _linked = false;
    try {
      _m0?.write(false);
      _m1?.write(false);
    } catch (_) {}
    for (final d in [_serial, _m0, _m1, _aux]) {
      try {
        (d as dynamic)?.dispose();
      } catch (_) {}
    }
    _serial = null;
    _m0 = null;
    _m1 = null;
    _aux = null;
  }

  // =========================================================
  // MODUL E220
  // =========================================================
  Future<bool> _waitAuxHigh(Duration timeout) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      if (_aux?.read() ?? true) return true;
      await Future.delayed(const Duration(milliseconds: 5));
    }
    return _aux?.read() ?? true;
  }

  Future<void> _setMode(int mode) async {
    _m0?.write((mode & 1) != 0);
    _m1?.write((mode & 2) != 0);
    await Future.delayed(const Duration(milliseconds: 20));
    await _waitAuxHigh(const Duration(seconds: 2));
    await Future.delayed(const Duration(milliseconds: 50));
  }

  List<int> _readBytes() {
    final ev = _serial!.read(256, 0); // timeout 0 = tidak memblokir
    return ev.data;
  }

  Future<bool> _readConfig() async {
    final s = _serial!;
    await _setMode(3);
    _readBytes();
    s.write(Uint8List.fromList([0xC1, 0x00, 0x08]));

    final buf = <int>[];
    final end = DateTime.now().add(const Duration(milliseconds: 600));
    while (DateTime.now().isBefore(end) && buf.length < 11) {
      await Future.delayed(const Duration(milliseconds: 20));
      buf.addAll(_readBytes());
    }

    if (buf.isEmpty) {
      _fail('Modul E220 tidak menjawab. Cek kabel TX/RX, M0/M1, dan daya.');
      return false;
    }
    if (buf.length >= 11 &&
        buf[0] == 0xC1 &&
        buf[1] == 0x00 &&
        buf[2] == 0x08) {
      _logConfig(buf.sublist(3, 11));
      return true;
    }
    final hex = buf.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    _fail('Jawaban config tidak dikenal: $hex');
    return false;
  }

  void _logConfig(List<int> p) {
    const bauds = [1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200];
    const air = [
      '2.4k', '2.4k', '2.4k', '4.8k', '9.6k', '19.2k', '38.4k', '62.5k'
    ];
    final addr = '${p[0].toRadixString(16).padLeft(2, '0')}'
            '${p[1].toRadixString(16).padLeft(2, '0')}'
        .toUpperCase();
    final b = bauds[(p[2] >> 5) & 7];
    final fixed = (p[5] & 0x40) != 0;
    _log('Config: alamat $addr, channel ${p[4]}, UART $b, '
        'air ${air[p[2] & 7]} bps, ${fixed ? 'FIXED' : 'transparent'}');
    if (b != 9600) _log('PERINGATAN: baud modul $b, aplikasi memakai 9600.');
    if (fixed) {
      _log('PERINGATAN: mode FIXED. Transmitter mengirim transparent, '
          'ubah modul ke transparent.');
    }
    if ((p[5] & 0x80) != 0) {
      _log('PERINGATAN: byte RSSI aktif. Matikan di modul Pi supaya tidak '
          'ada byte tambahan di tiap paket.');
    }
  }

  // =========================================================
  // PENERIMAAN
  // =========================================================
  void _poll() {
    if (_serial == null) return;
    try {
      for (final b in _readBytes()) {
        if (_parser.feed(b)) _onFrame();
      }
    } catch (e) {
      _fail('Serial error: $e');
    }
  }

  void _checkLink() {
    final at = _lastFrameAt;
    if (_linked && at != null && DateTime.now().difference(at) > linkTimeout) {
      _linked = false;
      _setStatus(ConnectionStatus.connecting,
          'Transmitter diam lebih dari ${linkTimeout.inSeconds} detik. '
          'Menunggu START ...');
      _log('Link putus: tidak ada frame ${linkTimeout.inSeconds} detik');
    }
  }

  Future<void> _send(Uint8List frame) async {
    await _waitAuxHigh(const Duration(milliseconds: 300));
    try {
      _serial?.write(frame);
    } catch (e) {
      _log('Gagal kirim ACK: $e');
    }
  }

  void _markLinked() {
    _lastFrameAt = DateTime.now();
    if (!_linked) {
      _linked = true;
      _setStatus(
          ConnectionStatus.connected, 'Link aktif, ACK dikirim ke transmitter');
    }
  }

  void _onFrame() {
    final seq = _parser.seq;
    final payload = Uint8List.fromList(_parser.payload.sublist(0, _parser.len));

    switch (_parser.type) {
      case LoraProtocol.pktStart:
        if (!listEquals(payload, LoraProtocol.startWord)) {
          _log('START dengan isi tidak cocok, diabaikan');
          return;
        }
        // START memakai nomor seq yang sama dengan paket data. Jadikan
        // baseline tanpa menambah hitungan paket, supaya handshake ulang
        // (atau transmitter yang reboot) tidak terbaca sebagai packet loss.
        _lastSeq = seq;
        _haveSeq = true;
        unawaited(_send(LoraProtocol.startAck(seq)));
        _log('START diterima (seq $seq), START_ACK dikirim');
        _markLinked();
        break;

      case LoraProtocol.pktGps:
        final g = GpsPayload.parse(payload);
        if (g == null) {
          _log('GPS payload ${payload.length} byte, harusnya 16');
          return;
        }
        final duplicate = _haveSeq && seq == _lastSeq;
        if (!duplicate) {
          if (!_haveSeq) {
            _unwrapped = seq;
            _haveSeq = true;
          } else {
            _unwrapped += (seq - _lastSeq) & 0xFF;
          }
          _lastSeq = seq;
          _rxCount = (_rxCount + 1) & 0xFFFF;
        }
        unawaited(_send(LoraProtocol.gpsAck(seq, _rxCount)));
        _markLinked();
        if (!duplicate) _ingestGps(g);
        break;

      default:
        _log('Tipe frame tidak dikenal: 0x${_parser.type.toRadixString(16)}');
    }
  }

  void _ingestGps(GpsPayload g) {
    final now = DateTime.now();
    _firstGpsAt ??= now;
    final el = now.difference(_firstGpsAt!);
    String two(int n) => n.toString().padLeft(2, '0');
    final mission =
        '${two(el.inHours)}:${two(el.inMinutes % 60)}:${two(el.inSeconds % 60)}';

    final fix = g.fixValid;
    final alt = fix ? g.altM.toStringAsFixed(1) : 'NaN';
    final csv = [
      teamId,
      mission,
      _unwrapped,
      alt, // ALTITUDE (altitude GPS, belum ada barometer)
      'NaN', // PRESSURE
      'NaN', // TEMPERATURE
      'NaN', // VOLTAGE
      'NaN', // ROLL
      'NaN', // PITCH
      'NaN', // YAW
      fix ? g.lat.toStringAsFixed(6) : 'NaN',
      fix ? g.lon.toStringAsFixed(6) : 'NaN',
      alt, // GPS_ALT
      'UNKNOWN',
    ].join(',');

    final t = Telemetry.fromCsv(csv);
    if (t == null) {
      _log('Paket GPS gagal diubah ke Telemetry');
      return;
    }

    _latest = t;
    _latestCurrent = double.nan;
    latestSpeedKmh = g.speedKmh;
    latestSats = g.sats;
    _history.add(t);
    _currentHistory.add(double.nan);
    _totalReceived++;
    if (_history.length > maxHistory) {
      _history.removeAt(0);
      _currentHistory.removeAt(0);
    }

    _log('RX #$_unwrapped | ${fix ? 'FIX' : 'NO FIX'} | '
        '${g.lat.toStringAsFixed(5)}, ${g.lon.toStringAsFixed(5)} | '
        'ALT ${g.altM.toStringAsFixed(1)} m | '
        '${g.speedKmh.toStringAsFixed(1)} km/h | ${g.sats} sat');
    notifyListeners();
  }

  void _setStatus(ConnectionStatus s, String msg) {
    _status = s;
    _statusMessage = msg;
    notifyListeners();
  }

  @override
  void dispose() {
    _stopped = true;
    _retryTimer?.cancel();
    _closeHardware();
    super.dispose();
  }
}
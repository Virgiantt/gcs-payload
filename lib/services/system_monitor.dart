import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// Memantau CPU / RAM sistem secara ringan (sampling tiap 2 detik).
///  - Windows : FFI ke kernel32 (GlobalMemoryStatusEx, GetSystemTimes)
///  - Linux   : baca /proc/stat, /proc/meminfo, suhu thermal (cocok utk Raspberry Pi)
///  - Lainnya : hanya RAM aplikasi + jumlah core
class SystemMonitor extends ChangeNotifier {
  final DateTime _started = DateTime.now();
  Timer? _timer;
  bool _disposed = false;

  final int cores = Platform.numberOfProcessors;
  double? cpuPercent;
  double? ramUsedMb;
  double? ramTotalMb;
  double? cpuTempC;
  int appRamMb = 0;

  Duration get uptime => DateTime.now().difference(_started);

  double? get ramPercent => (ramUsedMb != null && ramTotalMb != null)
      ? ramUsedMb! / ramTotalMb! * 100
      : null;

  // ---- state untuk hitung delta CPU ----
  int? _prevTotal, _prevIdle; // linux
  int? _pIdle, _pKernel, _pUser; // windows

  // ---- fungsi FFI Windows ----
  int Function(Pointer<Uint8>)? _memStatus;
  int Function(Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>)? _sysTimes;

  void start() {
    _sample();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _sample());
  }

  void _sample() {
    try {
      appRamMb = ProcessInfo.currentRss ~/ (1024 * 1024);
      if (Platform.isWindows) {
        _sampleWindows();
      } else if (Platform.isLinux) {
        _sampleLinux();
      }
    } catch (e) {
      debugPrint('[SYS] sample error: $e');
    }
    if (!_disposed) notifyListeners();
  }

  // ===================== WINDOWS =====================
  void _initWindows() {
    final k32 = DynamicLibrary.open('kernel32.dll');
    _memStatus = k32.lookupFunction<Int32 Function(Pointer<Uint8>),
        int Function(Pointer<Uint8>)>('GlobalMemoryStatusEx');
    _sysTimes = k32.lookupFunction<
        Int32 Function(Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>),
        int Function(Pointer<Uint64>, Pointer<Uint64>,
            Pointer<Uint64>)>('GetSystemTimes');
  }

  void _sampleWindows() {
    if (_memStatus == null) _initWindows();

    // RAM: struct MEMORYSTATUSEX (64 byte)
    final mem = calloc<Uint8>(64);
    try {
      mem.cast<Uint32>()[0] = 64; // dwLength
      if (_memStatus!(mem) != 0) {
        final u64 = mem.cast<Uint64>();
        final total = u64[1]; // ullTotalPhys
        final avail = u64[2]; // ullAvailPhys
        ramTotalMb = total / (1024 * 1024);
        ramUsedMb = (total - avail) / (1024 * 1024);
      }
    } finally {
      calloc.free(mem);
    }

    // CPU: selisih waktu idle/kernel/user antar sampling
    final idle = calloc<Uint64>();
    final kernel = calloc<Uint64>();
    final user = calloc<Uint64>();
    try {
      if (_sysTimes!(idle, kernel, user) != 0) {
        final i = idle.value, k = kernel.value, u = user.value;
        if (_pIdle != null) {
          final dIdle = i - _pIdle!;
          final dTotal = (k - _pKernel!) + (u - _pUser!); // kernel sudah termasuk idle
          if (dTotal > 0) {
            cpuPercent = ((dTotal - dIdle) / dTotal * 100).clamp(0.0, 100.0);
          }
        }
        _pIdle = i;
        _pKernel = k;
        _pUser = u;
      }
    } finally {
      calloc.free(idle);
      calloc.free(kernel);
      calloc.free(user);
    }
  }

  // ===================== LINUX =====================
  void _sampleLinux() {
    // CPU
    final stat = File('/proc/stat').readAsLinesSync().first.split(RegExp(r'\s+'));
    final v = stat.skip(1).where((e) => e.isNotEmpty).map(int.parse).toList();
    final idle = v[3] + (v.length > 4 ? v[4] : 0); // idle + iowait
    final total = v.fold<int>(0, (a, b) => a + b);
    if (_prevTotal != null) {
      final dTotal = total - _prevTotal!;
      final dIdle = idle - _prevIdle!;
      if (dTotal > 0) {
        cpuPercent = ((dTotal - dIdle) / dTotal * 100).clamp(0.0, 100.0);
      }
    }
    _prevTotal = total;
    _prevIdle = idle;

    // RAM
    final info = <String, int>{};
    for (final line in File('/proc/meminfo').readAsLinesSync()) {
      final m = RegExp(r'^(\w+):\s+(\d+)').firstMatch(line);
      if (m != null) info[m.group(1)!] = int.parse(m.group(2)!);
    }
    final t = info['MemTotal'];
    final a = info['MemAvailable'];
    if (t != null && a != null) {
      ramTotalMb = t / 1024;
      ramUsedMb = (t - a) / 1024;
    }

    // Suhu CPU (Raspberry Pi dll.)
    final tf = File('/sys/class/thermal/thermal_zone0/temp');
    if (tf.existsSync()) {
      final raw = int.tryParse(tf.readAsStringSync().trim());
      if (raw != null) cpuTempC = raw / 1000.0;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
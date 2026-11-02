import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// Sumber citra satelit. Urutan {z}/{y}/{x} milik Esri.
const String kSatTileUrl =
    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
const String kSatAttribution = 'Citra: Esri, Maxar, Earthstar Geographics';

// ---------------- Matematika tile Web Mercator ----------------
double lonToTileX(double lon, int z) => (lon + 180.0) / 360.0 * (1 << z);

double latToTileY(double lat, int z) {
  final r = lat * math.pi / 180.0;
  return (1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) /
      2 *
      (1 << z);
}

double tileXToLon(double x, int z) => x / (1 << z) * 360.0 - 180.0;

double tileYToLat(double y, int z) {
  final n = math.pi * (1 - 2 * y / (1 << z));
  return math.atan((math.exp(n) - math.exp(-n)) / 2) * 180.0 / math.pi;
}

@immutable
class TileKey {
  const TileKey(this.z, this.x, this.y);
  final int z, x, y;

  @override
  bool operator ==(Object other) =>
      other is TileKey && other.z == z && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(z, x, y);
}

/// Cache tile bersama untuk semua tampilan peta 3D.
/// Urutan cari: memori, lalu disk (~/.cache/eepisat_tiles), lalu internet.
class TileCache extends ChangeNotifier {
  TileCache._();
  static final TileCache shared = TileCache._();

  String urlTemplate = kSatTileUrl;

  static const int _maxMemory = 220;
  static const int _maxParallel = 4;
  static const Duration _retryAfter = Duration(seconds: 20);

  final LinkedHashMap<TileKey, ui.Image> _mem =
      LinkedHashMap<TileKey, ui.Image>();
  final Set<TileKey> _loading = <TileKey>{};
  final Map<TileKey, DateTime> _failed = <TileKey, DateTime>{};
  List<TileKey> _queue = const [];
  int _qPos = 0;
  int _active = 0;
  Timer? _notifyTimer;
  Directory? _dir;
  bool _dirTried = false;

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8)
    ..userAgent = 'EEPISAT-GCS/1.0 (Flutter)';

  int get loadingCount => _loading.length;

  /// Ambil tile dari memori tanpa memicu unduhan.
  ui.Image? peek(TileKey k) {
    final img = _mem.remove(k);
    if (img != null) _mem[k] = img; // tandai baru dipakai (LRU)
    return img;
  }

  /// Daftar tile yang dibutuhkan frame ini, urut prioritas.
  /// Antrian lama diganti supaya tile yang sudah tidak terlihat tidak diunduh.
  void want(List<TileKey> keys) {
    final now = DateTime.now();
    _queue = [
      for (final k in keys)
        if (!_mem.containsKey(k) && !_loading.contains(k) && !_recentFail(k, now))
          k,
    ];
    _qPos = 0;
    _pump();
  }

  bool _recentFail(TileKey k, DateTime now) {
    final t = _failed[k];
    return t != null && now.difference(t) < _retryAfter;
  }

  void _pump() {
    while (_active < _maxParallel && _qPos < _queue.length) {
      final k = _queue[_qPos++];
      if (_mem.containsKey(k) || _loading.contains(k)) continue;
      _active++;
      _loading.add(k);
      _load(k).whenComplete(() {
        _active--;
        _loading.remove(k);
        _pump();
      });
    }
  }

  Future<void> _load(TileKey k) async {
    try {
      final f = await _fileFor(k);
      Uint8List? bytes;
      var fromDisk = false;
      if (f != null && await f.exists()) {
        bytes = await f.readAsBytes();
        fromDisk = bytes.isNotEmpty;
      }
      if (!fromDisk) {
        bytes = await _download(k);
        if (f != null) {
          try {
            await f.parent.create(recursive: true);
            await f.writeAsBytes(bytes);
          } catch (_) {}
        }
      }
      try {
        final codec = await ui.instantiateImageCodec(bytes!);
        final frame = await codec.getNextFrame();
        codec.dispose();
        _put(k, frame.image);
        _failed.remove(k);
      } catch (e) {
        // File cache rusak: hapus supaya diunduh ulang.
        if (fromDisk && f != null) {
          try {
            await f.delete();
          } catch (_) {}
        }
        rethrow;
      }
    } catch (_) {
      _failed[k] = DateTime.now();
    }
  }

  void _put(TileKey k, ui.Image img) {
    _mem.remove(k)?.dispose();
    _mem[k] = img;
    while (_mem.length > _maxMemory) {
      final oldest = _mem.keys.first;
      _mem.remove(oldest)?.dispose();
    }
    _notifyTimer ??= Timer(const Duration(milliseconds: 60), () {
      _notifyTimer = null;
      notifyListeners();
    });
  }

  Future<Uint8List> _download(TileKey k) async {
    final url = urlTemplate
        .replaceAll('{z}', '${k.z}')
        .replaceAll('{x}', '${k.x}')
        .replaceAll('{y}', '${k.y}');
    final req = await _http.getUrl(Uri.parse(url));
    final res = await req.close().timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw HttpException('HTTP ${res.statusCode}', uri: Uri.parse(url));
    }
    final b = BytesBuilder(copy: false);
    await for (final chunk in res.timeout(const Duration(seconds: 15))) {
      b.add(chunk);
    }
    return b.takeBytes();
  }

  Future<Directory?> _cacheDir() async {
    if (_dirTried) return _dir;
    _dirTried = true;
    try {
      final home =
          Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      final base = home != null ? '$home/.cache' : Directory.systemTemp.path;
      final host = Uri.parse(urlTemplate).host;
      final d = Directory('$base/eepisat_tiles/$host');
      await d.create(recursive: true);
      _dir = d;
    } catch (_) {
      _dir = null;
    }
    return _dir;
  }

  Future<File?> _fileFor(TileKey k) async {
    final d = await _cacheDir();
    if (d == null) return null;
    return File('${d.path}/${k.z}/${k.x}/${k.y}.tile');
  }

  /// Unduh citra area peluncuran ke disk sebelum terbang.
  /// Zoom 12 sampai 17 radius 3 km, zoom 18 radius 1,2 km.
  /// Mengembalikan jumlah tile baru yang tersimpan.
  Future<int> prefetch(
    double lat,
    double lon, {
    void Function(int done, int total)? onProgress,
  }) async {
    final keys = <TileKey>[];
    for (var z = 12; z <= 18; z++) {
      final r = z >= 18 ? 1200.0 : 3000.0;
      final dLat = r / 111320.0;
      final dLon = r / (111320.0 * math.cos(lat * math.pi / 180));
      final x0 = lonToTileX(lon - dLon, z).floor();
      final x1 = lonToTileX(lon + dLon, z).floor();
      final y0 = latToTileY(lat + dLat, z).floor();
      final y1 = latToTileY(lat - dLat, z).floor();
      for (var x = x0; x <= x1; x++) {
        for (var y = y0; y <= y1; y++) {
          keys.add(TileKey(z, x, y));
        }
      }
    }

    var done = 0, added = 0, next = 0;
    final total = keys.length;

    Future<void> worker() async {
      while (next < keys.length) {
        final k = keys[next++];
        try {
          final f = await _fileFor(k);
          if (f != null && !await f.exists()) {
            final b = await _download(k);
            await f.parent.create(recursive: true);
            await f.writeAsBytes(b);
            added++;
          }
        } catch (_) {}
        done++;
        onProgress?.call(done, total);
      }
    }

    await Future.wait(List.generate(_maxParallel, (_) => worker()));
    return added;
  }
}
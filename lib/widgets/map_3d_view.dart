import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../models/telemetry.dart';
import '../services/tile_cache.dart';
import '../theme/app_theme.dart';
import 'glb_mesh.dart';

// =========================================================
// KONFIGURASI MODEL
// =========================================================

/// Spesifikasi satu model 3D.
class ModelSpec {
  const ModelSpec({
    required this.asset,
    required this.sizeM,
    this.screenScale = 1.0,
    this.autoAlign = true,
    this.fixXDeg = 0,
    this.fixYDeg = 0,
    this.fixZDeg = 0,
  });

  final String asset;

  /// Ukuran fisik sisi terpanjang (m). Dipakai saat kamera sangat dekat.
  final double sizeM;

  /// Pengali ukuran di layar relatif terhadap model lain.
  final double screenScale;

  /// Putar otomatis supaya sumbu terpanjang tegak.
  final bool autoAlign;

  /// Koreksi sumbu manual (derajat). Isi fixXDeg = 180 kalau model terbalik.
  final double fixXDeg, fixYDeg, fixZDeg;
}

/// Dipakai saat LAUNCH_PAD dan ASCENT.
const ModelSpec kRocketModel = ModelSpec(
  asset: 'assets/models/rocket.glb',
  sizeM: 1.8,
  screenScale: 1.25,
);

/// Dipakai mulai APOGEE, saat payload sudah terpisah dari roket.
const ModelSpec kPayloadModel = ModelSpec(
  asset: 'assets/models/payload.glb',
  sizeM: 0.31,
);

/// State yang berarti payload sudah lepas dari roket.
const Set<String> kSeparatedStates = {'APOGEE', 'DESCENT', 'LANDED'};

/// State yang berarti payload masih di dalam roket.
const Set<String> kAttachedStates = {'LAUNCH_PAD', 'ASCENT'};

// =========================================================
// KONFIGURASI LAIN
// =========================================================

/// true: yaw dianggap heading kompas (searah jarum jam dari utara).
const bool kYawClockwise = true;

/// Offset yaw bila sisi depan model tidak menghadap utara saat yaw = 0.
const double kYawOffsetDeg = 0;

/// Batas segitiga model. Turunkan bila RPi terasa berat.
const int kMaxModelTriangles = 3000;

/// Radius lingkaran area di tanah (m).
const double kRangeRingM = 30;

/// Tinggi model di layar sebagai fraksi tinggi panel.
const double kModelScreenFrac = 0.34;
const double kModelScreenFracCompact = 0.30;

/// Pilihan pengali ukuran model (tombol "1x" di panel).
const List<double> kModelScales = [0.6, 1.0, 1.6, 2.4];

/// Resolusi capture relatif terhadap ukuran panel di layar.
const double kCapturePixelRatio = 2.0;

/// Folder capture, relatif terhadap folder home pengguna.
const String kCaptureSubdir = 'Pictures/EEPISAT';

const double _fovDeg = 50;
const double _minDist = 8;
const double _maxDist = 60000;
const double _near = 0.5;

double _clampD(double v, double lo, double hi) =>
    v < lo ? lo : (v > hi ? hi : v);

// =========================================================
// WIDGET
// =========================================================
class Map3DView extends StatefulWidget {
  final AppPalette palette;
  final Telemetry? data;
  final List<Telemetry> history;

  final ModelSpec rocketModel;
  final ModelSpec payloadModel;

  /// true untuk panel kecil di Dashboard.
  final bool compact;

  /// Titik awal kamera sebelum ada GPS fix.
  final double fallbackLat;
  final double fallbackLon;

  /// Teks di pita bawah gambar capture.
  final String captureLabel;

  const Map3DView({
    super.key,
    required this.palette,
    required this.data,
    this.history = const [],
    this.rocketModel = kRocketModel,
    this.payloadModel = kPayloadModel,
    this.compact = false,
    this.fallbackLat = -7.275764,
    this.fallbackLon = 112.794317,
    this.captureLabel = 'EEPISAT Team 1064',
  });

  @override
  State<Map3DView> createState() => _Map3DViewState();
}

class _Map3DViewState extends State<Map3DView>
    with SingleTickerProviderStateMixin {
  final TileCache _tiles = TileCache.shared;
  final GlobalKey _captureKey = GlobalKey();

  MeshData? _rocketMesh;
  MeshData? _payloadMesh;

  /// true setelah state APOGEE, DESCENT, atau LANDED terlihat.
  bool _separated = false;

  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;

  _Geo? _geo;
  List<V3> _trail = const [];
  int _trailSig = 0;

  V3? _posT, _posC;
  double _rollT = 0, _pitchT = 0, _yawT = 0;
  double _rollC = 0, _pitchC = 0, _yawC = 0;
  bool _hasAtt = false;
  bool _gpsFix = false;

  // Kamera orbit
  double _heading = 20, _tilt = 32, _dist = 180;
  bool _follow = true;
  V3 _frozen = V3.zero;
  V3 _offset = V3.zero;
  double _distAtStart = 180;

  // Pesan singkat di atas panel
  String? _msg;
  int _msgId = 0;

  bool _prefetching = false;
  bool _capturing = false;
  bool _flash = false;

  int _scaleIdx = 1;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _tiles.addListener(_onTiles);
    _loadModel(widget.rocketModel, (m) => _rocketMesh = m);
    _loadModel(widget.payloadModel, (m) => _payloadMesh = m);
    _ingest();
  }

  void _loadModel(ModelSpec spec, void Function(MeshData) assign) {
    MeshData.load(
      spec.asset,
      maxTriangles: kMaxModelTriangles,
      alignLongAxis: spec.autoAlign,
    ).then((m) {
      if (mounted) setState(() => assign(m));
    });
  }

  @override
  void didUpdateWidget(covariant Map3DView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _ingest();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _tiles.removeListener(_onTiles);
    super.dispose();
  }

  void _onTiles() {
    if (mounted) setState(() {});
  }

  void _showMsg(String m, {Duration hold = const Duration(seconds: 4)}) {
    final id = ++_msgId;
    setState(() => _msg = m);
    Future.delayed(hold, () {
      if (mounted && _msgId == id) setState(() => _msg = null);
    });
  }

  // ---------------- Data telemetri ----------------
  static bool _validGps(Telemetry h) =>
      h.gpsLat.isFinite &&
      h.gpsLon.isFinite &&
      h.gpsLat.abs() <= 90 &&
      h.gpsLon.abs() <= 180 &&
      (h.gpsLat.abs() > 1e-6 || h.gpsLon.abs() > 1e-6);

  /// Tinggi dari altitude barometrik (relatif titik launch), bukan GPS alt.
  static double _alt(Telemetry t) =>
      t.altitude.isFinite ? math.max(0.0, t.altitude) : 0.0;

  static V3 _enu(_Geo g, Telemetry t) =>
      V3(g.east(t.gpsLon), g.north(t.gpsLat), _alt(t));

  void _ingest() {
    final hist = widget.history;
    final t = widget.data;

    // Titik asal ENU = titik GPS valid pertama (biasanya launch pad).
    var geoChanged = false;
    if (_geo == null) {
      Telemetry? first;
      for (final h in hist) {
        if (_validGps(h)) {
          first = h;
          break;
        }
      }
      if (first == null && t != null && _validGps(t)) first = t;
      if (first != null) {
        _geo = _Geo(first.gpsLat, first.gpsLon);
        geoChanged = true;
      }
    } else if (t != null && _validGps(t)) {
      final e = _geo!.east(t.gpsLon), n = _geo!.north(t.gpsLat);
      if (e * e + n * n > 30000.0 * 30000.0) {
        _geo = _Geo(t.gpsLat, t.gpsLon);
        geoChanged = true;
      }
    }
    final geo = _geo ?? _Geo(widget.fallbackLat, widget.fallbackLon);
    if (geoChanged) {
      _posC = null;
      _posT = null;
      _trailSig = 0;
    }

    // Trail dihitung ulang hanya saat history berubah.
    final sig = Object.hash(
        hist.length, hist.isEmpty ? -1 : hist.last.packetCount, geo.lat0);
    if (sig != _trailSig) {
      _trailSig = sig;
      final step = math.max(1, hist.length ~/ 1500);
      final pts = <V3>[];
      for (var i = 0; i < hist.length; i += step) {
        if (_validGps(hist[i])) pts.add(_enu(geo, hist[i]));
      }
      if (step > 1 &&
          (hist.length - 1) % step != 0 &&
          _validGps(hist.last)) {
        pts.add(_enu(geo, hist.last));
      }
      _trail = pts;
    }

    if (t == null) return;

    // Ganti model berdasarkan flight state. State lain (misalnya kosong
    // atau rusak) tidak mengubah model yang sedang tampil.
    final st = t.state.trim().toUpperCase();
    if (kSeparatedStates.contains(st)) {
      _separated = true;
    } else if (kAttachedStates.contains(st)) {
      _separated = false;
    }

    _gpsFix = _validGps(t);
    if (_gpsFix) {
      final np = _enu(geo, t);
      if (_posC == null || (np - _posC!).length > 3000) _posC = np;
      _posT = np;
    } else if (_posT != null) {
      _posT = V3(_posT!.x, _posT!.y, _alt(t));
    }

    if (t.roll.isFinite) _rollT = t.roll;
    if (t.pitch.isFinite) _pitchT = t.pitch;
    if (t.yaw.isFinite) _yawT = t.yaw;
    if (!_hasAtt) {
      _rollC = _rollT;
      _pitchC = _pitchT;
      _yawC = _yawT;
      _hasAtt = true;
    }
    if (!_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    }
  }

  /// Menghaluskan gerak di antara paket (telemetri 1 Hz).
  void _onTick(Duration elapsed) {
    final dt = _lastTick == Duration.zero
        ? 1 / 60
        : _clampD((elapsed - _lastTick).inMicroseconds / 1e6, 0, 0.1);
    _lastTick = elapsed;
    final k = 1 - math.exp(-dt / 0.2);
    var moving = false;

    if (_posT != null) {
      _posC ??= _posT;
      final d = _posT! - _posC!;
      if (d.length > 0.01) {
        _posC = _posC! + d * k;
        moving = true;
      } else {
        _posC = _posT;
      }
    }

    double lerpAngle(double c, double t) {
      final d = ((t - c + 540) % 360) - 180;
      if (d.abs() < 0.05) return t;
      moving = true;
      return c + d * k;
    }

    _rollC = lerpAngle(_rollC, _rollT);
    _pitchC = lerpAngle(_pitchC, _pitchT);
    _yawC = lerpAngle(_yawC, _yawT);

    if (!moving) _ticker.stop();
    if (mounted) setState(() {});
  }

  // ---------------- Kamera dan gesture ----------------
  V3 get _target => (_follow ? (_posC ?? V3.zero) : _frozen) + _offset;

  void _onScaleUpdate(ScaleUpdateDetails d) {
    setState(() {
      if (d.pointerCount >= 2) {
        _dist = _clampD(_distAtStart / d.scale, _minDist, _maxDist);
        if (d.focalPointDelta.distance > 1.5) _panBy(d.focalPointDelta);
      } else {
        _heading = (_heading - d.focalPointDelta.dx * 0.35) % 360;
        _tilt = _clampD(_tilt + d.focalPointDelta.dy * 0.25, 8, 89);
      }
    });
  }

  void _panBy(Offset delta) {
    final h = _heading * math.pi / 180;
    final right = V3(math.cos(h), -math.sin(h), 0);
    final fwd = V3(math.sin(h), math.cos(h), 0);
    final height = context.size?.height ?? 400;
    final focal = (height / 2) / math.tan(_fovDeg / 2 * math.pi / 180);
    final mpp = _dist / focal;
    _offset = _offset - right * (delta.dx * mpp) + fwd * (delta.dy * mpp);
  }

  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(e, (ev) {
      final s = ev as PointerScrollEvent;
      setState(() => _dist = _clampD(
          _dist * math.exp(s.scrollDelta.dy * 0.0015), _minDist, _maxDist));
    });
  }

  void _zoom(double f) =>
      setState(() => _dist = _clampD(_dist * f, _minDist, _maxDist));

  void _toggleFollow() {
    setState(() {
      if (_follow) {
        _frozen = _target;
        _offset = V3.zero;
        _follow = false;
      } else {
        _offset = V3.zero;
        _follow = true;
      }
    });
  }

  void _toggleTop() => setState(() => _tilt = _tilt > 80 ? 32 : 89);

  void _resetView() {
    setState(() {
      _follow = true;
      _offset = V3.zero;
      _heading = 20;
      _tilt = 32;
      _dist = 180;
    });
  }

  void _fitTrail() {
    final pts = _trail;
    if (pts.length < 2) return;
    var x0 = double.infinity, y0 = double.infinity;
    var x1 = -double.infinity, y1 = -double.infinity, zMax = 0.0;
    for (final p in pts) {
      x0 = math.min(x0, p.x);
      y0 = math.min(y0, p.y);
      x1 = math.max(x1, p.x);
      y1 = math.max(y1, p.y);
      zMax = math.max(zMax, p.z);
    }
    final ext = math.max(math.max(x1 - x0, y1 - y0), zMax);
    setState(() {
      _follow = false;
      _offset = V3.zero;
      _frozen = V3((x0 + x1) / 2, (y0 + y1) / 2, zMax / 2);
      _dist = _clampD(ext * 1.5 + 80, _minDist, _maxDist);
      _tilt = 35;
    });
  }

  Future<void> _prefetch() async {
    if (_prefetching) return;
    final g = _geo;
    if (g == null) {
      _showMsg('Tunggu GPS fix untuk menentukan area');
      return;
    }
    _prefetching = true;
    _showMsg('Mengunduh citra area...', hold: const Duration(hours: 1));
    final n = await _tiles.prefetch(g.lat0, g.lon0, onProgress: (done, total) {
      if (mounted) setState(() => _msg = 'Mengunduh $done/$total tile');
    });
    _prefetching = false;
    if (mounted) _showMsg('$n tile baru tersimpan ke disk');
  }

  // ---------------- Capture ----------------
  Future<void> _capture() async {
    if (_capturing) return;
    _capturing = true;
    try {
      // Tunggu frame selesai supaya isi panel sudah tergambar lengkap.
      await WidgetsBinding.instance.endOfFrame;
      final ro = _captureKey.currentContext?.findRenderObject();
      if (ro is! RenderRepaintBoundary) throw 'panel belum siap';

      final raw = await ro.toImage(pixelRatio: kCapturePixelRatio);
      final framed = await _addFooter(raw, kCapturePixelRatio);
      raw.dispose();
      final png = await framed.toByteData(format: ui.ImageByteFormat.png);
      framed.dispose();
      if (png == null) throw 'gagal membuat PNG';

      final file = await _captureFile();
      await file.writeAsBytes(png.buffer.asUint8List());

      if (!mounted) return;
      setState(() => _flash = true);
      Future.delayed(const Duration(milliseconds: 140), () {
        if (mounted) setState(() => _flash = false);
      });
      _showMsg('Tersimpan: $kCaptureSubdir/${file.uri.pathSegments.last}');
    } catch (e) {
      if (mounted) _showMsg('Capture gagal: $e');
    } finally {
      _capturing = false;
    }
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// Menambahkan pita info di bawah gambar: waktu, paket, state, posisi.
  Future<ui.Image> _addFooter(ui.Image img, double ratio) async {
    final t = widget.data;
    final now = DateTime.now();
    final ts = '${now.year}-${_two(now.month)}-${_two(now.day)} '
        '${_two(now.hour)}:${_two(now.minute)}:${_two(now.second)}';
    String f(double v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)}';

    final line1 = '${widget.captureLabel}   $ts';
    final line2 = t == null
        ? 'Belum ada data telemetri'
        : 'Pkt #${t.packetCount.toString().padLeft(4, '0')}  '
            '${t.missionTime}  ${t.state}  '
            'Alt ${t.altitude.toStringAsFixed(1)} m  '
            'Lat ${t.gpsLat.toStringAsFixed(6)}  '
            'Lon ${t.gpsLon.toStringAsFixed(6)}  '
            'R ${f(t.roll)}  P ${f(t.pitch)}  Y ${f(t.yaw)}';

    final w = img.width.toDouble();
    final h = img.height.toDouble();
    final pad = 10 * ratio;

    TextPainter tp(String s, double size, Color c, FontWeight fw) =>
        TextPainter(
          text: TextSpan(
            text: s,
            style: TextStyle(
              color: c,
              fontSize: size * ratio,
              fontWeight: fw,
              fontFamily: 'monospace',
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
          ellipsis: '...',
        )..layout(maxWidth: w - 2 * pad);

    final a = tp(line1, 11, Colors.white, FontWeight.w800);
    final b = tp(line2, 10, const Color(0xFFB8C4D6), FontWeight.w600);
    final footerH = (pad * 2 + a.height + b.height + 4 * ratio).ceilToDouble();

    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawImage(img, Offset.zero, Paint());
    c.drawRect(Rect.fromLTWH(0, h, w, footerH),
        Paint()..color = const Color(0xFF0B1220));
    c.drawRect(Rect.fromLTWH(0, h, w, 2 * ratio),
        Paint()..color = widget.palette.accent);
    a.paint(c, Offset(pad, h + pad));
    b.paint(c, Offset(pad, h + pad + a.height + 4 * ratio));
    final pic = rec.endRecording();
    final out = await pic.toImage(img.width, (h + footerH).toInt());
    pic.dispose();
    return out;
  }

  Future<File> _captureFile() async {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.systemTemp.path;
    final dir = Directory('$home/$kCaptureSubdir');
    await dir.create(recursive: true);
    final now = DateTime.now();
    final t = widget.data;
    final stamp = '${now.year}${_two(now.month)}${_two(now.day)}_'
        '${_two(now.hour)}${_two(now.minute)}${_two(now.second)}';
    final extra = t == null
        ? ''
        : '_pkt${t.packetCount.toString().padLeft(4, '0')}_'
            '${t.state.replaceAll(RegExp(r'[^A-Za-z0-9]'), '')}';
    return File('${dir.path}/capture_$stamp$extra.png');
  }

  // ---------------- Build ----------------
  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final t = widget.data;
    final pay = _posC;
    final spec = _separated ? widget.payloadModel : widget.rocketModel;
    final mesh = _separated ? _payloadMesh : _rocketMesh;

    final scene = _Scene(
      geo: _geo ?? _Geo(widget.fallbackLat, widget.fallbackLon),
      tiles: _tiles,
      target: _target,
      heading: _heading,
      tilt: _tilt,
      dist: _dist,
      payload: pay,
      roll: _rollC,
      pitch: _pitchC,
      yaw: _yawC,
      mesh: mesh,
      spec: spec,
      trail: pay == null ? _trail : [..._trail, pay],
      palette: p,
      modelFrac: (widget.compact ? kModelScreenFracCompact : kModelScreenFrac) *
          kModelScales[_scaleIdx] *
          spec.screenScale,
      dark: p.name == 'dark',
    );

    return Container(
      decoration: BoxDecoration(
        color: p.panel,
        border: Border.all(color: p.border),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.hardEdge,
      child: Stack(
        children: [
          // Semua di dalam boundary ini ikut tertangkap saat capture.
          Positioned.fill(
            child: RepaintBoundary(
              key: _captureKey,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Listener(
                      onPointerSignal: _onPointerSignal,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onScaleStart: (_) => _distAtStart = _dist,
                        onScaleUpdate: _onScaleUpdate,
                        onDoubleTap: _resetView,
                        child: RepaintBoundary(
                          child: CustomPaint(
                            painter: _ScenePainter(scene),
                            size: Size.infinite,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 10,
                    top: 10,
                    child: _chip(Text(
                      t == null || !_gpsFix
                          ? 'Lat --  Lon --'
                          : 'Lat ${t.gpsLat.toStringAsFixed(6)}  '
                              'Lon ${t.gpsLon.toStringAsFixed(6)}',
                      style: _mono(11),
                    )),
                  ),
                  if (t != null && !_gpsFix)
                    Positioned(
                      left: 10,
                      top: 42,
                      child: _chip(Text('GPS belum fix',
                          style:
                              _mono(11, color: p.warn, w: FontWeight.w800))),
                    ),
                  if (t != null)
                    Positioned(right: 10, top: 10, child: _altChip(t)),
                  Positioned(left: 10, bottom: 10, child: _attChip(t)),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 2,
                    child: IgnorePointer(
                      child: Center(
                        child: Text(
                          kSatAttribution,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 8,
                            shadows: [
                              Shadow(blurRadius: 3, color: Colors.black)
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Di luar boundary: tidak ikut tertangkap.
          Positioned(right: 10, bottom: 10, child: _controls()),
          if (_msg != null)
            Positioned(
              top: 10,
              left: 0,
              right: 0,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 380),
                  child: _chip(Text(
                    _msg!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: _mono(11),
                  )),
                ),
              ),
            ),
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _flash ? 0.55 : 0,
                duration: const Duration(milliseconds: 120),
                child: const ColoredBox(color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  TextStyle _mono(double size,
          {Color? color, FontWeight w = FontWeight.w600}) =>
      TextStyle(
        color: color ?? widget.palette.text,
        fontSize: size,
        fontWeight: w,
        fontFamily: 'monospace',
      );

  Widget _chip(Widget child) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: widget.palette.panel.withValues(alpha: 0.9),
          border: Border.all(color: widget.palette.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: child,
      );

  Widget _altChip(Telemetry t) {
    final p = widget.palette;
    return _chip(Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.height, size: 12, color: p.accent),
          const SizedBox(width: 4),
          Text('${t.altitude.toStringAsFixed(1)} m',
              style: _mono(12, w: FontWeight.w800)),
        ]),
        Text('GPS ${t.gpsAlt.toStringAsFixed(1)} m',
            style: _mono(9, color: p.textDim)),
      ],
    ));
  }

  Widget _attChip(Telemetry? t) {
    final p = widget.palette;
    String f(double v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)}°';
    return _chip(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          t == null
              ? 'Menunggu data...'
              : 'R ${f(t.roll)}  P ${f(t.pitch)}  Y ${f(t.yaw)}',
          style: _mono(11),
        ),
        if (t != null)
          Text(
            '${t.state}  ·  ${_separated ? 'PAYLOAD' : 'ROCKET'}',
            style: _mono(9, color: p.accent, w: FontWeight.w800),
          ),
      ],
    ));
  }

  Widget _controls() {
    const gap = SizedBox(height: 6);
    final top = _tilt > 80;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _btn(_follow ? Icons.gps_fixed : Icons.gps_not_fixed,
            _follow ? 'Ikuti payload: aktif' : 'Ikuti payload: mati',
            _toggleFollow,
            active: _follow),
        gap,
        _btn(Icons.photo_camera_outlined, 'Capture tampilan ke PNG', _capture),
        gap,
        _scaleBtn(),
        gap,
        _btn(Icons.add, 'Perbesar', () => _zoom(0.7)),
        gap,
        _btn(Icons.remove, 'Perkecil', () => _zoom(1.45)),
        gap,
        _btn(top ? Icons.threed_rotation : Icons.map_outlined,
            top ? 'Kembali ke tampilan miring' : 'Lihat dari atas', _toggleTop),
        gap,
        _btn(Icons.timeline, 'Tampilkan seluruh lintasan', _fitTrail),
        if (!widget.compact) ...[
          gap,
          _btn(Icons.download_for_offline_outlined,
              'Simpan citra area peluncuran ke disk', _prefetch),
        ],
      ],
    );
  }

  Widget _scaleBtn() {
    final p = widget.palette;
    final v = kModelScales[_scaleIdx];
    final label = v == v.roundToDouble() ? '${v.toInt()}x' : '${v}x';
    return Tooltip(
      message: 'Ukuran model $label (tap untuk ganti)',
      child: InkWell(
        onTap: () => setState(
            () => _scaleIdx = (_scaleIdx + 1) % kModelScales.length),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: p.panel.withValues(alpha: 0.94),
            border: Border.all(color: p.border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(label,
              style: TextStyle(
                  color: p.accent, fontSize: 11, fontWeight: FontWeight.w800)),
        ),
      ),
    );
  }

  Widget _btn(IconData icon, String tip, VoidCallback onTap,
      {bool active = false}) {
    final p = widget.palette;
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: active ? p.accent : p.panel.withValues(alpha: 0.94),
            border: Border.all(color: active ? p.accent : p.border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 18, color: active ? Colors.white : p.text),
        ),
      ),
    );
  }
}

// =========================================================
// GEO, KAMERA, SCENE
// =========================================================

/// Konversi lat/lon ke meter lokal (ENU) di sekitar titik asal.
class _Geo {
  _Geo(this.lat0, this.lon0)
      : mLat = 111132.954 -
            559.822 * math.cos(2 * lat0 * math.pi / 180) +
            1.175 * math.cos(4 * lat0 * math.pi / 180),
        mLon = 111412.84 * math.cos(lat0 * math.pi / 180) -
            93.5 * math.cos(3 * lat0 * math.pi / 180);

  final double lat0, lon0, mLat, mLon;

  double east(double lon) => (lon - lon0) * mLon;
  double north(double lat) => (lat - lat0) * mLat;
  double lonOf(double east) => lon0 + east / mLon;
  double latOf(double north) => lat0 + north / mLat;
}

class _Cam {
  V3 pos = V3.zero, r = V3.zero, u = V3.zero, f = V3.zero;
  double focal = 1, cx = 0, cy = 0;

  void setup(V3 target, double headingDeg, double tiltDeg, double dist,
      Size size) {
    final h = headingDeg * math.pi / 180, e = tiltDeg * math.pi / 180;
    pos = target +
        V3(-math.sin(h) * math.cos(e), -math.cos(h) * math.cos(e),
                math.sin(e)) *
            dist;
    f = (target - pos).normalized();
    r = f.cross(const V3(0, 0, 1)).normalized();
    u = r.cross(f);
    focal = (size.height / 2) / math.tan(_fovDeg / 2 * math.pi / 180);
    cx = size.width / 2;
    cy = size.height / 2;
  }

  /// Titik dunia ke ruang kamera (x kanan, y atas, z kedalaman).
  V3 cam(double x, double y, double z) {
    final dx = x - pos.x, dy = y - pos.y, dz = z - pos.z;
    return V3(
      dx * r.x + dy * r.y + dz * r.z,
      dx * u.x + dy * u.y + dz * u.z,
      dx * f.x + dy * f.y + dz * f.z,
    );
  }

  V3 camV(V3 p) => cam(p.x, p.y, p.z);

  Offset proj(V3 c) => Offset(cx + focal * c.x / c.z, cy - focal * c.y / c.z);
}

class _Scene {
  _Scene({
    required this.geo,
    required this.tiles,
    required this.target,
    required this.heading,
    required this.tilt,
    required this.dist,
    required this.payload,
    required this.roll,
    required this.pitch,
    required this.yaw,
    required this.mesh,
    required this.spec,
    required this.trail,
    required this.palette,
    required this.modelFrac,
    required this.dark,
  });

  final _Geo geo;
  final TileCache tiles;
  final V3 target;
  final double heading, tilt, dist;
  final V3? payload;
  final double roll, pitch, yaw;
  final MeshData? mesh;
  final ModelSpec spec;
  final List<V3> trail;
  final AppPalette palette;

  /// Tinggi minimum model di layar, fraksi dari tinggi panel.
  final double modelFrac;
  final bool dark;
}

class _TileRef {
  _TileRef(this.key, this.gx, this.d2);
  final TileKey key;
  final int gx; // x tanpa wrap, untuk geometri
  final int d2;
}

class _CV {
  _CV(this.p, this.u, this.v);
  final V3 p;
  final double u, v;

  static _CV atNear(_CV a, _CV b, double near) {
    final t = (near - a.p.z) / (b.p.z - a.p.z);
    return _CV(a.p + (b.p - a.p) * t, a.u + (b.u - a.u) * t,
        a.v + (b.v - a.v) * t);
  }
}

// =========================================================
// PAINTER
// =========================================================
class _ScenePainter extends CustomPainter {
  _ScenePainter(this.s);
  final _Scene s;
  final _Cam cam = _Cam();

  /// Near plane khusus tanah. Tanah yang terlihat di layar selalu berjarak
  /// minimal ~0,9 x tinggi kamera, jadi aman dipotong di 0,5 x tinggi kamera.
  double _gNear = _near;
  double _minPx = 60;

  static final Float64List _ident = Float64List.fromList(
      [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]);
  static final V3 _light = const V3(-0.35, -0.45, 0.82).normalized();

  /// glTF (Y atas) ke ENU (Z atas): timur = x, utara = -z, atas = y.
  static final M3 _toEnu =
      M3(Float64List.fromList([1, 0, 0, 0, 0, -1, 0, 1, 0]));

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 4 || size.height < 4) return;
    canvas.clipRect(Offset.zero & size);
    cam.setup(s.target, s.heading, s.tilt, s.dist, size);
    _gNear = math.max(_near, math.max(0.0, cam.pos.z) * 0.5);
    _minPx = s.modelFrac * size.height;

    _backdrop(canvas, size);
    _ground(canvas, size);
    final p = s.payload;
    if (p != null) _ring(canvas, p, kRangeRingM);
    _trail(canvas);
    if (p != null) _model(canvas, p);
  }

  @override
  bool shouldRepaint(covariant _ScenePainter oldDelegate) => true;

  // ---------------- Langit ----------------
  void _backdrop(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = s.dark ? const Color(0xFF263024) : const Color(0xFFB7BFA6),
    );
    final h = s.heading * math.pi / 180;
    final d = V3(math.sin(h), math.cos(h), 0);
    final dz = d.dot(cam.f);
    if (dz <= 1e-6) return;
    var hy = cam.cy - cam.focal * d.dot(cam.u) / dz;
    if (hy <= 1) return;
    hy = math.min(hy, size.height);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, hy),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(0, hy),
          s.dark
              ? const [Color(0xFF0B1220), Color(0xFF2E3D55)]
              : const [Color(0xFF7FAEE0), Color(0xFFE3EEF8)],
        ),
    );
  }

  // ---------------- Tanah (tile satelit) ----------------
  void _ground(Canvas canvas, Size size) {
    final g = s.geo;
    final gx = s.target.x, gy = s.target.y;
    final lat = g.latOf(gy), lon = g.lonOf(gx);
    final viewDist = (cam.pos - V3(gx, gy, 0)).length;
    final span = math.max(1.0, viewDist * size.width / cam.focal);
    final world = 40075016.686 * math.cos(lat * math.pi / 180);

    // Zoom detail: kira-kira 3 tile melintang layar di titik target.
    var z = (math.log(world * 3 / span) / math.ln2).floor();
    z = math.max(2, math.min(18, z));

    // Tiga lapis: jauh (z-6), menengah (z-3), detail (z).
    final levels = <List<int>>[
      if (z - 6 >= 1) [z - 6, 2],
      if (z - 3 >= 1) [z - 3, 2],
      [z, 3],
    ];

    final plan = <List<_TileRef>>[];
    final want = <TileKey>[];
    for (final lv in levels) {
      final lz = lv[0], rad = lv[1];
      final n = 1 << lz;
      final tx = lonToTileX(lon, lz).floor();
      final ty = latToTileY(lat, lz).floor();
      final refs = <_TileRef>[];
      for (var dy = -rad; dy <= rad; dy++) {
        for (var dx = -rad; dx <= rad; dx++) {
          final y = ty + dy;
          if (y < 0 || y >= n) continue;
          final ux = tx + dx;
          refs.add(_TileRef(
              TileKey(lz, ((ux % n) + n) % n, y), ux, dx * dx + dy * dy));
        }
      }
      refs.sort((a, b) => a.d2.compareTo(b.d2));
      want.addAll(refs.map((r) => r.key));
      plan.add(refs);
    }
    s.tiles.want(want);

    final screen = (Offset.zero & size).inflate(40);
    for (final refs in plan) {
      for (final r in refs) {
        final img = s.tiles.peek(r.key);
        if (img != null) _tile(canvas, r, img, screen);
      }
    }
  }

  void _tile(Canvas canvas, _TileRef r, ui.Image img, Rect screen) {
    const n = 6; // subdivisi supaya distorsi tekstur kecil
    final z = r.key.z;
    final g = s.geo;
    final grid = List<V3>.filled((n + 1) * (n + 1), V3.zero);
    var anyFront = false, allFront = true;
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;

    for (var j = 0; j <= n; j++) {
      final north = g.north(tileYToLat(r.key.y + j / n, z));
      for (var i = 0; i <= n; i++) {
        final east = g.east(tileXToLon(r.gx + i / n, z));
        final c = cam.cam(east, north, 0);
        grid[j * (n + 1) + i] = c;
        if (c.z >= _gNear) {
          anyFront = true;
          final o = cam.proj(c);
          minX = math.min(minX, o.dx);
          minY = math.min(minY, o.dy);
          maxX = math.max(maxX, o.dx);
          maxY = math.max(maxY, o.dy);
        } else {
          allFront = false;
        }
      }
    }
    if (!anyFront) return;
    if (allFront &&
        !screen.overlaps(Rect.fromLTRB(minX, minY, maxX, maxY))) {
      return;
    }

    final w = img.width.toDouble(), h = img.height.toDouble();
    final pos = <double>[], tex = <double>[];
    for (var j = 0; j < n; j++) {
      for (var i = 0; i < n; i++) {
        final ia = j * (n + 1) + i, ib = ia + 1;
        final id = ia + n + 1, ic = id + 1;
        final u0 = i / n * w, u1 = (i + 1) / n * w;
        final v0 = j / n * h, v1 = (j + 1) / n * h;
        _tri(pos, tex, _CV(grid[ia], u0, v0), _CV(grid[ib], u1, v0),
            _CV(grid[ic], u1, v1));
        _tri(pos, tex, _CV(grid[ia], u0, v0), _CV(grid[ic], u1, v1),
            _CV(grid[id], u0, v1));
      }
    }
    if (pos.isEmpty) return;

    final paint = Paint()
      ..shader = ui.ImageShader(img, ui.TileMode.clamp, ui.TileMode.clamp,
          _ident,
          filterQuality: FilterQuality.low);
    canvas.drawVertices(
      ui.Vertices.raw(ui.VertexMode.triangles, Float32List.fromList(pos),
          textureCoordinates: Float32List.fromList(tex)),
      BlendMode.srcOver,
      paint,
    );
  }

  /// Segitiga dengan clipping di near plane (Sutherland-Hodgman satu bidang).
  void _tri(List<double> pos, List<double> tex, _CV a, _CV b, _CV c) {
    final ina = a.p.z >= _gNear, inb = b.p.z >= _gNear, inc = c.p.z >= _gNear;
    if (!ina && !inb && !inc) return;
    if (ina && inb && inc) {
      _emit(pos, tex, a);
      _emit(pos, tex, b);
      _emit(pos, tex, c);
      return;
    }
    final src = [a, b, c];
    final poly = <_CV>[];
    for (var i = 0; i < 3; i++) {
      final cur = src[i], prev = src[(i + 2) % 3];
      final ci = cur.p.z >= _gNear, pi = prev.p.z >= _gNear;
      if (ci) {
        if (!pi) poly.add(_CV.atNear(prev, cur, _gNear));
        poly.add(cur);
      } else if (pi) {
        poly.add(_CV.atNear(prev, cur, _gNear));
      }
    }
    for (var i = 1; i + 1 < poly.length; i++) {
      _emit(pos, tex, poly[0]);
      _emit(pos, tex, poly[i]);
      _emit(pos, tex, poly[i + 1]);
    }
  }

  void _emit(List<double> pos, List<double> tex, _CV v) {
    final o = cam.proj(v.p);
    pos
      ..add(o.dx)
      ..add(o.dy);
    tex
      ..add(v.u)
      ..add(v.v);
  }

  // ---------------- Lingkaran area di tanah ----------------
  void _ring(Canvas canvas, V3 center, double radius) {
    final path = Path();
    for (var i = 0; i <= 48; i++) {
      final a = 2 * math.pi * i / 48;
      final c = cam.cam(center.x + radius * math.cos(a),
          center.y + radius * math.sin(a), 0.05);
      if (c.z < _near) return;
      final o = cam.proj(c);
      if (i == 0) {
        path.moveTo(o.dx, o.dy);
      } else {
        path.lineTo(o.dx, o.dy);
      }
    }
    path.close();
    final accent = s.palette.accent;
    canvas.drawPath(path, Paint()..color = accent.withValues(alpha: 0.12));
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = accent.withValues(alpha: 0.6),
    );
  }

  // ---------------- Lintasan 3D ----------------
  void _trail(Canvas canvas) {
    final accent = s.palette.accent;
    final pts = s.trail;
    Paint stroke(double w, Color c) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = c;

    if (pts.length >= 2) {
      final ground = [for (final p in pts) V3(p.x, p.y, 0.05)];
      _line(canvas, ground, stroke(3, Colors.black.withValues(alpha: 0.28)));
      _line(canvas, pts, stroke(10, accent.withValues(alpha: 0.18)));
      _line(canvas, pts, stroke(5.5, Colors.white.withValues(alpha: 0.85)));
      _line(canvas, pts, stroke(3.2, accent));

      final st = cam.cam(pts.first.x, pts.first.y, 0.05);
      if (st.z >= _near) {
        final o = cam.proj(st);
        canvas.drawCircle(o, 7, Paint()..color = s.palette.ok);
        canvas.drawCircle(o, 7, stroke(2, Colors.white));
      }
    }

    // Garis jatuh dari model ke tanah sebagai penanda ketinggian.
    final p = s.payload;
    if (p != null && p.z > 0.5) {
      _line(canvas, [p, V3(p.x, p.y, 0.05)],
          stroke(1.2, accent.withValues(alpha: 0.7)));
    }
  }

  void _line(Canvas canvas, List<V3> pts, Paint paint) {
    if (pts.length < 2) return;
    final path = Path();
    var pen = false;
    var prev = cam.camV(pts.first);
    for (var i = 1; i < pts.length; i++) {
      final cur = cam.camV(pts[i]);
      final pi = prev.z >= _near, ci = cur.z >= _near;
      if (pi || ci) {
        final a = pi ? prev : _clipNear(prev, cur);
        final b = ci ? cur : _clipNear(prev, cur);
        final oa = cam.proj(a), ob = cam.proj(b);
        if (!pen || !pi) path.moveTo(oa.dx, oa.dy);
        path.lineTo(ob.dx, ob.dy);
        pen = ci;
      } else {
        pen = false;
      }
      prev = cur;
    }
    canvas.drawPath(path, paint);
  }

  V3 _clipNear(V3 a, V3 b) {
    final t = (_near - a.z) / (b.z - a.z);
    return a + (b - a) * t;
  }

  // ---------------- Model (roket atau payload) ----------------
  void _model(Canvas canvas, V3 p0) {
    final pc = cam.camV(p0);
    if (pc.z < _near) return;
    final accent = s.palette.accent;
    final center = cam.proj(pc);
    final spec = s.spec;

    // Skala visual: ukuran asli, atau minimal _minPx piksel di layar.
    final size = math.max(spec.sizeM, _minPx * pc.z / cam.focal);

    canvas.drawCircle(center, _minPx * 0.62,
        Paint()..color = accent.withValues(alpha: 0.10));

    final mesh = s.mesh;
    if (mesh == null) {
      canvas.drawCircle(center, 9, Paint()..color = accent);
      canvas.drawCircle(
          center,
          9,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5
            ..color = Colors.white);
      return;
    }

    // Urutan rotasi sama dengan model-viewer: Y(yaw) X(pitch) Z(roll).
    const d2r = math.pi / 180;
    final fix = M3.rotX(spec.fixXDeg * d2r) *
        M3.rotY(spec.fixYDeg * d2r) *
        M3.rotZ(spec.fixZDeg * d2r);
    final yawDeg = (kYawClockwise ? -s.yaw : s.yaw) + kYawOffsetDeg;
    final m = (_toEnu *
            M3.rotY(yawDeg * d2r) *
            M3.rotX(s.pitch * d2r) *
            M3.rotZ(s.roll * d2r) *
            fix)
        .m;

    final vp = mesh.positions;
    final vc = mesh.vertexCount;
    final wx = Float64List(vc), wy = Float64List(vc), wz = Float64List(vc);
    var minZ = double.infinity;
    for (var i = 0; i < vc; i++) {
      final x = vp[i * 3], y = vp[i * 3 + 1], z = vp[i * 3 + 2];
      wx[i] = (m[0] * x + m[1] * y + m[2] * z) * size;
      wy[i] = (m[3] * x + m[4] * y + m[5] * z) * size;
      wz[i] = (m[6] * x + m[7] * y + m[8] * z) * size;
      if (wz[i] < minZ) minZ = wz[i];
    }
    // Model yang diperbesar tidak boleh menembus tanah.
    final ox = p0.x, oy = p0.y;
    final oz = p0.z + math.max(0.0, -(p0.z + minZ) + 0.02);

    final ind = mesh.indices;
    final tc = mesh.triangleCount;

    // ---- Bayangan tegak lurus di tanah ----
    final gxv = Float64List(vc), gyv = Float64List(vc), gzv = Float64List(vc);
    for (var i = 0; i < vc; i++) {
      final q = cam.cam(ox + wx[i], oy + wy[i], 0.03);
      gxv[i] = q.x;
      gyv[i] = q.y;
      gzv[i] = q.z;
    }
    final sp = <double>[];
    var sx0 = double.infinity, sy0 = double.infinity;
    var sx1 = -double.infinity, sy1 = -double.infinity;
    for (var t = 0; t < tc; t++) {
      final a = ind[t * 3], b = ind[t * 3 + 1], d = ind[t * 3 + 2];
      if (gzv[a] < _near || gzv[b] < _near || gzv[d] < _near) continue;
      for (final v in [a, b, d]) {
        final x = cam.cx + cam.focal * gxv[v] / gzv[v];
        final y = cam.cy - cam.focal * gyv[v] / gzv[v];
        sp
          ..add(x)
          ..add(y);
        sx0 = math.min(sx0, x);
        sy0 = math.min(sy0, y);
        sx1 = math.max(sx1, x);
        sy1 = math.max(sy1, y);
      }
    }
    if (sp.isNotEmpty) {
      final alpha = _clampD(1 - p0.z / 400, 0.3, 1.0) * 0.35;
      canvas.saveLayer(Rect.fromLTRB(sx0, sy0, sx1, sy1).inflate(2),
          Paint()..color = Colors.black.withValues(alpha: alpha));
      canvas.drawVertices(
        ui.Vertices.raw(ui.VertexMode.triangles, Float32List.fromList(sp)),
        BlendMode.srcOver,
        Paint()..color = Colors.black,
      );
      canvas.restore();
    }

    // ---- Mesh: proyeksi, shading, urut jauh ke dekat ----
    final cxv = Float64List(vc), cyv = Float64List(vc), czv = Float64List(vc);
    for (var i = 0; i < vc; i++) {
      final q = cam.cam(ox + wx[i], oy + wy[i], oz + wz[i]);
      cxv[i] = q.x;
      cyv[i] = q.y;
      czv[i] = q.z;
    }

    final baseArgb = accent.toARGB32();
    final depth = Float64List(tc);
    final shade = Int32List(tc);
    final order = <int>[];
    final lx = _light.x, ly = _light.y, lz = _light.z;

    for (var t = 0; t < tc; t++) {
      final a = ind[t * 3], b = ind[t * 3 + 1], d = ind[t * 3 + 2];
      if (czv[a] < _near || czv[b] < _near || czv[d] < _near) continue;
      final e1x = wx[b] - wx[a], e1y = wy[b] - wy[a], e1z = wz[b] - wz[a];
      final e2x = wx[d] - wx[a], e2y = wy[d] - wy[a], e2z = wz[d] - wz[a];
      final nx = e1y * e2z - e1z * e2y;
      final ny = e1z * e2x - e1x * e2z;
      final nz = e1x * e2y - e1y * e2x;
      final nl = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (nl < 1e-12) continue;
      // Pencahayaan dua sisi karena winding mesh CAD sering tidak konsisten.
      final lit = 0.4 + 0.6 * ((nx * lx + ny * ly + nz * lz) / nl).abs();
      final col = mesh.colors[t] == 0 ? baseArgb : mesh.colors[t];
      final rr = (((col >> 16) & 0xFF) * lit).round();
      final gg = (((col >> 8) & 0xFF) * lit).round();
      final bb = ((col & 0xFF) * lit).round();
      shade[t] = (0xFF << 24) | (rr << 16) | (gg << 8) | bb;
      depth[t] = czv[a] + czv[b] + czv[d];
      order.add(t);
    }
    if (order.isEmpty) return;
    order.sort((x, y) => depth[y].compareTo(depth[x]));

    final pos = Float32List(order.length * 6);
    final cols = Int32List(order.length * 3);
    var k = 0;
    for (final t in order) {
      for (var j = 0; j < 3; j++) {
        final v = ind[t * 3 + j];
        pos[k * 2] = cam.cx + cam.focal * cxv[v] / czv[v];
        pos[k * 2 + 1] = cam.cy - cam.focal * cyv[v] / czv[v];
        cols[k] = shade[t];
        k++;
      }
    }
    canvas.drawVertices(
      ui.Vertices.raw(ui.VertexMode.triangles, pos, colors: cols),
      BlendMode.dst,
      Paint(),
    );
  }
}
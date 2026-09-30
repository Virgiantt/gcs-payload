import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../models/telemetry.dart';
import '../theme/app_theme.dart';

// =========================================================
// GLB PARSER (top-level supaya bisa dijalankan lewat compute/isolate)
// Mendukung: mesh triangles, hierarki node (matrix / TRS), warna material.
// Tidak mendukung: tekstur, Draco/meshopt, skinning, animasi.
// =========================================================
const int _kMaxTris = 25000;

class GlbMesh {
  final Float32List pos; // 9 float per segitiga, sudah dinormalisasi (radius 1)
  final Int32List rgb; // 0xRRGGBB per segitiga
  final Uint8List dbl; // 1 = doubleSided
  final int count;
  final bool simplified;
  GlbMesh(this.pos, this.rgb, this.dbl, this.count, this.simplified);
}

GlbMesh parseGlb(Uint8List bytes) {
  final bd = ByteData.sublistView(bytes);
  if (bytes.length < 20 || bd.getUint32(0, Endian.little) != 0x46546C67) {
    throw 'File bukan GLB yang valid';
  }

  Map<String, dynamic>? json;
  var binStart = -1;
  var off = 12;
  while (off + 8 <= bytes.length) {
    final len = bd.getUint32(off, Endian.little);
    final type = bd.getUint32(off + 4, Endian.little);
    if (type == 0x4E4F534A) {
      json = jsonDecode(
              utf8.decode(Uint8List.sublistView(bytes, off + 8, off + 8 + len)))
          as Map<String, dynamic>;
    } else if (type == 0x004E4942 && binStart < 0) {
      binStart = off + 8;
    }
    off += 8 + len;
  }
  if (json == null || binStart < 0) throw 'GLB tidak punya chunk JSON/BIN';

  final accessors = (json['accessors'] as List?) ?? const [];
  final views = (json['bufferViews'] as List?) ?? const [];
  final nodes = (json['nodes'] as List?) ?? const [];
  final meshes = (json['meshes'] as List?) ?? const [];
  final materials = (json['materials'] as List?) ?? const [];

  int csize(int ct) {
    switch (ct) {
      case 5126:
      case 5125:
        return 4;
      case 5123:
      case 5122:
        return 2;
      default:
        return 1;
    }
  }

  double rd(int o, int ct, bool norm) {
    switch (ct) {
      case 5126:
        return bd.getFloat32(o, Endian.little);
      case 5125:
        return bd.getUint32(o, Endian.little).toDouble();
      case 5123:
        final v = bd.getUint16(o, Endian.little);
        return norm ? v / 65535.0 : v.toDouble();
      case 5122:
        final v = bd.getInt16(o, Endian.little);
        return norm ? math.max(v / 32767.0, -1.0) : v.toDouble();
      case 5121:
        final v = bd.getUint8(o);
        return norm ? v / 255.0 : v.toDouble();
      case 5120:
        final v = bd.getInt8(o);
        return norm ? math.max(v / 127.0, -1.0) : v.toDouble();
    }
    return 0;
  }

  Float64List readAcc(int idx) {
    final a = accessors[idx] as Map<String, dynamic>;
    const compMap = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4};
    final comps = compMap[a['type']] ?? 1;
    final count = a['count'] as int;
    final ct = a['componentType'] as int;
    final norm = a['normalized'] == true;
    final out = Float64List(count * comps);
    if (a['bufferView'] == null) return out;
    final bv = views[a['bufferView'] as int] as Map<String, dynamic>;
    final base = binStart +
        ((bv['byteOffset'] ?? 0) as int) +
        ((a['byteOffset'] ?? 0) as int);
    final cs = csize(ct);
    final stride = (bv['byteStride'] ?? comps * cs) as int;
    for (var i = 0; i < count; i++) {
      for (var c = 0; c < comps; c++) {
        out[i * comps + c] = rd(base + i * stride + c * cs, ct, norm);
      }
    }
    return out;
  }

  Float64List mul(Float64List a, Float64List b) {
    final o = Float64List(16);
    for (var c = 0; c < 4; c++) {
      for (var r = 0; r < 4; r++) {
        var s = 0.0;
        for (var k = 0; k < 4; k++) {
          s += a[k * 4 + r] * b[c * 4 + k];
        }
        o[c * 4 + r] = s;
      }
    }
    return o;
  }

  Float64List nodeMatrix(Map<String, dynamic> n) {
    if (n['matrix'] is List) {
      final l =
          (n['matrix'] as List).map((e) => (e as num).toDouble()).toList();
      if (l.length == 16) return Float64List.fromList(l);
    }
    final t = (n['translation'] as List?)
            ?.map((e) => (e as num).toDouble())
            .toList() ??
        [0.0, 0.0, 0.0];
    final q =
        (n['rotation'] as List?)?.map((e) => (e as num).toDouble()).toList() ??
            [0.0, 0.0, 0.0, 1.0];
    final s =
        (n['scale'] as List?)?.map((e) => (e as num).toDouble()).toList() ??
            [1.0, 1.0, 1.0];
    final x = q[0], y = q[1], z = q[2], w = q[3];
    return Float64List.fromList([
      (1 - 2 * (y * y + z * z)) * s[0],
      (2 * (x * y + z * w)) * s[0],
      (2 * (x * z - y * w)) * s[0],
      0,
      (2 * (x * y - z * w)) * s[1],
      (1 - 2 * (x * x + z * z)) * s[1],
      (2 * (y * z + x * w)) * s[1],
      0,
      (2 * (x * z + y * w)) * s[2],
      (2 * (y * z - x * w)) * s[2],
      (1 - 2 * (x * x + y * y)) * s[2],
      0,
      t[0],
      t[1],
      t[2],
      1,
    ]);
  }

  int c8(num v) => (v * 255).round().clamp(0, 255).toInt();

  final tris = <double>[];
  final cols = <int>[];
  final dbls = <int>[];

  void addMesh(int mi, Float64List m) {
    final prims = ((meshes[mi] as Map)['primitives'] as List?) ?? const [];
    for (final p in prims) {
      if ((p['mode'] ?? 4) != 4) continue;
      if (p['extensions']?['KHR_draco_mesh_compression'] != null) continue;
      final posIdx = p['attributes']?['POSITION'];
      if (posIdx == null) continue;

      final pv = readAcc(posIdx as int);
      final vc = pv.length ~/ 3;
      final wp = Float64List(vc * 3);
      for (var i = 0; i < vc; i++) {
        final x = pv[i * 3], y = pv[i * 3 + 1], z = pv[i * 3 + 2];
        wp[i * 3] = m[0] * x + m[4] * y + m[8] * z + m[12];
        wp[i * 3 + 1] = m[1] * x + m[5] * y + m[9] * z + m[13];
        wp[i * 3 + 2] = m[2] * x + m[6] * y + m[10] * z + m[14];
      }

      List<int> ids;
      if (p['indices'] != null) {
        final r = readAcc(p['indices'] as int);
        ids = List<int>.generate(r.length, (i) => r[i].toInt());
      } else {
        ids = List<int>.generate(vc, (i) => i);
      }

      var cr = 200, cg = 205, cb = 215, dbl = 0;
      final matIdx = p['material'];
      if (matIdx != null) {
        final mat = materials[matIdx as int] as Map<String, dynamic>;
        dbl = mat['doubleSided'] == true ? 1 : 0;
        final f = mat['pbrMetallicRoughness']?['baseColorFactor'];
        if (f is List && f.length >= 3) {
          cr = c8(f[0] as num);
          cg = c8(f[1] as num);
          cb = c8(f[2] as num);
        }
      }
      final col = (cr << 16) | (cg << 8) | cb;

      for (var k = 0; k + 2 < ids.length; k += 3) {
        final a = ids[k], b = ids[k + 1], c = ids[k + 2];
        if (a >= vc || b >= vc || c >= vc) continue;
        tris.addAll([
          wp[a * 3],
          wp[a * 3 + 1],
          wp[a * 3 + 2],
          wp[b * 3],
          wp[b * 3 + 1],
          wp[b * 3 + 2],
          wp[c * 3],
          wp[c * 3 + 1],
          wp[c * 3 + 2],
        ]);
        cols.add(col);
        dbls.add(dbl);
      }
    }
  }

  final ident =
      Float64List.fromList([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]);

  void visit(int ni, Float64List parent, int depth) {
    if (depth > 64 || ni < 0 || ni >= nodes.length) return;
    final n = nodes[ni] as Map<String, dynamic>;
    final m = mul(parent, nodeMatrix(n));
    if (n['mesh'] != null) addMesh(n['mesh'] as int, m);
    for (final c in (n['children'] as List?) ?? const []) {
      visit(c as int, m, depth + 1);
    }
  }

  final scenes = json['scenes'] as List?;
  if (nodes.isEmpty) {
    for (var i = 0; i < meshes.length; i++) {
      addMesh(i, ident);
    }
  } else if (scenes != null && scenes.isNotEmpty) {
    final s = scenes[(json['scene'] ?? 0) as int] as Map<String, dynamic>;
    for (final r in (s['nodes'] as List?) ?? const []) {
      visit(r as int, ident, 0);
    }
  } else {
    // tanpa scene: cari node yang bukan anak siapa pun
    final isChild = <int>{};
    for (final n in nodes) {
      for (final c in (n['children'] as List?) ?? const []) {
        isChild.add(c as int);
      }
    }
    for (var i = 0; i < nodes.length; i++) {
      if (!isChild.contains(i)) visit(i, ident, 0);
    }
  }

  final n = cols.length;
  if (n == 0) {
    throw 'Tidak ada mesh segitiga yang bisa dibaca '
        '(mungkin memakai kompresi Draco/meshopt)';
  }

  // Normalisasi: pusatkan & skala ke radius 1
  var minX = double.infinity, minY = double.infinity, minZ = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity, maxZ = -double.infinity;
  for (var i = 0; i < tris.length; i += 3) {
    final x = tris[i], y = tris[i + 1], z = tris[i + 2];
    if (x < minX) minX = x;
    if (y < minY) minY = y;
    if (z < minZ) minZ = z;
    if (x > maxX) maxX = x;
    if (y > maxY) maxY = y;
    if (z > maxZ) maxZ = z;
  }
  final cx = (minX + maxX) / 2, cy = (minY + maxY) / 2, cz = (minZ + maxZ) / 2;
  var radius = 0.0;
  for (var i = 0; i < tris.length; i += 3) {
    final dx = tris[i] - cx, dy = tris[i + 1] - cy, dz = tris[i + 2] - cz;
    final d = math.sqrt(dx * dx + dy * dy + dz * dz);
    if (d > radius) radius = d;
  }
  if (radius <= 0) radius = 1;
  final sc = 1.0 / radius;

  final stride = n > _kMaxTris ? (n / _kMaxTris).ceil() : 1;
  final outN = (n + stride - 1) ~/ stride;
  final pos = Float32List(outN * 9);
  final rgb = Int32List(outN);
  final dbl = Uint8List(outN);
  var o = 0;
  for (var i = 0; i < n; i += stride) {
    for (var k = 0; k < 9; k += 3) {
      pos[o * 9 + k] = (tris[i * 9 + k] - cx) * sc;
      pos[o * 9 + k + 1] = (tris[i * 9 + k + 1] - cy) * sc;
      pos[o * 9 + k + 2] = (tris[i * 9 + k + 2] - cz) * sc;
    }
    rgb[o] = cols[i];
    dbl[o] = dbls[i];
    o++;
  }
  return GlbMesh(pos, rgb, dbl, outN, stride > 1);
}

// =========================================================
// WIDGET
// =========================================================
class Model3DNativeView extends StatefulWidget {
  final AppPalette palette;
  final Telemetry? data;
  final String assetPath;

  const Model3DNativeView({
    super.key,
    required this.palette,
    required this.data,
    this.assetPath = 'assets/models/payload.glb',
  });

  @override
  State<Model3DNativeView> createState() => _Model3DNativeViewState();
}

class _Model3DNativeViewState extends State<Model3DNativeView>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  GlbMesh? _mesh;
  String? _error;

  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  List<double> _from = [0, 0, 0];
  List<double> _to = [0, 0, 0];
  int _lastPacket = -1;

  double _theta = 0.6; // azimuth kamera
  double _phi = 0.35; // elevasi kamera
  double _zoom = 1.0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    final t = widget.data;
    if (t != null) {
      _from = [t.roll, t.pitch, t.yaw];
      _to = List.of(_from);
      _lastPacket = t.packetCount;
    }
    _load();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final bd = await rootBundle.load(widget.assetPath);
      final bytes = bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
      final mesh = await compute(parseGlb, bytes);
      if (!mounted) return;
      setState(() => _mesh = mesh);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Gagal memuat ${widget.assetPath}\n$e');
    }
  }

  List<double> _cur() {
    final t = Curves.easeOut.transform(_anim.value);
    return [
      for (var i = 0; i < 3; i++) _from[i] + (_to[i] - _from[i]) * t,
    ];
  }

  double _shortest(double from, double to) {
    var d = (to - from) % 360;
    if (d > 180) d -= 360;
    return d;
  }

  @override
  void didUpdateWidget(covariant Model3DNativeView old) {
    super.didUpdateWidget(old);
    final t = widget.data;
    if (t == null || t.packetCount == _lastPacket) return;
    _lastPacket = t.packetCount;
    final cur = _cur();
    _from = cur;
    _to = [
      t.roll,
      t.pitch,
      cur[2] + _shortest(cur[2], t.yaw), // yaw lewat jalur terpendek
    ];
    _anim.forward(from: 0);
  }

  void _zoomBy(double f) =>
      setState(() => _zoom = (_zoom * f).clamp(0.4, 3.0).toDouble());

  void _resetView() => setState(() {
        _theta = 0.6;
        _phi = 0.35;
        _zoom = 1.0;
      });

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final p = widget.palette;
    return Container(
      decoration: BoxDecoration(
        color: p.panel,
        border: Border.all(color: p.border),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.hardEdge,
      child: Stack(
        children: [
          Positioned.fill(child: _buildBody(p)),
          Positioned(left: 12, bottom: 12, child: _attitudeBadge(p)),
          Positioned(right: 12, bottom: 12, child: _zoomControls(p)),
          if (_mesh?.simplified == true)
            Positioned(
              left: 12,
              top: 10,
              child: Text('model disederhanakan',
                  style: TextStyle(color: p.textDim, fontSize: 10)),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(AppPalette p) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(_error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: p.bad, fontSize: 12)),
        ),
      );
    }
    final mesh = _mesh;
    if (mesh == null) return const Center(child: CircularProgressIndicator());

    return Listener(
      onPointerSignal: (e) {
        if (e is PointerScrollEvent) _zoomBy(e.scrollDelta.dy > 0 ? 1.1 : 0.9);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (d) => setState(() {
          _theta += d.delta.dx * 0.01;
          _phi = (_phi + d.delta.dy * 0.01).clamp(-1.4, 1.4).toDouble();
        }),
        child: RepaintBoundary(
          child: AnimatedBuilder(
            animation: _anim,
            builder: (_, __) {
              final a = _cur();
              return CustomPaint(
                size: Size.infinite,
                painter: _ModelPainter(
                  mesh: mesh,
                  roll: a[0],
                  pitch: a[1],
                  yaw: a[2],
                  theta: _theta,
                  phi: _phi,
                  zoom: _zoom,
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _zoomControls(AppPalette p) {
    Widget btn(IconData icon, String tip, VoidCallback onTap) {
      return Tooltip(
        message: tip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: p.panelAlt.withOpacity(0.92),
              border: Border.all(color: p.border),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 18, color: p.text),
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        btn(Icons.add, 'Zoom in', () => _zoomBy(0.8)),
        const SizedBox(height: 6),
        btn(Icons.remove, 'Zoom out', () => _zoomBy(1.25)),
        const SizedBox(height: 6),
        btn(Icons.center_focus_strong, 'Reset view', _resetView),
      ],
    );
  }

  Widget _attitudeBadge(AppPalette p) {
    final t = widget.data;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: p.panelAlt.withOpacity(0.92),
        border: Border.all(color: p.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        t == null
            ? 'Waiting for data...'
            : 'R ${t.roll.toStringAsFixed(1)}°  '
                'P ${t.pitch.toStringAsFixed(1)}°  '
                'Y ${t.yaw.toStringAsFixed(1)}°',
        style: TextStyle(
          color: p.text,
          fontSize: 11,
          fontFamily: 'monospace',
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// =========================================================
// PAINTER (software transform + painter's algorithm + drawVertices)
// =========================================================
class _ModelPainter extends CustomPainter {
  final GlbMesh mesh;
  final double roll, pitch, yaw, theta, phi, zoom;

  _ModelPainter({
    required this.mesh,
    required this.roll,
    required this.pitch,
    required this.yaw,
    required this.theta,
    required this.phi,
    required this.zoom,
  });

  static List<double> _mul3(List<double> a, List<double> b) => [
        a[0] * b[0] + a[1] * b[3] + a[2] * b[6],
        a[0] * b[1] + a[1] * b[4] + a[2] * b[7],
        a[0] * b[2] + a[1] * b[5] + a[2] * b[8],
        a[3] * b[0] + a[4] * b[3] + a[5] * b[6],
        a[3] * b[1] + a[4] * b[4] + a[5] * b[7],
        a[3] * b[2] + a[4] * b[5] + a[5] * b[8],
        a[6] * b[0] + a[7] * b[3] + a[8] * b[6],
        a[6] * b[1] + a[7] * b[4] + a[8] * b[7],
        a[6] * b[2] + a[7] * b[5] + a[8] * b[8],
      ];

  static List<double> _rx(double a) {
    final c = math.cos(a), s = math.sin(a);
    return [1, 0, 0, 0, c, -s, 0, s, c];
  }

  static List<double> _ry(double a) {
    final c = math.cos(a), s = math.sin(a);
    return [c, 0, s, 0, 1, 0, -s, 0, c];
  }

  static List<double> _rz(double a) {
    final c = math.cos(a), s = math.sin(a);
    return [c, -s, 0, s, c, 0, 0, 0, 1];
  }

  @override
  void paint(Canvas canvas, Size size) {
    const deg = math.pi / 180;
    // Rotasi attitude (roll=X, pitch=Y, yaw=Z) lalu rotasi kamera (orbit)
    final ra = _mul3(_rz(yaw * deg), _mul3(_ry(pitch * deg), _rx(roll * deg)));
    final rv = _mul3(_rx(phi), _ry(theta));
    final r = _mul3(rv, ra);

    final n = mesh.count;
    final src = mesh.pos;
    final camDist = 3.0 * zoom;
    final f = size.shortestSide * 0.42 * 3.0;
    final cx = size.width / 2, cy = size.height / 2;

    // arah cahaya (ruang kamera)
    const lx = 0.35, ly = 0.55, lz = 0.75;
    final ll = math.sqrt(lx * lx + ly * ly + lz * lz);

    final scr = Float64List(n * 6);
    final depth = Float64List(n);
    final shade = Float64List(n);
    final vis = <int>[];

    for (var i = 0; i < n; i++) {
      final j = i * 9;
      final px = List<double>.filled(3, 0), py = List<double>.filled(3, 0);
      final pz = List<double>.filled(3, 0);
      for (var v = 0; v < 3; v++) {
        final x = src[j + v * 3],
            y = src[j + v * 3 + 1],
            z = src[j + v * 3 + 2];
        px[v] = r[0] * x + r[1] * y + r[2] * z;
        py[v] = r[3] * x + r[4] * y + r[5] * z;
        pz[v] = r[6] * x + r[7] * y + r[8] * z;
      }

      // normal bidang
      final ux = px[1] - px[0], uy = py[1] - py[0], uz = pz[1] - pz[0];
      final wx = px[2] - px[0], wy = py[2] - py[0], wz = pz[2] - pz[0];
      var nx = uy * wz - uz * wy;
      var ny = uz * wx - ux * wz;
      var nz = ux * wy - uy * wx;
      final nl = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (nl < 1e-12) continue;
      nx /= nl;
      ny /= nl;
      nz /= nl;

      final dbl = mesh.dbl[i] == 1;
      if (!dbl && nz <= 0) continue; // backface culling

      final d0 = camDist - pz[0], d1 = camDist - pz[1], d2 = camDist - pz[2];
      if (d0 < 0.15 || d1 < 0.15 || d2 < 0.15) continue;

      scr[i * 6] = cx + f * px[0] / d0;
      scr[i * 6 + 1] = cy - f * py[0] / d0;
      scr[i * 6 + 2] = cx + f * px[1] / d1;
      scr[i * 6 + 3] = cy - f * py[1] / d1;
      scr[i * 6 + 4] = cx + f * px[2] / d2;
      scr[i * 6 + 5] = cy - f * py[2] / d2;

      depth[i] = (pz[0] + pz[1] + pz[2]) / 3;
      var dot = (nx * lx + ny * ly + nz * lz) / ll;
      if (dbl) dot = dot.abs();
      shade[i] = 0.30 + 0.70 * math.max(0.0, dot);
      vis.add(i);
    }

    // jauh -> dekat
    vis.sort((a, b) => depth[a].compareTo(depth[b]));

    final positions = Float32List(vis.length * 6);
    final colors = Int32List(vis.length * 3);
    for (var k = 0; k < vis.length; k++) {
      final i = vis[k];
      for (var q = 0; q < 6; q++) {
        positions[k * 6 + q] = scr[i * 6 + q];
      }
      final base = mesh.rgb[i];
      final s = shade[i];
      final rr = (((base >> 16) & 0xFF) * s).round().clamp(0, 255).toInt();
      final gg = (((base >> 8) & 0xFF) * s).round().clamp(0, 255).toInt();
      final bb = ((base & 0xFF) * s).round().clamp(0, 255).toInt();
      final c = 0xFF000000 | (rr << 16) | (gg << 8) | bb;
      colors[k * 3] = c;
      colors[k * 3 + 1] = c;
      colors[k * 3 + 2] = c;
    }

    if (vis.isEmpty) return;
    final vertices = ui.Vertices.raw(
      ui.VertexMode.triangles,
      positions,
      colors: colors,
    );
    canvas.drawVertices(vertices, BlendMode.srcOver, Paint());
  }

  @override
  bool shouldRepaint(covariant _ModelPainter old) => true;
}

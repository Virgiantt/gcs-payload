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
// PENGATURAN KUALITAS — ubah di sini
// =========================================================
/// Batas jumlah segitiga setelah penyederhanaan. Makin besar makin detail
/// tapi makin berat. Raspberry Pi 4: 15000-30000 masih wajar.
const int _kMaxTris = 25000;

/// Sudut (derajat) di atas mana permukaan dianggap "tajam" (siku/tepi) dan
/// TIDAK dihaluskan shading-nya. Lebih kecil = lebih banyak tepi tajam.
const double _kCreaseDeg = 50;

/// Jumlah "keranjang" kedalaman untuk pengurutan segitiga (jauh -> dekat).
const int _kBuckets = 2048;

// =========================================================
// GLB PARSER (top-level supaya bisa dijalankan lewat compute/isolate)
// Mendukung: mesh triangles, hierarki node (matrix / TRS), warna material.
// Tidak mendukung: tekstur, Draco/meshopt, skinning, animasi.
//
// Hasil akhir berupa mesh BER-INDEKS yang sudah disederhanakan dengan
// vertex clustering (BUKAN membuang segitiga acak) + normal per sudut.
// =========================================================
class GlbMesh {
  final Float32List vpos; // 3 float per vertex (sudah dinormalisasi, radius 1)
  final Int32List tri; // 3 index vertex per segitiga
  final Float32List nrm; // 9 float per segitiga (normal tiap sudut)
  final Int32List rgb; // 0xRRGGBB per segitiga
  final Uint8List dbl; // 1 = doubleSided
  final int vertCount;
  final int triCount;
  final int origTris; // jumlah segitiga asli sebelum disederhanakan

  GlbMesh(this.vpos, this.tri, this.nrm, this.rgb, this.dbl, this.vertCount,
      this.triCount, this.origTris);

  bool get simplified => origTris > _kMaxTris;
}

class _Welded {
  final Float32List vpos;
  final Int32List tri;
  final Int32List rgb;
  final Uint8List dbl;
  final int vertCount;
  final int triCount;
  _Welded(
      this.vpos, this.tri, this.rgb, this.dbl, this.vertCount, this.triCount);
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

  // Normalisasi: pusatkan & skala ke radius 1 (diubah langsung di tempat)
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
  for (var i = 0; i < tris.length; i += 3) {
    tris[i] = (tris[i] - cx) * sc;
    tris[i + 1] = (tris[i + 1] - cy) * sc;
    tris[i + 2] = (tris[i + 2] - cz) * sc;
  }

  // Penyederhanaan yang BENAR (vertex clustering), bukan membuang segitiga
  // acak. Kalau model sudah ringan, cukup digabung (weld) titik kembarnya.
  final w = n > _kMaxTris
      ? _simplify(tris, cols, dbls, n)
      : _cluster(tris, cols, dbls, n, 2048);
  if (w.triCount == 0) throw 'Mesh kosong setelah penyederhanaan';

  final nrm = _cornerNormals(w.vpos, w.tri, w.triCount, w.vertCount);
  return GlbMesh(w.vpos, w.tri, nrm, w.rgb, w.dbl, w.vertCount, w.triCount, n);
}

/// Gabungkan semua titik yang jatuh di sel grid yang sama menjadi satu titik
/// (posisi rata-rata). Segitiga yang jadi "kolaps" dibuang. Permukaan tetap
/// utuh (tidak berlubang) karena yang berkurang adalah titiknya.
_Welded _cluster(
    List<double> tris, List<int> cols, List<int> dbls, int n, int grid) {
  final inv = grid / 2.0; // koordinat [-1, 1] -> [0, grid)
  final maxCell = grid - 1;
  final ids = <int, int>{};
  final sx = <double>[], sy = <double>[], sz = <double>[];
  final cn = <int>[];
  final outTri = <int>[];
  final outCol = <int>[];
  final outDbl = <int>[];

  int cell(double v) {
    final c = ((v + 1.0) * inv).floor();
    return c < 0 ? 0 : (c > maxCell ? maxCell : c);
  }

  int vid(double x, double y, double z) {
    final key = (cell(x) * grid + cell(y)) * grid + cell(z);
    final existing = ids[key];
    final int id;
    if (existing == null) {
      id = sx.length;
      ids[key] = id;
      sx.add(0);
      sy.add(0);
      sz.add(0);
      cn.add(0);
    } else {
      id = existing;
    }
    sx[id] += x;
    sy[id] += y;
    sz[id] += z;
    cn[id]++;
    return id;
  }

  for (var i = 0; i < n; i++) {
    final j = i * 9;
    final a = vid(tris[j], tris[j + 1], tris[j + 2]);
    final b = vid(tris[j + 3], tris[j + 4], tris[j + 5]);
    final c = vid(tris[j + 6], tris[j + 7], tris[j + 8]);
    if (a == b || b == c || a == c) continue; // segitiga kolaps
    outTri
      ..add(a)
      ..add(b)
      ..add(c);
    outCol.add(cols[i]);
    outDbl.add(dbls[i]);
  }

  final vc = sx.length;
  final vpos = Float32List(vc * 3);
  for (var v = 0; v < vc; v++) {
    final k = cn[v];
    vpos[v * 3] = sx[v] / k;
    vpos[v * 3 + 1] = sy[v] / k;
    vpos[v * 3 + 2] = sz[v] / k;
  }
  return _Welded(
    vpos,
    Int32List.fromList(outTri),
    Int32List.fromList(outCol),
    Uint8List.fromList(outDbl),
    vc,
    outCol.length,
  );
}

/// Cari ukuran grid yang menghasilkan <= _kMaxTris segitiga.
_Welded _simplify(List<double> tris, List<int> cols, List<int> dbls, int n) {
  var grid = 1024;
  var w = _cluster(tris, cols, dbls, n, grid);
  var guard = 0;
  while (w.triCount > _kMaxTris && grid > 8 && guard++ < 8) {
    // jumlah segitiga kira-kira sebanding dengan grid^2
    grid =
        math.max(8, (grid * math.sqrt(_kMaxTris / w.triCount) * 0.95).floor());
    w = _cluster(tris, cols, dbls, n, grid);
  }
  return w;
}

/// Normal per SUDUT segitiga. Normal dirata-ratakan (dibobot luas) dengan
/// segitiga tetangga hanya kalau sudutnya landai (< _kCreaseDeg), jadi
/// permukaan melengkung terlihat halus tapi tepi siku tetap tajam.
Float32List _cornerNormals(Float32List vpos, Int32List tri, int tc, int vc) {
  final fx = Float64List(tc), fy = Float64List(tc), fz = Float64List(tc);
  final ux = Float64List(tc), uy = Float64List(tc), uz = Float64List(tc);

  for (var t = 0; t < tc; t++) {
    final a = tri[t * 3] * 3, b = tri[t * 3 + 1] * 3, c = tri[t * 3 + 2] * 3;
    final e1x = vpos[b] - vpos[a];
    final e1y = vpos[b + 1] - vpos[a + 1];
    final e1z = vpos[b + 2] - vpos[a + 2];
    final e2x = vpos[c] - vpos[a];
    final e2y = vpos[c + 1] - vpos[a + 1];
    final e2z = vpos[c + 2] - vpos[a + 2];
    final nx = e1y * e2z - e1z * e2y;
    final ny = e1z * e2x - e1x * e2z;
    final nz = e1x * e2y - e1y * e2x;
    fx[t] = nx;
    fy[t] = ny;
    fz[t] = nz;
    final l = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (l > 1e-20) {
      ux[t] = nx / l;
      uy[t] = ny / l;
      uz[t] = nz / l;
    } else {
      ux[t] = 0;
      uy[t] = 0;
      uz[t] = 1;
    }
  }

  // daftar segitiga yang memakai tiap vertex
  final start = Int32List(vc + 1);
  for (var k = 0; k < tc * 3; k++) {
    start[tri[k] + 1]++;
  }
  for (var v = 0; v < vc; v++) {
    start[v + 1] += start[v];
  }
  final fill = Int32List.fromList(start);
  final list = Int32List(tc * 3);
  for (var t = 0; t < tc; t++) {
    for (var k = 0; k < 3; k++) {
      final v = tri[t * 3 + k];
      list[fill[v]++] = t;
    }
  }

  final cosC = math.cos(_kCreaseDeg * math.pi / 180);
  final out = Float32List(tc * 9);
  for (var t = 0; t < tc; t++) {
    for (var k = 0; k < 3; k++) {
      final v = tri[t * 3 + k];
      var ax = 0.0, ay = 0.0, az = 0.0;
      for (var i = start[v]; i < start[v + 1]; i++) {
        final u = list[i];
        final d = ux[u] * ux[t] + uy[u] * uy[t] + uz[u] * uz[t];
        if (d >= cosC) {
          ax += fx[u];
          ay += fy[u];
          az += fz[u];
        }
      }
      var l = math.sqrt(ax * ax + ay * ay + az * az);
      if (l < 1e-20) {
        ax = ux[t];
        ay = uy[t];
        az = uz[t];
        l = 1;
      }
      final o = t * 9 + k * 3;
      out[o] = ax / l;
      out[o + 1] = ay / l;
      out[o + 2] = az / l;
    }
  }
  return out;
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
  _Scratch? _scratch;
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
      setState(() {
        _mesh = mesh;
        _scratch = _Scratch(mesh);
      });
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
    // NaN (sensor error) jangan sampai merusak animasi
    if (!t.roll.isFinite || !t.pitch.isFinite || !t.yaw.isFinite) return;
    final cur = _cur();
    _from = cur;
    _to = [
      t.roll,
      t.pitch,
      cur[2] + _shortest(cur[2], t.yaw),
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
    final scratch = _scratch;
    if (mesh == null || scratch == null) {
      return const Center(child: CircularProgressIndicator());
    }

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
                  scratch: scratch,
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
// BUFFER KERJA (dipakai ulang tiap frame supaya tidak banyak alokasi)
// =========================================================
class _Scratch {
  final Float64List sx;
  final Float64List sy;
  final Float64List vz;
  final Uint8List ok;
  final Int32List bucketOf;
  final Int32List counts;
  final Int32List order;

  _Scratch(GlbMesh m)
      : sx = Float64List(m.vertCount),
        sy = Float64List(m.vertCount),
        vz = Float64List(m.vertCount),
        ok = Uint8List(m.vertCount),
        bucketOf = Int32List(m.triCount),
        counts = Int32List(_kBuckets * 2 + 1),
        order = Int32List(m.triCount);
}

List<double> _unit(double x, double y, double z) {
  final l = math.sqrt(x * x + y * y + z * z);
  return [x / l, y / l, z / l];
}

// Dua sumber cahaya (ruang kamera): utama + pengisi
final List<double> _kLightKey = _unit(0.35, 0.55, 0.75);
final List<double> _kLightFill = _unit(-0.6, -0.2, 0.5);

// =========================================================
// PAINTER
//  1. transformasi tiap VERTEX sekali (bukan tiap segitiga)
//  2. buang sisi belakang; sisi belakang material doubleSided digambar
//     LEBIH DULU, sisi depan sesudahnya (tidak menimpa sisi depan)
//  3. urutkan jauh -> dekat dengan bucket sort (tanpa comparator)
//  4. shading halus per sudut (2 lampu + ambient) -> drawVertices
// =========================================================
class _ModelPainter extends CustomPainter {
  final GlbMesh mesh;
  final _Scratch scratch;
  final double roll, pitch, yaw, theta, phi, zoom;

  _ModelPainter({
    required this.mesh,
    required this.scratch,
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
    final r0 = r[0], r1 = r[1], r2 = r[2];
    final r3 = r[3], r4 = r[4], r5 = r[5];
    final r6 = r[6], r7 = r[7], r8 = r[8];

    final m = mesh;
    final s = scratch;
    final vc = m.vertCount;
    final tc = m.triCount;
    final vp = m.vpos;
    final tri = m.tri;
    final dbl = m.dbl;

    final camDist = 3.0 * zoom;
    final f = size.shortestSide * 0.42 * 3.0;
    final cx = size.width / 2, cy = size.height / 2;

    // ---- 1) transformasi + proyeksi tiap vertex ----
    final sx = s.sx, sy = s.sy, vz = s.vz, ok = s.ok;
    for (var v = 0; v < vc; v++) {
      final x = vp[v * 3], y = vp[v * 3 + 1], z = vp[v * 3 + 2];
      final px = r0 * x + r1 * y + r2 * z;
      final py = r3 * x + r4 * y + r5 * z;
      final pz = r6 * x + r7 * y + r8 * z;
      final d = camDist - pz;
      if (d < 0.15) {
        ok[v] = 0;
        continue;
      }
      ok[v] = 1;
      sx[v] = cx + f * px / d;
      sy[v] = cy - f * py / d;
      vz[v] = pz;
    }

    // ---- 2) tentukan sisi depan/belakang + keranjang kedalaman ----
    const bk = _kBuckets;
    const zScale = (bk - 1) / 2.2;
    final counts = s.counts;
    counts.fillRange(0, counts.length, 0);
    final bucketOf = s.bucketOf;
    var visN = 0;

    for (var t = 0; t < tc; t++) {
      final a = tri[t * 3], b = tri[t * 3 + 1], c = tri[t * 3 + 2];
      if (ok[a] == 0 || ok[b] == 0 || ok[c] == 0) {
        bucketOf[t] = -1;
        continue;
      }
      // luas bertanda di layar (sumbu y layar terbalik -> depan = negatif)
      final area =
          (sx[b] - sx[a]) * (sy[c] - sy[a]) - (sx[c] - sx[a]) * (sy[b] - sy[a]);
      final front = area < 0;
      if ((!front && dbl[t] == 0) || area.abs() < 0.02) {
        bucketOf[t] = -1;
        continue;
      }
      final depth = (vz[a] + vz[b] + vz[c]) / 3;
      var q = ((depth + 1.1) * zScale).floor();
      if (q < 0) {
        q = 0;
      } else if (q >= bk) {
        q = bk - 1;
      }
      final bucket = front ? bk + q : q;
      bucketOf[t] = bucket;
      counts[bucket + 1]++;
      visN++;
    }
    if (visN == 0) return;

    // ---- 3) counting sort: jauh -> dekat (sisi belakang dulu) ----
    for (var i = 0; i < counts.length - 1; i++) {
      counts[i + 1] += counts[i];
    }
    final order = s.order;
    for (var t = 0; t < tc; t++) {
      final bucket = bucketOf[t];
      if (bucket < 0) continue;
      order[counts[bucket]++] = t;
    }

    // ---- 4) shading per sudut + susun data untuk drawVertices ----
    final nrm = m.nrm;
    final rgb = m.rgb;
    final k1x = _kLightKey[0], k1y = _kLightKey[1], k1z = _kLightKey[2];
    final k2x = _kLightFill[0], k2y = _kLightFill[1], k2z = _kLightFill[2];

    final positions = Float32List(visN * 6);
    final colors = Int32List(visN * 3);

    for (var k = 0; k < visN; k++) {
      final t = order[k];
      final base = rgb[t];
      final br = (base >> 16) & 0xFF;
      final bg = (base >> 8) & 0xFF;
      final bb = base & 0xFF;
      final front = bucketOf[t] >= bk;

      for (var c = 0; c < 3; c++) {
        final vi = tri[t * 3 + c];
        positions[k * 6 + c * 2] = sx[vi];
        positions[k * 6 + c * 2 + 1] = sy[vi];

        final o = t * 9 + c * 3;
        final wx = nrm[o], wy = nrm[o + 1], wz = nrm[o + 2];
        var nx = r0 * wx + r1 * wy + r2 * wz;
        var ny = r3 * wx + r4 * wy + r5 * wz;
        var nz = r6 * wx + r7 * wy + r8 * wz;
        if (!front) {
          nx = -nx;
          ny = -ny;
          nz = -nz;
        }
        final d1 = nx * k1x + ny * k1y + nz * k1z;
        final d2 = nx * k2x + ny * k2y + nz * k2z;
        var it = 0.30 + 0.62 * (d1 > 0 ? d1 : 0) + 0.22 * (d2 > 0 ? d2 : 0);
        if (it > 1.15) it = 1.15;

        final rr = (br * it).round().clamp(0, 255).toInt();
        final gg = (bg * it).round().clamp(0, 255).toInt();
        final b2 = (bb * it).round().clamp(0, 255).toInt();
        colors[k * 3 + c] = 0xFF000000 | (rr << 16) | (gg << 8) | b2;
      }
    }

    final vertices = ui.Vertices.raw(
      ui.VertexMode.triangles,
      positions,
      colors: colors,
    );
    canvas.drawVertices(
      vertices,
      BlendMode.srcOver,
      Paint()..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(covariant _ModelPainter old) => true;
}

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Vektor 3D. Di peta dipakai frame ENU: x timur, y utara, z atas (meter).
class V3 {
  const V3(this.x, this.y, this.z);
  final double x, y, z;

  static const V3 zero = V3(0, 0, 0);

  V3 operator +(V3 o) => V3(x + o.x, y + o.y, z + o.z);
  V3 operator -(V3 o) => V3(x - o.x, y - o.y, z - o.z);
  V3 operator *(double s) => V3(x * s, y * s, z * s);
  double dot(V3 o) => x * o.x + y * o.y + z * o.z;
  V3 cross(V3 o) =>
      V3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);
  double get length => math.sqrt(x * x + y * y + z * z);
  V3 normalized() {
    final l = length;
    return l < 1e-12 ? this : V3(x / l, y / l, z / l);
  }
}

/// Matriks rotasi 3x3, row-major.
class M3 {
  M3(this.m);
  final Float64List m;

  factory M3.identity() =>
      M3(Float64List.fromList([1, 0, 0, 0, 1, 0, 0, 0, 1]));

  factory M3.rotX(double rad) {
    final c = math.cos(rad), s = math.sin(rad);
    return M3(Float64List.fromList([1, 0, 0, 0, c, -s, 0, s, c]));
  }

  factory M3.rotY(double rad) {
    final c = math.cos(rad), s = math.sin(rad);
    return M3(Float64List.fromList([c, 0, s, 0, 1, 0, -s, 0, c]));
  }

  factory M3.rotZ(double rad) {
    final c = math.cos(rad), s = math.sin(rad);
    return M3(Float64List.fromList([c, -s, 0, s, c, 0, 0, 0, 1]));
  }

  M3 operator *(M3 o) {
    final a = m, b = o.m;
    final r = Float64List(9);
    for (var i = 0; i < 3; i++) {
      for (var j = 0; j < 3; j++) {
        r[i * 3 + j] = a[i * 3] * b[j] +
            a[i * 3 + 1] * b[3 + j] +
            a[i * 3 + 2] * b[6 + j];
      }
    }
    return M3(r);
  }
}

/// Mesh segitiga siap gambar.
/// Koordinat masih frame glTF (Y atas), pusat di 0, sisi terpanjang = 1.
class MeshData {
  MeshData(this.positions, this.indices, this.colors, {this.fromGlb = true});

  final Float32List positions;
  final Uint32List indices;

  /// Warna ARGB per segitiga. Nilai 0 berarti pakai warna aksen tema.
  final Int32List colors;
  final bool fromGlb;

  int get vertexCount => positions.length ~/ 3;
  int get triangleCount => indices.length ~/ 3;

  static final Map<String, Future<MeshData>> _cache = {};

  /// Memuat GLB dari asset. Parsing jalan di isolate terpisah supaya UI
  /// tidak macet. Kalau gagal, dipakai model tabung CanSat bawaan.
  static Future<MeshData> load(
    String asset, {
    int maxTriangles = 3000,
    bool alignLongAxis = true,
  }) {
    return _cache.putIfAbsent('$asset|$maxTriangles|$alignLongAxis', () async {
      try {
        final data = await rootBundle.load(asset);
        final bytes =
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
        final mesh = await compute(
            _parseGlbEntry, (bytes, maxTriangles, alignLongAxis));
        if (mesh != null) {
          debugPrint('[3D] $asset dimuat: ${mesh.triangleCount} segitiga');
          return mesh;
        }
        debugPrint('[3D] $asset tidak terbaca, memakai model CanSat bawaan');
      } catch (e) {
        debugPrint('[3D] Gagal memuat $asset: $e');
      }
      return MeshData.cansat();
    });
  }

  /// Model cadangan: tabung CanSat sederhana.
  factory MeshData.cansat() {
    const seg = 20;
    const r = 0.21, h = 0.5;
    const body = 0xFFD9DEE5, bottom = 0xFF6B7280, top = 0;
    final pos = <double>[];
    final idx = <int>[];
    final col = <int>[];
    for (var i = 0; i < seg; i++) {
      final a = 2 * math.pi * i / seg;
      pos.addAll([r * math.cos(a), -h, r * math.sin(a)]);
      pos.addAll([r * math.cos(a), h, r * math.sin(a)]);
    }
    final cb = pos.length ~/ 3;
    pos.addAll([0, -h, 0]);
    final ct = cb + 1;
    pos.addAll([0, h, 0]);
    for (var i = 0; i < seg; i++) {
      final j = (i + 1) % seg;
      final b0 = i * 2, t0 = i * 2 + 1, b1 = j * 2, t1 = j * 2 + 1;
      idx.addAll([b0, b1, t1, b0, t1, t0]);
      col.addAll([body, body]);
      idx.addAll([cb, b1, b0]);
      col.add(bottom);
      idx.addAll([ct, t0, t1]);
      col.add(top);
    }
    return MeshData(
      Float32List.fromList(pos),
      Uint32List.fromList(idx),
      Int32List.fromList(col),
      fromGlb: false,
    );
  }
}

// =========================================================
// PARSER GLB (glTF 2.0 biner)
// =========================================================

MeshData? _parseGlbEntry((Uint8List, int, bool) args) {
  final raw = _GlbReader(args.$1).read();
  if (raw == null || raw.idx.isEmpty) return null;
  return _buildMesh(raw, args.$2, args.$3);
}

class _RawMesh {
  final List<double> pos = [];
  final List<int> idx = [];
  final List<int> col = [];
}

class _GlbReader {
  _GlbReader(this.bytes);
  final Uint8List bytes;
  Map<String, dynamic> j = const {};
  ByteData? bin;

  _RawMesh? read() {
    if (bytes.length < 20) return null;
    final bd = ByteData.sublistView(bytes);
    if (bd.getUint32(0, Endian.little) != 0x46546C67) return null; // 'glTF'

    Map<String, dynamic>? json;
    var off = 12;
    while (off + 8 <= bytes.length) {
      final len = bd.getUint32(off, Endian.little);
      final type = bd.getUint32(off + 4, Endian.little);
      final s = off + 8;
      if (s + len > bytes.length) break;
      if (type == 0x4E4F534A) {
        json = jsonDecode(utf8.decode(Uint8List.sublistView(bytes, s, s + len)))
            as Map<String, dynamic>;
      } else if (type == 0x004E4942) {
        bin = ByteData.sublistView(bytes, s, s + len);
      }
      off = s + len;
    }
    if (json == null || bin == null) return null;
    j = json;

    final req = ((j['extensionsRequired'] as List?) ?? const [])
        .map((e) => e.toString().toLowerCase());
    if (req.any((e) => e.contains('draco') || e.contains('meshopt'))) {
      debugPrint('[3D] GLB memakai kompresi Draco/meshopt. '
          'Ekspor ulang tanpa kompresi.');
      return null;
    }

    final out = _RawMesh();
    final nodes = (j['nodes'] as List?) ?? const [];
    final scenes = (j['scenes'] as List?) ?? const [];
    final si = (j['scene'] as num?)?.toInt() ?? 0;

    if (scenes.isNotEmpty && si < scenes.length) {
      for (final n in ((scenes[si] as Map)['nodes'] as List?) ?? const []) {
        _visit((n as num).toInt(), _ident4(), out, 0);
      }
    } else if (nodes.isNotEmpty) {
      final children = <int>{};
      for (final n in nodes) {
        for (final c in ((n as Map)['children'] as List?) ?? const []) {
          children.add((c as num).toInt());
        }
      }
      for (var i = 0; i < nodes.length; i++) {
        if (!children.contains(i)) _visit(i, _ident4(), out, 0);
      }
    } else {
      final meshes = (j['meshes'] as List?) ?? const [];
      for (var i = 0; i < meshes.length; i++) {
        _addMesh(i, _ident4(), out);
      }
    }
    return out;
  }

  void _visit(int ni, Float64List parent, _RawMesh out, int depth) {
    final nodes = (j['nodes'] as List?) ?? const [];
    if (depth > 64 || ni < 0 || ni >= nodes.length) return;
    final node = nodes[ni] as Map;
    final world = _mul4(parent, _local(node));
    final mi = node['mesh'];
    if (mi is num) _addMesh(mi.toInt(), world, out);
    for (final c in (node['children'] as List?) ?? const []) {
      _visit((c as num).toInt(), world, out, depth + 1);
    }
  }

  Float64List _local(Map node) {
    final mat = node['matrix'] as List?;
    if (mat != null && mat.length == 16) {
      return Float64List.fromList([for (final v in mat) (v as num).toDouble()]);
    }
    final t = (node['translation'] as List?) ?? const [0, 0, 0];
    final r = (node['rotation'] as List?) ?? const [0, 0, 0, 1];
    final s = (node['scale'] as List?) ?? const [1, 1, 1];
    double d(List l, int i) => (l[i] as num).toDouble();
    final qx = d(r, 0), qy = d(r, 1), qz = d(r, 2), qw = d(r, 3);
    final sx = d(s, 0), sy = d(s, 1), sz = d(s, 2);
    final m = Float64List(16);
    m[0] = (1 - 2 * (qy * qy + qz * qz)) * sx;
    m[1] = (2 * (qx * qy + qz * qw)) * sx;
    m[2] = (2 * (qx * qz - qy * qw)) * sx;
    m[4] = (2 * (qx * qy - qz * qw)) * sy;
    m[5] = (1 - 2 * (qx * qx + qz * qz)) * sy;
    m[6] = (2 * (qy * qz + qx * qw)) * sy;
    m[8] = (2 * (qx * qz + qy * qw)) * sz;
    m[9] = (2 * (qy * qz - qx * qw)) * sz;
    m[10] = (1 - 2 * (qx * qx + qy * qy)) * sz;
    m[12] = d(t, 0);
    m[13] = d(t, 1);
    m[14] = d(t, 2);
    m[15] = 1;
    return m;
  }

  void _addMesh(int mi, Float64List w, _RawMesh out) {
    final meshes = (j['meshes'] as List?) ?? const [];
    if (mi < 0 || mi >= meshes.length) return;
    for (final p in ((meshes[mi] as Map)['primitives'] as List?) ?? const []) {
      final prim = p as Map;
      final mode = (prim['mode'] as num?)?.toInt() ?? 4;
      if (mode != 4) continue; // hanya TRIANGLES

      final pa = ((prim['attributes'] as Map?)?['POSITION'] as num?)?.toInt();
      if (pa == null) continue;
      final pos = _read(pa);
      if (pos == null) continue;

      final vc = pos.length ~/ 3;
      final base = out.pos.length ~/ 3;
      for (var i = 0; i < vc; i++) {
        final x = pos[i * 3], y = pos[i * 3 + 1], z = pos[i * 3 + 2];
        out.pos
          ..add(w[0] * x + w[4] * y + w[8] * z + w[12])
          ..add(w[1] * x + w[5] * y + w[9] * z + w[13])
          ..add(w[2] * x + w[6] * y + w[10] * z + w[14]);
      }

      final ia = (prim['indices'] as num?)?.toInt();
      final ind = ia == null ? null : _read(ia);
      final color = _color(prim['material']);
      final n = ind == null ? vc : ind.length;
      for (var t = 0; t + 2 < n; t += 3) {
        final a = ind == null ? t : ind[t].toInt();
        final b = ind == null ? t + 1 : ind[t + 1].toInt();
        final c = ind == null ? t + 2 : ind[t + 2].toInt();
        if (a >= vc || b >= vc || c >= vc) continue;
        out.idx
          ..add(base + a)
          ..add(base + b)
          ..add(base + c);
        out.col.add(color);
      }
    }
  }

  List<double>? _read(int ai) {
    final accs = (j['accessors'] as List?) ?? const [];
    if (ai < 0 || ai >= accs.length) return null;
    final acc = accs[ai] as Map;
    final count = (acc['count'] as num).toInt();
    final comps = const {
          'SCALAR': 1,
          'VEC2': 2,
          'VEC3': 3,
          'VEC4': 4,
          'MAT4': 16,
        }[acc['type']] ??
        1;
    final ct = (acc['componentType'] as num).toInt();
    final out = List<double>.filled(count * comps, 0.0);

    final bvi = (acc['bufferView'] as num?)?.toInt();
    if (bvi == null) return out;
    final bv = (j['bufferViews'] as List)[bvi] as Map;
    if (((bv['buffer'] as num?)?.toInt() ?? 0) != 0) return null;

    final size = switch (ct) {
      5120 || 5121 => 1,
      5122 || 5123 => 2,
      _ => 4,
    };
    final stride = (bv['byteStride'] as num?)?.toInt() ?? comps * size;
    final start = ((bv['byteOffset'] as num?)?.toInt() ?? 0) +
        ((acc['byteOffset'] as num?)?.toInt() ?? 0);
    final b = bin!;

    for (var i = 0; i < count; i++) {
      final o = start + i * stride;
      for (var c = 0; c < comps; c++) {
        final p = o + c * size;
        if (p + size > b.lengthInBytes) return null;
        out[i * comps + c] = switch (ct) {
          5120 => b.getInt8(p).toDouble(),
          5121 => b.getUint8(p).toDouble(),
          5122 => b.getInt16(p, Endian.little).toDouble(),
          5123 => b.getUint16(p, Endian.little).toDouble(),
          5125 => b.getUint32(p, Endian.little).toDouble(),
          _ => b.getFloat32(p, Endian.little),
        };
      }
    }
    return out;
  }

  int _color(dynamic mi) {
    if (mi is! num) return 0;
    final mats = (j['materials'] as List?) ?? const [];
    final i = mi.toInt();
    if (i < 0 || i >= mats.length) return 0;
    final pbr = (mats[i] as Map)['pbrMetallicRoughness'] as Map?;
    final f = pbr?['baseColorFactor'] as List?;
    if (f == null || f.length < 3) return 0xFFD9DEE5;
    int ch(int k) {
      final lin = (f[k] as num).toDouble();
      final v = lin < 0 ? 0.0 : (lin > 1 ? 1.0 : lin);
      return (math.pow(v, 1 / 2.2) * 255).round();
    }

    return 0xFF000000 | (ch(0) << 16) | (ch(1) << 8) | ch(2);
  }
}

Float64List _ident4() {
  final m = Float64List(16);
  m[0] = 1;
  m[5] = 1;
  m[10] = 1;
  m[15] = 1;
  return m;
}

Float64List _mul4(Float64List a, Float64List b) {
  final r = Float64List(16);
  for (var c = 0; c < 4; c++) {
    for (var row = 0; row < 4; row++) {
      var s = 0.0;
      for (var k = 0; k < 4; k++) {
        s += a[k * 4 + row] * b[c * 4 + k];
      }
      r[c * 4 + row] = s;
    }
  }
  return r;
}

/// Normalisasi ukuran lalu sederhanakan mesh bila segitiganya terlalu banyak.
MeshData _buildMesh(_RawMesh r, int maxTris, bool align) {
  final vc = r.pos.length ~/ 3;
  var minX = double.infinity, minY = double.infinity, minZ = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity, maxZ = -double.infinity;
  for (var i = 0; i < vc; i++) {
    final x = r.pos[i * 3], y = r.pos[i * 3 + 1], z = r.pos[i * 3 + 2];
    if (x < minX) minX = x;
    if (y < minY) minY = y;
    if (z < minZ) minZ = z;
    if (x > maxX) maxX = x;
    if (y > maxY) maxY = y;
    if (z > maxZ) maxZ = z;
  }
  final ext = math.max(maxX - minX, math.max(maxY - minY, maxZ - minZ));
  final inv = ext > 0 ? 1 / ext : 1.0;
  final cx = (minX + maxX) / 2, cy = (minY + maxY) / 2, cz = (minZ + maxZ) / 2;

  final pos = Float32List(vc * 3);
  for (var i = 0; i < vc; i++) {
    pos[i * 3] = (r.pos[i * 3] - cx) * inv;
    pos[i * 3 + 1] = (r.pos[i * 3 + 1] - cy) * inv;
    pos[i * 3 + 2] = (r.pos[i * 3 + 2] - cz) * inv;
  }
  if (align) _alignLongAxisToY(pos);
  final idx = Uint32List.fromList(r.idx);
  final col = Int32List.fromList(r.col);
  if (idx.length ~/ 3 <= maxTris) return MeshData(pos, idx, col);
  return _cluster(pos, idx, col, maxTris);
}

/// Ekspor CAD sering membuat sumbu panjang payload di X atau Z.
/// Fungsi ini memutar mesh supaya sumbu terpanjang menjadi Y (tegak).
void _alignLongAxisToY(Float32List pos) {
  final n = pos.length ~/ 3;
  final lo = [double.infinity, double.infinity, double.infinity];
  final hi = [-double.infinity, -double.infinity, -double.infinity];
  for (var i = 0; i < n; i++) {
    for (var a = 0; a < 3; a++) {
      final v = pos[i * 3 + a];
      if (v < lo[a]) lo[a] = v;
      if (v > hi[a]) hi[a] = v;
    }
  }
  final dx = hi[0] - lo[0], dy = hi[1] - lo[1], dz = hi[2] - lo[2];
  if (dy >= dx && dy >= dz) return;
  final alongX = dx >= dz;
  for (var i = 0; i < n; i++) {
    final x = pos[i * 3], y = pos[i * 3 + 1], z = pos[i * 3 + 2];
    if (alongX) {
      // Putar +90 derajat pada Z: X menjadi Y.
      pos[i * 3] = -y;
      pos[i * 3 + 1] = x;
    } else {
      // Putar -90 derajat pada X: Z menjadi Y.
      pos[i * 3 + 1] = z;
      pos[i * 3 + 2] = -y;
    }
  }
  debugPrint('[3D] Sumbu panjang model ada di ${alongX ? 'X' : 'Z'}, '
      'diputar menjadi tegak');
}

/// Penyederhanaan vertex clustering: vertex dalam satu sel grid digabung.
MeshData _cluster(
    Float32List pos, Uint32List idx, Int32List col, int maxTris) {
  final vc = pos.length ~/ 3;
  final tc = idx.length ~/ 3;
  MeshData? best;

  for (final res in const [160, 128, 96, 72, 56, 44, 34, 26, 20, 14, 10]) {
    final cell = 1.0 / res;
    final n1 = res + 2;
    final ids = <int, int>{};
    final remap = Int32List(vc);
    final sx = <double>[], sy = <double>[], sz = <double>[];
    final cnt = <int>[];

    for (var i = 0; i < vc; i++) {
      final x = pos[i * 3], y = pos[i * 3 + 1], z = pos[i * 3 + 2];
      final ix = math.max(0, math.min(res + 1, ((x + 0.5) / cell).floor()));
      final iy = math.max(0, math.min(res + 1, ((y + 0.5) / cell).floor()));
      final iz = math.max(0, math.min(res + 1, ((z + 0.5) / cell).floor()));
      final key = (ix * n1 + iy) * n1 + iz;
      var id = ids[key];
      if (id == null) {
        id = cnt.length;
        ids[key] = id;
        sx.add(0);
        sy.add(0);
        sz.add(0);
        cnt.add(0);
      }
      sx[id] += x;
      sy[id] += y;
      sz[id] += z;
      cnt[id]++;
      remap[i] = id;
    }

    final nc = cnt.length;
    final seen = <int>{};
    final ni = <int>[];
    final nco = <int>[];
    for (var t = 0; t < tc; t++) {
      final a = remap[idx[t * 3]];
      final b = remap[idx[t * 3 + 1]];
      final c = remap[idx[t * 3 + 2]];
      if (a == b || b == c || a == c) continue;
      var lo = a, md = b, hi = c, tmp = 0;
      if (lo > md) {
        tmp = lo;
        lo = md;
        md = tmp;
      }
      if (md > hi) {
        tmp = md;
        md = hi;
        hi = tmp;
      }
      if (lo > md) {
        tmp = lo;
        lo = md;
        md = tmp;
      }
      if (!seen.add((lo * nc + md) * nc + hi)) continue;
      ni.addAll([a, b, c]);
      nco.add(col[t]);
    }

    final p = Float32List(nc * 3);
    for (var i = 0; i < nc; i++) {
      p[i * 3] = sx[i] / cnt[i];
      p[i * 3 + 1] = sy[i] / cnt[i];
      p[i * 3 + 2] = sz[i] / cnt[i];
    }
    best = MeshData(p, Uint32List.fromList(ni), Int32List.fromList(nco));
    if (ni.length ~/ 3 <= maxTris) break;
  }
  return best!;
}
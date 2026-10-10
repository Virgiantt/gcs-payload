import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../models/telemetry.dart';
import '../theme/app_theme.dart';

/// Viewer 3D untuk payload.glb.
///
/// - Model dilayani lewat server HTTP lokal (127.0.0.1) supaya tidak kena
///   batas ukuran HTML WebView2 (~2 MB).
/// - Hanya SATU WebView, dibuat sekali. Rotasi dikirim lewat JavaScript.
/// - AutomaticKeepAlive: WebView tidak di-dispose saat pindah tab.
/// - Kualitas render: supersampling (digambar lebih besar lalu dikecilkan)
///   yang menyesuaikan diri dengan DPI layar. Tombol "2x" di pojok kanan
///   bawah untuk ganti 1x / 2x / 3x tanpa rebuild.
class Model3DGlbView extends StatefulWidget {
  final AppPalette palette;
  final Telemetry? data;
  final String assetPath;

  const Model3DGlbView({
    super.key,
    required this.palette,
    required this.data,
    this.assetPath = 'assets/models/payload.glb',
  });

  @override
  State<Model3DGlbView> createState() => _Model3DGlbViewState();
}

class _Model3DGlbViewState extends State<Model3DGlbView>
    with AutomaticKeepAliveClientMixin {
  HttpServer? _server;
  InAppWebViewController? _web;
  String? _url;
  String? _error;
  bool _pageReady = false;
  int _lastPacket = -1;

  // ================= PENGATURAN TAMPILAN 3D =================
  // Pose awal kamera: "<theta> <phi> <jarak>"
  //   theta : putar kiri-kanan (0deg = tampak depan)
  //   phi   : sudut dari atas (90deg = sejajar mata, makin kecil = makin dari atas)
  static const String _initOrbit = '0deg 78deg auto';

  // Tingkat kualitas (supersampling). Dipilih lewat tombol di pojok kanan
  // bawah. Angka = model digambar N kali lebih besar lalu dikecilkan -> tepi
  // lebih halus & tidak burik. Pakai angka BULAT (1, 2, 3) supaya hasil
  // pengecilannya rata. Makin besar makin berat untuk GPU.
  static const List<double> _qLevels = [1, 2, 3];
  static const int _defaultQuality = 1; // index -> 2x
  // ==========================================================

  int _qIdx = _defaultQuality;
  double _hostDpr = 1.0; // devicePixelRatio Flutter (skala layar Windows)

  double get _ss => _qLevels[_qIdx];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _startServer();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final d = MediaQuery.of(context).devicePixelRatio;
    if (d != _hostDpr) {
      _hostDpr = d;
      _applyQuality();
    }
  }

  @override
  void dispose() {
    _server?.close(force: true);
    super.dispose();
  }

  String _hex(Color c) =>
      '#${(c.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  Future<void> _startServer() async {
    try {
      final data = await rootBundle.load(widget.assetPath);
      final glb =
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      final js = await rootBundle.load('assets/web/model-viewer.min.js');
      final jsBytes = js.buffer.asUint8List(js.offsetInBytes, js.lengthInBytes);
      final html = _buildHtml(_hex(widget.palette.panel));

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;

      server.listen((req) async {
        final res = req.response;
        res.headers.set('Access-Control-Allow-Origin', '*');
        res.headers.set('Cache-Control', 'no-store');
        if (req.uri.path == '/model-viewer.min.js') {
          res.headers.contentType = ContentType('text', 'javascript');
          res.contentLength = jsBytes.length;
          res.add(jsBytes);
        } else if (req.uri.path == '/payload.glb') {
          res.headers.contentType = ContentType('model', 'gltf-binary');
          res.contentLength = glb.length;
          res.add(glb);
        } else {
          res.headers.contentType = ContentType.html;
          res.write(html);
        }
        await res.close();
      });

      if (!mounted) return;
      setState(() => _url = 'http://127.0.0.1:${server.port}/');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Gagal memuat ${widget.assetPath}\n$e');
    }
  }

  String _buildHtml(String bg) => '''
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<script>
  // Dibaca model-viewer saat dimuat: matikan penurunan resolusi otomatis.
  self.ModelViewerElement = self.ModelViewerElement || {};
  self.ModelViewerElement.minimumRenderScale = 1;
</script>
<script type="module" src="/model-viewer.min.js"
  onerror="document.getElementById('st').textContent='ERROR: model-viewer.min.js gagal dimuat'"></script>
<style>
  html, body { margin:0; height:100%; background:$bg; overflow:hidden; }
  #wrap { position:relative; width:100%; height:100%; overflow:hidden; }
  model-viewer {
    position:absolute; left:0; top:0;
    width:${_ss * 100}%; height:${_ss * 100}%;
    transform:scale(${1 / _ss}); transform-origin:0 0;
    background:$bg;
  }
  #st { position:absolute; top:8px; left:10px; font:11px monospace; color:#888;
        z-index:5; pointer-events:none; }
</style>
</head>
<body>
<div id="st">memuat model...</div>
<div id="wrap">
<model-viewer id="mv" src="/payload.glb"
  camera-controls
  camera-orbit="$_initOrbit"
  camera-target="auto auto auto"
  min-camera-orbit="auto auto 15%"
  max-camera-orbit="auto auto 600%"
  interaction-prompt="none"
  environment-image="neutral"
  shadow-intensity="1"
  shadow-softness="1"
  exposure="1.05"
  orientation="0deg 0deg 0deg">
</model-viewer>
</div>
<script>
  var st = document.getElementById('st');
  var mvEl = document.getElementById('mv');
  var wrapEl = document.getElementById('wrap');
  mvEl.addEventListener('load', function () { st.textContent = ''; console.log('model loaded'); });
  mvEl.addEventListener('error', function (e) {
    st.textContent = 'ERROR model: ' + (e.detail && e.detail.sourceError ? e.detail.sourceError : 'gagal memuat GLB');
    console.log(st.textContent);
  });
  // Cadangan kalau pengaturan di <head> tidak terbaca
  customElements.whenDefined('model-viewer').then(function (C) {
    try { C.minimumRenderScale = 1; } catch (e) {}
  });
  setTimeout(function () {
    if (!customElements.get('model-viewer')) st.textContent = 'ERROR: model-viewer tidak terdaftar';
  }, 4000);

  // ---- Kualitas render (supersampling adaptif) ----
  // base    : faktor dari tombol kualitas (1x / 2x / 3x)
  // hostDpr : skala layar Flutter. Kalau WebView ternyata menggambar pada
  //           DPR lebih rendah dari layar (penyebab umum gambar burik di
  //           layar 125% / 150%), selisihnya ditambahkan otomatis.
  // Total dibatasi maks. 4x dan ukuran kanvas maks. 8192 px.
  var base = $_ss;
  var hostDpr = 1;
  function applyQuality() {
    var wdpr = window.devicePixelRatio || 1;
    var comp = Math.max(1, hostDpr / wdpr);
    var big = Math.max(wrapEl.clientWidth, wrapEl.clientHeight) * wdpr;
    var s = Math.max(1, Math.min(base * comp, 4, big > 0 ? 8192 / big : 4));
    mvEl.style.width = (s * 100) + '%';
    mvEl.style.height = (s * 100) + '%';
    mvEl.style.transform = 'scale(' + (1 / s) + ')';
    return s;
  }
  window.setQuality = function (b, d) {
    base = b;
    hostDpr = d;
    var s = applyQuality();
    console.log('quality base=' + b + 'x hostDpr=' + d + ' webDpr=' + (window.devicePixelRatio || 1) + ' total=' + s.toFixed(2) + 'x');
    setTimeout(function () {
      var c = mvEl.shadowRoot && mvEl.shadowRoot.querySelector('canvas');
      if (c) console.log('canvas ' + c.width + 'x' + c.height);
    }, 700);
  };
  window.addEventListener('resize', applyQuality);

  window.setAttitude = function (r, p, y) {
    if (!isFinite(r) || !isFinite(p) || !isFinite(y)) return;
    var mv = document.getElementById('mv');
    if (mv) mv.orientation = r + 'deg ' + p + 'deg ' + y + 'deg';
  };
  window.zoomBy = function (f) {
    var o = mvEl.getCameraOrbit();
    mvEl.cameraOrbit = o.theta + 'rad ' + o.phi + 'rad ' + (o.radius * f) + 'm';
  };
  window.resetView = function () {
    mvEl.cameraOrbit = '$_initOrbit';
    mvEl.cameraTarget = 'auto auto auto';
    mvEl.fieldOfView = 'auto';
  };
  window.setBg = function (c) {
    document.body.style.background = c;
    document.getElementById('mv').style.background = c;
  };
</script>
</body>
</html>
''';

  @override
  void didUpdateWidget(covariant Model3DGlbView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_pageReady && _web != null && oldWidget.palette != widget.palette) {
      _web!.evaluateJavascript(
          source: "window.setBg('${_hex(widget.palette.panel)}');");
    }
    _pushAttitude();
  }

  void _pushAttitude() {
    final t = widget.data;
    if (t == null || !_pageReady || _web == null) return;
    if (t.packetCount == _lastPacket) return;
    _lastPacket = t.packetCount;
    _web!.evaluateJavascript(
      source: 'window.setAttitude(${t.roll}, ${t.pitch}, ${t.yaw});',
    );
  }

  void _applyQuality() {
    if (!_pageReady || _web == null) return;
    _web!.evaluateJavascript(source: 'window.setQuality($_ss, $_hostDpr);');
  }

  void _cycleQuality() {
    setState(() => _qIdx = (_qIdx + 1) % _qLevels.length);
    _applyQuality();
  }

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
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: p.bad, fontSize: 12),
          ),
        ),
      );
    }
    if (_url == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return RepaintBoundary(
      child: InAppWebView(
        key: const ValueKey('payload-webview'),
        initialUrlRequest: URLRequest(url: WebUri(_url!)),
        initialSettings: InAppWebViewSettings(javaScriptEnabled: true),
        onWebViewCreated: (c) => _web = c,
        onLoadStop: (c, url) {
          _pageReady = true;
          _lastPacket = -1;
          _applyQuality();
          _pushAttitude();
        },
        onReceivedError: (c, req, err) =>
            debugPrint('[3D] WebView error: ${err.description}'),
        onConsoleMessage: (c, msg) => debugPrint('[3D] ${msg.message}'),
      ),
    );
  }

  void _js(String code) {
    if (_pageReady) _web?.evaluateJavascript(source: code);
  }

  Widget _zoomControls(AppPalette p) {
    Widget box(Widget child, String tip, VoidCallback onTap) {
      return Tooltip(
        message: tip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: p.panelAlt.withOpacity(0.92),
              border: Border.all(color: p.border),
              borderRadius: BorderRadius.circular(8),
            ),
            child: child,
          ),
        ),
      );
    }

    Widget btn(IconData icon, String tip, VoidCallback onTap) =>
        box(Icon(icon, size: 18, color: p.text), tip, onTap);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        box(
          Text(
            '${_ss.toInt()}x',
            style: TextStyle(
              color: p.accent,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
          'Kualitas render ${_ss.toInt()}x (tap untuk ganti 1x/2x/3x)',
          _cycleQuality,
        ),
        const SizedBox(height: 6),
        btn(Icons.add, 'Zoom in', () => _js('window.zoomBy(0.75);')),
        const SizedBox(height: 6),
        btn(Icons.remove, 'Zoom out', () => _js('window.zoomBy(1.35);')),
        const SizedBox(height: 6),
        btn(Icons.center_focus_strong, 'Reset view',
            () => _js('window.resetView();')),
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

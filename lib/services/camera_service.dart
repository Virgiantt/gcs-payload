import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';

class CameraService {
  Process? _ffmpegProcess;
  bool _isRunning = false;

  bool get isRunning => _isRunning;

  static String get defaultDevice {
    if (Platform.isWindows) return 'USB2.0 PC CAMERA'; 
    return '/dev/video0';
  }

  Future<void> start({
    String? device,
    int port = 5000, 
  }) async {
    if (_isRunning) {
      debugPrint('[CAM] FFmpeg sudah berjalan.');
      return;
    }

    final dev = (device != null && device.isNotEmpty) ? device : defaultDevice;
    final finalDev = (Platform.isWindows && dev.contains('/dev/video0')) 
        ? defaultDevice 
        : dev;

    final args = <String>[];

    if (Platform.isWindows) {
      args.addAll([
        '-f', 'dshow',
        '-rtbufsize', '100M',
        '-video_size', '640x480',
        '-framerate', '30',
        '-i', 'video=$finalDev',
      ]);
    } else if (Platform.isLinux) {
      // 🔥 KONFIGURASI KHUSUS UNTUK KAMERA YUYV (RASPBERRY PI)
      // Resolusi diturunkan ke 320x240 dan FPS ke 15 agar ringan
      args.addAll([
        '-f', 'v4l2',
        '-input_format', 'yuyv422', 
        '-video_size', '320x240',   
        '-framerate', '15',         
        '-i', finalDev,
      ]);
    } else {
      return;
    }

    // Konversi ke H.264 agar bisa dibaca oleh GStreamer di flutter-pi
    args.addAll([
      '-c:v', 'libx264',
      '-preset', 'ultrafast',
      '-tune', 'zerolatency',
      '-f', 'mpegts',
      '-mpegts_flags', '+resend_headers',
      'udp://127.0.0.1:$port?pkt_size=1316',
    ]);

    try {
      debugPrint('[CAM] Menjalankan: ffmpeg ${args.join(" ")}');
      _ffmpegProcess = await Process.start('ffmpeg', args);
      _isRunning = true;

      // Membaca output log dari FFmpeg
      _ffmpegProcess!.stdout
          .transform(const SystemEncoding().decoder)
          .listen((d) => debugPrint('[CAM-OUT] $d'));
      _ffmpegProcess!.stderr
          .transform(const SystemEncoding().decoder)
          .listen((d) => debugPrint('[CAM-ERR] $d'));

      _ffmpegProcess!.exitCode.then((code) {
        debugPrint('[CAM] FFmpeg berhenti dengan kode $code');
        _isRunning = false;
        _ffmpegProcess = null;
      });
    } catch (e) {
      debugPrint('[CAM] Gagal menjalankan FFmpeg: $e');
      _isRunning = false;
    }
  }

  Future<void> stop() async {
    if (_ffmpegProcess != null) {
      debugPrint('[CAM] Mematikan FFmpeg...');
      _ffmpegProcess!.kill(ProcessSignal.sigkill); 
      await Future.delayed(const Duration(milliseconds: 1000)); 
      _ffmpegProcess = null;
    }
    _isRunning = false;
  }

  void dispose() {
    stop();
  }

  Future<List<String>> getAvailableDevices() async {
    final List<String> devices = [];
    if (!Platform.isWindows) return ['/dev/video0']; 
    try {
      final result = await Process.run(
        'ffmpeg',
        ['-list_devices', 'true', '-f', 'dshow', '-i', 'dummy'],
        stderrEncoding: utf8,
      );
      final output = result.stderr as String;
      final regex = RegExp(r'"([^"]+)"\s*\(video\)');
      final matches = regex.allMatches(output);
      for (final match in matches) {
        devices.add(match.group(1)!);
      }
    } catch (e) {
      debugPrint('[CAM] Gagal mendapatkan daftar device: $e');
    }
    return devices;
  }
}
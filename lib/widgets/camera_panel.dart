import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:flutterpi_gstreamer_video_player/flutterpi_gstreamer_video_player.dart';
import '../theme/app_theme.dart';

class CameraPanel extends StatefulWidget {
  final AppPalette palette;
  final String streamUrl;
  final bool compact;

  const CameraPanel({
    super.key,
    required this.palette,
    required this.streamUrl,
    this.compact = false,
  });

  @override
  State<CameraPanel> createState() => _CameraPanelState();
}

class _CameraPanelState extends State<CameraPanel> {
  VideoPlayerController? _controller;
  
  List<String> _availableDevices = ['/dev/video0'];
  String? _selectedDevice = '/dev/video0';
  int _quarterTurns = 0;
  bool _isPlayerReady = false;
  bool _isInitializing = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    if (_isInitializing) return;
    setState(() {
      _isInitializing = true;
      _isPlayerReady = false;
      _errorMessage = null;
    });

    // Tunggu FFmpeg (dari main.dart) bersiap mengirim data
    await Future.delayed(const Duration(milliseconds: 2000));
    if (!mounted) return;

    // Hentikan controller lama jika ada (saat refresh)
    await _controller?.dispose();
    _controller = null;

    const pipeline = 
        'udpsrc port=5000 caps="video/mpegts, systemstream=(boolean)true" '
        '! tsdemux ! h264parse ! avdec_h264 ! videoconvert ! appsink name="sink"';

    try {
      _controller = FlutterpiVideoPlayerController.withGstreamerPipeline(pipeline);
      await _controller!.initialize();
      
      if (!mounted) return;
      setState(() {
        _isPlayerReady = true;
        _isInitializing = false;
      });
      _controller!.play();
    } catch (e) {
      debugPrint('[CAM_PANEL] Gagal inisialisasi video: $e');
      if (mounted) {
        setState(() {
          _errorMessage = 'Gagal memuat stream.\nPastikan kamera tercolok.';
          _isInitializing = false;
        });
      }
    }
  }

  void _rotateCamera() {
    setState(() {
      _quarterTurns = (_quarterTurns + 1) % 4;
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return Container(
      decoration: BoxDecoration(
        color: p.panel,
        border: Border.all(color: p.border),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.videocam, size: 14, color: p.bad),
                const SizedBox(width: 6),
                Text(
                  'LIVE CAMERA',
                  style: TextStyle(
                    color: p.textDim,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
                const Spacer(),
                // Tombol Refresh Stream
                InkWell(
                  onTap: _isInitializing ? null : _initPlayer,
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.all(4.0),
                    child: Icon(
                      Icons.refresh,
                      size: 16,
                      color: _isInitializing ? p.textDim.withValues(alpha: 0.5) : p.accent,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Tombol Rotasi
                InkWell(
                  onTap: _rotateCamera,
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.all(4.0),
                    child: Icon(Icons.rotate_right,
                        size: 16, color: p.textDim),
                  ),
                ),
                const SizedBox(width: 8),
                // Indikator REC
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _isPlayerReady ? p.bad : p.textDim,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  'REC',
                  style: TextStyle(
                    color: _isPlayerReady ? p.bad : p.textDim,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          // Area Video
          Expanded(
            child: Container(
              color: Colors.black,
              child: RotatedBox(
                quarterTurns: _quarterTurns,
                child: _isPlayerReady && _controller != null
                    ? AspectRatio(
                        aspectRatio: _controller!.value.aspectRatio,
                        child: VideoPlayer(_controller!),
                      )
                    : Center(
                        child: _errorMessage != null
                            ? Padding(
                                padding: const EdgeInsets.all(16.0),
                                child: Text(
                                  _errorMessage!,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: p.bad,
                                    fontSize: 12,
                                  ),
                                ),
                              )
                            : Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: p.textDim,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    'Menunggu aliran video...',
                                    style: TextStyle(
                                      color: p.textDim,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
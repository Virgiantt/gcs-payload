// import 'dart:async';
// import 'dart:io';
// import 'dart:math' as math;

// /// Konfigurasi telemetri — sesuaikan dengan simulator Python asli.
// class SimConfig {
//   static const String teamId = '1064';
//   static const double baseLat = -7.275764;
//   static const double baseLon = 112.794317;

//   static const String csvHeader =
//       'TEAM_ID,MISSION_TIME,PACKET_COUNT,ALTITUDE,PRESSURE,TEMPERATURE,'
//       'VOLTAGE,ROLL,PITCH,YAW,GPS_LAT,GPS_LON,GPS_ALT,STATE\r\n';
// }

// /// Menghasilkan satu baris telemetri per detik, siklus 110 detik.
// class FlightProfile {
//   final math.Random _rng = math.Random();
//   late DateTime _startTime;
//   int packetCount = 0;

//   FlightProfile() {
//     reset();
//   }

//   void reset() {
//     _startTime = DateTime.now();
//     packetCount = 0;
//   }

//   /// Kembalikan satu baris CSV + info untuk logging.
//   SimStep step() {
//     packetCount++;
//     final elapsed =
//         DateTime.now().difference(_startTime).inMilliseconds / 1000.0;

//     // Siklus 110 detik
//     final cycleTime = elapsed % 110.0;

//     String state;
//     double alt, roll, pitch, yaw;

//     if (cycleTime <= 10.0) {
//       // LAUNCH_PAD
//       state = 'LAUNCH_PAD';
//       alt = _uniform(0.0, 0.4);
//       roll = _uniform(-0.5, 0.5);
//       pitch = _uniform(-0.5, 0.5);
//       yaw = 0.0;
//     } else if (cycleTime <= 40.0) {
//       // ASCENT (10-40s): 0 → 700 m
//       state = 'ASCENT';
//       final progress = (cycleTime - 10.0) / 30.0;
//       alt = 700.0 * math.sin(progress * (math.pi / 2.0));
//       alt += _uniform(-1.5, 1.5);
//       roll = _uniform(-15.0, 15.0);
//       pitch = _uniform(5.0, 20.0);
//       yaw = (cycleTime * 12.0) % 360.0;
//     } else if (cycleTime <= 50.0) {
//       // APOGEE (40-50s): ~700 m
//       state = 'APOGEE';
//       alt = 700.0 + _uniform(-1.0, 1.0);
//       roll = _uniform(-25.0, 25.0);
//       pitch = _uniform(-10.0, 10.0);
//       yaw = (cycleTime * 8.0) % 360.0;
//     } else if (cycleTime <= 90.0) {
//       // DESCENT (50-90s): 700 → 0 m
//       state = 'DESCENT';
//       final progress = (cycleTime - 50.0) / 40.0;
//       alt = 700.0 * (1.0 - progress);
//       alt = math.max(0.5, alt + _uniform(-1.0, 1.0));
//       roll = _uniform(-8.0, 8.0);
//       pitch = _uniform(-5.0, 5.0);
//       yaw = (cycleTime * 4.0) % 360.0;
//     } else {
//       // LANDED
//       state = 'LANDED';
//       alt = 0.0;
//       roll = _uniform(-1.0, 1.0);
//       pitch = _uniform(-1.0, 1.0);
//       yaw = 180.0;
//     }

//     // Barometric pressure: P = P0 * (1 - alt/44330)^5.255
//     double pressure =
//         1013.25 * math.pow(1.0 - (math.max(0.0, alt) / 44330.0), 5.255);
//     pressure = _round(pressure + _uniform(-0.2, 0.2), 1);

//     final temp = _round(28.5 - (alt * 0.0065) + _uniform(-0.3, 0.3), 1);
//     final voltage = _round(
//         4.20 - (math.min(elapsed, 110.0) * 0.002) + _uniform(-0.02, 0.02), 2);

//     // GPS drift
//     final driftFactor = math.min(cycleTime / 90.0, 1.0) * 0.0015;
//     final gpsLat = _round(
//         SimConfig.baseLat + (driftFactor * 0.7) + _uniform(-0.00002, 0.00002),
//         6);
//     final gpsLon = _round(
//         SimConfig.baseLon + (driftFactor * 0.4) + _uniform(-0.00002, 0.00002),
//         6);
//     final gpsAlt = _round(math.max(0.0, alt) + _uniform(-2.0, 2.0), 1);

//     // Mission Time HH:MM:SS
//     final totalSec = elapsed.floor();
//     final hh = (totalSec ~/ 3600).toString().padLeft(2, '0');
//     final mm = ((totalSec % 3600) ~/ 60).toString().padLeft(2, '0');
//     final ss = (totalSec % 60).toString().padLeft(2, '0');
//     final missionTime = '$hh:$mm:$ss';

//     final line = '${SimConfig.teamId},$missionTime,$packetCount,'
//         '${alt.toStringAsFixed(1)},${pressure.toStringAsFixed(1)},'
//         '${temp.toStringAsFixed(1)},${voltage.toStringAsFixed(2)},'
//         '${roll.toStringAsFixed(1)},${pitch.toStringAsFixed(1)},'
//         '${yaw.toStringAsFixed(1)},'
//         '${gpsLat.toStringAsFixed(6)},${gpsLon.toStringAsFixed(6)},'
//         '${gpsAlt.toStringAsFixed(1)},$state\r\n';

//     return SimStep(
//       line: line,
//       packetCount: packetCount,
//       missionTime: missionTime,
//       altitude: alt,
//       state: state,
//     );
//   }

//   double _uniform(double min, double max) =>
//       min + _rng.nextDouble() * (max - min);

//   double _round(double v, int digits) {
//     final m = math.pow(10, digits);
//     return (v * m).round() / m;
//   }
// }

// class SimStep {
//   final String line;
//   final int packetCount;
//   final String missionTime;
//   final double altitude;
//   final String state;

//   SimStep({
//     required this.line,
//     required this.packetCount,
//     required this.missionTime,
//     required this.altitude,
//     required this.state,
//   });
// }

// /// Server TCP yang men-stream telemetri ke GCS — pengganti `run_tcp_server`.
// class TelemetrySimulator {
//   final String host;
//   final int port;

//   TelemetrySimulator({this.host = '0.0.0.0', this.port = 9999});

//   ServerSocket? _server;
//   Socket? _client;
//   final FlightProfile _profile = FlightProfile();
//   bool _running = false;

//   /// Callback untuk logging (print ke console / status bar).
//   void Function(String msg)? onLog;

//   Future<void> start() async {
//     _server = await ServerSocket.bind(host, port);
//     _running = true;
//     _log('=' * 65);
//     _log('CanSat Telemetry Simulator (Dart)');
//     _log('   Listening on : $host:$port');
//     _log('   GCS Address  : 127.0.0.1:$port');
//     _log('   Status       : Waiting for GCS to connect...');
//     _log('=' * 65);

//     _server!.listen(_handleClient);
//   }

//   void _handleClient(Socket client) async {
//     // Hanya izinkan 1 client (seperti server Python)
//     if (_client != null) {
//       client.destroy();
//       return;
//     }
//     _client = client;
//     _log('\n[+] GCS Client Connected from '
//         '${client.remoteAddress.address}:${client.remotePort}');

//     // Kirim header
//     client.write(SimConfig.csvHeader);
//     _profile.reset();

//     // Detect disconnect
//     client.listen(
//       (_) {}, // abaikan data dari GCS (tidak ada command parsing di sini)
//       onDone: _onClientDisconnect,
//       onError: (_) => _onClientDisconnect(),
//       cancelOnError: true,
//     );

//     // Stream telemetri tiap 1 detik
//     while (_running && _client == client) {
//       final step = _profile.step();
//       try {
//         client.write(step.line);
//         _log(
//             '[${step.missionTime}] Pkt #${step.packetCount.toString().padLeft(3, '0')} '
//             '| Alt: ${step.altitude.toStringAsFixed(1).padLeft(6)} m '
//             '| State: ${step.state.padRight(12)} -> Sent');
//       } catch (_) {
//         break;
//       }
//       await Future.delayed(const Duration(seconds: 1));
//     }

//     _onClientDisconnect();
//   }

//   void _onClientDisconnect() {
//     if (_client == null) return;
//     try {
//       _client?.destroy();
//     } catch (_) {}
//     _client = null;
//     _log('[-] GCS Client Disconnected. Waiting for reconnection...\n');
//   }

//   void _log(String msg) {
//     onLog?.call(msg);
//   }

//   Future<void> stop() async {
//     _running = false;
//     _onClientDisconnect();
//     await _server?.close();
//     _server = null;
//     _log('[!] Simulator terminated.');
//   }
// }

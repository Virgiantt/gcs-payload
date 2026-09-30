// import 'dart:io';
// import '../lib/services/simulator_service.dart';

// Future<void> main(List<String> args) async {
//   int port = 9999;
//   String host = '0.0.0.0';

//   for (var i = 0; i < args.length; i++) {
//     if (args[i] == '--port' && i + 1 < args.length) {
//       port = int.tryParse(args[i + 1]) ?? port;
//     } else if (args[i] == '--host' && i + 1 < args.length) {
//       host = args[i + 1];
//     } else if (args[i] == '--help' || args[i] == '-h') {
//       print('CanSat Telemetry Simulator (Dart)');
//       print(
//           'Usage: dart run tools/simulator_main.dart [--port 9999] [--host 0.0.0.0]');
//       return;
//     }
//   }

//   final sim = TelemetrySimulator(host: host, port: port);
//   sim.onLog = (msg) => print(msg);

//   // Tangani Ctrl+C
//   ProcessSignal.sigint.watch().listen((_) async {
//     print('\n[!] Shutting down...');
//     await sim.stop();
//     exit(0);
//   });

//   try {
//     await sim.start();
//   } catch (e) {
//     print('[ERROR] Gagal start simulator: $e');
//     exit(1);
//   }
// }

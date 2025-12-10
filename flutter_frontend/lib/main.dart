// ignore_for_file: unused_field

import 'package:flutter/material.dart';
import 'mqtt_service.dart';
import 'package:flutter_vlc_player/flutter_vlc_player.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Camera Controller',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const MyHomePage(title: 'Camera Controller Home'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});
  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final mqttService = MQTTService();

  String _status = "Disconnected";
  String _log = "";
  bool _recording = false;
  double _brightness = 128;
  double _contrast = 128;
  double _sharpness = 128;
  double _saturation = 128;
  final double _pan = 0;
  double _focus = 0;
  double _whiteBalance = 4000;
  bool _focusAuto = false;
  bool _wbAuto = false;
  int _recordDuration = 5;

  // Captured image overlay
  String? _capturedImagePath;

  // VLC player
  late VlcPlayerController _vlcController;

  @override
  void initState() {
    super.initState();
    _setupMQTT();

    // Initialize VLC player for RTSP stream
    _vlcController = VlcPlayerController.network(
      'rtsp://127.0.0.1:8554/webcam', // Example IP
      autoPlay: true,
      options: VlcPlayerOptions(
        advanced: VlcAdvancedOptions([
          '--rtsp-tcp',
          '--network-caching=300', // Added buffer for network stability
        ]),
      ),
    );
  }

  @override
  void dispose() {
    _vlcController.dispose();
    super.dispose();
  }

  void _setupMQTT() async {
    await mqttService.connect(
      server: '127.0.0.1',
      clientId: 'FlutterClient',
      clientCertAsset: 'assets/certs/crt/client_chain.crt',
      clientKeyAsset: 'assets/certs/private/client_decrypted.key',
      caCertAsset: 'assets/certs/crt/ca_chain.crt',
    );

    mqttService.subscribe('camera/status', (msg) {
      setState(() {
        _status = msg;
        _log += "[${DateTime.now().toLocal().toIso8601String()}] $msg\n";

        if (msg.contains("The Recording Stops Now!")) {
          _recording = false;
        }

        if (msg.contains("SUCCESS: Image saved to") || msg.contains("Recording stopped:")) {
          _capturedImagePath = msg.split(" ").last;
          Future.delayed(const Duration(seconds: 5), () {
            setState(() {
              _capturedImagePath = null;
            });
          });
        }
      });
    });

    setState(() {
      _status = "Connected";
    });
  }

  void _publishAction(String action) {
    mqttService.publish('camera/control/action', action);
  }

  void _publishSetting(String setting, dynamic value) {
    mqttService.publish('camera/control/settings', "$setting $value");
    setState(() {
      _log += "[UI] $setting -> $value\n";
    });
  }

  void _toggleRecording() {
    if (!_recording) {
      _publishAction("record $_recordDuration");
      setState(() {
        _recording = true;
      });
    } else {
      _publishAction("stop");
      setState(() {
        _recording = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Row(
          children: [
            // Left Column: Live Stream + Log
            Expanded(
              flex: 6,
              child: Column(
                children: [
                  Expanded(
                    flex: 6,
                    child: Stack(
                      children: [
                        Container(
                          width: double.infinity,
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.blue, width: 3),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: VlcPlayer(
                              controller: _vlcController,
                              aspectRatio: 16 / 9,
                              placeholder: const Center(
                                child: CircularProgressIndicator(),
                              ),
                            ),
                          ),
                        ),
                        if (_capturedImagePath != null)
                          Positioned.fill(
                            child: Opacity(
                              opacity: 0.8,
                              child: Image.network(
                                "file://$_capturedImagePath",
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    flex: 4,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.grey[200],
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey),
                      ),
                      child: SingleChildScrollView(
                        child: Text(
                          _log,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(width: 10),

            // Right Column: Controls
            Expanded(
              flex: 4,
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    // Actions
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text("Actions", style: TextStyle(color: Colors.blue, fontWeight: FontWeight.bold)),
                            Row(
                              children: [
                                ElevatedButton(
                                  onPressed: () => _publishAction("picture"),
                                  child: const Text("📸 Take Picture"),
                                ),
                                const SizedBox(width: 8),
                                SizedBox(
                                  width: 50,
                                  child: TextField(
                                    decoration: const InputDecoration(
                                      border: OutlineInputBorder(),
                                      contentPadding: EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                                    ),
                                    keyboardType: TextInputType.number,
                                    onChanged: (val) {
                                      int? dur = int.tryParse(val);
                                      if (dur != null && dur > 0) _recordDuration = dur;
                                    },
                                    controller: TextEditingController(text: _recordDuration.toString()),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                ElevatedButton(
                                  onPressed: _toggleRecording,
                                  child: Text(_recording ? "⏹ Stop Record" : "⏺ Start Record"),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 8),

                    // Primary Settings
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text("Primary Settings", style: TextStyle(color: Colors.blue, fontWeight: FontWeight.bold)),
                            _buildSlider("Brightness", _brightness, 0, 255, (v) {
                              _brightness = v;
                              _publishSetting("brightness", v.toInt());
                            }),
                            _buildSlider("Contrast", _contrast, 0, 255, (v) {
                              _contrast = v;
                              _publishSetting("contrast", v.toInt());
                            }),
                            _buildSlider("Sharpness", _sharpness, 0, 255, (v) {
                              _sharpness = v;
                              _publishSetting("sharpness", v.toInt());
                            }),
                            _buildSlider("Saturation", _saturation, 0, 255, (v) {
                              _saturation = v;
                              _publishSetting("saturation", v.toInt());
                            }),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 8),

                    // Advanced Settings
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text("Advanced Settings", style: TextStyle(color: Colors.blue, fontWeight: FontWeight.bold)),
                            /* _buildSlider("Pan", _pan, -36000, 36000, (v) {
                              _pan = v;
                              _publishSetting("pan_absolute", v.toInt());
                            }), */
                            const SizedBox(height: 4),
                            const Text("Focus"),
                            Row(
                              children: [
                                Expanded(
                                  child: ElevatedButton(
                                    onPressed: () {
                                      _focusAuto = false;
                                      _publishSetting("focus_automatic_continuous", 0);
                                    },
                                    child: const Text("Manual"),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: ElevatedButton(
                                    onPressed: () {
                                      _focusAuto = true;
                                      _publishSetting("focus_automatic_continuous", 1);
                                    },
                                    child: const Text("Auto"),
                                  ),
                                ),
                              ],
                            ),
                            _buildSlider("Focus Absolute", _focus, 0, 250, (v) {
                              _focus = v;
                              _publishSetting("focus_absolute", v.toInt());
                            }),
                            const SizedBox(height: 4),
                            const Text("White Balance"),
                            Row(
                              children: [
                                Expanded(
                                  child: ElevatedButton(
                                    onPressed: () {
                                      _wbAuto = false;
                                      _publishSetting("white_balance_automatic", 0);
                                    },
                                    child: const Text("Manual"),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: ElevatedButton(
                                    onPressed: () {
                                      _wbAuto = true;
                                      _publishSetting("white_balance_automatic", 1);
                                    },
                                    child: const Text("Auto"),
                                  ),
                                ),
                              ],
                            ),
                            _buildSlider("White Balance Temp", _whiteBalance, 2000, 6500, (v) {
                              _whiteBalance = v;
                              _publishSetting("white_balance_temperature", v.toInt());
                            }),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSlider(String label, double value, double min, double max, Function(double) onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: ((max - min) ~/ 1),
          onChanged: (v) {
            setState(() {
              onChanged(v);
            });
          },
        ),
      ],
    );
  }
}

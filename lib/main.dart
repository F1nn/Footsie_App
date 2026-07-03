import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const MyApp());
}

const int kGammaMinX100 = 50;
const int kGammaMaxX100 = 500;
const int kGammaStepX100 = 10; // 0.1 step size
const int kDiscoveryHandleThresholdMv = 500;
const String kServiceUuid = '501e5b9c-764b-4b18-9d87-796d00008c4a';
const String kGammaCharUuid = '4a8c0001-6d79-879d-184b-4b769c5b1e50';
const String kAdcCharUuid = '4a8c0002-6d79-879d-184b-4b769c5b1e50';
const String kSliderCalCharUuid = '4a8c0003-6d79-879d-184b-4b769c5b1e50';
const String kOutputScaleCharUuid = '4a8c0004-6d79-879d-184b-4b769c5b1e50';
// gamma range defined above
const String kDeviceName = 'Footsie';

String _normalizeUuid(String value) => value.toLowerCase().replaceAll('-', '');

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Footsie',
      theme: ThemeData(useMaterial3: true),
      home: const FootsieHome(),
    );
  }
}

class FootsieHome extends StatefulWidget {
  const FootsieHome({super.key});

  @override
  State<FootsieHome> createState() => _FootsieHomeState();
}

class _FootsieHomeState extends State<FootsieHome> {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _gammaChar;
  BluetoothCharacteristic? _adcChar;
  BluetoothCharacteristic? _sliderChar;
  BluetoothCharacteristic? _outputChar;
  StreamSubscription<List<int>>? _adcSub;
  StreamSubscription? _scanSub;
  final ValueNotifier<bool> _isConnected = ValueNotifier<bool>(false);
  final ValueNotifier<List<String>> _logs = ValueNotifier<List<String>>(
    <String>[],
  );
  String _status = 'disconnected';
  int _gammaX100 = 220; // default
  int? _adcValue;
  int? _adcCalMinMv;
  int? _adcCalMaxMv;
  int? _outputMinMv;
  int? _outputMaxMv;

  void _appendLog(String message) {
    final timestamp = DateTime.now().toIso8601String().substring(11, 19);
    final entry = '[$timestamp] $message';
    debugPrint(entry);

    if (!mounted) {
      return;
    }

    _logs.value = <String>[entry, ..._logs.value];
  }

  void _setStatus(String status) {
    if (!mounted) {
      return;
    }

    setState(() {
      _status = status;
    });
  }

  Future<void> _openLogs() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AppLogScreen(
          logs: _logs,
          onClear: () {
            _logs.value = <String>[];
            debugPrint('[LOGS] Log buffer cleared');
          },
        ),
      ),
    );
  }

  Future<void> _openCalibration() async {
    if (!_isConnected.value || _sliderChar == null) {
      _appendLog('Calibration open skipped: device disconnected');
      return;
    }

    // Build a live ADC stream (maps List<int> -> int)
    final Stream<int?> adcStream = _adcChar != null
        ? _adcChar!.lastValueStream.map((data) {
            if (data.isEmpty) return null;
            return data.length >= 2 ? (data[0] | (data[1] << 8)) : data[0];
          })
        : Stream<int?>.value(null);

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => CalibrationScreen(
          sliderChar: _sliderChar,
          adcStream: adcStream,
          connectionListenable: _isConnected,
          currentMinMv: _adcCalMinMv,
          currentMaxMv: _adcCalMaxMv,
          readCal: _readSliderCal,
          writeCal: _writeSliderCal,
          outputChar: _outputChar,
          currentOutputMinMv: _outputMinMv,
          currentOutputMaxMv: _outputMaxMv,
          readOutput: _readOutputScale,
          writeOutput: _writeOutputScale,
          appendLog: _appendLog,
        ),
      ),
    );
  }

  Future<void> _closeConnection({String reason = 'disconnected'}) async {
    _setStatus('disconnecting');

    await _scanSub?.cancel();
    _scanSub = null;
    await _adcSub?.cancel();
    _adcSub = null;

    try {
      await FlutterBluePlus.stopScan();
    } catch (e) {
      _appendLog('Stop scan error: $e');
    }

    try {
      await _adcChar?.setNotifyValue(false);
    } catch (e) {
      _appendLog('Disable ADC notify error: $e');
    }

    final device = _device;
    if (device != null) {
      try {
        await device.disconnect(queue: false, timeout: 10);
        if (device.isConnected) {
          _appendLog('Disconnect returned but device still reports connected');
        }
      } on TimeoutException {
        _appendLog('Disconnect timed out after 10 seconds');
      } catch (e) {
        _appendLog('Disconnect error: $e');
      }
    }

    _device = null;
    _gammaChar = null;
    _adcChar = null;
    _sliderChar = null;
    _adcValue = null;
    _isConnected.value = false;
    _setStatus(reason);
    _appendLog('Connection closed: $reason');
  }

  Future<void> _disconnect({String reason = 'disconnected'}) async {
    await _closeConnection(reason: reason);
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _adcSub?.cancel();
    unawaited(_adcChar?.setNotifyValue(false));
    unawaited(_device?.disconnect(queue: false, timeout: 10));
    _isConnected.dispose();
    _logs.dispose();
    super.dispose();
  }

  Future<void> _startScanAndConnect() async {
    // Request Bluetooth permissions before scanning
    final scanStatus = await Permission.bluetoothScan.request();
    final connectStatus = await Permission.bluetoothConnect.request();
    await Permission.location.request();

    if (!scanStatus.isGranted || !connectStatus.isGranted) {
      _appendLog('Permission request denied for Bluetooth scan or connect');
      _setStatus('permissions denied');
      return;
    }

    _appendLog('Scanning for $kDeviceName');
    _setStatus('scanning');

    // Cancel previous scan subscription if any
    await _scanSub?.cancel();
    await FlutterBluePlus.stopScan();

    bool deviceFound = false;

    // start scan and listen to aggregated scanResults
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));

    _scanSub = FlutterBluePlus.scanResults.listen((results) async {
      if (deviceFound) return;

      for (var r in results) {
        final name = r.device.advName.isNotEmpty
            ? r.device.advName
            : r.device.platformName;
        _appendLog('Found device: $name (${r.device.remoteId})');

        if (name.toLowerCase().contains(kDeviceName.toLowerCase())) {
          deviceFound = true;
          _appendLog('Matched target device: $name');
          // stop scan
          await FlutterBluePlus.stopScan();
          await _scanSub?.cancel();
          _scanSub = null;

          _setStatus('connecting');
          _device = r.device;

          try {
            await _device!.connect(license: License.nonprofit);
            _appendLog('Connected to ${_device!.advName}');
            _isConnected.value = true;
          } catch (e) {
            _appendLog('Connection error: $e');
            await _closeConnection(reason: 'connection failed');
            return;
          }

          try {
            final services = await _device!.discoverServices();
            _appendLog('Found ${services.length} services');
            _gammaChar = null;
            _adcChar = null;
            final normalizedServiceUuid = _normalizeUuid(kServiceUuid);
            final normalizedGammaUuid = _normalizeUuid(kGammaCharUuid);
            final normalizedAdcUuid = _normalizeUuid(kAdcCharUuid);
            final normalizedSliderUuid = _normalizeUuid(kSliderCalCharUuid);
            final normalizedOutputUuid = _normalizeUuid(kOutputScaleCharUuid);

            for (var s in services) {
              final sUuid = s.uuid.toString().toLowerCase();
              _appendLog('Service: $sUuid');
              _appendLog('  Characteristics: ${s.characteristics.length}');
              if (_normalizeUuid(sUuid) == normalizedServiceUuid) {
                _appendLog('Target service matched');
              }
              for (var c in s.characteristics) {
                final cUuid = c.uuid.toString().toLowerCase();
                _appendLog('  Characteristic: $cUuid (props: ${c.properties})');
                final normalizedCharUuid = _normalizeUuid(cUuid);
                final isExactGammaChar =
                    normalizedCharUuid == normalizedGammaUuid;

                if (isExactGammaChar) {
                  _gammaChar = c;
                  _appendLog('Gamma characteristic bound');
                }

                if (normalizedCharUuid == normalizedAdcUuid) {
                  _adcChar = c;
                  _appendLog('ADC characteristic bound');
                }
                if (normalizedCharUuid == normalizedSliderUuid) {
                  _sliderChar = c;
                  _appendLog('ADC Calibration characteristic bound');
                }
                if (normalizedCharUuid == normalizedOutputUuid) {
                  _outputChar = c;
                  _appendLog('Output scaling characteristic bound');
                }
              }
            }

            _setStatus(
              _gammaChar != null ? 'connected' : 'connected (gamma not found)',
            );

            if (_gammaChar != null) {
              await _readGamma();
            }

            if (_adcChar != null) {
              await _startAdcStreaming();
            } else {
              _appendLog('ADC characteristic not found');
            }
            if (_sliderChar != null) {
              await _readSliderCal();
            }
            if (_outputChar != null) {
              await _readOutputScale();
            }
          } catch (e) {
            await _closeConnection(reason: 'service discovery failed');
            _appendLog('Service discovery error: $e');
          }
          return;
        }
      }
    });

    // Handle scan timeout
    Future.delayed(const Duration(seconds: 11), () {
      if (!mounted) {
        return;
      }

      if (!deviceFound && _status == 'scanning') {
        _scanSub?.cancel();
        _setStatus('device not found (scan timeout)');
        _isConnected.value = false;
        _appendLog('Scan timeout: target device not found');
      }
    });
  }

  Future<void> _readGamma() async {
    if (_gammaChar == null) {
      _appendLog('Gamma read skipped: characteristic not bound');
      return;
    }

    try {
      final data = await _gammaChar!.read();
      if (data.length >= 2) {
        final value = data[0] | (data[1] << 8);
        setState(() => _gammaX100 = value);
        _appendLog(
          'Gamma read success: $value (${(value / 100).toStringAsFixed(2)})',
        );
      } else {
        _appendLog('Gamma read failed: expected 2 bytes, got ${data.length}');
      }
    } catch (e) {
      _appendLog('Gamma read error: $e');
    }
  }

  Future<void> _writeGamma(int value) async {
    if (_gammaChar == null) {
      _appendLog('Gamma write skipped: characteristic not bound');
      return;
    }

    final bytes = Uint8List(2);
    bytes[0] = value & 0xFF;
    bytes[1] = (value >> 8) & 0xFF;
    try {
      await _gammaChar!.write(bytes, withoutResponse: false);
      setState(() => _gammaX100 = value);
      _appendLog(
        'Gamma write success: $value (${(value / 100).toStringAsFixed(2)})',
      );

      final readback = await _gammaChar!.read();
      if (readback.length >= 2) {
        final confirmed = readback[0] | (readback[1] << 8);
        setState(() => _gammaX100 = confirmed);
        if (confirmed == value) {
          _appendLog(
            'Gamma write verified by readback: $confirmed (${(confirmed / 100).toStringAsFixed(2)})',
          );
        } else {
          _appendLog(
            'Gamma write mismatch: wrote $value, read back $confirmed',
          );
        }
      } else {
        _appendLog(
          'Gamma readback failed: expected 2 bytes, got ${readback.length}',
        );
      }
    } catch (e) {
      _appendLog('Gamma write failed for $value: $e');
    }
  }

  Future<void> _startAdcStreaming() async {
    if (_adcChar == null) {
      _appendLog('ADC stream skipped: characteristic not bound');
      return;
    }

    try {
      await _adcSub?.cancel();
      _adcSub = _adcChar!.lastValueStream.listen((data) {
        if (!mounted || data.isEmpty) {
          return;
        }

        final value = data.length >= 2 ? (data[0] | (data[1] << 8)) : data[0];
        setState(() {
          _adcValue = value;
        });
      });

      await _adcChar!.setNotifyValue(true);
      _appendLog('ADC streaming enabled');
    } catch (e) {
      _appendLog('ADC streaming error: $e');
    }
  }

  Future<({int minMv, int maxMv})?> _readSliderCal() async {
    if (_sliderChar == null) {
      _appendLog('ADC Calibration read skipped: characteristic not bound');
      return null;
    }

    try {
      final data = await _sliderChar!.read();
      if (data.length >= 4) {
        final min = data[0] | (data[1] << 8);
        final max = data[2] | (data[3] << 8);
        setState(() {
          _adcCalMinMv = min;
          _adcCalMaxMv = max;
        });
        _appendLog('ADC Calibration read: ${min}mV - ${max}mV');
        return (minMv: min, maxMv: max);
      } else {
        _appendLog(
          'ADC Calibration read failed: expected 4 bytes, got ${data.length}',
        );
        return null;
      }
    } catch (e) {
      _appendLog('ADC Calibration read error: $e');
      return null;
    }
  }

  Future<({int minMv, int maxMv})?> _readOutputScale() async {
    if (_outputChar == null) {
      _appendLog('Output scale read skipped: characteristic not bound');
      return null;
    }

    try {
      final data = await _outputChar!.read();
      if (data.length >= 4) {
        final min = data[0] | (data[1] << 8);
        final max = data[2] | (data[3] << 8);
        setState(() {
          _outputMinMv = min;
          _outputMaxMv = max;
        });
        _appendLog('Output scaling read: ${min}mV - ${max}mV');
        return (minMv: min, maxMv: max);
      } else {
        _appendLog(
          'Output scaling read failed: expected 4 bytes, got ${data.length}',
        );
        return null;
      }
    } catch (e) {
      _appendLog('Output scaling read error: $e');
      return null;
    }
  }

  Future<void> _writeOutputScale(int minMv, int maxMv) async {
    if (_outputChar == null) {
      _appendLog('Output scaling write skipped: characteristic not bound');
      return;
    }

    final bytes = Uint8List(4);
    bytes[0] = minMv & 0xFF;
    bytes[1] = (minMv >> 8) & 0xFF;
    bytes[2] = maxMv & 0xFF;
    bytes[3] = (maxMv >> 8) & 0xFF;

    try {
      await _outputChar!.write(bytes, withoutResponse: false);
      _appendLog('Output scaling write requested: ${minMv}mV - ${maxMv}mV');
    } catch (e) {
      _appendLog('Output scaling write failed: $e');
    }
  }

  Future<void> _writeSliderCal(int minMv, int maxMv) async {
    if (_sliderChar == null) {
      _appendLog('ADC Calibration write skipped: characteristic not bound');
      return;
    }

    final bytes = Uint8List(4);
    bytes[0] = minMv & 0xFF;
    bytes[1] = (minMv >> 8) & 0xFF;
    bytes[2] = maxMv & 0xFF;
    bytes[3] = (maxMv >> 8) & 0xFF;

    try {
      await _sliderChar!.write(bytes, withoutResponse: false);
      _appendLog('ADC Calibration write requested: ${minMv}mV - ${maxMv}mV');
    } catch (e) {
      _appendLog('ADC Calibration write failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final gamma = (_gammaX100 / 100.0).toStringAsFixed(2);
    final gammaValue = _gammaX100 / 100.0;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Footsie — BLE'),
        actions: [
          TextButton(onPressed: _openLogs, child: const Text('Logs')),
          ValueListenableBuilder<bool>(
            valueListenable: _isConnected,
            builder: (context, isConnected, _) {
              return IconButton(
                tooltip: 'Calibration',
                onPressed: isConnected && _sliderChar != null
                    ? _openCalibration
                    : null,
                icon: const Icon(Icons.settings),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Status: $_status'),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          ValueListenableBuilder<bool>(
                            valueListenable: _isConnected,
                            builder: (context, isConnected, _) {
                              return FilledButton(
                                onPressed: _status == 'scanning'
                                    ? null
                                    : isConnected
                                    ? _disconnect
                                    : _startScanAndConnect,
                                child: Text(
                                  isConnected ? 'Disconnect' : 'Scan & Connect',
                                ),
                              );
                            },
                          ),
                          FilledButton.tonal(
                            onPressed: _gammaChar != null ? _readGamma : null,
                            child: const Text('Read Gamma'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          Text(
                            'Gamma: ',
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                          const Spacer(),
                          Text(
                            'Range 0.5-5.0',
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                        ],
                      ),
                      Slider(
                        value: _gammaX100.toDouble(),
                        min: kGammaMinX100.toDouble(),
                        max: kGammaMaxX100.toDouble(),
                        divisions:
                            (kGammaMaxX100 - kGammaMinX100) ~/ kGammaStepX100,
                        label: gamma,
                        onChanged: _gammaChar == null
                            ? null
                            : (v) {
                                final intVal = v.round();
                                setState(() => _gammaX100 = intVal);
                              },
                        onChangeEnd: _gammaChar == null
                            ? null
                            : (v) async {
                                final intVal = v.round();
                                await _writeGamma(intVal);
                              },
                      ),
                      const SizedBox(height: 4),
                      const Center(
                        child: Text(
                          'Gamma writes automatically when you release the slider.',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                      const SizedBox(height: 12),
                      const SizedBox(height: 24),
                      ThrottleCurveCard(gamma: gammaValue, adcValue: _adcValue),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text('Logs', style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 156,
                child: ValueListenableBuilder<List<String>>(
                  valueListenable: _logs,
                  builder: (context, entries, _) {
                    final previewEntries = entries.take(5).toList();
                    return DecoratedBox(
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                      ),
                      child: previewEntries.isEmpty
                          ? const Center(child: Text('No logs yet.'))
                          : ListView.separated(
                              padding: const EdgeInsets.all(12),
                              itemCount: previewEntries.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (context, index) {
                                return SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: Text(
                                    previewEntries[index],
                                    softWrap: false,
                                    maxLines: 1,
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                );
                              },
                            ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ThrottleCurveCard extends StatelessWidget {
  const ThrottleCurveCard({super.key, required this.gamma, this.adcValue});

  final double gamma;
  final int? adcValue;

  @override
  Widget build(BuildContext context) {
    final adcText = adcValue?.toString() ?? '--';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Gamma: ', style: Theme.of(context).textTheme.titleSmall),
                Text(
                  gamma.toStringAsFixed(2),
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                Text(
                  'ADC: $adcText',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 170,
              width: double.infinity,
              child: CustomPaint(
                painter: ThrottleCurvePlotPainter(
                  gamma: gamma,
                  adcValue: adcValue,
                  axisColor: Theme.of(context).colorScheme.outline,
                  guideColor: Theme.of(context).colorScheme.outlineVariant,
                  curveColor: Theme.of(context).colorScheme.primary,
                  markerColor: Theme.of(context).colorScheme.tertiary,
                ),
                size: Size.infinite,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ThrottleCurvePlotPainter extends CustomPainter {
  const ThrottleCurvePlotPainter({
    required this.gamma,
    required this.axisColor,
    required this.guideColor,
    required this.curveColor,
    required this.markerColor,
    this.adcValue,
  });

  final double gamma;
  final Color axisColor;
  final Color guideColor;
  final Color curveColor;
  final Color markerColor;
  final int? adcValue;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 36.0;
    const top = 8.0;
    const right = 8.0;
    const bottom = 22.0;

    final x0 = left;
    final y0 = size.height - bottom;
    final x1 = size.width - right;
    final y1 = top;
    final width = math.max(1.0, x1 - x0);
    final height = math.max(1.0, y0 - y1);

    final axisPaint = Paint()
      ..color = axisColor
      ..strokeWidth = 1;

    final guidePaint = Paint()
      ..color = guideColor
      ..strokeWidth = 1;

    for (var i = 1; i <= 4; i++) {
      final t = i / 5.0;
      final gx = x0 + width * t;
      final gy = y0 - height * t;
      canvas.drawLine(Offset(gx, y0), Offset(gx, y1), guidePaint);
      canvas.drawLine(Offset(x0, gy), Offset(x1, gy), guidePaint);
    }

    canvas.drawLine(Offset(x0, y0), Offset(x1, y0), axisPaint);
    canvas.drawLine(Offset(x0, y0), Offset(x0, y1), axisPaint);

    final linearPaint = Paint()
      ..color = guideColor
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(x0, y0), Offset(x1, y1), linearPaint);

    final curvePaint = Paint()
      ..color = curveColor
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;

    final path = Path()..moveTo(x0, y0);
    const points = 100; // sample 0..100%
    for (var i = 1; i <= points; i++) {
      final input = i / points;
      final output = math.pow(input, gamma).toDouble();
      final x = x0 + input * width;
      final y = y0 - output * height;
      path.lineTo(x, y);
    }
    canvas.drawPath(path, curvePaint);

    final adc = adcValue?.clamp(0, 3300);
    if (adc != null) {
      final input = adc / 3300.0;
      final output = math.pow(input, gamma).toDouble();
      final markerX = x0 + input * width;
      final markerY = y0 - output * height;

      final markerPaint = Paint()
        ..color = markerColor
        ..style = PaintingStyle.fill;
      final haloPaint = Paint()
        ..color = markerColor.withValues(alpha: 0.18)
        ..style = PaintingStyle.fill;

      canvas.drawCircle(Offset(markerX, markerY), 8, haloPaint);
      canvas.drawCircle(Offset(markerX, markerY), 4.5, markerPaint);
    }

    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    textPainter.text = TextSpan(
      text: 'Input',
      style: TextStyle(color: axisColor, fontSize: 10),
    );
    textPainter.layout();
    textPainter.paint(canvas, Offset(x1 - textPainter.width, y0 + 4));

    textPainter.text = TextSpan(
      text: 'Output',
      style: TextStyle(color: axisColor, fontSize: 10),
    );
    textPainter.layout();
    textPainter.paint(canvas, Offset(2, y1));
  }

  @override
  bool shouldRepaint(covariant ThrottleCurvePlotPainter oldDelegate) {
    return oldDelegate.gamma != gamma ||
        oldDelegate.axisColor != axisColor ||
        oldDelegate.guideColor != guideColor ||
        oldDelegate.curveColor != curveColor ||
        oldDelegate.markerColor != markerColor ||
        oldDelegate.adcValue != adcValue;
  }
}

class AppLogScreen extends StatelessWidget {
  const AppLogScreen({super.key, required this.logs, required this.onClear});

  final ValueNotifier<List<String>> logs;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Logs'),
        actions: [
          TextButton(onPressed: onClear, child: const Text('Clear')),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: ValueListenableBuilder<List<String>>(
          valueListenable: logs,
          builder: (context, entries, _) {
            if (entries.isEmpty) {
              return const Center(child: Text('No logs yet.'));
            }

            return ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: entries.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Text(
                    entries[index],
                    softWrap: false,
                    maxLines: 1,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class CalibrationScreen extends StatefulWidget {
  const CalibrationScreen({
    super.key,
    required this.sliderChar,
    required this.adcStream,
    required this.connectionListenable,
    required this.currentMinMv,
    required this.currentMaxMv,
    required this.readCal,
    required this.writeCal,
    this.outputChar,
    this.currentOutputMinMv,
    this.currentOutputMaxMv,
    this.readOutput,
    this.writeOutput,
    required this.appendLog,
  });

  final BluetoothCharacteristic? sliderChar;
  final Stream<int?> adcStream;
  final ValueNotifier<bool> connectionListenable;
  final int? currentMinMv;
  final int? currentMaxMv;
  final Future<({int minMv, int maxMv})?> Function() readCal;
  final Future<void> Function(int minMv, int maxMv) writeCal;
  final BluetoothCharacteristic? outputChar;
  final int? currentOutputMinMv;
  final int? currentOutputMaxMv;
  final Future<({int minMv, int maxMv})?> Function()? readOutput;
  final Future<void> Function(int minMv, int maxMv)? writeOutput;
  final void Function(String) appendLog;

  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends State<CalibrationScreen> {
  bool _busy = false;
  String? _errorMessage;
  StreamSubscription<int?>? _adcStreamSub;
  int? _adcMv;
  int? _storedMinMv;
  int? _storedMaxMv;
  int? _discoveredMinMv;
  int? _discoveredMaxMv;
  int? _discoveryBaseMinMv;
  int? _discoveryBaseMaxMv;
  double _rangeStart = 0.0;
  double _rangeEnd = 3300.0;
  bool _minHandleReady = false;
  bool _maxHandleReady = false;
  bool _discoveryStarted = false;
  bool _hasStartedOnce = false;
  bool _verified = false;
  int? _storedOutputMinMv;
  int? _storedOutputMaxMv;
  double _outputRangeStart = 0.0;
  double _outputRangeEnd = 5000.0;
  final TextEditingController _outputMinController = TextEditingController();
  final TextEditingController _outputMaxController = TextEditingController();
  String? _outputErrorMessage;
  bool _outputWriteLocked = false;

  @override
  void initState() {
    super.initState();
    _storedMinMv = widget.currentMinMv;
    _storedMaxMv = widget.currentMaxMv;
    _discoveredMinMv = widget.currentMinMv;
    _discoveredMaxMv = widget.currentMaxMv;
    _discoveryBaseMinMv = widget.currentMinMv;
    _discoveryBaseMaxMv = widget.currentMaxMv;
    if (widget.currentMinMv != null) {
      _rangeStart = widget.currentMinMv!.toDouble();
    }
    if (widget.currentMaxMv != null) {
      _rangeEnd = widget.currentMaxMv!.toDouble();
    }
    if (widget.currentOutputMinMv != null) {
      _storedOutputMinMv = widget.currentOutputMinMv;
      _outputRangeStart = widget.currentOutputMinMv!.toDouble();
      _outputMinController.text = widget.currentOutputMinMv!.toString();
    }
    if (widget.currentOutputMaxMv != null) {
      _storedOutputMaxMv = widget.currentOutputMaxMv;
      _outputRangeEnd = widget.currentOutputMaxMv!.toDouble();
      _outputMaxController.text = widget.currentOutputMaxMv!.toString();
    }
    _adcStreamSub = widget.adcStream.listen((v) {
      if (!mounted || v == null) return;

      final clampedMv = v.clamp(0, 3300);
      if (!_discoveryStarted) {
        setState(() {
          _adcMv = clampedMv;
        });
        return;
      }

      final baseMin = _discoveryBaseMinMv ?? clampedMv;
      final baseMax = _discoveryBaseMaxMv ?? clampedMv;
      final nextMin = _discoveredMinMv == null
          ? clampedMv
          : math.min(_discoveredMinMv!, clampedMv);
      final nextMax = _discoveredMaxMv == null
          ? clampedMv
          : math.max(_discoveredMaxMv!, clampedMv);
        final nextMinReady =
          _minHandleReady || (baseMin - nextMin > kDiscoveryHandleThresholdMv);
        final nextMaxReady =
          _maxHandleReady || (nextMax - baseMax > kDiscoveryHandleThresholdMv);

      final rangeChanged =
          nextMin != _discoveredMinMv || nextMax != _discoveredMaxMv;

      setState(() {
        _adcMv = clampedMv;
        _discoveredMinMv = nextMin;
        _discoveredMaxMv = nextMax;
        _discoveryBaseMinMv = baseMin;
        _discoveryBaseMaxMv = baseMax;
        _minHandleReady = nextMinReady;
        _maxHandleReady = nextMaxReady;
        _rangeStart = nextMin.toDouble();
        _rangeEnd = nextMax.toDouble();
        if (rangeChanged) {
          _verified = false;
        }
      });
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_refreshCalibration());
      }
    });
  }

  @override
  void dispose() {
    _adcStreamSub?.cancel();
    _outputMinController.dispose();
    _outputMaxController.dispose();
    super.dispose();
  }

  // ADC values are already sent in millivolts (0..3300 mV) by the device.

  Future<void> _refreshCalibration() async {
    final calibration = await widget.readCal();
    final outputCalibration = widget.readOutput != null ? await widget.readOutput!() : null;
    if (!mounted || calibration == null) {
      return;
    }

    setState(() {
      _storedMinMv = calibration.minMv;
      _storedMaxMv = calibration.maxMv;
      if (!_discoveryStarted &&
          (_discoveredMinMv == null || _discoveredMaxMv == null)) {
        _discoveredMinMv = calibration.minMv;
        _discoveredMaxMv = calibration.maxMv;
        _discoveryBaseMinMv = calibration.minMv;
        _discoveryBaseMaxMv = calibration.maxMv;
        _rangeStart = calibration.minMv.toDouble();
        _rangeEnd = calibration.maxMv.toDouble();
      }

      if (outputCalibration != null) {
        _storedOutputMinMv = outputCalibration.minMv;
        _storedOutputMaxMv = outputCalibration.maxMv;
        _outputRangeStart = outputCalibration.minMv.toDouble();
        _outputRangeEnd = outputCalibration.maxMv.toDouble();
        _outputMinController.text = outputCalibration.minMv.toString();
        _outputMaxController.text = outputCalibration.maxMv.toString();
      }
    });
  }

  Future<void> _saveDiscoveredCalibration() async {
    if (!_discoveryStarted) {
      setState(() {
        _errorMessage =
            'Press Start first, then move through the full range before saving.';
      });
      widget.appendLog('Calibration save blocked: discovery has not started');
      return;
    }

    if (!_minHandleReady || !_maxHandleReady) {
      setState(() {
        _errorMessage =
            'Move the control through both ends so min and max handles both move before saving.';
      });
      widget.appendLog(
        'Calibration save blocked: both handles must move from start position',
      );
      return;
    }

    final minMv = _discoveredMinMv;
    final maxMv = _discoveredMaxMv;
    if (minMv == null || maxMv == null) {
      setState(() {
        _errorMessage =
            'Move the slider first so min and max can be discovered.';
      });
      widget.appendLog('Calibration save blocked: discovered range is empty');
      return;
    }

    if (minMv >= maxMv) {
      setState(() {
        _errorMessage = 'Min must be less than max.';
      });
      widget.appendLog('Calibration save blocked: min must be < max');
      return;
    }

    if (maxMv > 3300 || minMv < 0) {
      setState(() {
        _errorMessage = 'Values must be in the 0..3300 mV range.';
      });
      widget.appendLog('Calibration save blocked: values outside 0..3300 mV');
      return;
    }

    const minimumSpanMv = 150;
    final spanMv = maxMv - minMv;
    if (spanMv < minimumSpanMv) {
      setState(() {
        _errorMessage =
            'Range span is too small ($spanMv mV). Move through the full range a couple of times, then save.';
      });
      widget.appendLog(
        'Calibration save blocked: discovered span $spanMv mV is below $minimumSpanMv mV',
      );
      return;
    }

    setState(() {
      _busy = true;
      _errorMessage = null;
      _verified = false;
    });

    try {
      await widget.writeCal(minMv, maxMv);
      final calibration = await widget.readCal();
      if (!mounted) {
        return;
      }

      setState(() {
        if (calibration == null) {
          _verified = false;
          _errorMessage =
              'Calibration verify failed: could not read back values';
          return;
        }

        _storedMinMv = calibration.minMv;
        _storedMaxMv = calibration.maxMv;
        _rangeStart = calibration.minMv.toDouble();
        _rangeEnd = calibration.maxMv.toDouble();
        _discoveredMinMv = calibration.minMv;
        _discoveredMaxMv = calibration.maxMv;

        final writeVerified =
            calibration.minMv == minMv && calibration.maxMv == maxMv;
        _verified = writeVerified;
        _errorMessage = writeVerified
            ? null
            : 'Calibration verify mismatch: wrote ${minMv}mV - ${maxMv}mV, read back ${calibration.minMv}mV - ${calibration.maxMv}mV';
      });

      if (_verified) {
        widget.appendLog('Calibration save verified: ${minMv}mV - ${maxMv}mV');
      } else {
        widget.appendLog('Calibration save failed verification');
      }
    } finally {
      setState(() => _busy = false);
    }
  }

  void _resetDiscoveredRange() {
    final startMv = _adcMv ?? 1650;
    final wasStartedOnce = _hasStartedOnce;
    setState(() {
      _discoveryStarted = true;
      _hasStartedOnce = true;
      _discoveredMinMv = startMv;
      _discoveredMaxMv = startMv;
      _discoveryBaseMinMv = startMv;
      _discoveryBaseMaxMv = startMv;
      _minHandleReady = false;
      _maxHandleReady = false;
      _rangeStart = startMv.toDouble();
      _rangeEnd = startMv.toDouble();
      _verified = false;
      _errorMessage = null;
    });
    widget.appendLog(
      wasStartedOnce
          ? 'Calibration discovery reset at ${startMv}mV'
          : 'Calibration discovery started at ${startMv}mV',
    );
  }

  @override
  Widget build(BuildContext context) {
    final adcMvText = _adcMv?.toString() ?? '--';
    final adcMv = _adcMv; // ADC stream already provides mV
    return Scaffold(
      appBar: AppBar(title: const Text('ADC Calibration')),
      body: ValueListenableBuilder<bool>(
        valueListenable: widget.connectionListenable,
        builder: (context, isConnected, _) {
          final content = SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                  if (_errorMessage != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8.0),
                      child: Material(
                        color: Theme.of(context).colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.all(12.0),
                          child: Row(
                            children: [
                              Icon(
                                Icons.error,
                                color: Theme.of(context).colorScheme.error,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  _errorMessage!,
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final width = constraints.maxWidth;
                      final sliderTheme = SliderTheme.of(context);
                      final sliderEnabled = false;
                      final verificationGreen = Colors.green;
                      final sliderTrackTheme = sliderTheme.copyWith(
                        activeTrackColor: _verified
                            ? verificationGreen
                            : sliderTheme.activeTrackColor,
                        inactiveTrackColor: _verified
                            ? verificationGreen.withValues(alpha: 0.6)
                            : sliderTheme.inactiveTrackColor,
                        secondaryActiveTrackColor: _verified
                            ? verificationGreen
                            : sliderTheme.secondaryActiveTrackColor,
                        disabledActiveTrackColor: _verified
                            ? verificationGreen
                            : sliderTheme.disabledActiveTrackColor,
                        disabledInactiveTrackColor: _verified
                            ? verificationGreen.withValues(alpha: 0.6)
                            : sliderTheme.disabledInactiveTrackColor,
                      );
                      final thumbWidth =
                          sliderTheme.rangeThumbShape
                              ?.getPreferredSize(sliderEnabled, true)
                              .width ??
                          20.0;
                      final overlayWidth =
                          sliderTheme.overlayShape
                              ?.getPreferredSize(sliderEnabled, true)
                              .width ??
                          thumbWidth;
                      const edgeCalibrationPx = 1.5;
                      final horizontalInset =
                          (math.max(thumbWidth, overlayWidth) / 2) +
                          edgeCalibrationPx;
                      final usableWidth = math.max(
                        0.0,
                        width - (horizontalInset * 2),
                      );
                      final indicatorCenterX = adcMv != null
                          ? horizontalInset +
                                (adcMv.clamp(0, 3300) / 3300.0) * usableWidth
                          : null;
                      final labelLeft = indicatorCenterX == null
                          ? null
                          : ((indicatorCenterX - 30.0).clamp(
                              0.0,
                              math.max(0.0, width - 60.0),
                            )).toDouble();
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            height: 94,
                            child: Stack(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 22.0,
                                  ),
                                  child: SliderTheme(
                                    data: sliderTrackTheme.copyWith(
                                      rangeThumbShape:
                                          _CalibrationRangeThumbShape(
                                            minReady: _minHandleReady,
                                            maxReady: _maxHandleReady,
                                          ),
                                    ),
                                    child: RangeSlider(
                                      values: RangeValues(
                                        _rangeStart,
                                        _rangeEnd,
                                      ),
                                      min: 0,
                                      max: 3300,
                                      divisions: 330,
                                      labels: RangeLabels(
                                        _rangeStart.round().toString(),
                                        _rangeEnd.round().toString(),
                                      ),
                                      padding: EdgeInsets.zero,
                                      onChanged: null,
                                    ),
                                  ),
                                ),
                                if (indicatorCenterX != null)
                                  Positioned(
                                    left: indicatorCenterX - 1.0,
                                    top: 28,
                                    bottom: 28,
                                    child: Container(
                                      width: 2,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    ),
                                  ),
                                if (labelLeft != null)
                                  Positioned(
                                    left: labelLeft,
                                    top: 64,
                                    child: SizedBox(
                                      width: 60,
                                      child: Text(
                                        '$adcMvText mV',
                                        textAlign: TextAlign.center,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.labelSmall,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 0),
                          Transform.translate(
                            offset: const Offset(0, -3),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: const [Text('0 mV'), Text('3300 mV')],
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Discovered range: ${_discoveredMinMv ?? '--'} mV - ${_discoveredMaxMv ?? '--'} mV',
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Current stored calibration: ${_storedMinMv ?? '--'} mV - ${_storedMaxMv ?? '--'} mV',
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Text(
                              'Calibration steps',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '1. Move the control to the approximate middle and press:',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 6),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton.tonal(
                                onPressed: _busy || !isConnected
                                    ? null
                                    : _resetDiscoveredRange,
                                child: Text(
                                  _hasStartedOnce
                                      ? 'Reset Discovery'
                                      : 'Start Discovery',
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '2. Move the control through its full range a couple of times as new min/max values are discovered.',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '3. Press Save to write calibration. Calibration bar will turn green once the data is verified successfully.',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Expanded(
                                  child: FilledButton(
                                    onPressed:
                                        widget.sliderChar == null ||
                                            _busy ||
                                            !isConnected ||
                                            !_discoveryStarted ||
                                            _verified ||
                                        !_minHandleReady ||
                                        !_maxHandleReady
                                        ? null
                                        : _saveDiscoveredCalibration,
                                    child: Text(
                                      _verified
                                          ? 'Saved and verified'
                                          : 'Save Calibration',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                'Output scaling',
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              const Spacer(),
                              Text(
                                'Range 0-5000 mV',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          RangeSlider(
                            values: RangeValues(_outputRangeStart, _outputRangeEnd),
                            min: 0,
                            max: 5000,
                            divisions: 500,
                            labels: RangeLabels(
                              _outputRangeStart.round().toString(),
                              _outputRangeEnd.round().toString(),
                            ),
                            onChanged: widget.outputChar == null
                                ? null
                                : (r) {
                                    setState(() {
                                      _outputRangeStart = r.start;
                                      _outputRangeEnd = r.end;
                                      _outputMinController.text =
                                          _outputRangeStart.round().toString();
                                      _outputMaxController.text =
                                          _outputRangeEnd.round().toString();
                                  _outputWriteLocked = false;
                                    });
                                  },
                            onChangeEnd: widget.outputChar == null
                                ? null
                                : (r) {
                                    final min = r.start.round();
                                    final max = r.end.round();
                                    setState(() {
                                      _outputErrorMessage = min >= max
                                          ? 'Min must be less than max.'
                                          : null;
                                    });
                                  },
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _outputMinController,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                    labelText: 'Min mV',
                                  ),
                                  onChanged: (value) {
                                    if (_outputWriteLocked) {
                                      setState(() {
                                        _outputWriteLocked = false;
                                      });
                                    }
                                    final parsed = int.tryParse(value);
                                    if (parsed == null || parsed < 0 || parsed > 5000) {
                                      return;
                                    }

                                    setState(() {
                                      if (parsed < _outputRangeEnd.round()) {
                                        _outputRangeStart = parsed.toDouble();
                                        _outputErrorMessage = null;
                                      } else {
                                        _outputErrorMessage =
                                            'Min must be less than max.';
                                      }
                                    });
                                  },
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: TextField(
                                  controller: _outputMaxController,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                    labelText: 'Max mV',
                                  ),
                                  onChanged: (value) {
                                    if (_outputWriteLocked) {
                                      setState(() {
                                        _outputWriteLocked = false;
                                      });
                                    }
                                    final parsed = int.tryParse(value);
                                    if (parsed == null || parsed < 0 || parsed > 5000) {
                                      return;
                                    }

                                    setState(() {
                                      if (_outputRangeStart.round() < parsed) {
                                        _outputRangeEnd = parsed.toDouble();
                                        _outputErrorMessage = null;
                                      } else {
                                        _outputErrorMessage =
                                            'Min must be less than max.';
                                      }
                                    });
                                  },
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton.tonal(
                                  onPressed: widget.outputChar == null || _outputWriteLocked
                                      ? null
                                      : () async {
                                          final min = int.tryParse(
                                            _outputMinController.text,
                                          );
                                          final max = int.tryParse(
                                            _outputMaxController.text,
                                          );
                                          if (min == null || max == null) {
                                            setState(() {
                                              _outputErrorMessage =
                                                  'Enter valid numeric values.';
                                            });
                                            return;
                                          }
                                          if (min >= max) {
                                            setState(() {
                                              _outputErrorMessage =
                                                  'Min must be less than max.';
                                            });
                                            return;
                                          }
                                          if (min < 0 || max > 5000) {
                                            setState(() {
                                              _outputErrorMessage =
                                                  'Values must be in 0..5000 mV.';
                                            });
                                            return;
                                          }
                                          setState(() {
                                            _outputErrorMessage = null;
                                          });
                                          await widget.writeOutput?.call(
                                            min,
                                            max,
                                          );
                                          final readback =
                                              widget.readOutput != null
                                              ? await widget.readOutput!()
                                              : null;
                                          if (!mounted) return;
                                          if (readback != null) {
                                            final writeVerified =
                                                readback.minMv == min &&
                                                readback.maxMv == max;
                                            setState(() {
                                              _storedOutputMinMv =
                                                  readback.minMv;
                                              _storedOutputMaxMv =
                                                  readback.maxMv;
                                              _outputRangeStart =
                                                  readback.minMv.toDouble();
                                              _outputRangeEnd =
                                                  readback.maxMv.toDouble();
                                              _outputMinController.text =
                                                  readback.minMv.toString();
                                              _outputMaxController.text =
                                                  readback.maxMv.toString();
                                              _outputWriteLocked =
                                                  writeVerified;
                                              _outputErrorMessage = writeVerified
                                                  ? null
                                                  : 'Output scaling verify mismatch: wrote ${min}mV - ${max}mV, read back ${readback.minMv}mV - ${readback.maxMv}mV';
                                            });
                                            if (writeVerified) {
                                              widget.appendLog(
                                                'Output scaling write verified: ${min}mV - ${max}mV',
                                              );
                                            } else {
                                              widget.appendLog(
                                                'Output scaling write verification failed',
                                              );
                                            }
                                          }
                                        },
                                  child: Text(
                                    _outputWriteLocked
                                        ? 'Output Scaling Saved'
                                        : 'Write Output Scaling',
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (_outputErrorMessage != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 8.0),
                              child: Text(
                                _outputErrorMessage!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                          const SizedBox(height: 4),
                          Text(
                            'Stored output scaling: ${_storedOutputMinMv ?? '--'} mV - ${_storedOutputMaxMv ?? '--'} mV',
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_busy) const Center(child: CircularProgressIndicator()),
                ],
                ),
              ),
            ),
          );

          return AnimatedOpacity(
            opacity: isConnected ? 1.0 : 0.45,
            duration: const Duration(milliseconds: 150),
            child: IgnorePointer(ignoring: !isConnected, child: content),
          );
        },
      ),
    );
  }
}

class _CalibrationRangeThumbShape extends RangeSliderThumbShape {
  const _CalibrationRangeThumbShape({
    required this.minReady,
    required this.maxReady,
  });

  final bool minReady;
  final bool maxReady;
  static const double _enabledThumbRadius = 10;
  static const double _disabledThumbRadius = 10;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) {
    final radius = isEnabled ? _enabledThumbRadius : _disabledThumbRadius;
    return Size.fromRadius(radius);
  }

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    bool isDiscrete = false,
    bool isEnabled = false,
    bool isOnTop = false,
    TextDirection textDirection = TextDirection.ltr,
    required SliderThemeData sliderTheme,
    Thumb thumb = Thumb.start,
    bool isPressed = false,
  }) {
    final isCompleted = thumb == Thumb.start ? minReady : maxReady;
    final pendingColor =
        sliderTheme.disabledThumbColor ?? Colors.grey.withValues(alpha: 0.9);
    final completedColor = Colors.green;
    final color = isCompleted ? completedColor : pendingColor;

    final radius = Tween<double>(
      begin: _disabledThumbRadius,
      end: _enabledThumbRadius,
    ).evaluate(enableAnimation);

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    context.canvas.drawCircle(center, radius, paint);

    if (isOnTop) {
      final outlinePaint = Paint()
        ..color = sliderTheme.overlappingShapeStrokeColor ?? Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;
      context.canvas.drawCircle(center, radius, outlinePaint);
    }
  }
}

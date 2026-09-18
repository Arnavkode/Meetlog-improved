import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:wear_os/config/app_env.dart';
import 'package:wear_os/globals.dart' as globals;
import 'package:wear_os/util/loggingclient.dart';

class Recog extends StatefulWidget {
  const Recog({super.key});

  @override
  State<Recog> createState() => _RecogState();
}

class DataPoint {
  final DateTime ts;
  final List<dynamic> values; // the rest of your accel/gyro fields

  DataPoint(this.ts, this.values);
}

class _RecogState extends State<Recog> {
  bool isPredicting = false;

  Map<String, dynamic>? ShowWatch;
  List<dynamic>? ShowEsense;
  DateTime? CurrentTime;

  var client = LoggingClient();
  // Queues for raw incoming:
  final List<DataPoint> watchQueue = [];
  final List<DataPoint> esenseQueue = [];

  // Aligned rows ready to write:
  final List<List<dynamic>> alignedBuffer = [];

  static const int kAlignmentThresholdMs = 40;
  static const int kBatchSize = 1;

  // … rest of your fields

// TO ADD TO QUEUES
  Timer? bufferTimer;
  void addToWatchBuffer(dynamic latestWatchData) {
    // 1) Make sure it’s even a Map
    if (latestWatchData == null || latestWatchData is! Map) {
      print('Error: not a Map');
      return;
    }

    // 2) Parse the timestamp (string here)
    final rawTs = latestWatchData['Timestamp'];
    if (rawTs == null) {
      print('Error: missing Timestamp');
      return;
    }
    final ts = DateTime.parse(rawTs.toString());

    // 3) Pull out each sensor map as a raw Map
    final accelRaw = latestWatchData['accelerometer'];
    final gyroRaw = latestWatchData['gyroscope'];

    if (accelRaw is! Map || gyroRaw is! Map) {
      print('Error: one of the sensor entries isn’t a Map');
      return;
    }

    // 4) Cast them into a Map<String,dynamic>
    final accel = (accelRaw as Map).cast<String, dynamic>();
    final gyro = (gyroRaw as Map).cast<String, dynamic>();

    // 5) Flatten into doubles
    final data = <double>[
      (accel['x'] as num).toDouble(),
      (accel['y'] as num).toDouble(),
      (accel['z'] as num).toDouble(),
      (gyro['x'] as num).toDouble(),
      (gyro['y'] as num).toDouble(),
      (gyro['z'] as num).toDouble(),
    ];

    // 6) Enqueue your DataPoint
    final dp = DataPoint(ts, data);
    watchQueue.add(dp);
    _tryAlign();
  }

  double toDouble(dynamic e) {
    if (e is num) {
      // covers both int and double
      return e.toDouble();
    } else if (e is String) {
      // in case it comes in as a numeric string
      return double.parse(e);
    } else {
      throw ArgumentError('Cannot convert $e (${e.runtimeType}) to double');
    }
  }

  void addToEsenseBuffer(List<dynamic> latestEsenseData) {
    print('Adding to esense buffer: $latestEsenseData');
    if (latestEsenseData == null || latestEsenseData.isEmpty) {
      print('Error: latestEsenseData is null or empty');
      return;
    }
    final timestamp = DateTime.fromMillisecondsSinceEpoch(latestEsenseData[0]);
    if (timestamp == null) {
      print('Error: unable to convert timestamp to DateTime');
      return;
    }

    final data = <double>[
      (latestEsenseData[1] as num).toDouble(),
      (latestEsenseData[2] as num).toDouble(),
      (latestEsenseData[3] as num).toDouble(),
      (latestEsenseData[4] as num).toDouble(),
      (latestEsenseData[5] as num).toDouble(),
      (latestEsenseData[6] as num).toDouble(),
    ];
    final dp = DataPoint(timestamp, data);
    print('Created DataPoint: $dp');
    esenseQueue.add(dp);
    print('Added to esense queue: $dp');
    _tryAlign();
  }

  int lengthleft = 0;
  void _tryAlign() {
    if (watchQueue.isEmpty || esenseQueue.isEmpty) return;

    print("GOT DATA IN BUFFERS");
    int? matchedWatchIndex;
    int? matchedEsenseIndex;

    for (int i = 0; i < watchQueue.length; i++) {
      final wdp = watchQueue[i];
      for (int j = 0; j < esenseQueue.length; j++) {
        final edp = esenseQueue[j];
        final diffMs = wdp.ts.difference(edp.ts).inMilliseconds.abs();

        if (diffMs <= kAlignmentThresholdMs) {
          print("esense values : ${edp.values}");
          final row = <dynamic>[
            // ++num,
            // dateFormatWithMs.format(DateTime.now()),
            // wdp.ts,
            wdp.values[0],
            wdp.values[1],
            wdp.values[2],
            wdp.values[3],
            wdp.values[4],
            wdp.values[5],
            // edp.ts,
            ...edp.values,
          ];
          final Datarow = <double>[
            // ++num,
            // dateFormatWithMs.format(DateTime.now()),
            // wdp.ts,
            wdp.values[0],
            wdp.values[1],
            wdp.values[2],
            wdp.values[3],
            wdp.values[4],
            wdp.values[5],
            // edp.ts,
            ...edp.values,
          ];
          alignedBuffer.add(row);

          print('About to add to InputWindow; row is: $row');
          print('Types: ${row.map((e) => e.runtimeType).toList()}');
          try {
            InputWindow?.add(Datarow);
          } catch (e, st) {
            print('Cast failed here: $e\n$st');
            rethrow;
          }

          print("✨✨✨✨");
          print("window size: ${InputWindow!.length}");
          if (InputWindow!.length >= 50) {
            setState(() => lengthleft = 0);
            print("👍👍Buffer filled");

            _runInference(InputWindow!);

            print("Got  prediction❤️‍🔥");

            InputWindow?.clear();
          }
          setState(() {
            lengthleft++;
          });

          matchedWatchIndex = i;
          matchedEsenseIndex = j;
          break;
        }
      }
      if (matchedWatchIndex != null && matchedEsenseIndex != null) break;
    }

    if (matchedWatchIndex != null && matchedEsenseIndex != null) {
      watchQueue.removeAt(matchedWatchIndex);
      esenseQueue.removeAt(matchedEsenseIndex);
      if (alignedBuffer.length >= kBatchSize) _flushAlignedBuffer();
    }

    // Remove stale entries
    final cutoff = DateTime.now().subtract(Duration(seconds: 2));
    watchQueue.removeWhere((d) => d.ts.isBefore(cutoff));
    esenseQueue.removeWhere((d) => d.ts.isBefore(cutoff));
  }

  Future<void> _runInference(List<List<double>> batch) async {
    print("🚀 _runInference started");

    try {
      // if you have any prep (e.g. startPredicting), do it here

      print("   • startPredicting done, now awaiting runWithSummaries…");

      final prediction = await runAndExtractLabelAndProbs(_session, batch);

      // use debugPrint for very long lists so they're not truncated
    } catch (e, st) {
      print("❌ _runInference error: $e\n$st");
    } finally {
      print("✅ _runInference finished");
    }
  }

  List<dynamic> alignedRow = [];

  void _flushAlignedBuffer() {
    print(
        '🧪 Buffer Snapshot | watch: ${watchQueue.length} | esense: ${esenseQueue.length}');
    print(
        '🔍 Next watch sample: ${watchQueue.isNotEmpty ? watchQueue.first : 'EMPTY'}');
    print(
        '🔍 Next esense sample: ${esenseQueue.isNotEmpty ? esenseQueue.first : 'EMPTY'}');
    print("🟨 flushAlignedBuffers called");
    while (alignedBuffer.isNotEmpty) {
      alignedRow = alignedBuffer.removeAt(0);
    }
  }

  late final OrtSession _session;

  bool _modelLoaded = false;

  Future<void> _loadModel() async {
    // 1. Init the runtime (once)
    OrtEnv.instance.init();

    // 2. Load the bytes from assets
    final raw = await rootBundle.load('assets/xgb_model_prob.onnx');
    final bytes = raw.buffer.asUint8List();

    // 3. Create the session
    final opts = OrtSessionOptions();
    _session = OrtSession.fromBuffer(bytes, opts);
    _modelLoaded = true;

    print("Model loaded");
  }

  @override
  void dispose() {
    bufferTimer?.cancel();
    _stopReportPolling(reason: 'widget dispose');
    OrtEnv.instance.release();
    super.dispose();
  }

  List<double> _computeFeatureSummaries(List<List<double>> data) {
    final int n = data.length;
    if (n == 0) return [];
    final int d = data[0].length;
    if (d != 12) {
      throw ArgumentError('Expected 12 features per row, got $d');
    }

    final List<double> flat = [];
    for (var j = 0; j < d; j++) {
      // extract column j
      final col = <double>[for (var row in data) row[j]];
      // mean
      final mean = col.reduce((a, b) => a + b) / n;
      // std (sample)
      final varSum =
          col.map((x) => (x - mean) * (x - mean)).reduce((a, b) => a + b);
      final std = sqrt(varSum / (n - 1));
      // min & max
      final minVal = col.reduce(min);
      final maxVal = col.reduce(max);
      // median
      col.sort();
      final median =
          (n % 2 == 1) ? col[n ~/ 2] : (col[(n ~/ 2) - 1] + col[n ~/ 2]) / 2;

      flat.addAll([mean, std, minVal, maxVal, median]);
    }
    return flat; // length == 12 * 5 = 60
  }

  List<double>? predictedProbabilities;

  Future<void> runAndExtractLabelAndProbs(
    OrtSession session,
    List<List<double>> data50x12,
  ) async {
    // a) Summarize → flat 60-vector
    final input60 = _computeFeatureSummaries(data50x12);

    // b) Build a float32 tensor [1,60]
    final floatInput = Float32List.fromList(input60);
    final tensor = OrtValueTensor.createTensorWithDataList(
      floatInput,
      [1, input60.length],
    );

    // c) Run synchronously (avoids runAsync hangs on some platforms)
    final outputs = session.run(
      OrtRunOptions(),
      {session.inputNames.first: tensor},
    );

    // d) Extract the two outputs by position
    final OrtValue? labelOrt = outputs.length > 0 ? outputs[0] : null;
    final OrtValue? probOrt = outputs.length > 1 ? outputs[1] : null;

    if (labelOrt == null) {
      print('❌ No label output from model');
    } else {
      // 1️⃣ Parse label
      final rawLabel = labelOrt.value;
      int label;
      if (rawLabel is Int64List) {
        label = rawLabel[0];
      } else if (rawLabel is List) {
        label = (rawLabel as List).cast<int>()[0];
      } else {
        throw StateError('Unexpected label type: ${rawLabel.runtimeType}');
      }

      // 2️⃣ Parse probabilities
      List<double> probs = [];
      if (probOrt != null) {
        final rawProb = probOrt.value;
        if (rawProb is Float32List) {
          probs = rawProb.toList();
        } else if (rawProb is List) {
          // could be List<double> or List<List<double>>
          if (rawProb.isEmpty) {
            probs = [];
          } else if (rawProb.first is num) {
            probs = rawProb.cast<num>().map((e) => e.toDouble()).toList();
          } else if (rawProb.first is List) {
            probs = <double>[];
            for (final row in (rawProb as List)) {
              probs.addAll((row as List).cast<num>().map((e) => e.toDouble()));
            }
          } else {
            throw StateError(
                'Unexpected prob element type: ${rawProb.first.runtimeType}');
          }
        } else {
          throw StateError(
              'Unexpected probabilities type: ${rawProb.runtimeType}');
        }
      }

      probs = toProbabilities(probs);

      int maxidx = 0;
      double maxvalue = 0;
      for (int i = 0; i < probs.length; i++) {
        if (probs[i] > maxvalue) {
          maxidx = i;
          maxvalue = probs[i];
        }
      }
      // 3️⃣ Update your state (or local variables) with both values
      setState(() {
        if (maxvalue > 0.5) {
          //threshold
          predictedLabel = Activity_classes[maxidx];
          nativeAttentionStatus = LABEL_TO_ATTENTION[maxidx];
        } else {
          predictedLabel = "Transition";
        }

        predictedProbabilities = probs;
      });

      if (nativeAttentionStatus != oldnativeAttentionStatus) {
        oldnativeAttentionStatus = nativeAttentionStatus;

        try {
          final resp = await client.post(
            AppEnv.attentionUri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'user_id': globals.Model,
              'attention_status': nativeAttentionStatus,
            }),
          );
          print("[SENT] ${nativeAttentionStatus} → ${resp.statusCode}");
        } catch (e, st) {
          print("❌ post failed: $e\n$st");
        }
        print("[SENT] message : $nativeAttentionStatus");
      }
      else{
        try {
    // 1) No body at all → sends Content-Length: 0
    final resp = await client.post(
            AppEnv.attentionPokeUri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'user_id': globals.Model,
            }),
          );
    print('Poke sent, status code: ${resp.statusCode}');
  } catch (e) {
    // swallow or log errors if you truly just want “fire-and-forget”
    print('Poke failed (ignored): $e');
  }

      }
      // 4️⃣ Print for debug
      print('🏷️ Predicted label: $label');
      print('📊 Probabilities: $probs');
    }

    // e) Clean up native buffers
    tensor.release();
    for (final v in outputs) {
      v?.release();
    }
  }

  List<double> toProbabilities(List<double> logits) {
    final exps = logits.map((x) => math.exp(x)).toList();
    final sumExp = exps.reduce((a, b) => a + b);
    return exps.map((e) => e / sumExp).toList();
  }

//NATIVE VARIABLES

  String? predictedLabel;
  String? nativeAttentionStatus = "first";
  String? oldnativeAttentionStatus = "first";

  List<List<double>>? InputWindow = [];
  List<List<double>>? Input1 = [];
  List<List<double>>? Input2 = [];
  Timer? PredictionTimer;
  String? labelPredicted;
  double? confidencePredicted;
  int Windowsize = 50;
  List<double>? _prediction;

  // ignore: non_constant_identifier_names
  List<String> Activity_classes = [
    "Sitting + Typing on Desk",
    "Sitting + Taking Notes",
    "Standing + Writing on Whiteboard",
    "Standing + Erasing Whiteboard",
    "Sitting + Talking + Waving Hands",
    "Standing + Talking + Waving Hands",
    "Sitting + Drinking Water",
    "Sitting + Drinking Coffee",
    "Standing + Drinking Water",
    "Standing + Drinking Coffee",
    "Scrolling on Phone",
  ];

  Map<int, String> LABEL_TO_ATTENTION = {
    0: "attentive",
    1: "attentive",
    2: "attentive",
    3: "attentive",
    4: "attentive",
    5: "attentive",
    6: "attentive",
    7: "distracted",
    8: "distracted",
    9: "distracted",
    10: "distracted",
    11: "distracted"
  };

  String predictedActivity = "Null";
// int maxidx = 0;
  int _max = 0;
  String? _attentionStatus;

  DeviceInfoPlugin? devicePlugin;
  AndroidDeviceInfo? info;

  void initState() {
    super.initState();
    initAsync();
  }

  void initAsync() async {
    _loadModel();
    devicePlugin = await DeviceInfoPlugin();
    info = await devicePlugin?.androidInfo;
    globals.Model = info!.model;
  }

  double? attentionPercent;
  String? finalSuggestion;
  Uint8List? finalReportGraphBytes;
  DateTime? finalReportTimestamp;
  bool isFinalReportLoading = false;
  String? finalReportError;
  int reportRefreshMinutes = 1;
  Timer? reportRefreshTimer;
  bool _isReportPollingActive = false;
  bool _isReportRequestInFlight = false;
  int _pollTickCounter = 0;

  Future<void> onStopPredicting() async {
    debugPrint(
      '[POLL][STOP] Stop pressed at ${DateTime.now().toIso8601String()}.',
    );
    _stopReportPolling(reason: 'stop button pressed');
    setState(() {
      ShowEsense = null;
      ShowWatch = null;
      isFinalReportLoading = true;
      finalReportError = null;
    });
    if (InputWindow!.isNotEmpty) InputWindow!.clear();
    lengthleft = 0;
    predictedActivity = "null";
    _attentionStatus = null;
    _prediction = null;
    nativeAttentionStatus = "null";
    oldnativeAttentionStatus = "null";
    predictedLabel = null;
    bufferTimer?.cancel();

    await _fetchAndStoreFinalReport(source: 'stop-button-end-meeting', finalizeMeeting: true);
    _stopReportPolling(reason: 'stop button safety guard');
    Fluttertoast.showToast(msg: "Predicting stopped");
  }

  Future<int?> _askReportIntervalMinutes() async {
    final controller = TextEditingController(text: reportRefreshMinutes.toString());
    bool adjusted = false;
    final selected = await showDialog<int>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setLocalState) {
            final raw = controller.text.trim();
            final parsed = double.tryParse(raw);
            final preview = _sanitizeIntervalMinutes(raw);
            final bool isInvalid = raw.isNotEmpty && parsed == null;
            final bool isBelowMinimum = parsed != null && parsed < 1;
            final bool hasDecimal = parsed != null && parsed != parsed.roundToDouble();

            return AlertDialog(
              title: const Text('Report refresh interval'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: controller,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    onChanged: (_) => setLocalState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Minutes',
                      hintText: '1',
                      helperText: 'Minimum 1 minute. Decimals are rounded.',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "Will use: $preview minute${preview == 1 ? '' : 's'}",
                    style: const TextStyle(color: Colors.white70),
                  ),
                  if (isInvalid)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                        'Invalid value. Defaulting to 1 minute.',
                        style: TextStyle(color: Color(0xFFFF9A9A), fontSize: 12),
                      ),
                    ),
                  if (isBelowMinimum)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                        'Minimum allowed is 1 minute.',
                        style: TextStyle(color: Color(0xFFFFC266), fontSize: 12),
                      ),
                    ),
                  if (hasDecimal)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                        'Decimal input will be rounded to nearest minute.',
                        style: TextStyle(color: Color(0xFFFFC266), fontSize: 12),
                      ),
                    ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    adjusted = _isInputAdjusted(controller.text, preview);
                    Navigator.of(ctx).pop(preview);
                  },
                  child: const Text('Start'),
                ),
              ],
            );
          },
        );
      },
    );

    if (selected != null && adjusted) {
      Fluttertoast.showToast(
        msg: "Interval adjusted to $selected minute${selected == 1 ? '' : 's'} (minimum 1).",
      );
    }

    return selected;
  }

  int _sanitizeIntervalMinutes(String raw) {
    final parsed = double.tryParse(raw.trim()) ?? 1.0;
    final rounded = parsed.round();
    return rounded < 1 ? 1 : rounded;
  }

  bool _isInputAdjusted(String raw, int sanitized) {
    final parsed = double.tryParse(raw.trim());
    if (parsed == null) {
      return true;
    }
    return parsed < 1 || parsed != parsed.roundToDouble() || sanitized != parsed.round();
  }

  void _startPeriodicFinalReportRefresh() {
    _stopReportPolling(reason: 'restart');
    _isReportPollingActive = true;
    _pollTickCounter = 0;
    debugPrint(
      '[POLL][START] interval=${reportRefreshMinutes}m at ${DateTime.now().toIso8601String()}',
    );
    _pollFinalReportTick(source: 'initial-start');
    reportRefreshTimer = Timer.periodic(
      Duration(minutes: reportRefreshMinutes),
      (timer) {
        _pollFinalReportTick(source: 'timer-${timer.tick}');
      },
    );
  }

  void _stopReportPolling({required String reason}) {
    if (reportRefreshTimer != null || _isReportPollingActive) {
      debugPrint(
        '[POLL][STOP] reason=$reason at ${DateTime.now().toIso8601String()}',
      );
    }
    reportRefreshTimer?.cancel();
    reportRefreshTimer = null;
    _isReportPollingActive = false;
  }

  Future<void> _pollFinalReportTick({required String source}) async {
    if (!_isReportPollingActive) {
      debugPrint('[POLL][SKIP][$source] inactive');
      return;
    }
    if (!isPredicting) {
      debugPrint('[POLL][SKIP][$source] isPredicting=false');
      return;
    }
    if (_isReportRequestInFlight) {
      debugPrint('[POLL][SKIP][$source] previous request in-flight');
      return;
    }

    _isReportRequestInFlight = true;
    _pollTickCounter += 1;
    debugPrint(
      '[POLL][TICK][$source] #$_pollTickCounter at ${DateTime.now().toIso8601String()}',
    );
    try {
      await _fetchAndStoreFinalReport(source: source, finalizeMeeting: false);
    } finally {
      _isReportRequestInFlight = false;
    }
  }

  Future<void> _fetchAndStoreFinalReport({
    required String source,
    bool finalizeMeeting = false,
  }) async {
    final reportUri = finalizeMeeting
        ? AppEnv.endMeetingUri
        : AppEnv.liveReportUri;

    final String reportMode = finalizeMeeting ? 'final' : 'live';

    debugPrint('[POLL][API][$source] POST $reportUri mode=$reportMode');

    setState(() {
      // Avoid flashing a spinner on every live poll once a report is already visible.
      if (finalizeMeeting || finalReportTimestamp == null) {
        isFinalReportLoading = true;
      }
      finalReportError = null;
    });

    try {
      final resp = await client.post(
        reportUri,
        headers: {
          'Content-Type': 'application/json',
          'Cache-Control': 'no-cache',
          'Pragma': 'no-cache',
        },
        body: jsonEncode({'user_id': globals.Model}),
      );

      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        debugPrint('[POLL][API][$source] status=${resp.statusCode}');
        throw Exception('Report request failed with status ${resp.statusCode}');
      }

      final response = jsonDecode(resp.body);
      final dynamic rawPercent = response['attentive_percent'];
      final double? parsedPercent = (rawPercent is num)
          ? rawPercent.toDouble()
          : double.tryParse(rawPercent?.toString() ?? '');
      final String suggestion = (response['suggestion'] ?? '').toString();
      final String graphRaw = (response['graph'] ?? '').toString();

      Uint8List? imageBytes;
      if (graphRaw.isNotEmpty) {
        final String base64String = graphRaw.contains(',')
            ? graphRaw.split(',').last
            : graphRaw;
        imageBytes = base64Decode(base64String);
      }

      setState(() {
        attentionPercent = parsedPercent;
        finalSuggestion = suggestion.isEmpty ? null : suggestion;
        finalReportGraphBytes = imageBytes;
        finalReportTimestamp = DateTime.now();
        isFinalReportLoading = false;
      });

      debugPrint(
        '[POLL][API][$source] success at ${finalReportTimestamp?.toIso8601String()} '
        'mode=$reportMode',
      );
    } catch (e) {
      setState(() {
        isFinalReportLoading = false;
        finalReportError = e.toString();
      });
      debugPrint('[POLL][API][$source] error=$e');
    }
  }


  Future<void> toggleStart() async {
    if (!isPredicting) {
      debugPrint('[PREDICT][TOGGLE] Start requested');
      final selectedInterval = await _askReportIntervalMinutes();
      if (selectedInterval == null) {
        debugPrint('[PREDICT][TOGGLE] Start cancelled');
        return;
      }
      setState(() {
        reportRefreshMinutes = selectedInterval;
        isPredicting = true;
        finalSuggestion = null;
        finalReportGraphBytes = null;
        finalReportTimestamp = null;
        finalReportError = null;
      });
      debugPrint(
        '[PREDICT][TOGGLE] Start confirmed with interval=${reportRefreshMinutes}m',
      );
      await onStart();
      return;
    }

    debugPrint('[PREDICT][TOGGLE] Stop requested');
    setState(() {
      isPredicting = false;
    });
    await onStopPredicting();
  }

  Future<void> onStart() async {
    _stopReportPolling(reason: 'new start request');
    Fluttertoast.showToast(msg: "Prediction started");

    debugPrint("BUFFERS TO BE STARTED BEING FILLED");
    predictedProbabilities = null;
    initIMU();
    try {
      debugPrint('[PREDICT][START] POST ${AppEnv.startMeetingUri}');
      final resp = await client.post(
        AppEnv.startMeetingUri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'user_id': globals.Model}),
      );
      debugPrint('[PREDICT][START] status=${resp.statusCode}');
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        debugPrint(
          '[PREDICT][START] start_meeting success. Starting poller now.',
        );
        _startPeriodicFinalReportRefresh();
      } else {
        debugPrint(
          '[PREDICT][START] start_meeting non-2xx. Poller not started.',
        );
      }
    } catch (e, st) {
      debugPrint('[PREDICT][START] failed=$e');
      debugPrint('$st');
    }
  }

  void initIMU() {
    bufferTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      try {
        setState(() {
          ShowWatch = globals.globallatestWatchData;
          ShowEsense = globals.gloaballatestEsenseData;
          CurrentTime = DateTime.now();
        });

        // void AddToBuffer
        if (globals.globallatestWatchData.isNotEmpty) {
          addToWatchBuffer(globals.globallatestWatchData);
        }

        if (globals.gloaballatestEsenseData.isNotEmpty) {
          addToEsenseBuffer(globals.gloaballatestEsenseData);
        }
      } catch (e, st) {
        print("Error in buffer loop: $e\n$st");
      }
    });
  }

  // ignore: unused_element
  Future<void> showSuggestion(
    BuildContext context,
    String message,
    Uint8List ImageBytes
  ) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Suggestion Dialog',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (ctx, anim1, anim2) => Center(
        child: SingleChildScrollView(
          child: Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(ctx).size.width - 24,
                maxHeight: MediaQuery.of(ctx).size.height - 80,
              ),
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF10182B), Color(0xFF0C1224)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white12),
                boxShadow: const [
                  BoxShadow(color: Colors.black54, blurRadius: 30, offset: Offset(0, 18), spreadRadius: -16),
                  BoxShadow(color: Color(0x445CA9FF), blurRadius: 18, offset: Offset(0, 12), spreadRadius: -10),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.tips_and_updates, color: Colors.white70),
                      const SizedBox(width: 10),
                      const Text('Session Summary',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.2)),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white70),
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
                    decoration: BoxDecoration(
                      color: const Color(0x225CA9FF),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Text(
                      'Attention Percent: ${attentionPercent != null ? '$attentionPercent %' : 'Nothing predicted'}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w700, letterSpacing: 0.2),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white10,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Text(
                      'Suggestion: $message',
                      style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.4),
                    ),
                  ),
                  const SizedBox(height: 14),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      color: Colors.black,
                      child: Image.memory(ImageBytes, fit: BoxFit.contain),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        backgroundColor: const Color(0xFF5CA9FF),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('Close', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      transitionBuilder: (ctx, anim, secAnim, child) {
        final fade = CurvedAnimation(parent: anim, curve: Curves.easeOut);
        final scale = CurvedAnimation(parent: anim, curve: Curves.elasticOut);
        return FadeTransition(
          opacity: fade,
          child: ScaleTransition(
            scale: scale,
            child: child,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    const bgColor = Color(0xFF0A0F1F);
    const textColor = Colors.white;
    const skyBlue = Color(0xFF5CA9FF);

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF0A0F1F), Color(0xFF0E1326)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: const [
                          Icon(Icons.insights_outlined, color: skyBlue, size: 28),
                          SizedBox(width: 10),
                          Text('Recognition Panel',
                              style: TextStyle(
                                  color: textColor,
                                  fontSize: 24,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.3)),
                        ],
                      ),
                      const SizedBox(height: 22),

                      _RecogCard(
                        child: Center(
                          child: _metaRow(
                            'Predicted (native model)',
                            predictedLabel ?? '--',
                            alignCenter: true,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _RecogCard(
                              child: _metaRow(
                                  'Native Attention Status', nativeAttentionStatus ?? '--'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _RecogCard(
                              child: _metaRow(
                                  'Attention Percent',
                                  attentionPercent != null ? '$attentionPercent %' : 'Nothing predicted'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _RecogCard(
                              child: _metaRow('Window Size', '$lengthleft'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _RecogCard(
                              child: _metaRow('Latency Tolerance', '$kAlignmentThresholdMs ms'),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 12),
                      _RecogCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Probabilities',
                                style: TextStyle(
                                    color: Colors.white70,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13)),
                            const SizedBox(height: 6),
                            Container(
                              height: 120,
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.white10),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              padding: const EdgeInsets.all(10),
                              child: SingleChildScrollView(
                                child: Text(
                                  predictedProbabilities?.toString() ?? '--',
                                  style: const TextStyle(color: textColor),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 16),
                      Center(
                        child: _PrimaryActionButton(
                          isActive: isPredicting,
                          onPressed: () {
                            toggleStart();
                          },
                        ),
                      ),
                      const SizedBox(height: 12),
                      _RecogCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Session Summary',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 16,
                                letterSpacing: 0.2,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
                              decoration: BoxDecoration(
                                color: const Color(0x225CA9FF),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: Colors.white24),
                              ),
                              child: Text(
                                'Attention Percent: ${attentionPercent != null ? '$attentionPercent %' : 'Nothing predicted'}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.2,
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: Colors.white10,
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: Colors.white12),
                              ),
                              child: Text(
                                'Suggestion: ${finalSuggestion ?? 'Waiting for report...'}',
                                style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.4),
                              ),
                            ),
                            const SizedBox(height: 12),
                            if (isFinalReportLoading)
                              const Center(
                                child: Padding(
                                  padding: EdgeInsets.symmetric(vertical: 16),
                                  child: CircularProgressIndicator(strokeWidth: 2.2),
                                ),
                              ),
                            if (finalReportError != null)
                              Text(
                                'Report Error: $finalReportError',
                                style: const TextStyle(color: Color(0xFFFF9A9A)),
                              ),
                            if (finalReportGraphBytes != null) ...[
                              ClipRRect(
                                borderRadius: BorderRadius.circular(14),
                                child: Container(
                                  color: Colors.black,
                                  child: Image.memory(finalReportGraphBytes!, fit: BoxFit.contain),
                                ),
                              ),
                            ] else if (!isFinalReportLoading) ...[
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  border: Border.all(color: Colors.white12),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Text(
                                  'No report graph available yet.',
                                  style: TextStyle(color: Colors.white70),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      _RecogCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Live Data',
                                style: TextStyle(
                                    color: Colors.white70,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13)),
                            const SizedBox(height: 6),
                            Container(
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.white10),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              padding: const EdgeInsets.all(10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Watch: ${ShowWatch.toString()}',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(color: textColor)),
                                  const SizedBox(height: 6),
                                  Text('eSense: ${ShowEsense?.toString() ?? 'No data'}',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(color: textColor)),
                                ],
                              ),
                            ),
                            const SizedBox(height: 10),
                            _metaRow('Current Time', CurrentTime?.toIso8601String() ?? '--'),
                            const SizedBox(height: 6),
                            _metaRow('Model Name', globals.Model ?? '--'),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecogCard extends StatelessWidget {
  const _RecogCard({Key? key, required this.child}) : super(key: key);
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF10182B), Color(0xFF0C1224)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white12),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 22, offset: Offset(0, 14), spreadRadius: -12),
          BoxShadow(color: Color(0x445CA9FF), blurRadius: 14, offset: Offset(0, 8), spreadRadius: -10),
        ],
      ),
      child: child,
    );
  }
}

Widget _metaRow(String label, String value, {bool alignCenter = false}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label,
          style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      Text(
        value,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        textAlign: alignCenter ? TextAlign.center : TextAlign.start,
        style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700),
      ),
    ],
  );
}

class _PrimaryActionButton extends StatelessWidget {
  const _PrimaryActionButton({Key? key, required this.isActive, required this.onPressed}) : super(key: key);

  final bool isActive;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final List<Color> colors = isActive
        ? [const Color(0xFFF06969), const Color(0xFFC73636)]
        : [const Color(0xFF69F079), const Color(0xFF36C978)];

    return SizedBox(
      width: 160,
      height: 56,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          elevation: 0,
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
        ),
        onPressed: onPressed,
        child: Ink(
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
            borderRadius: BorderRadius.circular(18),
            boxShadow: const [
              BoxShadow(color: Color(0x885CA9FF), blurRadius: 12, offset: Offset(0, 8), spreadRadius: -4),
            ],
          ),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(isActive ? Icons.stop_rounded : Icons.play_arrow_rounded,
                    color: Colors.white, size: 22),
                const SizedBox(width: 8),
                Text(isActive ? 'Stop' : 'Start',
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w700, letterSpacing: 0.3, fontSize: 15)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}



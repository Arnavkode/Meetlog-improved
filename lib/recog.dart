import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:http/http.dart' as http;
import 'package:onnxruntime/onnxruntime.dart';
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

  void dispose() {
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
            Uri.parse("http://10.6.0.56:8888/attention"),
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
            Uri.parse("http://10.6.0.56:8888/attention_poke"),
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

  void onStopPredicting() async {
    setState(() {
      ShowEsense = null;
      ShowWatch = null;
    });
    if (InputWindow!.isNotEmpty) InputWindow!.clear();
    lengthleft = 0;
    predictedActivity = "null";
    _attentionStatus = null;
    _prediction = null;
    nativeAttentionStatus = "null";
    oldnativeAttentionStatus = "null";
    predictedLabel = null;
    attentionPercent = null;
    bufferTimer?.cancel();

    final resp = await client.post(
      Uri.parse("http://10.6.0.56:8888/end_meeting"),
      headers: {
        'Content-Type': 'application/json',
        'Cache-Control': 'no-cache',
        'Pragma': 'no-cache',
      },
      body: jsonEncode({'user_id': globals.Model}),
    );
    final response = jsonDecode(resp.body);
    print("⬇️⬇️⬇️⬇️ $response['attentive_percent']");
    String base64string = response['graph'].split(',').last;
    Uint8List Imagebytes = base64Decode(base64string);

    setState(() {
      attentionPercent = response['attentive_percent'];
    });
    // watchBuffer.clear();
    // esenseBuffer.clear();
    Fluttertoast.showToast(msg: "Predicting stopped");

    if (response != null) {
      showSuggestion(context, response["suggestion"], Imagebytes);
    }
  }

  void toggleStart() {
    if (isPredicting == false) {
      isPredicting = true;
      onStart();
    } else if (isPredicting == true) {
      isPredicting = false;
      onStopPredicting();
    }
  }

  void onStart() async {
    Fluttertoast.showToast(msg: "Prediction started");

    print("BUFFERS TO BE STARTED BEING FILLED");
    predictedProbabilities = null;
    initIMU();
    try {
          final resp = await client.post(
            Uri.parse("http://10.6.0.56:8888/start_meeting"),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'user_id': globals.Model
            }),
          );
          print("[SENT] ${nativeAttentionStatus} → ${resp.statusCode}");
        } catch (e, st) {
          print("❌ post failed: $e\n$st");
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
            insetPadding: const EdgeInsets.all(5),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(ctx).size.width - 20,
                maxHeight: MediaQuery.of(ctx).size.height - 100,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Top bar with close button
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.only(right: 4, top: 4),
                    child: Align(
                      alignment: Alignment.topRight,
                      child: IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ),
                  ),

                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(16.0), // inner spacing
                    decoration: BoxDecoration(
                      color: Colors.white, // background color
                      border: Border.all(
                        color: const Color.fromARGB(
                            255, 242, 40, 195), // outline color
                        width: 2.0, // outline thickness
                      ),
                      borderRadius: BorderRadius.circular(
                          12), // circular corners (12px radius)
                    ),
                    child: Text(
                      'Attention Percent: ${"$attentionPercent %" ?? "Nothing predicted"}',
                      style: TextStyle(
                          color: const Color.fromARGB(255, 242, 40, 195)),
                    ),
                  ),
                  SizedBox(
                    height: 20,
                  ),

                  // Your scrollable message
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        children: [
                          Text(
                            "Suggestion: $message",
                            style: const TextStyle(fontSize: 15),
                          ),
                          SizedBox(height: 8,),
                          Image.memory(ImageBytes, fit: BoxFit.contain,)
                        ],
                      ),
                    ),
                  ),
                  

                  const SizedBox(height: 16),

                  // Optional OK button
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('Close'),
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
    return SafeArea(
        child: Column(
      children: [
        SizedBox(
          height: 20,
        ),
        Container(
          padding: const EdgeInsets.all(16.0), // inner spacing
          decoration: BoxDecoration(
            color: Colors.white, // background color
            border: Border.all(
              color: Colors.purple, // outline color
              width: 2.0, // outline thickness
            ),
            borderRadius:
                BorderRadius.circular(12), // circular corners (12px radius)
          ),
          child: Column(
            children: [
              Text(
                "Predicted (native model) : ${predictedLabel} ",
                style: TextStyle(color: Colors.purple),
              )
            ],
          ),
        ),
        SizedBox(
          height: 20,
        ),
        Container(
          padding: const EdgeInsets.all(16.0), // inner spacing
          decoration: BoxDecoration(
            color: Colors.white, // background color
            border: Border.all(
              color: const Color.fromARGB(255, 39, 98, 176), // outline color
              width: 2.0, // outline thickness
            ),
            borderRadius:
                BorderRadius.circular(12), // circular corners (12px radius)
          ),
          child: Column(
            children: [
              Text(
                "Native Attention Status : ${nativeAttentionStatus}",
                style:
                    TextStyle(color: const Color.fromARGB(255, 39, 117, 176)),
              )
            ],
          ),
        ),
        SizedBox(
          height: 20,
        ),
        Container(
          padding: const EdgeInsets.all(16.0), // inner spacing
          decoration: BoxDecoration(
            color: Colors.white, // background color
            border: Border.all(
              color: const Color.fromARGB(255, 242, 40, 195), // outline color
              width: 2.0, // outline thickness
            ),
            borderRadius:
                BorderRadius.circular(12), // circular corners (12px radius)
          ),
          child: Text(
            'Attention Percent: ${"$attentionPercent %" ?? "Nothing predicted"}',
            style: TextStyle(color: const Color.fromARGB(255, 242, 40, 195)),
          ),
        ),
        SizedBox(
          height: 20,
        ),
        Container(
          height: MediaQuery.sizeOf(context).height * 0.3,
          width: MediaQuery.sizeOf(context).width - 0.7,
          decoration: BoxDecoration(border: Border.all()),
          child: SingleChildScrollView(
            child: Column(
              children: [
                Text("Probabilities: $predictedProbabilities"),
                Text("Window Size: $lengthleft"),
                const SizedBox(height: 20),
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxHeight: 100,
                    // the maximum height of your scrollable window
                  ),
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    clipBehavior: Clip.hardEdge, // hide anything outside
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          Text("Watch Data: ${ShowWatch.toString()}"),
                          Text(
                              "eSense Data: ${ShowEsense.toString() ?? 'No data'}"),
                        ],
                      ),
                    ),
                  ),
                ),
                Text("Latency Tolerance: $kAlignmentThresholdMs"),
                Text("Current Time: ${CurrentTime}"),
                Text("Model Name: ${globals.Model}"),
              ],
            ),
          ),
        ),
        SizedBox(
          height: 40,
        ),
        ElevatedButton(
          onPressed: toggleStart,
          child: isPredicting
              ? Text(
                  "Stop",
                  style: TextStyle(
                    color: Colors.white,
                  ),
                )
              : Text("Start", style: TextStyle(color: Colors.white)),
          style: ElevatedButton.styleFrom(
            backgroundColor: isPredicting
                ? Color.fromARGB(255, 240, 105, 105)
                : Color.fromARGB(255, 77, 221, 94),
            shape: const CircleBorder(),
            padding: const EdgeInsets.all(50),
          ),
        ),
      ],
    ));
  }
}

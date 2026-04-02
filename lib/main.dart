import 'dart:async';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:hive/hive.dart';
import 'package:is_wear/is_wear.dart';
import 'package:media_scanner/media_scanner.dart';
import 'package:rxdart/rxdart.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:watch_connectivity/watch_connectivity.dart';
import 'package:wear/wear.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wear_os/graphs.dart';
import 'package:wear_os/homescreen.dart';
import 'package:wear_os/pongsense.dart';
import 'globals.dart' as globals;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:onnxruntime/onnxruntime.dart';

late final bool isWear;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  

  // Initialize Hive and open a box
  final appDocumentDir = await getApplicationDocumentsDirectory();
  Hive.init(appDocumentDir.path);

  // Open a box named 'myBox'
  await Hive.openBox('myBox');
  
  print("Env initiated");
  isWear = (await IsWear().check()) ?? false;

  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: HomeScreen(),
    ),
  );
}

const YesIcon = Icon(
  Icons.check,
  color: Colors.green,
);

const NoIcon = Icon(
  Icons.close,
  color: Colors.red,
);

class MyApp extends StatefulWidget {
  const MyApp({Key? key}) : super(key: key);
  
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with AutomaticKeepAliveClientMixin{
  
  @override
  bool get wantKeepAlive => true;
  late final WatchConnectivityBase _watch;

  var _supported = false;
  var _paired = false;
  var _reachable = false;


  Map<String, dynamic> _latestWatchData = {};

  @override
  void initState() {
    super.initState();
    initAsync();
    
    _watch = WatchConnectivity();

    // Listen for watch data
    _watch.messageStream
        .sampleTime(const Duration(milliseconds: 100))
        .listen((event) {
      setState(() {
        _latestWatchData = event;
        globals.globalupdateWatchData(event);

        List row = [
          DateTime.now(),
          event['accelerometer']?['x'],
          event['accelerometer']?['y'],
          event['accelerometer']?['z'],
          event['gyroscope']?['x'],
          event['gyroscope']?['y'],
          event['gyroscope']?['z'],
        ];

        globals.currentData = row;
        globals.datalist.add(row);
        globals.times.add(DateTime.now().millisecondsSinceEpoch);
        globals.globalupdateWatchData(event);
      });
    });

    // Start collecting phone IMU data

    initPlatformState();
  }


  @override
  void dispose() {
   
    super.dispose();
  }


  void initAsync() async {
    await requestAllPermissions();
    
    
    
    
  }

  Future<void> requestAllPermissions() async {
  // List all the permissions your app may need
  final permissions = [
    Permission.storage,
    Permission.manageExternalStorage, // for Android 11+
    Permission.sensors,
    Permission.bluetooth,
    Permission.bluetoothScan,
    Permission.bluetoothConnect,
    Permission.locationWhenInUse,
    Permission.locationAlways,
  ];

  for (var permission in permissions) {
    if (await permission.status != PermissionStatus.granted) {
      final result = await permission.request();
      if (result != PermissionStatus.granted) {
        print("Permission not granted: $permission");
      }
    }
  }
}

  Future<void> initPlatformState() async {
    _supported = await _watch.isSupported;
    _paired = await _watch.isPaired;
    _reachable = await _watch.isReachable;
    setState(() {});
  }

  Future<void> _generateCsvFile() async {
    if (!Platform.isIOS) {
      var status = await Permission.storage.status;
      if (!status.isGranted) {
        status = await Permission.storage.request();
        if (!status.isGranted) {
          print('Storage permission not granted');
          return;
        }
      }
    }

    final csvData = globals.datalist
        .map((list) =>
            "${list[0]},${list[4]},${list[5]},${list[6]},${list[1]},${list[2]},${list[3]}")
        .join('\n');
    final csvHeader =
        'timestamp,gyro_x,gyro_y,gyro_z,acc_x,acc_y,acc_z\n';
    final csvString = csvHeader + csvData;

    Directory? tempDirectory = await getExternalStorageDirectory();
    if (tempDirectory == null) return;
    Directory directory = Directory('${tempDirectory.path}/Download');
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }

    String filePath = '${directory.path}/data.csv';
    final file = File(filePath);

    try {
      await file.writeAsString(csvString);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('CSV file saved at $filePath')),
      );
    } catch (e) {
      print('Failed to write to the file: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return MaterialApp(
      home: isWear
          ? AmbientMode(builder: (context, mode, child) => child!, child: _buildUI())
          : _buildUI(),
    );
  }

  Widget _buildUI() {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(32),
        child: SafeArea(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Connection State', style: TextStyle(fontWeight: FontWeight.bold)),
                ListTile(leading: _supported ? YesIcon : NoIcon, title: const Text('Supported')),
                ListTile(leading: _paired ? YesIcon : NoIcon, title: const Text('Paired')),
                ListTile(leading: _reachable ? YesIcon : NoIcon, title: const Text('Reachable')),
                const Divider(),

                

                const Text('⌚ Latest Watch IMU Data'),
                Text('Accelerometer: ${_latestWatchData['accelerometer']}'),
                Text('Gyroscope: ${_latestWatchData['gyroscope']}'),
                const SizedBox(height: 10),

                ElevatedButton(
                  onPressed: _generateCsvFile,
                  child: const Text('Generate CSV'),
                ),
                const SizedBox(height: 10),

                TextButton(
                  onPressed: () {
                    Navigator.push(context, MaterialPageRoute(builder: (context) => Graphs()));
                  },
                  child: const Text('Graphs'),
                ),
                const SizedBox(height: 30),

               
                const SizedBox(height: 15),

                const Text('📜 Log'),
                
              ],
            ),
          ),
        ),
      ),
    );
  }
}

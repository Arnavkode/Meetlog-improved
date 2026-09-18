import 'dart:async';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
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
  await dotenv.load(fileName: '.env');
  

  // Initialize Hive and open a box
  final appDocumentDir = await getApplicationDocumentsDirectory();
  Hive.init(appDocumentDir.path);

  // Open a box named 'myBox'
  await Hive.openBox('myBox');
  
  print("Env initiated");
  isWear = (await IsWear().check()) ?? false;

  const bgColor = Color(0xFF0A0F1F); // midnight blue
  const textColor = Colors.white;
  const skyBlue = Color(0xFF5CA9FF);
  final theme = ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: bgColor,
    colorScheme: const ColorScheme.dark(
      background: bgColor,
      surface: bgColor,
      primary: skyBlue,
      secondary: skyBlue,
    ),
    textTheme: ThemeData.dark().textTheme.apply(
          bodyColor: textColor,
          displayColor: textColor,
        ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: textColor,
        backgroundColor: skyBlue,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: skyBlue,
        foregroundColor: textColor,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    ),
    tabBarTheme: TabBarThemeData(
      indicator: const UnderlineTabIndicator(
        borderSide: BorderSide(color: skyBlue, width: 3),
      ),
      labelColor: skyBlue,
      unselectedLabelColor: Colors.white70,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: bgColor,
      foregroundColor: textColor,
      elevation: 0,
    ),
    indicatorColor: skyBlue,
    iconTheme: const IconThemeData(color: textColor),
  );

  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
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
  static const bgColor = Color(0xFF0A0F1F); // midnight blue
  static const textColor = Colors.white;
  static const skyBlue = Color(0xFF5CA9FF);
  ThemeData get _theme => ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: bgColor,
        colorScheme: const ColorScheme.dark(
          background: bgColor,
          surface: bgColor,
          primary: skyBlue,
          secondary: skyBlue,
        ),
        textTheme: ThemeData.dark().textTheme.apply(
              bodyColor: textColor,
              displayColor: textColor,
            ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: textColor,
            backgroundColor: skyBlue,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: skyBlue,
            foregroundColor: textColor,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
        ),
        tabBarTheme: TabBarThemeData(
          indicator: const UnderlineTabIndicator(
            borderSide: BorderSide(color: skyBlue, width: 3),
          ),
          labelColor: skyBlue,
          unselectedLabelColor: Colors.white70,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: bgColor,
          foregroundColor: textColor,
          elevation: 0,
        ),
        indicatorColor: skyBlue,
        iconTheme: const IconThemeData(color: textColor),
      );

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
      debugShowCheckedModeBanner: false,
      theme: _theme,
      home: isWear
          ? AmbientMode(builder: (context, mode, child) => child!, child: _buildUI())
          : _buildUI(),
    );
  }

  Widget _buildUI() {
    const headerStyle = TextStyle(
      color: textColor,
      fontSize: 24,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.3,
    );

    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: const [
                        Icon(Icons.watch_outlined, color: skyBlue, size: 28),
                        SizedBox(width: 10),
                        Text('Watch Control Panel', style: headerStyle),
                      ],
                    ),
                    const SizedBox(height: 22),

                    BezelCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Connection State',
                              style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                  color: textColor)),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: [
                              _stateChip('Supported', _supported),
                              _stateChip('Paired', _paired),
                              _stateChip('Reachable', _reachable),
                            ],
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),
                    BezelCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Latest Watch IMU',
                              style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                  color: textColor)),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: _dataTile(
                                  label: 'Accelerometer',
                                  value: _latestWatchData['accelerometer']?.toString() ?? '--',
                                  icon: Icons.speed,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: _dataTile(
                                  label: 'Gyroscope',
                                  value: _latestWatchData['gyroscope']?.toString() ?? '--',
                                  icon: Icons.rotate_90_degrees_ccw,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: GradientButton(
                            label: 'Export CSV',
                            icon: Icons.download_rounded,
                            onPressed: _generateCsvFile,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: GradientButton(
                            label: 'Open Graphs',
                            icon: Icons.show_chart,
                            onPressed: () {
                              Navigator.push(context,
                                  MaterialPageRoute(builder: (context) => Graphs()));
                            },
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 18),
                    BezelCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          Text('Activity Log',
                              style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                  color: textColor)),
                          SizedBox(height: 10),
                          Text('Streaming sensor data…',
                              style: TextStyle(color: Colors.white70)),
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
    );
  }

  Widget _stateChip(String label, bool ok) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: (ok ? Colors.green : Colors.red).withOpacity(0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ok ? Colors.green : Colors.redAccent, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: (ok ? Colors.green : Colors.redAccent).withOpacity(0.2),
            blurRadius: 14,
            spreadRadius: 1,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(ok ? Icons.check_circle : Icons.cancel, size: 18, color: ok ? Colors.green : Colors.redAccent),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(color: textColor, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _dataTile({required String label, required String value, required IconData icon}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF111A2D), Color(0xFF0E1325)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white10),
            boxShadow: const [
              BoxShadow(color: Colors.black45, blurRadius: 18, offset: Offset(0, 14), spreadRadius: -10),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: skyBlue, size: 20),
                  const SizedBox(width: 8),
                  Text(label,
                      style: const TextStyle(
                          color: Colors.white70, fontWeight: FontWeight.w600, fontSize: 13)),
                ],
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: constraints.maxWidth),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Text(
                    value,
                    softWrap: false,
                    overflow: TextOverflow.fade,
                    style: const TextStyle(
                        color: textColor, fontWeight: FontWeight.w700, fontSize: 13, letterSpacing: 0.2),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class BezelCard extends StatelessWidget {
  const BezelCard({Key? key, required this.child}) : super(key: key);

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
          BoxShadow(color: Colors.black54, blurRadius: 26, offset: Offset(0, 18), spreadRadius: -16),
          BoxShadow(color: Color(0x445CA9FF), blurRadius: 18, offset: Offset(0, 10), spreadRadius: -10),
        ],
      ),
      child: child,
    );
  }
}

class GradientButton extends StatelessWidget {
  const GradientButton({Key? key, required this.label, required this.icon, required this.onPressed})
      : super(key: key);

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 0,
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
        ),
        onPressed: onPressed,
        child: Ink(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF5CA9FF), Color(0xFF5C7BFF)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
            boxShadow: const [
              BoxShadow(color: Color(0x885CA9FF), blurRadius: 16, offset: Offset(0, 8), spreadRadius: -4),
            ],
          ),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Text(label,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.3,
                        fontSize: 15)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:wear_os/esense/device.dart';
import 'package:wear_os/routes/calibration.dart';
import 'package:wear_os/routes/connect.dart';
import 'package:wear_os/globals/connection.dart' as g;
import 'package:wear_os/util/callback.dart';



class PongSense extends StatelessWidget {
  const PongSense({super.key});

  @override
  Widget build(BuildContext context) {
    const bgColor = Color(0xFF0A0F1F);
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
          backgroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: Colors.transparent,
        selectedItemColor: skyBlue,
        unselectedItemColor: Colors.white70,
        showUnselectedLabels: true,
        type: BottomNavigationBarType.fixed,
      ),
      iconTheme: const IconThemeData(color: textColor),
    );

    return MaterialApp(
      title: 'Pongsense',
      theme: theme,
      home: Navigation(),
    );
  }
}

class Navigation extends StatefulWidget {
  const Navigation({super.key});

  @override
  NavigationState createState() => NavigationState();
}

class NavigationState extends State<Navigation> with AutomaticKeepAliveClientMixin{
  bool get wantKeepAlive => true;
  Closer? _stateCallbackCloser;
  var _deviceState = g.device.state;

  int _currentTabIndex = 0;

  final calibrateScreen = const CalibrationScreen();
  final connectScreen = const ConnectScreen();

  final reconnectSnackBar = const SnackBar(
    content: Text('Please reconnect to the device first!'),
  );
  final connectSnackBar = const SnackBar(
    content: Text('You have to connect to a device first!'),
  );

  @override
  void initState() {
    super.initState();

    _stateCallbackCloser = g.device.registerStateCallback((state) {
      if (state == _deviceState) return;
      setState(() {
        _deviceState = state;

        // redirect to connect widget on disconnect
        if (_currentTabIndex != 0 && _deviceState != DeviceState.initialized) {
          ScaffoldMessenger.of(context).showSnackBar(reconnectSnackBar);
          _currentTabIndex = 0;
        }
      });
    });
  }

  Widget _bottomNavigationBar() {
    final disabledColor = Theme.of(context).disabledColor;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF10182B), Color(0xFF0C1224)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white12),
          boxShadow: const [
            BoxShadow(
                color: Colors.black45,
                blurRadius: 24,
                offset: Offset(0, 12),
                spreadRadius: -12),
            BoxShadow(
                color: Color(0x445CA9FF),
                blurRadius: 12,
                offset: Offset(0, 8),
                spreadRadius: -10),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: BottomNavigationBar(
            items: [
              const BottomNavigationBarItem(
                icon: Icon(Icons.bluetooth_connected),
                label: "Connect",
              ),
              BottomNavigationBarItem(
                icon: Icon(
                  Icons.calculate,
                  color: _deviceState != DeviceState.initialized
                      ? disabledColor
                      : null,
                ),
                label: "Calibrate",
              ),
            ],
            onTap: _onTap,
            currentIndex: _currentTabIndex,
          ),
        ),
      ),
    );
  }

  _onTap(int tabIndex) {
    if (_currentTabIndex == tabIndex) {
      return;
    }

    // calibrate is disabled when not connected
    // if (tabIndex != 0 && _deviceState != DeviceState.initialized) {
    //   ScaffoldMessenger.of(context).showSnackBar(connectSnackBar);
    //   return;
    // }

    setState(() {
      _currentTabIndex = tabIndex;
    });
  }

  Widget get route {
    switch (_currentTabIndex) {
      case 0:
        return connectScreen;
      case 1:
        return calibrateScreen;

      default:
        return connectScreen;
    }
  }

  String get routeTitle {
    switch (_currentTabIndex) {
      case 0:
        return "Connect";
      case 1:
        return "Calibrate";
      default:
        return "Connect";
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
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
        body: route,
        bottomNavigationBar: _bottomNavigationBar(),
      ),
    );
  }

  @override
  void dispose() {
    _stateCallbackCloser?.call();
    super.dispose();
  }
}

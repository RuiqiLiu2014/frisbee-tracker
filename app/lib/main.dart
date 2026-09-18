import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'constants.dart';
import 'settings.dart';
import 'theme.dart';
import 'screens/home_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterBluePlus.setLogLevel(LogLevel.info, color: true);
  final prefs = await SharedPreferences.getInstance();
  themeModeNotifier.value = parseThemeMode(prefs.getString(kThemeModeKey));
  appThemeNotifier.value = parseAppTheme(prefs.getString(kAppThemeKey));
  colorSwapNotifier.value = parseColorSwap(prefs.getString(kColorSwapKey));
  showAccelNotifier.value = prefs.getBool(kShowAccelKey) ?? true;
  showGyroNotifier.value = prefs.getBool(kShowGyroKey) ?? true;
  preRollMsNotifier.value = prefs.getInt(kPreRollKey) ?? kDefaultPreRollMs;
  runApp(const FrisbeeTrackerApp());
}

class FrisbeeTrackerApp extends StatelessWidget {
  const FrisbeeTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) => ValueListenableBuilder<AppTheme>(
        valueListenable: appThemeNotifier,
        builder: (context, appTheme, _) => ValueListenableBuilder<ColorSwap>(
          valueListenable: colorSwapNotifier,
          builder: (context, swap, _) => MaterialApp(
            title: 'Frisbee Tracker',
            debugShowCheckedModeBanner: false,
            theme: lightTheme(appTheme, swap),
            darkTheme: darkTheme(appTheme, swap),
            themeMode: mode,
            home: const HomeShell(),
          ),
        ),
      ),
    );
  }
}

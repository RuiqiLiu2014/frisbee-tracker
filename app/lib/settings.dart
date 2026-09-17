import 'package:flutter/material.dart';

// Non-theme app settings, kept as notifiers so any screen can read/observe them
// (mirrors the theme-notifier pattern in theme.dart).

const String kShowAccelKey = "showAccelGraph";
const String kShowGyroKey = "showGyroGraph";
const String kLogSeqKey = "logSeq"; // last issued throw-log number
const String kCalibKey = "calibration"; // "ax,ay,az,gxBias,gyBias,gzBias" (g, dps)
const String kCalibTimeKey = "calibrationTime"; // ms since epoch of last calibration
const String kLabelKey = "nextThrowLabel"; // persisted next-throw label selection

final ValueNotifier<bool> showAccelNotifier = ValueNotifier(true);
final ValueNotifier<bool> showGyroNotifier = ValueNotifier(true);

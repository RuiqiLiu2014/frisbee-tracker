import 'package:flutter/material.dart';

import 'constants.dart';

// Non-theme app settings, kept as notifiers so any screen can read/observe them
// (mirrors the theme-notifier pattern in theme.dart).

const String kShowAccelKey = "showAccelGraph";
const String kShowGyroKey = "showGyroGraph";
const String kLogSeqKey = "logSeq"; // last issued throw-log number
const String kCalibKey = "calibration"; // "ax,ay,az,gxBias,gyBias,gzBias" (g, dps)
const String kCalibTimeKey = "calibrationTime"; // ms since epoch of last calibration
const String kLabelKey = "nextThrowLabel"; // persisted next-throw label selection
const String kPreRollKey = "preRollMs"; // capture pre-roll length, ms

final ValueNotifier<bool> showAccelNotifier = ValueNotifier(true);
final ValueNotifier<bool> showGyroNotifier = ValueNotifier(true);
final ValueNotifier<int> preRollMsNotifier = ValueNotifier(kDefaultPreRollMs);

import 'package:flutter/material.dart';

// App version, shown in the app bar. Bump on app changes.
const String kAppVersion = "0.1";

// Sensor scaling for the LSM6DS3 configured at accel +/-16 g, gyro +/-2000 dps
// (same config as the PingPongTracker firmware). Raw int16 counts -> units.
const double kAccelScaleG = 0.488 / 1000.0; // g per raw count
const double kGyroScaleDps = 70.0 / 1000.0; // dps per raw count

// Nominal IMU output data rate; used to space samples when the firmware doesn't
// report an explicit capture rate.
const double kNominalOdrHz = 1660.0;

// Chart palette, shared by charts and legends. Accel = warm/primary triad,
// gyro = secondary triad.
const List<Color> kAccelColors = [Colors.red, Colors.green, Colors.blue];
const List<Color> kGyroColors = [Colors.orange, Colors.purple, Colors.teal];
const List<String> kAccelLabels = ["ax", "ay", "az"];
const List<String> kGyroLabels = ["gx", "gy", "gz"];

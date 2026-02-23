// ignore_for_file: curly_braces_in_flow_control_structures, non_constant_identifier_names, constant_identifier_names

import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import '../exercise_base.dart';

/// NOTE (Showcase):
/// Metric logic, thresholds, and rep detection are redacted.
/// This file demonstrates how an Exercise composes multiple metrics.

enum SquatState { standing, descending, bottom, ascending }

class Squat extends ExerciseBase {
  SquatState squatState = SquatState.standing;

  // In the real app, these are concrete metric implementations.
  // Here we keep names/structure only.
  final List<_SquatMetric> _metrics = [
    _SquatMetric(name: "Depth"),
    _SquatMetric(name: "TrunkLean"),
    _SquatMetric(name: "HeelRise"),
    _SquatMetric(name: "Tempo"),
    _SquatMetric(name: "HipShoulderSync"),
  ];

  @override
  String? checkSafety(
    Map<PoseLandmarkType, PoseLandmark> landmarks,
    CameraFacing cameraFacing,
    double? frontFacingRatio,
  ) {
    // Redacted safety thresholds; keep only the concept.
    return null;
  }

  @override
  void checkingPose(Pose pose, CameraFacing cameraFacing, double? scaleFactor) {
    // Redacted: geometry extraction (angles/distances), state machine thresholds,
    // per-metric update calls with real values.

    debugData['exercise'] = 'squat';
    debugData['squatState'] = squatState.toString().split('.').last;

    // Show the "metrics update" structure without revealing logic:
    final ctx = _SquatContext(
      squatState: squatState,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      resultIssues: resultIssues,
      debugData: debugData,
    );

    for (final metric in _metrics) {
      metric.update(ctx); // stub
      debugData.addAll(metric.debugData);
    }

    // Redacted rep completion:
    // repCount++, aggregation of faults, setFeedback building, etc.
  }
}



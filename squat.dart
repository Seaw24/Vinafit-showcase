// ignore_for_file: curly_braces_in_flow_control_structures, non_constant_identifier_names, constant_identifier_names

import '../../utils/pose_math_helpers.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import '../exercise_base.dart';
import 'metrics/squat_metric_base.dart';
import 'metrics/squat_depth_metric.dart';
import 'metrics/trunk_lean_metric.dart';
import 'metrics/heel_rise_metric.dart';
import 'metrics/tempo_metric.dart';
import 'metrics/hip_shoulder_sync.dart';

/* =========================================================================
   CONFIGURATION & THRESHOLDS
   ========================================================================= */
class SquatConfig {
  static const double MIN_CONFIDENCE = 0.98;

  static const int SQUAT_STAND_ANGLE_THRESHOLD = 160;
  static const int SQUAT_DESCEND_ANGLE_THRESHOLD = 152;
  static const List<int> SQUAT_BOTTOM_ANGLE_THRESHOLD = [80, 100];
}

enum SquatState {
  standing,
  descending,
  bottom,
  ascending,
}

/* =========================================================================
   SQUAT LOGIC
   ========================================================================= */

class Squat extends ExerciseBase {
  SquatState squatState = SquatState.standing;

  final DepthMetric depthMetric = DepthMetric();
  final TrunkLeanMetric trunkLeanMetric = TrunkLeanMetric();
  final HeelRiseMetric heelRiseMetric = HeelRiseMetric();
  final TempoMetric tempoMetric = TempoMetric();
  final HipShoulderSyncMetric hipShoulderSyncMetric = HipShoulderSyncMetric();

  late final List<SquatMetricBase> _metrics = [
    depthMetric,
    trunkLeanMetric,
    heelRiseMetric,
    tempoMetric,
    hipShoulderSyncMetric,
  ];

  /* -----------------------------------------------------------------------
     SAFETY CHECKS
  ----------------------------------------------------------------------- */
  @override
  String? checkSafety(Map<PoseLandmarkType, PoseLandmark> landmarks,
      CameraFacing cameraFacing, double? frontFacingRatio) {
    final criticalTypes = [
      PoseLandmarkType.leftHip,
      PoseLandmarkType.rightHip,
      PoseLandmarkType.leftKnee,
      PoseLandmarkType.rightKnee,
      PoseLandmarkType.leftShoulder,
      PoseLandmarkType.rightShoulder,
    ];

    if (cameraFacing == CameraFacing.front) {
      return "⚠️ Please turn to the side for better tracking for Squat";
    }

    for (var type in criticalTypes) {
      final landmark = landmarks[type];
      if (landmark == null) return "⚠️ Body not fully visible.";
      if (landmark.likelihood < SquatConfig.MIN_CONFIDENCE)
        return "⚠️ Adjust lighting/position.";
    }
    return null;
  }

  /* -----------------------------------------------------------------------
     MAIN PHYSICS LOOP — Called every frame when activated.
  ----------------------------------------------------------------------- */
  @override
  void checkingPose(Pose pose, CameraFacing cameraFacing, double? scaleFactor) {
    // ---------- 1. Get Landmarks ----------

    PoseLandmark? knee = getSideLandmark(
        pose: pose,
        rightType: PoseLandmarkType.rightKnee,
        leftType: PoseLandmarkType.leftKnee);
    PoseLandmark? hip = getSideLandmark(
        pose: pose,
        rightType: PoseLandmarkType.rightHip,
        leftType: PoseLandmarkType.leftHip);
    PoseLandmark? ankle = getSideLandmark(
        pose: pose,
        rightType: PoseLandmarkType.rightAnkle,
        leftType: PoseLandmarkType.leftAnkle);
    PoseLandmark? shoulder = getSideLandmark(
        pose: pose,
        rightType: PoseLandmarkType.rightShoulder,
        leftType: PoseLandmarkType.leftShoulder);
    PoseLandmark? foot = getSideLandmark(
        pose: pose,
        rightType: PoseLandmarkType.rightFootIndex,
        leftType: PoseLandmarkType.leftFootIndex);
    PoseLandmark? heel = getSideLandmark(
        pose: pose,
        rightType: PoseLandmarkType.rightHeel,
        leftType: PoseLandmarkType.leftHeel);

    if (knee == null ||
        hip == null ||
        ankle == null ||
        shoulder == null ||
        foot == null ||
        heel == null) return;

    // ---------- 2. Calculate Geometry ----------

    double kneeAngle =
        calculateAngle(firstPoint: hip, midPoint: knee, lastPoint: ankle);
    double backAngle = calculateVerticalAngle(pivot: hip, point: shoulder);
    double trunkLean = convertClockAngleToTrunkLean(backAngle, cameraFacing);
    double heelDistanceToFloor = foot.y - heel.y;
    int now = DateTime.now().millisecondsSinceEpoch;

    // ---------- 3. Build RepContext ----------

    final ctx = RepContext(
      kneeAngle: kneeAngle,
      trunkLean: trunkLean,
      clockAngle: backAngle,
      heelDistance: heelDistanceToFloor,
      scaleFactor: scaleFactor,
      squatState: squatState,
      frameTimestamp: now,
      kneeY: knee.y,
      hipY: hip.y,
      shoulderY: shoulder.y,
      resultIssues: resultIssues,
    );

    // ---------- 4. Populate Debug Data ----------

    debugData['squatState'] = squatState.toString().split('.').last;
    debugData['kneeAngle'] = kneeAngle.toStringAsFixed(1);
    debugData['backClockAngle'] = backAngle.toStringAsFixed(1);
    debugData['trunkLean'] =
        '${trunkLean >= 0 ? "+" : ""}${trunkLean.toStringAsFixed(1)}°';
    debugData['trunkLeanDir'] = trunkLean >= 0 ? 'Forward' : 'Backward';
    debugData['heelDist'] = heelDistanceToFloor.toStringAsFixed(2);
    debugData['correctForm'] = correctForm.toString();

    // ---------- 5. Rep Completion (Standing Up) ----------

    if (kneeAngle > SquatConfig.SQUAT_STAND_ANGLE_THRESHOLD) {
      if (squatState != SquatState.standing) {
        repCount += 1;

        // Let depth check if rep was deep enough
        depthMetric.checkRepCompletion(squatState, ctx);

        // Fire final state transition so tempo can calculate ascent
        _transitionState(SquatState.standing, now);

        // Let tempo evaluate the full rep
        tempoMetric.evaluateRep(ctx);

        // Collect faults from all metrics
        final allFaults = <FaultRecord>[];
        for (final metric in _metrics) {
          allFaults.addAll(metric.faults);
        }

        // Determine correctForm: true if no faults with affectsForm=true
        correctForm = !allFaults.any((f) => f.affectsForm);

        // UI feedback
        resultIssues.feedback['Result'] =
            correctForm ? 'Good Rep!' : 'Fix Form';

        // Build fault map for set history
        final faultMap = <String, Map<String, String>>{};
        for (final fault in allFaults) {
          if (!faultMap.containsKey(fault.phase)) {
            faultMap[fault.phase] = {};
          }
          faultMap[fault.phase]![fault.type] = fault.message;
        }
        setFeedback.add({correctForm: faultMap});

        // Merge metric debug data BEFORE reset
        for (final metric in _metrics) {
          debugData.addAll(metric.debugData);
        }

        // Add tempo summary to post-rep feedback
        if (tempoMetric.descentDuration != null) {
          resultIssues.feedback['Tempo'] =
              '↓${tempoMetric.descentDuration!.toStringAsFixed(1)}s';
          if (tempoMetric.ascentDuration != null) {
            resultIssues.feedback['Tempo'] =
                '↓${tempoMetric.descentDuration!.toStringAsFixed(1)}s ↑${tempoMetric.ascentDuration!.toStringAsFixed(1)}s';
          }
        }
      }

      // Reset metrics for next rep (instructions survive — shown during standing)
      squatState = SquatState.standing;
      correctForm = true;
      for (final metric in _metrics) {
        metric.reset();
      }
      return;
    }

    // ---------- 6. Update State Machine ----------

    _updateSquatState(kneeAngle, now);

    // ---------- 7. Run All Metrics ----------

    if (squatState != SquatState.standing) {
      for (final metric in _metrics) {
        metric.update(ctx);
      }
    }

    // Merge metric debug data
    for (final metric in _metrics) {
      debugData.addAll(metric.debugData);
    }

    // Status instruction based on current squat phase
    if (squatState == SquatState.descending) {
      resultIssues.addInstruction('descending', 'Status', 'Going Down...');
    } else if (squatState == SquatState.bottom) {
      final remaining = tempoMetric.bottomHoldRemaining;
      final progress = tempoMetric.bottomHoldProgress;
      if (remaining != null && remaining > 0.05) {
        resultIssues.addInstruction(
            'bottom', 'Status', 'Hold! ${remaining.toStringAsFixed(1)}s');
      } else {
        resultIssues.addInstruction('bottom', 'Status', 'Push Up Now!');
      }
      if (progress != null) {
        debugData['bottomHoldProgress'] = progress;
      }
    } else if (squatState == SquatState.ascending) {
      resultIssues.addInstruction('ascending', 'Status', 'Push Up!');
    }
  }

  /* -----------------------------------------------------------------------
     STATE MACHINE (with transition notifications)
  ----------------------------------------------------------------------- */

  void _updateSquatState(double kneeAngle, int timestampMs) {
    if (kneeAngle <= SquatConfig.SQUAT_DESCEND_ANGLE_THRESHOLD &&
        squatState == SquatState.standing) {
      _transitionState(SquatState.descending, timestampMs);
    } else if (kneeAngle <= SquatConfig.SQUAT_BOTTOM_ANGLE_THRESHOLD[1] &&
        squatState == SquatState.descending) {
      _transitionState(SquatState.bottom, timestampMs);
    } else if (kneeAngle > (SquatConfig.SQUAT_BOTTOM_ANGLE_THRESHOLD[1] + 5) &&
        squatState == SquatState.bottom) {
      _transitionState(SquatState.ascending, timestampMs);
    }
  }

  void _transitionState(SquatState newState, int timestampMs) {
    final oldState = squatState;
    squatState = newState;

    // Clear coaching instructions when user starts a new rep.
    // Instructions were shown during standing — no longer needed.
    if (newState == SquatState.descending) {
      resultIssues.instructions.clear();
    }

    for (final metric in _metrics) {
      metric.onStateTransition(oldState, newState, timestampMs);
    }
  }
}

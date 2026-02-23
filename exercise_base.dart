// ignore_for_file: constant_identifier_names

import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:vinafit_mobile/utils/debouncer.dart';
import '../utils/pose_smoother.dart';
import '../utils/pose_math_helpers.dart';

/* =========================================================================
   CONFIGURATION & THRESHOLDS
   ========================================================================= */

const double NODDING_ANGLE_FOR_START = 0.185; // 18.5% of the back length
const double FRONT_FACING_SHOULDER_THRESHOLD = 0.57; // > 0.57 is Front
const double SIDE_FACING_SHOULDER_THRESHOLD = 0.35; // < 0.35 is Side

/* =========================================================================
   ENUMS
   ========================================================================= */

enum ExerciseState {
  notActivated,
  activated,
  completed,
}

enum CameraFacing {
  front,
  left,
  right,
  angled,
  undefined,
}

// All metrics will have feedback and instruction for next rep, so we can bundle them together.
class ResultIssues {
  Map<String, String> feedback = {};
  Map<String, Map<String, String>> instructions =
      {}; // not using squat state because the exercise base won't know

  void addInstruction(String phase, String type, String message) {
    instructions.putIfAbsent(phase, () => {});
    instructions[phase]![type] = message;
  }

  void clear() {
    feedback.clear();
    instructions.clear();
  }
}

/* =========================================================================
   ExerciseBase - abstract base class for all fitness exercises.
   Manages: Smoothing, Orientation, Safety, Foreign Object Filter, and State.
   ========================================================================= */

abstract class ExerciseBase {
  // -- Core State --
  late PoseSmoother poseSmoother;
  int repCount = 0;
  final int MAX_REP = 15; // Placeholder max rep count for demo purposes
  List<Map<bool, Map<String, Map<String, String>>>> setFeedback = [];
  ResultIssues resultIssues = ResultIssues();

  ExerciseState exerciseState = ExerciseState.notActivated;
  CameraFacing cameraFacing = CameraFacing.front;
  bool correctForm = true;
  double? distanceScaleFactor; // Back length (Shoulder to Hip)
  double frontFacingRatio = 1.0; // Shoulder width / Torso height ratio

  /// Debug data exposed for the UI debug overlay.
  /// Child classes populate this with exercise-specific metrics.
  Map<String, dynamic> debugData = {};

  // -- Debouncers for filtering foreign object detection --
  StickyDebouncer leftRightDebouncer = StickyDebouncer(requiredFrames: 5);
  Debouncer confidenceDebouncer = Debouncer(requiredFrames: 5);
  Debouncer limbProportionsDebouncer = Debouncer(requiredFrames: 5);
  Debouncer anatomicalPlausibilityDebouncer = Debouncer(requiredFrames: 5);

  // -- Constructor --
  ExerciseBase() {
    poseSmoother = PoseSmoother(minCutoff: 0.5, beta: 0.005);
  }

  /* -----------------------------------------------------------------------
     MAIN PIPELINE
     ----------------------------------------------------------------------- */

  List<dynamic>? processPose(Map<PoseLandmarkType, PoseLandmark> landmarks) {
    resultIssues.feedback
        .clear(); // only clear feedback, keep instructions until rep completes

    // 1. Smooth the landmarks
    final smoothedLandmarks = poseSmoother.smoothing(landmarks);

    // 2. Foreign Object Filter (e.g., phone on table, chair, etc.)
    if (exerciseState == ExerciseState.notActivated) {
      final objectFilterError = detectObjectFilter(smoothedLandmarks);
      if (objectFilterError != null) {
        resultIssues.feedback["System"] = objectFilterError;
        _populateBaseDebugData();
        return [repCount, resultIssues.feedback];
      }
    }
    // 3. Auto-detect Left/Right/Front (MUST come before safety check!)
    cameraFacing = detectCameraFacing(smoothedLandmarks);

    // 4. Check for safety errors (child class logic)
    final safetyError =
        checkSafety(smoothedLandmarks, cameraFacing, frontFacingRatio);
    if (safetyError != null) {
      resultIssues.feedback["System"] = safetyError;
      _populateBaseDebugData();
      return [repCount, resultIssues.feedback];
    }

    final pose = Pose(landmarks: smoothedLandmarks);

    // 5. Calculate Distance Scale Factor (Back Length)
    final shoulder = getSideLandmark(
      pose: pose,
      rightType: PoseLandmarkType.rightShoulder,
      leftType: PoseLandmarkType.leftShoulder,
    );
    final hip = getSideLandmark(
      pose: pose,
      rightType: PoseLandmarkType.rightHip,
      leftType: PoseLandmarkType.leftHip,
    );
    if (shoulder != null && hip != null) {
      distanceScaleFactor = calculateDistance(shoulder, hip);
    }

    // 6. Run State Machine (Start -> Active -> Done)
    exerciseState = checkExerciseState(pose, exerciseState,
        scaleFactor: distanceScaleFactor);

    // Populate base-level debug data
    _populateBaseDebugData();
    debugData['scaleFactor'] = distanceScaleFactor?.toStringAsFixed(1) ?? 'N/A';

    if (exerciseState == ExerciseState.activated) {
      checkingPose(pose, cameraFacing, distanceScaleFactor);
      return getRepCountAndFeedback();
    } else if (exerciseState == ExerciseState.completed) {
      return getSetFeedback();
    }

    return null; // Idle
  }

  /// Populates common debug keys so they are always visible.
  void _populateBaseDebugData() {
    debugData['exerciseState'] = exerciseState.toString().split('.').last;
    debugData['cameraFacing'] = cameraFacing.toString().split('.').last;
  }

  /* -----------------------------------------------------------------------
     ORIENTATION LOGIC
     ----------------------------------------------------------------------- */

  CameraFacing detectCameraFacing(
      Map<PoseLandmarkType, PoseLandmark> smoothedLandmarks) {
    final leftS = smoothedLandmarks[PoseLandmarkType.leftShoulder];
    final rightS = smoothedLandmarks[PoseLandmarkType.rightShoulder];
    final leftH = smoothedLandmarks[PoseLandmarkType.leftHip];

    if (leftS == null || rightS == null || leftH == null) {
      return CameraFacing.undefined;
    }

    final shoulderWidth = (leftS.x - rightS.x);
    final torsoHeight = calculateDistance(leftS, leftH);

    if (torsoHeight < 10) return CameraFacing.undefined;

    final ratio = shoulderWidth.abs() / torsoHeight;
    frontFacingRatio = ratio;

    if (ratio > FRONT_FACING_SHOULDER_THRESHOLD) {
      return CameraFacing.front;
    } else if (ratio < SIDE_FACING_SHOULDER_THRESHOLD) {
      return _isLeftSide(smoothedLandmarks)
          ? CameraFacing.left
          : CameraFacing.right;
    } else {
      return CameraFacing.angled;
    }
  }

  // Determines left vs right side view using pair-voting on landmark Z coordinates. Only called when we already know it is a side view.
  bool _isLeftSide(Map<PoseLandmarkType, PoseLandmark>? smoothedLandmarks) {
    if (smoothedLandmarks == null) return false;

    const pairs = [
      [PoseLandmarkType.leftShoulder, PoseLandmarkType.rightShoulder],
      [PoseLandmarkType.leftElbow, PoseLandmarkType.rightElbow],
      [PoseLandmarkType.leftWrist, PoseLandmarkType.rightWrist],
      [PoseLandmarkType.leftHip, PoseLandmarkType.rightHip],
      [PoseLandmarkType.leftKnee, PoseLandmarkType.rightKnee],
      [PoseLandmarkType.leftAnkle, PoseLandmarkType.rightAnkle],
    ];

    int leftVotes = 0;
    int rightVotes = 0;
    for (final pair in pairs) {
      final leftLM = smoothedLandmarks[pair[0]];
      final rightLM = smoothedLandmarks[pair[1]];
      if (leftLM == null || rightLM == null) continue;

      final zDiff = leftLM.z - rightLM.z;
      double threshold = 0.01;
      if (zDiff.abs() > threshold) {
        if (zDiff < 0) {
          leftVotes++;
        } else {
          rightVotes++;
        }
      }
    }
    return leftRightDebouncer.update(leftVotes >= rightVotes);
  }

  /* -----------------------------------------------------------------------
     HELPERS
     ----------------------------------------------------------------------- */

  /// Smart Selector: returns the dominant-side landmark based on camera facing.
  /// - LEFT facing  -> Left landmark
  /// - RIGHT facing -> Right landmark
  /// - FRONT/ANGLED -> Defaults to Left
  PoseLandmark? getSideLandmark({
    required Pose pose,
    required PoseLandmarkType rightType,
    required PoseLandmarkType leftType,
  }) {
    if (cameraFacing == CameraFacing.right) {
      return pose.landmarks[rightType];
    }
    return pose.landmarks[leftType]; // left / front / angled
  }

  List<dynamic> getRepCountAndFeedback() => [repCount, resultIssues.feedback];

  List<dynamic> getSetFeedback() => setFeedback;

  /* -----------------------------------------------------------------------
     STATE MACHINE
     ----------------------------------------------------------------------- */

  ExerciseState checkExerciseState(
    Pose pose,
    ExerciseState currentState, {
    double? scaleFactor,
  }) {
    switch (currentState) {
      case ExerciseState.notActivated:
        final shoulder = getSideLandmark(
          pose: pose,
          rightType: PoseLandmarkType.rightShoulder,
          leftType: PoseLandmarkType.leftShoulder,
        );
        final nose = pose.landmarks[PoseLandmarkType.nose];

        if (shoulder == null || nose == null) {
          return ExerciseState.notActivated;
        }

        final dist = (nose.y - shoulder.y).abs() / (scaleFactor ?? 1.0);
        debugData['nodDist'] = dist.toStringAsFixed(3);

        if (dist < NODDING_ANGLE_FOR_START) {
          return ExerciseState.activated;
        }
        break;

      case ExerciseState.activated:
        // TODO: Replace with real completion logic
        if (repCount >= MAX_REP) return ExerciseState.completed;
        break;

      case ExerciseState.completed:
        break;
    }
    return currentState;
  }

  /* -----------------------------------------------------------------------
     FOREIGN OBJECT REJECTION FILTER
     ----------------------------------------------------------------------- */

  String? detectObjectFilter(
    Map<PoseLandmarkType, PoseLandmark>? smoothedLandmarks,
  ) {
    if (smoothedLandmarks == null) {
      return "Please stay in frame.";
    }

    String? confidenceError = _overallConfidenceFilter(smoothedLandmarks);
    // 1. Check overall confidence
    if (confidenceDebouncer.update(confidenceError != null)) {
      return confidenceError;
    }
    // 2. Check anatomical plausibility (nose above shoulders, shoulders above hips, etc.)
    String? anatomicalError = checkAnatomicalPlausibility(smoothedLandmarks);
    if (anatomicalPlausibilityDebouncer.update(anatomicalError != null)) {
      return anatomicalError;
    }

    // 3. Check limb proportions (foreign object heuristic)
    String? limbProportionsError = _limbProportionsFilter(smoothedLandmarks);
    if (limbProportionsDebouncer.update(limbProportionsError != null)) {
      return limbProportionsError;
    }

    return null;
  }
  /* =========================================================================
     All the filter
  ========================================================================= */

  /// Rejects frames where average landmark confidence is too low.
  String? _overallConfidenceFilter(
      Map<PoseLandmarkType, PoseLandmark> smoothedLandmarks) {
    double totalConfidence = 0.0;
    int count = 0;

    smoothedLandmarks.forEach((_, landmark) {
      totalConfidence += landmark.likelihood;
      count++;
    });

    if (count == 0) {
      return "No landmarks detected. Please adjust your position.";
    }

    final avgConfidence = totalConfidence / count;
    debugData['avgConfidence'] = avgConfidence.toStringAsFixed(3);

    if (avgConfidence < 0.7) {
      return "Low confidence in pose detection. Please improve lighting or move closer.";
    }
    return null;
  }

  /// Checks arm ratios, head-to-torso ratio, and joint angles to reject
  /// non-human shapes (e.g. chairs, phones on a table).
  String? _limbProportionsFilter(
      Map<PoseLandmarkType, PoseLandmark> smoothedLandmarks) {
    // 0. Get Important Landmarks (shoulders, hips, elbows, wrists, knees, ankles, nose,)
    final leftShoulder = smoothedLandmarks[PoseLandmarkType.leftShoulder];
    final leftElbow = smoothedLandmarks[PoseLandmarkType.leftElbow];
    final leftWrist = smoothedLandmarks[PoseLandmarkType.leftWrist];
    final rightShoulder = smoothedLandmarks[PoseLandmarkType.rightShoulder];
    final rightElbow = smoothedLandmarks[PoseLandmarkType.rightElbow];
    final rightWrist = smoothedLandmarks[PoseLandmarkType.rightWrist];
    final nose = smoothedLandmarks[PoseLandmarkType.nose];
    final leftHip = smoothedLandmarks[PoseLandmarkType.leftHip];
    final rightHip = smoothedLandmarks[PoseLandmarkType.rightHip];
    final leftKnee = smoothedLandmarks[PoseLandmarkType.leftKnee];
    final rightKnee = smoothedLandmarks[PoseLandmarkType.rightKnee];
    final leftAnkle = smoothedLandmarks[PoseLandmarkType.leftAnkle];
    final rightAnkle = smoothedLandmarks[PoseLandmarkType.rightAnkle];

    //
    // -- 1. Arm proportions (upper arm vs lower arm) --

    if (leftShoulder == null ||
        leftElbow == null ||
        leftWrist == null ||
        rightShoulder == null ||
        rightElbow == null ||
        rightWrist == null) {
      debugData['limbFilter'] = 'missing arm landmarks';
      return null;
    }

    final leftArmRatio = calculateDistance(leftShoulder, leftElbow) /
        calculateDistance(leftElbow, leftWrist);
    final rightArmRatio = calculateDistance(rightShoulder, rightElbow) /
        calculateDistance(rightElbow, rightWrist);

    debugData['leftArmRatio'] = leftArmRatio.toStringAsFixed(3);
    debugData['rightArmRatio'] = rightArmRatio.toStringAsFixed(3);

    // -- 2. Head-to-torso ratio (calculated early for debug visibility) --

    if (nose != null && leftHip != null && rightHip != null) {
      final shoulderMid = (
        x: (leftShoulder.x + rightShoulder.x) / 2,
        y: (leftShoulder.y + rightShoulder.y) / 2,
        z: (leftShoulder.z + rightShoulder.z) / 2,
        likelihood: (leftShoulder.likelihood + rightShoulder.likelihood) / 2,
      );

      final headLength = calculateDistance(nose, shoulderMid);
      final torsoLength = calculateDistance(leftHip, leftShoulder);
      final headToTorsoRatio = headLength / torsoLength;

      debugData['headToTorsoRatio'] = headToTorsoRatio.toStringAsFixed(3);

      if (headToTorsoRatio > 0.42 || headToTorsoRatio < 0.3) {
        return "Unusual head-to-torso ratio - this may not be a person.";
      }
    } else {
      debugData['headToTorsoRatio'] = 'N/A';
    }

    if ((leftArmRatio > 1.5 || leftArmRatio < 0.98) &&
        (rightArmRatio > 1.5 || rightArmRatio < 0.98)) {
      return "Unusual arm proportions detected - this may not be a person.";
    }

    // -- 3. Joint angles (knees and elbows) --
    if (leftKnee == null ||
        leftAnkle == null ||
        rightKnee == null ||
        rightAnkle == null ||
        leftHip == null ||
        rightHip == null) {
      debugData['limbFilter'] = 'missing leg landmarks';
      return null;
    }

    final leftKneeAngle = calculateAngle(
        firstPoint: leftHip, midPoint: leftKnee, lastPoint: leftAnkle);
    final rightKneeAngle = calculateAngle(
        firstPoint: rightHip, midPoint: rightKnee, lastPoint: rightAnkle);
    final leftElbowAngle = calculateAngle(
        firstPoint: leftShoulder, midPoint: leftElbow, lastPoint: leftWrist);
    final rightElbowAngle = calculateAngle(
        firstPoint: rightShoulder, midPoint: rightElbow, lastPoint: rightWrist);

    debugData['leftKneeAngle'] = leftKneeAngle.toStringAsFixed(1);
    debugData['rightKneeAngle'] = rightKneeAngle.toStringAsFixed(1);
    debugData['leftElbowAngle'] = leftElbowAngle.toStringAsFixed(1);
    debugData['rightElbowAngle'] = rightElbowAngle.toStringAsFixed(1);

    if (leftKneeAngle < 10 ||
        rightKneeAngle < 10 ||
        leftElbowAngle < 10 ||
        rightElbowAngle < 10) {
      return "Unusual joint angles detected - this may not be a person.";
    }

    debugData['limbFilter'] = 'passed';
    return null;
  }

  // Checks for basic anatomical plausibility (e.g., nose above shoulders, shoulders above hips, etc.) to filter out non-human detections.
  String? checkAnatomicalPlausibility(
      Map<PoseLandmarkType, PoseLandmark> smoothedLandmarks) {
    final nose = smoothedLandmarks[PoseLandmarkType.nose];
    final leftHip = smoothedLandmarks[PoseLandmarkType.leftHip];
    final rightHip = smoothedLandmarks[PoseLandmarkType.rightHip];
    final leftKnee = smoothedLandmarks[PoseLandmarkType.leftKnee];
    final rightKnee = smoothedLandmarks[PoseLandmarkType.rightKnee];
    final leftAnkle = smoothedLandmarks[PoseLandmarkType.leftAnkle];
    final rightAnkle = smoothedLandmarks[PoseLandmarkType.rightAnkle];
    final leftShoulder = smoothedLandmarks[PoseLandmarkType.leftShoulder];
    final rightShoulder = smoothedLandmarks[PoseLandmarkType.rightShoulder];

    double shoulderY = 0.0;
    double hipY = 0.0;
    double kneeY = 0.0;
    // Nose > shoulder ( y  increases downwards)
    if (nose != null && leftShoulder != null && rightShoulder != null) {
      shoulderY = (leftShoulder.y + rightShoulder.y) / 2;
      if (nose.y > shoulderY) {
        return "Nose below shoulders. Might not be a person.";
      }
    }

    // Shoulder < hip ( y  increases downwards)
    if (shoulderY != 0.0 && leftHip != null && rightHip != null) {
      hipY = (leftHip.y + rightHip.y) / 2;
      if (shoulderY > hipY) {
        return "Shoulders below hips. Might not be a person.";
      }
    }

    // Hip < knee ( y  increases downwards)
    if (hipY != 0.0 && leftKnee != null && rightKnee != null) {
      kneeY = (leftKnee.y + rightKnee.y) / 2;
      if (hipY > kneeY) {
        return "Hips below knees. Might not be a person.";
      }
    }

    // Knee < ankle ( y  increases downwards)
    if (kneeY != 0.0 && leftAnkle != null && rightAnkle != null) {
      final ankleY = (leftAnkle.y + rightAnkle.y) / 2;
      if (kneeY > ankleY) {
        return "Knees below ankles. Might not be a person.";
      }
    }

    return null;
  }

  /* -----------------------------------------------------------------------
     ABSTRACT METHODS (implemented by child exercises)
     ----------------------------------------------------------------------- */

  String? checkSafety(
    Map<PoseLandmarkType, PoseLandmark> smoothedLandmarks,
    CameraFacing cameraFacing,
    double? frontFacingRatio,
  );

  void checkingPose(Pose pose, CameraFacing cameraFacing, double? scaleFactor);
}

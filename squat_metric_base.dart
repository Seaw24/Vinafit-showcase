/* =========================================================================
   SquatMetricBase — Abstract base for all squat form metrics.
   
   Each metric is a self-contained unit that:
   - Receives frame data via update()
   - Writes feedback + instructions to ctx.resultIssues
   - Logs faults into its own fault list
   - Resets cleanly between reps
   
   Architecture:
   ┌─────────┐     ┌──────────────┐     ┌──────────────┐
   │  Squat  │────▶│  RepContext   │◀────│  MetricBase  │
   │ (owner) │     │ (shared state)│     │  (per metric)│
   └─────────┘     └──────────────┘     └──────────────┘
   
   Data flow:
   - feedback{}  → cleared every frame in processPose()
                  → metrics write live cards here (Depth, Back, Feet, etc.)
   - instructions{phase → {type → message}}
                  → coaching from evaluateRep() or per-frame faults
                  → cleared when new rep begins (standing → descending)
                  → UI reads instructions[currentPhase] for coaching chips
   ========================================================================= */

import '../squat.dart';
import '../../exercise_base.dart';

/* =========================================================================
   RepContext — Shared per-frame state, passed to all metrics.
   Avoids each metric needing to recalculate the same geometry.
   ========================================================================= */
class RepContext {
  final double kneeAngle;
  final double trunkLean; // Positive = forward, negative = backward
  final double clockAngle; // Raw clock angle for trunk
  final double heelDistance; // foot.y - heel.y (raw pixel distance)
  final double? scaleFactor; // Back length (shoulder-to-hip distance)
  final SquatState squatState;
  final int frameTimestamp; // millisecondsSinceEpoch

  // Landmark Y positions (for depth check, sync check, etc.)
  final double kneeY;
  final double hipY;
  final double shoulderY;

  /// Shared result container — metrics write feedback + instructions here.
  final ResultIssues resultIssues;

  RepContext({
    required this.kneeAngle,
    required this.trunkLean,
    required this.clockAngle,
    required this.heelDistance,
    required this.scaleFactor,
    required this.squatState,
    required this.frameTimestamp,
    required this.kneeY,
    required this.hipY,
    required this.shoulderY,
    required this.resultIssues,
  });
}

/* =========================================================================
   FaultRecord — A single fault logged by a metric.
   ========================================================================= */
class FaultRecord {
  final String phase; // e.g. "DESCENDING", "BOTTOM"
  final String type; // e.g. "Back", "Depth", "Feet", "Tempo"
  final String message; // e.g. "Leaned too forward"
  final bool affectsForm; // false = informational only (like heel rise)

  FaultRecord({
    required this.phase,
    required this.type,
    required this.message,
    this.affectsForm = true,
  });
}

/* =========================================================================
   SquatMetricBase — Interface every metric implements.
   ========================================================================= */
abstract class SquatMetricBase {
  /// Human-readable name for debug/logging.
  String get name;

  /// Called every frame during an active rep (squatState != standing).
  /// Writes feedback + instructions directly to ctx.resultIssues.
  void update(RepContext ctx);

  /// Faults accumulated this rep. Squat reads these when rep completes.
  List<FaultRecord> get faults;

  /// Debug data for the overlay. Keys should be metric-specific.
  Map<String, dynamic> get debugData;

  /// Reset all internal state for the next rep.
  void reset();

  /// Called when squat state transitions (e.g. descending → bottom).
  /// Override in metrics that care about transitions (tempo, sync).
  void onStateTransition(SquatState from, SquatState to, int timestampMs) {}
}

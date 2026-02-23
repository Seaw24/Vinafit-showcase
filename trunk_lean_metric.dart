/// NOTE (Showcase):
/// Trunk lean thresholds and evaluation logic are proprietary and redacted.
/// This file demonstrates the "metric module" shape only.

class TrunkLeanMetric {
  String get name => 'TrunkLean';

  final List<Map<String, dynamic>> faults = [];
  final Map<String, dynamic> debugData = {};

  void update(dynamic ctx) {
    // Proprietary: trunk lean evaluation, debouncing, coaching rules, fault logging.
    debugData['maxTrunkLean'] = 'redacted';
  }

  void reset() {
    faults.clear();
    debugData.clear();
  }
}

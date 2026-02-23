# VinaFit — AI Home Workout Coach for Vietnamese

> Real-time form analysis of multiple home workout exercise using on-device pose estimation.  
> This repo only include 1 metric of the squat exercise.  
> Built for Vietnamese users. Runs offline on mid-range Android phones.

---

## The Problem

Most current home workout app only suggested what exercise to do but never teach how to do it. 

VinaFit is an attempt to fix this by still have all the features of a normal exercising app ( suggesting exercise, build schedule, Progress tracking, ...) but have an additional feature that leverage AI to act like your coach during the exercise to suggest form fix, and giving instruction.

---

## What This Repo Shows

This is a **showcase of the system architecture** for the VinaFit squat analysis module. Proprietary thresholds, heuristics, and evaluation logic are intentionally redacted — this repo is meant to communicate *how the system is designed*, not serve as a copy-paste library.

**What you'll find:**
- The modular metric architecture (`SquatMetricBase`)
- The shared data-flow pattern (`RepContext` → `ResultIssues`)
- The separation between live per-frame feedback and post-rep coaching instructions
- The abstract exercise pipeline (`ExerciseBase`)

---

## System Architecture

### The Core Idea: Each Metric is Isolated
Take an example of Squat, but this how all exercise work.

Instead of one monolithic function analyzing everything, each form metric lives in its own class. They share data through a `RepContext` object but never talk to each other directly.

```
┌─────────┐     ┌──────────────┐     ┌───────────────────┐
│  Squat  │────▶│  RepContext  │◀────│  SquatMetricBase  │
│ (owner) │     │ (shared data)│     │   (per metric)    │
└─────────┘     └──────────────┘     └───────────────────┘
```

Every frame, `Squat` builds a `RepContext` with pre-calculated geometry (angles, distances, timestamps) and passes it to each metric. Metrics write their output into `resultIssues` — a shared container that the UI reads.

### The Five Metrics

| Metric | What It Detects | 
|---|---|---|
| `DepthMetric` | Knee flexion angle — gates rep counting | 
| `TrunkLeanMetric` | Forward/backward torso lean — lumbar load risk | 
| `HeelRiseMetric` | Heel lift — ankle mobility flag (informational) | 
| `TempoMetric` | Descent speed, bottom hold, eccentric control | 
| `HipShoulderSyncMetric` | "Good morning" pattern — hips rising before chest  |

### Two Types of Feedback

This distinction was important to get right:

```
feedback{}         → per-frame, cleared every frame
                   → powers live cards on screen ("Go Lower", "Good Back")

instructions{}     → set once per rep when a fault is detected
                   → survive until the NEXT rep starts
                   → shown as floating coaching chips during standing
                   → "Keep chest up next time!" instead of spamming mid-squat
```

The insight: users **cannot process corrective instructions while actively squatting**. The coaching chip pattern shows tips *between* reps, which is when the brain is ready to absorb them.

---

## Pose Pipeline

Every camera frame goes through this pipeline in `ExerciseBase`:

```
Raw Landmarks
     │
     ▼
1. One Euro Filter smoothing       (removes jitter at 30fps)
     │
     ▼
2. Foreign Object Filter           (rejects chairs, phones, other people)
   ├── Confidence check
   ├── Anatomical plausibility     (nose above shoulders, hips above knees, etc.)
   └── Limb proportion check       (arm ratios, head-to-torso ratio)
     │
     ▼
3. Camera Orientation Detection    (front / left-side / right-side / angled)
     │
     ▼
4. Safety Check                    (exercise-specific, e.g. "turn sideways for squats")
     │
     ▼
5. Scale Factor Calculation        (shoulder-to-hip distance normalizes all distances)
     │
     ▼
6. State Machine                   (standing → descending → bottom → ascending)
     │
     ▼
7. Metric Updates                  (each metric receives RepContext, writes to resultIssues)
```

---

## Trunk Lean: The Math

The trunk lean metric is a good example of where the geometry gets interesting.

ML Kit gives us 2D pixel coordinates for each landmark. To measure how far someone is leaning forward, we need the angle of the shoulder-hip line relative to vertical — but the interpretation flips depending on which side the person is facing.

**Step 1 — Clock Angle**

We use `atan2` to get the angle from hip to shoulder, then rotate so that straight up = 0°:

```
       0° (vertical / upright)
       │
 270° ─┼─ 90°
       │
      180°
```

**Step 2 — Interpret by Camera Facing**

For a left-facing view:
- `270–360°` means shoulder is *ahead* of hip → forward lean
- `0–90°` means shoulder is *behind* hip → backward lean

For a right-facing view, the logic mirrors.

```dart
// Left-facing: 330° clock angle → +30° forward lean
if (clockAngle >= 270) return (360 - clockAngle);

// Left-facing: 20° clock angle → -20° backward lean  
if (clockAngle <= 90) return -clockAngle;
```

**Step 3 — Vietnamese Anthropometric Adjustment**

Standard coaching literature targets a trunk lean range of ~20–30°. For Vietnamese males in Group 1 (relatively long femurs, shorter torso), a wider range of **15–40°** is biomechanically appropriate. Applying Western defaults would flag good squats as errors.

---

## Technical Stack

| Component | Choice | Why |
|---|---|---|
| Framework | Flutter (Dart) | Single codebase, good camera APIs |
| Pose Detection | Google ML Kit (BlazePose) | On-device, 30fps on mid-range Android |
| Smoothing | One Euro Filter | Adaptive — less lag during fast movement |
| Debouncing | Custom frame-counter | Prevents single-frame false positives |

**Known limitations of 2D side-view analysis:**
- ~65% fault coverage for common squat errors
- Cannot detect knee valgus (knees caving inward) — requires front view
- Depth accuracy degrades if user is not perpendicular to camera
- Scale normalization assumes consistent camera distance

---

## Why Not Just Use a Pre-trained Model?

Exercise-specific models (e.g. trained directly on squat videos with labelled errors) would give better accuracy. The constraint here is **data** — there is no labelled squat dataset for Vietnamese body proportions, and collecting one is a project in itself.

The geometric approach used here is:
- Interpretable (you can explain every decision)
- Adjustable (thresholds are tunable as more data comes in)  
- Fast enough to run on a Snapdragon 665

A hybrid approach — geometric features fed into a lightweight classifier — is the planned next step.

---

## What's Redacted

To protect the work done on calibration and evaluation logic:
- Specific threshold values for all metrics
- The One Euro Filter tuning parameters
- Foreign object rejection heuristics
- Rep counting state machine conditions
- Camera orientation detection algorithm

The architecture, data flow, and mathematical approach are fully shown.

---

## Status

This is an active solo project. Currently in closed testing with a small group of Vietnamese users in Ho Chi Minh City.

If you're a researcher, engineer, or builder interested in AI fitness applications for Southeast Asian markets — feel free to open an issue or reach out directly.

---

## License

Architecture and non-proprietary code: MIT  
Evaluation logic and thresholds: All rights reserved

# Input migration plan

Status: started. Direction: keep the rebuild's lane/modulation architecture and port
the legacy app's gesture feel and assignment UX into it.

## Principle

Treat gesture as one platform-specific input family, not the whole system:

| Platform | Physical input | Runtime source family |
|---|---|---|
| macOS | keyboard, mouse drag, scroll; MIDI later | `input.mac.*`, `midi.*` |
| iPadOS | touch drag, pinch, tap/long press | `input.touch.*` |
| visionOS | hand pinch, palm tap, fist, swipe, world grab | `hand.*`, `gesture.*` |

All physical inputs should normalize into source values, then flow through the same
binding/action resolver into the gesture lane, camera actions, or core commands.

## Current slice

- Rebuild `GestureBinding` now supports axis-specific scalar intent with
  `scalarAxis(ParamKey, GestureAxis)`.
- `GestureLaneResolver` maps `scalarAxis` from the selected vector component, not
  vector magnitude.
- `HandConstellationPanel` is moving back toward the legacy assignment surface:
  direct fingertip menus, whole-XYZ assignment, per-axis claims, actions, and an
  assignment summary.

## Next implementation phases

1. **VisionOS live-path diagnosis**
   - Add a compact debug readout for hand tracking, active sources, suppression
     reason, arming progress, and lane writes.
   - Verify `HandTracker.start`, compositor-frame `update`, binding table install,
     resolver output, and mailbox delivery.

2. **Direct assignment completion**
   - Add both-hand pair sources/actions to the rebuild model, then port the legacy
     center pair chips.
   - Add default hand profiles so first launch is useful without manual setup.

3. **Platform-equivalent input sources**
   - Promote the model from hand-only `GestureSource` toward a broader `InputSource`
     without breaking existing hand persistence keys.
   - Route macOS keyboard/mouse and iPad touch through the same resolver/action seam.

4. **Legacy feel ports**
   - Port relative gestures, per-parameter sensitivity, two-hand distance guardrails,
     menu-toggle gesture options, and per-finger tap behaviors as detector/settings
     logic over the rebuild binding model.

5. **MIDI-ready seam**
   - Reserve MIDI source IDs and persistence shape, but defer CoreMIDI implementation
     until the platform input resolver is stable.

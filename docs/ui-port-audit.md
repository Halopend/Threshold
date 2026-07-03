# UI port audit — legacy MetalRaymarch → Threshold

Status of the UI port from the original app (`Polinate/TEMP/MetalRaymarch-main`)
into the rebuild, and the ranked list of what's still missing. Direction
(user-confirmed 2026-07-03): the rebuild's tabbed organization wins — port
legacy **features into** the new structure, don't mirror the legacy layout.
Music/audio UI is deferred entirely for now.

## Landed (2026-07-03)

| Area | What |
|---|---|
| Design system | `DS.Spacing` / `DS.Radius` tokens, `moduleCard` tinted cards, `SectionHeader`, panel text-size steps (`DS.textSizeSteps`) |
| Components | `TabStrip` (generic icon-chip tabs), `EffectSliderRow` (icon + label + slider + value/toggle), `StatBox`, `GradientPreviewBar`, `RowLabel`/`RowValueText` shared row geometry, `DisplayIcons` |
| Navigation | `ControlTab` strip: Scenes · Fractal · Warps · Color · Motion · Perf · Setup; selection + text size persist via AppStorage |
| Fractal tab | Switcher grid with icons, active-DE-only Shape card (equation line, prettified param names, Reset-to-defaults) |
| Warps tab | Op cards (index badge, family icon, reorder/delete, strength), families add-menu; Hands toggles fold in here on visionOS |
| Color tab | Palette card (preview, tappable 14-preset grid with active outline, stop editor), Mapping card (named mode picker + repeat/offset/smoothing), Grading card |
| Motion tab | Infinite Zoom card (depth readout), Animation transport (+ empty state), Camera rig card |
| Perf tab | Session stat tiles, pipeline card, engine quality params |
| Scenes tab | `SceneLibrary` (folder of .threshscene in Application Support) + card grid: save-current-by-name, tap-to-load, delete. Library items show palette gradient + fractal + date |
| Settings tab | Display (panel text size), Input (orbit/dolly sensitivity, invert scroll — read live by `CameraInteraction`), keyboard-nav toggle + legend |
| Keyboard nav | macOS: arrows orbit, W/S / +/− dolly, ⇧ boost, R reset (`KeyboardCameraNav`, skips text fields) |
| Image export | `captureImage` session command → offscreen render of the live frame at export size → PNG file exporter (macOS/iOS); covered by `LiveCaptureTests` |

Bugs found while porting: the app target shipped
`ENABLE_USER_SELECTED_FILES = readonly`, so **every save/export dialog was
write-blocked** (now readwrite); capture polling was iteration-bounded and
fragile under main-actor load (now wall-clock deadlines + `os_log` under
subsystem `com.pupppower.threshold`); stacked presentation modifiers on one
view node could silently drop the error alert (now split across nodes).
The Scenes save spinner observed once in-session is still unexplained — the
new logging pins it down on next occurrence.

## Missing — user-named priorities

1. **Scenes, beyond v1**: thumbnails on cards (render via `captureImage` at
   save time — machinery now exists), categories (legacy Jumping Off / Animated
   / Mixed / Custom), bundled example scenes, "edited" badges, overwrite
   protection. Pure app-side work.
2. **Gestures config**: desktop feel-tuning landed under Settings ▸ Input;
   missing the visionOS surface — hand-tracking status view, per-hand
   assignments, relative-gestures toggle, menu-toggle gesture, per-finger taps.
   Needs `ThresholdInputs` signals beyond what HandTracker publishes today.
3. **Advanced settings**: governor target override UI, export size/format
   preferences, reset-all-device-state. Small, app-side.
4. **Exporting on iOS**: entitlement fix unblocks the Files-based exporters;
   still missing a share-sheet path (UIActivityViewController) for scenes and
   PNGs, and any visionOS export story (compositor has no flat frame — needs
   an offscreen render from scene state instead of the live request).
5. **Keyboard navigation on iPad**: hardware-keyboard equivalent of the macOS
   monitor (UIKeyCommand / `onKeyPress`).

## Missing — renderer-gated (engine work before any UI)

- **Atmosphere effects**: glow, bloom, fog + fog tint (legacy Effects ▸ Static).
- **Dynamic color modules**: gradient cycle (+ mirror loop), hue rotation,
  fog hue cycle, pulse, color-shift-speed master, linear rail (axis/reach/
  harmonic/orbit), polar rotation. These are shader + param-catalog features;
  the UI pattern (EffectSliderRow in tinted cards) is ready for them.
- **Scene transition timing**: legacy same-scene crossfade (0–3 s). Needs a
  transition mechanism in the modulation engine (lane-lerp on scene apply).
- **Bounding/performance shapes**: legacy Bounding tab (bounding-shape toggle
  exists as a warp kind but has no authoring UI).

## Missing — app-side, no renderer dependency

- **Quick Toggles** grid (master on/off switches across features).
- **Warp op payload editors**: per-kind axis/scalar controls beyond strength
  (legacy Transform cards had p1/p2/axis + self-doc). Needs per-kind UI
  metadata table over `WarpOpDTO` payload lanes.
- **Save-with-thumbnail flow** (legacy SaveDestinationSheet with preview).
- **Error banner** (severity-tinted, auto-dismissing — currently alert-only).
- **Onboarding / first-launch window**, menu-bar commands (⌘S, ⌘R, ⌘1…7 tabs),
  `AutoExpandingPopover`, and glass chrome (`dsGlass`) polish.
- **iOS shell polish**: inspector-style slide-over panel, controls toggle
  button, touch indicators (legacy iOS root view).

## Deferred by decision

- All Music/audio-reactive UI (library window, band mappings, derived-value
  ghost markers) — revisit after the music lane grows its signal set.

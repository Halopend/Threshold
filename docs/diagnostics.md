# Diagnostics

The rebuild identifies itself as **Threshold Rebuild**, uses bundle identifier
`com.pupppower.thresholdb3`, and writes unified logs under
`com.pupppower.threshold.rebuild`. This keeps its reports separate from the original
MetalRaymarch application.

## Persistent files

Breadcrumbs, unclean-exit state, and MetricKit diagnostic payloads are stored in the
app container's Application Support directory under:

```text
ThresholdRebuild/Diagnostics/
```

`breadcrumbs.jsonl` is capped at 512 KiB and rotated once to
`breadcrumbs.previous.jsonl`. `session.json` records build identity and whether the
last session exited cleanly. MetricKit crash/hang payloads are retained as timestamped
JSON files.

## Diagnostic switches

Set an environment variable to `1`, `true`, `yes`, or `on`:

| Environment variable | Effect |
|---|---|
| `THRESHOLD_DIAG_DISABLE_METALFX` | Full-resolution fallback; no temporal scaler |
| `THRESHOLD_DIAG_DISABLE_SPECIALIZATION` | Generic Metal pipeline only |
| `THRESHOLD_DIAG_DISABLE_EXTERNAL_DE` | Reject runtime-compiled scene formulas |
| `THRESHOLD_DIAG_DISABLE_ANIMATION` | Ignore animation clips and transport |
| `THRESHOLD_DIAG_DISABLE_AUDIO` | Reject microphone capture start |
| `THRESHOLD_DIAG_DISABLE_HANDS` | Do not start ARKit hand tracking |
| `THRESHOLD_DIAG_DISABLE_TRANSITIONS` | Scene loads snap instead of tweening |
| `THRESHOLD_GPU_FAULTS` | Record per-encoder Metal execution status |

Each switch also has a persistent `UserDefaults` key:

```text
com.pupppower.threshold.rebuild.diagnostics.<switchName>
```

For example:

```sh
defaults write com.pupppower.thresholdb3 \
  com.pupppower.threshold.rebuild.diagnostics.disableMetalFX -bool true
```

Remove a persistent switch with `defaults delete` using the same domain and key.

## Unified logs

```sh
log stream --predicate 'subsystem == "com.pupppower.threshold.rebuild"' --info
```

Breadcrumbs intentionally contain low-rate lifecycle, scene, pipeline, input, hang,
and GPU-fault events only. Per-frame telemetry remains in Instruments/signposts.

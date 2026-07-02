# Corpus — golden scenes and reference images

- `scenes/` — canonical `.threshscene` files rendered per-commit (plan §9).
- `golden/` — byte-golden PNGs for `scenes/`, rendered on Apple silicon
  (M-family GPU). Byte-compare is valid within one GPU family; across
  families use a perceptual compare (not yet implemented). Regenerate:

  ```
  swift build --build-system native --product threshold-render
  .build/debug/threshold-render Corpus/scenes/<name>.threshscene --out Corpus/golden/<name>.png
  ```

  Gate (exit 2 on mismatch):

  ```
  .build/debug/threshold-render Corpus/scenes/<name>.threshscene \
      --out /tmp/<name>.png --compare Corpus/golden/<name>.png
  ```

- `legacy/` — (pending) scenes exported from the shipping app, replayed
  through the migration table per commit (ADR build-order Phase 0; capture
  them while the old app still runs — see PLAN.md §7.3's cautionary tale).

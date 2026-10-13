# Euclid

Fast macOS launcher: clipboard history + calculator + AI. Swift + AppKit.

## Run

```sh
make run     # build build/Euclid.app and launch it
make test    # unit tests
make perf    # release-mode search benchmark
make log     # live timings (show / search)
```

Hotkey: `⌥Space` (configurable later via settings). Dev hook: `open euclid://toggle`.

## Speed budgets

| Moment | Target |
|---|---|
| Hotkey → panel visible | < 30 ms |
| Keystroke → results drawn | < 8 ms |
| Idle memory | < 50 MB |

## Layout

```
Sources/EuclidCore   UI-free logic (search; later calculator, AI)
Sources/Euclid       AppKit app (hotkey, panel, results)
Tests/               Swift Testing
```

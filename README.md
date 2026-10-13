# Euclid

Fast macOS launcher: clipboard history + calculator + AI. Swift + AppKit.

## Run

```sh
make run     # build build/Euclid.app and launch it
make test    # unit tests
make perf    # release-mode search benchmark
make log     # live timings (show / search)
make cert    # one-time: stable signing identity so Accessibility permission survives rebuilds
```

## Keys

| Key | Action |
|---|---|
| `⌥Space` | Toggle panel |
| `↵` | Paste into the previous app (needs Accessibility permission; copy-only until granted) |
| `⌘C` | Copy entry |
| `⌘⌫` | Delete entry |
| `esc` | Close |

History lives in `~/Library/Application Support/Euclid/history.sqlite` (last 5,000 text entries).
Password-manager copies (`org.nspasteboard.ConcealedType` etc.) are never recorded.

Hotkey: `⌥Space` (configurable later via settings). Dev hook: `open euclid://toggle`.

## Speed budgets

| Moment | Target |
|---|---|
| Hotkey → panel visible | < 30 ms |
| Keystroke → results drawn | < 8 ms |
| Idle memory (phys footprint) | < 50 MB |

## Layout

```
Sources/EuclidCore   UI-free logic (search; later calculator, AI)
Sources/Euclid       AppKit app (hotkey, panel, results)
Tests/               Swift Testing
```

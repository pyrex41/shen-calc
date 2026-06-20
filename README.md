# ShenCalc

A SwiftUI iOS **symbolic calculator** powered by the [shen-cas](../shen-cas)
computer-algebra system — tree-shaken with [ratatoskr](../ratatoskr), embedded
in [shen-rust](../shen-rust) via the [shenffi](../shen-rust/crates/shenffi) C
ABI, and called from Swift.

```
input ─▶ MathInterpreter ─▶ shen-cas syntax ─▶ ShenCAS (shenffi/shen-rust) ─▶ result
 │              │                "D[Sin[x],x]"        tree-shaken CAS            "[Cos x]"
 │        Phase 1: passthrough (type syntax directly)
 │        Phase 2: on-device Gemma (English / photo → syntax)
```

The model (Phase 2) only **parses intent** into shen-cas's grammar; the CAS does
the actual math — so a wrong derivative is impossible. At worst the model emits
syntax the CAS rejects.

## Status

- **Phase 1 (done, verified on the simulator):** the calculator. Type shen-cas
  syntax — `D[Sin[x], x]` → `[Cos x]`, `D[x^3, x]` → `[Times [Power x 2] 3]`,
  `6/4` → `[3 / 2]`. The CAS runs fully on-device with no network, no model.
- **Phase 2 (wired, opt-in, device-only):** English + photo input via an
  on-device Gemma model (MLX). Code is in `MLXInterpreter.swift`, gated behind
  `#if canImport(MLXLMCommon)` so the app builds without it.

## Architecture

| file | role |
|------|------|
| `ShenCAS.swift` | Boots shen-cas on a 256 MB-stack thread (tree-walked CAS recursion needs it) and serves `reduce` calls via the shenffi C ABI |
| `MathInterpreter.swift` | `MathInterpreter` protocol; `PassthroughInterpreter` (syntax mode); `NLEngine` factory (returns the MLX interpreter when available) |
| `MLXInterpreter.swift` | On-device Gemma → shen-cas syntax (text via LLM, photos via VLM). `#if canImport`-gated |
| `ContentView.swift` | The UI: transcript, example chips, Syntax/English/Photo mode picker, photo picker |
| `Bridging-Header.h` | `#include "shenffi.h"` |

## Build & run (Phase 1, simulator)

Requires the shenffi xcframework — build it first:
```sh
../shen-rust/crates/shenffi/build-xcframework.sh   # -> ../shen-rust/target/ShenRust.xcframework
xcodegen generate
open ShenCalc.xcodeproj         # ⌘R on a simulator or device
```
Headless (the shenffi simulator slice is arm64-only, so exclude x86_64):
```sh
xcodebuild -scheme ShenCalc -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  EXCLUDED_ARCHS=x86_64 CODE_SIGNING_ALLOWED=NO build
```

## Enabling Phase 2 (on-device Gemma, real device)

mlx-swift needs Metal — it does **not** run on the simulator. On a real device:

1. In `project.yml`, uncomment the `mlx-swift-lm` package + the three `MLX*`
   product dependencies, and set `deploymentTarget: iOS: "17.0"`. Re-run
   `xcodegen generate`. (Or add the package in Xcode: File ▸ Add Package
   Dependencies ▸ `https://github.com/ml-explore/mlx-swift-lm` — pin a **release
   tag**, not `main`; products `MLXLLM`, `MLXVLM`, `MLXLMCommon`, `MLXHuggingFace`.)
2. The app's `ShenCalc.entitlements` already requests
   `com.apple.developer.kernel.increased-memory-limit` (needed to hold the model
   weights). Use a provisioning profile that grants it.
3. Set the model ids in `MLXInterpreter.swift` to an MLX-converted Gemma build
   (text + a multimodal VLM for photos). Weights download on first use.

`MLXInterpreter` activates automatically once the package is linked. Note: the
exact `loadModel(...)` call tracks the package version — follow your pinned
release's README if it differs (the `ChatSession` / `respond` shape is stable).

> Run Shen off the main thread with a large stack (see `ShenCAS.swift`) — the
> tree-walked CAS reducer overflows a small stack.

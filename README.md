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

- **Phase 1 (done, verified on device):** the calculator + a custom math
  keyboard. Type shen-cas syntax — `D[Sin[x], x]` → `[Cos x]`,
  `Integrate[x^2, x]` → `[Times [Power x 3] [1 / 3]]`, `Factor[x^2 - 1]` →
  `[Times [Plus x 1] [Plus x -1]]`, `Solve[x^2 - 4, x]` → `[List 2 -2]`. The CAS
  runs fully on-device with no network, no model.
- **Phase 2 (built into the device build):** English + photo input via an
  on-device Gemma model (MLX). Code is in `MLXInterpreter.swift`, gated behind
  `#if canImport(MLXLMCommon)`. The MLX packages are now linked in `project.yml`
  (so a device build activates it); they build only on a real device (Metal), so
  simulator builds still work — `canImport` simply sees no MLX there.

## Math keyboard

Syntax mode replaces the system keyboard with a custom calculator keyboard
(`MathKeyboard.swift`, installed as the text field's `inputView`). The accent row
scrolls through the operations the embedded CAS actually evaluates — `d/dx`,
`∫ dx`, `Solve`, `Simplify`, `Expand`, `Factor`, `sin`/`cos`/`tan`, `eˣ`, `ln`,
`√` — each inserting a template (`D[▮, x]`, `Sin[▮]`, …) with the caret dropped
where you type next. Below is a numeric/operator grid (digits, `x` `y`, `^` `(` `)`
`,` and `+ − × ÷`) plus delete / clear / ↵. English and Photo modes fall back to
the system keyboard. (`Series`/`Limit` echo unevaluated in this shaken slice, so
they're intentionally left off the keys.)

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

## Run on your own iPhone with Gemma (Phase 2)

mlx-swift needs Metal, so this is **device only** (iOS 17+, iPhone 12 or newer;
an 8 GB iPhone — 15 Pro / 16 — is strongly preferred). You can run on your own
phone with a **free Apple ID**; a paid account is only needed for the big
multimodal vision model.

### Pick a model for your account

| Account | Model | Size | Modes |
|---|---|---|---|
| **Free** (default) | `mlx-community/gemma-3-1b-it-qat-4bit` | ~733 MB | English → syntax (text) |
| **Paid** + entitlement | `mlx-community/gemma-4-e4b-it-4bit` | ~5.2 GB | English **and** photo (multimodal) |

Without the memory entitlement iOS kills an app around ~50% of RAM, so the small
text model is the safe default (already set in `MLXInterpreter.swift`). The
vision/photo model needs the entitlement (paid account) — see below.

### Steps

1. **Packages are already linked** in `project.yml` (mlx-swift-lm **3.31.3**:
   `MLXLLM`/`MLXVLM`/`MLXLMCommon`/`MLXHuggingFace`; swift-transformers **1.3.x**:
   `Hub`/`Tokenizers`) and the deployment target is **iOS 17**. Just
   `xcodegen generate` and resolve packages (`xcodebuild
   -resolvePackageDependencies`).
2. **One-time toolchain bits** the MLX build needs:
   - Trust the package macros: in Xcode it's a click; on the CLI add
     `-skipMacroValidation` to `xcodebuild`.
   - Install the Metal Toolchain (MLX compiles Metal shaders at build time):
     `xcodebuild -downloadComponent MetalToolchain` (~690 MB, one time).
3. **Sign for your device:** target ▸ Signing & Capabilities ▸ Team = your
   *Personal Team* (free Apple ID), Automatically manage signing. Plug in the
   phone, pick it as the run destination, ⌘R. First launch: on the phone,
   Settings ▸ General ▸ VPN & Device Management ▸ trust your developer cert,
   then run again. (Free profiles expire every 7 days — just re-run from Xcode.)
4. **First run downloads the model** from Hugging Face (~0.7 GB for the default).
   The UI shows the engine status; give it a minute on first launch.

### Paid account → photo (vision) mode

Add `CODE_SIGN_ENTITLEMENTS: ShenCalc/ShenCalc.entitlements` to the target
(grants `increased-memory-limit`, already in the repo). The default
`visionModelId` is `gemma-4-e4b-it-4bit`; for a lighter one use
`mlx-community/gemma-3-4b-it-4bit` (~3.4 GB).

### Notes

- `MLXInterpreter` activates automatically once the packages are linked (it's
  `#if canImport`-gated; the app builds fine without them).
- The model only **translates intent** into shen-cas syntax — the CAS computes
  the answer, so it can't be a wrong derivative, only rejected syntax.
- The model-load call is verified against mlx-swift-lm **3.31.3**
  (`loadModelContainer(from: #hubDownloader(), using: #huggingFaceTokenizerLoader(), id:)`).
  If you bump the version and it differs, copy the load call from the package's
  LLMEval example — only that one line moves.

> Run Shen off the main thread with a large stack (see `ShenCAS.swift`) — the
> tree-walked CAS reducer overflows a small stack.

## Run as a native macOS app

There's a native macOS target (`ShenCalcMac`) that shares every source file with
the iOS app — same Rust CAS, same SwiftUI UI, same MLX model stack. Unlike the
iOS *simulator* (which can't run MLX/Metal), MLX runs natively on Apple silicon,
so **English/Photo modes and the model picker actually work on the Mac** — handy
for iterating on the on-device model without an iPhone.

```sh
# 1. Build the Rust CAS with a macOS slice (adds macos-arm64 to the xcframework)
../shen-rust/crates/shenffi/build-xcframework.sh

# 2. Generate the project and build/run the Mac target
xcodegen generate
xcodebuild -scheme ShenCalcMac -destination 'platform=macOS' \
  -derivedDataPath build-mac -skipMacroValidation build
open build-mac/Build/Products/Debug/ShenCalc.app
```

Notes:
- Requires **macOS 14+** on Apple silicon (MLX needs Metal).
- The on-screen math keypad is iOS-only; on the Mac, Syntax mode uses a plain
  text field with the physical keyboard (`MathKeyboard.swift` is
  `#if os(iOS)`-gated with a macOS shim).
- First use of English/Photo downloads the selected model from Hugging Face.

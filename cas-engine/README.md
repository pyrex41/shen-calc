# cas-engine — embedded shen-cas computer-algebra engine

The [shen-cas](../../shen-cas) computer-algebra system, tree-shaken by
[ratatoskr](../../ratatoskr) into a minimal kernel slice (`cas/cas-kernel.kl`)
plus the CAS compiled to KLambda (`cas/cas-all.kl`), both `include_str!`-embedded
so the engine boots with **no filesystem access**.

This crate lives in **shen-calc** (the app that uses it), not in shen-rust, so
shen-rust's generic [`shenffi`](../../shen-rust/crates/shenffi) C-ABI crate stays
program-agnostic. It depends only on the `shen-rust` interpreter crate.

## Two surfaces

- **Rust** — `cas_engine::CasEngine` (`boot()` / `reduce(&str) -> String`), linked
  as an `rlib` by the iced app ([`../shencalc-iced`](../shencalc-iced)).
- **C ABI** — `shen_cas_boot` / `shen_cas_reduce` / `shen_string_free` /
  `shen_free` (see [`include/shencas.h`](include/shencas.h)), packaged as
  `ShenCAS.xcframework` for the SwiftUI app ([`../ShenCalc`](../ShenCalc)).

Both drive the CAS's own `parse-expr-string → reduce → pretty-expr → shen.app`
pipeline directly — no Shen-level `eval`, so the eval-stripped shaken slice is
enough. `"D[Sin[x],x]"` → `"[Cos x]"`.

> The reducer is deeply recursive and tree-walked, so call `boot`/`reduce` from a
> thread with a large stack (≥ ~16 MB; the default 8 MB overflows on boot).

## Build

```sh
# Rust (rlib for the iced app, or a quick check):
cargo build --release

# Swift xcframework (iOS device + simulator + macOS):
./build-xcframework.sh            # -> target/ShenCAS.xcframework

# Standalone Swift round-trip demo (macOS):
cargo build --release             # -> target/release/libcas_engine.a
swiftc -O -import-objc-header include/shencas.h swift/cas-demo.swift \
  -L target/release -lcas_engine -o /tmp/cas_demo && /tmp/cas_demo
```

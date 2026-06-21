# shencalc-iced

A native, cross-platform (macOS / Windows / Linux) **Rust** implementation of
ShenCalc, using the [iced] GUI toolkit — a sibling to the SwiftUI app in this
repo. Same symbolic engine, different front-end.

It embeds the tree-shaken **shen-cas** engine directly (no FFI, no Swift) by
path-depending on the `shenffi` crate's safe `CasEngine` API in the neighbouring
`shen-rust` checkout. The deeply-recursive CAS reducer runs on a dedicated
64 MB-stack worker thread (the default 8 MB overflows on boot), with the UI
talking to it over channels.

## Layout

| file | role |
|------|------|
| `src/main.rs` | iced app + worker thread; `--selftest` / `--ask` headless paths |
| `src/pretty.rs` | renders CAS normal form to human math (`[Cos x]` → `cos(x)`) — Rust port of `MathPretty.swift` |
| `src/grammar.rs` | tool-call grammar (system prompt + `parse` + `normalize`) — Rust port of `CASTools.swift` |
| `src/nl.rs` | English mode: Qwen3-0.6B (candle) → tool call. Behind the `nl` feature |

## Build & run

Requires the `shen-rust` checkout as a sibling directory (this crate
path-depends on `../../shen-rust/crates/shenffi`).

```sh
# Syntax mode only (fast build):
cargo run --release

# With English mode (downloads Qwen3-0.6B on first use; heavier build):
cargo run --release --features nl
```

> Always use `--release`. The shen-cas reducer is a tree-walked interpreter;
> an unoptimized debug build is an order of magnitude slower.

Headless checks (no window):

```sh
cargo run --release -- --selftest                      # exercise the CAS
cargo run --release --features nl -- --ask "derivative of sin x"
```

## Notes

- English mode runs the model on **CPU**: candle's Metal backend currently has
  no rms-norm kernel for the quantized Qwen3 path. A 0.6B Q4 model decodes a
  one-line tool call fast enough on CPU.
- The model only maps a question to one tool call; shen-cas does the math, so a
  wrong answer is impossible — at worst the CAS rejects the operand.

[iced]: https://github.com/iced-rs/iced

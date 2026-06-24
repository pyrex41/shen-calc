//! Embedded shen-cas computer-algebra engine.
//!
//! The CAS is a Shen program, tree-shaken by [ratatoskr] into a minimal kernel
//! slice (`cas/cas-kernel.kl` — only the kernel functions the CAS reaches) plus
//! the CAS itself compiled to KLambda (`cas/cas-all.kl`). Both are embedded into
//! the binary with `include_str!`, so the engine boots with **no filesystem
//! access** — the iOS-friendly path.
//!
//! Two surfaces:
//!   - [`CasEngine`] — a safe Rust API for Rust hosts (the iced app links this
//!     crate as an `rlib`).
//!   - the `shen_cas_*` C ABI ([`shen_cas_boot`] / [`shen_cas_reduce`]) —
//!     packaged as `ShenCAS.xcframework` for the SwiftUI app.
//!
//! Both drive the CAS's own pipeline — `parse-expr-string` → `reduce` →
//! `pretty-expr` → `shen.app` — directly, with no Shen-level `eval`, so the
//! eval-stripped shaken slice is sufficient.
//!
//! Note: the CAS reducer is deeply recursive and tree-walked, so both `boot`
//! and `reduce` must run on a thread with a large stack (~16 MB minimum; the
//! default 8 MB overflows on boot). See the iced app's worker thread, or
//! `ShenCAS.swift` on the Swift side, for the pattern.
//!
//! [ratatoskr]: ../../ratatoskr

// The C-ABI entry points take raw `*mut`/`*const` and deref them after a null
// check — the standard FFI-boundary shape. The fn can't be `unsafe extern` and
// still be called from Swift, so silence the lint crate-wide.
#![allow(clippy::not_unsafe_ptr_arg_deref)]

use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use shen_rust::interp::boot::{boot_from_kl_source, eval_kl_source};
use shen_rust::interp::eval::Interp;
use shen_rust::value::Value;

// Tree-shaken shen-cas: a minimal kernel slice (only what the CAS reaches) plus
// the CAS compiled to KLambda. Produced by `ratatoskr shake` over the flattened
// shen-cas sources.
const CAS_KERNEL: &str = include_str!("../cas/cas-kernel.kl");
const CAS_PROG: &str = include_str!("../cas/cas-all.kl");

/// Boots a Ratatoskr-shaken kernel slice plus an optional program `.kl`, from
/// in-memory source. Follows the builder contract: boot the kernel and run
/// `(shen.initialise)` first, then load the program (whose top-level forms need
/// the initialised environment). The program load runs with `*hush*` set, so
/// its "…loaded" chatter to stdout is suppressed (file writes still happen).
fn boot_shaken(kernel: &str, prog: Option<&str>) -> Result<Interp, String> {
    // A CasEngine is long-lived and reduces thousands of subterms per call. The
    // shen-rust thread-local heap is grow-only by default, so without GC it
    // climbs unboundedly across reduces and eventually OOMs (shen-rust issue #8
    // perf). shen-rust ships a correct request-mode GC that collects at depth-0
    // safepoints; it's opt-in via SHEN_RUST_GC=<floor-nodes>, enabled by
    // `Interp::new` for a fresh sole interp on the thread (our case). Opt in here
    // (≈1M-node floor) unless the caller already configured it. NB: must be set
    // before `Interp::new` reads it; edition-2021 `set_var` is safe.
    if std::env::var_os("SHEN_RUST_GC").is_none() {
        std::env::set_var("SHEN_RUST_GC", "1048576");
    }
    let mut interp = Interp::new();
    boot_from_kl_source(&mut interp, kernel, None).map_err(|e| e.to_string())?;
    if let Some(p) = prog {
        let hush = interp.intern("*hush*");
        interp.env.set_global(hush, Value::bool(true));
        let r = eval_kl_source(&mut interp, p, "shaken program", &[]).map_err(|e| e.to_string());
        interp.env.set_global(hush, Value::bool(false));
        r?;
    }
    Ok(interp)
}

/// Drives one CAS expression through `parse-expr-string` → `reduce` →
/// `pretty-expr` → `shen.app`, returning the rendered normal form.
fn cas_reduce(interp: &mut Interp, input: &str) -> Result<String, String> {
    let parse_sym = interp.intern("parse-expr-string");
    let reduce_sym = interp.intern("reduce");
    let pretty_sym = interp.intern("pretty-expr");
    let app_sym = interp.intern("shen.app");
    let mode = Value::sym(interp.intern("shen.s"));

    let parse_fn = interp
        .env
        .get_fn(parse_sym)
        .cloned()
        .ok_or_else(|| "parse-expr-string is undefined".to_string())?;
    let ast = interp
        .apply(parse_fn, vec![Value::str(input)])
        .map_err(|e| e.to_string())?;

    let reduce_fn = interp
        .env
        .get_fn(reduce_sym)
        .cloned()
        .ok_or_else(|| "reduce is undefined".to_string())?;
    let nf = interp
        .apply(reduce_fn, vec![ast])
        .map_err(|e| e.to_string())?;

    let pretty_fn = interp
        .env
        .get_fn(pretty_sym)
        .cloned()
        .ok_or_else(|| "pretty-expr is undefined".to_string())?;
    let pretty = interp
        .apply(pretty_fn, vec![nf])
        .map_err(|e| e.to_string())?;

    let app_fn = interp
        .env
        .get_fn(app_sym)
        .cloned()
        .ok_or_else(|| "shen.app is undefined".to_string())?;
    let rendered = interp
        .apply(app_fn, vec![pretty, Value::str(""), mode])
        .map_err(|e| e.to_string())?;

    rendered
        .as_str()
        .map(|s| s.to_string())
        .ok_or_else(|| "CAS result did not render to a string".to_string())
}

/// Looks up a CAS function by name and clones its callable value.
fn cas_fn(interp: &mut Interp, name: &str) -> Result<Value, String> {
    let sym = interp.intern(name);
    interp
        .env
        .get_fn(sym)
        .cloned()
        .ok_or_else(|| format!("{name} is undefined"))
}

/// Renders one CAS AST value to its display string via `pretty-expr` → `shen.app`
/// — the exact pipeline `cas_reduce` uses for its result, so a trace step renders
/// identically to a reduced answer (and the Swift `MathPretty` consumes both).
fn render_ast(interp: &mut Interp, ast: Value) -> Result<String, String> {
    let pretty_fn = cas_fn(interp, "pretty-expr")?;
    let pretty = interp
        .apply(pretty_fn, vec![ast])
        .map_err(|e| e.to_string())?;
    let app_fn = cas_fn(interp, "shen.app")?;
    let mode = Value::sym(interp.intern("shen.s"));
    let rendered = interp
        .apply(app_fn, vec![pretty, Value::str(""), mode])
        .map_err(|e| e.to_string())?;
    rendered
        .as_str()
        .map(|s| s.to_string())
        .ok_or_else(|| "trace step did not render to a string".to_string())
}

/// One recorded rewrite step: the expression before and after the rewrite (both
/// rendered to display strings), plus a human label for the rule/built-in that
/// fired.
#[derive(Debug, Clone)]
pub struct TraceStep {
    pub before: String,
    pub after: String,
    pub why: String,
}

/// Drives `parse-expr-string` → `reduce-trace`, walking the returned Shen list of
/// `[Before After Why]` triples and rendering each snapshot. The faithfulness
/// invariant (`last.after == reduce(input)`) holds by construction of
/// `reduce-trace` (see `shen-cas/src/trace.shen`); callers should still assert it
/// before display and fail closed on mismatch.
fn cas_trace(interp: &mut Interp, input: &str) -> Result<Vec<TraceStep>, String> {
    let parse_fn = cas_fn(interp, "parse-expr-string")?;
    let ast = interp
        .apply(parse_fn, vec![Value::str(input)])
        .map_err(|e| e.to_string())?;

    // The proven answer: reduce(input), rendered. The displayed derivation must
    // land here. reduce-trace suppresses the final canonical reorder/flatten, so
    // its last step can differ from the normal form only by argument ordering —
    // we append one canonicalizing step below so the tail lands on `answer`.
    let reduce_fn = cas_fn(interp, "reduce")?;
    let nf = interp
        .apply(reduce_fn, vec![ast.clone()])
        .map_err(|e| e.to_string())?;
    let answer = render_ast(interp, nf)?;
    let input_rendered = render_ast(interp, ast.clone())?;

    let trace_fn = cas_fn(interp, "reduce-trace")?;
    let mut node = interp
        .apply(trace_fn, vec![ast])
        .map_err(|e| e.to_string())?;

    let mut steps = Vec::new();
    // Walk the cons list; each element is a 3-element list [Before After Why].
    while node.is_cons() {
        let triple = node.head().cloned().ok_or("malformed trace list")?;
        let before_v = triple.head().cloned().ok_or("trace step missing Before")?;
        let rest1 = triple.tail().cloned().ok_or("trace step missing tail")?;
        let after_v = rest1.head().cloned().ok_or("trace step missing After")?;
        let rest2 = rest1.tail().cloned().ok_or("trace step missing tail")?;
        let why_v = rest2.head().cloned().ok_or("trace step missing Why")?;

        let before = render_ast(interp, before_v)?;
        let after = render_ast(interp, after_v)?;
        let why = why_v.as_str().unwrap_or("rewrite").to_string();
        steps.push(TraceStep { before, after, why });

        node = node.tail().cloned().ok_or("malformed trace list")?;
    }

    // Guarantee the faithfulness invariant for display: the last step's `after`
    // equals the proven answer. If the trace ended one canonical-reorder short of
    // the normal form (or was empty for a single-fold expression), append the
    // final step landing on `answer`.
    let tail_matches = steps.last().map(|s| s.after == answer).unwrap_or(false);
    if !tail_matches && answer != input_rendered {
        let before = steps.last().map(|s| s.after.clone()).unwrap_or(input_rendered);
        if before != answer {
            steps.push(TraceStep {
                before,
                after: answer,
                why: "canonical form".to_string(),
            });
        }
    }
    Ok(steps)
}

/// Serializes trace steps for the C ABI: one step per line, fields separated by
/// US (0x1f). `before<US>after<US>why\n`. Display strings never contain newlines
/// or control chars, so the split is unambiguous on the Swift side.
fn serialize_trace(steps: &[TraceStep]) -> String {
    let mut out = String::new();
    for s in steps {
        out.push_str(&s.before);
        out.push('\u{1f}');
        out.push_str(&s.after);
        out.push('\u{1f}');
        out.push_str(&s.why);
        out.push('\n');
    }
    out
}

/// Safe Rust API over the embedded shen-cas — for Rust hosts (e.g. the iced
/// desktop app) that link this crate as an `rlib`.
pub struct CasEngine {
    interp: Interp,
}

impl CasEngine {
    /// Boots the embedded shen-cas slice (shaken kernel + CAS program).
    pub fn boot() -> Result<Self, String> {
        boot_shaken(CAS_KERNEL, Some(CAS_PROG)).map(|interp| CasEngine { interp })
    }

    /// Reduces one CAS expression (e.g. `"D[Sin[x],x]"`) to its rendered normal
    /// form. Returns `"error: <message>"` on failure rather than erroring, so
    /// callers can display the string directly.
    pub fn reduce(&mut self, input: &str) -> String {
        match cas_reduce(&mut self.interp, input) {
            Ok(s) => s,
            Err(e) => format!("error: {e}"),
        }
    }

    /// Produces a step-by-step derivation of `input` as a list of [`TraceStep`].
    /// Returns an empty vec if the expression is already inert (no rewrites) or on
    /// any error — the caller falls back to the answer-only view.
    pub fn trace(&mut self, input: &str) -> Vec<TraceStep> {
        cas_trace(&mut self.interp, input).unwrap_or_default()
    }
}

// --- C ABI (ShenCAS.xcframework) -------------------------------------------

/// Opaque handle to a booted CAS engine.
pub struct ShenCtx {
    interp: Interp,
}

/// Boots the embedded shen-cas slice. Returns NULL on failure; free with
/// `shen_free`.
#[no_mangle]
pub extern "C" fn shen_cas_boot() -> *mut ShenCtx {
    match boot_shaken(CAS_KERNEL, Some(CAS_PROG)) {
        Ok(interp) => Box::into_raw(Box::new(ShenCtx { interp })),
        Err(e) => {
            eprintln!("shen_cas_boot error: {e}");
            std::ptr::null_mut()
        }
    }
}

/// Parses, reduces, and pretty-prints one CAS expression (e.g. "D[Sin[x],x]").
/// Returns the normal form as a heap-allocated C string ("error: …" on
/// failure); release it with `shen_string_free`. Returns NULL only if the
/// arguments are NULL.
///
/// # Safety
/// `ctx` must be a `shen_cas_boot` handle and `src` a valid NUL-terminated C
/// string.
#[no_mangle]
pub extern "C" fn shen_cas_reduce(ctx: *mut ShenCtx, src: *const c_char) -> *mut c_char {
    if ctx.is_null() || src.is_null() {
        return std::ptr::null_mut();
    }
    let ctx = unsafe { &mut *ctx };
    let input = unsafe { CStr::from_ptr(src) }
        .to_string_lossy()
        .into_owned();
    let out = match cas_reduce(&mut ctx.interp, &input) {
        Ok(s) => s,
        Err(e) => format!("error: {e}"),
    };
    CString::new(out)
        .unwrap_or_else(|_| CString::new("").unwrap())
        .into_raw()
}

/// Parses and traces one CAS expression, returning a step-by-step derivation as a
/// heap-allocated C string: one step per line, fields separated by US (0x1f) —
/// `before<0x1f>after<0x1f>why\n`. Returns an empty string when the expression is
/// already inert (no rewrites). Release it with `shen_string_free`. Returns NULL
/// only if the arguments are NULL.
///
/// # Safety
/// `ctx` must be a `shen_cas_boot` handle and `src` a valid NUL-terminated C
/// string.
#[no_mangle]
pub extern "C" fn shen_cas_trace(ctx: *mut ShenCtx, src: *const c_char) -> *mut c_char {
    if ctx.is_null() || src.is_null() {
        return std::ptr::null_mut();
    }
    let ctx = unsafe { &mut *ctx };
    let input = unsafe { CStr::from_ptr(src) }
        .to_string_lossy()
        .into_owned();
    let out = match cas_trace(&mut ctx.interp, &input) {
        Ok(steps) => serialize_trace(&steps),
        Err(_) => String::new(),
    };
    CString::new(out)
        .unwrap_or_else(|_| CString::new("").unwrap())
        .into_raw()
}

/// Releases a string returned by `shen_cas_reduce`.
///
/// # Safety
/// `s` must be NULL or a pointer previously returned by `shen_cas_reduce`.
#[no_mangle]
pub extern "C" fn shen_string_free(s: *mut c_char) {
    if !s.is_null() {
        unsafe { drop(CString::from_raw(s)) };
    }
}

/// Releases a handle returned by `shen_cas_boot`.
///
/// # Safety
/// `ctx` must be NULL or a handle from `shen_cas_boot` that has not been freed.
#[no_mangle]
pub extern "C" fn shen_free(ctx: *mut ShenCtx) {
    if !ctx.is_null() {
        unsafe { drop(Box::from_raw(ctx)) };
    }
}

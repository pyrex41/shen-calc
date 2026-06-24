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

//! Regression guard for shen-rust issue #8: the shen-cas normal-form memo used
//! O(1) equality by content-hash alone (`nf-cache-key = [hash, basis]`, looked
//! up by `assoc`). The kernel hash (`shen.prodbutzero`) collides for distinct
//! long content strings, so a colliding term could be handed another term's
//! cached normal form — producing wrong/inert results that depended on
//! evaluation order within a session (e.g. `D[ArcTan[x],x] = [Times [D x x] …]`
//! with the inner `[D x x]` never reduced).
//!
//! The fix carries the canonical expression in the cache key so `assoc` rejects
//! a hash collision structurally. This test exercises the *failing* path: a
//! single long-lived engine reducing a battery in cold order (a fresh-thread
//! -per-case harness would mask it), and two boots producing identical results.
//!
//! One `#[test]`, run sequentially on a single large-stack thread: the CAS
//! reducer is deeply recursive (the default 8 MB stack overflows on boot), and
//! several concurrent big-stack engines OOM the test runner.

use cas_engine::CasEngine;
use std::thread;

const STACK: usize = 256 * 1024 * 1024;

/// (input, expected normal form) — the answers shen-cas produces under the
/// reference (ShenScript). `D[ArcTan[x],x]` and the cold `D[x+x,x]` / `D[2*x,x]`
/// are the ones that regressed under the unsound memo.
const CASES: &[(&str, &str)] = &[
    ("D[x,x]", "1"),
    ("D[ArcTan[x],x]", "[Power [Plus [Power x 2] 1] -1]"),
    ("D[x+x,x]", "2"),
    ("D[2*x,x]", "2"),
    ("D[Sin[x],x]", "[Cos x]"),
    ("D[x^3,x]", "[Times [Power x 2] 3]"),
    ("Integrate[x^2,x]", "[Times [Power x 3] [1 / 3]]"),
];

#[test]
fn memo_is_sound_and_boot_order_independent() {
    thread::Builder::new()
        .stack_size(STACK)
        .spawn(|| {
            let want: Vec<&str> = CASES.iter().map(|(_, w)| *w).collect();

            // Boot 1: one long-lived engine reduces the whole battery in order —
            // the session-state path that exposed the memo collision.
            let mut e1 = CasEngine::boot().expect("boot 1");
            let got1: Vec<String> = CASES.iter().map(|(i, _)| e1.reduce(i)).collect();
            assert_eq!(got1, want, "first boot produced a wrong/inert reduction");

            // Boot 2 on the same thread (shared thread-local heap): must agree —
            // the boot-order nondeterminism the issue reported.
            let mut e2 = CasEngine::boot().expect("boot 2");
            let got2: Vec<String> = CASES.iter().map(|(i, _)| e2.reduce(i)).collect();
            assert_eq!(got2, got1, "two boots in one process disagree");
        })
        .unwrap()
        .join()
        .unwrap();
}

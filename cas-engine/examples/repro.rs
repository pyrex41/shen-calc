//! Repro for shen-rust issue #8: boot-order-dependent CAS evaluation.
//!
//! Run: `cargo run --example repro` (debug is fine for the correctness signal).
//!
//! Prints three scenarios:
//!   A) two boots on ONE thread (the issue's repro — expected to diverge)
//!   B) two boots, each on its OWN thread (control — fresh thread-local heap)
//! If A diverges but B agrees, the shared per-thread grow-only heap is implicated.

use cas_engine::CasEngine;
use std::thread;

const STACK: usize = 512 * 1024 * 1024;

fn run<F: FnOnce() + Send + 'static>(f: F) {
    thread::Builder::new()
        .stack_size(STACK)
        .spawn(f)
        .unwrap()
        .join()
        .unwrap();
}

fn probe(tag: &str, e: &mut CasEngine) {
    println!("  [{tag}] D[x,x]         = {}", e.reduce("D[x,x]"));
    println!("  [{tag}] D[ArcTan[x],x] = {}", e.reduce("D[ArcTan[x],x]"));
}

fn main() {
    println!("== A: two boots, SAME thread ==");
    run(|| {
        let mut e1 = CasEngine::boot().unwrap();
        probe("e1", &mut e1);
        let mut e2 = CasEngine::boot().unwrap();
        probe("e2", &mut e2);
    });

    println!("== B: two boots, SEPARATE threads ==");
    run(|| {
        let mut e = CasEngine::boot().unwrap();
        probe("t1", &mut e);
    });
    run(|| {
        let mut e = CasEngine::boot().unwrap();
        probe("t2", &mut e);
    });
}

//! Print the step-by-step derivation of each argument (or a default battery),
//! and assert the faithfulness invariant: last step's `after` == reduce(input).
//! `cargo run --release --example trace -- "D[Sin[x], x]" "Expand[(x+1)^2]"`

use cas_engine::CasEngine;
use std::thread;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let cases: Vec<String> = if args.is_empty() {
        ["D[Sin[x], x]", "Expand[(x+1)^2]", "Solve[x^2 - 4, x]", "D[Sin[x^2], x]"]
            .iter()
            .map(|s| s.to_string())
            .collect()
    } else {
        args
    };

    thread::Builder::new()
        .stack_size(512 * 1024 * 1024)
        .spawn(move || {
            for c in &cases {
                let mut e = CasEngine::boot().expect("boot"); // fresh boot per case
                let steps = e.trace(c);
                let answer = e.reduce(c);
                println!("\n# {c}   (=> {answer})");
                for (i, s) in steps.iter().enumerate() {
                    println!("  {}. {}  ->  {}    [{}]", i + 1, s.before, s.after, s.why);
                }
                let faithful = steps.last().map(|s| s.after == answer).unwrap_or(true);
                println!(
                    "  steps={} faithful(last==reduce)={}",
                    steps.len(),
                    if faithful { "YES" } else { "NO !!!" }
                );
            }
        })
        .unwrap()
        .join()
        .unwrap();
}

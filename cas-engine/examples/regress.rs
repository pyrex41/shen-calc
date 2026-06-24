//! Regression battery: reduce a broad set of expressions and print `expr => result`.
//! Used to confirm a re-shaken slice preserves `reduce` behaviour (diff old vs new).
//! Run: `cargo run --release --example regress`

use cas_engine::CasEngine;
use std::thread;

const STACK: usize = 512 * 1024 * 1024;

fn main() {
    let cases = [
                // arithmetic / rationals
                "6/4", "2^10", "1/2 + 1/3", "2/3 * 3/4", "(2+3)^2", "7 - 9",
                // expressions / simplify / expand
                "Simplify[a + a]", "Simplify[2*x + 3*x]", "Expand[(x+1)^2]",
                "Expand[(x+1)*(x-1)]", "Expand[(2*x+3)*(x-4)]",
                // factoring / gcd / rational normal forms
                "Factor[x^2 - 1]", "Factor[x^2 + 2*x + 1]", "Factor[x^2 - 5*x + 6]",
                "PolynomialGCD[x^2 - 1, x - 1]", "Together[1/x + 1/y]", "Cancel[(x^2-1)/(x-1)]",
                // solve (deg 1 / deg 2)
                "Solve[2*x - 4, x]", "Solve[x^2 - 4, x]", "Solve[x^2 - 5*x + 6, x]",
                // differentiation (every rule)
                "D[x^3, x]", "D[Sin[x], x]", "D[Cos[x], x]", "D[Tan[x], x]",
                "D[Exp[x], x]", "D[Log[x], x]", "D[Sqrt[x], x]", "D[ArcTan[x], x]",
                "D[Sin[x]*Cos[x], x]", "D[Sin[x^2], x]", "D[x/(x+1), x]",
                // integration
                "Integrate[x^2, x]", "Integrate[Sin[x], x]", "Integrate[1/x, x]",
                "Integrate[Exp[x], x]",
                // trig / misc
                "Sin[0]", "a + b*c",
            ];
    // Fresh boot per case (fresh thread = fresh thread-local heap) to avoid the
    // known boot-order/grow-only-heap divergence (shen-rust issue #8) so the
    // battery is a clean per-case behaviour snapshot.
    for c in cases {
        let res = thread::Builder::new()
            .stack_size(STACK)
            .spawn(move || CasEngine::boot().expect("boot").reduce(c))
            .unwrap()
            .join()
            .unwrap();
        println!("{c} => {res}");
    }
}

# ShenCalc Tutor — CAS Coverage vs Curriculum

What shen-cas can *generate answers for* and *grade by equivalence* TODAY, mapped
against curriculum, with the selected MVP ladder and its rationale. Ground truth
is the shipped tree-shaken slice (`shen-rust/crates/shenffi/cas/cas-all.kl`) plus
the corpus tests (`shen-cas/test/test-external-corpus.shen`), not the full source.

Legend: **GENERABLE** = answer-generable *and* CAS-gradable against the shipped
slice now · **PARTIAL** = works but with caveats (degraded steps, narrow forms,
app-layer assist) · **NO** = needs floats / unwired heads / missing parser ops.

---

## 1. Operation-level coverage (shipped slice)

| CAS capability | Status | Notes for the tutor |
|---|---|---|
| Exact integer arithmetic (+,−,×,integer ^) | **GENERABLE** | int64 only; overflow → inert. Keep params int64-safe. |
| Exact rational arithmetic (fractions) | **GENERABLE** | `make-rat` auto-normalizes to lowest terms, positive denom; doubles as the answer key. No bignum. |
| Order of operations (PEMDAS) | **GENERABLE** | The parser's precedence *is* the answer key (`(2+3)^2 → 25`). |
| Simplify (collect like terms) | **PARTIAL** | Combines like terms, folds repeated factors → powers, Pythagorean fold. **Not** a general simplifier: branch-unsafe identities (`Log[Exp[x]]`, `Sqrt[x^2]`) stay inert by design. Excellent as the grading oracle. |
| Expand (polynomial normal form) | **GENERABLE** | Full multivariate, non-negative integer powers. `PolynomialQ` available. |
| Factor (univariate over Q) | **GENERABLE** | Expand-round-trip self-checked; unfactorable stays inert. |
| Together / Apart / Cancel | **GENERABLE** | Rational normal forms; useful for fraction nodes. |
| PolynomialGCD | **GENERABLE** | Backs GCF-factoring node. |
| Solve (polynomial) | **GENERABLE** | Keystone: every root substituted back and must reduce to `0`, else inert — provably correct root lists. deg-1 and deg-2 exact. |
| Differentiation `D[expr,x]` | **GENERABLE** | Power/product/quotient/chain over Sin,Cos,Tan,Sec,Exp,Log,Sqrt,ArcSin,ArcCos,ArcTan. FreeQ-guarded so unknown `f[x]` stays inert (never wrongly 0). Higher + partial derivatives. |
| Integration (bounded rule library, indefinite) | **PARTIAL** | Differentiate-back self-checked; many integrands stay inert. Generators must stay inside the provable subset. |
| reduce-trace / derive / steps (worked steps) | **NO (today)** | Exists in source + tests; **absent from `cas-all.kl`, unwired from C ABI.** Re-shake + thin FFI fast-follow (DESIGN §6). |
| Floats / decimals | **NO** | None. Rationals over Q only. |
| Quotient / Mod / FactorInteger / PrimeQ | **NO** | Not in slice. Excludes number-theory nodes. |
| Relational operators in parser (`<`, `≤`) | **NO** | Parser has none; inequalities handled via Solve + sign, not parsed relations. |
| Subst / ReplaceAll | **NO (unwired)** | Substitution is app-layer string interpolation, then a verified numeric fold. |

---

## 2. Curriculum-band coverage

| Band | Representative skills | Status | Why |
|---|---|---|---|
| Number / arithmetic | integer & fraction arithmetic, PEMDAS | **GENERABLE** | Parser + exact rational fold; answer key is free. |
| Number theory | GCD/LCM-as-integers, primes, mod | **NO** | No Quotient/Mod/FactorInteger/PrimeQ. |
| Algebra I — expressions | combine like terms, distribute, evaluate-at-value | **GENERABLE** (substitution PARTIAL — app-layer string interp) | Simplify + Expand wired; numeric fold verified. |
| Algebra I — equations | 1/2-step, multi-step, both-sides | **GENERABLE** | Solve, substitute-back gated. |
| Algebra I — systems (2×2 linear) | elimination/substitution result | **GENERABLE** | Solve over two equations. |
| Algebra I — inequalities (linear, 1 var) | solve + sign | **PARTIAL** | No parsed relations; modeled via Solve of the boundary + sign reasoning. |
| Polynomials | add/sub/mul, special products | **GENERABLE** | Expand + Simplify. |
| Factoring | GCF/GCD, quadratics | **GENERABLE** | Factor + PolynomialGCD, round-trip checked. |
| Quadratics | factor & formula solving | **GENERABLE** | Solve deg-2, rational-root params keep the gate satisfied. |
| Rational expressions | simplify/combine | **GENERABLE** | Together/Apart/Cancel. |
| Calculus — differentiation | power/product/quotient/chain | **GENERABLE** | Full elementary table; strongest zone. |
| Calculus — integration | indefinite, elementary | **PARTIAL** | Bounded provable subset only. |
| Anything needing decimals / floats | measurement, stats, trig values | **NO** | No floats. |
| Geometry / word problems / graphing | — | **NO (engine)** | App-layer, not CAS-gradable by difference-to-zero. |

---

## 3. Selected MVP ladder — the Algebra Spine

Shipped as `KnowledgeGraph.mvp` (13 nodes, `Learning/KnowledgeGraph.swift`):

```
alg-int-arith
  └─ alg-rational-arith
       └─ alg-linear-expr ─────────────┐
            └─ alg-eval-substitute      └─ alg-poly-arith
                 └─ alg-linear-eq-1step      ├─ alg-poly-special-products ┐
                      ├─ alg-linear-eq-multistep                          │
                      │     ├─ alg-linear-systems-2x2                     │
                      │     └─ alg-linear-inequality                      │
                      │                          alg-gcf-factor ──────────┤
                      │                               └─ alg-factor-quadratic
                      └──────────────────────────────────── alg-quadratic-solve
```

(Edges per the scaffolded graph: `alg-quadratic-solve` requires
`alg-factor-quadratic` + `alg-linear-eq-1step`; `alg-factor-quadratic` requires
`alg-gcf-factor` + `alg-poly-special-products`.)

### Rationale

1. **Every node is GENERABLE today.** Each maps to heads verified present in the
   shipped slice — `reduce`, `Plus/Times/Power/Minus/Divide` with exact rationals,
   `Simplify`, `Expand`, `Factor`, `Together`, `Apart`, `Cancel`,
   `PolynomialGCD`, `Solve`. No node depends on floats, unwired heads, or parser
   relations.
2. **Solve is the keystone and it is sound, not guessed.** `src/solve.shen`
   substitutes every root back and requires `[int 0]`, else returns inert — so a
   returned root list is provably correct. Grading is the difference-to-zero
   oracle (`reduce(Simplify[student − answer]) == 0`), accepting any equivalent
   student form.
3. **It's a genuine prerequisite DAG.** Each node's generator reuses heads its
   ancestors mastered (fractions feed equation roots; expand/simplify feed
   factoring), so the graph is simultaneously curriculum order and the data the
   spiral walks.
4. **It sits in the engine's sweet spot** — parser + exact rationals + polynomial
   algebra — where there are no coverage gaps, so authoring 13 generators carries
   near-zero engine risk.

### Explicitly excluded from MVP

Floats/decimals; Quotient/Mod/FactorInteger/PrimeQ; parser relational operators;
visual/perceptual arithmetic (app-layer only); calculus (GENERABLE but deferred
to keep the MVP a single coherent strand a learner can finish).

### Steps caveat for MVP

The MVP ships **verified answers + equivalence grading on day one.** Worked
**steps** are PARTIAL across the whole ladder until the `reduce-trace` re-shake
lands (DESIGN §6); until then the UI degrades to "canonical answer + one derive
line." Pedagogy is intact because grading is already provably correct — steps are
the next increment, not a blocker.

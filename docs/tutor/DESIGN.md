# ShenCalc Tutor — DESIGN

The architecture for turning ShenCalc from a symbolic calculator into a
shippable, adaptive math tutor. This is the master spec; `COVERAGE.md` maps
the CAS against curriculum and `ROADMAP.md` sequences delivery.

---

## 1. Product thesis

Every consumer math tutor today (Photomath, Khanmigo, the LLM wrappers) has the
same structural flaw: the entity generating the worked solution is a language
model, so the steps are *plausible* rather than *proven*. They hallucinate sign
errors, skip non-obvious cases, and grade by surface match.

ShenCalc inverts this. The math is computed by **shen-cas**, a Mathematica-style
term-rewriting CAS whose design philosophy is **SOUND > COMPLETE**: every Solve
root is substituted back and must reduce to `0`, every integral is
differentiated back, every Factor is Expand-round-tripped — and anything not
*provable* stays **inert** (head unchanged) rather than guessed. The tutor
inherits that guarantee end to end:

- **Verified answers.** The canonical answer to every problem is a CAS normal
  form that passed the engine's own self-check.
- **Verified grading.** A student answer is correct iff
  `reduce(Simplify[student − answer]) == 0` — CAS equivalence, not string match.
  Any algebraically equivalent form (reordered, unfactored, a different-but-equal
  fraction) is accepted.
- **Verified steps (the headline differentiator).** Worked solutions come from
  `reduce-trace` / `derive` with a **faithfulness invariant**: the last step of
  the trace equals the engine's normal form. The tutor literally cannot show a
  step sequence that doesn't land on the proven answer.

The pedagogy is the **Saxon spiral** — a little new material each day on top of
heavy mixed cumulative review — but the spiral is *driven by per-learner mastery
over a prerequisite knowledge graph (a DAG)*, not by a fixed lesson order. New
material unlocks when its prerequisites are mastered; the review mix is sampled
from mastered ancestors weighted by how stale or shaky each is.

Breadth is made tractable by authoring **one parametric generator per skill
node**, not individual problems. The CAS instantiates params, computes the
answer, and (soon) computes the trace. Authoring effort is O(skills), not
O(problems), and correctness is structural rather than reviewed.

The honest constraint that shapes everything below: **the shipped tree-shaken
engine exposes only `reduce(string) -> string`.** `reduce-trace` exists in
source and is test-covered but is *not* in the shaken slice and *not* wired to
the C ABI. So the MVP ships verified **answers + equivalence grading** today,
and verified **steps** as the immediate fast-follow (see §6, §7).

---

## 2. System overview

```
            authored, immutable                  per-learner, mutable
        ┌──────────────────────┐            ┌──────────────────────────┐
        │  KnowledgeGraph (DAG) │            │  LearnerState            │
        │  SkillNode + prereqs  │            │  NodeState (DSR mastery) │
        │  generatorKey, casOps │            │  attempt history         │
        └──────────┬───────────┘            └────────────┬─────────────┘
                   │                                      │
                   ▼                                      ▼
        ┌─────────────────────────────────────────────────────────┐
        │  SpiralScheduler  buildSession(graph, learner, now)       │
        │  -> [ProblemSlot]  (new | review | remediation)           │
        └───────────────────────────┬─────────────────────────────┘
                                     │ slot.nodeID + difficulty band
                                     ▼
        ┌─────────────────────────────────────────────────────────┐
        │  ProblemGenerator (per node)                              │
        │  params -> ProblemInstance (prompt, canonical answer,     │
        │            trace handle, AnswerKind)                       │
        └───────────────────────────┬─────────────────────────────┘
                                     │ uses
                                     ▼
        ┌─────────────────────────────────────────────────────────┐
        │  CASClient  ── facade over ShenCAS.reduce(_:) ──          │
        │   • instantiate / compute answer                          │
        │   • grade: reduce(Simplify[student-answer]) == 0          │
        │   • trace (capability-flagged; degrades gracefully)       │
        └───────────────────────────┬─────────────────────────────┘
                                     ▼
        ┌─────────────────────────────────────────────────────────┐
        │  ShenCAS (existing)  ── shenffi C ABI ── shen-cas (Rust)  │
        │  64MB worker thread, one in-flight reduce, serial queue   │
        └─────────────────────────────────────────────────────────┘

   grading result (AttemptSignal) ──> MasteryModel.applyReview ──> LearnerState
```

The scheduler is a **pure function** of persisted state + the static graph: it
never calls the CAS. Generation and grading are the only CAS consumers. This
keeps the scheduler deterministic and unit-testable, and keeps all engine
serialization behind one facade.

---

## 3. The engine: knowledge graph + mastery + scheduler

### 3.1 Knowledge graph (static, authored)

Implemented in `Learning/KnowledgeGraph.swift` (already scaffolded). A
`SkillNode` is one generator's worth of math: `id` (stable slug, the
mastery-store key — never changes once shipped), `name`, `prerequisites: [id]`
(DAG edges), and `casOps` (the shen-cas heads the generator/grader exercises —
documentation today, dispatch hook for the runtime). The graph validates as a
DAG via topological sort at load and rejects cycles.

The graph supplies exactly the queries the spiral needs, all O(V+E):

- `isUnlocked(id, mastered:)` — all prereqs mastered.
- `frontier(mastered:)` — unlocked-but-not-mastered nodes = **new-material**
  candidates (the incremental half of the spiral).
- `unlocked(by:mastered:)` — dependents newly opened by mastering a node (the
  "you unlocked X" moment).
- `reviewPool(mastered:)` — mastered ancestors that support the current frontier
  = the **cumulative-review** pool (the heavy-mixed half of the spiral), with a
  non-empty fallback to all-mastered so review never goes dry.

The shipped graph is the 13-node **Algebra Spine** (`KnowledgeGraph.mvp`):
integer arithmetic → rational arithmetic → linear expressions → substitution →
linear equations (1/2-step → multi-step → 2×2 systems / inequalities) → polynomial
arithmetic → special products → GCF/GCD factoring → quadratic factoring →
quadratic solving. Every edge is a genuine prerequisite (each generator reuses
heads its ancestors mastered).

### 3.2 Mastery model (per-learner, per-node)

Implemented in `Learning/Mastery.swift` (scaffolded). Canonical model is
**FSRS-6 DSR** (Difficulty, Stability, Retrievability):

- `NodeState` holds `D ∈ [1,10]`, `S > 0` (days), `lastReview`, `reps`,
  `lapses`, `unlocked`. **`R` is never stored** — retrievability is computed on
  demand from `S` and elapsed time via the power-law forgetting curve, so
  mastery decays *continuously* and the scheduler always reads current recall.
- `Grade` (again/hard/good/easy, 1–4) is **derived from the `AttemptSignal`**
  (CAS-correct? elapsed vs expected time? hints used? tries?), never
  self-reported. `Grade.from(signal:expectedTime:)` encodes the mapping.
- `applyReview(state, grade, now)` is a pure transition updating D/S and
  bookkeeping (initial-stability seeding, success/lapse/same-day stability
  growth, difficulty mean-reversion, clamping).
- `isMastered(now:)` is the hard predicate the graph reads to gate unlock;
  `mastery(now:)` is a continuous sigmoid for UI/ranking.
- **FIRe** (prerequisite credit propagation): mastering a node gives a small
  fractional review credit to its prerequisites — recognizing that using a skill
  in service of a harder one *is* spaced practice of it.

Difficulty intrinsic to a node (authored, not learner-specific) seeds time
thresholds and biases initial `D`; it lives on the static graph, not in
`NodeState`.

### 3.3 Adaptive Saxon-spiral scheduler

Implemented in `Learning/SpiralScheduler.swift` (scaffolded). Contract:

```
buildSession(graph, learner, now, size = 24) -> [ProblemSlot]
```

Each `ProblemSlot` names a `nodeID`, an `intent` (`new | review | remediation`),
and a difficulty band. The scheduler:

1. **Remediation first.** Any node with a remediation trigger (consecutive wrong
   / lapsed below threshold) is scheduled before new material, possibly with a
   step-back to a shaky prerequisite.
2. **New material, throttled.** Draw 1–2 nodes from `frontier(mastered:)`,
   ordered by readiness (prereq stability) and intrinsic difficulty. The Saxon
   principle: only a *small* dose of new per session.
3. **Heavy cumulative review.** Fill the remainder from `reviewPool(mastered:)`,
   weighted toward low current retrievability (most-forgotten first) and high
   lapse count, so review naturally concentrates where memory is decaying. This
   is the spiral's defining behavior: old skills keep resurfacing on a schedule
   set by *their own* forgetting curves.
4. **Interleave**, don't block — mix nodes within the session so retrieval is
   discriminative, not massed.

A separate generation pass turns each slot into a concrete problem. The
scheduler consumes only mastery telemetry; it is fully deterministic given
state + `now` and is unit-testable without the engine.

---

## 4. Generator / grader / verified-steps

### 4.1 Generator protocol

Implemented in `Learning/ProblemGenerator.swift` (scaffolded). One generator per
skill node, 1:1 with `SkillID`. Surface:

```swift
protocol ProblemGenerator {
    var skill: SkillID { get }
    func generate(difficulty: Difficulty, rng: inout RandomNumberGenerator)
        async -> ProblemInstance
    func grade(_ studentInput: String, against: ProblemInstance)
        async -> GradeResult
}
```

- **`Difficulty`** bands (introductory → standard → advanced → challenge) map to
  parameter ranges. The scheduler picks the band from learner mastery; the
  generator maps band → ranges (smaller ints / no negatives at low bands,
  fraction answers and near-degenerate params at high bands).
- **`ProblemInstance`** carries the rendered prompt (via `MathPretty.render`),
  the **canonical answer as a CAS normal form**, the `AnswerKind`, and a trace
  handle (forward-looking).
- Generators draw params with a **seeded RNG** so a session is reproducible
  (replay, debugging, "same problem set" sharing).
- Param instantiation must respect engine limits: keep all intermediates
  **int64-safe** (overflow → inert), avoid degenerate params (zero leading
  coefficient, division by zero, `0^0`), and prefer params whose answer the CAS
  can *prove* (e.g. quadratics with rational roots so Solve's substitute-back
  gate passes).

### 4.2 Grading by CAS equivalence

The one load-bearing decision: **never string-match answers.** The grader's rule
depends on `AnswerKind`:

- **`.expression`** (scalar / single expression): correct iff
  `reduce("Simplify[(student) - (answer)]") == "0"`.
- **`.solutionSet`** (Solve / List answers): reduce each element and compare as a
  normalized multiset — order-independent, form-independent.

The grader also normalizes student input through `CASTools.normalizeExpr` and
emits the exact bracket syntax (`D[…]`, `Solve[…, x]`) the CAS reader expects.
Because the engine is serial (one in-flight `reduce`), the grader issues its 1–3
CAS calls with sequential `await`, never assuming concurrency.

A `GradeResult` reports a verdict (correct / equivalent-but-flagged /
incorrect / unparseable) plus the timing/hint data the mastery model needs to
derive a `Grade`.

### 4.3 Verified steps (the differentiator) — current status and plan

`reduce-trace` (`shen-cas/src/trace.shen`) produces a step list with the
**faithfulness invariant**: `last(trace(E)) == reduce(E)`. It exists, is
test-covered (`test/test-trace.shen`), **but is absent from the shipped
`cas-all.kl` slice and unwired from the C ABI.** This is the single biggest gap
for the tutor goal.

The protocol is designed so this gap is a *fast-follow, not a rewrite*:

- A `Step` model and trace surface are defined now and **gated behind a
  capability flag**. Until `shen_cas_trace` exists, the UI degrades to "show the
  canonical answer + a single `derive` line"; pedagogy still works because
  grading is already verified.
- When the FFI lands, **only `ShenCAS`/`CASClient` change** — the generator and
  grader protocols are unchanged.

See §6 for the FFI work and §7 for the integration contract.

---

## 5. Swift module layout

All new code under `ShenCalc/Learning/`. `createIntermediateGroups: true` is set
and `sources: - ShenCalc` recurses, so **pure-Swift additions need no
project.yml edit** (see §8). Target layout:

```
ShenCalc/Learning/
  KnowledgeGraph.swift     ✅ scaffolded — SkillNode + DAG + frontier/review + .mvp (13 nodes)
  Mastery.swift            ✅ scaffolded — NodeState (DSR), FSRS, applyReview, Grade.from, FIRe
  SpiralScheduler.swift    ✅ scaffolded — buildSession -> [ProblemSlot]
  ProblemGenerator.swift   ✅ scaffolded — protocol, ProblemInstance, grade, Difficulty bands, seeded RNG
  Generators/              ⬜ one file per node generator (next phase)
    IntArithGen.swift, RationalArithGen.swift, LinearEqGen.swift, ...
  CAS/
    CASClient.swift        ⬜ Learning-facing facade over ShenCAS (grade, trace, batch)
    WorkedSolution.swift   ⬜ Step model + trace parsing (capability-flagged)
  State/
    LearnerStore.swift     ⬜ persistence (Codable JSON or SwiftData), save/query facade
    AttemptRecord.swift    ⬜ graded-attempt history row
  LearningSession.swift    ⬜ @MainActor view-model driving a practice session
  Views/                   ⬜ SwiftUI: session runner, step reveal, progress map
```

The existing `ShenCAS.swift` stays where it is. `CASClient` wraps it so Learning
code never touches the FFI directly; tests inject a `CASEvaluator` stub (the
protocol already exists in `ProblemGenerator.swift`).

Reuse, don't reinvent: prompts and worked steps render through
`MathPretty.render`; operand normalization reuses `CASTools.normalizeExpr`; the
generators emit the same bracket syntax `CASTools` builds.

---

## 6. shen-cas integration & FFI work needed

**Today (no rebuild required):**

- `ShenCAS.reduce(_:) async -> String` is the single primitive. It runs on a
  dedicated 64 MB-stack worker thread (the tree-walked reducer needs ~16 MB;
  GCD queues' small stacks crash it), serving a serial job queue. One reduce
  in flight at a time.
- Grading works **now**: `reduce(Simplify[a − b]) == 0`.
- Answer generation works **now**: instantiate params in Swift, `reduce` to the
  canonical answer.

**FFI work to land verified steps (the fast-follow):**

1. **Re-shake to include `trace.shen`.** Add `reduce-trace` / `derive` / `steps`
   to the tree-shaker's roots so they appear in `cas-all.kl` (currently 0
   occurrences). This is a re-shake of an existing, tested module — not new math.
2. **Expose a trace entry point over the C ABI.** A generic `shen_eval` entry
   point already exists in `shenffi/src/lib.rs`, so the trace can be reached as
   `shen_eval("(reduce-trace (parse-expr-string \"…\"))")` *or* via a thin
   dedicated `shen_cas_trace(ctx, cstr) -> cstr` mirroring `shen_cas_reduce`.
   Prefer the dedicated entry point for a stable contract.
3. **Swift side:** add `ShenCAS.trace(_:) async -> [Step]` that parses the
   returned step list and **asserts the faithfulness invariant** (`steps.last ==
   reduce(input)`) before display; on mismatch, fail closed to the answer-only
   view. Flip the `CASClient` capability flag.

Net: steps are a re-shake + thin FFI, gated so the product ships before they
land and lights them up without touching the generator/grader/scheduler.

**Engine boundaries the tutor must respect** (from coverage): exact rationals
over Q only — no floats/decimals, int64 only (overflow → inert), no bignum;
single-variable calculus is the strong zone; no relational operators in the
parser; no wired `Subst`/`ReplaceAll` (substitution is app-layer string interp,
then a verified numeric fold). Generators must stay inside these or the engine
returns inert and grading breaks.

---

## 7. Integration contract summary

| Concern | Today | After FFI fast-follow |
|---|---|---|
| Answer | `reduce(expr)` normal form, self-checked | unchanged |
| Grading | `reduce(Simplify[student−answer]) == 0` | unchanged |
| Steps | answer + single `derive` line (degraded) | full `reduce-trace`, faithfulness-asserted |
| Engine calls | serial `await ShenCAS.reduce` | + serial `await ShenCAS.trace` |
| Scheduler | pure, no CAS | unchanged |

The whole design is structured so the *value-correct* product (verified answers
+ verified grading + adaptive spiral) ships first, and the *headline*
(verified steps) is a localized, low-risk increment behind a capability flag.

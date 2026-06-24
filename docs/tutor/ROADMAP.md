# ShenCalc Tutor — ROADMAP

Phased path from the current scaffold to a shippable adaptive tutor. Each phase
is independently demoable and de-risks the next. See `DESIGN.md` for
architecture and `COVERAGE.md` for what the CAS can generate.

Status at start: `Learning/{KnowledgeGraph,Mastery,SpiralScheduler,
ProblemGenerator}.swift` are scaffolded and compile standalone; `ShenCAS.reduce`
ships and grading-by-equivalence works against the tree-shaken slice. No
generators are wired to the engine yet; `reduce-trace` is not in the slice.

---

## Phase 0 — Wire the loop (CASClient + 3 generators) · ~1 sprint

**Goal:** one real end-to-end practice session on a slice of the Algebra Spine.

- `Learning/CAS/CASClient.swift`: facade over `ShenCAS` (conforms `CASEvaluator`)
  — `grade(student, against:)` via `reduce(Simplify[a−b]) == 0`, plus a
  capability flag for trace (off).
- First 3 generators (`Generators/`): `alg-int-arith`, `alg-rational-arith`,
  `alg-linear-eq-1step`. Seeded RNG, int64-safe params, rational-root params for
  Solve so the substitute-back gate passes.
- `LearningSession.swift` (@MainActor view-model) + a minimal session-runner
  view: present prompt → accept input → grade → feed `AttemptSignal` into
  `applyReview`.
- In-memory `LearnerState` (no persistence yet).

**Exit:** a learner solves generated problems, gets CAS-correct grading, and
sees mastery move. **Demoable.**

---

## Phase 1 — MVP slice: full spine + scheduler + persistence · ~2 sprints

**Goal:** the shippable core — adaptive Saxon spiral over the whole 13-node spine.

- All 13 generators with `Difficulty` bands wired to `KnowledgeGraph.mvp`.
- `SpiralScheduler.buildSession` driving real sessions: remediation → throttled
  new material from `frontier` → heavy cumulative review from `reviewPool`
  weighted by current retrievability; interleaved.
- `State/LearnerStore.swift`: on-device persistence (Codable JSON blob or
  SwiftData) of `LearnerState` + `AttemptRecord` history. Survives relaunch.
- Placement: a short diagnostic to seed `NodeState` priors so a learner doesn't
  start at node 1 unnecessarily.
- Progress UI: a DAG map showing mastered / frontier / locked, and "you unlocked
  X" moments via `unlocked(by:)`.

**Exit:** install the app, get placed, and do daily adaptive sessions that
unlock new material as prerequisites are mastered and resurface old material on
its forgetting curve. **This is the shippable MVP** (verified answers + verified
grading + adaptive spiral; steps still degraded).

---

## Phase 2 — Verified steps (the differentiator) · ~1–2 sprints

**Goal:** light up the headline — provably-faithful worked solutions.

- **Re-shake** `shen-cas` to include `trace.shen` (`reduce-trace`/`derive`/
  `steps`) in `cas-all.kl`. Existing, tested module — re-shake, not new math.
- **Expose over the C ABI:** dedicated `shen_cas_trace(ctx, cstr) -> cstr`
  mirroring `shen_cas_reduce` (preferred over the generic `shen_eval` already in
  `shenffi/src/lib.rs`, for a stable contract).
- `ShenCAS.trace(_:) async -> [Step]` + `CAS/WorkedSolution.swift` parsing;
  **assert the faithfulness invariant** (`steps.last == reduce(input)`) before
  display, fail closed to answer-only on mismatch.
- Flip the `CASClient` capability flag; step-reveal UI (progressive hints =
  one trace step at a time, feeding `hintsUsed` into the grade).

**Exit:** every problem shows a step-by-step solution that is *provably* the
engine's own derivation. Nothing in scheduler/generator/grader changes.

---

## Phase 3 — Scale nodes beyond the spine · ongoing

**Goal:** breadth, cheaply, staying inside CAS coverage.

- Add GENERABLE bands (COVERAGE §2): rational expressions, polynomial division
  by GCD, and the **calculus differentiation** strand (engine's strongest zone).
- Each new skill = one `SkillNode` + one generator; authoring is O(skills).
- Keep PARTIAL/NO bands out until the engine supports them (no floats → no
  measurement/stats/trig-values; no Mod → no number theory).

**Exit:** curriculum spans multiple strands; the DAG branches.

---

## Phase 4 — Photo-homework hook · ~2 sprints

**Goal:** "snap your homework" capture, grounded by the CAS.

- Reuse the already-linked on-device MLX/Gemma multimodal path
  (`MLXInterpreter.swift`, `MLXVLM`) to OCR a photographed problem into a
  candidate CAS expression.
- **The CAS is the ground truth, not the model:** the VLM only proposes the
  expression; `reduce` computes the verified answer/steps and grades. A
  hallucinated transcription is caught when the expression fails to parse or the
  learner rejects the rendered prompt.
- Map the recognized problem to the nearest skill node so a photo attempt still
  updates mastery.

**Exit:** photograph a homework problem and get a verified worked solution +
practice on the same skill.

---

## Phase 5 — Accounts & sync · ~2 sprints

**Goal:** multi-device + the data model for a real product.

- Account layer; sync `LearnerState`/history (the data model is already designed
  for cloud-sync — authored graph in-bundle, mutable state portable).
- Parent/teacher visibility into the mastery map.
- Multiple learner profiles per install.

**Exit:** a learner's mastery follows them across devices.

---

## Honest risks

1. **Verified steps depend on a re-shake that hasn't happened.** The headline
   differentiator is absent from the shipped binary. *Mitigation:* the MVP
   (Phases 0–1) is valuable and shippable *without* steps (verified answers +
   grading), and the trace work is localized to `ShenCAS`/FFI behind a capability
   flag — but if the re-shake hits unforeseen tree-shaker or stack issues, the
   marquee feature slips. This is the top risk.

2. **Generator authoring must stay inside engine limits.** int64-only (overflow →
   inert), rationals over Q, no floats, Solve only returns roots it can prove.
   Careless param ranges produce inert results that silently break grading.
   *Mitigation:* every generator needs a self-test pass that asserts the answer
   reduces (non-inert) across its band before shipping.

3. **Grading equivalence is only as broad as Simplify.** `Simplify` is
   deliberately *not* a general simplifier (branch-unsafe identities stay inert),
   so a correct student answer in an unusual form could fail `Simplify[a−b]==0`.
   *Mitigation:* keep MVP answer shapes in polynomial/rational forms where
   difference-to-zero is reliable; add `Together`/`Expand`/`Cancel` normalization
   passes in the grader before declaring "incorrect."

4. **Mastery/FSRS parameters are unvalidated on this population.** FSRS-6 defaults
   come from flashcard data, not procedural math. *Mitigation:* ship the
   v4-simplified curve first (one fewer param), log `AttemptRecord` history from
   day one, and tune offline once real data exists. The model swap is
   signature-compatible.

5. **Serial engine + multi-call generators.** One in-flight `reduce` on a 64 MB
   worker thread; a generator may need 2–3 calls and grading 1–3 more.
   *Mitigation:* batch/sequence with `await`, never block the UI; keep session
   prep off the main actor. Watch latency as node count grows.

6. **Inequalities are modeled, not parsed.** No relational operators in the
   parser. *Mitigation:* `alg-linear-inequality` is PARTIAL — solve the boundary
   + reason about sign in app code; defer rich inequality work.

7. **Photo path adds an LLM back into the loop (Phase 4).** Re-introduces
   hallucination at the *transcription* boundary. *Mitigation:* the CAS remains
   ground truth; the model only proposes an expression the learner confirms and
   the parser validates — model error degrades to "couldn't read it," never to a
   wrong-but-confident answer.

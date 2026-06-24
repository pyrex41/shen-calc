import Foundation

/// Owns the embedded shen-cas engine (shen-rust via the shenffi C ABI).
///
/// The CAS reducer is deeply recursive and tree-walked, so it must run on a
/// thread with a large stack — not a GCD queue (those have small stacks). We
/// boot once on a dedicated big-stack thread and serve `reduce` requests from a
/// condition-guarded job queue. `jobs`/`cond` are protected by the lock, so they
/// are safe to touch from both the UI and the worker thread.
final class ShenCAS: ObservableObject {
    /// True once the kernel + CAS have booted.
    @Published var isReady = false

    private let cond = NSCondition()
    /// Each job runs on the worker thread with the booted engine handle (or `nil`
    /// if boot failed). Generalised beyond `reduce` so `trace` shares the same
    /// serial big-stack thread. Guarded by `cond`.
    private var jobs: [(OpaquePointer?) -> Void] = []

    init() {
        let worker = Thread { [weak self] in self?.run() }
        // The tree-walked CAS reducer needs ~16 MB of stack (8 MB overflows on
        // boot); 64 MB gives a 4× margin. NOT larger — iOS appears to reject an
        // over-large NSThread stack and silently fall back to the tiny default,
        // which let shallow ops (D[…]) run but crashed deeper ones (Integrate).
        worker.stackSize = 64 * 1024 * 1024
        worker.name = "shen-cas"
        worker.start()
    }

    /// Worker-thread entry: boot the CAS, then process jobs forever.
    private func run() {
        let ctx = shen_cas_boot()
        DispatchQueue.main.async { self.isReady = (ctx != nil) }

        while true {
            cond.lock()
            while jobs.isEmpty { cond.wait() }
            let job = jobs.removeFirst()
            cond.unlock()
            job(ctx)
        }
    }

    /// Enqueue a unit of work for the serial worker thread.
    private func enqueue(_ job: @escaping (OpaquePointer?) -> Void) {
        cond.lock()
        jobs.append(job)
        cond.signal()
        cond.unlock()
    }

    /// Reduce a shen-cas expression (e.g. "D[Sin[x], x]") to its normal form.
    func reduce(_ input: String) async -> String {
        await withCheckedContinuation { cont in
            enqueue { ctx in
                var result = "engine unavailable"
                if let ctx, let out = input.withCString({ shen_cas_reduce(ctx, $0) }) {
                    result = String(cString: out)
                    shen_string_free(out)
                }
                cont.resume(returning: result)
            }
        }
    }

    /// Raw step-by-step derivation of `input` via `shen_cas_trace`: one step per
    /// line, fields separated by US (0x1f). Returns `nil` if the engine is
    /// unavailable; an empty string means the expression is already inert. Parsed
    /// into a `WorkedSolution` by `WorkedSolution.parse`.
    func traceRaw(_ input: String) async -> String? {
        await withCheckedContinuation { cont in
            enqueue { ctx in
                guard let ctx, let out = input.withCString({ shen_cas_trace(ctx, $0) }) else {
                    cont.resume(returning: nil); return
                }
                let s = String(cString: out)
                shen_string_free(out)
                cont.resume(returning: s)
            }
        }
    }
}

/// Engines that can produce a raw worked-step trace (the live `ShenCAS`). Kept
/// separate from `CASEvaluator` so test stubs and pure reducers need not implement
/// it; `CASClient` feature-detects it via `as? CASTracer`.
protocol CASTracer {
    func traceRaw(_ input: String) async -> String?
}

extension ShenCAS: CASTracer {}

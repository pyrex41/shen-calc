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
    private var jobs: [(String, (String) -> Void)] = []   // guarded by `cond`

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
            let (input, done) = jobs.removeFirst()
            cond.unlock()

            var result = "engine unavailable"
            if let ctx, let out = input.withCString({ shen_cas_reduce(ctx, $0) }) {
                result = String(cString: out)
                shen_string_free(out)
            }
            done(result)
        }
    }

    /// Reduce a shen-cas expression (e.g. "D[Sin[x], x]") to its normal form.
    func reduce(_ input: String) async -> String {
        await withCheckedContinuation { cont in
            cond.lock()
            jobs.append((input, { cont.resume(returning: $0) }))
            cond.signal()
            cond.unlock()
        }
    }
}

import Foundation
import Metal
import QuartzCore
import simd

/// Presentation owns no game, decoder or depth assumptions. It may repeat the
/// latest SUCCESSFUL completed stereo scene, using a fresh late pose per output.
final class IndependentLensPresenter: @unchecked Sendable {
    struct Scene: @unchecked Sendable {
        let texture: MTLTexture
        let rendered: simd_quatf
        let startedNs: Int64
        var ended: Double
        var nativeSequence: UInt64 = 0
        var generated = false
        var trackingGeneration: UInt64 = 0
        func ending(at time: Double) -> Scene { var value = self; value.ended = time; return value }
    }
    /// Output ownership is explicit, allowing the same production presenter to
    /// be checked with an offscreen Metal texture instead of a physical display.
    struct Drawable: @unchecked Sendable {
        let texture: MTLTexture
        let prepare: () -> Void
        let present: (MTLCommandBuffer) -> Void
        let observe: (@escaping @Sendable (Double) -> Void) -> Void
    }
    struct Output: @unchecked Sendable {
        let acquire: () -> Drawable?
        init(layer: CAMetalLayer, presenting: (@Sendable (CAMetalDrawable) -> Void)?) {
            acquire = {
                guard let value = layer.nextDrawable() else { return nil }
                return Drawable(texture: value.texture,
                    prepare: { presenting?(value) }, present: { $0.present(value) },
                    observe: { callback in value.addPresentedHandler { callback($0.presentedTime) } })
            }
        }
        init(acquire: @escaping () -> Drawable?) { self.acquire = acquire }
    }
    struct Offer: @unchecked Sendable {
        let epoch: UInt64
        let output: Output
        let lens: Renderer.Lens
        let latch: LateLatch
        let pulse: CompositorDisplayPulse
        let scanDuration: Float
        let pose: @Sendable (Int64) -> LateHeadPose?
        let submitted: @Sendable (Double) -> Void
        let presented: @Sendable (Double) -> Void
        let completed: @Sendable (Double, Double) -> Void
    }
    let mailbox = CompositorSceneMailbox<Scene, Offer>()
    let clock: LateDisplayClock
    private let telemetry = CompositorPresentationTelemetry { s in
        log(String(format: "[presenter] epoch%llu %d actual presents: realImage%d generatedImage%d refreshGaps%d rejectedCallbacks%d; interval p50/p95/p99/max %.3f/%.3f/%.3f/%.3f ms; enqueue→present p95 %.3f ms; GPU queue/work p95 %.3f/%.3f ms; centre-target error p95 %.3f ms; drawable wait p95 %.3f ms; last pulse%llu scene%llu source%llu",
            s.epoch, s.frames, s.native, s.generated, s.refreshGaps, s.rejectedCallbacks,
            s.intervalP50Ms, s.intervalP95Ms, s.intervalP99Ms, s.intervalMaxMs, s.commitToPresentP95Ms,
            s.gpuQueueP95Ms, s.gpuWorkP95Ms, s.targetErrorP95Ms, s.drawableWaitP95Ms,
            s.lastPulse, s.lastScene, s.lastNativeSequence))
    }
    private let queue: DispatchQueue
    init(clock: LateDisplayClock, queue: DispatchQueue) { self.clock = clock; self.queue = queue }
    /// The physical-clock production integration is shared by HeadsetView and
    /// offscreen acceptance: fresh pulse identity is bound at offer time.
    func configureRefresh(_ driver: CompositorRefreshDriver, offsetNs: Int64, epoch: UInt64,
                          output: Output, lens: Renderer.Lens, latch: LateLatch,
                          pose: @escaping @Sendable (Int64) -> LateHeadPose?,
                          feedback: CompositorPulseFeedback,
                          submitted: @escaping @Sendable (Double) -> Void,
                          completed: @escaping @Sendable (Double, Double) -> Void) {
        clock.withCurrentState { current, period in
            guard current == epoch else { return }
            telemetry.configure(epoch: epoch, period: period)
            let scanDuration = LateLatch.scanDuration(forDisplayHz: Float(1 / period))
            driver.configure(offsetNs: offsetNs) { [self] pulse in
                offer(.init(epoch: epoch, output: output, lens: lens,
                    latch: latch, pulse: pulse, scanDuration: scanDuration, pose: pose,
                    submitted: submitted, presented: { shown in feedback.presented?(pulse, shown) },
                    completed: { end, duration in
                        completed(end, duration)
                        if end > 0 { feedback.drawn?(pulse, end) }
                    }))
            }
        }
    }

    func retire() {
        clock.withCurrentState { epoch, period in
            mailbox.retire(to: epoch); telemetry.configure(epoch: epoch, period: period)
        }
    }
    func completed(_ ticket: CompositorScenePolicy.Write, scene: Scene?) {
        mailbox.finishWrite(ticket, scene: scene)
        kick()
    }
    func offer(_ offer: Offer) { if mailbox.offer(offer, epoch: offer.epoch) { kick() } }
    private func kick() {
        guard let wait = mailbox.beginWait() else { return }
        queue.async { [self] in draw(wait) }
    }
    private func draw(_ wait: CompositorScenePolicy.Wait) {
        // No texture lease is acquired while nextDrawable blocks; the scene
        // completed most recently AT RETURN is selected, never a stale FIFO job.
        guard clock.isCurrent(epoch: wait.epoch),
              let initial = mailbox.peekRequest(epoch: wait.epoch) else {
            mailbox.cancelWait(wait); return
        }
        let began = CACurrentMediaTime()
        guard let drawable = initial.output.acquire() else {
            mailbox.cancelWait(wait); return // next physical offer retries
        }
        guard let work = mailbox.takeAfterDrawable(wait) else { return }
        let epoch = work.lease.epoch
        var submitted = false
        defer { if !submitted { mailbox.finishRead(work.lease) } }
        let now = CACurrentMediaTime()
        guard clock.isCurrent(epoch: epoch),
              let target = clock.chooseTarget(originalTargetNs: work.request.pulse.targetNs,
                  queryNs: Int64(now * 1e9), epoch: epoch),
              let cb = work.request.lens.queue.makeCommandBuffer() else { return }
        cb.label = "Independent late lens (newest completed scene)"
        guard let sample = work.request.pose(target), sample.normalizedOrientation != nil else { return }
        if work.scene.trackingGeneration != 0 && sample.trackingGeneration != work.scene.trackingGeneration {
            // A new tracker origin/relocalization cannot rotate an old scene.
            // Retire all pending old offers; the next admitted fresh scene uses
            // the new generation. Already committed GPU work keeps its lease.
            if clock.retireIfCurrent(epoch: epoch) { retire() }; return
        }
        let warp = work.request.latch.latch(rendered: work.scene.rendered,
            startedNs: work.scene.startedNs, targetNs: target, sceneEnd: work.scene.ended,
            drawableWait: now - began, pose: { _ in sample }, scanDuration: work.request.scanDuration,
            trackingGeneration: work.scene.trackingGeneration)
        guard work.request.lens.encode(into: cb, target: drawable.texture,
                                       scene: work.scene.texture, warp: warp) else { return }
        let committed = CACurrentMediaTime()
        let timing = CompositorPresentationTelemetry.Frame(epoch: epoch, pulse: work.request.pulse.id,
            scene: work.lease.scene, nativeSequence: work.scene.nativeSequence, generated: work.scene.generated,
            targetNs: target, committedNs: Int64(committed * 1e9), drawableWaitNs: Int64((now - began) * 1e9))
        cb.addCompletedHandler { [self] cb in
            mailbox.finishRead(work.lease)
            if cb.status == .completed {
                telemetry.gpu(timing, startNs: Int64(cb.gpuStartTime * 1e9), endNs: Int64(cb.gpuEndTime * 1e9))
                work.request.completed(cb.gpuEndTime,
                    cb.gpuEndTime > cb.gpuStartTime ? cb.gpuEndTime - cb.gpuStartTime : 0)
            }
            kick()
        }
        drawable.observe { [clock, telemetry] presented in
            work.request.presented(presented)
            if presented > 0 {
                telemetry.presented(timing, atNs: Int64(presented * 1e9))
                clock.observe(presentedNs: Int64(presented * 1e9),
                    committedNs: Int64(committed * 1e9), epoch: epoch)
            }
        }
        // Submission and retirement share one lock. Already submitted GPU work
        // remains leased until completion; it cannot be cancelled retrospectively.
        submitted = clock.submitIfCurrent(epoch: epoch) {
            drawable.prepare()
            drawable.present(cb)
            cb.commit()
        }
        if submitted { work.request.submitted(CACurrentMediaTime() - now) }
    }
}

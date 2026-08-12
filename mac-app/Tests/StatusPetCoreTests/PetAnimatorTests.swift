import XCTest
@testable import StatusPetCore

/// The animator owns *when*, the view owns *where* — so a pose can be checked
/// without a screen. Advance the clock, read the numbers back.
final class PetAnimatorTests: XCTestCase {
    private let frame = 1.0 / 30.0

    /// Runs the animator for `seconds` and hands every pose to `inspect`.
    private func run(_ animator: PetAnimator, seconds: Double,
                     inspect: (PetPose, Double) -> Void) {
        var elapsed = 0.0
        while elapsed < seconds {
            let pose = animator.advance(by: frame)
            elapsed += frame
            inspect(pose, elapsed)
        }
    }

    private func busyThenIdle() -> PetAnimator {
        let animator = PetAnimator()
        animator.set(mood: .busy)
        _ = animator.advance(by: 1)
        animator.set(mood: .idle)
        return animator
    }

    // MARK: - Triggering

    func testAnIdlePetIsNotCelebrating() {
        let animator = PetAnimator()
        animator.set(mood: .idle)
        run(animator, seconds: 1) { pose, _ in
            XCTAssertNil(pose.celebration, "nothing finished, so there is nothing to celebrate")
        }
    }

    func testCelebrationStartsAndStops() {
        let animator = busyThenIdle()
        animator.celebrate()

        XCTAssertTrue(animator.isCelebrating)

        var sawCelebration = false
        run(animator, seconds: PetAnimator.celebrationDuration - 0.2) { pose, _ in
            if pose.celebration != nil { sawCelebration = true }
        }
        XCTAssertTrue(sawCelebration)
        XCTAssertTrue(animator.isCelebrating, "still inside the window")

        // Past the end, the pet must go back to being a pet.
        run(animator, seconds: 0.5) { _, _ in }
        XCTAssertFalse(animator.isCelebrating)
        XCTAssertNil(animator.advance(by: frame).celebration)
    }

    func testProgressRunsForwardAcrossTheWholeWindow() {
        let animator = busyThenIdle()
        animator.celebrate()

        var last: CGFloat = -1
        var samples = 0
        run(animator, seconds: PetAnimator.celebrationDuration - 0.05) { pose, _ in
            guard let progress = pose.celebration else { return }
            XCTAssertGreaterThanOrEqual(progress, last, "progress must not run backwards")
            XCTAssertGreaterThanOrEqual(progress, 0)
            XCTAssertLessThanOrEqual(progress, 1)
            last = progress
            samples += 1
        }
        XCTAssertGreaterThan(samples, 30, "should be plenty of frames in 2.5s")
        XCTAssertGreaterThan(last, 0.9, "should reach the end of the window")
    }

    // MARK: - Shape of the motion

    /// The point of the state is to be noticed by someone who was not looking,
    /// so it has to be visibly bigger than the pet's ordinary bob.
    func testCelebrationJumpsHigherThanWorking() {
        let busy = PetAnimator()
        busy.set(mood: .busy)
        var busyPeak: CGFloat = 0
        run(busy, seconds: 2) { pose, _ in busyPeak = max(busyPeak, pose.offset.height) }

        let animator = busyThenIdle()
        animator.celebrate()
        var celebratePeak: CGFloat = 0
        run(animator, seconds: PetAnimator.celebrationDuration) { pose, _ in
            celebratePeak = max(celebratePeak, pose.offset.height)
        }

        XCTAssertGreaterThan(celebratePeak, busyPeak * 2,
                             "a flourish nobody notices is not doing its job")
    }

    /// Hops that lose height, so the last frame is already near the idle pose it
    /// hands back to rather than stopping mid-air.
    func testTheHopsDecay() {
        let animator = busyThenIdle()
        animator.celebrate()

        var firstHalf: CGFloat = 0
        var secondHalf: CGFloat = 0
        let half = PetAnimator.celebrationDuration / 2
        run(animator, seconds: PetAnimator.celebrationDuration) { pose, elapsed in
            if elapsed < half {
                firstHalf = max(firstHalf, pose.offset.height)
            } else {
                secondHalf = max(secondHalf, pose.offset.height)
            }
        }
        XCTAssertGreaterThan(firstHalf, secondHalf, "it should settle, not stop dead")
    }

    func testFeetStayUnderTheBody() {
        // Squash is anchored at the feet, and a pose that inverts it would turn
        // the critter inside out.
        let animator = busyThenIdle()
        animator.celebrate()
        run(animator, seconds: PetAnimator.celebrationDuration) { pose, _ in
            XCTAssertGreaterThan(pose.squash, 0.5)
            XCTAssertLessThan(pose.squash, 1.5)
            XCTAssertGreaterThanOrEqual(pose.offset.height, 0, "the pet does not sink into the desk")
        }
    }

    // MARK: - Interaction with the rest of the animator

    /// A blink mid-flourish reads as the pet losing its train of thought, and
    /// the view draws the delighted expression instead — so the pose must not
    /// also be asking for closed eyes.
    func testNoBlinkingWhileCelebrating() {
        let animator = busyThenIdle()
        animator.celebrate()
        run(animator, seconds: PetAnimator.celebrationDuration) { pose, _ in
            XCTAssertFalse(pose.eyesClosed)
        }
    }

    func testCelebrationRunsAtThirtyFps() {
        let animator = busyThenIdle()
        XCTAssertEqual(animator.frameInterval, 1.0 / 12.0, accuracy: 0.0001,
                       "idle is a calm state")
        animator.celebrate()
        XCTAssertEqual(animator.frameInterval, 1.0 / 30.0, accuracy: 0.0001,
                       "the fastest motion the pet makes judders at 12")
    }

    /// Opacity easing used to sit after an early return, which left a
    /// celebrating pet stranded at whatever alpha it had when the turn ended.
    func testOpacityKeepsEasingThroughACelebration() {
        let animator = PetAnimator()
        animator.set(mood: .asleep)
        _ = animator.advance(by: 1)          // settle down to the dimmed alpha
        animator.set(mood: .idle)
        animator.celebrate()

        var last: CGFloat = 0
        run(animator, seconds: 1) { pose, _ in last = pose.alpha }
        XCTAssertEqual(last, 1, accuracy: 0.02, "a waking pet reaches full opacity")
    }

    func testCelebrateRestartsAnInFlightCelebration() {
        let animator = busyThenIdle()
        animator.celebrate()
        run(animator, seconds: 2) { _, _ in }

        animator.celebrate()
        run(animator, seconds: 1) { _, _ in }
        XCTAssertTrue(animator.isCelebrating, "the restart extended the window")
    }
}

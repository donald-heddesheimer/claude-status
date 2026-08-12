import AppKit

/// Everything the view needs to draw one frame of the critter.
///
/// The animator owns *when*; the view owns *where*. Keeping the two apart is
/// what lets a pose be verified without a screen — advance the clock, read the
/// numbers back.
struct PetPose {
    /// Translation from the resting position.
    var offset = CGSize.zero
    /// Squash and stretch, anchored at the feet. >1 is wider and shorter.
    var squash: CGFloat = 1
    var alpha: CGFloat = 1
    var legs = PetSprite.Legs.planted
    /// A blink, which overrides whatever expression the mood would draw.
    var eyesClosed = false
    /// Attention ring progress, 0…1. Nil when the pet isn't calling for you.
    var pulse: CGFloat?
    /// Rising sleep glyphs, 0…1. Nil when the pet is awake.
    var sleep: CGFloat?
    /// Celebration progress, 0…1. Nil unless a turn just finished.
    var celebration: CGFloat?
}

/// Drives the critter's motion.
///
/// Every state gets a resting behaviour and an entrance. The entrance matters
/// more than it sounds: a pet that snaps between poses reads as a status light,
/// and the whole point of a pet is that you notice it changed without having
/// been watching it.
final class PetAnimator {
    private(set) var mood: PetMood = .asleep

    private var now: CFTimeInterval = 0
    /// When the current mood began, for the entrance spring.
    private var moodSince: CFTimeInterval = -.greatestFiniteMagnitude
    /// Eased separately from the pose so waking isn't a pop.
    private var alpha: CGFloat = 0.45

    private var nextBlink: CFTimeInterval = 0
    private var blinkUntil: CFTimeInterval = 0
    /// Blinks come in pairs often enough to be worth the one extra field.
    private var pendingSecondBlink = false

    /// How long the pet celebrates a finished turn.
    ///
    /// Long enough to catch your eye if you glance over, short enough that it is
    /// gone before you look back — the pet is a glance, and a pet still dancing
    /// a minute later would be reporting something it does not know.
    static let celebrationDuration: CFTimeInterval = 2.5

    private var celebrateUntil: CFTimeInterval = -.greatestFiniteMagnitude

    var isCelebrating: Bool { now < celebrateUntil }

    /// Calm states don't need 30fps. Breathing and blinking read the same at 12,
    /// and the pet is on screen all day. A celebration is the exception: it is
    /// the fastest motion the pet ever makes, and it judders at 12.
    var frameInterval: TimeInterval {
        if isCelebrating { return 1.0 / 30.0 }
        switch mood {
        case .busy, .waiting: return 1.0 / 30.0
        case .idle, .asleep:  return 1.0 / 12.0
        }
    }

    /// Claude just finished. Play a short flourish over whatever the mood is.
    func celebrate() {
        celebrateUntil = now + Self.celebrationDuration
    }

    func set(mood: PetMood) {
        guard mood != self.mood else { return }
        self.mood = mood
        moodSince = now
        // Land the first blink shortly after waking rather than on the frame the
        // mood changed, which would collide with the entrance.
        nextBlink = now + Double.random(in: 0.8...2.0)
    }

    // MARK: - Frame

    func advance(by delta: CFTimeInterval) -> PetPose {
        now += delta

        // Ease toward the target opacity instead of switching. 0.45 → 1 in about
        // a third of a second. Done before anything can return early, so a
        // celebration cannot leave the pet stranded at a stale opacity.
        let target: CGFloat = mood == .asleep ? 0.45 : 1
        alpha += (target - alpha) * min(1, CGFloat(delta) * 9)

        var pose: PetPose
        if isCelebrating {
            // The flourish replaces the resting pose rather than adding to it.
            // Layered on top of the idle breath the two beat against each other
            // and the hops lose their shape.
            let elapsed = Self.celebrationDuration - (celebrateUntil - now)
            pose = celebratePose(elapsed / Self.celebrationDuration)
        } else {
            switch mood {
            case .asleep:  pose = asleepPose()
            case .idle:    pose = idlePose()
            case .busy:    pose = busyPose()
            case .waiting: pose = waitingPose()
            }
            applyEntrance(to: &pose)
            applyBlink(to: &pose)
        }

        pose.alpha = alpha
        return pose
    }

    // MARK: - Resting behaviour

    /// Slow breathing and drifting glyphs. Nothing is still when it's alive,
    /// and a pet that freezes solid looks like the app hung.
    private func asleepPose() -> PetPose {
        var pose = PetPose()
        let breath = sin(now * 2 * .pi / 5.0)
        pose.offset.height = breath * 0.8
        pose.squash = 1 - breath * 0.025
        pose.sleep = CGFloat(fmod(now, 2.8) / 2.8)
        return pose
    }

    /// Awake and waiting on you to type. Breathes a little quicker than asleep,
    /// and blinks (added later in the frame).
    private func idlePose() -> PetPose {
        var pose = PetPose()
        let breath = sin(now * 2 * .pi / 3.4)
        pose.offset.height = breath * 1.1
        pose.squash = 1 - breath * 0.02
        return pose
    }

    /// Working. The bob carries squash and stretch — compressed on the ground,
    /// drawn out at the top — which is the difference between a sprite sliding
    /// up and down and one that has weight.
    private func busyPose() -> PetPose {
        var pose = PetPose()
        let hop = abs(sin(now * 4.2))
        pose.offset.height = hop * 2.6
        pose.squash = 1.03 - hop * 0.05
        pose.legs = sin(now * 8.4) > 0 ? .stepping : .planted
        return pose
    }

    /// Blocked on you. The jitter reads as urgency at a glance; the periodic
    /// two-footed hop is what catches your eye from across the room, and the
    /// foot tap fills the gap between hops so it never looks parked.
    private func waitingPose() -> PetPose {
        var pose = PetPose()
        pose.offset.width = sin(now * 22) * 1.3

        let beat = fmod(now, 1.9)
        if beat < 0.36 {
            let k = CGFloat(beat / 0.36)
            let lift = abs(sin(k * .pi * 2))
            pose.offset.height = lift * 2.2
            pose.squash = 1 + (0.5 - lift) * 0.06
        } else {
            pose.legs = fmod(beat, 0.9) < 0.18 ? .tapping : .planted
        }

        pose.pulse = CGFloat(fmod(now, 1.5) / 1.5)
        return pose
    }

    /// Claude finished. Three hops that lose height, so it reads as delight
    /// settling rather than a loop that got cut off — and so the last frame is
    /// already close to the idle pose it hands back to.
    ///
    /// Bigger than any other motion the pet makes on purpose: the whole job of
    /// this state is to be noticed by someone who was not looking.
    private func celebratePose(_ progress: Double) -> PetPose {
        var pose = PetPose()

        let bounce = abs(sin(progress * .pi * 3))
        let decay = 1 - progress * 0.55

        pose.offset.height = CGFloat(bounce * decay) * 7
        // Anchored at the feet like every other bob: compressed on landing,
        // drawn out at the top.
        pose.squash = 1 + CGFloat((0.45 - bounce) * decay) * 0.12
        pose.legs = bounce > 0.35 ? .stepping : .planted
        pose.celebration = CGFloat(progress)

        return pose
    }

    // MARK: - Overlays

    /// A damped spring on arrival, so a state change is visible even out of the
    /// corner of your eye. Sleep is exempt — dropping off should be quiet.
    private func applyEntrance(to pose: inout PetPose) {
        guard mood != .asleep else { return }
        let age = now - moodSince
        let duration: CFTimeInterval = 0.55
        guard age >= 0, age < duration else { return }

        let k = age / duration
        let spring = exp(-5.5 * k) * sin(k * .pi * 3)
        pose.squash *= 1 + CGFloat(spring) * 0.09
        pose.offset.height += CGFloat(spring) * 1.8
    }

    private func applyBlink(to pose: inout PetPose) {
        guard mood != .asleep else { return }

        if now >= blinkUntil, now >= nextBlink {
            blinkUntil = now + 0.14
            if pendingSecondBlink {
                pendingSecondBlink = false
                nextBlink = now + Double.random(in: 2.8...7.0)
            } else {
                // Roughly a third of blinks are doubles, which is what stops the
                // rhythm reading as a metronome.
                pendingSecondBlink = Double.random(in: 0...1) < 0.34
                nextBlink = pendingSecondBlink ? now + 0.30 : now + Double.random(in: 2.8...7.0)
            }
        }
        pose.eyesClosed = now < blinkUntil
    }
}

//
//  ClickyCoreBuddyCursorView.swift
//  leanring-buddy
//
//  "Core": Clicky's cursor as a small assistant with a face. A dark orb with
//  a cyan rim and two cyan pill eyes. The face is how Clicky shows what it is
//  doing (listening, thinking, talking), so it replaces the old triangle,
//  waveform and spinner with one character. When Clicky points at something
//  it quickly morphs into a cursor arrow in the same colors, so where it's
//  pointing is unmistakable, then turns back into the orb.
//

import SwiftUI

/// What Clicky's face is doing. Chosen by the overlay from the voice state
/// and whether the cursor is flying to / pointing at something.
enum ClickyCoreBuddyExpression: Equatable {
    /// Waiting for you. Eyes drift toward your mouse and blink now and then.
    case idle
    /// Push-to-talk is held. Eyes open wide and a ring pulses with your voice.
    case listening
    /// Waiting on Claude. Eyes glance up and to the side while a HUD ring spins.
    case thinking
    /// Talking: no mouth. The whole orb bounces to a speech-like rhythm
    /// (squash, stretch and a small hop) and the eyes stretch with it, for
    /// as long as the voice is playing.
    case speaking
    /// Flying to, or holding at, something on screen: the orb becomes a navy
    /// cursor arrow with a cyan rim, tip toward the target.
    case pointing
}

struct ClickyCoreBuddyCursorView: View {
    let expression: ClickyCoreBuddyExpression
    /// Where the eyes look, in screen directions (x right, y down). Length 0
    /// means straight ahead, 1 means as far as the eyes go.
    let gazeDirection: CGVector
    /// Live microphone level, so the listening ring reacts to your voice.
    let audioPowerLevel: CGFloat
    /// Whether Clicky's voice is playing. While pointing, the arrow's rim
    /// pulses gently so it still feels like it's talking.
    let isSpeaking: Bool
    /// Which way the arrow points, in degrees (0 = tip up). The overlay sets
    /// the direction of travel during flights and -35° (up-left, like a
    /// normal mouse cursor) once it lands.
    let pointerRotationDegrees: Double
    /// Grows during flights (1.0 at rest), used to brighten the glow mid-swoop.
    let flightScale: CGFloat

    private let orbDiameter: CGFloat = 18
    private let hudRingDiameter: CGFloat = 24
    private let eyeWidth: CGFloat = 2.6
    private let eyeSpacingFromCenter: CGFloat = 3.3
    /// How far (in points) the eyes can move inside the orb when looking.
    private let maximumEyeTravel: CGFloat = 2.3

    var body: some View {
        // The face is animated by time (blinks, the spinning ring, the
        // equalizer), so one timeline drives every part of it.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timelineContext in
            let secondsNow = timelineContext.date.timeIntervalSinceReferenceDate
            let isPointing = expression == .pointing
            let talkingBounceLevel = expression == .speaking ? speechLikeBounceLevel(secondsNow: secondsNow) : 0
            ZStack {
                // The orb and the arrow are both always here and cross-fade
                // with a quick scale, which reads as one shape morphing.
                ZStack {
                    hudRing(secondsNow: secondsNow)

                    // The orb and its eyes are one body, so they bounce
                    // together while talking: taller and a touch narrower on
                    // each syllable, standing on the bottom edge, with a
                    // small hop. At rest (level 0) nothing is changed.
                    ZStack {
                        Circle()
                            .fill(DS.Colors.overlayCoreBuddyBody)
                            .overlay(Circle().stroke(DS.Colors.overlayCoreBuddyCyan, lineWidth: 1.2 + 0.5 * talkingBounceLevel))
                            .frame(width: orbDiameter, height: orbDiameter)

                        eyes(secondsNow: secondsNow, talkingBounceLevel: talkingBounceLevel)
                            .offset(eyeOffset)
                            .animation(.easeOut(duration: 0.18), value: eyeOffset)
                    }
                    .scaleEffect(x: 1 - 0.07 * talkingBounceLevel, y: 1 + 0.12 * talkingBounceLevel, anchor: .bottom)
                    .offset(y: -1.1 * talkingBounceLevel)
                }
                .opacity(isPointing ? 0 : 1)
                .scaleEffect(isPointing ? 0.4 : 1)

                pointerArrow(secondsNow: secondsNow)
                    .opacity(isPointing ? 1 : 0)
                    .scaleEffect(isPointing ? 1 : 0.4)
            }
            .frame(width: hudRingDiameter + 6, height: hudRingDiameter + 6)
            // A cyan glow plus a soft dark shadow keep the orb visible on both
            // dark and light apps. The glow brightens mid-flight, and pulses
            // with each bounce while talking.
            .shadow(color: DS.Colors.overlayCoreBuddyCyan.opacity(0.35 + Double(flightScale - 1.0) * 1.5 + 0.4 * Double(talkingBounceLevel)),
                    radius: 4 + (flightScale - 1.0) * 16)
            .shadow(color: Color.black.opacity(0.35), radius: 2, x: 0, y: 1)
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: expression)
    }

    // MARK: - Eyes

    private var eyeOffset: CGSize {
        // Thinking glances up and to the right, like someone recalling something.
        let lookDirection = expression == .thinking ? CGVector(dx: 0.65, dy: -0.65) : gazeDirection
        let lookDirectionLength = sqrt(lookDirection.dx * lookDirection.dx + lookDirection.dy * lookDirection.dy)
        guard lookDirectionLength > 0.001 else { return .zero }
        // Longer than 1 is clamped, so the eyes never leave the orb.
        let eyeTravelScale = min(lookDirectionLength, 1) / lookDirectionLength * maximumEyeTravel
        return CGSize(
            width: lookDirection.dx * eyeTravelScale,
            height: lookDirection.dy * eyeTravelScale
        )
    }

    private func eyes(secondsNow: TimeInterval, talkingBounceLevel: CGFloat) -> some View {
        let eyeHeight = eyeHeight(talkingBounceLevel: talkingBounceLevel)
        return HStack(spacing: eyeSpacingFromCenter * 2 - eyeWidth) {
            Capsule()
                .fill(DS.Colors.overlayCoreBuddyCyan)
                .frame(width: eyeWidth, height: eyeHeight)
            Capsule()
                .fill(DS.Colors.overlayCoreBuddyCyan)
                .frame(width: eyeWidth, height: eyeHeight)
        }
        .scaleEffect(x: 1, y: blinkScale(secondsNow: secondsNow))
    }

    private func eyeHeight(talkingBounceLevel: CGFloat) -> CGFloat {
        switch expression {
        case .listening:
            // Wide open, and a touch wider when you're louder.
            return 7 + easedVoiceLevel * 1.5
        case .thinking:
            return 5
        case .speaking:
            // The eyes stretch with each bounce, so the face moves even
            // though it has no mouth.
            return 5.2 + 1.9 * talkingBounceLevel
        case .idle, .pointing:
            return 6
        }
    }

    // MARK: - Talking bounce

    /// While talking, how far into a bounce the orb is: 0 is at rest, 1 is
    /// fully stretched. It runs on the clock, not on the real voice: three
    /// syllables a second, some stressed more than others, with a short
    /// breath every few seconds so it never looks like a metronome.
    private func speechLikeBounceLevel(secondsNow: TimeInterval) -> CGFloat {
        let syllablesPerSecond = 3.0
        let syllableBounce = abs(sin(secondsNow * .pi * syllablesPerSecond))
        // Stress rises and falls once a second, so no two neighbouring
        // syllables bounce to the same height.
        let syllableStress = 0.45 + 0.55 * pow(sin(secondsNow * .pi + 0.6), 2)
        // A breath: the bounce nearly stops for the last half second of each
        // phrase. 4.1 seconds does not line up with the stress, so the
        // pattern takes a long time to repeat.
        let secondsPerPhrase = 4.1
        let breathSeconds = 0.48
        let secondsIntoPhrase = secondsNow.truncatingRemainder(dividingBy: secondsPerPhrase)
        let isTakingABreath = secondsIntoPhrase > secondsPerPhrase - breathSeconds
        let breathQuietening = isTakingABreath ? 0.06 : 1.0
        return CGFloat(syllableBounce * syllableStress * breathQuietening)
    }

    /// A quick blink every few seconds, with an occasional double blink, so the
    /// orb reads as alive rather than as an icon. Not while listening (it's
    /// paying attention) or thinking.
    private func blinkScale(secondsNow: TimeInterval) -> CGFloat {
        guard expression == .idle else { return 1 }
        let blinkCycleSeconds = 4.3
        let blinkDurationSeconds = 0.14
        let secondsIntoCycle = secondsNow.truncatingRemainder(dividingBy: blinkCycleSeconds)
        // Every third cycle blinks twice in a row.
        let cycleNumber = Int(secondsNow / blinkCycleSeconds)
        let blinkStartTimes: [Double] = cycleNumber % 3 == 0 ? [0, 0.26] : [0]
        for blinkStartTime in blinkStartTimes {
            let secondsIntoBlink = secondsIntoCycle - blinkStartTime
            if secondsIntoBlink >= 0 && secondsIntoBlink < blinkDurationSeconds {
                // Close then open: 1 -> 0.1 -> 1.
                let blinkProgress = secondsIntoBlink / blinkDurationSeconds
                return CGFloat(0.1 + 0.9 * abs(blinkProgress * 2 - 1))
            }
        }
        return 1
    }

    // MARK: - Listening halo

    /// The raw microphone level is tiny (speech is mostly 0.01-0.3), so it's
    /// shifted and curved into 0...1 the same way the old waveform did, which
    /// makes normal speaking volume move things visibly.
    private var easedVoiceLevel: CGFloat {
        let levelAboveNoiseFloor = max(audioPowerLevel - 0.008, 0)
        return pow(min(levelAboveNoiseFloor * 2.85, 1), 0.76)
    }

    /// While you hold push-to-talk: a ring of short cyan rays around the orb
    /// that jump with your voice, like a sound meter wrapped around it. The
    /// rays never shrink to nothing, so it reads as listening even when quiet.
    private func listeningHalo(secondsNow: TimeInterval) -> some View {
        let numberOfRays = 14
        let rayInnerRadius: CGFloat = orbDiameter / 2 + 2.2

        return ZStack {
            ForEach(0..<numberOfRays, id: \.self) { rayIndex in
                // Each ray wobbles on its own so the halo looks alive; your
                // voice sets how long they all are.
                let rayWobble = CGFloat((sin(secondsNow * 9 + Double(rayIndex) * 2.3) + 1) / 2)
                let rayLength = 1.6 + easedVoiceLevel * (3 + 4 * rayWobble)
                Capsule()
                    .fill(DS.Colors.overlayCoreBuddyCyan)
                    .frame(width: 1.4, height: rayLength)
                    .offset(y: -(rayInnerRadius + rayLength / 2))
                    .rotationEffect(.degrees(Double(rayIndex) / Double(numberOfRays) * 360))
            }
            .animation(.linear(duration: 0.08), value: easedVoiceLevel)
        }
    }

    // MARK: - Pointer arrow

    /// A navy arrowhead with a cyan rim and a notched tail, tip 11pt from the
    /// center. Rotated toward the travel direction while flying.
    private func pointerArrow(secondsNow: TimeInterval) -> some View {
        let rimPulseWhileTalking = isSpeaking ? CGFloat((sin(secondsNow * 9) + 1) / 2) * 0.6 : 0
        return ZStack {
            ClickyCorePointerArrowShape()
                .fill(DS.Colors.overlayCoreBuddyBody)
            ClickyCorePointerArrowShape()
                .stroke(
                    DS.Colors.overlayCoreBuddyCyan,
                    style: StrokeStyle(lineWidth: 1.4 + rimPulseWhileTalking, lineJoin: .round)
                )
        }
        .frame(width: 16, height: 22)
        .rotationEffect(.degrees(pointerRotationDegrees))
    }

    // MARK: - HUD ring

    @ViewBuilder
    private func hudRing(secondsNow: TimeInterval) -> some View {
        switch expression {
        case .listening:
            listeningHalo(secondsNow: secondsNow)
        case .thinking:
            Circle()
                .stroke(
                    DS.Colors.overlayCoreBuddyCyan,
                    style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [10, 5, 3, 5])
                )
                .frame(width: hudRingDiameter, height: hudRingDiameter)
                .rotationEffect(.degrees((secondsNow * 150).truncatingRemainder(dividingBy: 360)))
        case .idle, .speaking, .pointing:
            EmptyView()
        }
    }
}

/// Arrowhead pointing up: tip at the top center, two wings at the bottom,
/// and a notch in the tail so it reads as a cursor, not a triangle.
private struct ClickyCorePointerArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.28))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

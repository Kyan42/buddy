//
//  ClickyAnalytics.swift
//  leanring-buddy
//
//  Analytics are switched OFF in this personal fork. Upstream sent events
//  (including voice transcripts and replies) to the original author's
//  PostHog project. Every function is kept as a no-op so call sites stay
//  unchanged, and nothing leaves this Mac.
//

import Foundation

enum ClickyAnalytics {

    // MARK: - Setup

    static func configure() {}

    // MARK: - App Lifecycle

    static func trackAppOpened() {}

    // MARK: - Onboarding

    static func trackOnboardingStarted() {}
    static func trackOnboardingReplayed() {}
    static func trackOnboardingDemoTriggered() {}

    // MARK: - Permissions

    static func trackAllPermissionsGranted() {}
    static func trackPermissionGranted(permission: String) {}

    // MARK: - Voice Interaction

    static func trackPushToTalkStarted() {}
    static func trackPushToTalkReleased() {}
    static func trackUserMessageSent(transcript: String) {}
    static func trackAIResponseReceived(response: String) {}
    static func trackElementPointed(elementLabel: String?) {}

    // MARK: - Errors

    static func trackResponseError(error: String) {}
    static func trackTTSError(error: String) {}
}

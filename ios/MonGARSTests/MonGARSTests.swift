//
//  MonGARSTests.swift
//  MonGARSTests
//
//  Created by Rork on April 10, 2026.
//

import Testing
@testable import MonGARS

struct MonGARSTests {
    @Test func retryPlannerRetriesTransientFailuresWithExponentialBackoff() {
        let planner = DownloadRetryPlanner(maxRetriesPerURL: 3, baseDelaySeconds: 1, maxDelaySeconds: 8)

        let first = planner.nextAction(for: .transientNetwork, retryCountOnCurrentURL: 0, hasFallbackURL: true)
        let second = planner.nextAction(for: .transientNetwork, retryCountOnCurrentURL: 1, hasFallbackURL: true)
        let capped = planner.nextAction(for: .transientNetwork, retryCountOnCurrentURL: 4, hasFallbackURL: true)

        #expect(first == .retry(delaySeconds: 1))
        #expect(second == .retry(delaySeconds: 2))

        #expect(capped == .switchToFallbackURL)
        #expect(planner.delay(forRetryAttempt: 7) == 8)
    }

    @Test func retryPlannerSwitchesToFallbackOnRepositorySpecificFailures() {
        let planner = DownloadRetryPlanner(maxRetriesPerURL: 2, baseDelaySeconds: 1, maxDelaySeconds: 8)

        let on404WithFallback = planner.nextAction(for: .httpStatus(404), retryCountOnCurrentURL: 0, hasFallbackURL: true)
        let on404NoFallback = planner.nextAction(for: .httpStatus(404), retryCountOnCurrentURL: 0, hasFallbackURL: false)
        let on403WithFallback = planner.nextAction(for: .httpStatus(403), retryCountOnCurrentURL: 0, hasFallbackURL: true)

        #expect(on404WithFallback == .switchToFallbackURL)
        #expect(on404NoFallback == .fail)
        #expect(on403WithFallback == .switchToFallbackURL)
    }

    @Test func fallbackURLSelectionIsDeterministic() {
        #expect(DownloadURLSelector.nextIndex(after: .switchToFallbackURL, currentIndex: 0, totalURLCount: 3) == 1)
        #expect(DownloadURLSelector.nextIndex(after: .switchToFallbackURL, currentIndex: 2, totalURLCount: 3) == nil)
        #expect(DownloadURLSelector.nextIndex(after: .retry(delaySeconds: 1), currentIndex: 1, totalURLCount: 3) == 1)
    }

    @Test func stateReducerTransitionsDownloadLifecycle() {
        var state = ModelDownloadState.notDownloaded

        state = ModelDownloadStateReducer.reduce(state, event: .started)
        #expect(state == .downloading(progress: 0))

        state = ModelDownloadStateReducer.reduce(state, event: .progress(0.42))
        #expect(state == .downloading(progress: 0.42))

        state = ModelDownloadStateReducer.reduce(state, event: .beginInstall)
        #expect(state == .installing)

        state = ModelDownloadStateReducer.reduce(state, event: .success(hasTokenizer: false))
        #expect(state == .installedMissingTokenizer)

        state = ModelDownloadStateReducer.reduce(state, event: .fail(message: "network down"))
        #expect(state == .error("network down"))

        state = ModelDownloadStateReducer.reduce(state, event: .cancelled)
        #expect(state == .notDownloaded)
    }
}

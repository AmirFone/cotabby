import Foundation
import Logging

/// File overview:
/// Lifecycle entry points and user preference changes for `SuggestionCoordinator`.
/// These methods are the closest thing this subsystem has to "public commands" from the app and UI.
extension SuggestionCoordinator {
    // MARK: - Lifecycle

    /// Reconciles coordinator state with the current permission and focus environment.
    func start() {
        CotabbyLogger.suggestion.info("Suggestion coordinator starting")
        reconcileWithCurrentEnvironment()
    }

    /// Cancels any pending work and detaches long-lived callbacks during shutdown.
    func stop() {
        CotabbyLogger.suggestion.info("Suggestion coordinator stopping")
        cancelPredictionWork()
        resetCachedGenerationContext()
        visualContextCoordinator.cancel(resetState: true)
        hideOverlay(reason: "Overlay hidden because Cotabby stopped observing suggestions.")
        inputMonitor.onEvent = nil
        inputMonitor.onSuppressedSyntheticInput = nil
        overlayController.onStateChange = nil
        visualContextCoordinator.onStateChange = nil
        visualContextCoordinator.onInjectedContextReady = nil
    }

    /// Clears any active suggestion work before the runtime swaps to a different model.
    /// This prevents stale completions from the previous model from surviving the switch.
    func prepareForRuntimeModelSwitch() {
        CotabbyLogger.suggestion.info("Preparing for runtime model switch, clearing active state")
        cancelPredictionWork()
        resetCachedGenerationContext()
        interactionState.resetAll()
        visualContextCoordinator.cancel(resetState: true)
        clearSuggestion(clearDiagnostics: true)
        hideOverlay(reason: "Overlay hidden because the runtime model is switching.")
        state = .idle
    }

    // MARK: - Settings

    /// The coordinator reacts to settings changes instead of owning those preferences directly.
    /// That separation keeps "user configuration" distinct from "active autocomplete session."
    func handleSuggestionSettingsChange(_ snapshot: SuggestionSettingsSnapshot) {
        guard settingsSnapshot != snapshot else {
            return
        }

        CotabbyLogger.suggestion.info("Settings changed, resetting suggestion state")
        // The prediction scheduled at the end of this method was asked for by a setting, not by a
        // key, so the spelling stages must not act on it. That covers Cotabby being switched back
        // on, where the field holds text written without it: rewriting that the instant the
        // switch flips is not what was asked for, and the edit used to go out while the key taps
        // were being put back, which lost its deletes and left the fix appended to the sentence.
        // It also covers a change while on (say, automatic fixes being enabled), which would
        // otherwise make the stages decide differently about a word they had already left alone.
        typedTextCheck = nil
        settingsSnapshot = snapshot
        cancelPredictionWork()
        resetCachedGenerationContext()
        clearSuggestion(clearDiagnostics: true)
        hideOverlay(reason: "Overlay hidden because autocomplete settings changed.")
        state = .idle

        // Cancel any obsolete context, then restart only when the subsystem is not disabled.
        visualContextCoordinator.cancel(resetState: true)
        if let focusedSnapshot = focusModel.snapshot.context,
           SuggestionAvailabilityEvaluator.shouldCaptureVisualContext(
               globallyEnabled: settingsSnapshot.isGloballyEnabled,
               temporarilyPaused: settingsSnapshot.isTemporarilyPaused,
               isLowPowerModeActive: lowPowerModeProvider.isLowPowerModeEnabled,
               isLowPowerModeAutoDisableEnabled: settingsSnapshot.isLowPowerModeAutoDisableEnabled,
               disabledAppBundleIdentifiers: settingsSnapshot.disabledAppBundleIdentifiers,
               disabledDomains: PerDomainDisableSettings.disabledDomains(),
               suggestInIntegratedTerminals: settingsSnapshot.suggestInIntegratedTerminals,
               inputMonitoringGranted: permissionManager.inputMonitoringGranted,
               screenRecordingGranted: permissionManager.screenRecordingGranted,
               focusSnapshot: focusModel.snapshot,
               isFastModeEnabled: settingsSnapshot.isFastModeEnabled
           ) {
            visualContextCoordinator.startSessionIfNeeded(for: focusedSnapshot)
        }

        if SuggestionAvailabilityEvaluator.shouldSchedulePrediction(
            globallyEnabled: settingsSnapshot.isGloballyEnabled,
            temporarilyPaused: settingsSnapshot.isTemporarilyPaused,
            disabledAppBundleIdentifiers: settingsSnapshot.disabledAppBundleIdentifiers,
            disabledDomains: PerDomainDisableSettings.disabledDomains(),
            suggestInIntegratedTerminals: settingsSnapshot.suggestInIntegratedTerminals,
            inputMonitoringGranted: permissionManager.inputMonitoringGranted,
            focusSnapshot: focusModel.snapshot
        ) {
            schedulePrediction()
        }
    }
}

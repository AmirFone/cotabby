import Foundation
import Logging

/// File overview:
/// Focus, permission, and keyboard-event entry points for `SuggestionCoordinator`.
/// This file answers: "what should happen when the environment changes or the user types?"
extension SuggestionCoordinator {
    // MARK: - Environment and Input Handling

    func handlePermissionChange() {
        CotabbyLogger.suggestion.debug("Permission state changed, reconciling")
        reconcileWithCurrentEnvironment()

        // Screen Recording is optional, so revoking it no longer trips `disabledReason` and the
        // `disablePredictions` teardown that used to cancel the session. Cancel it here instead so a
        // cached excerpt can't keep feeding screenshot-derived text into prompts after the user turns
        // the permission off. Granting it falls through to the schedule path below, which restarts
        // capture via `handleSupportedSnapshot`.
        if !permissionManager.screenRecordingGranted {
            visualContextCoordinator.cancel(resetState: true)
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
            handleSupportedSnapshot(focusModel.snapshot)
        }
    }

    /// Re-evaluates the pipeline immediately instead of waiting for another input or focus event.
    func handleLowPowerModeChange() {
        CotabbyLogger.suggestion.debug("Low Power Mode state changed, reconciling")
        reconcileWithCurrentEnvironment()
        if lowPowerModeProvider.isLowPowerModeEnabled, settingsSnapshot.isLowPowerModeAutoDisableEnabled {
            visualContextCoordinator.cancel(resetState: true)
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
            handleSupportedSnapshot(focusModel.snapshot)
        }
    }

    func handleFocusSnapshotChange(_ snapshot: FocusSnapshot) {
        switch capabilityFlickerGate.evaluate(snapshot) {
        case .apply:
            break
        case let .suppress(pendingBlockedReadCount: count):
            // Single-poll AX flicker on the same element (see FocusCapabilityFlickerGate). Drop the
            // event so the overlay does not bounce; log it so the suppression is observable.
            let suppressedDetail = snapshot.capability.summary
            CotabbyLogger.suggestion.trace(
                // swiftlint:disable:next line_length
                "Focus snapshot flicker suppressed: app=\(snapshot.applicationName) capability=\(snapshot.capability.shortLabel) detail=\(suppressedDetail) pendingBlockedReads=\(count)"
            )
            return
        }

        let changedDetail = snapshot.capability.summary
        CotabbyLogger.suggestion.trace(
            "Focus snapshot changed: app=\(snapshot.applicationName) capability=\(snapshot.capability.shortLabel) detail=\(changedDetail)"
        )
        // Start capturing visual context for a newly focused input even when predictions are
        // temporarily disabled by transient field states (e.g., "text is selected" or "secure
        // field"). Skip capture entirely when the subsystem is hard-disabled (globally off,
        // per-app disabled, terminal apps, or missing permissions) to avoid wasted compute.
        if let context = snapshot.context,
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
               focusSnapshot: snapshot,
               isFastModeEnabled: settingsSnapshot.isFastModeEnabled
           ) {
            visualContextCoordinator.startSessionIfNeeded(for: context)
        }

        if let disabledReason = currentDisabledReason(focusSnapshot: snapshot) {
            disablePredictionsPreservingVisualContext(reason: disabledReason)
        } else {
            handleSupportedSnapshot(snapshot)
        }
    }

    func handleSupportedSnapshot(_ snapshot: FocusSnapshot) {
        guard let focusedContext = snapshot.context else {
            disablePredictions(reason: "No focused text input.")
            return
        }

        // Start capturing visual context for newly focused input. Gated like the focus-change path
        // (and skipped in fast mode) so this entry point never kicks off screenshot/OCR work that the
        // earlier `shouldCaptureVisualContext` check already declined.
        if SuggestionAvailabilityEvaluator.shouldCaptureVisualContext(
            globallyEnabled: settingsSnapshot.isGloballyEnabled,
            temporarilyPaused: settingsSnapshot.isTemporarilyPaused,
            isLowPowerModeActive: lowPowerModeProvider.isLowPowerModeEnabled,
            isLowPowerModeAutoDisableEnabled: settingsSnapshot.isLowPowerModeAutoDisableEnabled,
            disabledAppBundleIdentifiers: settingsSnapshot.disabledAppBundleIdentifiers,
            disabledDomains: PerDomainDisableSettings.disabledDomains(),
            suggestInIntegratedTerminals: settingsSnapshot.suggestInIntegratedTerminals,
            inputMonitoringGranted: permissionManager.inputMonitoringGranted,
            screenRecordingGranted: permissionManager.screenRecordingGranted,
            focusSnapshot: snapshot,
            isFastModeEnabled: settingsSnapshot.isFastModeEnabled
        ) {
            visualContextCoordinator.startSessionIfNeeded(for: focusedContext)
        }

        if case .disabled = state {
            state = .idle
        }

        if interactionState.activeSession != nil {
            reconcileActiveSession(with: snapshot)
            return
        }

        if interactionState.hasFocusedElementChanged(comparedTo: focusedContext) {
            cancelPredictionWork()
            resetCachedGenerationContext()
            clearSuggestion(clearDiagnostics: true)
            hideOverlay(reason: "Overlay hidden because the focused field changed.")
            state = .idle
            // The user is now on a new editable surface and is likely to type soon. Prime the
            // selected engine in the background so weight loading and instruction tokenization
            // happen before the first real `respond` instead of inside its critical path. The
            // external endpoint also uses this hook to cold-load default local Ollama separately
            // from the aggressively cancellable autocomplete request.
            prewarmEngineForCurrentField(rawContext: focusedContext)
        }

        if overlayState.isVisible {
            hideOverlay(reason: "Overlay hidden because no ready suggestion remains.")
        }
    }

    /// Fire-and-forget warmup that builds a minimal request shape for the current focus and asks
    /// the routed engine to prime itself. Generation 0 is intentional — prewarm requests must not
    /// burn real generation numbers, because those drive the stale-result drop logic.
    private func prewarmEngineForCurrentField(rawContext: FocusedInputSnapshot) {
        let settings = settingsSnapshot
        let configuration = configuration
        let suggestionEngine = suggestionEngine
        Task { @MainActor [weak self] in
            // If the coordinator has been torn down (app shutdown), skip prewarm entirely.
            // Using `guard let self` instead of the optional chain prevents prewarm from
            // racing past a missed cache-reset barrier when self has gone away.
            guard let self else { return }
            // Honor the cache-reset barrier so prewarm always runs *after* the engine has dropped
            // the session that belongs to the previous editing context. Otherwise the reset can
            // null the freshly primed session out from under us.
            await self.awaitCachedGenerationContextResetIfNeeded()
            let prewarmContext = FocusedInputContext(snapshot: rawContext, generation: 0)
            let request = SuggestionRequestFactory.buildRequest(
                context: prewarmContext,
                settings: settings,
                configuration: configuration
            ).request
            await suggestionEngine.prewarm(for: request)
        }
    }

    /// Does the spelling work for a typed character before anything else reacts to the key, for the
    /// text the field is about to hold. Two reasons for doing it first and in place:
    /// the decision is then ready the moment the host publishes the key (see
    /// `handlePreparedTypoGateWithoutQueueing`), and the word strip can see that the word is about to
    /// be fixed and skip a redraw that would only delay the fix. The observer tap is listen-only, so
    /// the key itself is not held up by this.
    private func prepareSpellingAtKeystroke(for event: CapturedInputEvent) {
        isSpellingPendingForLastKey = false
        pendingKeystrokeUptimeNanoseconds = nil
        fieldAlreadyShowsLastKey = false
        guard event.shouldSchedulePrediction, interactionState.activeSession == nil,
              let suffix = Self.publishedSuffix(for: event), let baseline = focusModel.snapshot.context,
              currentDisabledReason(focusSnapshot: focusModel.snapshot) == nil else { return }
        let keystrokeUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        pendingKeystrokeUptimeNanoseconds = keystrokeUptimeNanoseconds
        lastTypingKeystrokeUptimeNanoseconds = keystrokeUptimeNanoseconds
        // The observer tap only listens, so the host gets the key without waiting for this
        // callback. When the main thread was busy, the host has often published the key already and
        // the snapshot read here is the text *with* it. Recognized by the field being exactly one
        // typed character ahead of what the gate last saw; waiting for "the text to change" would
        // then wait for a change that already happened, all the way to the 400 ms ceiling.
        fieldAlreadyShowsLastKey = lastGatedPrecedingText.map { baseline.precedingText == $0 + suffix } ?? false
        prepareTypoGate(
            precedingText: fieldAlreadyShowsLastKey ? baseline.precedingText : baseline.precedingText + suffix,
            textAfter: baseline.trailingText
        )
    }

    func handleInputEvent(_ event: CapturedInputEvent) -> Bool {
        leavesExistingTextAlone = false
        prepareSpellingAtKeystroke(for: event)
        // Give the emoji picker first look at every keystroke so it can drive its trigger state
        // machine. When a capture is involved, the picker owns the interaction: the suggestion
        // pipeline stands down and any lingering ghost text is cleared so it does not show behind the
        // panel. Consumption still happens through the active tap's `emojiCaptureKeyDecider`.
        if emojiInputObserver?(event) == true {
            if overlayState.isVisible || interactionState.activeSession != nil {
                cancelPredictionWork()
                clearSuggestion(clearDiagnostics: true)
                hideOverlay(reason: "Overlay hidden because the emoji picker is active.")
            }
            return false
        }

        if let disabledReason = currentDisabledReason(focusSnapshot: focusModel.snapshot) {
            disablePredictions(reason: disabledReason)
            return false
        }

        if event.kind == .acceptance {
            return acceptCurrentSuggestion()
        }

        if event.kind == .fullAcceptance {
            return acceptEntireSuggestion()
        }

        if let activeSession = interactionState.activeSession {
            return handleInputEvent(event, with: activeSession)
        }

        if event.shouldClearSuggestion {
            // Always kill pending work: a stale host-publish chain or debounce from the previous
            // keystroke must not fire a prediction this event meant to cancel.
            cancelPredictionWork()
            if hasSuggestionArtifactsToClear {
                clearSuggestion(clearDiagnostics: true)
                hideOverlay(reason: SuggestionSessionReconciler.overlayHideReason(for: event))
            }
            if !event.shouldSchedulePrediction, state != .idle {
                state = .idle
            }
        }

        if event.shouldSchedulePrediction {
            // Same Chromium AX-publish race as the with-session paths below: the CGEvent tap runs
            // *before* the host app processes the keystroke, so a synchronous `refreshNow()` here
            // reads pre-keystroke text and feeds it into generation. The result is a suggestion
            // that looks like the typed character was ignored — see
            // `schedulePredictionAfterHostPublishDelay` for the full rationale.
            schedulePredictionAfterHostPublishDelay(expectingSuffix: Self.publishedSuffix(for: event))
        }

        return false
    }

    /// Maximum wall time we'll wait for the host app to publish post-keystroke AX before giving
    /// up and generating against whatever's there. Chosen empirically: long enough to cover
    /// Chrome's slower contenteditable publish on a busy page, short enough that the user can
    /// always type ahead without the rescheduled suggestion feeling stuck.
    fileprivate static let hostPublishWaitCeilingMs = 400

    /// Interval between AX polls while waiting for the host publish. Same order of magnitude as
    /// the focus poll itself (default 80ms) but tighter so we catch the publish promptly without
    /// burning CPU on AX queries that are themselves 5–15ms each.
    private static let hostPublishPollIntervalMs = 30

    /// First-retry interval after the immediate (elapsed 0) poll, which runs inside the keystroke's
    /// own tap callback before the host has even processed the key and therefore always misses. A
    /// short first retry catches fast-publishing native apps in ~10ms instead of making them wait a
    /// full steady interval; slow Chromium hosts fall through to `hostPublishPollIntervalMs` below.
    private static let hostPublishFirstPollIntervalMs = 10

    /// How long polls keep the short first interval before relaxing to `hostPublishPollIntervalMs`.
    private static let hostPublishFastPollWindowMs = 60

    /// Schedules a fresh prediction once the host app has actually published the new
    /// contenteditable text to AX. The previous fix waited a fixed 150ms — see PR #376 — but the
    /// logs in #381 showed Chromium's publish lag can exceed that ceiling on a busy page, so the
    /// rescheduled generation still read pre-keystroke text and produced a suggestion that looked
    /// like Cotabby swallowed the character.
    ///
    /// We now snapshot the AX state at keystroke time (focused element identity, preceding text,
    /// selection) and poll `focusModel` until the snapshot actually moves on. The poll is capped
    /// at `hostPublishWaitCeilingMs` so a silent host can't hang the pipeline — once the cap is
    /// reached we generate against whatever's there, matching the old fixed-delay behavior.
    /// `schedulePrediction()` internally `replaceDebouncedWork`s, so back-to-back keystrokes
    /// still collapse cleanly. The `hostPublishPollGeneration` token adds the missing outer
    /// coalescing layer: only the newest keystroke's polling chain may keep reading AX.
    /// The character a typing keystroke must leave at the end of the field, when it is predictable.
    /// Quotes are excluded because hosts may substitute smart quotes.
    static func publishedSuffix(for event: CapturedInputEvent) -> String? {
        guard event.kind == .textMutation, event.characters.count == 1, let character = event.characters.first,
              character.isLetter || character.isNumber || " .,!?;:-".contains(character) else {
            return nil
        }
        return event.characters
    }

    /// - Parameter expectingSuffix: the character the keystroke typed. When given, the host counts as
    ///   having published only once the field ends with it; otherwise a field that was already lagging
    ///   one keystroke behind (`over` read while `over ` was typed) passes the "text changed" test a
    ///   key early, and a finished word is processed as if it were still being typed.
    func schedulePredictionAfterHostPublishDelay(expectingSuffix: String? = nil) {
        hostPublishPollGeneration &+= 1
        let pollGeneration = hostPublishPollGeneration
        let baseline = focusModel.snapshot.context
        // Anchor for folding the publish wait into the debounce: `schedulePrediction` subtracts
        // the wall time already spent waiting for AX from the configured debounce, so the debounce
        // window starts at the keystroke instead of stacking on top of the publish delay. Measured
        // from real uptime rather than the scheduled poll intervals because each poll's AX capture
        // adds milliseconds the schedule does not account for.
        let keystrokeUptimeNanoseconds = pendingKeystrokeUptimeNanoseconds ?? DispatchTime.now().uptimeNanoseconds
        pendingKeystrokeUptimeNanoseconds = nil
        lastTypingKeystrokeUptimeNanoseconds = keystrokeUptimeNanoseconds
        // A typed character that `prepareSpellingAtKeystroke` did not cover (a key typed through a
        // visible suggestion): do the spelling work for the text the field is about to hold in the
        // gap before the host publishes it.
        let alreadyShowsKey = fieldAlreadyShowsLastKey && expectingSuffix != nil
        fieldAlreadyShowsLastKey = false
        if let suffix = expectingSuffix, let baseline, !alreadyShowsKey {
            let predictedText = baseline.precedingText + suffix
            let textAfter = baseline.trailingText
            if preparedTypoGate?.precedingText != predictedText || preparedTypoGate?.textAfter != textAfter {
                DispatchQueue.main.async { [weak self] in
                    self?.prepareTypoGate(precedingText: predictedText, textAfter: textAfter)
                }
            }
        }

        // The event tap fires before the host processes the key, so an immediate `refreshNow()`
        // almost always reads the pre-keystroke value while still paying the full AX cost. Start at
        // the first retry instead; this keeps fast native fields responsive and removes one
        // guaranteed-stale read from every keypress.
        // Nothing to wait for when the field already shows the key: check on the next turn (not
        // inside this tap callback, where posting a fix's keys is unreliable).
        // The first look is timed from the key, not from here: the spelling work done at the key
        // has already used part of the wait.
        let sinceKeyMs = Self.elapsedMilliseconds(since: keystrokeUptimeNanoseconds)
        let firstPollDelayMs = alreadyShowsKey ? 0 : max(0, Self.hostPublishFirstPollIntervalMs - sinceKeyMs)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(firstPollDelayMs)) { [weak self] in
            self?.pollForHostPublish(
                baseline: HostPublishBaseline(
                    precedingText: baseline?.precedingText,
                    elementIdentifier: baseline?.elementIdentifier,
                    selectionLocation: baseline?.selection.location,
                    keystrokeUptimeNanoseconds: keystrokeUptimeNanoseconds,
                    expectedSuffix: expectingSuffix,
                    alreadyShowsKey: alreadyShowsKey
                ),
                pollGeneration: pollGeneration,
                elapsedMs: Self.hostPublishFirstPollIntervalMs
            )
        }
    }

    /// The AX state captured at keystroke time, against which the host-publish poll detects "the
    /// host has processed the key", plus the uptime anchor for folding the wait into the debounce.
    private struct HostPublishBaseline {
        let precedingText: String?
        let elementIdentifier: String?
        let selectionLocation: Int?
        let keystrokeUptimeNanoseconds: UInt64
        let expectedSuffix: String?
        /// The baseline text already includes the typed character, so an unchanged field is the
        /// published state rather than a reason to keep waiting.
        var alreadyShowsKey = false
        /// How long to keep polling, and whether to run the pipeline anyway when that time is up.
        var ceilingMs = SuggestionCoordinator.hostPublishWaitCeilingMs
        var generatesAtCeiling = true
    }

    /// Drives the snapshot-changed gate. Reads the live focus snapshot, fires `schedulePrediction`
    /// as soon as any of the captured baseline fields move on, and otherwise tail-calls itself
    /// after `hostPublishPollIntervalMs` until the ceiling is hit.
    private func pollForHostPublish(
        baseline: HostPublishBaseline,
        pollGeneration: UInt64,
        elapsedMs: Int
    ) {
        guard pollGeneration == hostPublishPollGeneration else {
            return
        }

        traceTyping("poll")
        focusModel.refreshNow()
        traceTyping("poll read")
        guard pollGeneration == hostPublishPollGeneration else {
            return
        }

        let currentContext = focusModel.snapshot.context

        // No focus context at all means the user moved away from any editable field — let
        // `schedulePrediction` and its downstream guards handle the disabled / unsupported state.
        let textChanged = currentContext?.precedingText != baseline.precedingText
        let elementChanged = currentContext?.elementIdentifier != baseline.elementIdentifier
        let selectionChanged = currentContext?.selection.location != baseline.selectionLocation
        let showsTypedCharacter = elementChanged
            || baseline.expectedSuffix.map { currentContext?.precedingText.hasSuffix($0) ?? true } ?? true
        let isPublished = (textChanged || elementChanged || selectionChanged) && showsTypedCharacter
        if isPublished || (baseline.alreadyShowsKey && !textChanged) {
            // The publish arrived. When it matches the snapshot a speculative post-acceptance
            // generation was built against, that generation is already in flight (or applied) for
            // exactly this content: scheduling another would only retire it and pay the full
            // round-trip the speculation existed to skip. Stand down and let it land; `apply`
            // validates via the same signature. Any divergence falls through to the normal
            // reschedule, whose newer work id retires the speculation automatically.
            if let expected = pendingSpeculativeSignature,
               currentContext?.contentSignature == expected {
                logStage(
                    "speculation-validated",
                    workID: currentWorkID,
                    generation: latestGenerationNumber,
                    message: "Host published exactly the speculated text; keeping the in-flight generation."
                )
                return
            }
            pendingSpeculativeSignature = nil
            traceTyping(isPublished ? "host published" : "host had published")
            if handlePreparedTypoGateWithoutQueueing(context: currentContext) {
                return
            }
            schedulePrediction(
                consumedDelayMilliseconds: Self.elapsedMilliseconds(since: baseline.keystrokeUptimeNanoseconds)
            )
            if !isPublished {
                // "Already shows the key" is a deduction, and a doubled letter typed faster than
                // the gate runs can fool it (the field is then still one key behind). Keep watching
                // briefly: if the text does move on to end with this key, that publish is handled
                // like any other; if not, the watch ends without doing anything.
                var watch = baseline
                watch.alreadyShowsKey = false
                watch.ceilingMs = elapsedMs + Self.hostPublishFastPollWindowMs
                watch.generatesAtCeiling = false
                // The work just scheduled must not be retired by this watch, so it keeps the
                // generation it was started with.
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.hostPublishFirstPollIntervalMs)) { [weak self] in
                    self?.pollForHostPublish(
                        baseline: watch,
                        pollGeneration: pollGeneration,
                        elapsedMs: elapsedMs + Self.hostPublishFirstPollIntervalMs
                    )
                }
            }
            return
        }

        // Ceiling: stop polling and generate anyway. Without this fallback a host that genuinely
        // produces no AX change (rare but possible — e.g. dead-key composition) would never get
        // its next prediction.
        // We already waited the short first interval before entering this method. Native fields
        // publish within a few tens of milliseconds, so the first stretch polls tightly; slower
        // Chromium hosts fall through to the steady cadence until the ceiling.
        let interval = elapsedMs < Self.hostPublishFastPollWindowMs
            ? Self.hostPublishFirstPollIntervalMs
            : Self.hostPublishPollIntervalMs
        let nextElapsed = elapsedMs + interval
        guard nextElapsed < baseline.ceilingMs else {
            if baseline.generatesAtCeiling {
                schedulePrediction(
                    consumedDelayMilliseconds: Self.elapsedMilliseconds(since: baseline.keystrokeUptimeNanoseconds)
                )
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(interval)) { [weak self] in
            self?.pollForHostPublish(
                baseline: baseline,
                pollGeneration: pollGeneration,
                elapsedMs: nextElapsed
            )
        }
    }

    static func elapsedMilliseconds(since uptimeNanoseconds: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- uptimeNanoseconds) / 1_000_000)
    }

    func handleSuppressedSyntheticInput() {
        logStage(
            "suppressed-synthetic-input",
            workID: currentWorkID,
            generation: latestGenerationNumber,
            message: "Ignored Cotabby's own synthetic key event."
        )
    }

    /// While a suggestion tail is active, normal typing is interpreted relative to that tail first.
    /// This is the same idea as reconciling optimistic UI with the eventual live editor state:
    /// keep the existing session only when the user's new input is still consistent with it.
    /// Typing exactly what the ghost text predicted skips the prediction pipeline, which is where the
    /// sentence pass and the word strip are fed. Look at the field once the host has published the
    /// keystroke, so the strip follows type-through and a sentence finished that way is still proofread.
    func noteTextDuringTypeThrough(_ characters: String) {
        let crossesWordBoundary = characters.contains { $0 == " " || $0.isNewline }
        let feedsSentencePass = sentenceFixPresenter != nil && crossesWordBoundary
        guard feedsSentencePass || wordPredictionPresenter != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.typeThroughSentenceCheckDelaySeconds) { [weak self] in
            guard let self else { return }
            self.focusModel.refreshNow()
            guard let context = self.focusModel.snapshot.context, !context.isSecure else { return }
            self.noteTextForWordStrip(context)
            guard feedsSentencePass else { return }
            self.sentenceFixPresenter?.noteTypedText(
                context.precedingText,
                caretRect: context.caretRect,
                focusChangeSequence: context.focusChangeSequence
            )
        }
    }

    func handleInputEvent(_ event: CapturedInputEvent, with session: ActiveSuggestionSession) -> Bool {
        switch event.kind {
        case .textMutation:
            if advanceActiveSessionIfTypedCharactersMatch(event.characters, session: session) {
                noteTextDuringTypeThrough(event.characters)
                return false
            }

            invalidateActiveSuggestion(
                reason: SuggestionSessionReconciler.overlayHideReason(for: event),
                clearDiagnostics: false
            )
            if event.shouldSchedulePrediction {
                schedulePredictionAfterHostPublishDelay(expectingSuffix: Self.publishedSuffix(for: event))
            }
            return false

        case .shortcutMutation:
            invalidateActiveSuggestion(
                reason: "Overlay hidden because a shortcut changed the text and invalidated the current suggestion.",
                clearDiagnostics: false
            )
            if event.shouldSchedulePrediction {
                schedulePredictionAfterHostPublishDelay()
            }
            return false

        case .navigation, .dismissal:
            invalidateActiveSuggestion(
                reason: SuggestionSessionReconciler.overlayHideReason(for: event),
                clearDiagnostics: false
            )
            state = .idle
            return false

        case .other, .acceptance, .fullAcceptance:
            return false
        }
    }
}

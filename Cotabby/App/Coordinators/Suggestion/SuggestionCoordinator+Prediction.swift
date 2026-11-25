import Foundation
import Logging

/// File overview:
/// Debounce, generation, stale-result handling, and visual-context-triggered rescheduling.
/// This is the async half of the coordinator's state machine.
extension SuggestionCoordinator {
    // MARK: - Prediction Pipeline

    /// How recent a focus capture must be for the pipeline to trust it instead of paying another
    /// synchronous AX walk. Chosen to cover the debounce window plus scheduling jitter: a capture
    /// younger than this was taken after the keystroke that scheduled the current work, so a fresh
    /// read cannot observe a different editing context without the downstream generation guards
    /// also tripping.
    static let freshSnapshotReuseWindowMilliseconds = 30

    func schedulePrediction(consumedDelayMilliseconds: Int = 0) {
        // Any normal reschedule supersedes an outstanding speculative bet (its work id retires the
        // in-flight task; this retires the signature exemption so a late result cannot sneak in).
        pendingSpeculativeSignature = nil
        if let disabledReason = currentDisabledReason(focusSnapshot: focusModel.snapshot) {
            disablePredictions(reason: disabledReason)
            return
        }

        // The debounce window adapts to the last generation latency: snappier when the model is
        // fast, calmer when it is slow (fewer doomed generations to cancel). The configured value
        // is the fallback until a first latency exists.
        // With the word strip on there is no model request to protect: the typo gate and the strip
        // are local and take well under a millisecond, so they run as soon as the host publishes.
        let debounceMilliseconds = wordPredictionPresenter?.replacesGhostText == true ? 0 : DebouncePolicy.milliseconds(
            lastGenerationLatencyMilliseconds:
                lastLatencyByEngine[settingsSnapshot.selectedEngine],
            fallback: settingsSnapshot.debounceMilliseconds,
            engine: settingsSnapshot.selectedEngine,
            isCloudEndpoint: settingsSnapshot.usesCloudEndpoint
        )
        // The debounce clock starts at the keystroke, not here. The host-publish poll has already
        // consumed real wall time waiting for the host to publish the keystroke to AX, and that
        // wait collapses bursts just as well as sleeping does. Stacking the full debounce on top
        // of the publish wait was pure added latency, so only the unconsumed remainder is slept.
        let remainingDelay = max(0, debounceMilliseconds - consumedDelayMilliseconds)

        // Task cancellation in Swift is cooperative, so we also use an explicit work id.
        // That gives us strict "latest request wins" semantics even if an old task wakes up late.
        let workID = workController.replaceDebouncedWork(
            delayMilliseconds: remainingDelay
        ) { [weak self] workID in
            await self?.generateFromCurrentFocus(workID: workID)
        }

        // Equality guards keep repeated keystrokes from republishing identical state: every
        // @Published write re-renders every coordinator observer (menu bar label included).
        if state != .debouncing {
            state = .debouncing
        }
        logStage(
            "debouncing",
            workID: workID,
            message: "Debouncing (\(debounceMilliseconds)ms window, \(remainingDelay)ms remaining) before generating."
        )
    }

    /// Cotabby's own paced keystrokes may still be landing: the field is mid-edit, and planning from it
    /// would stack a second edit on a half-applied one. Returns false when newer work superseded this.
    private func waitForSyntheticInputToSettle(workID: UInt64) async -> Bool {
        let pending = SyntheticEventPoster.secondsUntilSettled
        guard pending > 0 else { return true }
        try? await Task.sleep(nanoseconds: UInt64((pending + 0.01) * 1_000_000_000))
        return workController.isCurrent(workID)
    }

    /// One line of the typing hot path's timeline, measured from the last typed key. Trace level,
    /// so the message is only built under `-cotabby-debug`; the live test reads these to show where
    /// the time between a key and its fix goes.
    func traceTyping(_ step: @autoclosure () -> String) {
        CotabbyLogger.suggestion.trace(
            "typing +\(Self.elapsedMilliseconds(since: lastTypingKeystrokeUptimeNanoseconds)) ms: \(step())"
        )
    }

    /// Refreshes focus after debounce, materializes a stable context, and starts generation.
    func generateFromCurrentFocus(workID: UInt64) async {
        guard workController.isCurrent(workID) else {
            return
        }
        traceTyping("work started")
        guard await waitForSyntheticInputToSettle(workID: workID) else {
            return
        }

        await awaitCachedGenerationContextResetIfNeeded()
        guard workController.isCurrent(workID) else {
            return
        }
        traceTyping("settled")

        // We intentionally re-read the latest focus snapshot here instead of trusting the earlier
        // key event, because the user may have switched apps or fields during the debounce window.
        // The host-publish poll usually captured one milliseconds ago, though, so a fresh-enough
        // capture is reused instead of paying another synchronous AX walk back to back.
        focusModel.refreshIfStale(maxAgeMilliseconds: Self.freshSnapshotReuseWindowMilliseconds)
        let snapshot = focusModel.snapshot

        if let disabledReason = currentDisabledReason(focusSnapshot: snapshot) {
            disablePredictions(reason: disabledReason)
            return
        }

        guard let rawContext = snapshot.context else {
            disablePredictions(reason: snapshot.capability.summary)
            return
        }

        guard SuggestionRequestFactory.shouldGenerateSuggestion(for: rawContext.precedingText) else {
            wordPredictionPresenter?.hidePredictions()
            clearSuggestion()
            hideOverlay(reason: "Overlay hidden because the field has no typed text yet.")
            state = .idle
            return
        }

        if settingsSnapshot.usesCloudEndpoint, !settingsSnapshot.isFastModeEnabled,
           permissionManager.screenRecordingGranted {
            visualContextCoordinator.refreshWhileTyping(for: rawContext)
        }
        // Typo gate: before building a normal continuation, check the current word with
        // NSSpellChecker. A misspelled word either suppresses the continuation (so completions never
        // pile onto a broken word), presents a green correction, or automatically fixes a completed
        // word after Space. Native correction is instant and needs no model generation, so it is
        // handled synchronously and returns before any request runs.
        // Before the gate, so a just-reverted fix is already "kept" when the gate sees the word again.
        settleAutoFixOutcomes(precedingText: rawContext.precedingText)
        noticeSelfCorrections(precedingText: rawContext.precedingText)
        traceTyping("typo gate")
        if runSpellingStages(rawContext: rawContext, workID: workID) {
            return
        }
        if let pauseReason = ghostTextPauseReason() {
            clearSuggestion()
            hideOverlay(reason: pauseReason)
            state = .idle
            logStage("ghost-paused", workID: workID, message: pauseReason)
            return
        }

        let context = interactionState.materializeContext(from: rawContext)
        // A cached suggestion consistent with the live text re-shows instantly: no debounce paid,
        // no model run. Covers backspace rollback, type-through re-entry, and field return.
        if restoreSuggestionFromAnchorCache(context: context, workID: workID) {
            return
        }
        // Screen Recording is optional. Re-check it live so a cached excerpt captured before the user
        // revoked the permission can never be injected during the 2s permission-poll window.
        let visualContextSummary = permissionManager.screenRecordingGranted
            ? visualContextCoordinator.excerpt(for: context)
            : nil
        let clipboardContext = pinnedClipboardContext(rawContext: rawContext)
        let requestBuildResult = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: settingsSnapshot,
            configuration: configuration,
            clipboardContext: clipboardContext,
            visualContextSummary: visualContextSummary
        )
        latestGenerationNumber = context.generation
        let request = requestBuildResult.request
        latestRequestID = request.requestID

        state = .generating
        logStage(
            "generating",
            workID: workID,
            generation: context.generation,
            message: "Requesting a completion for \(context.elementIdentifier).",
            prompt: requestBuildResult.promptPreview
        )

        dispatchGeneration(request: request, workID: workID)
    }

    /// Why ghost text should not be generated right now, even though the field is eligible: the word
    /// strip owns Tab while it is on (ghost text would give Tab two meanings), or Low Power Mode
    /// pauses the on-device model.
    /// Starts reading the screen around a newly focused field, unless nothing would read the
    /// result. Screen text only ever goes into a ghost-text prompt, and while ghost text is paused
    /// (the word strip has taken its place, or Low Power Mode) a capture is a screenshot and a
    /// text-recognition pass for nothing. A chat app changes its focused element many times a
    /// minute, and each change used to pay for one.
    func startVisualContextSessionIfUsed(for context: FocusedInputSnapshot) {
        guard ghostTextPauseReason() == nil else { return }
        visualContextCoordinator.startSessionIfNeeded(for: context)
    }

    /// True while ghost text cannot be generated, so warming its model up would be work for
    /// nothing (and, with the model not loaded for the word strip's sake, would load it).
    var isGhostTextPaused: Bool {
        ghostTextPauseReason() != nil
    }

    private func ghostTextPauseReason() -> String? {
        if wordPredictionPresenter?.replacesGhostText == true {
            return "Overlay hidden because word predictions replace ghost text."
        }
        return SuggestionAvailabilityEvaluator.generationPauseReason(
            isLowPowerModeActive: lowPowerModeProvider.isLowPowerModeEnabled,
            isLowPowerModeAutoDisableEnabled: settingsSnapshot.isLowPowerModeAutoDisableEnabled,
            usesOnDeviceModel: !settingsSnapshot.usesCloudEndpoint
        )
    }

    /// Re-shows the freshest cached suggestion consistent with the live text, if any survives the
    /// same display guards a fresh generation passes. Returns true when a suggestion was restored
    /// (the caller skips generation entirely). The win is exactly the common editing moments:
    /// deleting a typo, retyping suggested words after an invalidation, returning to a field.
    private func restoreSuggestionFromAnchorCache(context: FocusedInputContext, workID: UInt64) -> Bool {
        guard !userDefaults.bool(forKey: Self.anchorReuseDisabledDefaultsKey) else { return false }
        guard context.selection.length == 0, !context.isSecure else { return false }
        guard let remainder = suggestionAnchorCache.remainder(
            identityKey: context.focusedInputIdentityKey,
            precedingText: context.precedingText
        ), !remainder.isEmpty else { return false }

        // Same display guards `apply` enforces on a fresh result. The remainder is a suffix of a
        // suggestion that already passed the normalizer and seam guard for this exact text path,
        // so only the guards that depend on CURRENT field state need re-checking.
        if TrailingDuplicationFilter.duplicatesTrailingText(remainder, trailingText: context.trailingText) {
            return false
        }
        if let pendingAcceptedTail = lastAcceptedTail,
           SuggestionSessionReconciler.isStaleAcceptanceEcho(
               resultText: remainder,
               acceptedChunk: pendingAcceptedTail.text,
               currentPrecedingText: context.precedingText,
               acceptedPrecedingText: pendingAcceptedTail.precedingText
           ) {
            return false
        }

        lastAcceptedTail = nil
        latestGenerationNumber = context.generation
        let session = interactionState.startSession(
            fullText: remainder,
            liveContext: context,
            latency: 0
        )
        state = .ready(text: session.remainingText, latency: session.latency)
        presentOverlay(
            text: session.remainingText,
            at: context.caretRect,
            context: context,
            isRightToLeft: TextDirectionDetector.isRightToLeft(context.precedingText)
        )
        logStage(
            "anchor-restore",
            workID: workID,
            generation: context.generation,
            message: "Re-showed a cached suggestion without regenerating.",
            normalizedOutput: remainder
        )
        return true
    }

    /// Starts the next generation immediately after a final-chunk accept, against the snapshot
    /// the host is expected to publish, instead of idling through the publish poll first. The
    /// poll keeps running as the validator: a matching publish lets this result through
    /// (`pendingSpeculativeSignature` in `apply`), a mismatch schedules a normal regeneration
    /// whose newer work id retires this one automatically.
    func dispatchSpeculativePostAcceptanceGeneration(
        rawContext: FocusedInputSnapshot,
        insertionChunk: String
    ) {
        guard !userDefaults.bool(forKey: Self.speculativePrefetchDisabledDefaultsKey) else { return }
        guard !insertionChunk.isEmpty else { return }

        let optimistic = SpeculativeAcceptanceContext.optimisticSnapshot(
            after: rawContext,
            inserting: insertionChunk
        )

        // Same pre-generation gates the ordinary cycle applies, minus their UI side effects: a
        // speculative request must not spend a decode on text the normal path would refuse (too
        // little text) or suppress (typo gate). The post-publish regeneration still runs the full
        // gate with its correction semantics; declining here only skips the speculation.
        guard SuggestionRequestFactory.shouldGenerateSuggestion(for: optimistic.precedingText) else {
            return
        }
        if settingsSnapshot.suppressCompletionsOnTypo,
           let trailingWord = CurrentWordExtractor.extractTrailingWord(from: optimistic.precedingText)?.result.word,
           spellChecker.isTypo(trailingWord) {
            return
        }

        let context = interactionState.materializeContext(from: optimistic)
        pendingSpeculativeSignature = context.contentSignature

        let visualContextSummary = permissionManager.screenRecordingGranted
            ? visualContextCoordinator.excerpt(for: context)
            : nil
        // The pinned clipboard verdict, not a fresh filter pass: a speculative request that
        // re-evaluated relevance against the optimistic prefix could flip the verdict and rewrite
        // the prompt head mid-session, breaking prompt-byte continuity with the ordinary cycle
        // (and the llama KV prefix reuse that depends on it).
        let clipboardContext = pinnedClipboardContext(rawContext: optimistic)
        let requestBuildResult = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: settingsSnapshot,
            configuration: configuration,
            clipboardContext: clipboardContext,
            visualContextSummary: visualContextSummary
        )
        latestGenerationNumber = context.generation
        let request = requestBuildResult.request
        latestRequestID = request.requestID

        let workID = workController.replaceDebouncedWork(delayMilliseconds: 0) { [weak self] workID in
            guard let self else { return }
            self.dispatchGeneration(request: request, workID: workID)
        }
        state = .generating
        logStage(
            "speculative-generating",
            workID: workID,
            generation: context.generation,
            message: "Started the post-acceptance generation against the expected post-insert text.",
            prompt: requestBuildResult.promptPreview
        )
    }

    /// Runs the engine generation for `request` as the replaceable work for `workID`, applying the
    /// result (or failure) only while it is still the current work. Extracted from
    /// `generateFromCurrentFocus` so that function stays within the project's complexity budget.
    private func dispatchGeneration(request: SuggestionRequest, workID: UInt64) {
        // A new generation starts a new stream. The state value deliberately preserves an already
        // scheduled drain callback while dropping the old request's partial and rendered text.
        suggestionStreamingState.beginGeneration()
        // Streaming the ghost text token-by-token is opt-in. Read the flag here on the main actor so
        // the work closure captures a plain Bool. When off, the closure passes no `onPartial`, so the
        // engine skips its per-token main-actor hops entirely and the suggestion appears once, fully
        // formed, through `apply` below; when on, each partial renders as an acceptable session the
        // user can Tab into early.
        let shouldStreamPartials = settingsSnapshot.streamSuggestionsWhileGenerating
        workController.replaceGenerationWork(for: workID) { [weak self] in
            guard let self else {
                return
            }

            do {
                let onPartial: (@MainActor (SuggestionResult) -> Void)?
                if shouldStreamPartials {
                    onPartial = { [weak self] partial in self?.queueStreamedPartial(partial, workID: workID) }
                } else {
                    onPartial = nil
                }
                let result = try await suggestionEngine.generateSuggestion(
                    for: request,
                    onPartial: onPartial
                )
                guard !Task.isCancelled, self.workController.isCurrent(workID) else {
                    return
                }

                await apply(result: result, workID: workID)
            } catch SuggestionClientError.cancelled {
                return
            } catch {
                guard self.workController.isCurrent(workID) else {
                    return
                }

                await applyFailure(error.localizedDescription, workID: workID)
            }
        }
    }

    /// Resolves the clipboard prompt section under the pinning policy documented on
    /// `clipboardPrefaceMemo`: an accepted (non-nil) verdict is reused for the rest of the field
    /// session so the prompt head stays stable and the engine's KV common prefix survives; a nil
    /// verdict re-evaluates per request because it adds nothing to the prompt and the clipboard
    /// may only become relevant once more text is typed. A new copy or a field switch always
    /// re-evaluates.
    private func pinnedClipboardContext(rawContext: FocusedInputSnapshot) -> String? {
        guard settingsSnapshot.isClipboardContextEnabled else {
            return nil
        }

        let changeCount = clipboardContextProvider.currentChangeCount
        if let memo = clipboardPrefaceMemo,
           memo.focusSequence == rawContext.focusChangeSequence,
           memo.changeCount == changeCount,
           memo.value != nil {
            return memo.value
        }

        // Same bounded window the downstream distiller sees, so the relevance gate and the
        // per-line filter can't disagree about what "shares tokens with the prefix" means.
        let truncatedPrefix = SuggestionRequestFactory.truncatedPromptPrefix(
            from: rawContext.precedingText,
            configuration: configuration,
            engine: settingsSnapshot.selectedEngine,
            cloudWindow: SuggestionRequestFactory.cloudContextWindow(for: settingsSnapshot)
        )
        let value = clipboardRelevanceFilter.filter(
            clipboard: clipboardContextProvider.currentContext(),
            pasteboardChangeCount: changeCount,
            precedingText: truncatedPrefix
        )
        clipboardPrefaceMemo = ClipboardPrefaceMemo(
            focusSequence: rawContext.focusChangeSequence,
            changeCount: changeCount,
            value: value
        )
        return value
    }

    // MARK: - Streamed partial rendering

    /// Coalesces streamed partials to at most one render per runloop turn. Tokens arrive every
    /// 10-50ms from the engine, and rendering each one would stack session updates and overlay
    /// layout on the main actor; latest-wins coalescing bounds that work while the authoritative
    /// final result still arrives through `apply`.
    private func queueStreamedPartial(_ partial: SuggestionResult, workID: UInt64) {
        guard workController.isCurrent(workID) else {
            return
        }
        guard suggestionStreamingState.enqueue(partial, workID: workID) else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.drainStreamedPartial()
        }
    }

    private func drainStreamedPartial() {
        guard let pending = suggestionStreamingState.drain() else {
            return
        }
        applyStreamedPartial(pending.result, workID: pending.workID)
    }

    /// Renders one streamed partial as a real, acceptable session.
    ///
    /// A real session rather than a cosmetic overlay because acceptance gates on the live session
    /// (never on `state`), so the user can Tab into a stream the moment the first words appear;
    /// accepting cancels the in-flight work (work id bump), freezing the suggestion at what was
    /// streamed. Renders are monotonic (`StreamedGhostTextPolicy`) so reordered hops and
    /// normalizer rewrites never shrink visible ghost text, and the materialize check stops
    /// partials the moment the field text moves on without a keystroke (a keystroke already
    /// bumped the work id before this runs).
    private func applyStreamedPartial(_ partial: SuggestionResult, workID: UInt64) {
        guard workController.isCurrent(workID) else {
            return
        }
        guard suggestionStreamingState.canRender(partial.text) else {
            return
        }
        guard let rawContext = focusModel.snapshot.context else {
            return
        }

        let liveContext = interactionState.materializeContext(from: rawContext)
        guard liveContext.generation == partial.generation else {
            return
        }

        // Junk checks remain cheap enough for every partial. The first generated word is buffered
        // until its boundary arrives, then its spelling decision is cached for the generation so
        // the AppKit/XPC lookup never runs at token cadence.
        guard CompletionSeamGuard.allowsStreamedPartial(
            precedingText: liveContext.precedingText,
            completion: partial.text
        ) else {
            return
        }
        guard passesStreamedLeadingWordGate(
            precedingText: liveContext.precedingText,
            completion: partial.text
        ) else {
            return
        }

        _ = interactionState.startSession(
            fullText: partial.text,
            liveContext: liveContext,
            latency: partial.latency
        )
        suggestionStreamingState.recordRendered(partial.text)
        presentOverlay(
            text: partial.text,
            at: liveContext.caretRect,
            context: liveContext,
            isRightToLeft: TextDirectionDetector.isRightToLeft(liveContext.precedingText)
        )
    }

    /// Resolves the generation-scoped leading-word gate for one streamed partial and returns whether
    /// the partial may render. A pending gate consults the seam guard, which either keeps buffering
    /// (`wait`) or settles the gate for the rest of this generation; a settled gate answers without
    /// touching the spell checker again. Kept separate so `applyStreamedPartial` stays within the
    /// project's cyclomatic-complexity budget.
    private func passesStreamedLeadingWordGate(precedingText: String, completion: String) -> Bool {
        switch suggestionStreamingState.leadingWordGateState {
        case .allowed:
            return true
        case .suppressed:
            return false
        case .pending:
            switch CompletionSeamGuard.streamedLeadingWordVerdict(
                precedingText: precedingText,
                completion: completion,
                spellingAssessment: { self.completionSpellingAssessment(for: $0) }
            ) {
            case .wait:
                return false
            case .allow:
                suggestionStreamingState.resolveLeadingWordGate(.allowed)
                return true
            case .suppress:
                suggestionStreamingState.resolveLeadingWordGate(.suppressed)
                return false
            }
        }
    }

    /// The gate's thresholds for this writer right now: the auto-fix bar rises with their undo rate.
    private func typoGateSettings() -> TypoGate.Settings {
        var gateSettings = TypoGate.Settings(
            suppressCompletionsOnTypo: settingsSnapshot.suppressCompletionsOnTypo,
            offerTypoCorrections: settingsSnapshot.offerTypoCorrections,
            automaticallyFixTypos: settingsSnapshot.automaticallyFixTypos
        )
        gateSettings.autoApplyMinimumScore = TypoGate.Settings.adaptedAutoApplyMinimumScore(
            autoApplied: qualityMetricsStore.counters.correctionsAutoApplied,
            reverted: qualityMetricsStore.counters.correctionsAutoReverted
        )
        gateSettings.autoApplyMinimumConfidence = autoFixModel.map {
            TypoGate.Settings.adaptedAutoApplyMinimumConfidence(
                base: $0.threshold,
                autoApplied: qualityMetricsStore.counters.correctionsAutoApplied,
                reverted: qualityMetricsStore.counters.correctionsAutoReverted
            )
        }
        return gateSettings
    }

    /// The writer pressed Escape on the spelling bar: leave the word at the caret alone (see `DismissedTypo`).
    func noteSpellingBarDismissed() {
        dismissedTypo = focusModel.snapshot.context.flatMap { DismissedTypo(precedingText: $0.precedingText) }
    }

    /// Does the spelling work for the word at the caret the moment a character is typed, instead of
    /// after the host has published that key. The field will read `precedingText` a few milliseconds
    /// from now; until then the main thread is only waiting, so the dictionary lookups and the system
    /// checker's guesses (up to 15 ms together) run in that gap. `handleTypoGate` picks the prepared
    /// work up if the field then reads exactly this text, and ignores it otherwise, so a wrong guess
    /// about what the key did costs nothing but the wasted lookup.
    @discardableResult
    func prepareTypoGate(precedingText: String, textAfter: String) -> TypoGateDecision? {
        guard settingsSnapshot.suppressCompletionsOnTypo else { return nil }
        let inputs = TypoGateInputs(dependencies: spellingEngineDependencies, precedingText: precedingText, textAfter: textAfter)
        // A bar that is held back takes nothing from the strip, so the strip draws for this key.
        let decision = inputs.decide(settings: typoGateSettings())
        isSpellingPendingForLastKey = decision != .proceed && !holdsBack(decision, precedingText: precedingText)
        preparedTypoGate = PreparedTypoGate(precedingText: precedingText, textAfter: textAfter, inputs: inputs)
        traceTyping("prepared")
        return decision
    }

    /// Types the automatic fix for the word the last key finished from the keys alone, without
    /// waiting for the app to show that key. Called one run-loop turn after the key, and only
    /// for an app that has been slow to show keys (`HostLateness`).
    ///
    /// Why: the other route makes the fix when the field reads the finished word, and a chat app
    /// that is busy takes 150 to 400 ms to show a key, or does not show it before the wait gives
    /// up. The fix then came late, or on top of the writer's next word, or not at all, and to the
    /// writer the spelling check had stopped working because another app was slow.
    ///
    /// Why it is safe to type without that read: the fix is a number of backspaces and the word,
    /// posted as keys after the writer's own, so the app applies it to the text those keys made.
    /// What has to be true is that the keys made the text Cotabby thinks they made, and that is
    /// asked of the word strip's record of the keys, twice: when the work was prepared and again
    /// here, after the key itself was applied. Everything the read-based route checks that does
    /// not need the new text is checked here too.
    func typeFixFromKeys(for text: String, field: UInt64) {
        guard let prepared = preparedTypoGate, prepared.precedingText == text,
              let context = focusModel.snapshot.context, context.focusChangeSequence == field,
              prepared.textAfter == context.trailingText,
              wordPredictionPresenter?.textAfterKeys(typing: "") == text,
              dismissedTypo == nil, pendingCacheReset == nil, SyntheticEventPoster.secondsUntilSettled <= 0,
              interactionState.activeSession == nil,
              currentDisabledReason(focusSnapshot: focusModel.snapshot) == nil else { return }
        // Same order as the other routes: a fix the writer just undid counts as kept before the
        // gate decides about the word again.
        settleAutoFixOutcomes(precedingText: text)
        noticeSelfCorrections(precedingText: text)
        let decision = prepared.inputs.decide(settings: typoGateSettings())
        guard case let .applyCorrection(word, correctedWord) = decision else { return }
        // This text has been looked at; the read that shows it later must not start over.
        typedTextCheck = TypedTextCheck(field: field, pollGeneration: hostPublishPollGeneration, checkedPrecedingText: text)
        lastGatedPrecedingText = text
        preparedTypoGate = nil
        heldSpellingBar?.cancel()
        heldSpellingBar = nil
        traceTyping("decided (from the keys)")
        applyAutomaticCorrection(
            typoWord: word, correctedWord: correctedWord, rawContext: context, workID: currentWorkID, textFromKeys: text
        )
        reportDecision(decision, inputs: prepared.inputs, precedingText: text)
    }

    /// The fast lane for spelling work that was already done at the keypress. Called the moment the
    /// host publishes the key, in the same main-thread turn: a fix is typed, or the bar is shown,
    /// there and then.
    ///
    /// The normal route hands the work to a task, and a task only runs after everything already
    /// queued on the main thread, including the redraw of whatever panel the previous key changed.
    /// Measured live, that queue is usually empty but sometimes holds 30-100 ms of window work,
    /// which is the difference between a fix that lands before the writer's next key and one that
    /// lands on top of it. Anything that is not exactly "the field reads the prepared text and the
    /// word needs a fix or a bar" returns false and takes the normal route, which repeats the checks.
    func handlePreparedTypoGateWithoutQueueing(context: FocusedInputSnapshot?) -> Bool {
        guard let context, let prepared = preparedTypoGate,
              prepared.precedingText == context.precedingText, prepared.textAfter == context.trailingText,
              dismissedTypo == nil, pendingCacheReset == nil, SyntheticEventPoster.secondsUntilSettled <= 0,
              currentDisabledReason(focusSnapshot: focusModel.snapshot) == nil else { return false }
        // Same order as `generateFromCurrentFocus`: a fix the writer just undid must count as kept
        // before the gate looks at the word again. Both calls are no-ops when repeated for the
        // same text, which is what the normal route does if this returns false.
        settleAutoFixOutcomes(precedingText: context.precedingText)
        noticeSelfCorrections(precedingText: context.precedingText)
        let decision = prepared.inputs.decide(settings: typoGateSettings())
        // Asked last, because asking records this text as looked at. The normal route asks again
        // for the same text when this lane stands down, and gets the same answer. A bar that is
        // held back is nothing to hurry: it goes the normal route, which takes the prepared work.
        guard decision != .proceed, !holdsBack(decision, precedingText: context.precedingText),
              claimTypedText(in: context) else { return false }
        lastGatedPrecedingText = context.precedingText
        preparedTypoGate = nil
        traceTyping("decided (fast lane)")
        return carryOut(decision, inputs: prepared.inputs, rawContext: context, workID: currentWorkID)
    }

    private func takePreparedTypoGate(precedingText: String, textAfter: String) -> TypoGateInputs? {
        defer { preparedTypoGate = nil }
        guard let prepared = preparedTypoGate, prepared.precedingText == precedingText, prepared.textAfter == textAfter else {
            traceTyping(preparedTypoGate == nil ? "nothing prepared" : "prepared for other text")
            return nil
        }
        return prepared.inputs
    }

    /// Runs the typo gate for the current word. Returns `true` when it handled the cycle by suppressing,
    /// offering, or applying a correction; `false` proceeds with a normal continuation. Kept separate
    /// so `generateFromCurrentFocus` stays within the project's cyclomatic-complexity budget.
    private func handleTypoGate(rawContext: FocusedInputSnapshot, workID: UInt64) -> Bool {
        lastGatedPrecedingText = rawContext.precedingText
        if let dismissed = dismissedTypo {
            if dismissed.covers(precedingText: rawContext.precedingText) {
                // Escape on the bar: no bar and no fix for this word, as if it were spelled right.
                preparedTypoGate = nil
                candidateOfferPresenter?.dismissChoices()
                noteTextForWordStrip(rawContext)
                return false
            }
            dismissedTypo = nil
        }
        let inputs = takePreparedTypoGate(precedingText: rawContext.precedingText, textAfter: rawContext.trailingText)
            ?? TypoGateInputs(
                dependencies: spellingEngineDependencies,
                precedingText: rawContext.precedingText,
                textAfter: rawContext.trailingText
            )
        let decision = inputs.decide(settings: typoGateSettings())
        traceTyping("decided")
        return carryOut(decision, inputs: inputs, rawContext: rawContext, workID: workID)
    }

    /// Acts on the gate's decision; returns true when the word is now owned by a fix, the bar, or a
    /// suppression, so no continuation is generated for it.
    private func carryOut(
        _ decision: TypoGateDecision,
        inputs: TypoGateInputs,
        rawContext: FocusedInputSnapshot,
        workID: UInt64
    ) -> Bool {
        // Whatever was decided for the text before this one is out of date.
        heldSpellingBar?.cancel()
        heldSpellingBar = nil
        if case let .applyCorrection(word, correctedWord) = decision {
            // The fix for this word in this place was already typed and the app has not shown
            // it yet: this read is the text from before it (`AutoFixOutcomeTracker.isAwaitingFix`).
            guard !autoFixOutcomes.isAwaitingFix(in: rawContext.precedingText, field: rawContext.focusChangeSequence) else {
                return true
            }
            defer { reportDecision(decision, inputs: inputs, precedingText: rawContext.precedingText) }
            // Nothing may sit between the decision and the keys that type the fix: closing the word
            // strip or the spelling bar is panel work that has measured 50-140 ms on a busy main
            // thread, long enough for the writer's next key to land first. The fix goes out, then
            // `applyAutomaticCorrection` closes the panels.
            applyAutomaticCorrection(typoWord: word, correctedWord: correctedWord, rawContext: rawContext, workID: workID)
            return true
        }
        if holdsBack(decision, precedingText: rawContext.precedingText) {
            // The word is unfinished and the writer may be in the middle of typing it: the strip
            // keeps the word, and the bar comes only if they stop (`holdSpellingBar`).
            candidateOfferPresenter?.dismissChoices()
            noteTextForWordStrip(rawContext)
            holdSpellingBar(decision, inputs: inputs, rawContext: rawContext)
            return false
        }
        if decision == .proceed {
            candidateOfferPresenter?.dismissChoices()
            noteTextForWordStrip(rawContext)
            return false
        }
        return present(decision, inputs: inputs, rawContext: rawContext, workID: workID)
    }

    /// True for a decision about an unfinished word that puts the spelling bar up (or flags the
    /// word with nothing to offer) while the word strip is on. Such a bar is not shown at once.
    ///
    /// Why: the gate judges the word on every key, so from the first slipped letter each key drew
    /// a bar, and each bar took the strip down. On one recorded day of real typing that was 1,173
    /// bars, two in three with another first word than the one before, seven in ten replaced
    /// within 200 ms, and in 88 of 201 automatic fixes a bar stood for 76 ms on the last letter
    /// before the fix at the space removed it. Nobody reads a panel that fast (a bar was acted on
    /// after a second, never under 200 ms), and to the writer it was the strip vanishing as they
    /// typed. Meanwhile the strip, which forgives a slip in the letters typed, held the intended
    /// word more often than those bars did.
    ///
    /// So inside a word the strip stays, and the bar waits for a pause. A finished word is
    /// decided at once, as before: that is where fixes are made.
    ///
    /// Only with the strip on. Without it the old rule stands, because there the bar is all the
    /// help there is, and ghost text must not continue a misspelled word.
    private func holdsBack(_ decision: TypoGateDecision, precedingText: String) -> Bool {
        guard wordPredictionPresenter?.replacesGhostText == true else { return false }
        switch decision {
        case .proceed, .applyCorrection, .offerRealWordFix:
            return false
        case .suppress, .offerCorrection, .offerRankedCorrection, .offerChoices:
            return TypoGate.isMidWord(precedingText)
        }
    }

    /// Shows the bar for an unfinished word once the writer has stopped for `midWordBarHoldSeconds`
    /// with the field still as it was judged. The next key cancels it (`handleInputEvent`), and
    /// so does any newer decision (`carryOut`). A word flagged with nothing to offer shows nothing
    /// later either; it only no longer costs the strip.
    private func holdSpellingBar(_ decision: TypoGateDecision, inputs: TypoGateInputs, rawContext: FocusedInputSnapshot) {
        guard decision != .suppress else { return }
        let held = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.heldSpellingBar = nil
            guard let context = self.focusModel.snapshot.context,
                  context.precedingText == rawContext.precedingText, context.trailingText == rawContext.trailingText,
                  self.dismissedTypo == nil, SyntheticEventPoster.secondsUntilSettled <= 0,
                  self.currentDisabledReason(focusSnapshot: self.focusModel.snapshot) == nil else { return }
            // The strip already lists this fix, one Tab or Option+digit away. Swapping it for a
            // bar that says the same, and back again at the next letter, is the flicker a
            // writer who pauses inside a word used to get on every pause.
            if let fix = Self.firstFix(in: decision), self.wordPredictionPresenter?.isOffering(fix) == true { return }
            _ = self.present(decision, inputs: inputs, rawContext: context, workID: self.currentWorkID)
        }
        heldSpellingBar = held
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.midWordBarHoldSeconds, execute: held)
    }

    /// The word a decision would put first in the spelling bar, when it offers one.
    private static func firstFix(in decision: TypoGateDecision) -> String? {
        switch decision {
        case let .offerCorrection(_, correctedWord):
            return correctedWord
        case let .offerRankedCorrection(_, candidates), let .offerChoices(_, candidates), let .offerRealWordFix(_, candidates):
            return candidates.first?.term
        case .proceed, .suppress, .applyCorrection:
            return nil
        }
    }

    /// Hands the word to the spelling bar (or holds a flagged word with nothing to offer): the
    /// strip steps aside, the record is told, and the bar is drawn. True, because the word is now
    /// owned and no continuation is generated for it.
    private func present(
        _ decision: TypoGateDecision,
        inputs: TypoGateInputs,
        rawContext: FocusedInputSnapshot,
        workID: UInt64
    ) -> Bool {
        // The spelling bar or a suppressed typo owns this word; predictions wait.
        wordPredictionPresenter?.hidePredictions()
        reportDecision(decision, inputs: inputs, precedingText: rawContext.precedingText)

        switch decision {
        case .proceed:
            return false
        case .suppress:
            candidateOfferPresenter?.dismissChoices()
            clearSuggestion()
            hideOverlay(reason: "Overlay hidden because the current word looks misspelled.")
            state = .idle
            logStage(
                "typo-suppressed",
                workID: workID,
                message: "Skipped generation because the current word looks misspelled."
            )
            return true
        case let .offerCorrection(word, correctedWord):
            presentSpellingBar(
                typo: word,
                candidates: [SpellingCandidate(term: correctedWord, score: 1)],
                inputs: inputs,
                rawContext: rawContext,
                workID: workID
            )
            return true
        case let .offerRankedCorrection(word, candidates), let .offerChoices(word, candidates):
            presentSpellingBar(typo: word, candidates: candidates, inputs: inputs, rawContext: rawContext, workID: workID)
            return true
        case let .offerRealWordFix(word, candidates):
            presentSpellingBar(
                typo: word,
                candidates: candidates,
                inputs: inputs,
                rawContext: rawContext,
                workID: workID,
                keepKey: inputs.realWordKeepKey(for: word)
            )
            return true
        case .applyCorrection:
            // Handled above, before any panel work.
            return true
        }
    }

    /// Tells the training record what was decided about the word and on what evidence. Does nothing
    /// (not even the lookups) when nobody listens. For a fix typed without asking it runs after the
    /// fix's keys have gone out (see `carryOut`), so the record never delays a fix.
    private func reportDecision(_ decision: TypoGateDecision, inputs: TypoGateInputs, precedingText: String) {
        guard let onSpellingDecision else { return }
        let typed: String
        let action: String
        var offered: [SpellingCandidate] = []
        switch decision {
        case .proceed:
            return
        case .suppress:
            guard let word = CurrentWordExtractor.extractTrailingWord(from: precedingText)?.result.word else { return }
            (typed, action) = (word, "held")
        case let .applyCorrection(word, correctedWord):
            (typed, action) = (word, "fixed")
            offered = [SpellingCandidate(term: correctedWord, score: 1)]
        case let .offerCorrection(word, correctedWord):
            (typed, action) = (word, "offered")
            offered = [SpellingCandidate(term: correctedWord, score: 1)]
        case let .offerRankedCorrection(word, candidates):
            (typed, action, offered) = (word, "offered", candidates)
        case let .offerChoices(word, candidates):
            (typed, action, offered) = (word, "offeredChoices", candidates)
        case let .offerRealWordFix(word, candidates):
            (typed, action, offered) = (word, "offeredWrongWord", candidates)
        }
        // The ranked list behind the decision says more than the decision: the runners-up and
        // their scores. It is there for a finished word; mid-word only the offer itself is.
        let ranked = inputs.rankedCandidates(forFinishedWord: typed).map(\.candidate)
        let candidates = (ranked.isEmpty ? offered : ranked).prefix(SpellingDecisionRecord.maximumCandidates)
        let before = CurrentWordExtractor.textBeforeTrailingWord(in: precedingText) ?? ""
        onSpellingDecision(SpellingDecisionRecord(
            typed: typed, action: action,
            candidates: candidates.map { .init(term: $0.term, score: ($0.score * 1000).rounded() / 1000) },
            confidence: inputs.autoFixConfidence(typed).map { ($0 * 1000).rounded() / 1000 },
            before: StripUseTracker.sentenceSoFar(before)
        ))
    }

    /// Called by the host-publish wait when the field shows what a key did: from here the spelling
    /// stages may take one look at this field (see `TypedTextCheck`). No field at the key (`nil`)
    /// means there is no telling where the key went, so nothing is handed over.
    func noteTypedTextPublished(inField field: UInt64?, pollGeneration: UInt64) {
        typedTextCheck = field.map { TypedTextCheck(field: $0, pollGeneration: pollGeneration) }
    }

    /// Whether the spelling stages may look at `context`, asked by both routes into them (the fast
    /// lane and `runSpellingStages`). Yes in two cases, both in the field the key went to:
    /// a key's text was published and has not been looked at yet, or the field still reads
    /// exactly the text that was looked at after a key. Every other prediction (screen text
    /// became ready, a setting changed, the caret was clicked somewhere else) finds text nobody
    /// just typed and gets no.
    ///
    /// A yes for a first look records the text, so the question can be asked again for it.
    private func claimTypedText(in context: FocusedInputSnapshot) -> Bool {
        guard var check = typedTextCheck, check.field == context.focusChangeSequence else { return false }
        if let checkedPrecedingText = check.checkedPrecedingText {
            return checkedPrecedingText == context.precedingText
        }
        // A first look belongs to the wait that published the key. If that wait's work was
        // cancelled since (the field got disabled, a panel took over, focus left the app), the
        // caret may be anywhere by now.
        guard check.pollGeneration == hostPublishPollGeneration else { return false }
        check.checkedPrecedingText = context.precedingText
        typedTextCheck = check
        return true
    }

    /// The typo gate for the word at the caret, then the sentence pass. True when the gate took
    /// the turn (it fixed or offered something), so no continuation is generated. Skipped
    /// entirely unless a key of the writer put this text in this field (see `TypedTextCheck`).
    private func runSpellingStages(rawContext: FocusedInputSnapshot, workID: UInt64) -> Bool {
        guard claimTypedText(in: rawContext) else { return false }
        if handleTypoGate(rawContext: rawContext, workID: workID) {
            return true
        }
        // After the gate, so a sentence rewrite never races an edit the gate just made to the last word.
        sentenceFixPresenter?.noteTypedText(
            rawContext.precedingText,
            caretRect: rawContext.caretRect,
            focusChangeSequence: rawContext.focusChangeSequence
        )
        return false
    }

    /// Learns from the writer going back and retyping a misspelled word: the pair is recorded as an
    /// accepted fix, so after a couple of times Cotabby makes it on its own. Edits Cotabby itself
    /// just made are excluded by resetting the detector while its own keys are landing.
    private func noticeSelfCorrections(precedingText: String) {
        if SyntheticEventPoster.secondsSinceDrained < Self.ownEditQuietSeconds {
            selfCorrections.reset()
        }
        let corrector = symSpellCorrector
        guard let correction = selfCorrections.observe(precedingText, isPlausible: { typed, corrected in
            SelfCorrectionDetector.isPlausibleFix(typed: typed, corrected: corrected) { corrector.isDictionaryWord($0) }
        }) else { return }
        personalCorrectionMemory?.recordAccepted(typo: correction.typed, replacement: correction.corrected)
        correctionJournal?.record(.selfCorrected, typed: correction.typed, final: correction.corrected)
        CotabbyLogger.suggestion.debug("Learned a self-correction: \(correction.typed) -> \(correction.corrected)")
    }

    /// Feeds the word strip unless another Cotabby card owns the caret; two panels would stack.
    func noteTextForWordStrip(_ context: FocusedInputSnapshot) {
        guard !isInlinePanelOwningKeys else {
            wordPredictionPresenter?.hidePredictions()
            return
        }
        wordPredictionPresenter?.noteTypedText(
            context.precedingText,
            caretRect: context.caretRect,
            focusChangeSequence: context.focusChangeSequence
        )
    }

    /// Teaches the personal history from how the writer reacted to earlier auto-fixes: a fix they
    /// typed past is recorded as accepted, one they undid marks the typed word as intended so it is
    /// never auto-fixed again.
    private func settleAutoFixOutcomes(precedingText: String) {
        for outcome in autoFixOutcomes.observe(precedingText, field: focusModel.snapshot.context?.focusChangeSequence ?? 0) {
            switch outcome.kind {
            case .confirmed:
                personalCorrectionMemory?.recordAccepted(typo: outcome.typo, replacement: outcome.fix)
                correctionJournal?.record(.autoFixKept, typed: outcome.typo, final: outcome.fix)
            case .reverted:
                // A habit is taken down a step; anything else was a guess, and the word is kept.
                if personalCorrectionMemory?.demoteHabit(typo: outcome.typo, fix: outcome.fix) != true {
                    personalCorrectionMemory?.recordKept(outcome.typo)
                }
                qualityMetricsStore.recordCorrectionReverted()
                correctionJournal?.record(.autoFixUndone, typed: outcome.typo, final: outcome.typo, offered: outcome.fix)
            case .replaced:
                noteReplacedAutoFix(outcome)
            }
            CotabbyLogger.suggestion.debug("Auto-fix \(outcome.typo) -> \(outcome.fix) \(outcome.kind)")
        }
    }

    /// The writer changed an automatic fix into a third word. That is a wrong fix whichever
    /// word it is, and it counts as one. It teaches the right word only when the third word could
    /// be what the slip was meant as (the same test as for a word the writer retypes themselves):
    /// someone who deletes `the` to write `however` was rewording, not correcting.
    private func noteReplacedAutoFix(_ outcome: AutoFixOutcome) {
        guard let meant = outcome.replacement else { return }
        qualityMetricsStore.recordCorrectionReverted()
        personalCorrectionMemory?.demoteHabit(typo: outcome.typo, fix: outcome.fix)
        let corrector = symSpellCorrector
        let isCorrection = SelfCorrectionDetector.isPlausibleFix(typed: outcome.typo, corrected: meant) {
            corrector.isDictionaryWord($0)
        }
        guard isCorrection else { return }
        personalCorrectionMemory?.recordAccepted(typo: outcome.typo, replacement: meant)
        correctionJournal?.record(.autoFixReplaced, typed: outcome.typo, final: meant, offered: outcome.fix)
    }

    var spellingEngineDependencies: SpellingEngineDependencies {
        SpellingEngineDependencies(
            spellChecker: spellChecker,
            symSpellCorrector: symSpellCorrector,
            languageResolver: spellingLanguageResolver,
            enabledLanguages: { [settingsSnapshot] in
                SpellingDictionaryCatalog.languages(for: settingsSnapshot.enabledSpellingDictionaryCodes)
            },
            memory: personalCorrectionMemory,
            bigrams: bigramContextModel,
            refiner: wordIntentRefiner,
            personalPairCount: personalPhraseModel.map { phrases in
                { phrases.pairCount(first: $0, second: $1) }
            },
            sentenceContextScore: nextWordModel.map { model in
                { NextWordPredictor.contextScore(of: $1, after: $0, model: model) }
            },
            personalWords: personalVocabulary.map { vocabulary in { vocabulary.matches(for: $0) } },
            autoFixModel: autoFixModel,
            keyboardFixModel: keyboardFixModel,
            wrongWordModel: wrongWordModel,
            americanSpellings: americanSpellings,
            technicalTerms: technicalTerms,
            // The strip's own lookup: a listed term's capitals (`api` is API), else the writer's.
            usualCasing: { [technicalCapitals, personalVocabulary] word in
                technicalCapitals[word] ?? personalVocabulary?.preferredCasing(of: word)
            }
        )
    }

    /// The words of `sentence` (lowercased) that must not be learned as the writer's, because the
    /// local proofreader would offer to change them; nil when it would change the sentence on its
    /// own, which means this is not the text the writer ends up with.
    func wordsNotToLearn(in sentence: String) -> Set<String>? {
        let result = proofreadLocally(FinishedSentence(sentence: sentence + ".", trailingWhitespace: " ", precedingContext: ""))
        guard !result.hasAutoFixes else { return nil }
        return Set(result.flags.map { $0.typed.lowercased() })
    }

    /// The words of a line the writer finished that Cotabby flags as misspelled and is not sure
    /// how to fix: candidates for being the writer's own words (`PersonalCorrectionMemory
    /// .recordLeftStanding`). Each word once, as written.
    ///
    /// Left out: words inside paths, identifiers and other joined tokens, the certain
    /// misspellings (`teh`, `dont`), and a word the engine has a confident fix for. Such a word
    /// standing in a finished line is a slip that got through, not a word to learn; only where
    /// the engine itself has no good answer does "the writer keeps writing it" count for more.
    func wordsLeftStanding(in sentence: String) -> [String] {
        TypoGateInputs.wordsLeftStanding(in: sentence, dependencies: spellingEngineDependencies, settings: typoGateSettings())
    }

    /// The instant on-device proofread of a finished sentence (see `LocalSentenceProofreader`).
    func proofreadLocally(_ finished: FinishedSentence) -> LocalProofreadResult {
        LocalSentenceProofreader.proofread(finished.sentence, checks: sentenceChecks)
    }

    /// What the sentence model's answer means for a finished sentence: which of its changed words to
    /// type in place and which to offer for review (see `SentenceModelGate`). A word the dictionary
    /// or the writer's own vocabulary knows needs a surer model before it is replaced.
    func proofread(_ finished: FinishedSentence, modelOutput: SentenceModelOutput) -> LocalProofreadResult? {
        let isTypo = sentenceChecks.isTypo
        // Left as typed: a word the writer kept when a fix was offered or undid a fix of (their
        // explicit answer), and a term of the bundled technical vocabulary, which is spelled right
        // by definition and which a model trained on general text likes to turn into an everyday
        // word. The learned vocabulary is not on this list: it can hold a misspelling the writer
        // never noticed, and that must stay fixable.
        let memory = personalCorrectionMemory, vocabulary = personalVocabulary, corrector = symSpellCorrector
        let technical = technicalTerms
        let isWritersOwn: (String) -> Bool = { memory?.isKept($0) == true || technical.contains($0.lowercased()) }
        let words = SentenceModelGate.WordChecks(
            isInDictionary: { corrector.isDictionaryWord($0.lowercased()) || vocabulary?.preferredCasing(of: $0) != nil },
            isWritersOwn: isWritersOwn
        )
        if let onSentencePass {
            onSentencePass(
                finished.sentence,
                SentenceModelGate.judgments(typed: finished.sentence, output: modelOutput, isKnownWord: { !isTypo($0) }, words: words)
            )
        }
        return SentenceModelGate.result(typed: finished.sentence, output: modelOutput, isKnownWord: { !isTypo($0) }, words: words)
    }

    private var sentenceChecks: LocalSentenceProofreader.Checks {
        TypoGateInputs.sentenceChecks(
            dependencies: spellingEngineDependencies,
            settings: TypoGate.Settings(
                suppressCompletionsOnTypo: true,
                offerTypoCorrections: settingsSnapshot.offerTypoCorrections,
                automaticallyFixTypos: settingsSnapshot.automaticallyFixTypos,
                autoApplyMinimumConfidence: autoFixModel?.threshold
            )
        )
    }

    /// Shows the iPhone-style bar (`"typed"` | best | runner-up) and, when the local evidence was
    /// not decisive, asks Jev to reorder it from the sentence's meaning.
    private func presentSpellingBar(
        typo: String,
        candidates: [SpellingCandidate],
        inputs: TypoGateInputs,
        rawContext: FocusedInputSnapshot,
        workID: UInt64,
        keepKey: String? = nil
    ) {
        cancelPredictionWork()
        clearSuggestion()
        hideOverlay(reason: "Overlay hidden while the spelling bar is open.")
        state = .idle
        // Three fixes: in the end-to-end writer simulation (`cotabby-spell --writer`) a third slot left
        // 8% fewer misspellings in the text than two, and a fourth added almost nothing.
        let fixes = candidates.filter { $0.term != typo }.prefix(3)
        var offer = CandidateOffer(
            source: .spelling(typo: typo),
            candidates: [typo] + fixes.map(\.term),
            scores: [0] + fixes.map { min(max($0.score, 0), 1) },
            caretRect: rawContext.caretRect,
            focusChangeSequence: rawContext.focusChangeSequence
        )
        offer.preferredIndex = fixes.isEmpty ? 0 : 1
        offer.keepKey = keepKey
        offer.isContextRefined = inputs.usedJevVerdict
        candidateOfferPresenter?.presentChoices(offer)
        traceTyping("bar shown")
        if !inputs.usedJevVerdict {
            inputs.requestJevVerdict(typo: typo, candidates: candidates, includesTypedWord: keepKey != nil)
        }
        logStage(
            "typo-bar-ready",
            workID: workID,
            message: "Offered \(fixes.count) spelling fixes\(inputs.usedJevVerdict ? " ordered by Jev" : "") "
                + "\(Self.elapsedMilliseconds(since: lastTypingKeystrokeUptimeNanoseconds)) ms after the key.",
            normalizedOutput: fixes.map(\.term).joined(separator: " | ")
        )
    }

    /// Collapses native typo detection and correction availability into the seam guard's single
    /// spelling contract. Keeping this adapter at the orchestration boundary lets the pure guard
    /// express its policy without knowing about `NSSpellChecker` or accepting contradictory hooks.
    private func completionSpellingAssessment(
        for word: String
    ) -> CompletionSeamGuard.SpellingAssessment {
        guard spellChecker.isTypo(word) else {
            return .known
        }
        return spellChecker.bestCorrection(for: word) == nil
            ? .uncorrectableTypo
            : .correctableTypo
    }

    /// Replaces a completed typo after Space without creating a visible correction session.
    ///
    /// Automatic mutation is intentionally limited to a committed word boundary. The shared planner
    /// revalidates the exact trailing word and requires that Space to still be present, so a stale AX
    /// snapshot or a user who resumed typing cannot make Cotabby delete an unrelated suffix.
    /// An automatic fix owns the word, so the word strip and any spelling bar for it go away.
    private func closePanelsForAutomaticCorrection() {
        wordPredictionPresenter?.hidePredictions()
        candidateOfferPresenter?.dismissChoices()
        traceTyping("panels closed")
    }

    private func applyAutomaticCorrection(
        typoWord: String,
        correctedWord: String,
        rawContext: FocusedInputSnapshot,
        workID: UInt64,
        textFromKeys: String? = nil
    ) {
        let liveContext = interactionState.materializeContext(from: rawContext)
        latestGenerationNumber = liveContext.generation
        // Re-read before editing when the capture is not fresh: the host (or macOS's own autocorrect)
        // may have changed the word since a debounced snapshot, and backspacing over a different word
        // would garble the text. A capture taken milliseconds ago for this same cycle is reused; a
        // second walk would only delay the fix past the writer's next key.
        // A fix made from the keys (`typeFixFromKeys`) has no read to wait for: the field is
        // behind, and the text is the one the keys left.
        traceTyping("fix chosen")
        let livePrecedingText: String
        if let textFromKeys {
            livePrecedingText = textFromKeys
        } else {
            focusModel.refreshIfStale(maxAgeMilliseconds: Self.freshSnapshotReuseWindowMilliseconds)
            livePrecedingText = focusModel.snapshot.context.map { current in
                current.focusChangeSequence == rawContext.focusChangeSequence ? current.precedingText : ""
            } ?? rawContext.precedingText
        }
        guard let replacement = TypoCorrectionReplacementPlanner.plan(
            precedingText: livePrecedingText,
            expectedTypo: typoWord,
            correctedWord: correctedWord,
            requiresTrailingSpace: true
        ) else {
            closePanelsForAutomaticCorrection()
            clearSuggestion()
            hideOverlay(reason: "Overlay hidden because the automatic correction target changed.")
            state = .idle
            logStage(
                "typo-auto-correction-stale",
                workID: workID,
                generation: liveContext.generation,
                message: "Skipped automatic correction because the completed word no longer matched."
            )
            return
        }

        guard suggestionInserter.replace(
            deletingUTF16Count: replacement.backspaceCount,
            with: replacement.replacementText
        ) else {
            let message = suggestionInserter.lastErrorMessage ?? "Automatic correction insertion failed."
            closePanelsForAutomaticCorrection()
            cancelPredictionWork()
            clearSuggestion(clearDiagnostics: true)
            hideOverlay(reason: "Overlay hidden because automatic correction insertion failed.")
            state = .idle
            logStage(
                "typo-auto-correction-failed",
                workID: workID,
                generation: liveContext.generation,
                message: message,
                normalizedOutput: correctedWord
            )
            return
        }

        let fixedAfterMilliseconds = Self.elapsedMilliseconds(since: lastTypingKeystrokeUptimeNanoseconds)
        traceTyping("fix typed")
        // The strip's record of the keys moves on to the fixed text, so the word from before
        // the fix, when a slow app reports it afterwards, is known for what it is.
        let kept = String(decoding: Array(livePrecedingText.utf16.dropLast(replacement.backspaceCount)), as: UTF16.self)
        wordPredictionPresenter?.noteFixTyped(leaving: kept + replacement.replacementText)
        // After the keys, and before the flash below: the flash is skipped while the bar is up.
        closePanelsForAutomaticCorrection()
        focusModel.invalidateTransientCaretCaches()
        cancelPredictionWork()
        clearSuggestion(clearDiagnostics: false)
        hideOverlay(reason: "Overlay hidden because Cotabby automatically fixed a typo.")
        state = .idle
        autoFixOutcomes.noteAutoFix(
            typo: typoWord, fix: correctedWord, precedingText: livePrecedingText,
            field: focusModel.snapshot.context?.focusChangeSequence ?? 0
        )
        qualityMetricsStore.recordCorrectionAutoApplied()
        candidateOfferPresenter?.flashAutoCorrection(
            typo: typoWord,
            correction: correctedWord,
            caretRect: liveContext.caretRect
        )
        logStage(
            "typo-auto-corrected",
            workID: workID,
            generation: liveContext.generation,
            message: "Automatically replaced the completed misspelled word \(fixedAfterMilliseconds) ms after the key.",
            normalizedOutput: correctedWord
        )
        // Synthetic replacement is asynchronous from the host editor's perspective. Poll until AX
        // publishes the corrected text before asking for the next continuation.
        schedulePredictionAfterHostPublishDelay()
    }

    /// Presents a native spell-checker correction as a replace-the-word suggestion, with no model
    /// generation. The session carries `.correction(typoWord:)` so the acceptance
    /// path swaps the typo for the fix, and the overlay renders green so the user can tell at a
    /// glance that accepting replaces their last word rather than extending it.
    private func presentCorrection(
        typoWord: String,
        correctedWord: String,
        rawContext: FocusedInputSnapshot,
        workID: UInt64
    ) {
        let liveContext = interactionState.materializeContext(from: rawContext)
        latestGenerationNumber = liveContext.generation
        let session = interactionState.startSession(
            fullText: correctedWord,
            liveContext: liveContext,
            latency: 0,
            kind: .correction(typoWord: typoWord)
        )
        state = .ready(text: session.remainingText, latency: 0)
        presentOverlay(
            text: session.remainingText,
            at: liveContext.caretRect,
            context: liveContext,
            isRightToLeft: TextDirectionDetector.isRightToLeft(liveContext.precedingText),
            isCorrection: true
        )
        logStage(
            "typo-correction-ready",
            workID: workID,
            generation: liveContext.generation,
            message: "Offered a native spell-checker correction for the current word.",
            normalizedOutput: correctedWord
        )
    }

    /// Empty-result bookkeeping for `apply`, extracted to keep that function inside the
    /// complexity budget as its guard chain grew.
    private func discardEmptyResult(_ result: SuggestionResult, workID: UInt64) {
        clearSuggestion()
        hideOverlay(reason: "Overlay hidden because the model returned an empty continuation.")
        state = .idle
        // The router already counted engine-attributed suppressions (normalizer, confidence
        // floor); only the unattributed "model produced nothing" case needs a ledger entry.
        if result.suppressionReason == nil {
            qualityMetricsStore.recordSuppressed(reason: "emptyUnattributed")
        }
        logStage(
            "empty-result",
            workID: workID,
            generation: result.generation,
            message: "Model returned an empty or whitespace-only continuation after normalization.",
            rawOutput: result.rawText,
            normalizedOutput: result.text
        )
    }

    private static func seamSuppressionReason(for verdict: CompletionSeamGuard.Verdict) -> String {
        switch verdict {
        case .seamMisspelling:
            return "seamMisspelling"
        case .leadingWordMisspelling:
            return "leadingWordMisspelling"
        case .junkPunctuationRun:
            return "seamJunkPunctuationRun"
        case .allow:
            return "unknownSeamGuardSuppression"
        }
    }

    /// Promotes a generated result to `ready` only when it is still fresh for the current field.
    func apply(result: SuggestionResult, workID: UInt64) async {

        // A suggestion that lands while a Cotabby panel owns Tab would give Tab two meanings.
        guard workController.isCurrent(workID), !isInlinePanelOwningKeys else {

            return
        }

        // Record every completed result, including output later suppressed by normalization or seam
        // checks. Those requests still consumed backend time and are exactly the evidence the next
        // debounce needs to avoid another burst of doomed HTTP work.
        lastLatencyByEngine[settingsSnapshot.selectedEngine] =
            Int((result.latency * 1_000).rounded())

        // The free-running focus poll keeps capturing while the engine generates, so a fresh
        // capture often already exists here; only pay a synchronous AX walk when it does not.
        // Any keystroke during generation bumped the work id (checked above), and non-keyboard
        // edits are caught by the generation guard below on the materialized context.
        focusModel.refreshIfStale(maxAgeMilliseconds: Self.freshSnapshotReuseWindowMilliseconds)
        let snapshot = focusModel.snapshot

        if let disabledReason = currentDisabledReason(focusSnapshot: snapshot) {

            disablePredictions(reason: disabledReason)
            return
        }

        guard let rawContext = snapshot.context else {

            disablePredictions(reason: snapshot.capability.summary)
            return
        }

        let liveContext = interactionState.materializeContext(from: rawContext)

        // Consume the tail recorded by a final-chunk accept. It gets exactly one shot to be
        // recognized as a stale echo on the regeneration scheduled right after acceptance.
        let pendingAcceptedTail = lastAcceptedTail
        lastAcceptedTail = nil

        // Generation numbers are our stale-result guard. If the text changed while the model was
        // thinking, we drop the answer instead of showing a suggestion for old content. One
        // exception: a speculative post-acceptance generation was built against text the host had
        // not published yet, so its generation predates the live one by construction. When the
        // live content now matches the signature the speculation was built against, the bet paid
        // off and the result is exactly current.
        let isPaidOffSpeculation = pendingSpeculativeSignature != nil
            && pendingSpeculativeSignature == liveContext.contentSignature
        if isPaidOffSpeculation {
            pendingSpeculativeSignature = nil
        }

        guard isPaidOffSpeculation || liveContext.generation == result.generation else {

            // Lifecycle discards are counted under their own reasons so `generated` always equals
            // `shown` plus the suppression histogram; without this, every drop here silently
            // inflated the generated count against the others.
            qualityMetricsStore.recordSuppressed(reason: "discardedStaleContext")
            logStage(
                "stale-drop",
                workID: workID,
                generation: result.generation,
                message: "Dropped stale result because live generation is \(liveContext.generation).",
                rawOutput: result.rawText,
                normalizedOutput: result.text
            )
            hideOverlay(reason: "Overlay hidden because a stale result was dropped.")
            return
        }

        guard !result.text.isEmpty else {
            discardEmptyResult(result, workID: workID)
            return
        }

        guard liveContext.selection.length == 0 else {
            clearSuggestion(clearDiagnostics: true)
            hideOverlay(reason: "Overlay hidden because text is selected.")
            state = .idle
            qualityMetricsStore.recordSuppressed(reason: "discardedSelection")
            logStage(
                "selected-text",
                workID: workID,
                generation: result.generation,
                message: "Ignored the suggestion because the current field has selected text.",
                rawOutput: result.rawText,
                normalizedOutput: result.text
            )
            return
        }

        // A regeneration that only re-proposes the just-accepted tail while the field still shows the
        // pre-acceptance text means our insert has not published yet. Drop it so the next accept can't
        // re-insert the same word and spin the final-word loop.
        if let pendingAcceptedTail,
           SuggestionSessionReconciler.isStaleAcceptanceEcho(
               resultText: result.text,
               acceptedChunk: pendingAcceptedTail.text,
               currentPrecedingText: liveContext.precedingText,
               acceptedPrecedingText: pendingAcceptedTail.precedingText
           ) {
            clearSuggestion(clearDiagnostics: false)
            hideOverlay(reason: "Overlay hidden because the regeneration only echoed the just-accepted text before the host published it.")
            state = .idle
            qualityMetricsStore.recordSuppressed(reason: "discardedAcceptEcho")
            logStage(
                "stale-accept-echo",
                workID: workID,
                generation: result.generation,
                message: "Dropped a regeneration that re-proposed the just-accepted tail before the host published the insert.",
                rawOutput: result.rawText,
                normalizedOutput: result.text
            )
            return
        }

        // Last line of defense before display: junk punctuation runs, mid-word splices, and newly
        // started words that the native checker can actually correct read as glitches, so showing
        // nothing beats showing them. The leading-word check is intentionally fail-open for names
        // and jargon with no correction candidate.
        let seamVerdict = CompletionSeamGuard.verdict(
            precedingText: liveContext.precedingText,
            completion: result.text,
            spellingAssessment: { self.completionSpellingAssessment(for: $0) }
        )
        if seamVerdict != .allow {
            clearSuggestion()
            hideOverlay(reason: "Overlay hidden because the completion failed the seam guard.")
            state = .idle
            qualityMetricsStore.recordSuppressed(reason: Self.seamSuppressionReason(for: seamVerdict))
            logStage(
                "seam-suppressed",
                workID: workID,
                generation: result.generation,
                message: "Suppressed completion at the caret seam: \(seamVerdict).",
                rawOutput: result.rawText,
                normalizedOutput: result.text
            )
            return
        }

        latestGenerationNumber = liveContext.generation
        // One shown event per suggestion: this is the only place a fresh generation becomes
        // visible (re-presentations after partial accepts reuse the same session).
        qualityMetricsStore.recordShown()
        suggestionAnchorCache.record(
            identityKey: liveContext.focusedInputIdentityKey,
            precedingText: liveContext.precedingText,
            fullText: result.text
        )
        let session = interactionState.startSession(
            fullText: result.text,
            liveContext: liveContext,
            latency: result.latency
        )
        state = .ready(text: session.remainingText, latency: session.latency)

        presentOverlay(
            text: session.remainingText,
            at: liveContext.caretRect,
            context: liveContext,
            isRightToLeft: TextDirectionDetector.isRightToLeft(liveContext.precedingText)
        )
        if !result.alternates.isEmpty {
            candidateOfferPresenter?.armChoices(CandidateOffer(
                source: .continuation,
                candidates: [result.text] + result.alternates,
                scores: [],
                caretRect: liveContext.caretRect,
                focusChangeSequence: liveContext.focusChangeSequence
            ))
        }
        logStage(
            "ready",
            workID: workID,
            generation: result.generation,
            message: "Accepted a non-empty normalized suggestion.",
            rawOutput: result.rawText,
            normalizedOutput: result.text
        )

        // If the user pressed Tab while this continuation was still regenerating, accept its first
        // word now so rapid Tabbing keeps inserting words across the exhaustion boundary instead of
        // stalling once the previous suggestion ran out. No-op when nothing was queued.
        flushQueuedPostExhaustionAcceptIfNeeded()
    }

    /// Converts a runtime or engine failure into visible coordinator state and clears stale UI.
    func applyFailure(_ message: String, workID: UInt64) async {
        guard workController.isCurrent(workID) else {
            return
        }

        clearSuggestion()
        hideOverlay(reason: "Overlay hidden because generation failed.")
        state = .failed(message)
        logStage("failed", workID: workID, generation: latestGenerationNumber, message: message)
    }

    // MARK: - Coordinator State Reset

    /// Recomputes whether prediction should be enabled based on current permissions and focus support.
    func reconcileWithCurrentEnvironment() {
        let disabledReason = currentDisabledReason(focusSnapshot: focusModel.snapshot)

        if disabledReason == nil {
            if case .disabled = state {
                state = .idle
            }
        } else if let disabledReason {
            disablePredictions(reason: disabledReason)
        }
    }

    /// Reconciles the active suggestion session with the latest live AX context.
    /// This is the heart of partial acceptance: a text change is not automatically "stale" anymore.
    /// It may instead mean "the user consumed the next expected part of the suggestion."
    func reconcileActiveSession(with snapshot: FocusSnapshot) {
        guard let activeSession = interactionState.activeSession else {
            if overlayState.isVisible {
                hideOverlay(reason: "Overlay hidden because no ready suggestion remains.")
            }
            return
        }

        // Corrections are accept-or-dismiss, never partially consumed: the corrected word is not a
        // continuation of the preceding text, so the normal reconciler would mis-advance it the
        // moment the user types a character that happens to match the fix. Keep the offer only while
        // the field is unchanged; any edit drops it and the next prediction re-evaluates the new word.
        if activeSession.kind.isCorrection {
            reconcileCorrectionSession(activeSession, with: snapshot)
            return
        }

        guard case .supported = snapshot.capability, let rawContext = snapshot.context else {
            // Browser-based editors can transiently report "no usable text field" for a single AX
            // poll right after we synthesize accepted text. During that narrow post-insertion sync
            // window, keep the active session alive and wait for the next settled snapshot.
            if interactionState.isAwaitingPostInsertionSync {
                return
            }
            invalidateActiveSuggestion(reason: snapshot.capability.summary)
            return
        }

        guard let reconciliation = interactionState.reconcileActiveSession(with: rawContext) else {
            invalidateActiveSuggestion(reason: "Overlay hidden because no ready suggestion remains.")
            return
        }

        switch reconciliation {
        case let .valid(liveContext, reconciledSession, advancement):
            applyValidReconciliation(
                liveContext: liveContext,
                reconciledSession: reconciledSession,
                advancement: advancement
            )

        case let .invalid(reason):
            invalidateActiveSuggestion(reason: reason)
        }
    }

    /// Applies a `.valid` reconciliation result: completes an exhausted session, or re-renders the
    /// remaining tail (subject to the stability gate). Extracted from `reconcileActiveSession` so that
    /// function stays within the project's cyclomatic-complexity budget after the correction branch.
    private func applyValidReconciliation(
        liveContext: FocusedInputContext,
        reconciledSession: ActiveSuggestionSession,
        advancement: SuggestionSessionAdvancement?
    ) {
        latestGenerationNumber = liveContext.generation

        if reconciledSession.isExhausted {
            completeActiveSuggestion(
                reason: "Overlay hidden because the active suggestion was fully consumed.",
                scheduleNextPrediction: true,
                stage: advancement?.exhaustionStage ?? "session-exhausted",
                message: advancement?.exhaustionMessage ?? "The active suggestion was fully consumed."
            )
            return
        }

        state = .ready(text: reconciledSession.remainingText, latency: reconciledSession.latency)
        // Reconciliation runs both for legitimate context changes (window drag, field switch,
        // user typing through the tail) and for the +30ms post-insertion AX refresh that fires
        // after every Tab accept. In the post-insertion case the underlying state has not
        // meaningfully changed (the overlay already shows the right tail at the predicted
        // caret), but AX commonly returns a slightly different `caretRect` / `observedCharWidth`
        // than the predicted pair. Re-rendering against those drifted measurements is what
        // causes the visible one-frame "shift left and down then snap back" on accept. Hold the
        // existing geometry whenever the field, text, and on-screen field bounds have not
        // materially moved; the gate below still re-anchors on legitimate context changes.
        if SuggestionOverlayStabilityGate.shouldRePresent(
            currentOverlay: overlayState,
            newText: reconciledSession.remainingText,
            newCaretRect: liveContext.caretRect,
            newInputFrameRect: liveContext.inputFrameRect,
            newFocusChangeSequence: liveContext.focusChangeSequence,
            // While the host has not published our own synthetic insert, this snapshot's caret is
            // the pre-insertion one; re-anchoring to it is the left-then-right accept jitter.
            isAwaitingPostInsertionSync: interactionState.isAwaitingPostInsertionSync,
            millisecondsSinceLastAcceptance: lastAcceptanceAt.map {
                Int(Date().timeIntervalSince($0) * 1000)
            }
        ) {
            presentOverlay(
                text: reconciledSession.remainingText,
                at: liveContext.caretRect,
                context: liveContext,
                isRightToLeft: TextDirectionDetector.isRightToLeft(liveContext.precedingText)
            )
        }
        if let advancement {
            logStage(
                advancement.stage,
                workID: currentWorkID,
                generation: liveContext.generation,
                message: advancement.message,
                normalizedOutput: reconciledSession.remainingText
            )
        }
    }

    /// Keeps a native correction offer on screen only while the field is unchanged. A correction is
    /// a snapshot in time: the instant the user edits (or switches apps/fields), the offer is stale,
    /// so we drop it and let the next prediction re-run the typo gate against the new current word.
    /// We deliberately do not advance or re-anchor it, because a corrected word is not a continuation
    /// of the preceding text.
    private func reconcileCorrectionSession(_ session: ActiveSuggestionSession, with snapshot: FocusSnapshot) {
        guard case .supported = snapshot.capability, let rawContext = snapshot.context else {
            // Tolerate the transient post-insertion AX-sync gap the same way the continuation path
            // does, so a single empty poll right after our own edit does not flap the overlay.
            if interactionState.isAwaitingPostInsertionSync {
                return
            }
            invalidateActiveSuggestion(reason: snapshot.capability.summary)
            return
        }

        guard case let .correction(typoWord) = session.kind else {
            invalidateActiveSuggestion(reason: "Overlay hidden because the correction session was invalid.")
            return
        }

        // Keep the offer while the live trailing word (tolerating one trailing space the user just
        // typed) is still the exact typo we offered to fix, in the same app. This is what makes the
        // green correction survive a space: the word is unchanged, so we keep showing it as
        // Tab-acceptable. Any other edit — typing more, a second space, deleting, switching apps —
        // drops it, and the next prediction re-runs the gate for the new current word.
        let liveWord = CurrentWordExtractor.extractTrailingWord(from: rawContext.precedingText)?.result.word
        if liveWord == typoWord, rawContext.processIdentifier == session.baseContext.processIdentifier {
            return
        }
        invalidateActiveSuggestion(
            reason: "Overlay hidden because the field changed after a correction was offered."
        )
    }

    /// The single marshalling point for `SuggestionAvailabilityEvaluator.disabledReason`: every gate
    /// in the input and prediction paths shares the same settings, permission, and per-domain inputs,
    /// and varies only by which focus snapshot it is checking. Returns the user-facing disable reason,
    /// or nil when predictions are allowed for `focusSnapshot`.
    func currentDisabledReason(focusSnapshot: FocusSnapshot) -> String? {
        SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: settingsSnapshot.isGloballyEnabled,
            temporarilyPaused: settingsSnapshot.isTemporarilyPaused,
            disabledAppBundleIdentifiers: settingsSnapshot.disabledAppBundleIdentifiers,
            disabledDomains: PerDomainDisableSettings.disabledDomains(),
            suggestInIntegratedTerminals: settingsSnapshot.suggestInIntegratedTerminals,
            inputMonitoringGranted: permissionManager.inputMonitoringGranted,
            focusSnapshot: focusSnapshot
        )
    }

    /// Fully disables prediction, clears cached context, and updates UI messaging with the cause.
    func disablePredictions(reason: String) {
        // In a field that stays blocked (capability, per-app, per-domain), every keystroke routes
        // here. Once the pipeline is already torn down for this exact reason there is nothing
        // left to cancel or hide; re-running the teardown only spawns a redundant engine-reset
        // task and republishes identical UI state on each key.
        if isAlreadyDisabled(for: reason) {
            return
        }

        CotabbyLogger.suggestion.debug("Predictions disabled: \(reason)")
        wordPredictionPresenter?.hidePredictions()
        cancelPredictionWork()
        resetCachedGenerationContext()
        visualContextCoordinator.cancel(resetState: true)
        interactionState.resetAll()
        clearSuggestion(clearDiagnostics: true)
        hideOverlay(reason: reason)
        state = .disabled(reason)
    }

    /// Disables predictions without tearing down the visual context session.
    ///
    /// Transient disabled states — "text is selected", "secure field", brief "no focused element"
    /// between field switches — should not cancel an in-progress OCR pipeline. The visual context
    /// session is field-scoped and outlives individual prediction cycles; destroying it here would
    /// force a redundant re-capture when the user starts typing again.
    func disablePredictionsPreservingVisualContext(reason: String) {
        if isAlreadyDisabled(for: reason) {
            return
        }

        cancelPredictionWork()
        resetCachedGenerationContext()
        interactionState.resetAll()
        clearSuggestion(clearDiagnostics: true)
        hideOverlay(reason: reason)
        state = .disabled(reason)
    }

    /// True when a previous teardown already disabled the pipeline for this exact reason and
    /// nothing visible or session-shaped has appeared since. The overlay and session checks are
    /// defensive: any path that shows ghost text or starts a session also moves `state` away from
    /// `.disabled`, but re-running the teardown is cheap insurance if that invariant ever slips.
    private func isAlreadyDisabled(for reason: String) -> Bool {
        guard case .disabled(let currentReason) = state, currentReason == reason else {
            return false
        }

        return !overlayState.isVisible && interactionState.activeSession == nil
    }

    /// True when the no-session clear path still has anything to tear down. With no active
    /// session, most keystrokes arrive with the overlay already hidden and the state already idle.
    /// `.disabled` counts as nothing-to-clear because entering it already ran the full teardown.
    var hasSuggestionArtifactsToClear: Bool {
        if overlayState.isVisible || interactionState.activeSession != nil {
            return true
        }

        switch state {
        case .idle, .disabled:
            return false
        default:
            return true
        }
    }

    /// Clears the active suggestion and optionally preserves or drops diagnostic breadcrumbs.
    func clearSuggestion(clearDiagnostics: Bool = false) {
        // Drop any pending accepted-tail guard whenever the suggestion state is torn down (user
        // typed, focus changed, predictions disabled). The final-chunk accept re-sets it afterward.
        lastAcceptedTail = nil
        // Stream bookkeeping follows the session it was rendering for.
        suggestionStreamingState.clearSession()
        interactionState.clearSuggestion()

        if clearDiagnostics {
            latestGenerationNumber = nil
            // Clear so the next session's terminal logStage doesn't carry the previous
            // request_id forward. `+Acceptance.logStage` falls back to "req_none" on nil,
            // preserving the join-key contract documented on `latestRequestID`.
            latestRequestID = nil
        }
    }

    /// Cancels debounce/generation tasks and advances the work id so late completions are ignored.
    func cancelPredictionWork() {
        heldSpellingBar?.cancel()
        heldSpellingBar = nil
        pendingSpeculativeSignature = nil
        hostPublishPollGeneration &+= 1
        workController.cancelAll()
    }

    /// Starts an ordered backend context reset without forcing synchronous input handlers to become
    /// async. `generateFromCurrentFocus` awaits this barrier before it builds the next request, so a
    /// reset caused by focus/settings changes cannot race with the following generation.
    func resetCachedGenerationContext() {
        pendingCacheReset?.task.cancel()
        cacheResetSequence &+= 1
        let sequence = cacheResetSequence
        let suggestionEngine = suggestionEngine
        let resetTask = Task { @MainActor in
            guard !Task.isCancelled else {
                return
            }

            await suggestionEngine.resetCachedGenerationContext()
        }
        pendingCacheReset = (sequence, resetTask)
    }

    func awaitCachedGenerationContextResetIfNeeded() async {
        guard let pendingCacheReset else {
            return
        }

        await pendingCacheReset.task.value

        if self.pendingCacheReset?.sequence == pendingCacheReset.sequence {
            self.pendingCacheReset = nil
        }
    }

    // MARK: - Visual Context

    /// Once screenshot context becomes ready, regenerate only if the user is still in the same
    /// field and there is enough typed text for a real inline completion request.
    func schedulePredictionForCurrentFocusIfPossible(matching identity: FocusedInputIdentity) {
        focusModel.refreshNow()
        let snapshot = focusModel.snapshot

        guard SuggestionAvailabilityEvaluator.shouldSchedulePredictionWhenVisualContextBecomesReady(
            focusSnapshot: snapshot,
            matching: identity
        ) else {
            return
        }

        schedulePrediction()
    }
}

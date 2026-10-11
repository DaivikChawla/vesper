//
//  CompanionPanelView.swift
//  leanring-buddy
//
//  The SwiftUI content hosted inside the menu bar panel. Two pages at one
//  fixed size (VesperPanelLayout), so it fits a MacBook screen and never
//  jumps: Home (what she's doing, type to her, control mode, recent
//  conversation, usage) and Settings (grouped cards). During first-run
//  setup it shows the permissions checklist instead. Built from the
//  pieces in VesperPanelComponents.swift.
//

import AppKit
import AVFoundation
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var googleAPIKeyInput = ""
    /// True for a moment after "New conversation", so the click visibly did something.
    @State private var isShowingNewConversationConfirmation = false
    /// Whether the list of shortcuts (each Off / Run / Ask) is open.
    @State private var isShortcutListExpanded = false
    /// What's being typed into "Ask Vesper".
    @State private var typedQuestionInput = ""
    @FocusState private var isTypedQuestionFieldFocused: Bool
    /// The exchange whose copy button was just clicked, so it can show a tick.
    @State private var recentlyCopiedExchangeID: UUID?
    /// Which page is showing. Remembered while the app runs.
    @State private var selectedPage: VesperPanelPage = .home

    private var isSetUp: Bool {
        companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VesperPanelHeader(
                statusText: statusText,
                statusColor: statusDotColor,
                selectedPage: isSetUp ? selectedPage : nil,
                onSelectPage: { page in selectedPage = page }
            )

            if isSetUp {
                Group {
                    switch selectedPage {
                    case .home:
                        homePage
                    case .settings:
                        settingsPage
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                setupPage
            }
        }
        .frame(width: VesperPanelLayout.panelWidth, height: isSetUp ? VesperPanelLayout.panelHeight : nil)
        .background(panelBackground)
        // ctrl+option+/ opened the panel to type a question.
        .onReceive(NotificationCenter.default.publisher(for: .vesperFocusTypedQuestionField)) { _ in
            // From Settings the field doesn't exist until Home is drawn, so
            // focus it a moment after switching.
            selectedPage = .home
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isTypedQuestionFieldFocused = true
            }
        }
    }

    // MARK: - Home

    private var homePage: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let claudeConnectionProblemDescription = companionManager.claudeConnectionProblemDescription {
                connectionProblemBanner(claudeConnectionProblemDescription)
            }

            VesperPanelHero(
                title: heroTitle,
                detail: heroDetail,
                keyLabels: BuddyPushToTalkShortcut.currentShortcutOption.keyCapsuleLabels,
                isActive: companionManager.voiceState != .idle,
                taskStatusText: companionManager.handsOnTaskStatusDescription,
                onStopTask: { companionManager.stopHandsOnTask() }
            )

            typedQuestionField

            VesperPanelGroup(footnote: homeControlFootnote) {
                VesperPanelRow(iconName: "hand.point.up.left", title: "Control", showsDivider: false) {
                    VesperPanelSegmentedControl(
                        options: VesperControlMode.allCases.map { controlMode in
                            .init(id: controlMode.rawValue, title: controlMode.displayName, tooltip: controlModeExplanation(for: controlMode))
                        },
                        selectedOptionID: companionManager.controlMode.rawValue,
                        selectionColor: companionManager.controlMode == .handsOn ? VesperPanelPalette.inControl : nil,
                        onSelect: { selectedID in
                            if let controlMode = VesperControlMode(rawValue: selectedID) {
                                companionManager.setControlMode(controlMode)
                            }
                        }
                    )
                }
                if companionManager.controlMode != .off {
                    paceRow(showsDivider: true)
                }
            }

            recentConversationSection
                .frame(maxHeight: .infinity, alignment: .top)

            homeFooter
        }
        .padding(.horizontal, VesperPanelLayout.outerPadding)
        .padding(.bottom, 12)
    }

    private var heroTitle: String {
        if companionManager.isSubscriptionKnownToBeResting {
            return "Resting"
        }
        switch companionManager.voiceState {
        case .idle:
            return companionManager.isOverlayVisible ? "Ready when you are" : "Hidden"
        case .listening:
            return "Listening…"
        case .processing:
            return "Thinking…"
        case .responding:
            return "Speaking"
        }
    }

    /// What she heard last, so a mishearing is easy to spot. (Only here,
    /// never in the island: the user doesn't want their words on screen.)
    private var heroDetail: String? {
        if companionManager.isSubscriptionKnownToBeResting {
            return "Your Claude plan's limit is reached. She'll be back when it resets."
        }
        if let lastTranscript = companionManager.lastTranscript, !lastTranscript.isEmpty {
            return "Heard \u{201C}\(lastTranscript)\u{201D}"
        }
        return "Ask about anything on your screen."
    }

    // MARK: - Typed Question

    /// "Ask Vesper": Return sends it through the same pipeline as a spoken
    /// question (screenshot, Claude, speech, pointing). Escape closes the
    /// panel (handled by the panel itself).
    private var typedQuestionField: some View {
        let hasTypedText = VesperTypedQuestion.cleanedQuestionText(typedQuestionInput) != nil
        return HStack(spacing: 8) {
            Image(systemName: "text.cursor")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
            TextField("Ask Vesper…", text: $typedQuestionInput)
                // Voice setup is listening for clips, not questions.
                .disabled(companionManager.voiceSetupClipIndex != nil)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundColor(DS.Colors.textPrimary)
                .focused($isTypedQuestionFieldFocused)
                .onSubmit(submitTypedQuestionInput)

            Button(action: submitTypedQuestionInput) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(hasTypedText ? .white : DS.Colors.textTertiary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(hasTypedText ? VesperPanelPalette.tint : Color.white.opacity(0.08)))
            }
            .buttonStyle(VesperPanelPressableButtonStyle())
            .disabled(!hasTypedText)
            .pointerCursor(isEnabled: hasTypedText)
            .nativeTooltip("Send (Return). She sees your screen, like when you speak.")
        }
        .padding(.leading, 11)
        .padding(.trailing, 5)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(isTypedQuestionFieldFocused ? 0.08 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isTypedQuestionFieldFocused ? VesperPanelPalette.tint.opacity(0.7) : VesperPanelPalette.cardStroke, lineWidth: isTypedQuestionFieldFocused ? 1 : 0.5)
        )
        .animation(.easeOut(duration: DS.Animation.fast), value: isTypedQuestionFieldFocused)
    }

    private func submitTypedQuestionInput() {
        guard VesperTypedQuestion.cleanedQuestionText(typedQuestionInput) != nil else { return }
        let typedQuestionText = typedQuestionInput
        typedQuestionInput = ""
        isTypedQuestionFieldFocused = false
        companionManager.submitTypedQuestion(typedQuestionText)
    }

    // MARK: - Recent Conversation

    /// The last few exchanges, newest first, filling the rest of Home.
    /// Tags are already stripped and each side capped (VesperRecentConversation).
    private var recentConversationSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("RECENT")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer()
                Button(action: startNewConversation) {
                    HStack(spacing: 4) {
                        Image(systemName: isShowingNewConversationConfirmation ? "checkmark" : "plus.bubble")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text(isShowingNewConversationConfirmation ? "Started fresh" : "New conversation")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundColor(isShowingNewConversationConfirmation ? DS.Colors.success : DS.Colors.textSecondary)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                }
                .buttonStyle(VesperPanelPlainHoverButtonStyle(cornerRadius: 6))
                .pointerCursor()
                .nativeTooltip("Vesper forgets this conversation; the next question starts fresh. Her long-term memory notes are kept.")
            }
            .padding(.leading, 4)

            if companionManager.recentExchanges.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 18, weight: .light))
                        .foregroundColor(DS.Colors.textTertiary.opacity(0.7))
                    Text("Your conversation shows up here.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(companionManager.recentExchanges) { recentExchange in
                            VesperPanelRecentRow(
                                userText: recentExchange.userText,
                                replyText: recentExchange.replyText,
                                isShowingCopiedTick: recentlyCopiedExchangeID == recentExchange.id,
                                onCopy: { copyRecentExchangeToClipboard(recentExchange) }
                            )
                        }
                    }
                }
            }
        }
    }

    private func startNewConversation() {
        companionManager.startNewConversation()
        // Confirm it happened: the button says so for a moment.
        withAnimation(.easeOut(duration: 0.15)) {
            isShowingNewConversationConfirmation = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeOut(duration: 0.3)) {
                isShowingNewConversationConfirmation = false
            }
        }
    }

    private func copyRecentExchangeToClipboard(_ recentExchange: VesperRecentExchange) {
        var copiedLines: [String] = []
        if !recentExchange.userText.isEmpty {
            copiedLines.append("You: \(recentExchange.userText)")
        }
        if !recentExchange.replyText.isEmpty {
            copiedLines.append("Vesper: \(recentExchange.replyText)")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copiedLines.joined(separator: "\n"), forType: .string)
        recentlyCopiedExchangeID = recentExchange.id
        let copiedExchangeID = recentExchange.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if recentlyCopiedExchangeID == copiedExchangeID {
                recentlyCopiedExchangeID = nil
            }
        }
    }

    // MARK: - Home Footer

    /// Claude usage at a glance, and Quit.
    private var homeFooter: some View {
        HStack(spacing: 12) {
            if let usageSnapshot = companionManager.latestSubscriptionUsage {
                VesperPanelUsageMeter(
                    label: "5h",
                    fraction: usageSnapshot.fiveHourWindowUtilization,
                    tooltip: "Claude plan, 5-hour window: \(usageDetailText(utilization: usageSnapshot.fiveHourWindowUtilization, resetsAt: usageSnapshot.fiveHourWindowResetsAt))"
                )
                VesperPanelUsageMeter(
                    label: "Week",
                    fraction: usageSnapshot.sevenDayWindowUtilization,
                    tooltip: "Claude plan, weekly: \(usageDetailText(utilization: usageSnapshot.sevenDayWindowUtilization, resetsAt: usageSnapshot.sevenDayWindowResetsAt))"
                )
            } else {
                Text("Usage shows after your first question")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            if companionManager.isSubscriptionKnownToBeResting {
                statusChip("Resting", color: DS.Colors.warning)
            } else if companionManager.isSaverModeActive {
                statusChip("Saver", color: DS.Colors.warning)
            }
            Spacer()
            VesperPanelIconButton(systemName: "power", tooltip: "Quit Vesper") {
                NSApp.terminate(nil)
            }
        }
        .padding(.top, 2)
    }

    private func usageDetailText(utilization: Double?, resetsAt: Date?) -> String {
        let clampedUtilization = min(max(utilization ?? 0, 0), 1)
        let percentText = "\(Int((clampedUtilization * 100).rounded()))%"
        guard let resetsAt, resetsAt > Date() else { return percentText }

        let resetTimeFormatter = DateFormatter()
        resetTimeFormatter.dateFormat = Calendar.current.isDateInToday(resetsAt) ? "h:mm a" : "EEE h:mm a"
        return "\(percentText) · resets \(resetTimeFormatter.string(from: resetsAt))"
    }

    // MARK: - Settings

    private var settingsPage: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                claudeSettingsGroup
                voiceSettingsGroup
                if companionManager.controlMode != .off {
                    controlSettingsGroup
                }
                listeningSettingsGroup
                displaySettingsGroup
            }
            .padding(.horizontal, VesperPanelLayout.outerPadding)
            .padding(.top, 2)
            .padding(.bottom, 16)
        }
    }

    private var claudeSettingsGroup: some View {
        VesperPanelGroup(title: "Claude", footnote: claudePlanFootnote) {
            VesperPanelRow(iconName: "sparkle", title: "Model", subtitle: "Sonnet is fastest", showsDivider: false) {
                VesperPanelSegmentedControl(
                    options: VesperClaudeModel.allCases.map { model in .init(id: model.rawValue, title: model.displayName, tooltip: nil) },
                    selectedOptionID: companionManager.selectedModel.rawValue,
                    onSelect: { selectedID in
                        if let model = VesperClaudeModel(rawValue: selectedID) {
                            companionManager.setSelectedModel(model)
                        }
                    }
                )
            }
            VesperPanelRow(iconName: "globe", title: "Web research", subtitle: "~15k tokens per lookup") {
                VesperPanelSwitch(
                    isOn: companionManager.isWebResearchEnabled,
                    tooltip: "Looks things up on the web for questions that need current info. Each lookup uses about 15k tokens of your Claude plan and takes 6–15 s.",
                    onChange: { companionManager.setWebResearchEnabled($0) }
                )
            }
            VesperPanelRow(
                iconName: "brain",
                title: "Memory",
                subtitle: companionManager.memoryNoteCount == 1 ? "1 note" : "\(companionManager.memoryNoteCount) notes"
            ) {
                VesperPanelSmallButton(
                    title: "Edit",
                    tooltip: "See, change or delete what Vesper remembers. One note per line; changes count from her next conversation."
                ) {
                    companionManager.openMemoryInTextEditor()
                }
            }
        }
    }

    private var claudePlanFootnote: String? {
        guard let usageSnapshot = companionManager.latestSubscriptionUsage else { return nil }
        return "Plan usage — 5-hour: \(usageDetailText(utilization: usageSnapshot.fiveHourWindowUtilization, resetsAt: usageSnapshot.fiveHourWindowResetsAt)). Weekly: \(usageDetailText(utilization: usageSnapshot.sevenDayWindowUtilization, resetsAt: usageSnapshot.sevenDayWindowResetsAt))."
    }

    private var voiceSettingsGroup: some View {
        VesperPanelGroup(title: "Voice", footnote: voiceStatusFootnote) {
            VesperPanelRow(iconName: "waveform", title: "Voice", showsDivider: false) {
                VesperPanelSegmentedControl(
                    options: VesperVoiceMode.allCases.map { voiceMode in
                        .init(id: voiceMode.rawValue, title: voiceMode.displayName, tooltip: voiceModeTooltip(for: voiceMode))
                    },
                    selectedOptionID: companionManager.voiceMode.rawValue,
                    onSelect: { selectedID in
                        if let voiceMode = VesperVoiceMode(rawValue: selectedID) {
                            companionManager.setVoiceMode(voiceMode)
                        }
                    }
                )
            }
            if companionManager.voiceMode != .kokoro {
                VesperPanelRow(iconName: "person.wave.2", title: "Google voice") {
                    googleVoicePicker
                }
                googleAPIKeyRow
            }
        }
    }

    private func voiceModeTooltip(for voiceMode: VesperVoiceMode) -> String {
        switch voiceMode {
        case .automatic:
            return "Google when it answers quickly, otherwise Kokoro — whichever gets her talking sooner"
        case .google:
            return "Always Google's Chirp 3 HD voice (needs internet)"
        case .kokoro:
            return "Always Kokoro, on this Mac — offline, instant, unlimited"
        }
    }

    /// The voices' live status, in one small note under the Voice card.
    private var voiceStatusFootnote: String? {
        var statusLines: [String] = []
        if companionManager.voiceMode != .kokoro, let googleVoiceStatusDescription = companionManager.googleVoiceStatusDescription {
            statusLines.append("Google: \(googleVoiceStatusDescription)")
        }
        if companionManager.voiceMode != .google, let kokoroVoiceStatusDescription = companionManager.kokoroVoiceStatusDescription {
            statusLines.append("Kokoro: \(kokoroVoiceStatusDescription)")
        }
        if let lastSentenceVoiceDescription = companionManager.lastSentenceVoiceDescription {
            statusLines.append("Last spoke: \(lastSentenceVoiceDescription)")
        }
        return statusLines.isEmpty ? nil : statusLines.joined(separator: "\n")
    }

    private var googleVoicePicker: some View {
        Menu {
            ForEach(GoogleChirpSpeechSynthesisProvider.femaleVoiceNames, id: \.self) { voiceName in
                Button(action: {
                    companionManager.setGoogleVoiceName(voiceName)
                }) {
                    if voiceName == companionManager.googleVoiceName {
                        Label(voiceName, systemImage: "checkmark")
                    } else {
                        Text(voiceName)
                    }
                }
            }
        } label: {
            Text(companionManager.googleVoiceName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .pointerCursor()
    }

    @ViewBuilder
    private var googleAPIKeyRow: some View {
        if companionManager.hasGoogleAPIKey {
            VesperPanelRow(iconName: "key", title: "Google API key", subtitle: "Saved in your Keychain") {
                VesperPanelSmallButton(title: "Remove", tooltip: "Delete the key from your Keychain") {
                    companionManager.saveGoogleAPIKey("")
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Rectangle()
                    .fill(VesperPanelPalette.rowDivider)
                    .frame(height: 0.5)
                    .padding(.leading, 28)
                HStack(spacing: 6) {
                    SecureField("Paste Google API key", text: $googleAPIKeyInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                        .onSubmit(saveGoogleAPIKeyInput)
                    VesperPanelSmallButton(title: "Save", color: VesperPanelPalette.tint, action: saveGoogleAPIKeyInput)
                        .disabled(googleAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.leading, 28)
                Text("Stored in your Mac's Keychain. Without a key, Auto uses Kokoro.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.leading, 28)
                    .padding(.bottom, 8)
            }
        }
    }

    private func saveGoogleAPIKeyInput() {
        let trimmedGoogleAPIKey = googleAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoogleAPIKey.isEmpty else { return }
        companionManager.saveGoogleAPIKey(trimmedGoogleAPIKey)
        googleAPIKeyInput = ""
    }

    private var controlSettingsGroup: some View {
        VesperPanelGroup(title: "Doing things", footnote: controlModeExplanation(for: companionManager.controlMode)) {
            paceRow(showsDivider: false)
            if companionManager.controlMode == .handsOn {
                VesperPanelRow(iconName: "list.number", title: "Max steps per task") {
                    handsOnStepLimitStepper
                }
            }
            VesperPanelRow(
                iconName: "square.stack.3d.up",
                title: "Shortcuts",
                subtitle: companionManager.shortcutPermissions.isEmpty ? "None allowed" : "\(companionManager.shortcutPermissions.count) allowed"
            ) {
                VesperPanelSmallButton(
                    title: isShortcutListExpanded ? "Done" : "Choose",
                    tooltip: "Pick which of your Shortcuts Vesper may run: Run (at once) or Ask (she asks first). Everything else stays off."
                ) {
                    if !isShortcutListExpanded {
                        companionManager.loadInstalledShortcutNames()
                    }
                    withAnimation(.easeOut(duration: DS.Animation.fast)) {
                        isShortcutListExpanded.toggle()
                    }
                }
            }
            if isShortcutListExpanded {
                shortcutPermissionList
                    .padding(.leading, 28)
                    .padding(.bottom, 10)
            }
        }
    }

    @ViewBuilder
    private var shortcutPermissionList: some View {
        if companionManager.installedShortcutNames.isEmpty {
            Text("No shortcuts found yet. Make some in the Shortcuts app, then open this again.")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(companionManager.installedShortcutNames, id: \.self) { shortcutName in
                    HStack(spacing: 6) {
                        Text(shortcutName)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        VesperPanelSegmentedControl(
                            options: VesperShortcutPermission.allCases.map { permission in
                                .init(id: permission.rawValue, title: permission.displayName, tooltip: shortcutPermissionExplanation(permission))
                            },
                            selectedOptionID: (companionManager.shortcutPermissions[shortcutName] ?? .off).rawValue,
                            onSelect: { selectedID in
                                if let permission = VesperShortcutPermission(rawValue: selectedID) {
                                    companionManager.setShortcutPermission(permission, forShortcutNamed: shortcutName)
                                }
                            }
                        )
                    }
                }
            }
        }
    }

    private func shortcutPermissionExplanation(_ permission: VesperShortcutPermission) -> String {
        switch permission {
        case .off:
            return "Vesper can't run this shortcut."
        case .run:
            return "Vesper runs it as soon as you ask."
        case .askFirst:
            return "Vesper asks before running it. Use this for anything that sends, buys or deletes."
        }
    }

    /// − 30 + : how many look-and-act steps one hands-on task may take.
    private var handsOnStepLimitStepper: some View {
        let stepLimit = companionManager.maximumHandsOnStepsPerTask
        let stepLimitRange = CompanionManager.handsOnStepLimitRange
        let stepLimitIncrement = CompanionManager.handsOnStepLimitIncrement
        return HStack(spacing: 0) {
            stepperButton(systemName: "minus", isEnabled: stepLimit > stepLimitRange.lowerBound, tooltip: "Fewer steps") {
                companionManager.setMaximumHandsOnStepsPerTask(stepLimit - stepLimitIncrement)
            }
            Text("\(stepLimit)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundColor(DS.Colors.textPrimary)
                .frame(minWidth: 26)
            stepperButton(systemName: "plus", isEnabled: stepLimit < stepLimitRange.upperBound, tooltip: "More steps. Each step is one short Claude request with a screenshot.") {
                companionManager.setMaximumHandsOnStepsPerTask(stepLimit + stepLimitIncrement)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(VesperPanelPalette.controlTrack)
        )
    }

    private func stepperButton(systemName: String, isEnabled: Bool, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(isEnabled ? DS.Colors.textSecondary : DS.Colors.textTertiary.opacity(0.5))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(VesperPanelPlainHoverButtonStyle(cornerRadius: 6))
        .disabled(!isEnabled)
        .pointerCursor(isEnabled: isEnabled)
        .nativeTooltip(tooltip)
    }

    private var listeningSettingsGroup: some View {
        VesperPanelGroup(title: "Listening", footnote: companionManager.voiceIdentityStatusDescription) {
            VesperPanelRow(iconName: "ear", title: "Listen for my answer", subtitle: "Mic stays open after her questions", showsDivider: false) {
                VesperPanelSwitch(
                    isOn: companionManager.isListenForAnswerEnabled,
                    tooltip: "When she asks you something, the mic stays on for 6 seconds so you can answer without the hotkey. Off: always use the hotkey.",
                    onChange: { companionManager.setListenForAnswerEnabled($0) }
                )
            }
            VesperPanelRow(iconName: "person.wave.2.fill", title: "Only my voice", subtitle: "Ignores anyone who isn't you") {
                onlyMyVoiceControls
            }
        }
    }

    /// Before setup: "Set up". During setup: "Cancel". After: the switch
    /// (password or Touch ID to change) and "Redo".
    @ViewBuilder
    private var onlyMyVoiceControls: some View {
        if companionManager.voiceSetupClipIndex != nil {
            VesperPanelSmallButton(title: "Cancel", tooltip: "Stop learning your voice") {
                companionManager.cancelVoiceSetup()
            }
        } else if !companionManager.hasOwnerVoiceprint {
            VesperPanelSmallButton(title: "Set up", tooltip: "Teach Vesper your voice: three short clips of you talking. Only a voiceprint is kept, never audio.") {
                companionManager.startVoiceSetup()
            }
        } else {
            HStack(spacing: 8) {
                VesperPanelSmallButton(title: "Redo", tooltip: "Learn your voice on the mic you're using now; other mics keep theirs (needs your Mac password or Touch ID)") {
                    companionManager.startVoiceSetup()
                }
                VesperPanelSwitch(
                    isOn: companionManager.isOnlyMyVoiceEnabled,
                    tooltip: "When on, Vesper ignores anyone who isn't you. Changing this needs your Mac password or Touch ID.",
                    onChange: { companionManager.requestOnlyMyVoiceChange(to: $0) }
                )
            }
        }
    }

    private var displaySettingsGroup: some View {
        VesperPanelGroup(title: "On screen") {
            VesperPanelRow(iconName: "captions.bubble", title: "Captions", subtitle: "Her words in the island", showsDivider: false) {
                VesperPanelSwitch(
                    isOn: companionManager.areCaptionsEnabled,
                    onChange: { companionManager.setCaptionsEnabled($0) }
                )
            }
            VesperPanelRow(iconName: "cursorarrow", title: "Always show cursor", subtitle: "Off: only while you talk") {
                VesperPanelSwitch(
                    isOn: companionManager.isClickyCursorEnabled,
                    onChange: { companionManager.setClickyCursorEnabled($0) }
                )
            }
        }
    }

    // MARK: - Pace

    /// Careful (she asks before risky steps) or Turbo (she never asks).
    /// Stored as "Ask before risky actions" on / off.
    private func paceRow(showsDivider: Bool) -> some View {
        let isTurboOn = !companionManager.isAskingBeforeRiskyActions
        return VesperPanelRow(iconName: isTurboOn ? "bolt.fill" : "checkmark.shield", title: "Pace", showsDivider: showsDivider) {
            VesperPanelSegmentedControl(
                options: [
                    .init(id: "careful", title: "Careful", tooltip: "She asks before sending, paying, deleting, pressing Return, running terminal commands or opening unknown sites, and says each step before doing it."),
                    .init(id: "turbo", title: "Turbo", tooltip: "She never asks first and works without talking through each step. She still checks her own clicks and typing, and never types passwords.")
                ],
                selectedOptionID: isTurboOn ? "turbo" : "careful",
                selectionColor: isTurboOn ? VesperPanelPalette.inControl : nil,
                onSelect: { selectedID in
                    companionManager.setAskingBeforeRiskyActions(selectedID == "careful")
                }
            )
        }
    }

    /// One line under Home's control card saying what the choice means.
    private var homeControlFootnote: String {
        let controlText = shortControlModeExplanation(for: companionManager.controlMode)
        guard companionManager.controlMode != .off else { return controlText }
        return companionManager.isAskingBeforeRiskyActions
            ? controlText + " · asks before risky steps"
            : controlText + " · Turbo: never asks first"
    }

    // MARK: - Control Mode Text

    private func shortControlModeExplanation(for controlMode: VesperControlMode) -> String {
        switch controlMode {
        case .off:
            return "Talks and points only"
        case .quickActions:
            return "Opens apps, sites, music"
        case .handsOn:
            return "Clicks and types for you"
        }
    }

    private func controlModeExplanation(for controlMode: VesperControlMode) -> String {
        switch controlMode {
        case .off:
            return "She only talks and points. She won't open or touch anything."
        case .quickActions:
            return "She can open apps and websites, play and pause media, set the volume and do things in Chrome."
        case .handsOn:
            return "She can also click, type and press keys, step by step. Your talk keys stop her."
        }
    }

    // MARK: - Setup

    private var setupPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let claudeConnectionProblemDescription = companionManager.claudeConnectionProblemDescription {
                connectionProblemBanner(claudeConnectionProblemDescription)
            }
            setupIntroduction

            if !companionManager.allPermissionsGranted {
                VesperPanelGroup(title: "Permissions") {
                    microphonePermissionRow(showsDivider: false)
                    accessibilityPermissionRow
                    screenRecordingPermissionRow
                    if companionManager.hasScreenRecordingPermission {
                        screenContentPermissionRow
                    }
                }
            }
            if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                startButton
            }

            HStack {
                Spacer()
                VesperPanelIconButton(systemName: "power", tooltip: "Quit Vesper") {
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(.horizontal, VesperPanelLayout.outerPadding)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var setupIntroduction: some View {
        if companionManager.allPermissionsGranted {
            Text("You're all set. Hit Start to meet Vesper.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding {
            // Permissions were revoked after setup — tell the user to re-grant
            VStack(alignment: .leading, spacing: 4) {
                Text("Permissions needed")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Some permissions were revoked. Grant them below to keep using Vesper.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Meet Vesper.")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Hold Control+Option and ask her anything about what's on your screen. She only looks while you're holding the keys, and she runs on your own Claude subscription.")
                    .font(.system(size: 11.5))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var startButton: some View {
        Button(action: {
            companionManager.triggerOnboarding()
        }) {
            Text("Start")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(VesperPanelPalette.tint)
                )
        }
        .buttonStyle(VesperPanelPressableButtonStyle())
        .pointerCursor()
    }

    private func microphonePermissionRow(showsDivider: Bool) -> some View {
        VesperPanelRow(iconName: "mic", title: "Microphone", showsDivider: showsDivider) {
            if companionManager.hasMicrophonePermission {
                grantedBadge
            } else {
                grantButton {
                    // Triggers the native macOS microphone permission dialog on
                    // first attempt. If already denied, opens System Settings.
                    let status = AVCaptureDevice.authorizationStatus(for: .audio)
                    if status == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private var accessibilityPermissionRow: some View {
        VesperPanelRow(iconName: "hand.raised", title: "Accessibility") {
            if companionManager.hasAccessibilityPermission {
                grantedBadge
            } else {
                HStack(spacing: 6) {
                    VesperPanelSmallButton(title: "Find App", tooltip: "Show Vesper in Finder, to drag into the Accessibility list if it isn't there") {
                        // Reveals the app in Finder so the user can drag it into
                        // the Accessibility list if it doesn't appear automatically
                        // (common with unsigned dev builds).
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    }
                    grantButton {
                        // Triggers the system accessibility prompt (AXIsProcessTrustedWithOptions)
                        // on first attempt, then opens System Settings on subsequent attempts.
                        WindowPositionManager.requestAccessibilityPermission()
                    }
                }
            }
        }
    }

    private var screenRecordingPermissionRow: some View {
        let isGranted = companionManager.hasScreenRecordingPermission
        return VesperPanelRow(
            iconName: "rectangle.dashed.badge.record",
            title: "Screen Recording",
            subtitle: isGranted ? "Only while you hold the shortcut" : "Quit and reopen after granting"
        ) {
            if isGranted {
                grantedBadge
            } else {
                grantButton {
                    // Triggers the native macOS screen recording prompt on first
                    // attempt (auto-adds app to the list), then opens System Settings
                    // on subsequent attempts.
                    WindowPositionManager.requestScreenRecordingPermission()
                }
            }
        }
    }

    private var screenContentPermissionRow: some View {
        VesperPanelRow(iconName: "eye", title: "Screen Content") {
            if companionManager.hasScreenContentPermission {
                grantedBadge
            } else {
                grantButton {
                    companionManager.requestScreenContentPermission()
                }
            }
        }
    }

    private var grantedBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
            Text("Granted")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(DS.Colors.success)
    }

    private func grantButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Grant")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 11)
                .frame(height: 22)
                .background(Capsule().fill(VesperPanelPalette.tint))
        }
        .buttonStyle(VesperPanelPressableButtonStyle())
        .pointerCursor()
    }

    // MARK: - Visual Helpers

    private func connectionProblemBanner(_ problemDescription: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.warning)
            Text(problemDescription)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.warningText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: VesperPanelLayout.cardCornerRadius, style: .continuous)
                .fill(DS.Colors.warning.opacity(0.10))
        )
    }

    private func statusChip(_ chipText: String, color: Color) -> some View {
        Text(chipText)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(VesperPanelPalette.background)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }

    private var statusDotColor: Color {
        if companionManager.claudeConnectionProblemDescription != nil || companionManager.isSubscriptionKnownToBeResting {
            return DS.Colors.warning
        }
        if companionManager.handsOnTaskStatusDescription != nil {
            return VesperPanelPalette.inControl
        }
        if !companionManager.isOverlayVisible {
            return DS.Colors.textTertiary
        }
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening, .processing, .responding:
            return VesperPanelPalette.tint
        }
    }

    private var statusText: String {
        if !isSetUp {
            return "Setup"
        }
        if companionManager.isSubscriptionKnownToBeResting {
            return "Resting"
        }
        switch companionManager.voiceState {
        case .idle:
            return companionManager.isOverlayVisible ? "Ready" : "Hidden"
        case .listening:
            return "Listening"
        case .processing:
            return "Thinking"
        case .responding:
            return "Speaking"
        }
    }
}

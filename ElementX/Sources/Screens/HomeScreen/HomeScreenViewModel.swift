//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE in the repository root for full details.
//

import AnalyticsEvents
import Combine
import DSWaveformImage
import DSWaveformImageViews
import Foundation
import MatrixRustSDK
import Speech
import SwiftUI

typealias HomeScreenViewModelType = StateStoreViewModel<HomeScreenViewState, HomeScreenViewAction>

class HomeScreenViewModel: HomeScreenViewModelType, HomeScreenViewModelProtocol {
    private let userSession: UserSessionProtocol
    private let analyticsService: AnalyticsService
    private let appSettings: AppSettings
    private let userIndicatorController: UserIndicatorControllerProtocol
    
    private var roomSummaryProvider: RoomSummaryProviderProtocol?
    private var roomListService: RoomListServiceProtocol?
    
    // Voice recording properties
    private var voiceRecorder: VoiceMessageRecorderProtocol?
    let audioRecorderState = VoiceSearchRecorderState()
    private var actionsSubject: PassthroughSubject<HomeScreenViewModelAction, Never> = .init()
    var actions: AnyPublisher<HomeScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(userSession: UserSessionProtocol,
         analyticsService: AnalyticsService,
         appSettings: AppSettings,
         selectedRoomPublisher: CurrentValuePublisher<String?, Never>,
         userIndicatorController: UserIndicatorControllerProtocol) {
        self.userSession = userSession
        self.analyticsService = analyticsService
        self.appSettings = appSettings
        self.userIndicatorController = userIndicatorController
        
        roomSummaryProvider = userSession.clientProxy.roomSummaryProvider
        
        super.init(initialViewState: .init(userID: userSession.clientProxy.userID),
                   mediaProvider: userSession.mediaProvider)
        
        userSession.clientProxy.userAvatarURLPublisher
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.userAvatarURL, on: self)
            .store(in: &cancellables)
        
        userSession.clientProxy.userDisplayNamePublisher
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.userDisplayName, on: self)
            .store(in: &cancellables)
        
        userSession.sessionSecurityStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] securityState in
                guard let self else { return }
                
                switch securityState.recoveryState {
                case .disabled:
                    state.requiresExtraAccountSetup = true
                    if !state.securityBannerMode.isDismissed {
                        state.securityBannerMode = .show(.setUpRecovery)
                    }
                case .incomplete:
                    state.requiresExtraAccountSetup = true
                    state.securityBannerMode = .show(.recoveryOutOfSync)
                default:
                    state.securityBannerMode = .none
                    state.requiresExtraAccountSetup = false
                }
            }
            .store(in: &cancellables)
        
        userSession.sessionSecurityStatePublisher
            .receive(on: DispatchQueue.main)
            .filter { state in
                state.verificationState != .unknown
                    && state.recoveryState != .settingUp
                    && state.recoveryState != .unknown
            }
            .sink { [weak self] state in
                guard let self else { return }
                
                self.analyticsService.updateUserProperties(AnalyticsEvent.newVerificationStateUserProperty(verificationState: state.verificationState, recoveryState: state.recoveryState))
                self.analyticsService.trackSessionSecurityState(state)
            }
            .store(in: &cancellables)
        
        selectedRoomPublisher
            .weakAssign(to: \.state.selectedRoomID, on: self)
            .store(in: &cancellables)
        
        appSettings.$hideUnreadMessagesBadge
            .sink { [weak self] _ in self?.updateRooms() }
            .store(in: &cancellables)
        
        appSettings.$publicSearchEnabled
            .weakAssign(to: \.state.isRoomDirectorySearchEnabled, on: self)
            .store(in: &cancellables)
        
        let isSearchFieldFocused = context.$viewState.map(\.bindings.isSearchFieldFocused)
        let searchQuery = context.$viewState.map(\.bindings.searchQuery)
        let activeFilters = context.$viewState.map(\.bindings.filtersState.activeFilters)
        isSearchFieldFocused
            .combineLatest(searchQuery, activeFilters)
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] isSearchFieldFocused, _, _ in
                guard let self else { return }
                // isSearchFieldFocused` is sometimes turning to true after cancelling the search. So to be extra sure we are updating the values correctly we read them directly in the next run loop, and we add a small delay if the value has changed
                let delay = isSearchFieldFocused == self.context.viewState.bindings.isSearchFieldFocused ? 0.0 : 0.05
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self.updateFilter()
                }
            }
            .store(in: &cancellables)
        
        setupRoomListSubscriptions()
        
        updateRooms()
        
        Task {
            await checkSlidingSyncMigration()
        }
    }
    
    // MARK: - Public
    
    override func process(viewAction: HomeScreenViewAction) {
        switch viewAction {
        case .searchGlobally(let query, let completion):
            Task {
                let result = await userSession.clientProxy.searchRooms(query: query, roomID: nil, language: "en")
                completion(result)
            }
        case .getRoomInfo(let roomId, let completion):
            Task {
                let roomSummary = roomSummaryProvider?.roomListPublisher.value.first { $0.id == roomId }
                completion(roomSummary)
            }
        case .getMessageContent(let roomId, let eventId, let completion):
            Task {
                // Try to get the room to access basic information
                guard case let .joined(roomProxy) = await userSession.clientProxy.roomForIdentifier(roomId) else {
                    MXLog.error("Could not find room for ID: \(roomId)")
                    completion(nil)
                    return
                }
                
                // Try to create a focused timeline for this specific event
                // This is a more reliable way to get the event content
                let focusedTimelineResult = await roomProxy.timelineFocusedOnEvent(eventID: eventId, numberOfEvents: 1)
                
                switch focusedTimelineResult {
                case .success(let focusedTimeline):
                    // Wait for the timeline to initialize
                    await focusedTimeline.subscribeForUpdates()
                    
                    // Wait a moment for the timeline to load
                    try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                    
                    // Try to find the event in the focused timeline
                    if let provider = try? focusedTimeline.timelineProvider,
                       let itemProxy = provider.itemProxies.first(where: { proxy in
                           if case .event(let eventProxy) = proxy, eventProxy.id.eventID == eventId {
                               return true
                           }
                           return false
                       }) {
                        // Found the event, return it
                        completion(itemProxy)
                        return
                    }
                    
                    // If we couldn't find it, try a different approach
                    // Log the failure and return nil
                    MXLog.error("Could not find event \(eventId) in focused timeline")
                    completion(nil)
                    
                case .failure(let error):
                    MXLog.error("Failed to create focused timeline for event \(eventId): \(error)")
                    completion(nil)
                }
            }
            
        // MARK: - Voice Recording Actions
            
        case .startVoiceRecording:
            Task {
                // Start actual voice recording on the main actor
                await MainActor.run {
                    // Start actual voice recording
                    audioRecorderState.startRecording()
                    
                    MXLog.info("Started voice recording for search, isRecording: \(audioRecorderState.isRecording)")
                }
            }
            
        case .stopVoiceRecording(let useTranscript):
            Task {
                // Safely get the transcript if needed before stopping
                var capturedTranscript: String? = nil
                if useTranscript {
                    // Use a safe way to access the transcript
                    capturedTranscript = audioRecorderState.safeGetTranscript()
                    MXLog.info("Captured transcript before stopping: \(capturedTranscript ?? "nil")")
                }
                
                await MainActor.run {
                    // Stop the actual recording
                    audioRecorderState.stopRecording()
                    
                    // If we're not using the transcript, clear it
                    if !useTranscript {
                        audioRecorderState.currentTranscript = nil
                    } else if capturedTranscript == nil || capturedTranscript?.isEmpty == true {
                        // If we want to use the transcript but it's nil or empty, provide a fallback
                        audioRecorderState.currentTranscript = "voice search query"
                    } else if let transcript = capturedTranscript {
                        // Make sure we preserve the transcript we captured
                        audioRecorderState.currentTranscript = transcript
                    }
                    
                    MXLog.info("Stopped voice recording for search, useTranscript: \(useTranscript)")
                }
            }
            
        case .cancelVoiceRecording:
            Task {
                await MainActor.run {
                    // Stop the actual recording and clear the transcript
                    audioRecorderState.stopRecording()
                    audioRecorderState.currentTranscript = nil
                    
                    MXLog.info("Cancelled voice recording for search")
                }
            }
            
        case .switchToKeyboard:
            Task {
                await MainActor.run {
                    // Stop the actual recording
                    audioRecorderState.stopRecording()
                    
                    MXLog.info("Switched to keyboard input for search")
                }
            }
        case .selectRoom(let roomIdentifier):
            actionsSubject.send(.presentRoom(roomIdentifier: roomIdentifier))
        case .showRoomDetails(roomIdentifier: let roomIdentifier):
            actionsSubject.send(.presentRoomDetails(roomIdentifier: roomIdentifier))
        case .leaveRoom(roomIdentifier: let roomIdentifier):
            startLeaveRoomProcess(roomID: roomIdentifier)
        case .confirmLeaveRoom(roomIdentifier: let roomIdentifier):
            Task { await leaveRoom(roomID: roomIdentifier) }
        case .showSettings:
            actionsSubject.send(.presentSettingsScreen)
        case .setupRecovery:
            actionsSubject.send(.presentSecureBackupSettings)
        case .confirmRecoveryKey:
            actionsSubject.send(.presentRecoveryKeyScreen)
        case .resetEncryption:
            actionsSubject.send(.presentEncryptionResetScreen)
        case .skipRecoveryKeyConfirmation:
            state.securityBannerMode = .dismissed
        case .confirmSlidingSyncUpgrade:
            appSettings.slidingSyncDiscovery = .native
            actionsSubject.send(.logout)
        case .skipSlidingSyncUpgrade:
            state.slidingSyncMigrationBannerMode = .dismissed
        case .updateVisibleItemRange(let range):
            roomSummaryProvider?.updateVisibleRange(range)
        case .startChat:
            actionsSubject.send(.presentStartChatScreen)
        case .globalSearch:
            actionsSubject.send(.presentGlobalSearch)
        case .markRoomAsUnread(let roomIdentifier):
            Task {
                guard case let .joined(roomProxy) = await userSession.clientProxy.roomForIdentifier(roomIdentifier) else {
                    MXLog.error("Failed retrieving room for identifier: \(roomIdentifier)")
                    return
                }
                
                switch await roomProxy.flagAsUnread(true) {
                case .success:
                    analyticsService.trackInteraction(name: .MobileRoomListRoomContextMenuUnreadToggle)
                case .failure(let error):
                    MXLog.error("Failed marking room \(roomIdentifier) as unread with error: \(error)")
                }
            }
        case .markRoomAsRead(let roomIdentifier):
            Task {
                guard case let .joined(roomProxy) = await userSession.clientProxy.roomForIdentifier(roomIdentifier) else {
                    MXLog.error("Failed retrieving room for identifier: \(roomIdentifier)")
                    return
                }
                
                switch await roomProxy.flagAsUnread(false) {
                case .success:
                    analyticsService.trackInteraction(name: .MobileRoomListRoomContextMenuUnreadToggle)
                    
                    if case .failure(let error) = await roomProxy.markAsRead(receiptType: appSettings.sharePresence ? .read : .readPrivate) {
                        MXLog.error("Failed marking room \(roomIdentifier) as read with error: \(error)")
                    }
                case .failure(let error):
                    MXLog.error("Failed flagging room \(roomIdentifier) as read with error: \(error)")
                }
            }
        case .markRoomAsFavourite(let roomIdentifier, let isFavourite):
            Task {
                await markRoomAsFavourite(roomIdentifier, isFavourite: isFavourite)
            }
        case .selectRoomDirectorySearch:
            actionsSubject.send(.presentRoomDirectorySearch)
        case .acceptInvite(let roomIdentifier):
            Task {
                await acceptInvite(roomID: roomIdentifier)
            }
        case .declineInvite(let roomIdentifier):
            showDeclineInviteConfirmationAlert(roomID: roomIdentifier)
        }
    }
    
    // perphery: ignore - used in release mode
    func presentCrashedLastRunAlert() {
        // Delay setting the alert otherwise it automatically gets dismissed. Same as the force logout one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.state.bindings.alertInfo = AlertInfo(id: UUID(),
                                                      title: L10n.crashDetectionDialogContent(InfoPlistReader.main.bundleDisplayName),
                                                      primaryButton: .init(title: L10n.actionNo, action: nil),
                                                      secondaryButton: .init(title: L10n.actionYes) { [weak self] in
                                                          self?.actionsSubject.send(.presentFeedbackScreen)
                                                      })
        }
    }
    
    // MARK: - Private
    
    private func updateFilter() {
        if state.shouldHideRoomList {
            roomSummaryProvider?.setFilter(.excludeAll)
        } else {
            if state.bindings.isSearchFieldFocused {
                roomSummaryProvider?.setFilter(.search(query: state.bindings.searchQuery))
            } else {
                roomSummaryProvider?.setFilter(.all(filters: state.bindings.filtersState.activeFilters.set))
            }
        }
    }
    
    private func setupRoomListSubscriptions() {
        guard let roomSummaryProvider else {
            MXLog.error("Room summary provider unavailable")
            return
        }
        
        analyticsService.signpost.beginFirstRooms()
                
        roomSummaryProvider.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                
                updateRoomListMode(with: state)
            }
            .store(in: &cancellables)
        
        roomSummaryProvider.roomListPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateRooms()
            }
            .store(in: &cancellables)
    }
    
    private func updateRoomListMode(with roomSummaryProviderState: RoomSummaryProviderState) {
        let isLoadingData = !roomSummaryProviderState.isLoaded
        let hasNoRooms = roomSummaryProviderState.isLoaded && roomSummaryProviderState.totalNumberOfRooms == 0
        
        var roomListMode = state.roomListMode
        if isLoadingData {
            roomListMode = .skeletons
        } else if hasNoRooms {
            roomListMode = .empty
        } else {
            roomListMode = .rooms
        }
        
        guard roomListMode != state.roomListMode else {
            return
        }
        
        if roomListMode == .rooms, state.roomListMode == .skeletons {
            analyticsService.signpost.endFirstRooms()
        }
        
        state.roomListMode = roomListMode
        
        MXLog.info("Received room summary provider update, setting view room list mode to \"\(state.roomListMode)\"")
        // Delay user profile detail loading until after the initial room list loads
        if roomListMode == .rooms {
            Task {
                await self.userSession.clientProxy.loadUserAvatarURL()
                await self.userSession.clientProxy.loadUserDisplayName()
            }
        }
    }
        
    private func updateRooms() {
        guard let roomSummaryProvider else {
            MXLog.error("Room summary provider unavailable")
            return
        }
        
        var rooms = [HomeScreenRoom]()
        
        for summary in roomSummaryProvider.roomListPublisher.value {
            let room = HomeScreenRoom(summary: summary, hideUnreadMessagesBadge: appSettings.hideUnreadMessagesBadge)
            rooms.append(room)
        }
        
        state.rooms = rooms
    }
    
    /// Check whether we can inform the user about potential migrations
    /// or have him logout as his proxy is no longer available
    private func checkSlidingSyncMigration() async {
        // Not logged in with a proxy, don't need to do anything
        guard userSession.clientProxy.slidingSyncVersion.isProxy else {
            return
        }
        
        let versions = await userSession.clientProxy.availableSlidingSyncVersions
        
        // Native not available, nothing we can do
        guard versions.contains(.native) else {
            return
        }
        
        if versions.contains(where: \.isProxy) { // Both available, prompt for migration
            state.slidingSyncMigrationBannerMode = .show
        } else { // The proxy has been removed and logout is needed
            // Delay setting the alert otherwise it automatically gets dismissed. Same as the crashed last run one
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.state.bindings.alertInfo = AlertInfo(id: UUID(),
                                                          title: L10n.bannerMigrateToNativeSlidingSyncForceLogoutTitle,
                                                          primaryButton: .init(title: L10n.bannerMigrateToNativeSlidingSyncAction,
                                                                               action: { [weak self] in
                                                                                   self?.appSettings.slidingSyncDiscovery = .native
                                                                                   self?.actionsSubject.send(.logoutWithoutConfirmation)
                                                                               }))
            }
        }
    }
    
    private func markRoomAsFavourite(_ roomID: String, isFavourite: Bool) async {
        guard case let .joined(roomProxy) = await userSession.clientProxy.roomForIdentifier(roomID) else {
            MXLog.error("Failed retrieving room for identifier: \(roomID)")
            return
        }
        
        switch await roomProxy.flagAsFavourite(isFavourite) {
        case .success:
            analyticsService.trackInteraction(name: .MobileRoomListRoomContextMenuFavouriteToggle)
        case .failure(let error):
            MXLog.error("Failed marking room \(roomID) as favourite: \(isFavourite) with error: \(error)")
        }
    }
    
    private static let leaveRoomLoadingID = "LeaveRoomLoading"
    
    private func startLeaveRoomProcess(roomID: String) {
        Task {
            defer {
                userIndicatorController.retractIndicatorWithId(Self.leaveRoomLoadingID)
            }
            userIndicatorController.submitIndicator(UserIndicator(id: Self.leaveRoomLoadingID, type: .modal, title: L10n.commonLoading, persistent: true))
            
            guard case let .joined(roomProxy) = await userSession.clientProxy.roomForIdentifier(roomID) else {
                state.bindings.alertInfo = AlertInfo(id: UUID(), title: L10n.errorUnknown)
                return
            }
            
            if roomProxy.infoPublisher.value.isPublic {
                state.bindings.leaveRoomAlertItem = LeaveRoomAlertItem(roomID: roomID, isDM: roomProxy.isEncryptedOneToOneRoom, state: .public)
            } else {
                state.bindings.leaveRoomAlertItem = if roomProxy.infoPublisher.value.joinedMembersCount > 1 {
                    LeaveRoomAlertItem(roomID: roomID, isDM: roomProxy.isEncryptedOneToOneRoom, state: .private)
                } else {
                    LeaveRoomAlertItem(roomID: roomID, isDM: roomProxy.isEncryptedOneToOneRoom, state: .empty)
                }
            }
        }
    }
    
    private func leaveRoom(roomID: String) async {
        defer {
            userIndicatorController.retractIndicatorWithId(Self.leaveRoomLoadingID)
        }
        userIndicatorController.submitIndicator(UserIndicator(id: Self.leaveRoomLoadingID, type: .modal, title: L10n.commonLeavingRoom, persistent: true))
        
        guard case let .joined(roomProxy) = await userSession.clientProxy.roomForIdentifier(roomID),
              case .success = await roomProxy.leaveRoom() else {
            state.bindings.alertInfo = AlertInfo(id: UUID(), title: L10n.errorUnknown)
            return
        }
        
        userIndicatorController.submitIndicator(UserIndicator(id: UUID().uuidString,
                                                              type: .toast,
                                                              title: L10n.commonCurrentUserLeftRoom,
                                                              iconName: "checkmark"))
        actionsSubject.send(.roomLeft(roomIdentifier: roomID))
    }
    
    // MARK: Invites
    
    private func acceptInvite(roomID: String) async {
        defer {
            userIndicatorController.retractIndicatorWithId(roomID)
        }
        
        userIndicatorController.submitIndicator(UserIndicator(id: roomID, type: .modal, title: L10n.commonLoading, persistent: true))
        
        guard case let .invited(roomProxy) = await userSession.clientProxy.roomForIdentifier(roomID) else {
            displayError()
            return
        }
        
        switch await roomProxy.acceptInvitation() {
        case .success:
            actionsSubject.send(.presentRoom(roomIdentifier: roomID))
            analyticsService.trackJoinedRoom(isDM: roomProxy.info.isDirect,
                                             isSpace: roomProxy.info.isSpace,
                                             activeMemberCount: UInt(roomProxy.info.activeMembersCount))
        case .failure:
            displayError()
        }
    }
    
    private func showDeclineInviteConfirmationAlert(roomID: String) {
        guard let room = state.rooms.first(where: { $0.id == roomID }) else {
            displayError()
            return
        }
        
        let roomPlaceholder = room.isDirect ? (room.inviter?.displayName ?? room.name) : room.name
        let title = room.isDirect ? L10n.screenInvitesDeclineDirectChatTitle : L10n.screenInvitesDeclineChatTitle
        let message = room.isDirect ? L10n.screenInvitesDeclineDirectChatMessage(roomPlaceholder) : L10n.screenInvitesDeclineChatMessage(roomPlaceholder)
        
        state.bindings.alertInfo = .init(id: UUID(),
                                         title: title,
                                         message: message,
                                         primaryButton: .init(title: L10n.actionCancel, role: .cancel, action: nil),
                                         secondaryButton: .init(title: L10n.actionDecline, role: .destructive, action: { Task { await self.declineInvite(roomID: room.id) } }))
    }
    
    private func declineInvite(roomID: String) async {
        defer {
            userIndicatorController.retractIndicatorWithId(roomID)
        }
        
        userIndicatorController.submitIndicator(UserIndicator(id: roomID, type: .modal, title: L10n.commonLoading, persistent: true))
        
        guard case let .invited(roomProxy) = await userSession.clientProxy.roomForIdentifier(roomID) else {
            displayError()
            return
        }
        
        let result = await roomProxy.rejectInvitation()
        
        if case .failure = result {
            displayError()
        }
    }
    
    private func displayError() {
        state.bindings.alertInfo = .init(id: UUID(),
                                         title: L10n.commonError,
                                         message: L10n.errorUnknown)
    }
}

extension HomeScreenViewModel {
    /// Simulates voice recording by updating the audio recorder state
    private func startRecordingSimulation() {
        // Start a timer to update the duration and waveform samples
        Task {
            var elapsedTime: TimeInterval = 0
            
            while audioRecorderState.isRecording {
                // Update duration
                audioRecorderState.duration = elapsedTime
                
                // Generate random waveform samples
                let newSamples = (0..<10).map { _ in Float.random(in: 0.1...1.0) }
                audioRecorderState.waveformSamples.append(contentsOf: newSamples)
                
                // Keep the waveform samples array at a reasonable size
                if audioRecorderState.waveformSamples.count > 100 {
                    audioRecorderState.waveformSamples.removeFirst(10)
                }
                
                // Wait a bit before the next update
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                elapsedTime += 0.1
            }
        }
    }
}

extension SlidingSyncVersion {
    var isProxy: Bool {
        switch self {
        case .proxy:
            return true
        default:
            return false
        }
    }
}

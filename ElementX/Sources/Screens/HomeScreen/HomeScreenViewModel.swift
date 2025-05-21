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
import SwiftOGG
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
    let searchRecorderState = VoiceSearchRecorderState()
    let contactRoutingRecorderState = VoiceSearchRecorderState()
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
        
        // Set up observer for search language changes
        searchLanguageObserver = NotificationCenter.default.addObserver(forName: .searchLanguageDidChange,
                                                                        object: nil,
                                                                        queue: .main) { [weak self] _ in
            // Language changed, but we don't need to do anything here
            // The next search will automatically use the new language
            MXLog.debug("Search language changed to: \(self?.appSettings.searchLanguage.displayName ?? "")")
        }
        
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
    
    private var searchLanguageObserver: NSObjectProtocol?
    
    override func process(viewAction: HomeScreenViewAction) {
        switch viewAction {
        case .searchGlobally(let query, let completion):
            Task {
                // Use the selected language from app settings
                let language = appSettings.searchLanguage.rawValue
                print("[HomeScreenViewModel] Searching with language: \(language)")
                let result = await userSession.clientProxy.searchRooms(query: query, roomID: nil, language: language)
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
                    MXLog.error("[Voice Contact Routing] Could not find event \(eventId) in focused timeline")
                    completion(nil)
                    
                case .failure(let error):
                    MXLog.error("[Voice Contact Routing] Failed to create focused timeline for event \(eventId): \(error)")
                    completion(nil)
                }
            }
            
        // MARK: - Voice Recording Actions
            
        case .startVoiceRecording:
            Task {
                contactRoutingRecorderState.startRecording()
                MXLog.info("Started voice recording for search using VoiceMessageRecorder")
            }
            
        case .stopVoiceRecording(let useTranscript):
            Task {
                contactRoutingRecorderState.stopRecording()
                MXLog.info("Stopped voice recording using VoiceMessageRecorder")
            }
            
        case .cancelVoiceRecording:
            Task {
                contactRoutingRecorderState.stopRecording()
                MXLog.info("Cancelled voice recording using VoiceMessageRecorder")
            }
            
    // MARK: - Voice Contact Routing Actions
        
        case .routeContacts(let messageContent, let completion):
            Task {
                // Use the selected language from app settings
                let language = appSettings.searchLanguage.rawValue
            
                // Call the ClientProxy method to route contacts
                let result = await userSession.clientProxy.routeContacts(messageContent: messageContent, language: language)
            
                switch result {
                case .success(let json):
                    MXLog.info("[Voice Contact Routing] Contact routing successful: \(json)")
                    // Parse the JSON response
                    if let result = json["result"] as? String {
                        if result == "success" {
                            if let data = json["data"] as? [[String: Any]] {
                                // Extract room IDs and scores
                                var suggestedRooms: [SuggestedRoom] = []
                            
                                for roomJson in data {
                                    if let roomId = roomJson["room_id"] as? String {
                                        let score = roomJson["score"] as? Double ?? 0.0
                                    
                                        let room = SuggestedRoom(roomId: roomId, score: score)
                                        suggestedRooms.append(room)
                                    }
                                }
                            
                                // Return the parsed rooms
                                completion(.success(suggestedRooms))
                            } else {
                                MXLog.error("[Voice Contact Routing] Missing or invalid 'data' field in response")
                                completion(.failure(ClientProxyError.sdkError(NSError(domain: "ClientProxyErrorDomain", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format"]))))
                            }
                        } else if result == "error" {
                            MXLog.error("[Voice Contact Routing] Server returned error response")
                            completion(.failure(ClientProxyError.sdkError(NSError(domain: "ClientProxyErrorDomain", code: -1, userInfo: [NSLocalizedDescriptionKey: "Contact routing server error"]))))
                        } else {
                            MXLog.error("[Voice Contact Routing] Unexpected result value: \(result)")
                            completion(.failure(ClientProxyError.sdkError(NSError(domain: "ClientProxyErrorDomain", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected contact routing response"]))))
                        }
                    } else {
                        MXLog.error("[Voice Contact Routing] Failed to parse contact routing response")
                        completion(.failure(ClientProxyError.sdkError(NSError(domain: "ClientProxyErrorDomain", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse contact routing response"]))))
                    }
                case .failure(let error):
                    MXLog.error("[Voice Contact Routing] Contact routing failed: \(error)")
                    completion(.failure(error))
                }
            }
            
        case .getDirectRoom(let userId, let completion):
            Task {
                let directRoomResult = await userSession.clientProxy.directRoomForUserID(userId)
                
                switch directRoomResult {
                case .success(let roomId):
                    completion(roomId)
                case .failure(let error):
                    MXLog.error("[Voice Contact Routing] Failed to get direct room: \(error)")
                    completion(nil)
                }
            }
            
        case .createDirectRoom(let userId, let completion):
            Task {
                let result = await userSession.clientProxy.createRoom(name: "", topic: "", isRoomPrivate: true, isKnockingOnly: false, userIDs: [userId], avatarURL: nil, aliasLocalPart: nil)
                
                switch result {
                case .success(let roomId):
                    completion(.success(roomId))
                case .failure(let error):
                    MXLog.error("Failed to create direct room: \(error)")
                    completion(.failure(error))
                }
            }
            
        case .showIndicator(let indicator):
            userIndicatorController.submitIndicator(indicator)
            
        case .hideIndicator(let indicator):
            userIndicatorController.retractIndicatorWithId(indicator.id)
            
        case .sendVoiceMessageToRoom(let roomId, let transcript, let completion):
            Task {
                MXLog.info("[Voice Contact Routing] Sending voice message to room: \(roomId)")
                
                // Get the room proxy for the room
                guard case let .joined(roomProxy) = await userSession.clientProxy.roomForIdentifier(roomId) else {
                    MXLog.error("[Voice Contact Routing] Failed to get room proxy for room: \(roomId)")
                    completion(.failure(ClientProxyError.sdkError(NSError(domain: "ClientProxyErrorDomain", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get room proxy"]))))
                    return
                }
                
                // Create a new audio converter instance
                let audioConverter = AudioConverter()
                
                // Send the voice message
                let result = await contactRoutingRecorderState.sendVoiceMessage(inRoom: roomProxy, audioConverter: audioConverter)
                
                switch result {
                case .success:
                    MXLog.info("[Voice Contact Routing] Voice message sent successfully")
                    completion(.success(()))
                    
                case .failure(let error):
                    MXLog.error("[Voice Contact Routing] Failed to send voice message: \(error)")
                    completion(.failure(ClientProxyError.sdkError(NSError(domain: "ClientProxyErrorDomain", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to send voice message: \(error)"]))))
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
        case .trackSearch(let isSubmitted, let isVoiceSearch, let queryLength):
            analyticsService.trackSearch(isSubmitted: isSubmitted,
                                         isVoiceSearch: isVoiceSearch,
                                         queryLength: queryLength)
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

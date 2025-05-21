//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE in the repository root for full details.

import Combine

//

import Compound
import DSWaveformImage
import SwiftUI

// Import for AudioRecorderState

// Model to represent message content for search results
struct SearchMessageContent {
    let body: String?
    let sender: String?
    let timestamp: Date?
}

// Model to represent room summary for search results
struct SearchRoomSummary {
    let id: String
    let name: String
}

// Model to represent a search result item
struct SearchResultItem: Identifiable {
    let id = UUID()
    let roomId: String
    var roomName: String
    let eventId: String
    var content: String
    var sender: String
    var timestamp: String
}

// Model to represent room-grouped search results
struct RoomSearchResults: Identifiable {
    let id = UUID()
    let roomId: String
    var roomName: String
    var items: [SearchResultItem]
}

struct SearchModalView: View {
    @Environment(\.dismiss) private var dismiss
    
    @ObservedObject var context: HomeScreenViewModel.Context
    @State private var searchText = ""
    @FocusState private var isSearchFieldFocused: Bool
    
    @State private var searchResults: [RoomSearchResults] = []
    
    // Voice recording states
    @State private var isVoiceRecordingMode = false
    @ObservedObject var audioRecorderState: VoiceSearchRecorderState
    @State private var roomResults: [RoomSearchResults] = []
    @State private var isSendButtonPressed = false
    
    // Language selection
    @State private var currentLanguage: TranscriptionLanguage = AppSettings().searchLanguage
    @State private var showLanguageSelector = false
    
    // Answer field for search results
    @State private var answerText: String? = nil
    
    // Search results view
    private var searchResultsListView: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(roomResults) { roomResult in
                    VStack(alignment: .leading, spacing: 8) {
                        // Room header
                        Text(roomResult.roomName)
                            .font(.headline)
                            .padding(.horizontal)
                        
                        // Messages in this room
                        ForEach(roomResult.items) { item in
                            MessageResultView(item: item) {
                                // Handle tap on message - navigate to the room and message
                                context.send(viewAction: .selectRoom(roomIdentifier: item.roomId))
                                dismiss()
                            }
                            .padding(.horizontal)
                        }
                    }
                    .padding(.vertical, 8)
                    .background(Color.compound.bgSubtleSecondary)
                    .cornerRadius(8)
                }
            }
            .padding()
        }
    }
    
    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                // Main content area
                VStack {
                    if let answer = answerText, !answer.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Answer")
                                .font(.headline)
                                .padding(.horizontal)
                            
                            Text(answer)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.compound.bgSubtleSecondary)
                                .cornerRadius(8)
                                .padding(.horizontal)
                                .fixedSize(horizontal: false, vertical: true) // Allow text to expand vertically
                            
                            Divider()
                                .padding(.vertical, 8)
                            
                            Text("Search Results")
                                .font(.headline)
                                .padding(.horizontal)
                        }
                        .padding(.top)
                        // Show search results when we have a query
                        searchResultsListView
                    }
                }
                
                // Bottom input area - either voice recording or text input
                VStack {
                    Spacer()
                    HStack {
                        languageSelectorButton
                        Spacer()
                        if isVoiceRecordingMode {
                            // Voice recording view with waveform and controls
                            voiceRecordingBar
                        } else {
                            // Regular search bar
                            searchBar
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                }
            }
            .navigationTitle("Search Messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        // If in voice recording mode, cancel recording first
                        if isVoiceRecordingMode {
                            cancelVoiceRecording()
                        }
                        dismiss()
                    } label: {
                        Text("Cancel")
                    }
                }
            }
            .onAppear {
                // Track the search
                context.send(viewAction: .trackSearch(isSubmitted: false,
                                                      isVoiceSearch: nil,
                                                      queryLength: nil))
                
                // Start voice recording mode automatically when the view appears
                print("[SearchModalView] View appeared, starting voice recording")
                
                // Set up initial state
                isVoiceRecordingMode = true
                isSearchFieldFocused = false
                
                // Add a small delay to ensure the view and audio session are ready
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    // Start recording directly through audioRecorderState
                    audioRecorderState.startRecording()
                    
                    // Verify recording started
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        if !audioRecorderState.isRecording {
                            print("[SearchModalView] Recording didn't start, resetting state and trying again")
                            audioRecorderState.stopRecording()
                            audioRecorderState.startRecording()
                        }
                    }
                }
            }
            .onDisappear {
                // Clean up recording if needed
                if isVoiceRecordingMode {
                    cancelVoiceRecording()
                }
            }
        }
    }
    
    // MARK: - Subviews
    
    private var searchBar: some View {
        HStack {
            // Regular search field
            Image(systemName: "magnifyingglass")
                .foregroundColor(.gray)
            
            TextField("Search", text: $searchText)
                .focused($isSearchFieldFocused)
                .submitLabel(.search)
                .onSubmit {
                    print("[SearchModalView] Search submitted")
                    performSearch()
                    // Track the search
                    context.send(viewAction: .trackSearch(isSubmitted: true,
                                                          isVoiceSearch: false,
                                                          queryLength: searchText.count))
                }
            
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray)
                }
            } else {
                // Microphone button to switch to voice input
                Button {
                    startVoiceRecording()
                } label: {
                    Image(systemName: "mic")
                        .foregroundColor(.gray)
                        .padding(8)
                }
            }
        }
    }
    
    // Voice recording bar that appears at the bottom
    private var voiceRecordingBar: some View {
        // Use the VoiceSearchRecorder component to display the waveform
        VoiceSearchRecorder(recorderState: audioRecorderState,
                            onSwitchToKeyboard: switchToKeyboard,
                            onSearch: { transcript in
                                print("[SearchModalView] Using transcript for search: \(transcript)")
                                stopVoiceRecording(useTranscript: true)
                                performSearch()
                                // Track the search
                                context.send(viewAction: .trackSearch(isSubmitted: true,
                                                                      isVoiceSearch: true,
                                                                      queryLength: transcript.count))
                            })
    }

    /// A reusable language selector button component that shows a menu with available languages
    private var languageSelectorButton: some View {
        Menu {
            ForEach(TranscriptionLanguage.allCases, id: \.self) { language in
                Button(action: {
                    selectLanguage(language)
                }) {
                    HStack {
                        Text(language.displayName)
                        if language == currentLanguage {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Text(currentLanguage.shortCode)
                .font(.compound.bodySMSemibold)
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.blue)
                .cornerRadius(4)
        }
        .accessibilityLabel("Change search language: \(currentLanguage.displayName)")
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    private func processSearchResults(_ response: [String: Any]) {
        print("[SearchModalView] Processing search results: \(response)")
        
        // Extract the answer field if available
        if let answer = response["answer"] as? String, !answer.isEmpty {
            print("[SearchModalView] Found answer: \(answer)")
            answerText = answer
        } else {
            answerText = nil
            print("[SearchModalView] No answer field found in response")
        }
        
        // Extract contexts from the search response
        guard let contexts = response["contexts"] as? [[String: Any]] else {
            print("[SearchModalView] No contexts found in search response")
            return
        }
        
        // Create a dictionary to group results by room
        var roomResultsDict: [String: [SearchResultItem]] = [:]
        
        // Process each context (room)
        for context in contexts {
            guard let roomId = context["room_id"] as? String,
                  let eventIds = context["event_ids"] as? [String] else { continue }
            
            // Create placeholder items for each event ID
            let items = eventIds.map { eventId in
                SearchResultItem(roomId: roomId,
                                 roomName: getRoomName(roomId) ?? "",
                                 eventId: eventId,
                                 content: "Loading message content...",
                                 sender: "Unknown",
                                 timestamp: "")
            }
            
            // Add items to the room group
            if roomResultsDict[roomId] == nil {
                roomResultsDict[roomId] = items
            } else {
                roomResultsDict[roomId]?.append(contentsOf: items)
            }
        }
        
        // Convert dictionary to array of RoomSearchResults
        roomResults = roomResultsDict.map { roomId, items in
            RoomSearchResults(roomId: roomId,
                              roomName: getRoomName(roomId) ?? "",
                              items: items)
        }
        
        // Sort rooms by name
        roomResults.sort { $0.roomName < $1.roomName }
        
        // Load actual content for each message
        loadMessageContents()
    }
    
    private func loadMessageContents() {
        // For each room in the results
        for roomIndex in roomResults.indices {
            let roomResult = roomResults[roomIndex]
            
            // Get room summary to access room name
            Task {
                if let roomName = await getRoomSummary(roomId: roomResult.roomId) {
                    // Update room name with the actual room name from the SDK
                    DispatchQueue.main.async {
                        if roomIndex < roomResults.count {
                            roomResults[roomIndex].roomName = roomName
                        }
                    }
                }
                
                // For each message in the room
                for itemIndex in roomResults[roomIndex].items.indices {
                    // Safely access the item
                    guard roomIndex < roomResults.count,
                          itemIndex < roomResults[roomIndex].items.count else {
                        continue
                    }
                    
                    let item = roomResults[roomIndex].items[itemIndex]
                    
                    // Create a placeholder content with the context from the search result
                    // This ensures we at least show the content from the search result
                    let placeholderContent = SearchMessageContent(body: item.content,
                                                                  sender: item.sender.isEmpty ? "Unknown sender" : item.sender,
                                                                  timestamp: Date())
                    
                    // Try to load message content, but don't crash if it fails
                    if let messageContent = await getMessageContent(roomId: item.roomId, eventId: item.eventId) {
                        // Update the item with content
                        DispatchQueue.main.async {
                            guard roomIndex < roomResults.count,
                                  itemIndex < roomResults[roomIndex].items.count else {
                                return
                            }
                            
                            var updatedItem = item
                            updatedItem.content = messageContent.body ?? "[No content]"
                            updatedItem.sender = messageContent.sender ?? "Unknown"
                            
                            if let timestamp = messageContent.timestamp {
                                let formatter = DateFormatter()
                                formatter.dateStyle = .short
                                formatter.timeStyle = .short
                                updatedItem.timestamp = formatter.string(from: timestamp)
                            }
                            
                            // Update the item in the results array
                            roomResults[roomIndex].items[itemIndex] = updatedItem
                        }
                    } else {
                        // If loading fails, use the placeholder content
                        DispatchQueue.main.async {
                            guard roomIndex < roomResults.count,
                                  itemIndex < roomResults[roomIndex].items.count else {
                                return
                            }
                            
                            var updatedItem = item
                            updatedItem.content = placeholderContent.body ?? "[No content]"
                            updatedItem.sender = placeholderContent.sender ?? "Unknown"
                            
                            if let timestamp = placeholderContent.timestamp {
                                let formatter = DateFormatter()
                                formatter.dateStyle = .short
                                formatter.timeStyle = .short
                                updatedItem.timestamp = formatter.string(from: timestamp)
                            }
                            
                            // Update the item in the results array
                            roomResults[roomIndex].items[itemIndex] = updatedItem
                        }
                    }
                }
            }
        }
    }
    
    private func getRoomSummary(roomId: String) async -> String? {
        await withCheckedContinuation { continuation in
            context.send(viewAction: .getRoomInfo(roomId: roomId) { roomSummary in
                if let name = roomSummary?.name {
                    continuation.resume(returning: name)
                } else {
                    continuation.resume(returning: "Room \(roomId.prefix(8))")
                }
            })
        }
    }
    
    private func getMessageContent(roomId: String, eventId: String) async -> SearchMessageContent? {
        await withCheckedContinuation { continuation in
            context.send(viewAction: .getMessageContent(roomId: roomId, eventId: eventId) { timelineItemProxy in
                if let itemProxy = timelineItemProxy, case .event(let eventProxy) = itemProxy {
                    // Extract content from the timeline item proxy
                    let body: String
                    
                    // Handle different content types
                    if case let .message(messageContent) = eventProxy.content {
                        // Check if this is a refined STT message
                        if case .refinedStt = messageContent.msgType {
                            print("[SearchModalView] Found refined STT message: \(eventId)")
                            
                            // Try to parse the JSON content to extract the summary
                            if let jsonData = messageContent.body.data(using: .utf8),
                               let jsonDict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                                // Extract the summary if available
                                if let summary = jsonDict["summary"] as? String {
                                    body = summary
                                } else if let refinedTranscription = jsonDict["refined_transcription"] as? String {
                                    body = refinedTranscription
                                } else {
                                    // Fallback to the raw body if we can't extract the summary
                                    body = messageContent.body
                                }
                            } else {
                                // Fallback to the raw body if we can't parse the JSON
                                body = messageContent.body
                            }
                        } else {
                            // Regular message
                            body = messageContent.body
                        }
                    } else if case .sticker(let stickerBody, _, _) = eventProxy.content {
                        body = stickerBody
                    } else if case let .failedToParseMessageLike(eventType, _) = eventProxy.content {
                        body = "[Failed to parse message: \(eventType)]"
                    } else if case .redactedMessage = eventProxy.content {
                        body = "[Redacted message]"
                    } else {
                        body = "[Unsupported content type]"
                    }
                    
                    let searchContent = SearchMessageContent(body: body,
                                                             sender: eventProxy.sender.displayName ?? eventProxy.sender.id,
                                                             timestamp: eventProxy.timestamp)
                    continuation.resume(returning: searchContent)
                } else {
                    // Fallback to placeholder if message content can't be retrieved
                    // We'll use the event ID as a unique identifier in the placeholder
                    // This will at least show something useful to the user
                    let placeholder = SearchMessageContent(body: "[Message content unavailable]",
                                                           sender: "Unknown",
                                                           timestamp: Date())
                    continuation.resume(returning: placeholder)
                }
            })
        }
    }
    
    private func getRoomName(_ roomId: String) -> String? {
        // Use the room summary provider to get the room name
        // This is synchronous and used during initial processing of search results
        // For actual display, we use the async getRoomSummary method
        var roomName: String? = nil
        
        let semaphore = DispatchSemaphore(value: 0)
        context.send(viewAction: .getRoomInfo(roomId: roomId) { roomSummary in
            roomName = roomSummary?.name ?? "Room \(roomId.prefix(8))"
            semaphore.signal()
        })
        
        // Wait briefly for the room name, but don't block indefinitely
        _ = semaphore.wait(timeout: .now() + 0.1)
        return roomName
    }
    
    // MARK: - Voice Recording Methods
    
    /// Start voice recording for search
    private func startVoiceRecording() {
        print("[SearchModalView] startVoiceRecording called")
        isVoiceRecordingMode = true
        isSearchFieldFocused = false
        
        // Start recording directly instead of using context.send
        audioRecorderState.startRecording()
        
        // Force UI update
        DispatchQueue.main.async {
            print("[SearchModalView] Voice recording mode: \(isVoiceRecordingMode), Recording state: \(audioRecorderState.isRecording)")
        }
    }
    
    /// Stop voice recording and optionally use the transcript for search
    private func stopVoiceRecording(useTranscript: Bool) {
        print("[SearchModalView] stopVoiceRecording called, useTranscript: \(useTranscript)")
        
        // Instead of sending a view action, directly interact with the audioRecorderState
        // This avoids the potential EXC_BAD_ACCESS when using context.send
        
        // First capture the transcript if needed
        let capturedTranscript = useTranscript ? audioRecorderState.safeGetTranscript() : nil
        print("[SearchModalView] Captured transcript: \(capturedTranscript ?? "")")
        // Stop the recording directly
        audioRecorderState.stopRecording()
                
        // If we want to use the transcript for search, just set the searchText
        // The actual search will be triggered by the caller if needed
        if useTranscript {
            if let transcript = capturedTranscript, !transcript.isEmpty {
                print("[SearchModalView] Using transcript for search: \(transcript)")
                searchText = transcript
            } else {
                // No transcript available
                print("[SearchModalView] No transcript available for search")
                searchText = "I have nothing to search"
            }
        }
        print("[SearchModalView] searchText: \(searchText), isVoiceRecordingMode: \(isVoiceRecordingMode)")
    }
    
    /// Cancel voice recording without using the transcript
    private func cancelVoiceRecording() {
        // Cancel recording directly instead of using context.send
        audioRecorderState.stopRecording()
        audioRecorderState.currentTranscript = nil
    }
    
    /// Select a specific language, stop and restart recording if needed
    private func selectLanguage(_ language: TranscriptionLanguage) {
        print("[SearchModalView] Selecting language: \(language.displayName)")
        
        // If the selected language is the same as current, do nothing
        if language == currentLanguage {
            return
        }
        
        // Remember if we were recording
        let wasRecording = audioRecorderState.isRecording
        
        // Stop recording if active
        if wasRecording {
            // Stop recording without using transcript
            audioRecorderState.stopRecording()
        }
        
        // Update current language
        currentLanguage = language
        
        // Save the selected language to app settings
        let appSettings = AppSettings()
        appSettings.setSearchLanguage(language)

        audioRecorderState.reset()
        
        print("[SearchModalView] Changed language to: \(language.displayName)")
        
        // Restart recording if it was active
        if wasRecording {
            // Small delay to ensure the recording system has time to reset
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                audioRecorderState.startRecording()
            }
        }
    }
    
    /// Switch from voice recording to keyboard input
    private func switchToKeyboard() {
        // Stop recording but don't use the transcript
        stopVoiceRecording(useTranscript: false)
        
        // Focus the search field after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            isSearchFieldFocused = true
        }
    }
    
    /// Perform search with the current search text
    private func performSearch() {
        print("[SearchModalView] performSearch called with text: \(searchText)")
        guard !searchText.isEmpty else {
            print("[SearchModalView] Search text is empty, not performing search")
            return
        }
        
        // Always clear the transcript once we submit the search
        audioRecorderState.currentTranscript = nil
        
        // Perform search with current query
        print("[SearchModalView] Sending search request with query: \(searchText)")
        
        // First try to search for messages
        context.send(viewAction: .searchGlobally(query: searchText) { result in
            print("[SearchModalView] Search result received: \(result)")
            switch result {
            case .success(let response):
                DispatchQueue.main.async {
                    processSearchResults(response)
                }
            case .failure(let error):
                print("[SearchModalView] Search failed with error: \(error)")
            }
        })
        searchText = ""
        isVoiceRecordingMode = false
    }
}

// View for displaying a single message result
struct MessageResultView: View {
    let item: SearchResultItem
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.sender)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    Spacer()
                    
                    Text(item.timestamp)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Text(item.content)
                    .font(.body)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.compound.bgCanvasDefault)
            .cornerRadius(8)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct SearchModalView_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        let clientProxy = ClientProxyMock(.init())
        let userSession = UserSessionMock(.init(clientProxy: clientProxy))
        let viewModel = HomeScreenViewModel(userSession: userSession,
                                            analyticsService: ServiceLocator.shared.analytics,
                                            appSettings: ServiceLocator.shared.settings,
                                            selectedRoomPublisher: CurrentValueSubject<String?, Never>(nil).asCurrentValuePublisher(),
                                            userIndicatorController: ServiceLocator.shared.userIndicatorController)
        return SearchModalView(context: viewModel.context, audioRecorderState: VoiceSearchRecorderState.preview())
    }
}

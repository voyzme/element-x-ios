//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE in the repository root for full details.

import Combine

//

import Compound
import SwiftUI

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
    @State private var searchQuery = ""
    @State private var isSearching = false
    @State private var searchResult: [String: Any]?
    @State private var errorMessage: String?
    @State private var roomResults: [RoomSearchResults] = []
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // Search input field
                searchInputView
                
                // Content area
                if isSearching {
                    loadingView
                } else if let errorMessage {
                    errorView(errorMessage)
                } else if let searchResult {
                    searchResultsView(searchResult)
                }
                
                Spacer()
            }
            .padding(.top)
            .navigationTitle("Search Messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Cancel")
                    }
                }
            }
        }
    }
    
    // MARK: - Subviews
    
    private var searchInputView: some View {
        VStack(spacing: 16) {
            TextField("Search", text: $searchQuery)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding(.horizontal)
            
            Button {
                performSearch()
            } label: {
                Text("Search")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.compound(.primary))
            .padding(.horizontal)
            .disabled(searchQuery.isEmpty || isSearching)
        }
    }
    
    private var loadingView: some View {
        ProgressView()
            .padding()
    }
    
    private func errorView(_ message: String) -> some View {
        Text(message)
            .foregroundColor(.red)
            .padding()
    }
    
    private func searchResultsView(_ searchResult: [String: Any]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Search Results")
                    .font(.headline)
                    .padding(.horizontal)
                
                if let answer = searchResult["status"] as? String, answer == "success" {
                    answerView(searchResult)
                } else {
                    Text("No results found")
                        .padding()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    
    private func answerView(_ searchResult: [String: Any]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Display answer text if available
            if let answerText = searchResult["answer"] as? String {
                Text(answerText)
                    .padding()
                    .background(Color.compound.bgSubtleSecondary)
                    .cornerRadius(8)
                    .padding(.horizontal)
            }
            
            // Display event count and room results
            if let contexts = searchResult["contexts"] as? [[String: Any]] {
                let eventCount = contexts.reduce(0) { count, context in
                    if let eventIds = context["event_ids"] as? [String] {
                        return count + eventIds.count
                    }
                    return count
                }
                
                Text("Found in \(eventCount) messages across \(contexts.count) rooms")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                
                // Display search results grouped by room
                ForEach(roomResults) { roomResult in
                    roomResultView(roomResult)
                }
            }
        }
    }
    
    private func roomResultView(_ roomResult: RoomSearchResults) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(roomResult.roomName.isEmpty ? roomResult.roomId : roomResult.roomName)
                .font(.headline)
                .padding(.horizontal)
                .padding(.top, 8)
            
            ForEach(roomResult.items) { item in
                MessageResultView(item: item) {
                    // Navigate to the specific message in the room
                    dismiss()
                    context.send(viewAction: .selectRoom(roomIdentifier: roomResult.roomId))
                }
                .padding(.horizontal)
            }
        }
        .background(Color.compound.bgSubtleSecondary)
        .cornerRadius(8)
        .padding(.horizontal)
    }
    
    private func performSearch() {
        guard !searchQuery.isEmpty else { return }
        
        isSearching = true
        errorMessage = nil
        roomResults = []
        
        context.send(viewAction: .searchMessages(query: searchQuery) { result in
            DispatchQueue.main.async {
                isSearching = false
                
                switch result {
                case .success(let response):
                    searchResult = response
                    processSearchResults(response)
                case .failure(let error):
                    errorMessage = "Search failed: \(error.localizedDescription)"
                }
            }
        })
    }
    
    private func processSearchResults(_ response: [String: Any]) {
        // Extract contexts from the search response
        guard let contexts = response["contexts"] as? [[String: Any]] else {
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
                        body = messageContent.body
                    } else if case let .sticker(stickerContent) = eventProxy.content {
                        body = stickerContent.body
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
        return SearchModalView(context: viewModel.context)
    }
}

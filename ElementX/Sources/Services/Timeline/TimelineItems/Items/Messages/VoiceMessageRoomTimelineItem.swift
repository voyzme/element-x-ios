//
// Copyright 2023, 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE in the repository root for full details.
//

import Combine
import Foundation

class VoiceMessageRoomTimelineItem: EventBasedMessageTimelineItemProtocol, Equatable, ObservableObject {
    let id: TimelineItemIdentifier
    let timestamp: String
    let isOutgoing: Bool
    let isEditable: Bool
    let canBeRepliedTo: Bool
    let isThreaded: Bool
    let sender: TimelineItemSender
    
    @Published var content: AudioRoomTimelineItemContent
    
    var replyDetails: TimelineItemReplyDetails?

    var properties = RoomTimelineItemProperties()
    
    private var cancellables = Set<AnyCancellable>()
    
    var body: String {
        content.caption ?? content.filename
    }
    
    var contentType: EventBasedMessageTimelineItemContentType {
        .voice(content)
    }
    
    init(id: TimelineItemIdentifier,
         timestamp: String,
         isOutgoing: Bool,
         isEditable: Bool,
         canBeRepliedTo: Bool,
         isThreaded: Bool,
         sender: TimelineItemSender,
         content: AudioRoomTimelineItemContent,
         replyDetails: TimelineItemReplyDetails? = nil,
         properties: RoomTimelineItemProperties = RoomTimelineItemProperties()) {
        self.id = id
        self.timestamp = timestamp
        self.isOutgoing = isOutgoing
        self.isEditable = isEditable
        self.canBeRepliedTo = canBeRepliedTo
        self.isThreaded = isThreaded
        self.sender = sender
        self.content = content
        self.replyDetails = replyDetails
        self.properties = properties
        
        // Log the initialization of the voice message timeline item
        MXLog.debug("VoiceMessageRoomTimelineItem: Initialized with ID: \(id), eventID: \(id.eventID ?? "nil")")
        
        // Observe refined STT data from the RefinedSTTManager
        MXLog.debug("VoiceMessageRoomTimelineItem: About to call observeRefinedSTTData()")
        observeRefinedSTTData()
    }
    
    private func observeRefinedSTTData() {
        MXLog.debug("VoiceMessageRoomTimelineItem: observeRefinedSTTData() called")
        
        // Check if the RefinedSTTManager is available
        if let refinedSTTManager = ServiceLocator.shared.refinedSTTManager {
            MXLog.debug("VoiceMessageRoomTimelineItem: RefinedSTTManager is available, subscribing to refinedSTTDataPublisher")
            setupRefinedSTTDataObserver(refinedSTTManager)
        } else {
            MXLog.warning("VoiceMessageRoomTimelineItem: RefinedSTTManager not available, will try again later")
            
            // Set up a timer to check for the RefinedSTTManager periodically
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self else { return }
                MXLog.debug("VoiceMessageRoomTimelineItem: Checking for RefinedSTTManager again")
                self.observeRefinedSTTData()
            }
        }
    }
    
    private func setupRefinedSTTDataObserver(_ refinedSTTManager: RefinedSTTManagerProtocol) {
        MXLog.debug("VoiceMessageRoomTimelineItem: Setting up refined STT data observer")
        
        refinedSTTManager.refinedSTTDataPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] refinedSTTDataDict in
                guard let self = self else { return }
                
                // Check if there's refined STT data for this voice message
                if let eventID = self.id.eventID {
                    MXLog.debug("VoiceMessageRoomTimelineItem: Checking for refined STT data for voice message event ID: \(eventID)")
                    
                    // Log all available refined STT data for debugging
                    MXLog.debug("VoiceMessageRoomTimelineItem: Available refined STT data: \(refinedSTTDataDict.count)")
                    if let refinedSTTData = refinedSTTDataDict[eventID] {
                        MXLog.debug("VoiceMessageRoomTimelineItem: Found refined STT data for voice message: \(eventID)")
                        // Set both the raw refined STT body and the parsed data
                        self.content.refinedSttBody = refinedSTTData.refinedSttBody
                        self.content.refinedSTTData = refinedSTTData
                    }
                    
                    // Iterate through all refined STT data and check if any of them reference this voice message event ID
                    var found = false
                    for (_, refinedSTTData) in refinedSTTDataDict {
                        MXLog.debug("VoiceMessageRoomTimelineItem: Checking if refinedSTTData.referencedEventId: \(refinedSTTData.referencedEventId) matches voice message event ID: \(eventID)")
                        
                        if refinedSTTData.referencedEventId == eventID {
                            // Update the content with the refined STT data
                            var updatedContent = self.content
                            updatedContent.refinedSttBody = refinedSTTData.refinedSttBody
                            updatedContent.refinedSTTData = refinedSTTData
                            self.content = updatedContent
                            
                            MXLog.debug("VoiceMessageRoomTimelineItem: MATCH FOUND! Updated voice message with refined STT data: \(eventID)")
                            found = true
                            break
                        }
                    }
                    
                    if !found {
                        MXLog.debug("VoiceMessageRoomTimelineItem: No matching refined STT data found for voice message event ID: \(eventID)")
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    // Required for Equatable conformance
    static func == (lhs: VoiceMessageRoomTimelineItem, rhs: VoiceMessageRoomTimelineItem) -> Bool {
        lhs.id == rhs.id &&
            lhs.timestamp == rhs.timestamp &&
            lhs.isOutgoing == rhs.isOutgoing &&
            lhs.isEditable == rhs.isEditable &&
            lhs.canBeRepliedTo == rhs.canBeRepliedTo &&
            lhs.isThreaded == rhs.isThreaded &&
            lhs.sender == rhs.sender &&
            lhs.content == rhs.content &&
            lhs.replyDetails == rhs.replyDetails &&
            lhs.properties == rhs.properties
    }
}

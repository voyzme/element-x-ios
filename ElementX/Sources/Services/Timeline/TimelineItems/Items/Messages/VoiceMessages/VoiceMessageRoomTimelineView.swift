//
// Copyright 2023, 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE in the repository root for full details.
//

import Foundation
import SwiftUI

// Import necessary frameworks
import Foundation
import SwiftUI

struct VoiceMessageRoomTimelineView: View {
    @EnvironmentObject private var context: TimelineViewModel.Context
    @ObservedObject private var timelineItem: VoiceMessageRoomTimelineItem
    private let playerState: AudioPlayerState
    @State private var resumePlaybackAfterScrubbing = false
    
    // States for toggling between different views
    @State private var showTranscription = false
    @State private var showTopicsModal = false
    
    init(timelineItem: VoiceMessageRoomTimelineItem, playerState: AudioPlayerState) {
        self.timelineItem = timelineItem
        self.playerState = playerState
    }
    
    var body: some View {
        TimelineStyler(timelineItem: timelineItem) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    VoiceMessageRoomPlaybackView(playerState: playerState,
                                                 onPlayPause: onPlaybackPlayPause,
                                                 onSeek: { onPlaybackSeek($0) },
                                                 onScrubbing: { onPlaybackScrubbing($0) })
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 400)
                    
                    // Only show buttons if we have parsed data from the refined STT
                    if let refinedSTTData = timelineItem.content.refinedSTTData,
                       refinedSTTData.summary != nil || refinedSTTData.refinedTranscription != nil || refinedSTTData.topics != nil {
                        // Transcription toggle button
                        Button(action: {
                            withAnimation {
                                showTranscription.toggle()
                            }
                        }) {
                            Text("T")
                                .font(.system(size: 16, weight: .bold, design: .default))
                                .foregroundColor(showTranscription ? .white : .primary)
                                .frame(width: 25, height: 25)
                                .background(showTranscription ? Color.blue : Color.compound.bgSubtlePrimary)
                                .cornerRadius(8)
                                .padding(.leading, 8)
                        }
                        
                        // Summary/topics button
                        /*
                         Button(action: {
                             showTopicsModal = true
                         }) {
                             Text("S")
                                 .font(.system(size: 16, weight: .bold, design: .default))
                                 .foregroundColor(.primary)
                                 .frame(width: 25, height: 25)
                                 .background(Color.compound.bgSubtlePrimary)
                                 .cornerRadius(8)
                         }
                         */
                    }
                }
                
                // Display refined STT content if available
                if let refinedSTTData = timelineItem.content.refinedSTTData {
                    Group {
                        if let summary = refinedSTTData.summary, let refinedTranscription = refinedSTTData.refinedTranscription {
                            // Display either summary or refined transcription based on toggle state
                            ScrollView {
                                Text(showTranscription ? refinedTranscription : summary)
                                    .font(.compound.bodyMD)
                                    .foregroundColor(.compound.textPrimary)
                                    .padding(8)
                            }
                            .frame(maxHeight: 150) // Set maximum height for the scroll view
                            .background(Color.compound.bgSubtleSecondary)
                            .cornerRadius(8)
                            .transition(.opacity)
                        } else if let summary = refinedSTTData.summary {
                            // Only summary available
                            ScrollView {
                                Text(summary)
                                    .font(.compound.bodyMD)
                                    .foregroundColor(.compound.textPrimary)
                                    .padding(8)
                            }
                            .frame(maxHeight: 150) // Set maximum height for the scroll view
                            .background(Color.compound.bgSubtleSecondary)
                            .cornerRadius(8)
                        } else if let refinedTranscription = refinedSTTData.refinedTranscription {
                            // Only refined transcription available
                            ScrollView {
                                Text(refinedTranscription)
                                    .font(.compound.bodyMD)
                                    .foregroundColor(.compound.textPrimary)
                                    .padding(8)
                            }
                            .frame(maxHeight: 150) // Set maximum height for the scroll view
                            .background(Color.compound.bgSubtleSecondary)
                            .cornerRadius(8)
                        } else {
                            // Fallback to displaying raw refined STT body
                            ScrollView {
                                Text(refinedSTTData.refinedSttBody)
                                    .font(.compound.bodyMD)
                                    .foregroundColor(.compound.textPrimary)
                                    .padding(8)
                            }
                            .frame(maxHeight: 150) // Set maximum height for the scroll view
                            .background(Color.compound.bgSubtleSecondary)
                            .cornerRadius(8)
                        }
                    }
                } else {
                    ScrollView {
                        Text("Processing voice message...")
                            .font(.compound.bodyMD)
                            .foregroundColor(.compound.textPrimary)
                            .padding(8)
                    }
                    .frame(maxHeight: 150) // Set maximum height for the scroll view
                    .background(Color.compound.bgSubtleSecondary)
                    .cornerRadius(8)
                }
            }
            .sheet(isPresented: $showTopicsModal) {
                if let refinedSTTData = timelineItem.content.refinedSTTData, let topics = refinedSTTData.topics {
                    TopicsModalView(topics: topics, timelineItem: timelineItem, context: context)
                }
            }
        }
    }
    
    private func onPlaybackPlayPause() {
        context.send(viewAction: .handleAudioPlayerAction(.playPause(itemID: timelineItem.id)))
    }
    
    private func onPlaybackSeek(_ progress: Double) {
        context.send(viewAction: .handleAudioPlayerAction(.seek(itemID: timelineItem.id, progress: progress)))
    }
    
    private func onPlaybackScrubbing(_ dragging: Bool) {
        if dragging {
            if playerState.playbackState == .playing {
                resumePlaybackAfterScrubbing = true
                context.send(viewAction: .handleAudioPlayerAction(.playPause(itemID: timelineItem.id)))
            }
        } else if resumePlaybackAfterScrubbing {
            resumePlaybackAfterScrubbing = false
            context.send(viewAction: .handleAudioPlayerAction(.playPause(itemID: timelineItem.id)))
        }
    }
}

// Response button component for emoji buttons
struct ResponseButton: View {
    let response: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(response)
                .font(.system(size: 20))
                .padding(8)
                .background(isSelected ? Color.compound.bgSubtlePrimary : Color.clear)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.blue : Color.gray.opacity(0.3), lineWidth: 1)
                )
        }
        .buttonStyle(BorderlessButtonStyle())
    }
}

// Topic section component with topic box and emoji response buttons
struct TopicSection: View {
    let topic: RefinedSTTData.Topic
    let timelineItem: VoiceMessageRoomTimelineItem
    let context: TimelineViewModel.Context
    let selectedResponse: String?
    let onResponseSelected: (String) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Topic box with original case
            VStack(alignment: .leading, spacing: 12) {
                // Topic text
                Text(topic.topic)
                    .font(.body)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                // Emoji response buttons in a row at the bottom right
                HStack {
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach(topic.responses, id: \.self) { response in
                            ResponseButton(response: response,
                                           isSelected: selectedResponse == response,
                                           action: {
                                               // Create reply draft with the selected response
                                               // Include the topic name in the reply text to make it clear what the voice message was about
                                               let replyText = "Re: \(topic.topic) → \(response)"
                                    
                                               // First start replying to the message
                                               context.send(viewAction: .handleTimelineItemMenuAction(itemID: timelineItem.id,
                                                                                                      action: .reply(isThread: false)))
                                    
                                               // Wait a moment for the reply to be set up, then set the text
                                               DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                                   // Set the draft text using notification
                                                   NotificationCenter.default.post(name: Notification.Name("ElementX.SetDraftText"),
                                                                                   object: nil,
                                                                                   userInfo: ["text": replyText])
                                               }
                                    
                                               // Notify parent about selection
                                               onResponseSelected(response)
                                           })
                        }
                    }
                }
            }
            .padding(12)
            .background(Color.compound.bgSubtlePrimary)
            .cornerRadius(8)
        }
    }
}

// Modal view for displaying topics and responses
struct TopicsModalView: View {
    let topics: [RefinedSTTData.Topic]
    let timelineItem: VoiceMessageRoomTimelineItem
    let context: TimelineViewModel.Context
    @State private var selectedResponse: String? = nil
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(topics) { topic in
                        TopicSection(topic: topic,
                                     timelineItem: timelineItem,
                                     context: context,
                                     selectedResponse: selectedResponse,
                                     onResponseSelected: { response in
                                         // Show feedback
                                         selectedResponse = response
                                
                                         // Dismiss the modal after a short delay
                                         DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                             presentationMode.wrappedValue.dismiss()
                                         }
                                     })
                    }
                }
                .padding(16)
            }
            .navigationTitle("Topics")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct VoiceMessageRoomTimelineView_Previews: PreviewProvider, TestablePreview {
    static let viewModel = TimelineViewModel.mock
    static let timelineItemIdentifier = TimelineItemIdentifier.randomEvent
    static let voiceRoomTimelineItem = VoiceMessageRoomTimelineItem(id: timelineItemIdentifier,
                                                                    timestamp: "Now",
                                                                    isOutgoing: false,
                                                                    isEditable: false,
                                                                    canBeRepliedTo: true,
                                                                    isThreaded: false,
                                                                    sender: .init(id: "Bob"),
                                                                    content: .init(filename: "audio.ogg",
                                                                                   duration: 300,
                                                                                   waveform: EstimatedWaveform.mockWaveform,
                                                                                   source: nil,
                                                                                   contentType: nil))
    
    static let playerState = AudioPlayerState(id: .timelineItemIdentifier(timelineItemIdentifier),
                                              title: L10n.commonVoiceMessage,
                                              duration: 10.0,
                                              waveform: EstimatedWaveform.mockWaveform,
                                              progress: 0.4)
    
    static var previews: some View {
        body.environmentObject(viewModel.context)
            .previewDisplayName("Bubble")
    }
    
    static var body: some View {
        VoiceMessageRoomTimelineView(timelineItem: voiceRoomTimelineItem, playerState: playerState)
            .fixedSize(horizontal: false, vertical: true)
    }
}

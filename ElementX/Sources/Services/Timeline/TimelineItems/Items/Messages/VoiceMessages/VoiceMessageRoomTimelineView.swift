//
// Copyright 2023, 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE in the repository root for full details.
//

import Foundation
import SwiftUI

struct VoiceMessageRoomTimelineView: View {
    @EnvironmentObject private var context: TimelineViewModel.Context
    @ObservedObject private var timelineItem: VoiceMessageRoomTimelineItem
    private let playerState: AudioPlayerState
    @State private var resumePlaybackAfterScrubbing = false
    
    // States for toggling between different views
    @State private var showTranscription = false
    @State private var currentSummaryIndex = 0
    
    init(timelineItem: VoiceMessageRoomTimelineItem, playerState: AudioPlayerState) {
        self.timelineItem = timelineItem
        self.playerState = playerState
    }
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Main content
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
                           refinedSTTData.summaries != nil || refinedSTTData.refinedTranscription != nil {
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
                                // Navigation buttons for summaries as part of the scroll view
                            }
                        }
                    }
                    
                    // Display refined STT content if available
                    if let refinedSTTData = timelineItem.content.refinedSTTData {
                        Group {
                            if let summaries = refinedSTTData.summaries, let refinedTranscription = refinedSTTData.refinedTranscription {
                                // Display either summary or refined transcription based on toggle state
                                Group {
                                    if showTranscription {
                                        // Show transcription
                                        ScrollView {
                                            Text(refinedTranscription)
                                                .font(.compound.bodyMD)
                                                .foregroundColor(.compound.textPrimary)
                                                .padding(8)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .frame(maxHeight: 150)
                                        .frame(maxWidth: 300)
                                        .background(Color.compound.bgSubtleSecondary)
                                        .cornerRadius(8)
                                    } else if let summaries = refinedSTTData.summaries, !summaries.isEmpty {
                                        // Show summary
                                        ScrollView {
                                            Text(summaries[min(currentSummaryIndex, summaries.count - 1)])
                                                .font(.compound.bodyMD)
                                                .foregroundColor(.compound.textPrimary)
                                                .padding(8)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .frame(maxHeight: 150)
                                        .frame(maxWidth: 300)
                                        .background(Color.compound.bgSubtleSecondary)
                                        .cornerRadius(8)
                                    }
                                }
                                
                                // Navigation buttons for summaries below the scroll view
                                if summaries.count > 1, !showTranscription {
                                    HStack {
                                        Spacer()
                                        SummaryNavigationButtons(currentIndex: $currentSummaryIndex, summariesCount: summaries.count)
                                            .padding(.top, -10)
                                            .padding(.trailing, 2)
                                    }
                                }
                            } else if let refinedTranscription = refinedSTTData.refinedTranscription {
                                // Only refined transcription available
                                ScrollView {
                                    Text(refinedTranscription)
                                        .font(.compound.bodyMD)
                                        .foregroundColor(.compound.textPrimary)
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
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
                                        .frame(maxWidth: .infinity, alignment: .leading)
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
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 150) // Set maximum height for the scroll view
                        .background(Color.compound.bgSubtleSecondary)
                        .cornerRadius(8)
                    }
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

// Custom floating button component for summary navigation
struct SummaryNavigationButtons: View {
    @Binding var currentIndex: Int
    let summariesCount: Int
    
    var body: some View {
        HStack(spacing: 8) {
            // Minus button to move to previous summary
            if currentIndex > 0 {
                Button(action: {
                    if currentIndex > 0 {
                        currentIndex -= 1
                    }
                }) {
                    Image(systemName: "minus.circle.fill")
                        .resizable()
                        .frame(width: 28, height: 28)
                        .foregroundColor(.compound.iconPrimary)
                        .background(Color.white.opacity(0.8))
                        .clipShape(Circle())
                }
            }
            
            // Plus button to move to next summary
            Button(action: {
                if currentIndex < summariesCount - 1 {
                    currentIndex += 1
                }
            }) {
                Image(systemName: "plus.circle.fill")
                    .resizable()
                    .frame(width: 28, height: 28)
                    .foregroundColor(.compound.iconPrimary)
                    .background(Color.white.opacity(0.8))
                    .clipShape(Circle())
            }
            .disabled(currentIndex >= summariesCount - 1)
            .opacity(currentIndex >= summariesCount - 1 ? 0.5 : 1.0)
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

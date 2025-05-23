//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE in the repository root for full details.
//

import Compound
import DSWaveformImage
import DSWaveformImageViews
import SwiftUI

/// A view that displays voice message recording with contact routing functionality
struct VoiceContactRoutingView: View {
    @Environment(\.dismiss) private var dismiss
    
    // MARK: - Properties
    
    @ObservedObject var context: HomeScreenViewModel.Context
    @ObservedObject var recorderState: VoiceSearchRecorderState
    
    // State for suggested contacts
    @State private var suggestedRooms: [SuggestedRoom] = []
    @State private var isProcessingTranscript = false
    @State private var lastProcessedTranscript = ""
    @State private var processingTimer: Timer?
    @State private var showSendButtons = false
    @State private var currentTranscript = ""
    @State private var currentLanguage: TranscriptionLanguage = AppSettings().searchLanguage
    
    // Recording UI properties
    private static let elapsedTimeFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "mm:ss"
        return dateFormatter
    }()
    
    private var formattedDuration: String {
        Self.elapsedTimeFormatter.string(from: Date(timeIntervalSinceReferenceDate: recorderState.duration))
    }
    
    private var configuration: Waveform.Configuration {
        .init(style: .striped(.init(color: .compound.iconSecondary, width: 2, spacing: 2)),
              verticalScalingFactor: 1.0)
    }
    
    // MARK: - View
    
    private var suggestedRoomsSection: some View {
        Group {
            if showSendButtons, !suggestedRooms.isEmpty {
                VStack(spacing: 8) {
                    // Take top 3 rooms sorted by score (ascending order - highest at bottom)
                    ForEach(Array(suggestedRooms.sorted(by: { $0.score > $1.score }).prefix(3)).reversed(), id: \.id) { room in
                        roomButton(for: room, isHighestRated: room.score == suggestedRooms.map(\.score).max())
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
                    .background(Color.compound.bgSubtleSecondary)
                    .cornerRadius(8)
                }
            }
        }
        .padding(.top, 24)
        .padding(.horizontal)
    }
    
    private func roomButton(for room: SuggestedRoom, isHighestRated: Bool) -> some View {
        Button(action: { sendToRoom(room) }) {
            HStack {
                Text(context.viewState.rooms.first(where: { $0.id == room.roomId })?.name ?? room.roomId)
                    .font(isHighestRated ? .compound.bodySMSemibold : .compound.bodySM)
                    .foregroundColor(.compound.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundColor(.compound.iconSecondary)
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(10)
            .frame(height: 15)
        }
    }
    
    private var stopButton: some View {
        Button {
            context.send(viewAction: .stopVoiceRecording(useTranscript: true))
            processCurrentTranscript()
        } label: {
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 24))
                .foregroundColor(.compound.iconPrimary)
        }
    }
    
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
                .background(Color.compound.iconAccentTertiary)
                .cornerRadius(4)
        }
    }
    
    private var recordingControlsSection: some View {
        HStack(spacing: 16) {
            languageSelectorButton
            recordingIndicator
            waveformView
            Spacer()
            HStack(spacing: 16) {
                stopButton
                cancelButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.compound.bgCanvasDefault)
        .cornerRadius(8)
    }
    
    private var recordingIndicator: some View {
        HStack(spacing: 8) {
            RecordingIndicator()
                .frame(width: 8, height: 8)
            
            Text(formattedDuration)
                .lineLimit(1)
                .font(.compound.bodySMSemibold)
                .foregroundColor(.compound.textSecondary)
                .monospacedDigit()
                .fixedSize()
        }
    }
    
    private var waveformView: some View {
        WaveformLiveCanvas(samples: recorderState.waveformSamples,
                           configuration: configuration)
            .frame(height: 20)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
    }
    
    private var cancelButton: some View {
        Button {
            context.send(viewAction: .cancelVoiceRecording)
            dismiss()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 24))
                .foregroundColor(.compound.iconSecondary)
        }
    }
    
    var body: some View {
        VStack(spacing: 8) {
            suggestedRoomsSection
            Spacer()
            recordingControlsSection
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .onAppear {
            // Start a timer to process transcripts every 2 seconds while recording
            processingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                if recorderState.isRecording {
                    currentTranscript = recorderState.safeGetTranscript() ?? ""
                    processCurrentTranscript()
                }
            }
        }
        .onDisappear {
            processingTimer?.invalidate()
            processingTimer = nil
        }
    }
    
    // MARK: - Private methods
    
    private func selectLanguage(_ language: TranscriptionLanguage) {
        // Stop the recording
        recorderState.stopRecording()
        
        // Update current language
        currentLanguage = language
        // Update recorder state's language
        recorderState.transcriptionLanguage = language.rawValue
        // Update app settings through context
        let appSettings = AppSettings()
        appSettings.setSearchLanguage(language)
        // Reset the recorder state
        recorderState.reset()
        // Restart the recording
        recorderState.startRecording()
    }
    
    /// Process the current transcript to find suggested contacts
    private func processCurrentTranscript() {
        // Get the current transcript from the recorder state
        let transcript = recorderState.safeGetTranscript() ?? ""
        
        // Skip if we're already processing or have processed this transcript
        guard !transcript.isEmpty,
              transcript != lastProcessedTranscript,
              !isProcessingTranscript else {
            return
        }
        
        // Update the current transcript for display
        currentTranscript = transcript
        
        // Mark as processing to avoid duplicate requests
        isProcessingTranscript = true
        lastProcessedTranscript = transcript
        
        // Use the context to route contacts instead of directly accessing userSession
        context.send(viewAction: .routeContacts(messageContent: transcript) { result in
            Task { @MainActor in
                
                switch result {
                case .success(let rooms):
                    // Update UI with the contacts
                    suggestedRooms = rooms
                    showSendButtons = !rooms.isEmpty
                    isProcessingTranscript = false
                    
                case .failure(let error):
                    // Handle errors
                    MXLog.error("Contact routing failed: \(error)")
                    isProcessingTranscript = false
                }
            }
        })
    }
    
    /// Send the voice message to the selected contact
    private func sendToRoom(_ room: SuggestedRoom) {
        // First, stop recording but keep the recording file
        context.send(viewAction: .stopVoiceRecording(useTranscript: true))
        
        // Get the transcript to send
        let messageText = currentTranscript.isEmpty ? "Hello" : currentTranscript
        
        // Show loading indicator
        let loadingIndicator = UserIndicator(type: .modal, title: "Sending message...", persistent: true)
        // Add the loading indicator
        context.send(viewAction: .showIndicator(loadingIndicator))
        
        // Send directly to the existing room
        sendVoiceMessageAndNavigate(roomId: room.roomId, transcript: messageText, loadingIndicator: loadingIndicator)
        dismiss()
    }
    
    /// Send a voice message to a room and navigate to it
    private func sendVoiceMessageAndNavigate(roomId: String, transcript: String, loadingIndicator: UserIndicator) {
        // Update loading indicator
        context.send(viewAction: .hideIndicator(loadingIndicator))
        let sendingIndicator = UserIndicator(type: .modal, title: "Sending voice message...", persistent: true)
        context.send(viewAction: .showIndicator(sendingIndicator))
        
        // Send the voice message
        context.send(viewAction: .sendVoiceMessageToRoom(roomId: roomId, transcript: transcript) { result in
            // Hide the sending indicator
            context.send(viewAction: .hideIndicator(sendingIndicator))
            
            switch result {
            case .success:
                // Navigate to the room
                navigateToRoom(roomId: roomId)
            case .failure(let error):
                MXLog.error("Failed to send voice message: \(error)")
                // Show error message but still navigate to the room
                let errorIndicator = UserIndicator(type: .toast, title: "Failed to send voice message", persistent: false)
                context.send(viewAction: .showIndicator(errorIndicator))
                navigateToRoom(roomId: roomId)
            }
        })
    }
    
    /// Navigate to the selected room
    private func navigateToRoom(roomId: String) {
        // Navigate to the room
        context.send(viewAction: .selectRoom(roomIdentifier: roomId))
    }
}

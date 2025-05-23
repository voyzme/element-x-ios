//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE in the repository root for full details.
//

import Combine
import DSWaveformImage
import DSWaveformImageViews
import Foundation
import MatrixRustSDK
import SwiftUI

// We need this for the AudioRecorderState class

/// A view that displays the voice recording interface for search
struct VoiceSearchRecorder: View {
    @ObservedObject var recorderState: VoiceSearchRecorderState
    @State private var isRecording = false
    
    var onSwitchToKeyboard: () -> Void
    var onSearch: (String) -> Void
    
    @ScaledMetric private var waveformLineWidth = 2.0
    @ScaledMetric private var waveformLinePadding = 2.0
    @ScaledMetric private var recordingIndicatorSize = 8
    
    private static let elapsedTimeFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "mm:ss"
        return dateFormatter
    }()
    
    private var timeLabelContent: String {
        Self.elapsedTimeFormatter.string(from: Date(timeIntervalSinceReferenceDate: recorderState.duration))
    }
    
    private var configuration: Waveform.Configuration {
        .init(style: .striped(.init(color: .compound.iconSecondary, width: 2, spacing: 2)),
              verticalScalingFactor: 1.0)
    }
    
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                // Recording indicator and time
                HStack(spacing: 8) {
                    RecordingIndicator()
                        .frame(width: recordingIndicatorSize, height: recordingIndicatorSize)
                    
                    Text(timeLabelContent)
                        .lineLimit(1)
                        .font(.compound.bodySMSemibold)
                        .foregroundColor(.compound.textSecondary)
                        .monospacedDigit()
                        .fixedSize()
                }
                
                // Waveform
                WaveformLiveCanvas(samples: recorderState.waveformSamples,
                                   configuration: configuration)
                    .frame(height: 20)
                
                Spacer()
                
                // Switch to keyboard button
                Button(action: onSwitchToKeyboard) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 20))
                        .foregroundColor(.compound.textSecondary)
                }
                .accessibilityLabel("Switch to keyboard")
                
                // Search button
                Button(action: {
                    if let transcript = recorderState.currentTranscript, !transcript.isEmpty {
                        onSearch(transcript)
                    }
                }) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20))
                        .foregroundColor(.compound.textPrimary)
                }
                .accessibilityLabel("Search with voice recording")
                .disabled(recorderState.currentTranscript?.isEmpty ?? true)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.compound.bgCanvasDefault)
            .cornerRadius(8)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

/// A pulsing recording indicator
struct RecordingIndicator: View {
    @State private var opacity: CGFloat = 0
    
    var body: some View {
        Circle()
            .foregroundColor(.red)
            .opacity(opacity)
            .onAppear {
                withElementAnimation(.easeOut(duration: 1).repeatForever(autoreverses: true)) {
                    opacity = 1
                }
            }
    }
}

// AudioRecorderState is now in a separate file

#Preview {
    VStack {
        Spacer()
        VoiceSearchRecorder(recorderState: VoiceSearchRecorderState.preview(),
                            onSwitchToKeyboard: { },
                            onSearch: { _ in })
    }
    .background(Color.gray.opacity(0.2))
}

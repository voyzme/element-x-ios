//
// Copyright 2023, 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE in the repository root for full details.
//

import Compound
import Foundation
import SwiftUI

struct VoiceMessageRecordingComposer: View {
    @ObservedObject var recorderState: AudioRecorderState
    let languageCode: String
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            VoiceMessageRecordingView(recorderState: recorderState)
                .padding(.vertical, 8.0)
                .padding(.horizontal, 12.0)
                .background {
                    let roundedRectangle = RoundedRectangle(cornerRadius: 12)
                    ZStack {
                        roundedRectangle
                            .fill(Color.compound.bgSubtleSecondary)
                    }
                }
            
            languageCodeBadge
                .padding(.top, -16)
                .padding(.leading, -2)
        }
    }

    private var languageCodeBadge: some View {
        Text(languageCode)
            .font(.compound.bodySMSemibold)
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.compound.iconAccentTertiary)
            .cornerRadius(4)
            .accessibilityLabel("Voice message language: \(languageCode)")
    }
}

struct VoiceMessageRecordingComposer_Previews: PreviewProvider, TestablePreview {
    static let recorderState = AudioRecorderState()
    
    static var previews: some View {
        VoiceMessageRecordingComposer(recorderState: recorderState, languageCode: "en")
            .fixedSize(horizontal: false, vertical: true)
    }
}

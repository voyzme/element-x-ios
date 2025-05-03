//
// Copyright 2023, 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE in the repository root for full details.
//

import Compound
import SwiftUI

struct KeyboardButton: View {
    @ObservedObject var context: ComposerToolbarViewModel.Context
    
    var body: some View {
        Button(action: {
            // Cancel any active voice recording
            if case .recordVoiceMessage = context.viewState.composerMode {
                context.send(viewAction: .voiceMessage(.deleteRecording))
            }
            
            // Set the composer mode to default (text input)
            if context.viewState.composerMode != .default {
                context.send(viewAction: .cancelReply)
                context.send(viewAction: .cancelEdit)
            }
            
            // Deactivate voice message mode
            if case .recordVoiceMessage = context.viewState.composerMode {
                // This will switch from voice message mode to text input mode
                context.send(viewAction: .voiceMessage(.deleteRecording))
            }
            
            // Clear any existing text and prepare for text input
            context.plainComposerText = NSAttributedString(string: "")
            
            // Force switch to text input mode
            context.send(viewAction: .composerAppeared)
            
            // Force focus with a delay to ensure the keyboard appears
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                context.composerFocused = true
            }
            
            // Send another focus command after a slightly longer delay as a backup
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                context.composerFocused = true
            }
        }) {
            ZStack {
                Circle()
                    .fill(Color.compound.bgSubtleSecondary)
                    .frame(width: 44, height: 44)
                    
                CompoundIcon(\.keyboard)
                    .scaledToFit()
                    .scaledFrame(size: 24, relativeTo: .title)
            }
        }
        .accessibilityLabel("Keyboard")
        .accessibilityIdentifier("KeyboardButton")
    }
}

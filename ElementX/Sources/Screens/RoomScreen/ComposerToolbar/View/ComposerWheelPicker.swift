//
// Copyright 2023, 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE in the repository root for full details.
//

import Compound
import SwiftUI

// ComposerWheelOption is now defined in ComposerWheelOption.swift

struct ComposerWheelPicker: View {
    @Binding var selectedOption: ComposerWheelOption
    let onSelect: (ComposerWheelOption) -> Void
    
    // For tracking the drag gesture
    @State private var offset: CGFloat = 0
    @State private var isDragging = false
    
    // Constants for the wheel picker
    private let itemWidth: CGFloat = 60
    private let itemHeight: CGFloat = 44
    private let dragThreshold: CGFloat = 30
    
    var body: some View {
        ZStack {
            // Background for the wheel
            RoundedRectangle(cornerRadius: 22)
                .fill(Color.compound.bgSubtleSecondary)
                .frame(width: itemWidth, height: itemHeight)
            
            // The selected option
            Button {
                onSelect(selectedOption)
            } label: {
                CompoundIcon(selectedOption.icon, size: .custom(30), relativeTo: .title)
                    .scaledPadding(7, relativeTo: .title)
            }
            .accessibilityLabel(selectedOption.accessibilityLabel)
            .accessibilityIdentifier(selectedOption.accessibilityIdentifier)
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    isDragging = true
                    offset = value.translation.width
                }
                .onEnded { _ in
                    isDragging = false
                    
                    // Determine if we should change the selected option
                    if abs(offset) > dragThreshold {
                        let direction = offset > 0 ? -1 : 1
                        let allOptions = ComposerWheelOption.allCases
                        let currentIndex = allOptions.firstIndex(of: selectedOption) ?? 0
                        let newIndex = (currentIndex + direction + allOptions.count) % allOptions.count
                        selectedOption = allOptions[newIndex]
                        
                        // Provide haptic feedback
                        let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
                        impactFeedback.impactOccurred()
                        
                        // Notify the parent
                        onSelect(selectedOption)
                    }
                    
                    // Reset the offset
                    offset = 0
                }
        )
        .animation(.spring(response: 0.3), value: selectedOption)
        .animation(.spring(response: 0.3), value: isDragging)
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var selectedOption: ComposerWheelOption = .voiceMessage
        
        var body: some View {
            ComposerWheelPicker(selectedOption: $selectedOption) { option in
                print("Selected option: \(option)")
            }
            .padding()
            .previewLayout(.sizeThatFits)
        }
    }
    
    return PreviewWrapper()
}

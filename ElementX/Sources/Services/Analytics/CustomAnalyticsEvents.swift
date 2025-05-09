//
// Copyright 2024 VoiceDrop
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE in the repository root for full details.
//

import AnalyticsEvents
import Foundation

extension AnalyticsEvent {
    /// Event for tracking voice messages
    struct VoiceMessage: AnalyticsEventProtocol {
        let eventName = "VoiceMessage"
        let inThread: Bool
        let isReply: Bool
        let durationSeconds: Double?
        let startsThread: Bool?
        
        var properties: [String: Any] {
            var props: [String: Any] = [
                "inThread": inThread,
                "isReply": isReply
            ]
            
            if let durationSeconds = durationSeconds {
                props["durationSeconds"] = durationSeconds
            }
            
            if let startsThread = startsThread {
                props["startsThread"] = startsThread
            }
            
            return props
        }
    }
    
    /// Event for tracking text messages
    struct TextMessage: AnalyticsEventProtocol {
        let eventName = "TextMessage"
        let inThread: Bool
        let isEditing: Bool
        let isReply: Bool
        let startsThread: Bool?
        
        var properties: [String: Any] {
            var props: [String: Any] = [
                "inThread": inThread,
                "isEditing": isEditing,
                "isReply": isReply
            ]
            
            if let startsThread = startsThread {
                props["startsThread"] = startsThread
            }
            
            return props
        }
    }
}

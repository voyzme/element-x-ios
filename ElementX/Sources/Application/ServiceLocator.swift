//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE in the repository root for full details.
//

import Combine
import Foundation

/// Data structure to hold refined STT information for voice messages
struct RefinedSTTData: Hashable {
    /// The event ID of the transcription event
    let eventId: String
    
    /// The event ID of the referenced audio message
    let referencedEventId: String
    
    /// The raw refined STT body text
    let refinedSttBody: String
    
    /// Timestamp when the transcription was created
    let timestamp: Date
    
    /// Parsed summaries from the JSON, if available
    let summaries: [String]?
    
    /// Parsed refined transcription from the JSON, if available
    let refinedTranscription: String?
    
    init(eventId: String, referencedEventId: String, refinedSttBody: String, timestamp: Date) {
        self.eventId = eventId
        self.referencedEventId = referencedEventId
        self.refinedSttBody = refinedSttBody
        self.timestamp = timestamp
        
        // Parse JSON if possible
        let parsedData = Self.parseJSON(refinedSttBody)
        summaries = parsedData.summaries
        refinedTranscription = parsedData.refinedTranscription
    }
    
    /// Parse the JSON refined STT body to extract structured data
    private static func parseJSON(_ json: String) -> (summaries: [String]?, refinedTranscription: String?) {
        guard !json.isEmpty, let jsonData = json.data(using: .utf8) else {
            return (nil, nil)
        }
        
        do {
            // Use JSONSerialization for better performance
            if let parsedJSON = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                // Extract refined transcription - now under "refined_text" key
                let refinedTranscription = parsedJSON["refined_text"] as? String
                
                // Extract summaries array
                let summaries = parsedJSON["summaries"] as? [String]
                
                return (summaries, refinedTranscription)
            }
        } catch {
            #if DEBUG
            print("Failed to parse transcription JSON: \(error)")
            #endif
        }
        
        return (nil, nil)
    }
    
    /// Get the primary summary (first one) for backward compatibility
    var summary: String? {
        summaries?.first
    }
    
    /// Topic structure for voice message topics
    struct Topic: Hashable, Identifiable {
        let id = UUID()
        let text: String
        let responses: [String]
        
        init(text: String, responses: [String] = ["👍", "👎", "🤔"]) {
            self.text = text
            self.responses = responses
        }
    }
    
    /// Parsed topics from the JSON, if available
    var topics: [Topic]? {
        // For now, if we have summaries, create topics from them
        // In the future, this would parse actual topics from the JSON
        summaries?.map { Topic(text: $0) }
    }
}

protocol RefinedSTTManagerProtocol {
    /// Add a new refined STT data to the manager
    /// - Parameter refinedSTTData: The refined STT data to add
    func addRefinedSTTData(_ refinedSTTData: RefinedSTTData)
    
    /// Get refined STT data for a specific audio event ID
    /// - Parameter eventId: The event ID of the audio message
    /// - Returns: The refined STT data if available, nil otherwise
    func getRefinedSTTData(forAudioEventId eventId: String) -> RefinedSTTData?
    
    /// Publisher for refined STT data updates
    var refinedSTTDataPublisher: AnyPublisher<[String: RefinedSTTData], Never> { get }
}

class ServiceLocator {
    private(set) static var shared = ServiceLocator()
    
    private init() { }
    
    private(set) var userIndicatorController: UserIndicatorControllerProtocol!
    
    func register(userIndicatorController: UserIndicatorControllerProtocol) {
        self.userIndicatorController = userIndicatorController
    }
    
    private(set) var settings: AppSettings!
    
    func register(appSettings: AppSettings) {
        settings = appSettings
    }
    
    private(set) var analytics: AnalyticsService!
    
    func register(analytics: AnalyticsService) {
        self.analytics = analytics
    }
    
    private(set) var bugReportService: BugReportServiceProtocol!
    
    func register(bugReportService: BugReportServiceProtocol) {
        self.bugReportService = bugReportService
    }
    
    private(set) var refinedSTTManager: RefinedSTTManagerProtocol!
    
    func register(refinedSTTManager: RefinedSTTManagerProtocol) {
        MXLog.debug("ServiceLocator: Registering RefinedSTTManager")
        self.refinedSTTManager = refinedSTTManager
        MXLog.debug("ServiceLocator: RefinedSTTManager registered successfully")
    }
}

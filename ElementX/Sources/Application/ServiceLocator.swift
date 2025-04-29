//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE in the repository root for full details.
//

import Combine
import Foundation

// Define the necessary types here to avoid circular dependencies
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
    
    /// Parsed summary from the JSON, if available
    let summary: String?
    
    /// Parsed refined transcription from the JSON, if available
    let refinedTranscription: String?
    
    /// Topics with suggested replies parsed from the JSON, if available
    let topics: [Topic]?
    
    /// Topic with suggested replies
    struct Topic: Identifiable, Hashable {
        let topic: String
        let responses: [String]
        
        var id: String { topic }
    }
    
    init(eventId: String, referencedEventId: String, refinedSttBody: String, timestamp: Date) {
        self.eventId = eventId
        self.referencedEventId = referencedEventId
        self.refinedSttBody = refinedSttBody
        self.timestamp = timestamp
        
        // Parse JSON if possible
        let parsedData = Self.parseJSON(refinedSttBody)
        summary = parsedData.summary
        refinedTranscription = parsedData.refinedTranscription
        topics = parsedData.topics
    }
    
    /// Parse the JSON refined STT body to extract structured data
    private static func parseJSON(_ json: String) -> (summary: String?, refinedTranscription: String?, topics: [Topic]?) {
        guard !json.isEmpty, let jsonData = json.data(using: .utf8) else {
            return (nil, nil, nil)
        }
        
        do {
            // Use JSONSerialization for better performance
            if let parsedJSON = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                // Extract summary
                let summary = parsedJSON["summary"] as? String
                
                // Extract refined transcription
                let refinedTranscription = parsedJSON["refined_transcription"] as? String
                
                // Extract topics and responses
                var topics: [Topic]? = nil
                if let topicsArray = parsedJSON["topics"] as? [[String: Any]] {
                    topics = topicsArray.compactMap { topicDict -> Topic? in
                        guard let topicName = topicDict["topic"] as? String,
                              let responses = topicDict["responses"] as? [String] else {
                            return nil
                        }
                        return Topic(topic: topicName, responses: responses)
                    }
                    
                    // Only return topics if we have at least one valid topic
                    if topics?.isEmpty == true {
                        topics = nil
                    }
                }
                
                return (summary, refinedTranscription, topics)
            }
        } catch {
            #if DEBUG
            print("Failed to parse transcription JSON: \(error)")
            #endif
        }
        
        return (nil, nil, nil)
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

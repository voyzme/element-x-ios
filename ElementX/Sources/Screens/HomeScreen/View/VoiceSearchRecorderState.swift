//
// Copyright 2024 New Vector Ltd.
//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE in the repository root for full details.
//

import AVFoundation
import Combine
import Foundation
import MatrixRustSDK
import Speech
import SwiftUI

/// VoiceSearchRecorderState class for voice recording in search
@MainActor
class VoiceSearchRecorderState: ObservableObject {
    // Published properties for UI updates
    @Published var isRecording = false
    @Published var duration: TimeInterval = 0
    @Published var waveformSamples: [Float] = []
    @Published var currentTranscript: String?
    
    // Audio recording properties
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var displayLink: CADisplayLink?
    private var fakeWaveformTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    
    // Properties needed for voice message sending
    let audioRecorder = AudioRecorder()
    var recordingDuration: UInt64 { UInt64(duration * 1000) } // Convert to milliseconds
    var transcriptionLanguage = "en" // Default language
    private var recordingFileURL: URL? // Store the recording file URL
    
    init() {
        // Initialize with empty state
        setupSpeechRecognition()
    }
  
    deinit {
        // Can't call stopRecording() directly in deinit due to actor isolation
        // Use detached task to ensure proper cleanup
        Task.detached { @MainActor [weak self] in
            self?.stopRecording()
        }
    }
    
    /// Safely get the current transcript
    /// This method can be called from outside the actor to safely access the transcript
    func safeGetTranscript() -> String? {
        // Since this class is already @MainActor, we can safely return the transcript
        // This provides a safe way for external code to access the transcript
        currentTranscript
    }
    
    // MARK: - Public Methods
    
    /// Start recording audio and speech recognition
    func startRecording() {
        print("[VoiceSearchRecorderState] Starting recording")
        
        // Make sure any existing recording is properly cleaned up
        if isRecording {
            stopRecording()
        }
        
        // Configure audio session first
        do {
            print("[VoiceSearchRecorderState] Configuring audio session")
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: .duckOthers)
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            print("[VoiceSearchRecorderState] Audio session configured successfully")
        } catch {
            print("[VoiceSearchRecorderState] Failed to configure audio session: \(error)")
            return
        }
        
        // Reset state
        duration = 0
        currentTranscript = nil
        waveformSamples.removeAll()
        
        // Create a temporary file URL for recording
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(UUID().uuidString)
        recordingFileURL = tempFile
        
        print("[VoiceSearchRecorderState] Starting speech recognition")
        // Start new recording components
        startAudioEngine()
        startDisplayLink()
        
        // Only set recording state after everything is set up
        isRecording = true
        print("[VoiceSearchRecorderState] Recording started, isRecording = \(isRecording)")
        startDisplayLink()
        
        // Start the audio recorder for voice message recording
        if let fileURL = recordingFileURL {
            Task {
                await audioRecorder.record(audioFileURL: fileURL)
            }
        }
        
        // Update UI state - this will automatically trigger objectWillChange
        // because isRecording is a @Published property
        isRecording = true
        
        print("[VoiceSearchRecorderState] Recording started, isRecording = \(isRecording)")
    }
    
    /// Stop recording audio and speech recognition
    func stopRecording() {
        print("[VoiceSearchRecorderState] Stopping recording")
        
        // Stop all recording components
        stopDisplayLink()
        stopSpeechRecognition()
        
        // Stop the audio recorder asynchronously
        Task {
            await audioRecorder.stopRecording()
        }
        
        // Update UI state - this will automatically trigger objectWillChange
        // because isRecording is a @Published property
        isRecording = false
        
        print("[VoiceSearchRecorderState] Recording stopped, isRecording = \(isRecording)")
    }

    func reset() {
        // Reset state
        duration = 0
        currentTranscript = nil
        waveformSamples.removeAll()
        setupSpeechRecognition()
    }

    /// Build a waveform from the current recording
    /// - Returns: A result containing the waveform or an error
    func buildRecordingWaveform() async -> Result<[UInt16], VoiceMessageRecorderError> {
        // Use the current waveform samples to build a waveform
        // Normalize the samples to be between 0 and 1, then convert to UInt16 values
        // Matrix waveform values are in the range 0-1024
        let normalizedSamples = waveformSamples.map { UInt16(min(max($0, 0), 1) * 1024) }
        
        // Return the array of UInt16 values
        return .success(normalizedSamples)
    }
    
    func sendVoiceMessage(inRoom roomProxy: JoinedRoomProxyProtocol, audioConverter: AudioConverterProtocol) async -> Result<Void, VoiceMessageRecorderError> {
        guard let url = recordingFileURL else {
            return .failure(VoiceMessageRecorderError.missingRecordingFile)
        }
        
        // convert the file
        let sourceFilename = url.deletingPathExtension().lastPathComponent
        let oggFile = URL.temporaryDirectory.appendingPathComponent(sourceFilename).appendingPathExtension("ogg")
        defer {
            // delete the temporary file
            try? FileManager.default.removeItem(at: oggFile)
        }

        do {
            try audioConverter.convertToOpusOgg(sourceURL: url, destinationURL: oggFile)
        } catch {
            return .failure(.failedSendingVoiceMessage)
        }

        // send it
        let size: UInt64
        do {
            size = try UInt64(FileManager.default.sizeForItem(at: oggFile))
        } catch {
            MXLog.error("Failed to get the recording file size. \(error)")
            return .failure(.failedSendingVoiceMessage)
        }
        
        // Create audio info and waveform
        let audioInfo = AudioInfo(duration: TimeInterval(duration), size: size, mimetype: "audio/ogg")
        guard case .success(let waveform) = await buildRecordingWaveform() else {
            return .failure(.failedSendingVoiceMessage)
        }
        
        // Send the voice message
        let result = await roomProxy.timeline.sendVoiceMessage(url: oggFile,
                                                               audioInfo: audioInfo,
                                                               waveform: waveform,
                                                               progressSubject: nil) { _ in }
        
        // Check if voice message was sent successfully
        if case .success(let eventId) = result {
            // Get the room-specific transcription language
            let roomID = roomProxy.id
            
            MXLog.info("Sending transcript event with language: \(transcriptionLanguage)")
            // Use the actual transcript we generated during recording
            let transcript = currentTranscript ?? ""
            let result_stt = await roomProxy.timeline.sendTranscriptEvent(transcript: transcript, language: transcriptionLanguage, relatedEventId: eventId)
            MXLog.info("Finished sending transcript event: \(result_stt)")
        } else if case .failure(let error) = result {
            MXLog.error("Failed to send the voice message. \(error)")
            return .failure(.failedSendingVoiceMessage)
        }
        
        return .success(())
    }
    
    // MARK: - Private Methods
    
    private func setupSpeechRecognition() {
        let language = AppSettings().searchLanguage.rawValue
        transcriptionLanguage = language
        print("[VoiceSearchRecorderState] Setting up speech recognition with language: \(language)")
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: language))
    }
    
    private func configureAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            print("[VoiceSearchRecorderState] Configuring audio session")
            
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            
            print("[VoiceSearchRecorderState] Audio session configured successfully")
        } catch {
            print("[VoiceSearchRecorderState] Failed to configure audio session: \(error.localizedDescription)")
        }
    }
    
    private func startSpeechRecognition() {
        print("[VoiceSearchRecorderState] Starting speech recognition")
        // First check if speech recognition is available
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            print("[VoiceSearchRecorderState] Speech recognition not available")
            return
        }
        
        // Check microphone authorization
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard let self = self else { return }
            
            Task { @MainActor in
                if status == .authorized {
                    self.startAudioEngine()
                } else {
                    print("[VoiceSearchRecorderState] Speech recognition authorization denied")
                }
            }
        }
    }
    
    private func startAudioEngine() {
        // First, ensure any existing engine is fully cleaned up
        stopSpeechRecognition()
        
        // Create a fresh audio engine
        let engine = AVAudioEngine()
        audioEngine = engine
        
        // Create a new recognition request
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request
        
        // Start the recognition task
        do {
            // Get the input node
            let node = engine.inputNode
            inputNode = node
            
            // Get the hardware input format
            let inputFormat = node.inputFormat(forBus: 0)
            print("[VoiceSearchRecorderState] Hardware input format: \(inputFormat)")
            
            // Install a tap on the audio input using the hardware format
            node.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
                self?.processAudioBuffer(buffer)
            }
            
            // Prepare and start the audio engine
            engine.prepare()
            try engine.start()
            
            // Start the recognition task
            recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
                guard let self = self else { return }
                
                Task { @MainActor in
                    if let result = result {
                        let transcript = result.bestTranscription.formattedString
                        self.currentTranscript = transcript
                        print("[VoiceSearchRecorderState] Transcript updated: \(transcript)")
                    }
                    
                    if error != nil || result?.isFinal == true {
                        print("[VoiceSearchRecorderState] Recognition finished or error: \(error?.localizedDescription ?? "No error")")
                        self.stopSpeechRecognition()
                    }
                }
            }
            
            print("[VoiceSearchRecorderState] Audio engine started successfully")
        } catch {
            print("[VoiceSearchRecorderState] Failed to start audio engine: \(error.localizedDescription)")
            stopSpeechRecognition()
        }
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        // Calculate audio level for waveform visualization
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = UInt(buffer.frameLength)
        
        var sum: Float = 0
        for i in 0..<frameLength {
            let sample = abs(channelData[Int(i)])
            sum += sample
        }
    }
    
    private func stopSpeechRecognition() {
        print("[VoiceSearchRecorderState] Stopping speech recognition")
        
        // Cancel any ongoing recognition task first
        if let task = recognitionTask {
            task.cancel()
            recognitionTask = nil
        }
        
        // End audio for the recognition request
        if let request = recognitionRequest {
            request.endAudio()
            recognitionRequest = nil
        }
        
        // Stop audio engine and remove tap
        if let engine = audioEngine {
            // Remove tap first if it exists
            if let node = inputNode {
                node.removeTap(onBus: 0)
            }
            // Then stop and reset the engine
            engine.stop()
            engine.reset()
            audioEngine = nil
        }
        
        // Clear remaining references
        inputNode = nil
        
        // Deactivate audio session
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        
        print("[VoiceSearchRecorderState] Speech recognition stopped")
    }
    
    // MARK: - Display Link and Timer Methods
    
    private func startDisplayLink() {
        print("[VoiceSearchRecorderState] Starting display link")
        // Stop any existing display link
        stopDisplayLink()
        
        // Create a new display link on the main actor
        let newDisplayLink = CADisplayLink(target: self, selector: #selector(updateDuration))
        newDisplayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60)
        newDisplayLink.add(to: .main, forMode: .common)
        displayLink = newDisplayLink
        
        print("[VoiceSearchRecorderState] Display link started")
    }
    
    private func stopDisplayLink() {
        print("[VoiceSearchRecorderState] Stopping display link")
        if let link = displayLink {
            link.invalidate()
            displayLink = nil
        }
    }
    
    @objc private func updateDuration() {
        if isRecording {
            duration += 1.0 / 60.0 // Assuming 60fps
            
            // Update waveform samples
            let power = audioRecorder.averagePower()
            waveformSamples.append(1.0 - power)
        }
    }
    
    // MARK: - Preview
    
    // For preview purposes only
    static func preview() -> VoiceSearchRecorderState {
        let state = VoiceSearchRecorderState()
        state.isRecording = true
        state.duration = 12.5
        state.currentTranscript = "Hello world"
        state.waveformSamples = (0..<50).map { _ in Float.random(in: 0.1...1.0) }
        return state
    }
}

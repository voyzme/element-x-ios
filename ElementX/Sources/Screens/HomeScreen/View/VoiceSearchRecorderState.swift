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
    
    init() {
        // Initialize with empty state
        setupSpeechRecognition()
        
        // Generate some initial waveform data
        for _ in 0..<30 {
            waveformSamples.append(Float.random(in: 0.1...0.5))
        }
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
        
        // Reset state
        duration = 0
        currentTranscript = nil
        
        // Start audio session and recording
        configureAudioSession()
        startSpeechRecognition()
        startDisplayLink()
        startFakeWaveformTimer()
        
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
        stopFakeWaveformTimer()
        stopSpeechRecognition()
        
        // Update UI state - this will automatically trigger objectWillChange
        // because isRecording is a @Published property
        isRecording = false
        
        print("[VoiceSearchRecorderState] Recording stopped, isRecording = \(isRecording)")
    }

    func reset() {
        setupSpeechRecognition()
    }
    
    // MARK: - Private Methods
    
    private func setupSpeechRecognition() {
        let language = AppSettings().searchLanguage.rawValue
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
        // Create a new audio engine if needed
        let engine = audioEngine ?? AVAudioEngine()
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
            
            // Install a tap on the audio input
            let recordingFormat = node.outputFormat(forBus: 0)
            node.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
                
                // Calculate audio level for waveform
                self?.processAudioBuffer(buffer)
            }
            
            // Start the audio engine
            engine.prepare()
            try engine.start()
            
            // Start the recognition task
            recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
                guard let self = self else { return }
                
                Task { @MainActor in
                    if let result = result {
                        // Update the transcript
                        let transcript = result.bestTranscription.formattedString
                        self.currentTranscript = transcript
                        print("[VoiceSearchRecorderState] Transcript updated: \(transcript)")
                    }
                    
                    if error != nil || result?.isFinal == true {
                        // Stop if there's an error or if we're done
                        print("[VoiceSearchRecorderState] Recognition finished or error: \(error?.localizedDescription ?? "No error")")
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
        
        // Calculate average and normalize to 0-1 range
        let average = sum / Float(frameLength)
        let level = min(max(average * 5, 0.1), 1.0) // Scale and clamp
        
        // Update waveform on main thread
        Task { @MainActor in
            if self.waveformSamples.count > 30 {
                self.waveformSamples.removeFirst()
            }
            self.waveformSamples.append(level)
        }
    }
    
    private func stopSpeechRecognition() {
        print("[VoiceSearchRecorderState] Stopping speech recognition")
        
        // Stop audio engine and remove tap
        if let engine = audioEngine, let node = inputNode {
            engine.stop()
            node.removeTap(onBus: 0)
        }
        
        // End audio for the recognition request
        recognitionRequest?.endAudio()
        
        // Cancel the recognition task
        recognitionTask?.cancel()
        
        // Clear all references
        audioEngine = nil
        inputNode = nil
        recognitionRequest = nil
        recognitionTask = nil
        
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
    
    private func startFakeWaveformTimer() {
        // Stop any existing timer
        stopFakeWaveformTimer()
        
        // Create a new timer that fires every 0.1 seconds on the main thread
        fakeWaveformTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            // Use Task to ensure we're on the MainActor when accessing actor-isolated properties
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                
                // Only proceed if we're still recording
                if self.isRecording, self.audioEngine == nil {
                    // Update waveform samples to show activity
                    if self.waveformSamples.count > 30 {
                        self.waveformSamples.removeFirst()
                    }
                    self.waveformSamples.append(Float.random(in: 0.1...0.8))
                }
            }
        }
    }
    
    private func stopFakeWaveformTimer() {
        fakeWaveformTimer?.invalidate()
        fakeWaveformTimer = nil
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

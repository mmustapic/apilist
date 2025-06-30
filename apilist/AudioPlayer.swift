//
//  AudioPlayer.swift
//  apilist
//
//  Created by Marco Mustapic on 29/06/2025.
//

import AVFoundation
import Foundation

enum AudioError: Error {
    case playback
}

@Observable
class AudioPlayer {
    public var samples: [Float] = []

    @ObservationIgnored private var samplesToPlay: [Float] = []
    private let audioEngine = AVAudioEngine()
    private let audioPlayerNode = AVAudioPlayerNode()

    @ObservationIgnored private var playingTask: Task<Void, any Error>? = nil
    @ObservationIgnored private let audioFormat: AVAudioFormat
    @ObservationIgnored private let sampleRate: Double

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        audioEngine.attach(audioPlayerNode)
        audioFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        audioEngine.connect(audioPlayerNode, to: audioEngine.mainMixerNode, format: audioFormat)

        let minimumBufferSize: Int = 1024
        audioPlayerNode.installTap(onBus: 0, bufferSize: UInt32(minimumBufferSize), format: audioFormat) { [weak self] buffer, _ in
            let channelData = buffer.floatChannelData?[0]
            let length = Int(buffer.frameLength)
            if length >= minimumBufferSize {
                let data = Array(UnsafeBufferPointer(start: channelData, count: length))
                self?.samples = downsample(data: data, minimumBufferSize: minimumBufferSize, finalNumberOfSamples: 16)
            }
        }
    }

    func play(samples: [Float]) async throws {
//        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
//        try AVAudioSession.sharedInstance().setPreferredSampleRate(sampleRate)
//        try AVAudioSession.sharedInstance().setActive(true)

        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else {
            throw AudioError.playback
        }

        buffer.frameLength = frameCount
        memcpy(buffer.floatChannelData![0], samples, samples.count * MemoryLayout<Float>.size)

        playingTask?.cancel()
        playingTask = Task {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try audioEngine.start()
                    audioPlayerNode.scheduleBuffer(buffer, at: nil, options: []) {
                        print("finished playing in scheduleBuffer")
                        continuation.resume()
                    }
                    audioPlayerNode.play()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        try await playingTask?.value
    }

    func stop() {
        print("stoppping")
        playingTask?.cancel()
        if audioPlayerNode.isPlaying {
            audioPlayerNode.stop()
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
    }
}

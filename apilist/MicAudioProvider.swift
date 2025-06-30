//
//  Audio.swift
//  apilist
//
//  Created by Marco Mustapic on 16/05/2025.
//
import Accelerate
import AVFoundation
import Combine

@Observable
public class MicAudioProvider {
    public var samples: [Float] = []
    public var chunk: [Float] = []

    @ObservationIgnored private var accumulatedSamples = [Float]()
    @ObservationIgnored private var accumulatedSampleThreshold: Double = 0.1    // minimum audio to send is 0.2 seconds
    @ObservationIgnored private var silentSampleCount: Int = 0 // number of samples that were silent, so we can decide when the user stopped talking and send the chunk
    @ObservationIgnored private let silentSampleThreshold = 1.0 // after this number of silent seconds, we send the audio chunnk

    @ObservationIgnored private let audioEngine = AVAudioEngine()

    @ObservationIgnored let preferredSampleRate: Double = 16000
    @ObservationIgnored var sampleRate: Double = 0.0

    public enum MicAudioProviderError: Error {
        case permissionToRecordNotGranted
    }

    init() {
        accumulatedSamples.reserveCapacity(Int(preferredSampleRate) * 10)  // 10 seconds of audio, supposing 48kHz input
    }

    public func prepare() throws {
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default)
        try AVAudioSession.sharedInstance().setPreferredSampleRate(preferredSampleRate)
        try AVAudioSession.sharedInstance().setActive(true)

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        sampleRate = format.sampleRate

        let minimumBufferSize: Int = 1024
        input.installTap(onBus: 0, bufferSize: UInt32(minimumBufferSize), format: format) { [weak self] buffer, _ in
            let channelData = buffer.floatChannelData?[0]
            let length = Int(buffer.frameLength)
            if length >= minimumBufferSize {
                let data = Array(UnsafeBufferPointer(start: channelData, count: length))
                self?.appendNonSilentSamples(data: data, minimumBufferSize: minimumBufferSize, frequency: Int(format.sampleRate))
                self?.samples = downsample(data: data, minimumBufferSize: minimumBufferSize, finalNumberOfSamples: 16)
            }
        }
    }

    public func stop() {
        audioEngine.pause()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.reset()
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    func record() throws {
        accumulatedSamples.removeAll()
        silentSampleCount = 0
        try audioEngine.start()
    }

    func pause() {
        if audioEngine.isRunning {
            print("pausing mic")
            audioEngine.pause()
        }
    }

    private func appendNonSilentSamples(data: [Float], minimumBufferSize: Int, frequency: Int) {
        // process the sample in chunks, it's not the same to have 1024 silent samples, than 8000
        stride(from: 0, to: data.count, by: minimumBufferSize).forEach { i in
            let slice = data[i ..< min(i+minimumBufferSize, data.count)]

            // compute rms of all slices to see if the volume is low enough to be considered a silence
            let rms = vDSP.rootMeanSquare(slice)
            let rmsThreshold: Float = 0.05
            if rms > rmsThreshold {
                // append to accumulated samples if volume is high enough
                accumulatedSamples.append(contentsOf: slice)
                // reset silence count
                silentSampleCount = 0
            } else {
               // silence, so don't accumulate
                silentSampleCount += slice.count
               // if silence is long enough, send what we accumulated, but only if it is significant
                if Double(silentSampleCount) / sampleRate > silentSampleThreshold &&
                    Double(accumulatedSamples.count) / sampleRate > accumulatedSampleThreshold {
                    chunk = accumulatedSamples
                    // reset accumulated samples
                    accumulatedSamples.removeAll()
                    silentSampleCount = 0
                }
            }
        }
    }
}

func downsample(data: [Float], minimumBufferSize: Int, finalNumberOfSamples: Int) -> [Float] {
    // trim to a multiple of minimumBufferSize
    if data.count < minimumBufferSize {
        print("here")
    }
    let multiple = data.count / minimumBufferSize
    let trimmed = data.prefix(multiple * minimumBufferSize)
    let chunkSize = trimmed.count / finalNumberOfSamples
    let reduced = stride(from: 0, to: trimmed.count, by: chunkSize).map { i -> Float in
        let chunk = trimmed[i..<i+chunkSize]
        return vDSP.maximum(chunk)
    }
    return vDSP.clip(reduced, to: -1.0...1.0)
}

func floatArrayToPCMData(_ samples: [Float]) -> Data {
    var data = Data(capacity: samples.count * MemoryLayout<Int16>.size)
    let amplified = vDSP.multiply(Float(Int16.max), samples)
    let clipped = vDSP.clip(amplified, to: Float(Int16.min)...Float(Int16.max))
    let intSamples = vDSP.floatingPointToInteger(clipped, integerType: Int16.self, rounding: .towardNearestInteger)
    // this supposes little endianness, ARM and Intel, so don't have to convert anything
    intSamples.withUnsafeBufferPointer { pointer in
        data.append(pointer)
    }
    return data
}

func floatToWav(samples: [Float], rate: Int) -> Data {
    let pcmData = floatArrayToPCMData(samples)
    let pcmDataLengthInBytes = pcmData.count * MemoryLayout<Int16>.size
    var data = Data()
    // header
    data.append("RIFF".data(using: .ascii)!)
    data.append(UInt32(36 + pcmDataLengthInBytes).littleEndianData)    // total file size - 8 bytes, meaning remaining header (36 bytes) + samples
    data.append("WAVE".data(using: .ascii)!)
    data.append("fmt ".data(using: .ascii)!)
    // chunk header
    data.append(UInt32(16).littleEndianData)    // chunk size - 8 bytes, so 16
    data.append(UInt16(1).littleEndianData)    // PCM integer
    data.append(UInt16(1).littleEndianData)    // 1 channel
    data.append(UInt32(rate).littleEndianData)    // sample rate in Hz
    data.append(UInt32(rate * MemoryLayout<Int16>.size * 1).littleEndianData)    // bytes per second: rate * sample size * channels
    data.append(UInt16(1 * MemoryLayout<Int16>.size).littleEndianData)    // bytes per block: channels * bits per sample / 8
    data.append(UInt16(Int16.bitWidth).littleEndianData)    // bits per sample
    // chunk data
    data.append("data".data(using: .ascii)!)    // chunk data header
    data.append(UInt32(pcmDataLengthInBytes).littleEndianData)  // data length in bytes
    data.append(pcmData)

    return data
}

private extension FixedWidthInteger {
    var littleEndianData: Data {
        var v = self
        return Data(bytes: &v, count: MemoryLayout<Self>.size)
    }
}

/*
func fft(signal: [Float], binCount: Int) -> [Float] {
    guard signal.count > 0 else {
        return []
    }
    let log2n = vDSP_Length(log2(Float(signal.count)))

    guard let fftSetUp = vDSP.FFT(log2n: log2n,
                                  radix: .radix2,
                                  ofType: DSPSplitComplex.self) else {
                                    fatalError("Can't create FFT Setup.")
    }

    let halfN = Int(signal.count / 2)
    var forwardInputReal = [Float](repeating: 0, count: halfN)
    var forwardInputImag = [Float](repeating: 0, count: halfN)
    var forwardOutputReal = [Float](repeating: 0, count: halfN)
    var forwardOutputImag = [Float](repeating: 0, count: halfN)

    forwardInputReal.withUnsafeMutableBufferPointer { forwardInputRealPtr in
        forwardInputImag.withUnsafeMutableBufferPointer { forwardInputImagPtr in
            forwardOutputReal.withUnsafeMutableBufferPointer { forwardOutputRealPtr in
                forwardOutputImag.withUnsafeMutableBufferPointer { forwardOutputImagPtr in

                    // Create a `DSPSplitComplex` to contain the signal.
                    var forwardInput = DSPSplitComplex(realp: forwardInputRealPtr.baseAddress!,
                                                       imagp: forwardInputImagPtr.baseAddress!)

                    // Convert the real values in `signal` to complex numbers.
                    signal.withUnsafeBytes {
                        vDSP.convert(interleavedComplexVector: [DSPComplex]($0.bindMemory(to: DSPComplex.self)),
                                     toSplitComplexVector: &forwardInput)
                    }

                    // Create a `DSPSplitComplex` to receive the FFT result.
                    var forwardOutput = DSPSplitComplex(realp: forwardOutputRealPtr.baseAddress!,
                                                        imagp: forwardOutputImagPtr.baseAddress!)

                    // Perform the forward FFT.
                    fftSetUp.forward(input: forwardInput,
                                     output: &forwardOutput)
                }
            }
        }
    }

    // autospectrum from Apple's sample
    let autospectrum = [Float](unsafeUninitializedCapacity: halfN) {
        autospectrumBuffer, initializedCount in

        // The `vDSP_zaspec` function accumulates its output. Clear the
        // uninitialized `autospectrumBuffer` before computing the spectrum.
        vDSP.clear(&autospectrumBuffer)

        forwardOutputReal.withUnsafeMutableBufferPointer { forwardOutputRealPtr in
            forwardOutputImag.withUnsafeMutableBufferPointer { forwardOutputImagPtr in

                var frequencyDomain = DSPSplitComplex(realp: forwardOutputRealPtr.baseAddress!,
                                                      imagp: forwardOutputImagPtr.baseAddress!)

                vDSP_zaspec(&frequencyDomain,
                            autospectrumBuffer.baseAddress!,
                            vDSP_Length(halfN))
            }
        }
        initializedCount = halfN
    }

    // now bucket the frequencies in buckets because we just want some bars, not the same as signal.count / 2
    // we just take the maximum, not the average
    let binSize = autospectrum.count / binCount
    let binned = (0..<autospectrum.count / binSize).map { i in
        let slice = autospectrum[i*binSize..<(i+1)*binSize]
        return vDSP.maximum(slice)
    }

    // now do the sqrt / signal.count on only binned values, not the complete signal
    return vDSP.divide(vForce.sqrt(binned), Float(signal.count))
}
*/

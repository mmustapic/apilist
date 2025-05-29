//
//  FrequencyView.swift
//  apilist
//
//  Created by Marco Mustapic on 14/05/2025.
//
import Accelerate
import SwiftUI
import Combine

struct SignalView: View {
    @Binding
    var signal: [Float]

    var body: some View {
        if signal.count > 0 {
            GeometryReader { proxy in
                Path { path in
                    let origin = 0.0
                    let width = proxy.size.width
                    let amplitudeMultiplier: Float = 30.0
                    let y = proxy.size.height * 0.5 + CGFloat(signal[0]*amplitudeMultiplier)
                    path.move(to: CGPoint(x: 0.0, y: y))
                    let increment = width / CGFloat(signal.count-1)
                    (1 ..< signal.count).forEach { i in
                        let p = CGPoint(x: origin + CGFloat(i)*increment, y: y + CGFloat(signal[i]*amplitudeMultiplier))
                        path.addLine(to: p)
                    }
                }
                .stroke(Color.white)
            }
        } else {
            Color.gray
        }
    }
}

struct FrequencyView: View {
    @Binding
    var signal: [Float]
    @Binding
    var waiting: Bool

    struct Frequency: Identifiable {
        let id: Int
        let value: Float
    }

    struct Anim {
        var value: CGFloat = 0.0
    }

    var body: some View {
        return GeometryReader { proxy in
            HStack(alignment: .center, spacing: 10) {
                Spacer()
                if waiting {
                    ForEach(0..<16) { i in
                        let radius = 3.0
                        Color(UIColor(white: 1.0, alpha: 0.8))
                            .cornerRadius(radius)
                            .frame(width: radius*2.0, height: radius*2.0)
                            .keyframeAnimator(initialValue: Anim(), repeating: true) { content, anim in
                            content
                                .offset(y: anim.value)
                        } keyframes: { anim in
                            let totalTime = TimeInterval(signal.count) * 0.1 + 0.5
                            let delayTime = 0.05*(TimeInterval(i)+0.001)
                            KeyframeTrack(\.value) {
                                CubicKeyframe(0.0, duration: 0.1)
                                CubicKeyframe(0.0, duration: delayTime)
                                CubicKeyframe(-8.0, duration: 0.2)
                                CubicKeyframe(0.0, duration: 0.2)
                                CubicKeyframe(0.0, duration: totalTime-delayTime)
                            }
                        }
                    }
                } else {
                    ForEach(signal.enumerated().map({ i, v in
                        Frequency(id: i, value: abs(v))
                    })) { f in
                        let radius = 3.0
                        let barHeight = waiting ? 0.0 : f.value
                        Color.white
                            .cornerRadius(radius)
                            .frame(width: radius*2.0, height: max(radius*2.0, min(proxy.size.height-radius*2.0, CGFloat(barHeight)*2*proxy.size.height)))
                    }
                    .animation(.easeIn(duration: 0.1), value: signal)
                }
                Spacer()
            }
            .frame(maxHeight: .infinity)
        }
    }
}

struct FrequencyTestView: View {
    @State var signal: [Float] = [10, 100, 200, 300, 500, 800]

    var body: some View {
        VStack {
            FrequencyView(signal: $signal, waiting: .constant(true))
                .frame(maxWidth: .infinity, maxHeight: 100)
                .background(Color.blue)
                .clipped()
        }
    }
}

func synthesizeSignal(frequencyAmplitudePairs: [(f: Float, a: Float)],
                             count: Int) -> [Float] {

    let tau: Float = .pi * 2
    let signal: [Float] = (0 ..< count).map { index in
        frequencyAmplitudePairs.reduce(0) { accumulator, frequenciesAmplitudePair in
            let normalizedIndex = Float(index) / Float(count)
            return accumulator + sin(normalizedIndex * frequenciesAmplitudePair.f * tau) * frequenciesAmplitudePair.a
        }
    }

    return signal
}

func fft(signal: [Float], binCount: Int) -> [Float] {
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

#Preview {
    FrequencyTestView()
}

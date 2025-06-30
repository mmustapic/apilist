//
//  apilistApp.swift
//  apilist
//
//  Created by Marco Mustapic on 12/05/2025.
//

import AVFoundation
import SwiftUI
import SwiftData

@main
struct apilistApp: App {
    @StateObject private var viewModel = AppViewModel()
    @State private var micAudioProvider = MicAudioProvider()
    @State private var audioPlayer = AudioPlayer(sampleRate: 16000)
    @State private var agent: TodoListAgent = TodoListAgent()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            switch viewModel.recordPermission {
            case .undetermined:
                VStack {
                    Text("Tap button to request recording permission")
                    Button {
                        Task {
                            await viewModel.requestRecordPermission()
                        }
                    } label: {
                        Text("Request")
                    }
                }
            case .granted:
                ContentView()
                    .environment(micAudioProvider)
                    .environment(audioPlayer)
                    .environment(agent)
            case .denied:
                Text("Recording permission was denied. Go to Settings > Privacy & Security > Microphone and enable it for the app")
            @unknown default:
                Text("Recording permission was denied. Go to Settings > Privacy & Security > Microphone and enable it for the app")
            }
        }
        .modelContainer(sharedModelContainer)
    }
}

class AppViewModel: ObservableObject {
    @Published
    var recordPermission: AVAudioApplication.recordPermission = AVAudioApplication.shared.recordPermission

    @MainActor
    func requestRecordPermission() async {
        await AVAudioApplication.requestRecordPermission()
        recordPermission = AVAudioApplication.shared.recordPermission
    }
}

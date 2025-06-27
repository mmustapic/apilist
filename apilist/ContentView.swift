//
//  ContentView.swift
//  apilist
//
//  Created by Marco Mustapic on 12/05/2025.
//

import SwiftUI
import SwiftData
import AVFoundation
import Combine
import Accelerate

enum VisualState {
    case closed
    case bar
    case fullScreen

}

enum InputState {
    case closed
    case listening
    case waiting
    case talking
    case finished
}

@MainActor
struct ListenView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var agent: TodoListAgent = TodoListAgent()

    @State private var soundBars: [Float] = []
    @State private var inputState: InputState = .closed
    @State private var visualState: VisualState = .closed
    @State private var error: Error? = nil

    @State private var micAudioProvider = MicAudioProvider()

    private let padding = 10.0

    private var isWaiting: Binding<Bool> {
        Binding(get: {
            if case .waiting = inputState {
                return true
            }
            return false
        }, set: { newValue in
        })
    }

    var body: some View {
        ZStack {
            // this is the view that can go full screen
            backgroundView
            // this is the view that contains the button itself, the transcript, etc
            contentView
        }
    }

    var backgroundView: some View {
        HStack {
            Color.blue

        }
        .frame(maxWidth: backgroundViewFrameMaxSize.width, maxHeight:  backgroundViewFrameMaxSize.height)
        .cornerRadius(corderRadiusForState)
        .ignoresSafeArea(edges: visualState == .fullScreen ? .all : [])
        .padding(paddingForState)
        .animation(.easeInOut, value: visualState)
    }

    var contentView: some View {
        VStack() {
            if visualState == .fullScreen {
                Text(agent.response ?? "")
                    .foregroundStyle(.white)
                    .font(.system(size: 20))
                Spacer()
            }
            ZStack {
                Color.blue
                if visualState == .closed {
                    Image(systemName: "waveform.path")
                        .foregroundStyle(.white)
                        .font(.system(size: 30))
                } else {
                    HStack(spacing: 0) {
                        Spacer(minLength: 15)
                        FrequencyView(signal: $soundBars, waiting: isWaiting)
                            .frame(maxWidth: .infinity)
                        Image(systemName: "xmark")
                            .foregroundStyle(.white)
                            .font(.system(size: 30))
                            .frame(maxWidth: 60, maxHeight: .infinity)
                            .onTapGesture {
                                stopListening()
                            }
                    }
                }
            }
            .onTapGesture {
                buttonTapped()
            }
            .frame(height: 60.0)
        }
        .frame(maxWidth: backgroundViewFrameMaxSize.width, maxHeight:  backgroundViewFrameMaxSize.height)
        .cornerRadius(corderRadiusForState)
        .padding(paddingForState)
        .animation(.easeInOut, value: visualState)
        .onReceive(micAudioProvider.samples.receive(on: RunLoop.main)) { samples in
            self.soundBars = samples
        }
        .onReceive(micAudioProvider.audioChunk.receive(on: RunLoop.main)) { chunk in
            process(chunk: chunk)
        }
        .onAppear() {
            agent.onFinish = finish
            agent.onCreateItem = createItem
            agent.onDeleteItem = deleteItem
            agent.onUpdateItem = updateItem
            agent.onGetItem = getItem
            agent.onSetItemState = setItemState
            agent.onGetAllItems = getAllItems
        }
        .onDisappear {
            stopListening()
        }
        .onChange(of: agent.response) { oldValue, newValue in
            if newValue != nil {
                do {
                    try startListening()
                } catch {
                    self.error = error
                }
                visualState = .fullScreen
            }
        }
    }

    private func stopListening() {
        visualState = .closed
        inputState = .closed

        // TODO: stop agent too

        agent.cancel()
        micAudioProvider.stop()
    }

    private func buttonTapped() {
        do {
            if inputState == .closed {
                visualState = .bar
                inputState = .waiting
                try prepareToListen()
                try startListening()
                agent.reset()
            } else {
                stopListening()
            }
        } catch {
            self.error = error
        }
    }

    private func prepareToListen() throws {
        try micAudioProvider.prepare()
    }

    private func startListening() throws {
        do {
            try micAudioProvider.record()
            inputState = .listening
        } catch {
            self.error = error
        }
    }

    private func pauseListening() {
        inputState = .waiting
        micAudioProvider.pause()
    }

    private func process(chunk: [Float]) {
        pauseListening()    // stop receiving chunks too

        Task {
            let wav = floatToWav(samples: chunk, rate: Int(self.micAudioProvider.sampleRate))
            let text = try await OpenAI.shared.transcribe(wav: wav)
//                agent.send(text: "remember to have lunch tomorrow")
            agent.send(text: text)
        }
    }

    private var backgroundViewFrameMaxSize: CGSize {
        switch visualState {
        case .closed: CGSize(width: 60.0, height: 60.0)
        case .bar: CGSize(width: CGFloat.infinity, height: 60.0)
        case .fullScreen: CGSize(width: CGFloat.infinity, height: CGFloat.infinity)
        }
    }

    private var paddingForState: EdgeInsets {
        switch visualState {
        case .closed: EdgeInsets(top: 0.0, leading: 10.0, bottom: 0.0, trailing: 10.0)
        case .bar: EdgeInsets(top: 0.0, leading: 10.0, bottom: 0.0, trailing: 10.0)
        case .fullScreen: EdgeInsets()
        }
    }

    private var corderRadiusForState: CGFloat {
        switch visualState {
        case .closed, .bar: 30.0
        case .fullScreen: 0.0
        }
    }
}

enum ButtonState {
    case closed
    case bar
    case fullscreen
}

enum ButtonContentState {
    case soundBars
    case waiting
}

extension ListenView {
    func createItem(title: String, description: String) async throws -> TodoListAgent.Item {
        let newItem = Item(title: title, text: description)
        modelContext.insert(newItem)
        return newItem.toFunctionHandlerItem()
    }
    
    func getAllItems() async throws -> [TodoListAgent.Item] {
        let descriptor = FetchDescriptor<Item>()
        let items = try modelContext.fetch(descriptor)
        return items.map {  $0.toFunctionHandlerItem() }
    }

    func deleteItem(uid: String) async throws -> Bool {
        let descriptor = FetchDescriptor<Item>(predicate: #Predicate { $0.uid == uid} )
        guard let first = try modelContext.fetch(descriptor).first else { return false }
        modelContext.delete(first)
        return true
    }

    func getItem(uid: String) async throws -> TodoListAgent.Item? {
        let descriptor = FetchDescriptor<Item>(predicate: #Predicate { $0.uid == uid} )
        let item = try modelContext.fetch(descriptor).first?.toFunctionHandlerItem()
        return item
    }

    func updateItem(uid: String, title: String?, description: String?) async throws -> Bool {
        let descriptor = FetchDescriptor<Item>(predicate: #Predicate { $0.uid == uid} )
        guard let first = try modelContext.fetch(descriptor).first  else { return false }
        if let title { first.title = title }
        if let description { first.text = description }
        try modelContext.save()
        return true
    }

    func setItemState(uid: String, state: Bool) async throws -> Bool {
        let descriptor = FetchDescriptor<Item>(predicate: #Predicate { $0.uid == uid} )
        guard let first = try modelContext.fetch(descriptor).first else { return false }
        first.completed = state
        try modelContext.save()
        return true
    }

    func finish() async throws {
        stopListening()
    }
}

extension Item {
    func toFunctionHandlerItem() -> TodoListAgent.Item {
        TodoListAgent.Item(id: self.uid,
                             title: self.title,
                             description: self.text,
                             status: self.completed ? .closed : .open)
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var items: [Item]

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            NavigationSplitView {
                List {
                    ForEach(items) { item in
                        NavigationLink {
                            ItemView(item: item)
                            Text("Item at \(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))")
                        } label: {
                            Text("\(item.title) \(item.completed ? "" : "")")
                        }
                    }
                    .onDelete(perform: deleteItems)
                }
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        EditButton()
                    }
                    ToolbarItem {
                        Button(action: addItem) {
                            Label("Add Item", systemImage: "plus")
                        }
                    }
                }
            } detail: {
                Text("Select an item")
            }
            ListenView()
        }
    }

    private func addItem() {
        withAnimation {
            let newItem = Item(title: "something", text: "hi there")
            modelContext.insert(newItem)
        }
    }

    private func deleteItems(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(items[index])
            }
        }
    }
}

struct ItemView: View {
    let item: Item

    var body: some View {
        VStack {
            Text("\(item.title)")
                .font(Font.system(size: 14))
            Text("\(item.text)")
                .font(Font.system(size: 12))
            Text("UID: \(item.uid)")
            Text("Date: \(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))")
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}

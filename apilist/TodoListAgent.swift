//
//  FunctionHandler.swift
//  apilist
//
//  Created by Marco Mustapic on 08/06/2025.
//
import SwiftData
import SwiftUI


@Observable
class TodoListAgent {
    actor CancellationActor {
        var cancel: Bool

        init() {
            self.cancel = false
        }
    }

    var onCreateItem: ((_ title: String, _ description: String) async throws -> TodoListAgent.Item)? = nil
    var onGetAllItems: (() async throws -> [TodoListAgent.Item])? = nil
    var onGetItem: ((_ uid: String) async throws -> TodoListAgent.Item?)? = nil
    var onDeleteItem: ((_ uid: String) async throws -> Bool)? = nil
    var onUpdateItem: ((_ uid: String, _ title: String?, _ description: String?) async throws -> Bool)? = nil
    var onSetItemState: ((_ uid: String, _ state: Bool) async throws -> Bool)? = nil
    var onFinish: (() async throws -> ())? = nil

    var response: String? = nil // response after calling agent's send(text), we don't need an async call for it

    @ObservationIgnored
    private lazy var agent: Agent = {
        createApiListAgent(openAI: OpenAI.shared, functionHandler: self.handle)
    }()

    private func handle(functionName: String, parameters: String) async throws -> String {
        switch functionName {
        case "createItem":
            let input = try JSONDecoder().decode(CreateItemInput.self, from: parameters.data(using: .utf8)!)
            guard let created = try await onCreateItem?(input.title, input.description) else { return "{}" }
            let json = try JSONEncoder().encode(CreateItemOutput(item: created))
            return String(data: json, encoding: .utf8)!
        case "getAllItems":
            guard let items = try await onGetAllItems?() else { return "{}" }
            let json = try JSONEncoder().encode(GetAllItemsOuput(items: items))
            return String(data: json, encoding: .utf8)!
        case "getItem":
            let input = try JSONDecoder().decode(GetItemInput.self, from: parameters.data(using: .utf8)!)
            guard let item = try await onGetItem?(input.id) else { return "{}" }
            let json = try JSONEncoder().encode(GetItemOutput(item: item))
            return String(data: json, encoding: .utf8)!
        case "deleteItem":
            let input = try JSONDecoder().decode(DeleteItemInput.self, from: parameters.data(using: .utf8)!)
            guard let result = try await onDeleteItem?(input.id) else { return "{}" }
            let json = try JSONEncoder().encode(DeleteItemOutput(deleted: result))
            return String(data: json, encoding: .utf8)!
        case "updateItem":
            let input = try JSONDecoder().decode(UpdateItemInput.self, from: parameters.data(using: .utf8)!)
            guard let result = try await onUpdateItem?(input.id, input.title, input.description) else { return "{}" }
            let json = try JSONEncoder().encode(UpdateItemOutput(updated: result))
            return String(data: json, encoding: .utf8)!
        case "setItemState":
            let input = try JSONDecoder().decode(SetItemStateInput.self, from: parameters.data(using: .utf8)!)
            guard let result = try await onSetItemState?(input.id, input.state) else { return "{}" }
            let json = try JSONEncoder().encode(SetItemStateOutput(updated: result))
            return String(data: json, encoding: .utf8)!
        case "finish":
            try await onFinish?()
            return "{}"
        default:
            throw AgentError.unknownFunction(name: functionName)
        }
    }

    public func send(text: String) {
        Task {
            do {
                self.response = try await agent.send(text: text)
            } catch {
                print(">>>> error \(error)")
            }
        }
    }

    public func reset() {
        agent.reset()
    }

    public func cancel() {
        agent.cancel()
    }

    struct CreateItemInput: Decodable {
        let title: String
        let description: String
    }

    struct CreateItemOutput: Encodable {
        let item: Item
    }

    struct GetAllItemsOuput: Encodable {
        let items: [Item]
    }

    struct GetItemInput: Decodable {
        let id: String
    }

    struct GetItemOutput: Encodable {
        let item: Item?
    }

    struct DeleteItemInput: Decodable {
        let id: String
    }

    struct DeleteItemOutput: Encodable {
        let deleted: Bool
    }

    struct UpdateItemInput: Decodable {
        let id: String
        let title: String?
        let description: String?
    }

    struct UpdateItemOutput: Encodable {
        let updated: Bool
    }

    struct SetItemStateInput: Decodable {
        let id: String
        let state: Bool
    }

    struct SetItemStateOutput: Encodable {
        let updated: Bool
    }

    struct Item: Codable {
        let id: String
        let title: String
        let description: String
        let status: Status

        enum Status: String, Codable {
            case open = "open"
            case closed = "closed"
        }
    }
}

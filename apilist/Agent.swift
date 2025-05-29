//
//  Agent.swift
//  apilist
//
//  Created by Marco Mustapic on 30/05/2025.
//

class Agent {
    public typealias FunctionHandler = (_ functionName: String, _ parameters: String) async throws -> String
    let client: ResponsesClient
    let configuration: Configuration
    let functionHandler: FunctionHandler?
    var previousResponseId: String?

    private var currentFunctionsTask: Task<[(ResponsesClient.FunctionCall, String?)], any Error>? = nil
    private var currentOpenAIResponseTask: Task<ResponsesClient.ResponsesResponse, any Error>? = nil

    struct Configuration {
        let instructions: String?
        let tools: [ResponsesClient.Tool]
        let model: OpenAI.Model
    }

    init(openAI: OpenAI, configuration: Configuration, functionHandler: FunctionHandler? = nil) {
        self.client = ResponsesClient(openAI: openAI)
        self.configuration = configuration
        self.functionHandler = functionHandler
    }

    func reset() {
        cancel()
        previousResponseId = nil
        currentOpenAIResponseTask = nil
        currentFunctionsTask = nil
    }
    
    func send(text: String) async throws -> String? {
        var completed = false
        var functionResults: [(ResponsesClient.FunctionCall, String?)] = []
        var iteration: Int = 0
        repeat {
            if let currentOpenAIResponseTask,
               currentOpenAIResponseTask.isCancelled {
                throw CancellationError()
            }
            if let currentFunctionsTask,
               currentFunctionsTask.isCancelled {
                throw CancellationError()
            }
            let firstRequest = previousResponseId == nil
            // setup input, text and instructions
            var input: [ResponsesClient.ResponsesRequest.Input] = []
            if firstRequest,
               let instructions = configuration.instructions {
                input.append(
                    .text(ResponsesClient.ResponsesRequest.Input.Text(role: .developer, content: instructions))
                )
            }
            if iteration == 0 {
                print(">>> request with \(text)")
                input.append(
                    .text(ResponsesClient.ResponsesRequest.Input.Text(role: .user, content: text))
                )
            }
            functionResults.forEach { (call, result) in
                input.append(
                    .functionCallOutput(ResponsesClient.ResponsesRequest.Input.FunctionCallOutput(callId: call.callId, output: result))
                )
            }
            let request = ResponsesClient.ResponsesRequest(model: configuration.model,
                                                           input: input,
                                                           tools: configuration.tools,
                                                           previousResponseId: previousResponseId)
            currentOpenAIResponseTask?.cancel()
            currentOpenAIResponseTask = Task {
                return try await client.send(request: request)
            }
            guard let response = try await currentOpenAIResponseTask?.value else { return nil }
            print(">>>> response \(response)")
            previousResponseId = response.id
            let functionCalls = response.allFunctionCalls()

            // if no more function calls, the agent has finished
            completed = functionCalls.count == 0

            // process existing function calls, one by one
            currentFunctionsTask?.cancel()
            currentFunctionsTask = Task {
                try await processFunctionCalls(calls: functionCalls)
            }
            functionResults = try await currentFunctionsTask?.value ?? []

            // extract text output, and return it if completed
            let messages = response.allMessages().filter { $0.role == .assistant }

            // just join all the content from the first output message
            if completed {
                return messages.first?.content.reduce("", { (partialResult: String, content) in
                    return partialResult + content.text
                })
            }
            iteration += 1
        } while !completed
        return nil
    }

    func cancel() {
        currentOpenAIResponseTask?.cancel()
        currentFunctionsTask?.cancel()
    }

    private func processFunctionCalls(calls: [ResponsesClient.FunctionCall]) async throws -> [(ResponsesClient.FunctionCall, String?)] {
        try await withThrowingTaskGroup(of: (ResponsesClient.FunctionCall, String?).self) { group in
            for call in calls {
                let _ = group.addTaskUnlessCancelled { [weak self] in
                    do {
                        print(">>> processing call \(call.name) with \(call.arguments)")
                        let result = try await self?.functionHandler?(call.name, call.arguments)
                        return (call, result)
                    } catch {
                        throw OpenAIError.functionCall(name: call.name, arguments: call.arguments, error: error)
                    }
                }
            }
            var results: [(ResponsesClient.FunctionCall, String?)] = []
            for try await (call, result) in group {
                results.append((call, result))
            }
            return results
        }
    }
}

extension ResponsesClient.ResponsesResponse {
    func allFunctionCalls() -> [ResponsesClient.FunctionCall] {
        return output.compactMap { output -> ResponsesClient.FunctionCall? in
            switch output {
            case .functionCall(let call): call
            default: nil
            }
        }
    }

    func allMessages() -> [ResponsesClient.ResponsesResponse.Output.Message] {
        return output.compactMap { output -> ResponsesClient.ResponsesResponse.Output.Message? in
            switch output {
            case .message(let message): message
            default: nil
            }
        }
    }
}

func createApiListAgent(openAI: OpenAI, functionHandler: @escaping Agent.FunctionHandler) -> Agent {
    let instructions = """
        # Identity
    
        You are an assistant that manages a todo list stored in a user's device. Based on user instructions,
        you will be responsible for: 
            * creating new items
            * updating existing ones
            * deleting existing items
            * marking an item state as complete or todo
        
        Instructions from the user will be in an arbitrary language, but when possible it will be specified. 
    
        # Instructions
    
        A user will issue instructions in text in any language (maybe in spanish). You'll have to figure
        out what functions to call to manipulate the list and fulfill the user's instructions. If you can
        complete your job with just the user's initial instructions the you can call the finish function
        and be done. Otherwise you can ask the user for more information if the instructions are not clear,
        are ambiguous or there are several items that he is refering to.
    
        Each item in the list has:
            * a unique id. This id is crated by the user's device when creating a new item. 
            * a title, around 4-6 words in length, that is, a short summary of the task itself. You will
              be responsible for creating and updating this title
            * a complete text description. You will also be responsible for figuring out this text based
              on user's instructions when creating or updating an item.
            * a state: todo or complete

        You will have several functions to call to manipulate the list and interact with the user's device:
        * Create new item: it expects a title and a description, and it will return the item just created,
          with its id, title, description and state. You could use the id further in the conversation to
          keep working on a specific item.
        * Update an item: it expects an id, a new title and new description.
        * Set Item state: it expects an id and a state. The device will mark the item as complete/todo, depending on the state.
        * Delete an item: it expexts an id. The device will delete it.
        * Get all items: it will return a list of all items with all their fields: id, title, description,
          state. You can use this function initially to know if the user wants to update an item or create a
          new one, or you can use it to verify that your actions did in fact fulfill the user's instructions.
        * Finish: it expects a boolean specifying if you could fulfill user's instructions or not. This will
          end the conversation with the user.      
    
        IMPORTANT:
        * Always ask for the list of items first, since it will help you recognize conflicts and ambigous
          instructions from the user
        * Ask the user for clarifications only if necessary. For example, if you can create or update an item
          with no conflicts, just do it.
        
        IMPORTANT:
        Keep in mind that you may have to ask the user for some more information in some cases
        * When creating a new item, there might be a similar one, so you should ask the user if he might want
          to update the existing item or create a new one. For this you need to have the complete list
          of items by callling the "get all items" function
        * When updating an item, it might conflict with an existing one too, so you should probably ask for
          confirmation. Again, it's a good idea to know the items that already exist.
        * To delete an item ask for confirmation
    
    """

    let createItemTool = ResponsesClient.Tool(type: .function,
                                      name: "createItem",
                                      description: "Creates an item in the todo list",
                                      parameters: ResponsesClient.Parameter(type: "object",
                                                                   properties: [
                                                                        "title" : ResponsesClient.Parameter(type: "string", description: "Item short title"),
                                                                        "description" : ResponsesClient.Parameter(type: "string", description: "Item long text description")
                                                                   ],
                                                                   required: ["title", "description"]))

    let getItemTool = ResponsesClient.Tool(type: .function,
                                  name: "getItem",
                                  description: "Gets an item based on an item id",
                                  parameters: ResponsesClient.Parameter(type: "object",
                                                               properties: [
                                                                    "id" : ResponsesClient.Parameter(type: "string", description: "Item id")
                                                               ],
                                                               required: ["id"]))

    let deleteItemTool = ResponsesClient.Tool(type: .function,
                                      name: "deleteItem",
                                      description: "Deletes an item based on an item id",
                                      parameters: ResponsesClient.Parameter(type: "object",
                                                                   properties: [
                                                                        "id" : ResponsesClient.Parameter(type: "string", description: "Item id")
                                                                   ],
                                                                   required: ["id"]))

    let completeItemTool = ResponsesClient.Tool(type: .function,
                                        name: "setItemState",
                                        description: "Set item todo or complete state based on an item id and a state value",
                                        parameters: ResponsesClient.Parameter(type: "object",
                                                                     properties: [
                                                                        "id" : ResponsesClient.Parameter(type: "string", description: "Item id"),
                                                                        "state" : ResponsesClient.Parameter(type: "boolean", description: "State, todo or complete")
                                                                     ],
                                                                     required: ["id", "state"]))

    let updateItemTool = ResponsesClient.Tool(type: .function,
                                      name: "updateItem",
                                      description: "Updates an item in the todo list with a new title and description",
                                      parameters: ResponsesClient.Parameter(type: "object",
                                                                   properties: [
                                                                        "id" : ResponsesClient.Parameter(type: "string", description: "Item id"),
                                                                        "title" : ResponsesClient.Parameter(type: "string", description: "Item short title"),
                                                                        "description" : ResponsesClient.Parameter(type: "string", description: "Item long text description")
                                                                   ],
                                                                   required: ["id", "title", "description"]))

    let getAllItemsTool = ResponsesClient.Tool(type: .function,
                                        name: "getAllItems",
                                        description: "Gets a list of all items",
                                        parameters: ResponsesClient.Parameter(type: "object",
                                                                              properties: [:],
                                                                              required: []) )

    let finishTool = ResponsesClient.Tool(type: .function,
                                 name: "finish",
                                 description: "Finish interaction with user",
                                 parameters: ResponsesClient.Parameter(type: "object", properties: [:], required: []))

    let configuration = Agent.Configuration(instructions: instructions,
                                            tools: [getItemTool, createItemTool, updateItemTool, deleteItemTool, completeItemTool, getAllItemsTool, finishTool],
                                            model: .gpt4_1)

    return Agent(openAI: openAI, configuration: configuration, functionHandler: functionHandler)
}

enum AgentError: Error {
    case handlerNotReady
    case unknownFunction(name: String)
}

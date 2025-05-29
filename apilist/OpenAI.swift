//
//  OpenAI.swift
//  apilist
//
//  Created by Marco Mustapic on 23/05/2025.
//
import AnyCodable
import Foundation

class OpenAI {
    let apiKey: String

    struct TranscribeResponse: Decodable {
        let text: String
    }

    public func transcribe(wav: Data) async throws -> String {
        var urlRequest = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let multiPart = HTTPMultiPart()
        urlRequest.setValue("multipart/form-data; boundary=\(multiPart.boundary)", forHTTPHeaderField: "Content-Type")
        multiPart.append(name: "model", value: "gpt-4o-transcribe")
        multiPart.append(name: "file", value: wav, type: .file(filename: "data.wav"))
        urlRequest.httpBody = multiPart.httpBody

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode == 200 {
            let transcribeResponse = try JSONDecoder().decode(TranscribeResponse.self, from: data)
            return transcribeResponse.text
        } else {
//            print("response: \(response), data: \(String(data: data, encoding: .utf8) ?? "no data")")
            return "nothing"
        }
    }

//    public func conversation(configuration: ConversationConfiguration) -> Conversation {
//        return Conversation(configuration: configuration)
//    }
//
    public enum Model: String, Codable {
        case gpt4o = "gpt-4o"
        case gpt4_1 = "gpt-4.1"
        case gpt4_1_mini = "gpt-4.1-mini"
        case gpt4_1_nano = "gpt-4.1-nano"
    }

    public static let shared: OpenAI = OpenAI()

    private init() {
        self.apiKey = Bundle.main.infoDictionary?["OPENAI_API_KEY"] as? String ?? ""
    }
}

class ResponsesClient {
    let openAI: OpenAI

    init(openAI: OpenAI) {
        self.openAI = openAI
    }

    func send(request: ResponsesRequest) async throws -> ResponsesResponse {
        var urlRequest = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(openAI.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // add tools only if
        let body = try JSONEncoder().encode(request)
        urlRequest.httpBody = body

        let prettyEncoder = JSONEncoder()
        prettyEncoder.outputFormatting = .prettyPrinted
        let encodedData = try prettyEncoder.encode(request)
//        print(">>>>>>>> REQUEST")
//        print(String(data: encodedData, encoding: .utf8)!)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
//        print("<<<<<<<< RESPONSE")
//        print(String(data: data, encoding: .utf8)!)
        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode == 200 {
            return try JSONDecoder().decode(ResponsesResponse.self, from: data)
        } else {
            let error = try JSONDecoder().decode(ResponsesError.self, from: data)
            throw error
        }
    }

    struct FunctionCall: Codable {
        let id: String
        let callId: String
        let name: String
        let arguments: String
    }

    enum Role: String, Codable {
        case user = "user"
        case developer = "developer"
        case assistant = "assistant"
    }

    struct Tool: Encodable {
        let type: ToolType
        let name: String
        let description: String
        let parameters: Parameter?
        let strict: Bool

        init(type: ToolType, name: String, description: String, parameters: Parameter? = nil, strict: Bool = true) {
            self.type = type
            self.name = name
            self.description = description
            self.parameters = parameters
            self.strict = strict
        }
    }

    struct Parameter: Encodable {
        let type: String
        let description: String?
        let properties: [String : Parameter]?
        let required: [String]?
        let additionalProperties: Bool

        init(type: String, description: String? = nil, properties: [String : Parameter]? = nil, required: [String]? = nil, additionalProperties: Bool = false) {
            self.type = type
            self.description = description
            self.properties = properties
            self.required = required
            self.additionalProperties = additionalProperties
        }
    }

    enum ParameterType: String, Encodable {
        case string = "string"
        case number = "number"
        case array = "array"
        case object = "object"
    }

    enum ToolType: String, Encodable {
        case function = "function"
    }

    struct ResponsesRequest: Encodable {
        let model: OpenAI.Model
        let input: [Input]
        let tools: [Tool]
        let previousResponseId: String?

        private enum CodingKeys : String, CodingKey {
            case model = "model"
            case input = "input"
            case tools = "tools"
            case previousResponseId = "previous_response_id"
        }

        enum Input: Encodable {
            case text(Text)
            case functionCall(FunctionCall)
            case functionCallOutput(FunctionCallOutput)

            struct Text: Encodable {
                let role: Role
                let content: String
            }

            struct FunctionCallOutput: Encodable {
                let callId: String
                let output: String?
            }

            enum CodingKeys: String, CodingKey {
                case role = "role"
                case content = "content"
                case id = "id"
                case callId = "call_id"
                case output = "output"
                case type = "type"
                case name = "name"
                case arguments = "arguments"
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .text(let content):
                    try container.encode(content.role, forKey: .role)
                    try container.encode(content.content, forKey: .content)
                case .functionCall(let content):
                    try container.encode(content.id, forKey: .id)
                    try container.encode(content.callId, forKey: .callId)
                    try container.encode(content.name, forKey: .name)
                    try container.encode(content.arguments, forKey: .arguments)
                    try container.encode("function_call", forKey: .type)
                case .functionCallOutput(let content):
                    try container.encode(content.callId, forKey: .callId)
                    try container.encode(content.output, forKey: .output)
                    try container.encode("function_call_output", forKey: .type)
                }
            }
        }
    }

    struct ResponsesResponse: Decodable {
        let id: String
        let previousResponseId: String?
        let output: [Output]
        let status: Status

        // no idea if all of thse are necessary
        enum Status: String, Codable {
            case completed = "completed"
            case queued = "queued"
            case inProgress = "in_progress"
            case cancelling = "cancelling"
            case requiresAction = "requires_action"
            case cancelled = "cancelled"
            case failed = "failed"
            case incomplete = "incomplete"
            case expired = "expired"
        }

        private enum CodingKeys: String, CodingKey {
            case id = "id"
            case previousResponseId = "previous_response_id"
            case output = "output"
            case status = "status"
        }

        enum Output: Decodable {
            case message(Message)
            case functionCall(FunctionCall)

            struct Message: Decodable {
                let id: String
                let role: Role
                let content: [MessageContent]
            }

            enum MessageContentType: String, Decodable {
                case outputText = "output_text"
            }

            struct MessageContent: Decodable {
                let type: MessageContentType
                let text: String
                let annotations: [MessageAnnotation]
            }

            struct MessageAnnotation: Decodable {
                let type: String
                let startIndex: String
                let endIndex: String
                let url: String?
                let title: String?
            }

            private enum CodingKeys : String, CodingKey {
                case type = "type"
                case content = "content"
                case role = "role"
                case id = "id"
                case callId = "call_id"
                case output = "output"
                case name = "name"
                case arguments = "arguments"
            }

            enum ResponseType: String, Decodable {
                case message = "message"
                case functionCall = "function_call"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let type = try container.decode(ResponseType.self, forKey: .type)
                switch type {
                case .message:
                    let id = try container.decode(String.self, forKey: .id)
                    let role = try container.decode(Role.self, forKey: .role)
                    let content = try container.decode([MessageContent].self, forKey: .content)
                    self = .message(Message(id: id, role: role, content: content))
                case .functionCall:
                    let id = try container.decode(String.self, forKey: .id)
                    let callId = try container.decode(String.self, forKey: .callId)
                    let name = try container.decode(String.self, forKey: .name)
                    let arguments = try container.decode(String.self, forKey: .arguments)
                    self = .functionCall(FunctionCall(id: id, callId: callId, name: name, arguments: arguments))
                }
            }
        }
    }

    struct ResponsesError: Error, Decodable {
        let error: Error

        struct Error: Decodable {
            let message: String
            let type: String
            let param: String?
            let code: String?
        }
    }
}

enum OpenAIError: Error {
    case decoding(json: String?)
    case structured(message: String, type: String, param: String?, code: String?)
    case functionCall(name: String, arguments: String, error: Error)

    var localzedDescription: String {
        switch self {
        case .decoding(let data): "Error decoding response, data '\(data ?? "nil")'"
        case .structured(let message, let type, let param, let code): "OpenAI Error '\(message)', type: '\(type)', param: '\(param ?? "nil")', code: '\(code ?? "nil")'"
        case .functionCall(let name, let arguments, let error): "Error calling function \(name) with arguments \(arguments), \(error.localizedDescription)"
        }
    }
}

class HTTPMultiPart {
    private class Part {
        let name: String
        let value: Data
        let type: PartType

        init(name: String, value: Data, type: PartType = .input) {
            self.name = name
            self.value = value
            self.type = type
        }
    }

    enum PartType {
        case input
        case file(filename: String)
    }

    let boundary: String
    private var parts: [Part] = []

    init(boundary: String = UUID().uuidString) {
        self.boundary = boundary
    }

    func append(name: String, value: Data, type: PartType = .input) {
        parts.append(Part(name: name, value: value, type: type))
    }

    func append(name: String, value: String) {
        parts.append(Part(name: name, value: value.data(using: .utf8)!, type: .input))
    }

    var httpBody: Data {
        var data = Data()
        parts.forEach { part in
            data.append("--\(boundary)\r\n".data(using: .utf8)!)
            let filenameParam = if case .file(let filename) = part.type {
                "; filename=\"\(filename)\""
            } else {
                ""
            }
            data.append("Content-Disposition: form-data; name=\"\(part.name)\"\(filenameParam)\r\n".data(using: .utf8)!)
            let contentType = switch part.type {
            case .input: "text/plain"
            case .file: "application/octet-stream"
            }
            data.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
            data.append(part.value)
            data.append("\r\n".data(using: .utf8)!)
        }
        data.append("--\(boundary)--\r\n".data(using: .utf8)!)  // final boundary
        return data
    }
}

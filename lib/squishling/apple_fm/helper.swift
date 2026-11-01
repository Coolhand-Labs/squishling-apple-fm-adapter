import Foundation
import FoundationModels

// Reads one JSON request on stdin, writes one JSON line on stdout. Exit status is 0 whenever a line was written.
// Request:  {"instructions": String?, "messages": [{"role": "user"|"assistant", "content": String}],
//            "schema": <JSON Schema decodable as GenerationSchema>, "temperature": Double?, "max_tokens": Int?}
// Success:  {"content": String, "usage": {"input_tokens": Int, "output_tokens": Int}?, "finish_reason": "max_tokens"?}
// Failure:  {"error": <code>}, never the model's or the system's own message

func emit(_ object: [String: Any]) -> Never {
  let data = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{\"error\":\"other\"}".utf8)
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data("\n".utf8))
  exit(0)
}

func segments(_ text: String) -> [Transcript.Segment] {
  [.text(Transcript.TextSegment(content: text))]
}

func unavailability(_ model: SystemLanguageModel) -> String? {
  switch model.availability {
  case .available: return nil
  case .unavailable(let reason):
    switch reason {
    case .deviceNotEligible: return "device_not_eligible"
    case .appleIntelligenceNotEnabled: return "apple_intelligence_not_enabled"
    case .modelNotReady: return "model_not_ready"
    @unknown default: return "unavailable"
    }
  }
}

// Token counts need macOS 26.4; on anything older, or if counting fails, the answer simply carries no usage.
func usage(_ model: SystemLanguageModel, entries: [Transcript.Entry], schema: GenerationSchema, answer: String) async -> [String: Int] {
  guard #available(macOS 26.4, *) else { return [:] }
  var counts: [String: Int] = [:]
  if let prompt = try? await model.tokenCount(for: entries), let shape = try? await model.tokenCount(for: schema) {
    counts["input_tokens"] = prompt + shape
  }
  if let generated = try? await model.tokenCount(for: answer) { counts["output_tokens"] = generated }
  return counts
}

func failure(_ error: Error) -> String {
  guard let generation = error as? LanguageModelSession.GenerationError else { return "other" }
  switch generation {
  case .exceededContextWindowSize: return "context_window"
  case .guardrailViolation: return "guardrail"
  case .unsupportedLanguageOrLocale: return "unsupported_language"
  case .rateLimited: return "rate_limited"
  case .assetsUnavailable: return "model_not_ready"
  default: return "generation"
  }
}

// With max_tokens set, a reply cut off at the limit is truncated JSON that the framework can't decode, and it reports
// only a decoding failure, so any decoding failure with a limit set is treated as a cutoff. The partial text isn't
// kept: the answer is empty and says why, so Squishling can tell a cutoff from a wrong answer.
func isCutoff(_ error: Error, limit: Int?) -> Bool {
  guard limit != nil, let generation = error as? LanguageModelSession.GenerationError else { return false }
  if case .decodingFailure = generation { return true }
  return false
}

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let request = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
      let messages = request["messages"] as? [[String: String]], let last = messages.last,
      let schemaObject = request["schema"] else { emit(["error": "bad_request"]) }

let model = SystemLanguageModel.default
if let reason = unavailability(model) { emit(["error": reason]) }

let schema: GenerationSchema
do {
  let data = try JSONSerialization.data(withJSONObject: schemaObject)
  schema = try JSONDecoder().decode(GenerationSchema.self, from: data)
} catch { emit(["error": "unsupported_schema"]) }

var entries: [Transcript.Entry] = []
if let instructions = request["instructions"] as? String, !instructions.isEmpty {
  entries.append(.instructions(Transcript.Instructions(segments: segments(instructions), toolDefinitions: [])))
}
for message in messages.dropLast() {
  let text = message["content"] ?? ""
  if message["role"] == "assistant" {
    entries.append(.response(Transcript.Response(assetIDs: [], segments: segments(text))))
  } else {
    entries.append(.prompt(Transcript.Prompt(segments: segments(text))))
  }
}

var options = GenerationOptions()
if let temperature = request["temperature"] as? Double { options.temperature = temperature }
let limit = request["max_tokens"] as? Int
if let limit { options.maximumResponseTokens = limit }

do {
  let session = LanguageModelSession(model: model, tools: [], transcript: Transcript(entries: entries))
  let prompt = last["content"] ?? ""
  let response = try await session.respond(to: prompt, schema: schema, options: options)
  let asked = entries + [.prompt(Transcript.Prompt(segments: segments(prompt)))]
  let counts = await usage(model, entries: asked, schema: schema, answer: response.content.jsonString)
  emit(["content": response.content.jsonString, "usage": counts])
} catch {
  if isCutoff(error, limit: limit) { emit(["content": "", "finish_reason": "max_tokens"]) }
  emit(["error": failure(error)])
}

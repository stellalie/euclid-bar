import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// `euclid-bar --ai "<prompt>"`: Apple's on-device model. Free, private, no account or key;
/// needs macOS 26 with Apple Intelligence on. `--ai --check` exits 0 when it's ready.
/// The `ai` plugin uses it unless you set another CLI.
enum AppleAI {
    static func run(_ args: [String]) -> Int32 {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return respond(args) }
        #endif
        fail("Apple's on-device model needs macOS 26 with Apple Intelligence")
        return 1
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    private static func respond(_ args: [String]) -> Int32 {
        let model = SystemLanguageModel.default
        if case .unavailable(let reason) = model.availability {
            switch reason {
            case .deviceNotEligible: fail("this Mac can't run Apple Intelligence")
            case .appleIntelligenceNotEnabled: fail("turn on Apple Intelligence in System Settings")
            case .modelNotReady: fail("Apple Intelligence is still getting ready; try again in a few minutes")
            @unknown default: fail("Apple's on-device model isn't available")
            }
            return 1
        }
        if args.first == "--check" { return 0 }
        let prompt = args.joined(separator: " ")
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail("usage: euclid-bar --ai <prompt>")
            return 64
        }
        let box = AnswerBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.result = .success(try await LanguageModelSession().respond(to: prompt).content) }
            catch { box.result = .failure(error) }
            done.signal()
        }
        done.wait()
        switch box.result {
        case .success(let text):
            print(text)
            return 0
        case .failure(let error):
            fail("Apple's on-device model: \(error.localizedDescription)")
            return 1
        }
    }
    #endif

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

private final class AnswerBox: @unchecked Sendable {
    var result: Result<String, Error> = .success("")
}

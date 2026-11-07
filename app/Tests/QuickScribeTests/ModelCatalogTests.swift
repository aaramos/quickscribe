import XCTest
@testable import QuickScribeCore

/// The menu's model lists: which of a service's models go to Speech, which to
/// Clean Up, and which stay out of the menu. The first list is the owner's own
/// server, copied from its GET /models reply; the second is what a plain
/// OpenAI-style server sends, with no model_type at all.
final class ModelCatalogTests: XCTestCase {

    /// The owner's 16 models exactly as that server lists them.
    private let ownerServer: [ModelEntry] = [
        ModelEntry(id: "Muse-Glimmer-30B-oQ4e", modelType: "vlm"),
        ModelEntry(id: "Qwen3.8-27B-4bit", modelType: "vlm"),
        ModelEntry(id: "Qwen3.8-Flash-Next-oQ4e-mtp", modelType: "vlm"),
        ModelEntry(id: "Qwen3-ASR-1.7B-8bit", modelType: "audio_stt"),
        ModelEntry(id: "Qwen3-Embedding-0.6B-4bit-DWQ", modelType: "embedding"),
        ModelEntry(id: "Qwen3-Reranker-0.6B-4bit", modelType: "reranker"),
        ModelEntry(id: "Qwen3.6-35B-A3B-4bit", modelType: "vlm"),
        ModelEntry(id: "Qwen3.8-27B-Uncensored-MLX", modelType: "vlm"),
        ModelEntry(id: "Qwen3.8-Flash-Next-UD-Q4_K_XL", modelType: "vlm"),
        ModelEntry(id: "clef-flash-oQ4e", modelType: "decision"),
        ModelEntry(id: "cohere-transcribe-03-2026-mlx-8bit", modelType: "audio_stt"),
        ModelEntry(id: "gemma-4-12B-it-oQ8e-mtp", modelType: "vlm"),
        ModelEntry(id: "granite-speech-4.1-2b-nar-mlx", modelType: "audio_stt"),
        ModelEntry(id: "parakeet-tdt-0.6b-v3", modelType: "audio_stt"),
        ModelEntry(id: "whisper-large-v3-8bit", modelType: "audio_stt"),
        ModelEntry(id: "MarkItDown", modelType: "markitdown"),
    ]

    func testTheOwnersServerSplitsExactlyAsTheBriefSays() {
        let lists = ModelCatalog.split(ownerServer)
        XCTAssertEqual(Set(lists.speech), Set([
            "Qwen3-ASR-1.7B-8bit",
            "cohere-transcribe-03-2026-mlx-8bit",
            "granite-speech-4.1-2b-nar-mlx",
            "parakeet-tdt-0.6b-v3",
            "whisper-large-v3-8bit",
        ]))
        XCTAssertEqual(Set(lists.hidden), Set([
            "Qwen3-Embedding-0.6B-4bit-DWQ",
            "Qwen3-Reranker-0.6B-4bit",
            "clef-flash-oQ4e",
            "MarkItDown",
        ]))
        XCTAssertEqual(Set(lists.cleanup), Set([
            "Muse-Glimmer-30B-oQ4e",
            "Qwen3.8-27B-4bit",
            "Qwen3.8-Flash-Next-oQ4e-mtp",
            "Qwen3.6-35B-A3B-4bit",
            "Qwen3.8-27B-Uncensored-MLX",
            "Qwen3.8-Flash-Next-UD-Q4_K_XL",
            "gemma-4-12B-it-oQ8e-mtp",
        ]))
        XCTAssertEqual(lists.speech.count, 5, "5 speech")
        XCTAssertEqual(lists.cleanup.count, 7, "7 clean up")
        XCTAssertEqual(lists.hidden.count, 4, "4 hidden")
        XCTAssertEqual(lists.speech.count + lists.cleanup.count + lists.hidden.count, 16,
                       "every model lands somewhere; nothing vanishes")
    }

    func testTheOrderTheServiceGaveIsKept() {
        let lists = ModelCatalog.split(ownerServer)
        XCTAssertEqual(lists.speech, ["Qwen3-ASR-1.7B-8bit", "cohere-transcribe-03-2026-mlx-8bit",
                                      "granite-speech-4.1-2b-nar-mlx", "parakeet-tdt-0.6b-v3",
                                      "whisper-large-v3-8bit"],
                       "the menu lists them in the server's order, not resorted")
        XCTAssertEqual(lists.cleanup.first, "Muse-Glimmer-30B-oQ4e")
    }

    /// A plain OpenAI-style server sends ids only. Nothing may disappear just
    /// because the service does not say what kind each model is.
    func testAPlainServerWithNoTypesIsSplitByName() {
        let plain = ["gpt-4o-transcribe", "gpt-4o-mini-tts", "whisper-1", "text-embedding-3-large",
                     "gpt-4o", "o3-mini", "parakeet-tdt-0.6b-v3", "some-image-editor"]
                     .map { ModelEntry(id: $0) }
        let lists = ModelCatalog.split(plain)
        XCTAssertEqual(lists.speech, ["gpt-4o-transcribe", "whisper-1", "parakeet-tdt-0.6b-v3"])
        XCTAssertEqual(lists.hidden, ["gpt-4o-mini-tts", "text-embedding-3-large", "some-image-editor"])
        XCTAssertEqual(lists.cleanup, ["gpt-4o", "o3-mini"],
                       "a name that matches nothing is offered for cleanup, never dropped")
    }

    func testNamesThatWouldBeMisfiled() {
        func kind(_ id: String, _ type: String? = nil) -> ModelCatalog.Kind {
            ModelCatalog.kind(of: ModelEntry(id: id, modelType: type))
        }
        // The name rule is case-insensitive and matches inside the name.
        XCTAssertEqual(kind("Whisper-Large-V3"), .speech)
        XCTAssertEqual(kind("Systran/faster-whisper-small"), .speech)
        XCTAssertEqual(kind("Qwen3-ASR-1.7B"), .speech)
        XCTAssertEqual(kind("my-stt-model"), .speech)
        XCTAssertEqual(kind("voxtral-mini"), .speech)
        XCTAssertEqual(kind("speech-2"), .speech)
        XCTAssertEqual(kind("bge-embed-large"), .hidden)
        XCTAssertEqual(kind("jina-reranker-v2"), .hidden)
        XCTAssertEqual(kind("kokoro-tts"), .hidden)
        XCTAssertEqual(kind("sdxl-image"), .hidden)
        // Everything else is cleanup, even odd names.
        XCTAssertEqual(kind("llama-3-70b"), .cleanup)
        XCTAssertEqual(kind("clef-flash-oQ4e"), .cleanup, "with no type, a decision model is just a model")
        // A stated type wins over the name in both directions.
        XCTAssertEqual(kind("whisper-large-v3", "vlm"), .cleanup, "the service says chat model: believe it")
        XCTAssertEqual(kind("gpt-4o", "audio_stt"), .speech)
        XCTAssertEqual(kind("embed-this", "llm"), .cleanup)
        XCTAssertEqual(kind("gpt-4o", "embedding"), .hidden)
        // A blank type reads as no type at all.
        XCTAssertEqual(kind("whisper-1", ""), .speech)
        XCTAssertEqual(kind("whisper-1", "  "), .speech)
    }

    func testEveryTypeTheOwnerSawIsCovered() {
        for type in ["vlm", "audio_stt", "embedding", "reranker", "decision", "markitdown"] {
            let kind = ModelCatalog.kind(of: ModelEntry(id: "any-name", modelType: type))
            switch type {
            case "vlm": XCTAssertEqual(kind, .cleanup, type)
            case "audio_stt": XCTAssertEqual(kind, .speech, type)
            default: XCTAssertEqual(kind, .hidden, "\(type) has no business in a speech or cleanup list")
            }
        }
        XCTAssertEqual(ModelCatalog.kind(of: ModelEntry(id: "x", modelType: "stt")), .speech)
        XCTAssertEqual(ModelCatalog.kind(of: ModelEntry(id: "x", modelType: "asr")), .speech)
        XCTAssertEqual(ModelCatalog.kind(of: ModelEntry(id: "x", modelType: "llm")), .cleanup)
    }

    func testDuplicatesAndBlanksNeverMakeTwoEntries() {
        let lists = ModelCatalog.split([ModelEntry(id: "a"), ModelEntry(id: "a"), ModelEntry(id: "  "),
                                        ModelEntry(id: " whisper-1 "), ModelEntry(id: "whisper-1")])
        XCTAssertEqual(lists.speech, ["whisper-1"], "trimmed, and the second sighting is not a second entry")
        XCTAssertEqual(lists.cleanup, ["a"])
        XCTAssertEqual(lists.hidden, [], "a blank id is not a hidden model, it is no model")
    }
}

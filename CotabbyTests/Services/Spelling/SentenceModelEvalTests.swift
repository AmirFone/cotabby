import XCTest
@testable import Cotabby

/// Runs the installed sentence model, through the same service and decoder the app uses, over a
/// file of test sentences and writes its answers for `Tools/sentence-model/gate_report.py`.
///
/// This is a measurement, not a pass/fail test, and it needs the 640 MB model, so it only runs when
/// asked for:
///
///     TEST_RUNNER_SENTENCE_MODEL_SET=<set.tsv> TEST_RUNNER_SENTENCE_MODEL_OUT=<out.tsv> \
///       xcodebuild test ... -only-testing:CotabbyTests/SentenceModelEvalTests
///
/// (`xcodebuild` hands variables prefixed `TEST_RUNNER_` to the test process without the prefix.)
/// `TEST_RUNNER_SENTENCE_MODEL_FILE=<model.gguf>` scores a model other than the installed one.
/// Input lines are `<kind><TAB><intended><TAB><typed>`; output lines add the answer, the
/// milliseconds it took, each word's log-probability, and the number of model passes.
final class SentenceModelEvalTests: XCTestCase {
    func test_writeAnswersForTheSentenceSet() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let setPath = environment["SENTENCE_MODEL_SET"], let outPath = environment["SENTENCE_MODEL_OUT"] else {
            throw XCTSkip("Set SENTENCE_MODEL_SET and SENTENCE_MODEL_OUT to run the sentence model evaluation.")
        }
        let installedURL = await SentenceModelService.defaultModelURL()
        let modelURL = environment["SENTENCE_MODEL_FILE"].map { URL(fileURLWithPath: $0) } ?? installedURL
        let service = SentenceModelService(modelURL: modelURL)
        guard service.isInstalled else { throw XCTSkip("No sentence model at \(modelURL.path).") }

        let rows = try String(contentsOfFile: setPath, encoding: .utf8).split(separator: "\n").map { $0.components(separatedBy: "\t") }
        _ = await service.correct("Warm up the modle.")
        var lines: [String] = []
        var times: [Double] = []
        for row in rows where row.count >= 3 {
            let started = DispatchTime.now().uptimeNanoseconds
            let output = await service.correct(row[2])
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            times.append(milliseconds)
            let words = output?.words ?? []
            lines.append([
                row[0], row[1], row[2],
                words.map(\.text).joined(separator: " "),
                String(format: "%.0f", milliseconds),
                words.map { String(format: "%.4f", log(max($0.probability, 1e-9))) }.joined(separator: " "),
                words.map { _ in String(output?.passes ?? 0) }.joined(separator: " ")
            ].joined(separator: "\t"))
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
        times.sort()
        print("SENTENCE_MODEL_EVAL \(rows.count) sentences, median \(Int(times[times.count / 2])) ms, 90% within \(Int(times[times.count * 9 / 10])) ms")
    }
}

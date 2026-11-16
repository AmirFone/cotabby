import Foundation

/// File overview:
/// Evaluates a trained gradient-boosted tree ensemble (LightGBM, exported by `Tools/autofix`). Two
/// spelling decisions use one: which fix for a misspelled word to put first and whether to apply it
/// unasked (`AutoFixFeatures`), and whether a correctly spelled word is the wrong word
/// (`WrongWordDetector`). Each has its own model file and feature list; the arithmetic is the same.
///
/// Each tree is stored as parallel arrays: an inner node compares one feature with a threshold and
/// goes left when it is less or equal; a leaf (feature index -1) contributes its value. The sum over
/// trees is a log-odds. A few hundred trees a handful of levels deep cost a few microseconds, so
/// this runs synchronously wherever the decision is needed.
nonisolated struct TreeEnsembleModel: Sendable {
    struct Tree: Decodable, Sendable {
        let feature: [Int]
        let threshold: [Double]
        let left: [Int]
        let right: [Int]
        let value: [Double]
    }

    private struct File: Decodable {
        let features: [String]
        let threshold: Double
        let caretThreshold: Double?
        let trees: [Tree]
    }

    let trees: [Tree]
    /// The probability the model was tuned to act at (see the training scripts).
    let threshold: Double
    /// Wrong-word model only: the stricter bar for judging a word at the caret, where nothing to its
    /// right has been typed yet. Nil in a file that was not tuned for that use.
    let caretThreshold: Double?
    private let featureCount: Int

    /// Nil when the data is not a model for exactly `featureNames`: a model trained on other inputs
    /// must be ignored (callers fall back to their hand rules) rather than read the wrong columns.
    init?(data: Data, featureNames: [String]) {
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.features == featureNames,
              !file.trees.isEmpty,
              file.trees.allSatisfy({ tree in
                  let count = tree.feature.count
                  return count > 0 && tree.threshold.count == count && tree.left.count == count
                      && tree.right.count == count && tree.value.count == count
                      && tree.feature.allSatisfy { $0 < featureNames.count }
                      && tree.left.allSatisfy { $0 < count } && tree.right.allSatisfy { $0 < count }
              }) else {
            return nil
        }
        trees = file.trees
        threshold = file.threshold
        caretThreshold = file.caretThreshold
        featureCount = featureNames.count
    }

    static func bundled(named name: String, featureNames: [String], in bundle: Bundle = .main) -> TreeEnsembleModel? {
        guard let url = bundle.url(forResource: name, withExtension: "json"), let data = try? Data(contentsOf: url) else {
            return nil
        }
        return TreeEnsembleModel(data: data, featureNames: featureNames)
    }

    func probability(features: [Double]) -> Double {
        guard features.count == featureCount else { return 0 }
        var logOdds = 0.0
        for tree in trees {
            var node = 0
            // A tree is at most a few levels deep; the bound only guards a malformed cycle.
            for _ in 0..<64 {
                let feature = tree.feature[node]
                if feature < 0 { break }
                node = features[feature] <= tree.threshold[node] ? tree.left[node] : tree.right[node]
            }
            logOdds += tree.value[node]
        }
        return 1 / (1 + exp(-logOdds))
    }
}

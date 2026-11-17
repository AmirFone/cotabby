# Word prediction: test data, method, results

How often is the first word in the strip the word the writer is about to type, and does the right
form of a verb come before its other forms? This folder holds the test data and the notes; the
measurements are made by the app's own engine through `cotabby-spell --typing`.

## What is measured

A text is "typed" word by word, exactly as written, punctuation and earlier sentences included. At
every moment (before a word's first letter, after one letter, after two, ...) the engine is asked
what the strip would show. Names and numbers are not scored.

- **First suggestion right:** the first word shown is the word, by letters typed so far, and over
  all moments together.
- **Tense test:** for a verb with at least three forms (`walk`, `walks`, `walked`, `walking`;
  `verb_forms.txt`), the letters all its forms share are typed (`walk`). Right when the form the
  sentence really has is listed before the other forms.
- **Typing a misspelling:** a misspelled word is typed letter by letter; from the letter where it
  goes wrong, is the word that was meant offered?
- **Keys saved:** by a writer who only ever takes the first suggestion, as soon as it is right.

## Test data

| File | What | Used for |
|---|---|---|
| `passages-dev.jsonl` | 136 passages, five writers | tuning the three numbers below |
| `passages-test.jsonl` | 147 passages, five other writers | scored once, after tuning |
| `passages-fresh.jsonl` | 295 passages, ten more writers on other themes, written after tuning | scored only |
| real held-out sentences | every 50th sentence of the context-table corpora (`Tools/ngram/`) | scored only |

The passages are 3 to 5 sentences each, with a declared tense (past, present, future, or mixed),
and a second copy with a few misspellings. They were written by twenty language-model writers, each
given a different theme, voice and list of random seed words so that they do not all fall into the
same phrasing (`writer-brief.txt`). The dev/test split is by writer, so no writer's style is on
both sides. A few passages that touched private themes were removed by hand. `merge_passages.py`
checks and merges the writers' files.

Why generated passages as well as real sentences: the real corpora are single sentences in random
order, and tense is mostly set by the sentences before. The passages are what test that.

## Run it

```sh
xcodebuild -project Cotabby.xcodeproj -scheme cotabby-spell -configuration Release \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/CotabbyFork-CLI build
CLI=~/Library/Developer/Xcode/DerivedData/CotabbyFork-CLI/Build/Products/Release/cotabby-spell
MODELS="$HOME/Library/Application Support/Cotabby Dev/LlamaRuntime"

# The word table alone, then with a language model (any GGUF the app can use)
$CLI --typing Tools/prediction/passages-test.jsonl 200 --verbs Tools/prediction/verb_forms.txt
$CLI --typing Tools/prediction/passages-test.jsonl 200 --verbs Tools/prediction/verb_forms.txt \
  --lm "$MODELS/gemma-4-E2B.i1-Q6_K.gguf"

$CLI --predict "Yesterday we walk|" --lm "$MODELS/gemma-4-E2B.i1-Q6_K.gguf"   # one list
E2E_ONLY=tense Tools/e2e/live-smoke.sh                                         # in the running app

# The app's own service (queue, callbacks, refinement) against a real model, no screen needed
TEST_RUNNER_WORD_LM_FILE="$MODELS/gemma-4-E2B.i1-Q6_K.gguf" xcodebuild test -project Cotabby.xcodeproj \
  -scheme Cotabby -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/CotabbyFork-Check \
  -only-testing:CotabbyTests/WordLanguageModelLiveTests
```

`TYPING_MISSES=<file>` writes every moment the first suggestion was wrong. `MIX_TABLE_WEIGHT`,
`MIX_SLIP_PENALTY` and `MIX_CANDIDATES` try other mixing numbers without rebuilding; `NO_REFINE=1`
leaves out the exact second pass. Several runs can go at once; the pass times printed are only
meaningful for a run on its own.

## Results

First suggestion is the word (held-back test passages, 147 passages, 8,585 words):

| Letters typed | 0 | 1 | 2 | 3 | 4 | 5 | all moments | keys saved | right verb form first |
|---|---|---|---|---|---|---|---|---|---|
| word table only | 11.6% | 34.2% | 43.3% | 56.7% | 56.6% | 62.1% | 38.4% | 32.0% | 54.3% |
| Gemma 4 E2B | 34.1% | 68.6% | 80.6% | 90.1% | 92.2% | 93.6% | 69.8% | 56.8% | 92.9% |
| Qwen 3.5 2B base | 32.3% | 65.7% | 77.3% | 86.7% | 89.7% | 90.8% | 67.1% | 54.4% | 91.3% |
| Qwen 3.5 0.8B base | 29.9% | 62.4% | 75.0% | 85.6% | 89.5% | 90.7% | 65.1% | 52.9% | 91.0% |
| the sentence model's file | 21.5% | 51.9% | 67.1% | 79.5% | 85.1% | 88.4% | 57.6% | 47.1% | 84.3% |

The same engines on the other sets, all moments / right verb form first:

| | tuning passages | test passages | fresh passages | 1,500 real held-out sentences |
|---|---|---|---|---|
| word table only | 36.3% / 51.5% | 38.4% / 54.3% | 37.4% / 53.8% | 44.0% / 63.8% |
| Gemma 4 E2B | 67.2% / 92.4% | 69.8% / 92.9% | 68.4% / 92.6% | 61.2% / 85.6% |
| Qwen 3.5 2B base | 65.0% / 89.5% | 67.1% / 91.3% | 65.3% / 90.3% | not run |
| Qwen 3.5 0.8B base | 62.6% / 89.1% | 65.1% / 91.0% | 63.3% / 89.8% | 56.8% / 82.5% |
| the sentence model's file | 55.3% / 82.8% | 57.6% / 84.3% | 56.0% / 83.8% | 52.0% / 79.5% |

The test and fresh passages score as well as the tuning passages or better, so the numbers below
were not fitted to the tuning set. The real sentences gain less, as expected: each one stands
alone, with no earlier sentence to set the tense, and the word table was built from the same
corpora (though not from these sentences), which helps it more there than on other writing. With
Gemma the first suggestion on them is right 28.7% / 58.0% / 68.7% / 80.2% / 84.9% after 0 to 4
letters.

Typing a misspelling, from the letter where it goes wrong (test passages): the word meant is first
38.0% of the time with the table alone and 67.9% with Gemma.

One pass of the model, run on its own on an M3 Max: Gemma 4 E2B 11 ms, Qwen 3.5 0.8B 6 ms, the
sentence model's file 5 ms. In the running app, sharing the GPU: 15 to 25 ms.

## What was tuned, and what was tried

Three numbers, all in `NextWordPredictor.LanguageModelMix`, chosen on the tuning passages:

- **Table weight 0.05.** A word's score is the model's log-probability plus this much of the word
  table's log score. 0.05 was as good as or better than 0.15 and 0.3 with every model; the table
  mostly matters for words the model's dictionary does not have (the writer's own names).
- **Slip penalty 0.005.** What a word that does not start with the typed letters is multiplied by.
  At 0.5 near misses crowded out exact completions (`with` first while typing `withou`), costing
  four points from the fourth letter on; at 0.00001 a misspelled start stopped finding its word.
- **12 of the model's own words** join the table's candidates.

Tried and not kept:

- **The model ordering the spelling bar's fixes.** Of finished misspellings, the engine's own order
  puts the word first in 22.2% (72.1% more are fixed unasked); ordered by the model, 21.6%.
- **The larger Gemma (E4B, 5.3 GB):** no better than E2B on the tuning passages (65.3% against
  65.7% in the comparison run, made before the final mixing numbers), at half again the time per word.
- **An exact second pass for every word.** Kept only where the typed letters leave several words
  sharing a first piece; it adds 0.3 points overall and one point on the tense test.

Before any letter is typed, about a third is where every model lands: many words are possible
there, and no ordering can know which. The gain is in how fast the list narrows once letters come.

## Files

- `passages-*.jsonl`: `id`, `register`, `tense`, `text`, and usually `typed` (the misspelled copy)
  and `fixes` (`[wrong, right]` pairs).
- `verb_forms.txt`: one verb per line with every form in the app's dictionary, built by
  `build_verb_forms.py` (needs `pip install lemminflect`).
- `writer-brief.txt`: what the writers were asked for. `merge_passages.py`: checks and merges
  their files.

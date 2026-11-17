# Word prediction: test data, method, results

How often is the first word in the strip the word the writer is about to type, and does the right
form of a verb come before its other forms? This folder holds the test data and the notes; the
measurements are made by the app's own engine through `cotabby-spell --typing`.

## What is measured

A text is "typed" word by word, exactly as written, punctuation and earlier sentences included. At
every moment (before a word's first letter, after one letter, after two, ...) the engine is asked
what the strip would show. Numbers are not scored, and names (capitalized inside a sentence) are
scored apart.

- **First suggestion right:** the first word shown is the word, by letters typed so far, over all
  moments together, and over the moments with at least one letter typed ("while typing a word").
- **Tense test:** for a verb with at least three forms (`walk`, `walks`, `walked`, `walking`;
  `verb_forms.txt`), the letters all its forms share are typed (`walk`). Right when the form the
  sentence really has is listed before the other forms.
- **Names typed again:** a name the text has already used, typed a second time: is it first, with
  its capital, once a letter is typed?
- **Typing a misspelling:** a misspelled word is typed letter by letter; from the letter where it
  goes wrong, is the word that was meant offered?
- **Keys saved:** by a writer who only ever takes the first suggestion, as soon as it is right.

## Test data

| File | What | Used for |
|---|---|---|
| `passages-dev.jsonl` | 136 passages, five writers | tuning |
| `passages-test.jsonl` | 147 passages, five other writers | scored only |
| `passages-fresh.jsonl` | 295 passages, ten more writers on other themes | scored only |
| `documents-dev.jsonl` | 50 documents of 200 to 320 words, five writers | tuning |
| `documents-test.jsonl` | 50 documents, five other writers | scored only |
| real held-out sentences | every 50th sentence of the context-table corpora (`Tools/ngram/`) | scored only |

The passages are 3 to 5 sentences each, with a declared tense (past, present, future, or mixed),
and a second copy with a few misspellings. The documents are two to four paragraphs about one
specific thing, whose own terms and names come back through the text; they test what short passages
cannot, whether the predictor follows the subject and vocabulary of a longer text. All were written
by language-model writers, each given a different theme, voice and list of random seed words so
that they do not all fall into the same phrasing (`writer-brief.txt`). Every split is by writer, so
no writer's style is on both sides. A few passages that touched private themes were removed by
hand. `merge_passages.py` and `merge_documents.py` check and merge the writers' files.

Why generated text as well as real sentences: the real corpora are single sentences in random
order, and tense, subject and names are set by the sentences before.

## Run it

```sh
xcodebuild -project Cotabby.xcodeproj -scheme cotabby-spell -configuration Release \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/CotabbyFork-CLI build
CLI=~/Library/Developer/Xcode/DerivedData/CotabbyFork-CLI/Build/Products/Release/cotabby-spell
MODELS="$HOME/Library/Application Support/Cotabby Dev/LlamaRuntime"

# The word table alone, then with a language model (any GGUF the app can use). --american scores
# what the app shows on a Mac whose region is the United States.
$CLI --typing Tools/prediction/documents-test.jsonl 200 --verbs Tools/prediction/verb_forms.txt --american
$CLI --typing Tools/prediction/documents-test.jsonl 200 --verbs Tools/prediction/verb_forms.txt --american \
  --lm "$MODELS/gemma-4-E2B.i1-Q6_K.gguf"

$CLI --predict "Yesterday we walk|" --lm "$MODELS/gemma-4-E2B.i1-Q6_K.gguf"   # one list
E2E_ONLY=tense Tools/e2e/live-smoke.sh                                         # in the running app

# The app's own service (queue, callbacks, exact passes, look-ahead) against a real model, no screen needed
TEST_RUNNER_WORD_LM_FILE="$MODELS/gemma-4-E2B.i1-Q6_K.gguf" xcodebuild test -project Cotabby.xcodeproj \
  -scheme Cotabby -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/CotabbyFork-Check \
  -only-testing:CotabbyTests/WordLanguageModelLiveTests
```

A model pass per word makes a run slow, so split the file and run the parts at once; the last line
of every run (`counts {...}`) holds the raw counts, which add up exactly across parts.

Switches, all read from the environment: `TYPING_MISSES=<file>` writes every moment the first
suggestion was wrong. `MIX_TABLE_WEIGHT`, `MIX_SLIP_PENALTY`, `MIX_CANDIDATES` try other mixing
numbers; `LM_REACH_CHARS` and `LM_REACH_STEP` another reading window; `NO_SUPPLEMENT=1` leaves out
`prediction_words_en.txt`; `NO_REFINE=1` leaves out the exact second pass; `REFINE_ROUNDS=<n>`
lifts the cap on exact rounds and prints how many each moment took. The pass times printed are only
meaningful for a run on its own.

## Results

First suggestion is the word, on sets that were never used to choose anything. "While typing" is
every moment with at least one letter typed.

Long test documents (50 documents, 13,103 words):

| Letters typed | 0 | 1 | 2 | 3 | 4 | 5 | all moments | while typing | right verb form first |
|---|---|---|---|---|---|---|---|---|---|
| word table only | 11.8% | 31.9% | 39.6% | 51.6% | 55.0% | 60.8% | 36.0% | 44.1% | 52.5% |
| Gemma 4 E2B | 37.6% | 70.9% | 83.0% | 90.1% | 92.7% | 93.7% | 71.6% | 82.9% | 93.5% |
| Qwen 3.5 2B base | 34.4% | 66.9% | 79.3% | 86.3% | 88.5% | 89.0% | 67.9% | 79.0% | 89.8% |
| Qwen 3.5 0.8B base | 31.1% | 62.5% | 75.5% | 84.2% | 87.0% | 88.0% | 64.8% | 76.0% | 88.8% |
| the sentence model's file | 22.3% | 51.6% | 66.8% | 79.2% | 84.8% | 86.7% | 57.3% | 68.9% | 83.8% |

Test passages (147 passages, 8,585 words):

| Letters typed | 0 | 1 | 2 | 3 | 4 | 5 | all moments | while typing | right verb form first |
|---|---|---|---|---|---|---|---|---|---|
| word table only | 11.6% | 34.2% | 43.3% | 56.8% | 56.8% | 62.3% | 38.4% | 47.3% | 54.3% |
| Gemma 4 E2B | 34.3% | 68.7% | 81.0% | 90.4% | 92.7% | 94.3% | 70.1% | 82.0% | 92.8% |
| Qwen 3.5 2B base | 32.3% | 65.8% | 77.8% | 86.9% | 90.2% | 91.3% | 67.3% | 79.0% | 91.3% |
| Qwen 3.5 0.8B base | 29.9% | 62.5% | 75.4% | 85.7% | 89.8% | 91.1% | 65.3% | 77.0% | 91.0% |
| the sentence model's file | 21.4% | 52.2% | 67.2% | 79.5% | 85.2% | 88.7% | 57.7% | 69.8% | 84.2% |

Gemma 4 E2B before and after the second round of changes (all moments / while typing / tense):

| | 0.2.0 engine | this engine |
|---|---|---|
| long test documents | 69.5% / 80.9% / 92.6% | 71.6% / 82.9% / 93.5% |
| test passages | 69.8% / 81.7% / 92.9% | 70.1% / 82.0% / 92.8% |
| fresh passages | 68.4% / 79.8% / 92.6% | 68.5% / 80.0% / 92.4% |
| 1,500 real held-out sentences | 60.7% / 71.4% / 84.5% | 60.8% / 71.5% / 84.3% |
| tuning documents | 67.2% / 77.9% / 91.4% | 70.2% / 81.0% / 92.6% |
| tuning passages | 67.2% / 78.2% / 92.4% | 67.5% / 78.6% / 92.3% |

The gain is where it should be: in long text, where there is more to read back and names and terms
recur. It is smaller on the test documents than on the tuning documents (2.0 points against 3.1
while typing), which is the honest size of it. Short passages and single sentences, with little to
read back, gain a fraction of a point.

Other measures, this engine with Gemma 4 E2B:

- A name the text already used, typed again, is first and capitalized as written at 91.2% of the
  moments on the long test documents. The 0.2.0 engine never offered such a name.
- Typing a misspelling, from the letter where it goes wrong (test passages): the word meant is
  first 68.9% of the time (39.0% with the table alone).
- Finished misspellings in the test passages (499): fixed unasked 72.3%, wrongly 0.4%; offered
  with the word first 22.6%, lower 2.8%; not caught 1.8%.

Real held-out sentences score lower than everything else for every engine: each stands alone, with
nothing before it to set the tense or the subject.

### Which model: accuracy against time

All on the same third of the tuning documents, with one pass timed alone on an M3 Max:

| Model | Size | While typing | Before any letter | Right verb form first | One pass |
|---|---|---|---|---|---|
| Gemma 3 12B (pt) | 7.3 GB | 83.5% | 38.8% | 94.4% | 27 ms |
| Qwen 3.5 9B base | 5.6 GB | 81.7% | 40.5% | 91.9% | 21 ms |
| Gemma 4 E4B | 5.3 GB | 81.1% | 35.8% | 92.7% | 16 ms |
| **Gemma 4 E2B** | 3.8 GB | 80.7% | 35.9% | 93.2% | 11 ms |
| Qwen 3.5 4B base | 2.7 GB | 80.5% | 38.1% | 91.8% | not timed |
| Qwen 3.5 2B base | 1.3 GB | 77.7% | 33.9% | 89.6% | 8 ms |
| Qwen 3.5 0.8B base | 0.6 GB | 74.9% | 30.6% | 89.4% | 6 ms |

Gemma 4 E2B is the choice: nothing smaller comes close, and the models up to twice its size add a
point or less. The 12B model adds about three points for two and a half times the time per word
and twice the memory. Even it is right before any letter is typed only 39% of the time: many words
are possible there, and no model that can run between two keystrokes knows which. That is why "all
moments" stays near 70% for every model while "while typing" passes 80%.

In the running app a pass takes 15 to 25 ms for Gemma 4 E2B, because the GPU is shared. Re-reading
a full reading window (about 400 pieces) takes about 25 ms on its own.

## What was tuned, and what was tried

Round one (0.2.0), three numbers in `NextWordPredictor.LanguageModelMix`, chosen on the tuning
passages:

- **Table weight 0.05.** A word's score is the model's log-probability plus this much of the word
  table's log score. 0.05 was as good as or better than 0.15 and 0.3 with every model; the table
  mostly matters for words the model's dictionary does not have.
- **Slip penalty 0.005.** What a word that does not start with the typed letters is multiplied by.
  At 0.5 near misses crowded out exact completions (`with` first while typing `withou`), costing
  four points from the fourth letter on; at 0.00001 a misspelled start stopped finding its word.
- **12 of the model's own words** join the table's candidates.

Round two started from the misses: every moment the first suggestion was wrong on the tuning sets,
sorted by kind. Three things came out of it, each measured on the tuning documents (while typing):

- **Reading further back: 77.9% to 80.5%.** The model read the last four sentences. It now reads
  the text whole up to 1,600 characters and loses the beginning in steps of 800 after that
  (`LanguageModelContext.Reach`). On a third of the documents 2,400 characters did no better
  (80.8% against 80.7%) and 1,000 did worse (79.9%).
- **Words the dictionary lacks: to 80.7%.** The spelling dictionary leans British and predates a
  lot of current vocabulary, and the model can only put a word first that is in its list:
  `neighbor`, `favorite`, `traveling`, `mom`, `you've`, `dataset` and about 1,200 more were never
  offered. `prediction_words_en.txt` adds them (`build_word_supplement.py`: words used at least 25
  times in the corpora, in lowercase, accepted by the system spell checker).
- **Real counts for contractions: to 81.0% with the next item.** The dictionary carries every
  contraction at the same placeholder count (`that's`, `you're` and `don't` all at 300,000, a
  thousandth of their real use). Once `you've` and `that'll` were added with real counts they
  outranked `you're` and `that's`: the first held-back run on real sentences came out 0.2 points
  below the 0.2.0 engine, and the misses showed why. The supplement now lists the dictionary's
  contractions again with their real counts and the larger count wins.
- **The writer's own words: names from nothing to 91%.** A name or term the text has
  already used (`Priyanka`, `cutover`, `ETL`) is in no dictionary. `TextVocabulary` finds them in
  the text the model reads and the model scores them like any word. A lowercase word needs two uses
  first, so a slip that was not corrected is not offered back.

Tried and not kept:

- **The model ordering the spelling bar's fixes.** Of finished misspellings, the engine's own order
  puts the word first in 22.2% (72.1% more are fixed unasked); ordered by the model, 21.6%.
- **Larger models as the default.** See the table above.
- **An exact second pass for every word.** Kept only where the typed letters leave several words
  sharing a first piece; it adds 0.3 points overall and one point on the tense test.
- **The app's learning of the writer's phrases** switched on for the run changed nothing here
  (80.7% both ways): it learns sentences made of dictionary words, and the test texts do not repeat
  each other.
- **Counting on the spelling preference for accuracy.** British-for-American mix-ups were 16 of
  5,077 misses, and the real-sentence score is the same with and without `--american`. The app
  still folds the two spellings into one slot (`AmericanSpellings`), because offering both is noise.

## Files

- `passages-*.jsonl`: `id`, `register`, `tense`, `text`, and usually `typed` (the misspelled copy)
  and `fixes` (`[wrong, right]` pairs). `documents-*.jsonl`: `id`, `register`, `tense`, `text`.
- `verb_forms.txt`: one verb per line with every form in the app's dictionary, built by
  `build_verb_forms.py` (needs `pip install lemminflect`).
- `writer-brief.txt`: what the writers were asked for. `merge_passages.py`, `merge_documents.py`:
  check and merge their files.
- `build_word_supplement.py` with `check_spelling.swift`: builds
  `Cotabby/Resources/prediction_words_en.txt`. `build_american_spellings.py`: builds
  `Cotabby/Resources/american_spellings_en.txt`. Both read the corpus chunks that
  `Tools/ngram/build_context_table.sh` leaves in its work folder.

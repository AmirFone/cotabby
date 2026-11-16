# Dyslexia-assist fork

Spelling help that keeps up with fast, error-heavy typing. Everything below runs on your Mac.

## Install

No Xcode needed. macOS 14 or later. Tested on an Apple Silicon Mac running macOS 26 only; the app also contains an Intel build that has not been run.

1. Download `Cotabby-Dev-<version>.dmg` from the [releases page](https://github.com/AmirFone/cotabby/releases), open it, and drag **Cotabby Dev** into Applications.
2. Open it. This build is not signed with an Apple Developer ID, so the first time macOS refuses: go to System Settings → Privacy & Security, scroll to "Cotabby Dev was blocked", and press **Open Anyway**. This is asked once.
3. Follow the app's setup: it asks for Accessibility and Input Monitoring (needed to see and fix what you type) and, optionally, Screen Recording.
4. Turn off macOS's own autocorrect (the Writing pane in Cotabby's settings has a button). Two autocorrects fight over the same word.

The app is named "Cotabby Dev" and keeps its own settings and permissions, so it can sit next to the official Cotabby. It does not update itself: a new version is a new download, and permissions carry over. The download is about 700 MB because the sentence model is inside it.

**Turning it off and on:** Control+Option+C (⌃⌥C), from any app. A short notice at the caret says which way it went, and anything Cotabby had on screen goes away. Change or clear the shortcut in Settings → Shortcuts → Toggle Cotabby.

## How it works while you type

- **Certain fixes happen by themselves** when you finish a word: `teh` → the, `becuase` → because, `enuf` → enough, `dont` → don't, typos before a comma or period too. A short green flash shows what changed; Cmd+Z undoes it.
  A small trained model decides which fixes are certain (see "Auto-fix model" below), and the spelling work starts the moment you press Space, so the fix lands before your next key.
- **Two words run together are split:** `nextdoor` → next door, `infact` → in fact, when the two halves are common words that really follow each other.
- **Shift slips are undone instantly:** `THe` → The, `kKing` → King (not `IDs`, `MHz`, or `iPhone`).
- **Names you spelled right are capitalized, not "corrected":** `walmart` → Walmart, `monday` → Monday. When a common word is one slip away (`hungary`: Hungary or hungry?) you get the bar instead.
- **Unsure words open a three-slot bar** above the word, like the iPhone: `"what you typed"` | **best fix** | runner-up. Tab takes the highlighted slot, ←/→ move, ⌥1/2/3 pick directly, or click. Return only picks after you move the highlight. Picking the quoted slot keeps your word and stops flagging it. Esc leaves this one word alone (no bar, no fix) until you move on. Shift- and Option-arrows go to the app. If you keep typing, the bar just goes away.
- **Next-word strip** above the caret while you type: up to five likely words. Tab types the highlighted one (the first, to begin with) and the strip moves on to the word after it. → steps the highlight to the next word and ← steps back, then Tab or Return types it; ⌥1…5 pick a slot directly. The arrows are only taken when the app has no use for them: → when nothing follows the caret on its line, ← once → has moved the highlight. With text to the right of the caret, and for ↑/↓ always, arrows stay caret movement and the strip steps aside. Esc hides it until the next word.
- **Capitals like the iPhone:** the first word of a sentence and `i` / `i'm` / `i've`.
- **Sentence pass** when you finish a sentence (`.` `!` `?`):
  - fixed automatically: doubled words (`the the`), `hello ,world`, double spaces, leftover certain typos;
  - also fixed automatically: `could of` → could have (not `of course`);
  - reviewed in one pass: likely wrong words judged from both sides (`went their yesterday` → there, `to tired` → too, `I want to by a car` → buy) and uncertain typos. The card steps through them: Tab takes the fix and moves on, ←/→ pick another option, Esc keeps your word (and it is not flagged there again). Typing closes it with no change. Wrong words are never changed without asking.
- **Learns you:** fixes you pick rank higher next time.
- **Learns your words:** a name or term the dictionary lacks, once you have written it twice, becomes a correction target in your capitals (`lindqvsit` → Lindqvist instead of Lundqvist). Stored locally; "Clear Learned Phrases" clears it.

## Engine

- 82k-word dictionary with SymSpell (edit distance 2), preloaded in memory at launch.
- Sound-alike index over the 30k most common words (`skool` → school, `fisical` → physical), including words whose sound is one slip off once the word is finished (`apsolootly` → absolutely, `comfterbul` → comfortable).
- A table of ~340 certain misspellings and dropped apostrophes (non-words only, no slang).
- 242k English word pairs for context (`know wich` → which, `different form` → from).
- A context table of word sequences up to four words long (48 MB, memory-mapped), counted from 114 million words: Tatoeba sentences, news, web pages, Wikipedia, and film subtitles. It feeds the next-word strip and tells the two models below how well a candidate fits the words around it. See "Context table" below.
- A gradient-boosted tree model (250 small trees, 184 KB, about 5 µs per candidate) reorders the candidates for a finished word and gives the probability that the first one is what you meant.
- A second tree model (300 trees, 444 KB) judges every correctly spelled word against words one slip away or sounding the same, using the words on both sides in a finished sentence and the words before it at the caret.
- Optional: Jev (TypeSafe) can re-rank unsure words from the full sentence; Groq can add a grammar check. Both off unless you add a key.

Measured with `cotabby-spell` (below): 166/166 edge cases, 23/23 sentence cases, 176 automatic fixes on three test lists with 0 wrong, per-keystroke cost p50 < 0.1 ms, p99 ≈ 14 ms. Live test in the real app: 34/34.

### Speed, measured live

`E2E_ONLY=speed Tools/e2e/live-smoke.sh` types ten sentences with misspellings into the test host and reads the app's own timeline. Counted from the key that finished the word, at 120 ms per key (about 100 words a minute):

| | median | 90% within | slowest seen |
|---|---|---|---|
| automatic fix typed | 16-17 ms | 33 ms | ~100 ms |
| spelling bar shown | 27-28 ms | 41 ms | ~100 ms |

Almost all of the median is waiting for the host app to show the key through Accessibility (about 12-15 ms in a native text view); Cotabby's own part is about 1 ms, because:

- the spelling work is done at the keypress, before anything else reacts to the key;
- when the host shows the key, a prepared fix or bar is acted on in that same main-thread turn (`handlePreparedTypoGateWithoutQueueing`) instead of being queued behind pending drawing;
- the fix's keys go out before any panel is closed, and panels do their window work one turn later (`CandidateListPanelController.place`);
- the word strip leaves a key alone when the spelling gate already owns that word.

The remaining slow cases (roughly one in ten above 35 ms) are the main thread blocked in the system's display flush or in an Accessibility read the host answers late. `E2E_SAMPLE=<file>` records stack samples during the run for digging further.

## Context table

`Tools/ngram/build_context_table.sh <work-dir>` downloads the corpora, holds out every 50th sentence of each, counts the rest in parallel (under a minute on 16 cores) and writes `next_word_model_en.bin`. Until 2026-11-12 the table came from Tatoeba alone (15 million words, 16 MB). Next-word prediction on held-out sentences, before any letter of the word is typed:

| Held-out text | Top guess right, Tatoeba-only table | Top guess right, five-corpus table | Keystrokes saved |
|---|---|---|---|
| Film subtitles (everyday speech) | 15.2% | 22.2% | 50.0% → 55.0% |
| News | 14.0% | 18.4% | 47.4% → 50.9% |
| Web pages | 12.9% | 16.2% | 48.2% → 50.9% |
| Tatoeba | 24.3% | 21.9% | 54.8% → 54.2% |

It is better on everything except the textbook-style sentences the old table was built from. For spelling, on typos placed in a mix of held-out sentences from four of the sources, the five-corpus table catches more wrong words (21.8% against 19.1% of swaps in a finished sentence, with fewer correct sentences flagged) and is level on misspellings (first guess right 80.9% against 80.1%). On Tatoeba sentences alone it is about two points behind the old table. The table is cut at 48 MB (`NGRAM_MIN_TOTAL=12`); the 58 MB cut is about one point better on next-word guesses and the 30 MB cut about one point worse.

## Auto-fix model

The ranker's score orders candidates; it is a poor measure of how likely the top one is to be right. `AutoFixConfidence.swift` turns the same evidence (edit distance, word frequency, sound match, the system checker's opinion, sentence context, mirrored letters, neighboring keys, and so on) into a probability for each candidate. The candidates are shown in that order, and the first is applied unasked when its probability clears a threshold. A known misspelling, a word that is a name, and a fix you have accepted three times keep the older score rule.

Trained on the Birkbeck misspelling corpora placed in held-out sentences (Tatoeba, subtitles, web and news, mixed), plus correct words the system checker flags (names, slang), where any fix is wrong. Measured on the held-out halves (test rows never tune anything):

| Test set | Fixed unasked, old rule | Fixed unasked, model |
|---|---|---|
| Typos in sentences (1,349) | 56.9%, 4.8% wrong | 61.3%, 3.4% wrong |
| Typos in an empty field (1,711) | 47.7%, 3.7% wrong | 68.3%, 3.4% wrong |
| Two words run together (591) | 28.1%, 12.0% wrong | 70.6%, none wrong |
| Wikipedia typos (1,075) | 58.8%, 1.7% wrong | 67.5%, 0.6% wrong |
| Hard words, aspell list (227) | 41.0%, 10.8% wrong | 44.9%, 3.9% wrong |
| Schoolchildren's spellings, holbrook (409) | 25.4%, 23.1% wrong | 24.7%, 14.9% wrong |
| Words the checker flags in untouched text (2,102) | 206 edited | 79 edited |

"Wrong" overstates the real rate: the corpora list `realy` under `ready` and `thorugh` under `thought`. The 79 edits in untouched text are almost all real slips in the subtitles and web pages themselves (`seperate`, `anyyhing`, `ofyou` → of you); the debatable ones are British spellings and compounds (`fertiliser`, `videogames`). First-guess accuracy in sentences rose from 76.9% to 80.9% (schoolchildren's spellings: 54.8% to 60.1%; run-together words: 76.1% to 98.0%). The sentences are harder than the Tatoeba-only set used before 2026-11-12, where the same pipeline scored 83.3% and fixed 65.5% unasked, so the two sets of numbers are not comparable. Word vectors (word2vec trained on the same sentences) were tried as an extra context signal and added nothing measurable on top of the n-gram table, so they are not shipped.

## Wrong-word model

`WrongWordDetector.swift` gives every real word in a finished sentence its alternatives (a listed confusable, a same-sounding word, or a common word one edit away, never a plain plural or past tense) and asks a tree model whether one of them fits the sentence much better. Trained on real-word errors from the Birkbeck corpora and the listed confusables, swapped into held-out sentences; every other word of every sentence is a negative. The threshold is set by how many *correct* sentences get a flag.

| Held-out test (8,040 swapped, 28,513 correct sentences, four sources) | Caught | Correct sentences flagged |
|---|---|---|
| Finished sentence, old rule (listed confusables with pair counts) | 8.2% | 1.28% |
| Finished sentence, model | 21.8% | 0.35% |
| At the caret, old rule | 6.5% | 0.82% |
| At the caret, model (nothing typed after the word yet) | 14.4% | 0.32% |

The same model also judges each word right after it is typed, with a stricter threshold because nothing to its right exists yet, so a line that never ends in a period still gets checked (`I want to no` → know). A word that only the rest of the sentence can settle (`I went their` could become `their way`, `we need to by` could become `by then`) waits for the sentence pass.

About half the swaps in that test are not reachable at all (two or more edits away, or noise in the corpus). On 27 hand-written sentences with common slips it catches 20 (old rule: 7), with no flag on 10 correct ones. Flags go to the review card; they are not applied unasked, because even above 90% confidence about 1 correct sentence in 1,250 would be silently changed (`fan` → fun). Still missed: words that need meaning rather than neighbors (`a grate day`, `pulled a mussel`), and `I am form London` since the retrain on mixed text.

Each model file names its inputs. After changing the ranker, `AutoFixFeatures`, `WrongWordDetector`, or the context table, retrain both (about seven minutes), or the app falls back to the hand rules:

```sh
Tools/ngram/build_context_table.sh ~/cotabby-work                # only to rebuild the context table (1.2 GB of downloads)
TARGET_WRONG=0.04 Tools/autofix/run.sh ~/cotabby-work             # trains and writes both models
TARGET_WRONG=0.04 Tools/autofix/run.sh ~/cotabby-work --report-only   # report without writing
COTABBY_RESOURCES=<copy of Resources> Tools/autofix/run.sh <dir>  # score a candidate table or dictionary on the side
$CLI --rank "I think teh "                          # candidates, and the model's probability
$CLI --no-model --accuracy <file>                   # compare with the score rule
$CLI --proofread "He was to tired to walk."         # the sentence pass, wrong words included
```

## Sentence model

When a sentence is finished, a small language model fine-tuned for spelling rereads it. Words it is
sure of are typed in place (green flash, Cmd+Z undoes and it will not try again); words it is less
sure of go on the review card. It runs after the local sentence pass and catches what rules and
word lists cannot: misspelled names and technical terms (`I drive a Tyoda Corola to work.` →
`Toyota Corolla`), and more wrong real words.

- **Model file:** `spelling-qwen3-0.6b-q8_0.gguf` (639 MB, about that much memory while the app runs).
  The app looks in `~/Library/Application Support/Cotabby Dev/SentenceModel/` first, then inside its
  own bundle, which is where a downloaded release carries it. A build from source has neither until
  the file is put in the first place. No file, no model stage: nothing else changes.
  `Tools/sentence-model/README.md` has the recipe.
- **Code:** `Support/Spelling/SentenceModelCorrection.swift` (decoder and gate, pure),
  `Services/Spelling/SentenceModelService.swift` (llama.cpp model of its own, separate from ghost
  text), `SentenceCheckController.startModelPass`.
- **Bars** (`SentenceModelGate.Bars`): typed in place from 0.9 (0.95 when the typed word is itself a
  known word), offered from 0.6. Punctuation changes and answers with a different word count are
  ignored.
- **Speed, live** (M3 Max, no developer overlay): a correct sentence is cleared in about 35 ms, a
  one-word fix is decided in about 60 ms, a two-word fix in about 80 ms. The answer is dropped if
  the writer has already typed past the sentence (at 120 ms a key most fixes still land; at 70 ms a
  key most are dropped, text untouched).
- **Typing through a fix is safe.** While the app deletes and retypes, the writer's own key-downs
  are held by the active event tap and replayed in order right after (`InputMonitor`
  `holdTypingWhileEditsDrain`, `HeldKeyReplayer`). Without this, a key landing between the
  backspaces shifted the rest of the fix by one character (`Tyoyota`, a lost letter); the same hold
  now covers word fixes and the local sentence pass. `E2E_ONLY=flow` tests it.
- **Measured through the app's own runtime** on the 1,040 sentences below, with the bars above:
  typed in place, 79.7% of misspellings (0.3% wrong), 22.7% of wrong words, 61.5% of names and
  terms, 0.1 correct words changed per 1,000 and no correct sentence touched. With the offered words
  accepted too: 90.7% / 42.7% / 80.8%.

### How it was chosen

The question: would a small language model that rewrites each finished sentence beat the pipeline
above? Measured on 1,040 held-out sentences (300 with a misspelling, 300 with a wrong real word,
400 correct, 40 hand-written with names and technical terms). Scripts and the rebuild recipe are in
`Tools/sentence-model/`.

| System | Misspellings fixed | Wrong words fixed | Names and terms fixed | Correct words changed |
|---|---|---|---|---|
| Sentence pass above, applied without asking | 60.7% | 0.8% | 43.6% | 1.4–2.3 per 1,000 |
| Sentence pass above, every suggestion accepted | 80.9% | 26.2% | 51.3% | 4.3 per 1,000 |
| Qwen3.5 0.8B chat model, untuned, as a rewriter | 78.6% | 28.5% | 89.7% | about 100 per 1,000 |
| Qwen3 0.6B fine-tuned, changes it is ≥ 90% sure of | 80.7% | 28.3% | 61.5% | 0.2 per 1,000 |
| Qwen3 0.6B fine-tuned, changes it is ≥ 80% sure of | 87.0% | 35.0% | 69.2% | 0.7 per 1,000 |
| Qwen3 0.6B fine-tuned, every change | 94.0% | 52.0% | 84.6% | 4.1 per 1,000 |

(The first two rows leave out each sentence's last word, which the word-level check handles as it is
typed; the model rows include it.)

- **An untuned chat model cannot be trusted to rewrite.** It knows the names (`Tyoda Corola` →
  `Toyota Corolla`) but rewords one correct sentence in five. A 9B model, on the 122 sentences it
  got through, drifted the same way.
- **Fine-tuning on (typed → correct) pairs fixes the drift.** 160,000 pairs from the training corpora,
  a third left untouched so copying is the default, the rest with one to three errors: recorded
  misspellings (Birkbeck dev half), real-word slips, and made-up slips that also hit names. LoRA
  rank 16 on all layers, 4,000 steps of 16, about 35 minutes on an M3 Max.
- **The model's own probability is the gate.** A changed word is kept when the lowest probability of
  its pieces clears a bar; an answer with a different word count is dropped whole (4 of 1,040).
- **Speed comes from not writing what does not change.** The sentence as typed is checked in one
  pass and pieces are only generated where the model disagrees, then the rest is checked again in one
  pass. Same output as plain decoding. Median 45 ms per sentence, 27 ms for a correct one (MLX,
  M3 Max); plain decoding takes 159 ms.
- **Names depend on the training pairs.** The first fine-tune learned to leave unfamiliar names
  alone (67% on the hand-written set); misspelling a name or long technical word in half the
  corrupted sentences brought that to 85% before the gate.
- Run after the current sentence pass instead of in place of it, the model at the 90% bar fixes
  71.5% of the misspellings and 27.7% of the wrong words the pass left, changing 0.1 correct words
  per 1,000.

Also measured: a tiny masked model as one more opinion for the wrong-word trees. Its score for the
typed word against each alternative, added as features, lifts wrong words caught in a finished
sentence from 21.8% to 34.7% at the same false-alarm rate (0.35% of correct sentences). A 13.5M
model (`google/electra-small-generator`) does as well as an 82M one (`distilroberta-base`, 34.6%).

Qwen 3.5 0.8B, the model the app already downloads for ghost text, could not be fine-tuned with
MLX on this machine (about 4 s a step, then out of memory), which is why the fine-tune uses Qwen3.

## Setup notes

- **Turn off macOS autocorrect** (Settings → Writing → macOS Autocorrect has a button). Two autocorrects fight over the same word.
- Low Power Mode pauses only the on-device ghost-text model; spelling keeps working.

## Testing

```sh
# Decision engine, same code as the app
xcodebuild -project Cotabby.xcodeproj -scheme cotabby-spell -configuration Release \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/CotabbyFork-CLI build
CLI=~/Library/Developer/Xcode/DerivedData/CotabbyFork-CLI/Build/Products/Release/cotabby-spell
$CLI "I don't know wich |"                          # one decision (| is the caret)
$CLI --suite Tools/cotabby-spell/cases.txt          # word-level edge cases
$CLI --sentences Tools/cotabby-spell/sentences.txt  # sentence pass
$CLI --accuracy Tools/cotabby-spell/severe-heldout.txt
$CLI --proofread "i think teh the plan works."

# The whole pipeline inside the test process (real coordinator, dictionary and both models; only the
# text field and key injector are stand-ins): SuggestionCoordinatorSpellingModelTests.
xcodebuild test -project Cotabby.xcodeproj -scheme Cotabby -destination 'platform=macOS' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/CotabbyFork-Check CODE_SIGNING_ALLOWED=NO \
  -only-testing:CotabbyTests/SuggestionCoordinatorSpellingModelTests

# Build + install Cotabby Dev, then drive it live. The live test types into its own test host app
# (Tools/e2e/TestHost), never your apps or documents, and restores your Cotabby history afterwards.
# The keys are posted by Cotabby Dev itself (Services/Input/E2EKeyDriver.swift, active only when
# launched with -cotabby-e2e-commands, and only while the test host is the frontmost app), so the
# terminal that runs the script needs no Accessibility permission. It stops with SKIP if the screen
# locks or another app comes to the front.
Tools/install-dev.sh
Tools/e2e/live-smoke.sh                       # everything, about three minutes
E2E_ONLY=speed Tools/e2e/live-smoke.sh        # key-to-fix timings only (E2E_PACE=<ms per key>)
E2E_ONLY=toggle Tools/e2e/live-smoke.sh       # the on/off shortcut only
# A picture of the test window with a panel up, taken by the app itself (it holds Screen Recording):
# the word strip by default, or whatever E2E_SHOT_TEXT brings up; E2E_HOST_LOOK=light|dark sets the
# window behind it.
E2E_ONLY=shot E2E_SHOT=/tmp/strip.png Tools/e2e/live-smoke.sh
E2E_ONLY=shot E2E_HOST_LOOK=light E2E_SHOT_TEXT="we need a recipt" E2E_SHOT=/tmp/bar.png Tools/e2e/live-smoke.sh
```

The panels are glass (`UI/Components/PopupChrome.swift`): Liquid Glass on macOS 26 with only a light
shade over it, so what is behind the panel shows through blurred, and a behind-window material on 14
and 15. A panel of an app that is not in front gets blur but no lens effect from the system, so the
depth is drawn: a lit rim, a gloss, and a shaded lower edge. The selected slot is a raised white key
with dark text. On macOS 26 the panel turns light over a light window and dark over a dark one, and
the text follows. Checked by picture (spelling bar and word strip) over white, dark and colorful test
windows; the macOS 14–15 fallback compiles but has not been run.

## Releasing

```sh
Tools/release/package-dmg.sh 0.1.0   # builds, puts the sentence model in the app, signs, writes the .dmg
```

The script prints the image's path (outside the repo) and its SHA-256. Install that app and run
`Tools/e2e/live-smoke.sh` against it before uploading. Tags are named `fork-v<version>`: a tag that
starts with `v` and a digit would start upstream's release workflow, which needs upstream's signing
secrets.

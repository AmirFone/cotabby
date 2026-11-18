# Dyslexia-assist fork

Spelling help that keeps up with fast, error-heavy typing. Everything below runs on your Mac.

## Install

No Xcode needed. macOS 14 or later. Tested on an Apple Silicon Mac running macOS 26 only; the app also contains an Intel build that has not been run.

1. Download `Cotabby-Dev-<version>.dmg` from the [releases page](https://github.com/AmirFone/cotabby/releases), open it, and drag **Cotabby Dev** into Applications.
2. Open it. This build is not signed with an Apple Developer ID, so the first time macOS refuses: go to System Settings → Privacy & Security, scroll to "Cotabby Dev was blocked", and press **Open Anyway**. This is asked once.
3. Follow the app's setup: it asks for Accessibility and Input Monitoring (needed to see and fix what you type) and, optionally, Screen Recording.
4. Turn off macOS's own autocorrect (the Writing pane in Cotabby's settings has a button). Two autocorrects fight over the same word.

The app is named "Cotabby Dev" and keeps its own settings and permissions, so it can sit next to the official Cotabby. It does not update itself: a new version is a new download, and permissions carry over. The download is about 700 MB because the sentence model is inside it.

## Recommended setup

What gives the best results, in order of how much it matters:

1. **Run only one Cotabby.** The released Cotabby app and this fork are two typing assistants; with both running, the released one's ghost text also takes Tab and types words of its own. Quit it and take it out of System Settings → General → Login Items while you use this one. If it is running anyway, this build says so once at the caret when you start typing.
2. **Install the Gemma model for the word strip.** Settings → Engine & Model → download **tabby-2-base** (Gemma 4 E2B, 3.8 GB). The strip is ordered by a language model that reads back what you have written, and it uses the best one installed, with no setting to change:

   | Model (name in the app) | Size | First suggestion right while typing a word | After 2 letters | After 3 letters | Right verb form first | One pass | Used when |
   |---|---|---|---|---|---|---|---|
   | Gemma 4 E2B (tabby-2-base) | 3.8 GB | 83% | 83% | 90% | 94% | 11 ms | installed, and the Mac has 16 GB of memory or more |
   | Qwen 3.5 2B base (tabby-2-mini) | 1.3 GB | 79% | 79% | 86% | 90% | 8 ms | installed, 12 GB of memory or more |
   | Qwen 3.5 0.8B base (tabby-2-nano) | 0.6 GB | 76% | 76% | 84% | 89% | 6 ms | installed |
   | the built-in sentence model | already loaded | 69% | 67% | 79% | 84% | 5 ms | nothing else is installed |
   | no language model (word table only) | | 44% | 40% | 52% | 53% | | |

   Measured on the held-back long test documents (`Tools/prediction/README.md`); "while typing a word" is every moment with at least one letter typed. Before any letter is typed the first suggestion is right about 38% of the time with Gemma, and no model does much better there (a 12B model reached 39% where Gemma reached 36%), which is why the number over all moments is 72%. The larger Gemma (tabby-2-pro, 5.3 GB) is within half a point of tabby-2-base and takes half again as long per word.
3. **Settings → Writing:** keep **Show Next-Word Predictions**, **Hide Suggestions on Typo**, **Offer Corrections on Typo** and **Automatically Fix Confident Typos** on (the defaults), and press the button under **macOS Autocorrect Is Also On** so macOS's own autocorrect is off.
4. **Optional:** **Save Training Examples** (Settings → Writing → Training Data) if you want to train a model on your own writing later or see where Cotabby got a word wrong. It is off unless you turn it on, and it records what was shown and decided for each word, not only the result (see "Training data").

On a Mac with less than 16 GB of memory, install tabby-2-mini (or tabby-2-nano under 12 GB) instead of tabby-2-base. With neither, everything still works; the strip is just right less often.

**Turning it off and on:** Control+Option+C (⌃⌥C), from any app. Text written while it was off is left as written when it comes back on; help starts again with your next key. A short notice at the caret says which way it went, and anything Cotabby had on screen goes away. Change or clear the shortcut in Settings → Shortcuts → Toggle Cotabby.

## How it works while you type

- **Certain fixes happen by themselves** when you finish a word: `teh` → the, `becuase` → because, `enuf` → enough, `dont` → don't, typos before a comma or period too. A short green flash shows what changed; Cmd+Z undoes it.
  A small trained model decides which fixes are certain (see "Auto-fix model" below), and the spelling work starts the moment you press Space, so the fix lands before your next key.
- **Two words run together are split:** `nextdoor` → next door, `infact` → in fact, when the two halves are common words that really follow each other.
- **Shift slips are undone instantly:** `THe` → The, `kKing` → King (not `IDs`, `MHz`, or `iPhone`).
- **Names you spelled right are capitalized, not "corrected":** `walmart` → Walmart, `monday` → Monday. When a common word is one slip away (`hungary`: Hungary or hungry?) you get the bar instead.
- **Unsure words open a three-slot bar** above the word, like the iPhone: `"what you typed"` | **best fix** | runner-up. Tab takes the highlighted slot, ←/→ move, ⌥1/2/3 pick directly, or click. Return only picks after you move the highlight. Picking the quoted slot keeps your word and stops flagging it. Esc leaves this one word alone (no bar, no fix) until you move on. Shift- and Option-arrows go to the app. If you keep typing, the bar just goes away.
- **Next-word strip** above the caret while you type: up to five likely words, likeliest first, ordered by a language model that reads your last few sentences. That is what makes the verb form follow the tense you are writing in: after `Yesterday we` the letters `walk` offer **walked** first, after `She is still` **walking**, after `Every morning she` **walks**. It never offers slurs or swear words. Tab types the highlighted one (the first, to begin with) and the strip moves on to the word after it. → steps the highlight to the next word and ← steps back, then Tab or Return types it; ⌥1…5 pick a slot directly. The arrows are only taken when the app has no use for them: → when nothing follows the caret on its line, ← once → has moved the highlight. With text to the right of the caret, and for ↑/↓ always, arrows stay caret movement and the strip steps aside. Esc hides it until the next word.
- **Size and glass of the panels are yours to pick** (Settings → Writing → Suggestion Size, Glass). Size: Compact (the default, about a fifth smaller than before), Regular, Large. Glass: Clear (the default: smoked glass, the document shows through and the words are drawn bolder with a fine outline), Standard (the frosted look every earlier build had), Solid (hides the document, for the strongest contrast). `defaults write com.jacobfu.tabby.dev cotabbyPanelSize regular` and `cotabbyPanelGlass standard` bring back the old look.
- **Capitals like the iPhone:** the first word of a sentence and `i` / `i'm` / `i've`.
- **Words joined by a dot, slash or hyphen get the same help.** In `users.nmae`, `read/wriet` or `schema.table.colum` the word after the mark is checked and the strip completes it, and a word finished by a slash or a hyphen is checked like one before a comma (`recieve/`, `teh-`). Because such text is as often a name as prose, a fix there is offered on the bar and never made by itself, and the word after a dot is not capitalized. Web and email addresses, file names (`notes.txt`), paths (`src/main/app`, `~/Desktop`) and version numbers are left alone as before. Right after a dot the strip waits for the first letter, since a dot is nearly always the end of a sentence.
- **Sentence pass** when you finish a sentence (`.` `!` `?`):
  - fixed automatically: doubled words (`the the`), `hello ,world`, double spaces, leftover certain typos;
  - also fixed automatically: `could of` → could have (not `of course`);
  - reviewed in one pass: likely wrong words judged from both sides (`went their yesterday` → there, `to tired` → too, `I want to by a car` → buy) and uncertain typos. The card steps through them: Tab takes the fix and moves on, ←/→ pick another option, Esc keeps your word (and it is not flagged there again). Typing closes it with no change. Wrong words are never changed without asking.
- **Learns you:** a fix you pick or retype ranks higher next time. Once you have made the same fix for the same slip twice, that word leads the bar whatever the dictionary thinks is likelier, and from the third time it is made for you (`wich` → which, for someone who always means *which*, even though *with* is the commoner word). A slip you correct to two different words about as often has no habit and stays a choice. Undoing a fix marks the word as meant; correcting it yourself later takes that back. A fix only counts as undone once it has been seen in the field and is gone again, so a fix that never landed is not read as you rejecting it.
- **Knows software terms:** about 900 engineering words are built in, so `backend`, `kubectl` and `jsonb` are not flagged, slips go to the term (`frontned` → frontend), and the strip offers `Kubernetes`, `JSON` or `repo` where the text calls for them (see "Software-engineering vocabulary").
- **Learns your words:** a name or term the dictionary lacks, once you have written it twice, becomes a correction target in your capitals (`lindqvsit` → Lindqvist instead of Lundqvist). Stored locally; "Clear Learned Phrases" clears it.

## Training data (opt-in)

Settings → Writing → **Training Data** has a switch, **Save Training Examples**, that is off until you
turn it on. With it on, each sentence you finish is saved with everything Cotabby did while you wrote
it, so a model can be trained on your own writing and the places Cotabby got wrong can be found.
**Export…** writes one JSON object per line (wrapped and cut down here for reading; in the file the
keys are sorted):

```json
{"scope":"sentence","day":"2026-11-17","app":"com.apple.Notes","context":"We left early.",
 "typed":"I drive a Tyoda to wrok evry day.","final":"I drive a Toyota to wrok every day.",
 "accepted":[{"typed":"evry","fix":"every","how":"autoFix"},{"typed":"Tyoda","fix":"Toyota","how":"sentenceFix"}],
 "rejected":[],
 "session":{"version":"0.4.0","stripModel":"gemma-4-E2B.i1-Q6_K.gguf","hasSentenceModel":true},
 "steps":[
  {"kind":"strip","ms":0,"before":"I","word":"drive","shownFirst":["have","am","was"],"shownLast":["drive","drove","dropped"],"lettersTyped":2,"rank":0},
  {"kind":"decision","ms":4100,"before":"I drive a Tyoda to wrok","word":"evry","how":"fixed","candidates":["every","very"],"scores":[1.6,0.7],"confidence":0.97},
  {"kind":"outcome","ms":4900,"word":"evry","final":"every","how":"autoFixKept"},
  {"kind":"sentencePass","ms":6200,"before":"I drive a Tyoda to wrok every day.",
   "changes":[{"typed":"Tyoda","written":"Toyota","probability":0.97,"action":"fixed"},{"typed":"wrok","written":"work","probability":0.41,"action":"left"}]},
  {"kind":"sentenceFix","ms":7400,"how":"kept","final":"I drive a Toyota to wrok every day."}]}
```

The first block is the training pair:

- `typed` is the sentence as you first typed it (the model's input) and `final` what you ended up with
  (its target). A sentence nothing was done to has the two equal, which teaches a model what to leave alone.
- `accepted` lists changes you kept: `autoFix` (fixed for you, you typed on), `picked` (chosen from the
  bar or card), `selfCorrected` (you retyped it), `sentenceFix` (fixed when the sentence was finished).
- `rejected` lists what you turned down: an `autoFix` or `sentenceFix` you undid, or a fix that was
  `offered` and you kept your word. These are the "do not change this" examples.
- `context` is up to 300 characters of what stood before the sentence, `app` the app it was typed in
  (its bundle identifier), and `session` the build and models that were running.

`steps` is what happened on the way, in order, with `ms` counted from the sentence's first step. It
is there because outcomes cannot be read backwards: "`evry` became `every`" does not say what was
offered, how sure the engine was, or what you typed past.

| `kind` | Written when | What it holds |
|---|---|---|
| `strip` | you finish a word, or pick one | the strip before any letter (`shownFirst`) and as it last stood (`shownLast`), how many letters you had typed by then, the slot you picked (`pickedSlot`, absent when you typed the word out), and `rank`: where the word you meant stood in the last list (0 is first, absent when it was not listed) |
| `decision` | the spelling engine flags a word | what it did (`fixed` without asking, `offered`, `offeredChoices`, `offeredWrongWord`, or `held`), its candidates best first with their scores, and the trained model's `confidence` in the first one |
| `outcome` | you react | what became of the word: `autoFixKept`, `autoFixUndone`, `picked`, `keptAsTyped`, `selfCorrected` |
| `sentencePass` | the sentence model has read the finished sentence | every word it would change, its probability for it, and whether that was enough to fix it (`fixed`), to ask (`asked`), or neither (`left`) |
| `sentenceFix` | you type on, or undo | `kept` or `undone`, and the fixed sentence |

So a word the strip never had (`rank` absent, many `lettersTyped`), a fix made unasked that you undid
(`decision` `fixed` then `outcome` `autoFixUndone`), a right fix the engine was too unsure to make
(`confidence` under the bar, then `selfCorrected`), and a misspelling the sentence model saw and left
(`action` `left`) are each one line to find. `Tools/training/summarize.py <export>` counts them: how
often the word you meant was first in the strip, which fixes you undid, and what the sentence model saw
and left.

A fix whose sentence was never saved (a line you did not finish, or one too short or too long to keep)
is exported with `scope` `word`; its `steps` carry the engine's decision and what the strip showed, so
it still says where in the line it happened. Other steps that fit no saved sentence are exported with
`scope` `strip`, `decision` or `sentencePass`.

The first export from a work day on 0.3.1 had 187 of 417 fixes without a sentence. Three causes were
found and fixed in 0.4.0: a chat line that ends in a full stop and is sent with Return was never saved
(only lines without one were), a sentence sent within 0.8 s of its full stop was dropped because the
field was already empty, and a fix was looked for in its sentence by exact capitals (`the` was not found
in `The cat`).

Not recorded: a change you make to a sentence by going back to it after typing on (only what you do
at the caret as you write is seen), and letters you typed and deleted inside a word.

This is a training record, not a keystroke log, and the code is written to keep it that way
(`Services/Spelling/TrainingLog.swift`):

- Nothing is saved until the switch is on.
- Sentences, words and what Cotabby did with them: no key presses or shortcuts, no window titles,
  nothing from a field once it is deleted before a word is finished.
- Order and pace, not the clock: times are milliseconds since the app's first line of that launch,
  and a sentence has a calendar date but no time of day.
- Two things have a switch of their own under the main one, on by default: **Include the Text Before
  Each Sentence** and **Include the App**. Turn them off to keep sentences only.
- Only where Cotabby is working: never password fields, nothing while Cotabby is off, paused, or
  disabled for the app in front. Sentences with a web address, an email address, or code are skipped
  with everything recorded for their words, as are fragments under three words and blocks over 400
  characters.
- One file on this Mac, readable only by your user (`~/Library/Application Support/Cotabby/training-log.jsonl`),
  never uploaded. It leaves the Mac only through Export, to a place you pick.
- **Show in Finder** and **Delete All** are next to the switch. The file is capped at 100 MB (the older
  half is dropped past that); a word typed with the strip on is about 200 bytes.

A file written by 0.3.1 or earlier still exports; its sentences have the training pair and no `steps`.

**Checking a build against your own writing.** `cotabby-spell --replay <export>` types an export
again through the current engine (see "Testing"). On the first real export (187 sentences and 184
fixes without a sentence, one work day), 0.4.0 fixes 61% of the slips in sentences without asking on
a fresh install and has the right word made or first on the bar for 79%; replayed in order with what
the app learns along the way, 69% and 85%, with 1.4% changed to another word. Of 1,877 words that
were left as typed it changes 30 without asking, 29 of them slips that had been left in the text.
That replay is also what found the three learning faults fixed in 0.4.0 (see "Learns you" and the
sentence model's limits).

The examples are joined from small events at export time (`Support/Spelling/TrainingExamples.swift`),
because the events for one sentence do not arrive in order: a sentence fix is confirmed only when you
type on, and an undo replaces a sentence that was already saved.

## Engine

- 82k-word dictionary with SymSpell (edit distance 2), preloaded in memory at launch, plus the common American and current words it lacks (see "American spelling and current words").
- Sound-alike index over the 30k most common words (`skool` → school, `fisical` → physical), including words whose sound is one slip off once the word is finished (`apsolootly` → absolutely, `comfterbul` → comfortable).
- A table of ~340 certain misspellings and dropped apostrophes (non-words only, no slang).
- 242k English word pairs for context (`know wich` → which, `different form` → from).
- A context table of word sequences up to four words long (48 MB, memory-mapped), counted from 114 million words: Tatoeba sentences, news, web pages, Wikipedia, and film subtitles. It feeds the next-word strip and tells the two models below how well a candidate fits the words around it. See "Context table" below.
- A gradient-boosted tree model (250 small trees, 184 KB, about 5 µs per candidate) reorders the candidates for a finished word and gives the probability that the first one is what you meant.
- A second tree model (300 trees, 444 KB) judges every correctly spelled word against words one slip away or sounding the same, using the words on both sides in a finished sentence and the words before it at the caret.
- Optional: Jev (TypeSafe) can re-rank unsure words from the full sentence; Groq can add a grammar check. Both off unless you add a key.

Measured with `cotabby-spell` (below): 166/166 edge cases, 23/23 sentence cases, 176 automatic fixes on three test lists with 0 wrong, per-keystroke cost p50 < 0.1 ms, 95% within 2.0 ms, 99% within 7.9 ms. Live test in the real app: 34/34.

Three things keep that cost down and the start short (all give results identical to the plain versions they replaced, which the tests pin):

- **Dictionary scans compare bytes.** The scans that run on every key (which words start like this, which start nearly like this) walk a bucket of several thousand words. They used to build a `Character` array per word and three table rows per comparison; an English word is ASCII, so its letters now sit end to end in one byte array and one set of rows serves the whole scan. The strip's own work per key fell from 1.21 to 0.43 ms, and the slowest spelling keystrokes from 4.7 to 2.0 ms (95%) and 11.2 to 7.9 ms (99%).
- **The index is built on all cores.** The delete-variants of every word and the sound keys of the common ones are worked out in parallel and filed in word order on one thread: about 0.4 s instead of 1.5 s, at user-initiated priority instead of utility. Until it is built there is no spelling help.
- **The word-pair table is read as bytes** (0.3 s to under 0.1 s).

Together the spelling engine is ready about 0.5 s after launch instead of 1.9 s. None of this shows in the live numbers below, which are dominated by the wait for the app being typed into; it is main-thread time given back to that app.

### Speed, measured live

`E2E_ONLY=speed Tools/e2e/live-smoke.sh` types ten sentences with misspellings into the test host and reads the app's own timeline. Counted from the key that finished the word, at 120 ms per key (about 100 words a minute):

| | median | 90% within | slowest seen |
|---|---|---|---|
| automatic fix typed | 16-17 ms | 33 ms | ~100 ms |
| spelling bar shown | 27-28 ms | 41 ms | ~100 ms |

Measured again on 0.3.1 (three runs): automatic fix typed, median 15-16 ms, 90% within 36 ms; spelling bar shown, median 30 ms, 90% within 41-48 ms. In the full live suite the strip's model answered in a median of 15 ms, and for 64 of 229 words the list for the next word was already worked out when the space was pressed.

Almost all of the median is waiting for the host app to show the key through Accessibility (about 12-15 ms in a native text view); Cotabby's own part is about 1 ms, because:

- the spelling work is done at the keypress, before anything else reacts to the key;
- when the host shows the key, a prepared fix or bar is acted on in that same main-thread turn (`handlePreparedTypoGateWithoutQueueing`) instead of being queued behind pending drawing;
- the fix's keys go out before any panel is closed, and panels do their window work one turn later (`CandidateListPanelController.place`);
- the word strip leaves a key alone when the spelling gate already owns that word.

The remaining slow cases (roughly one in ten above 35 ms) are the main thread blocked in the system's display flush or in an Accessibility read the host answers late. `E2E_SAMPLE=<file>` records stack samples during the run for digging further.

## American spelling and current words

The frequency dictionary leans British and is some years old: it has `neighbour`, `analyse` and
`travelling` and no `neighbor`, `analyze`, `traveling`, `favorite`, `canceled`, `jewelry`, `dataset`
or `onboarding`. For someone who spells the American way that had two effects: a slip was fixed to
the British word (`neigborhood` → `neighbourhood`, unasked), and the word strip could not offer the
American one at all.

- **The words.** `prediction_words_en.txt` holds about 1,200 words the dictionary lacks, found in the
  corpora the context table is built from: written in lowercase at least 25 times, more often than
  capitalized, and accepted by the system spell checker
  (`Tools/prediction/build_word_supplement.py`). The word strip uses all of them. The spelling
  dictionary takes only the common ones of five letters or more (about 260;
  `SymSpellCorrector.spellingLines`), because every word added there makes some slip look correct.
- **The spelling.** `american_spellings_en.txt` pairs about 850 British spellings with their American
  form (`Tools/prediction/build_american_spellings.py`: spelling rules, kept only where both forms are
  known words and the American one is at least as common in the corpora, then read by a person; that
  keeps `dialogue` and `glamour` and leaves out look-alikes such as `timbre`/`timber`). On a Mac
  whose region is the United States a fix or a suggestion in the British spelling is given in the
  American one (`AmericanSpellings`). Elsewhere nothing changes. To choose by hand:
  `defaults write com.jacobfu.tabby.dev cotabbySpellingStyle american` (or `british`), then restart.
  What you type yourself is judged as before, by the system's checker for your region.

Measured on 394 misspellings of 200 words drawn at random from the list, written by four writers who
were given only the words (`cotabby-spell --accuracy`):

| | Right word first | Fixed unasked | Unasked fixes that were wrong |
|---|---|---|---|
| before | 18.8% | 4.1% | 16 of 16 (to the British spelling or another word) |
| with the words | 81.5% | 34.3% | 6 of 135 |
| with the words and the American spelling | 85.3% | 34.3% | 2 of 135 |

On the general spelling tests nothing moves: 8,000 misspellings in sentences, right word first 73.0%
before and 73.1% after, the same 49.8% fixed unasked with the same number wrong; the other test
lists are within 0.3 points. In 40,000 words of untouched text, 24 are edited against 17 before, and
all 7 new ones are British spellings turned American (`favourite`, `travelling`, `colourful`), which
is what the app already did with `organisation`. The trained models were left as they are;
retraining them on the larger dictionary gave the same first-guess accuracy.

## Software-engineering vocabulary

The dictionary is general English: it has `server` and `database` but not `backend`, `config`,
`repo`, `async`, `kubectl` or `jsonb`, and it counts `docker` and `refactor` as rare words. For
someone who writes about software the strip then never offered the word being typed, and the
spelling engine flagged it or changed it into an ordinary word (`kuberntes` was offered `currents`).

`Tools/prediction/build_technical_words.py` holds about 900 terms (languages, tools, protocols, data
formats, cloud services, and the everyday jargon of code review and operations) and writes two lists:

- **`technical_words_en.txt`, for the word strip:** every term with a count and its usual capitals.
  The language model that orders the strip can now put `Kubernetes`, `JSON`, `GitHub`, `TypeScript`,
  `kubectl` or `repo` first where the text calls for it, shown the way it is written. A term that is
  also an ordinary word (`swift`, `spring`, `react`, `rust`) gets no capitals, so a sentence about
  the weather is not offered a programming language.
- **`technical_spelling_en.txt`, for the spelling dictionary:** the 382 terms the dictionary lacks
  that are five letters or longer, plus `json`, `yaml`, `html`, `http`, `repo`, `enum` and `sudo`.
  These are no longer flagged (the system checker calls most of them misspelled), slips are fixed
  toward them (`frontned` → frontend, `josn` → json, `kuberntes` → kubernetes), and the sentence
  model leaves them as typed. Short terms stay out on purpose: `aws` is how `was` comes out with two
  keys swapped, `iam` is `I am` run together, `util` is `until` with a letter dropped, and as
  dictionary words they would make those slips look right. The strip still offers them.

The counts are three tiers set by hand (used daily, weekly, now and then), not measured in a corpus;
where the dictionary also has the word the larger count is used, and a word the dictionary has keeps
its own count in the spelling dictionary.

Measured on ordinary text nothing moves: the 8,000 misspellings in sentences give the same result
with and without the lists (right word first 73.1%, fixed without asking 49.8% with the same 338
wrong), and the strip's four held-back sets give the same numbers as before (first suggestion right
while typing a word: 82.9%, 82.0%, 80.0% and 71.5%). It is on by default; to turn it off:
`defaults write com.jacobfu.tabby.dev cotabbyTechnicalVocabularyEnabled -bool false`, then restart
the app. To add your own terms, edit the script and run it (its header has the command); a term you
write twice is also learned by itself (see "Learns your words").

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

## Word strip language model

The n-gram table sees the last three words of the current sentence. That is enough for `would like to`
and blind to everything that sets a tense or a subject: `Yesterday`, the verbs earlier in the
sentence, the paragraph before. So the strip is ordered by a language model that reads back up to
1,600 characters of what you have written.

- **Once per word, not per key.** The model's answer depends only on the text before the word being
  typed, so every letter of a word reuses one answer. One pass takes 11 ms on its own and 15 to 25 ms
  inside the running app.
- **Ready at the space.** While you type a word's last letters the model already works out the list
  for the word after it (for the word as typed if it is one, else for the strip's first word), so the
  next list is there when the space is pressed instead of one pass later
  (`WordLanguageModelService.lookAheadKey`). It runs only when nothing for the current word is waiting.
- **No second redraw.** When the answer is not there yet, the strip waits up to 50 ms for it instead
  of showing the table's order and swapping it.
- **How far back it reads.** A text up to 1,600 characters is read whole; a longer one loses its
  beginning in steps of 800 characters counted from the start, so the model re-reads once per 800
  characters typed (about 25 ms), not once per sentence as before
  (`LanguageModelContext.Reach`). Reading further back than the last four sentences is worth 2.6
  points of first-suggestion accuracy on long text.
- **From pieces to words.** A model predicts pieces, not words. A word's probability is its first
  piece's probability times the word's share of that piece; once the typed letters narrow the field
  to words sharing a piece (`shin`, `shins`, `shiny`), one more pass gives the exact numbers for them
  (`Support/Prediction/WordLanguageModel.swift`). Models that cannot take a piece back out of their
  memory (Qwen 3.5) skip that pass.
- **Words the dictionary lacks.** The model can only put a word first that is in its list, and the
  spelling dictionary leans British and predates current vocabulary. `prediction_words_en.txt` adds
  about 1,200 everyday words it lacked (`neighbor`, `favorite`, `traveling`, `mom`, `you've`,
  `dataset`, `onboarding`) and gives the dictionary's contractions their real counts (it carries
  `that's`, `you're` and `don't` all at one placeholder).
- **Your own words.** A name or term the text has already used (`Priyanka`, the project `Lantern`,
  `cutover`, `ETL`) is offered again, spelled and capitalized as you wrote it
  (`Support/Prediction/TextVocabulary.swift`). A name counts from its first use; a lowercase word
  needs two, so an uncorrected slip is not offered back. Typed again, such a name is first at 91% of
  the moments after its first letter; before, it was never offered.
- **One spelling.** On a Mac whose region is the United States, `travelling` and `traveling` are one
  suggestion, in the American spelling (see "American spelling and current words").
- **Near misses.** A word that does not start with the typed letters (`small` for `smalle`) is charged
  heavily, so it only comes first when nothing likely starts with them (`necc` → necessary).
- **Which model:** the best one installed (see "Recommended setup"). Nothing is downloaded for this;
  all of them are files the app already uses for ghost text or the sentence pass.
- **Speed of everything else is unchanged:** see "Speed, measured live".

Results on the held-back long test documents, `cotabby-spell --typing` (first suggestion is the word):

| Letters typed | 0 | 1 | 2 | 3 | 4 | while typing a word | all moments | right verb form first |
|---|---|---|---|---|---|---|---|---|
| word table only | 12% | 32% | 40% | 52% | 55% | 44% | 36% | 53% |
| Gemma 4 E2B | 38% | 71% | 83% | 90% | 93% | 83% | 72% | 94% |
| Qwen 3.5 2B base | 34% | 67% | 79% | 86% | 88% | 79% | 68% | 90% |
| Qwen 3.5 0.8B base | 31% | 63% | 76% | 84% | 87% | 76% | 65% | 89% |
| built-in sentence model | 22% | 52% | 67% | 79% | 85% | 69% | 57% | 84% |

On the held-back short passages Gemma 4 E2B scores 82% while typing a word and 70% over all moments
(0.2.0: 82% and 70%); on the long documents 0.2.0 scored 81% and 70%. Before any letter is typed no
model gets far past a third: many words are possible there. Larger models were measured and not made
the default: a 12B model adds about three points while typing for two and a half times the time per
word and twice the memory. Everything that was tried, the test data and how to run it are in
`Tools/prediction/README.md`.

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
- **Two limits on what it may type** (`SentenceModelGate.WordChecks`, since 0.4.0): only a word the
  app's dictionary or your own vocabulary has is typed in place, so a term the dictionary lacks is
  not turned into another word it lacks (`kubectl` into `kubelet`); such a change is asked about at
  most. And a word you kept when a fix was offered or undid a fix of, and any term of the bundled
  software vocabulary, is never changed or asked about. (0.4.0 also left alone every word in your
  learned vocabulary. That file can hold a misspelling you never noticed, which then could not be
  fixed, so 0.4.1 took it off the list.) On the sentences below this moves 0.4 to 0.8 points of
  misspellings from "typed in place" to "asked" (74.1% to 73.7%, 72.5% to 71.7%).
- **Speed, live** (M3 Max, no developer overlay): a correct sentence is cleared in about 35 ms, a
  one-word fix is decided in about 60 ms, a two-word fix in about 80 ms. The answer is dropped if
  the writer has already typed past the sentence (at 120 ms a key most fixes still land; at 70 ms a
  key most are dropped, text untouched).
- **Typing through a fix is safe.** While the app deletes and retypes, the writer's own key-downs
  are held by the active event tap and replayed in order right after (`InputMonitor`
  `holdTypingWhileEditsDrain`, `HeldKeyReplayer`). Without this, a key landing between the
  backspaces shifted the rest of the fix by one character (`Tyoyota`, a lost letter); the same hold
  now covers word fixes and the local sentence pass. `E2E_ONLY=flow` tests it.
- **Checked again on sentences written later** (the misspelled copies of the prediction test
  passages, by twenty writers, none of it seen in training): of 1,265 sentences with misspellings and
  491 without, 74.1% of misspellings typed in place, 0.4% of them wrongly, no correct sentence
  touched; on the tuning passages 72.5%, none wrong, 1 of 135 correct sentences touched. A bar of
  0.85 instead of 0.9 would fix four points more and make wrong fixes about half again as common
  (0.40% to 0.67%), so the bars stay.
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

**One command for everything that needs no screen:** `Tools/check.sh` runs lint, the unit suite (with
the real-model tests when a strip model is installed), the regression suites on the command-line
tool, and a check that the generated word lists match their scripts, all side by side, and ends with
one row per stage and `ALL PASS` or `FAILED`. It takes about as long as the unit suite alone.
`FAST=1` leaves out the tests that load a language model; `REPLAY=<export.jsonl>` also types that
training export again through the engine. Run it before every commit. Only the on-screen suite
(further down) is left out. The pieces it runs, should you want one by itself:

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

# The word strip the same way, with a real model and no screen: the production predictor and the real
# model service behind the real controller, typed into key by key, with only the text field, the panel
# and the key injector stood in (the `test_realModel_...` cases of WordPredictionControllerTests, and
# WordLanguageModelLiveTests for the service alone). They run when a model file is named, and work
# on a locked Mac, where the live test below cannot.
TEST_RUNNER_WORD_LM_FILE="$HOME/Library/Application Support/Cotabby Dev/LlamaRuntime/gemma-4-E2B.i1-Q6_K.gguf" \
  xcodebuild test -project Cotabby.xcodeproj -scheme Cotabby -destination 'platform=macOS' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/CotabbyFork-Check CODE_SIGNING_ALLOWED=NO \
  -only-testing:CotabbyTests/WordPredictionControllerTests -only-testing:CotabbyTests/WordLanguageModelLiveTests

# The training examples for a raw training log at any path (what Export writes), and a summary of an
# export: how often the strip had the word, which fixes were undone, what the sentence model left.
$CLI --training-export "$HOME/Library/Application Support/Cotabby/training-log.jsonl" > /tmp/export.jsonl
python3 Tools/training/summarize.py /tmp/export.jsonl

# An export typed again through the engine as it is now: every sentence word by word as you first
# typed it, then the sentence pass, compared with what you ended up with. --adapt replays in order
# and teaches the engine after each sentence what the app would have learned from it; --show lists
# the words (never sentences) it missed or changed. This is the check that a new build still works
# on your own writing. It is for checking, not for tuning against (see Tools/cotabby-spell/Replay.swift).
$CLI --american --replay ~/Downloads/cotabby-training.jsonl --adapt \
  --sentence-model "/Applications/Cotabby Dev.app/Contents/Resources/spelling-qwen3-0.6b-q8_0.gguf"

# Build + install Cotabby Dev, then drive it live. The live test types into its own test host app
# (Tools/e2e/TestHost), never your apps or documents, and restores your Cotabby history afterwards.
# The keys are posted by Cotabby Dev itself (Services/Input/E2EKeyDriver.swift, active only when
# launched with -cotabby-e2e-commands, and only while the test host is the frontmost app), so the
# terminal that runs the script needs no Accessibility permission. It stops with SKIP if the screen
# locks or another app comes to the front.
Tools/install-dev.sh
Tools/e2e/live-smoke.sh                       # everything, about three minutes
E2E_ONLY=speed Tools/e2e/live-smoke.sh        # key-to-fix timings only (E2E_PACE=<ms per key>)
E2E_ONLY=tense Tools/e2e/live-smoke.sh        # the word strip's verb forms (needs the CLI; COTABBY_SPELL=<path>)
E2E_PAUSE_OTHER=1 Tools/e2e/live-smoke.sh     # quit the released Cotabby for the run (it types into the test window)
E2E_ONLY=toggle Tools/e2e/live-smoke.sh       # the on/off shortcut only
E2E_ONLY=training Tools/e2e/live-smoke.sh     # the opt-in training record (on for that run only)
# A picture of Settings at one setting, taken by the app of its own window only:
E2E_ONLY=settings E2E_SETTING=trainingData E2E_SETTINGS_HEIGHT=2200 E2E_SHOT=/tmp/settings.png Tools/e2e/live-smoke.sh
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

## Building from source on another Mac

```sh
git clone https://github.com/AmirFone/cotabby && cd cotabby && git checkout groq
Tools/release/fetch-models.sh     # the word table and the sentence model: too large for git
Tools/install-dev.sh              # builds "Cotabby Dev", installs it in /Applications, opens it
```

Needs Xcode and `xcodegen` (`brew install xcodegen`; run `xcodegen generate` if the project file is
out of date). `install-dev.sh` signs with a local identity when it finds one and ad hoc otherwise;
with an ad hoc signature macOS asks for the Accessibility and Input Monitoring grants again after
each rebuild. The downloadable release avoids all of this.

## Releasing

```sh
Tools/release/package-dmg.sh 0.2.0   # builds, puts the sentence model in the app, signs, writes the .dmg
```

Upload the image together with `next_word_model_en.bin` and the sentence model file, which
`Tools/release/fetch-models.sh` downloads for source builds.

The script prints the image's path (outside the repo) and its SHA-256. Install that app and run
`Tools/e2e/live-smoke.sh` against it before uploading. Tags are named `fork-v<version>`: a tag that
starts with `v` and a digit would start upstream's release workflow, which needs upstream's signing
secrets.

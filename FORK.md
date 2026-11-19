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
  Two small trained models decide which fixes are certain (see "Auto-fix model" and "Two judges" below), and the spelling work starts the moment you press Space, so the fix lands before your next key.
- **Two words run together are split:** `nextdoor` → next door, `infact` → in fact, when the two halves are common words that really follow each other.
- **Shift slips are undone instantly:** `THe` → The, `kKing` → King (not `IDs`, `MHz`, or `iPhone`).
- **Names you spelled right are capitalized, not "corrected":** `walmart` → Walmart, `monday` → Monday. When a common word is one slip away (`hungary`: Hungary or hungry?) you get the bar instead.
- **Unsure words open a three-slot bar** above the word, like the iPhone: `"what you typed"` | **best fix** | runner-up. Tab takes the highlighted slot, ←/→ move, ⌥1/2/3 pick directly, or click. Return only picks after you move the highlight. Picking the quoted slot keeps your word and stops flagging it. Esc leaves this one word alone (no bar, no fix) until you move on. Shift- and Option-arrows go to the app. If you keep typing, the bar just goes away.
- **Next-word strip** above the caret while you type: up to five likely words, likeliest first, ordered by a language model that reads your last few sentences. That is what makes the verb form follow the tense you are writing in: after `Yesterday we` the letters `walk` offer **walked** first, after `She is still` **walking**, after `Every morning she` **walks**. It never offers slurs or swear words. Tab types the highlighted one (the first, to begin with) and the strip moves on to the word after it. → steps the highlight to the next word and ← steps back, then Tab or Return types it; ⌥1…5 pick a slot directly. The arrows are only taken when the app has no use for them: → when nothing follows the caret on its line, ← once → has moved the highlight. With text to the right of the caret, and for ↑/↓ always, arrows stay caret movement and the strip steps aside. Esc hides it until the next word.
- **Size and glass of the panels are yours to pick** (Settings → Writing → Suggestion Size, Glass). Size: Compact (the default, about a fifth smaller than before), Regular, Large. Glass: Clear (the default: smoked glass, the document shows through and the words are drawn bolder with a fine outline), Standard (the frosted look every earlier build had), Solid (hides the document, for the strongest contrast). `defaults write com.jacobfu.tabby.dev cotabbyPanelSize regular` and `cotabbyPanelGlass standard` bring back the old look.
- **The strip follows your keys, not the app.** It is redrawn the moment a key is pressed, for the text that key leaves, also after a hyphen or a slash and in apps that are slow to report what was typed (chat and browser windows take 30 to 400 ms). It stays when a message box grows a line, and a Tab pressed before the app has caught up waits for it and then types the word.
- **Panels go away when you stop.** Five seconds after your last key the strip and the spelling bar are taken down, and the next key brings them back.
- **Inside a word the bar waits for a pause.** A slip in the middle of a word no longer swaps the strip for a bar on every key: the strip stays (and offers the word a slip away from what you typed), and the bar comes up if you stop for a third of a second or when the word is finished.
- **Capitals like the iPhone:** the first word of a sentence and `i` / `i'm` / `i've`.
- **Words joined by a dot, slash or hyphen get the same help.** In `users.nmae`, `read/wriet` or `schema.table.colum` the word after the mark is checked and the strip completes it, and a word finished by a slash or a hyphen is checked like one before a comma (`recieve/`, `teh-`). Because such text is as often a name as prose, a fix there is offered on the bar and never made by itself, and the word after a dot is not capitalized. Web and email addresses, file names (`notes.txt`), paths (`src/main/app`, `~/Desktop`) and version numbers are left alone as before. Right after a dot the strip waits for the first letter, since a dot is nearly always the end of a sentence.
- **The second half of a hyphenated word keeps its strip (0.4.6).** While you type `user-fac` or `well-kn` the spelling check looks only at the letters after the hyphen. It used to ask about the whole token, and since no dictionary word starts with `user-fac`, the half-typed compound was a misspelling on every key: the bar that came up when you paused (`user-fat`, `well-in`) took the strip down just as you looked at it. On 80 everyday compounds that was 118 of 532 typing moments, now none. A slip after the hyphen is still caught (`well-knwon` → well-known), and the finished compound is checked whole as before. A word typed straight after a long dash (`done—then`, which macOS writes for two hyphens) gets a strip as well; it used to get none.
- **Sentence pass** when you finish a sentence (`.` `!` `?`), and in a line with no closing mark whenever you stop typing in it (from five words, 0.7 s after your last key, at the end of a word). An unfinished line's last word is left for the next look, since what follows often decides it; a fix you undo and a word you typed past on the card are not brought up again in that line:
  - fixed automatically: doubled words (`the the`), `hello ,world`, double spaces, leftover certain typos;
  - also fixed automatically: `could of` → could have (not `of course`);
  - reviewed in one pass: likely wrong words judged from both sides (`went their yesterday` → there, `to tired` → too, `I want to by a car` → buy) and uncertain typos. The card steps through them: Tab takes the fix and moves on, ←/→ pick another option, Esc keeps your word (and it is not flagged there again). Typing closes it with no change. Wrong words are never changed without asking.
- **Learns you:** a fix you pick or retype ranks higher next time. Once you have made the same fix for the same slip twice, that word leads the bar whatever the dictionary thinks is likelier, and from the third time it is made for you (`wich` → which, for someone who always means *which*, even though *with* is the commoner word). A slip you correct to two different words about as often has no habit and stays a choice. Undoing a fix marks the word as meant; correcting it yourself later takes that back. A fix only counts as undone once it has been seen in the field and is gone again, so a fix that never landed is not read as you rejecting it.
- **Learns the words you keep.** A word Cotabby flags that is still there, as you typed it, in three lines you finished or sent becomes yours: no more bar, the strip offers it, and the sentence pass leaves it alone. A word you have ever corrected is never learned this way, and correcting a learned word once takes it back out.
- **Knows software terms:** about 1,130 engineering words are built in, so `backend`, `kubectl` and `jsonb` are not flagged, slips go to the term (`frontned` → frontend), and the strip offers `Kubernetes`, `JSON` or `repo` where the text calls for them (see "Software-engineering vocabulary").
- **Learns your working vocabulary** (Settings → Writing → Learn From My Sentences, on by default). Three things, all on this Mac:
  - every word of a sentence you finish is counted, with the words before it. A sentence with a system name or a term in it used to teach nothing; now only the unknown spelling itself is left out, so a slip is never offered back;
  - the strip's order then leans toward the words you use far more than general English does (`replay`, `tenant`, `backfill` for someone who writes them all day) and toward what you wrote after the same words before, without overruling the model where it is sure;
  - the word model reads your last few finished sentences before the field you are typing in, so in a chat box it starts a new message already knowing the subject, the terms and the names of the last ones. Those sentences are kept in memory only, about a page, and are gone when Cotabby quits.

  On a day of real work sentences this took the first suggestion from right 44% of the time after one typed letter to 54%, and from 54% to 65% after two (see "Learning the writer"). "Clear Learned Words, Phrases and Fixes" clears all three, and with them the fixes you accepted and the words you kept as typed. Nothing new is learned while Show Next-Word Predictions is off.
- **Learns your words:** a name or term the dictionary lacks, once you have written it twice, becomes a correction target in your capitals (`lindqvsit` → Lindqvist instead of Lundqvist). Stored locally; "Clear Learned Words, Phrases and Fixes" clears it.

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
| `strip` | you finish a word, or pick one | every strip drawn for the word with the letters typed at the time (`draws`), `listedAt` and `listedSlot`: how many letters you had typed when the word you meant first stood in the strip, and where; also the strip before any letter (`shownFirst`) and as it last stood (`shownLast`), how many letters you had typed by then, the slot you picked (`pickedSlot`, absent when you typed the word out), and `rank`: where the word you meant stood in the last list (0 is first, absent when it was not listed) |
| `decision` | the spelling engine flags a word | what it did (`fixed` without asking, `offered`, `offeredChoices`, `offeredWrongWord`, or `held`), its candidates best first with their scores, and the trained model's `confidence` in the first one |
| `outcome` | you react | what became of the word: `autoFixKept`, `autoFixUndone`, `autoFixReplaced` (you changed the fix into a third word: a wrong fix, with the word you meant), `picked`, `keptAsTyped`, `selfCorrected` |
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

The first full day recorded on 0.4.3 (1,043 records) showed what the record itself was missing, and
0.4.4 fills it in:

- **Every line of a message.** Only the last line was saved when Return sent a message; a line ended
  with Shift+Return is now saved like one that was sent. About 72% of the lines typed that day were
  saved.
- **The whole last word.** A line was saved as the app had last reported it, so one line in ten ended
  in a word cut short (`gy` for `gym`). It is now saved as the keys left it.
- **What the strip showed at every letter** (`draws`, `listedAt`, `listedSlot`). `rank` only looked at
  the last strip, which is usually drawn for the complete word and so never lists it: `rank` was
  absent for 720 of 840 typed-out words, and for 466 of those only for that reason. And nine words in
  ten had no strip step at all, because the strip for the next word was drawn before the finished one
  was reported.
- **Wrong fixes you replace** (`autoFixReplaced`). A fix you delete and replace with another word left
  no trace: 8 of 10 wrong fixes that day were invisible to the record and to the count that tunes the
  auto-fix threshold.
- **When and where, on every record.** `day` and `app` are stamped on every line, and each example has
  `run` (a random name for one launch of the app) and `at` (milliseconds into that launch), so the
  single events whose sentence was never saved still line up in time. They had neither.
- A sentence that ends in several marks (`!!!`) is saved, a dot inside a file name no longer cuts the
  sentence there, a sentence's `context` is read when the sentence is finished and not 0.8 s later when
  a sent message's field is already empty, and a sentence-model pass over a line that was still being
  written is a step of the sentence it became.
- A `decision` step is now written when a bar is really shown or a fix made. Before, one was written
  on every key while a word with a slip in it was being typed (1,173 of 1,886 that day), which read
  as 1,400 offers where there were 280.

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

`Tools/prediction/build_technical_words.py` holds about 1,130 terms (languages, tools, protocols, data
formats, cloud services, and the everyday jargon of code review and operations) and writes two lists:

- **`technical_words_en.txt`, for the word strip:** every term with a count and its usual capitals.
  The language model that orders the strip can now put `Kubernetes`, `JSON`, `GitHub`, `TypeScript`,
  `kubectl` or `repo` first where the text calls for it, shown the way it is written. A term that is
  also an ordinary word (`swift`, `spring`, `react`, `rust`) gets no capitals, so a sentence about
  the weather is not offered a programming language.
- **`technical_spelling_en.txt`, for the spelling dictionary:** the 660 terms the dictionary lacks
  that can be accepted as typed without hiding a real slip.
  These are no longer flagged (the system checker calls most of them misspelled), slips are fixed
  toward them (`frontned` → frontend, `josn` → json, `kuberntes` → kubernetes), and the sentence
  model leaves them as typed. A term that is one ordinary slip from a common word stays out on
  purpose: `aws` is how `was` comes out with two keys swapped, `iam` is `I am` run together, `util`
  is `until` with a letter dropped, and as dictionary words they would make those slips look right
  (the builder prints the ones it keeps out). The strip still offers them. Other short terms (`ttl`,
  `sdk`, `rpc`, `cdn`) go in at a count low enough that they are accepted as typed and never the
  target of a fix.

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

**Keyboard slips: measured, and the retrained model not shipped (0.4.4).** The training typos are
handwriting and spelling beliefs. A recorded day of one writer's typing was 77% one-edit finger slips
(a key beside the one meant 25%, a dropped letter 26%, an extra letter 20%, two letters swapped 18%),
and where the model's first candidate was right it fixed 82% of the swaps but only 22% of the
neighbouring-key slips. `build_dataset.py` now generates such slips on words of held-out sentences
(`keys-train`, `keys-test`), and every report includes the keyboard test:

| Keyboard test (7,362 flagged slips) | Trained without the slips, as shipped | Trained with the slips (weight 0.3) | Two models (short words without them) |
|---|---|---|---|
| Fixed unasked, wrong among them | 47.3%, 1.4% | 67.0%, 1.4% | 52.2%, 1.4% |
| Right first candidates that were fixed | 55.6% | 75.6% | 60.8% |
| Typos in sentences (1,313) | 62.7%, 3.2% | 62.1%, 2.9% | 61.6%, 2.8% |
| Typos in an empty field (1,711) | 69.0%, 3.6% | 64.2%, 2.9% | 64.0%, 2.8% |
| Words the checker flags in untouched text | 80 edited | 88 | 85 |
| Two real days: fixed unasked / changed to another word | 344 / 3 | 380 / 7 | 359 / 1 |

Trained with the slips, the model fixes far more generated slips but, on the two real days, its new
fixes of two- to four-letter forms were wrong 6 times in 43, where the generated test predicted 1 in
75: a generated slip of `form` is not the `fomr` a writer types for `from`. Keeping the short words on
a model trained without the slips removes those errors and most of the gain with them (a plain
retrain on today's engine already gives 353 of those 359). Neither clears the bar of "more fixes, no
more wrong ones, no more edits of untouched text", so in 0.4.4 the shipped model is unchanged (0.4.5
uses the retrained model another way, see "Two judges" below). The options stay
in `train.py` (`KEYS_WEIGHT`, `SHORT_TARGET_WRONG`, `SHORT_PLAIN`); with none set it trains as before.
What would help is the writer's own short-word slips as training rows, which the fuller training
record of 0.4.4 starts to collect.

A rule was tried on top of it and rejected as well: offer every form of up to four letters on the
bar and fix only a clean swap of two neighbouring letters (`teh`, `taht`). With the shipped model it
took away about ten right fixes on one recorded day (`tht`, `rght`, `clen`) and no wrong one, and it
contradicted seven regression cases where the words before settle a short form (`they wher` → were,
`she hit her hed` → head). The wrong short fixes of that day came from the certain-misspellings table
and from habits, not from the model, and those are handled where they arise: `thay` left the table,
and a fix the writer replaces or undoes now takes the habit down a step.

### Two judges (0.4.5)

The bar set for 0.4.4, "not one more wrong fix", was too strict for what the writer asked for: more
slips fixed without a question, with a wrong fix now and then accepted as the price. Replacing the
model failed for a narrower reason than its confidence: trained with finger slips it also *orders*
the candidates of a few ambiguous forms worse (`sayed` as `stayed` with a dropped letter, where the
writer meant `said`), and the first candidate is the word that gets typed.

So the order stays with the first model, and the retrained one is bundled beside it as a second
judge (`autofix_keyboard_en.json`, read by `TypoGateInputs.secondOpinion`). It is asked only about
the candidate the first judge put first, and its confidence counts only when

- it puts that same candidate first itself,
- that candidate's score leads every other by the margin under which the bar shows a list (0.15),
  so `agen` (again, agent) and `sayed` (said, stayed) stay questions, and
- no other candidate sounds exactly like what was typed.

Everything the first judge fixes alone is fixed as before; the second can only add fixes. It is
trained with the slips at weight 0.3 and a stricter bar for forms of up to four letters that are not
a plain swap (2% wrong out of fold, 4% for the rest); the command is in `Tools/autofix/run.sh`.

Measured through the real gate (`cotabby-spell --accuracy`, `--clean`, `--replay --adapt`), first
judge alone against both:

| | First judge alone (0.4.4) | Two judges (0.4.5) | Of the added fixes, wrong |
|---|---|---|---|
| Two recorded days: slips the writer corrected, fixed unasked (663) | 342 | 375 | 0 of 33 |
| Two recorded days: fixed to another word than the one meant | 3 | 3 | |
| Two recorded days: words left as typed that are changed (3,398) | 91 | 108 | 15 are slips left standing, fixed right; 2 are one-word fragments nobody can judge |
| Other writers' misspellings in held-out sentences (8,000) | 49.5% | 56.6% | 10 of about 570 |
| Generated finger slips in held-out sentences (8,000) | 43.5% | 54.9% | 13 of about 910 |
| Wikipedia typos, bare words (1,097) | 66.3% | 67.7% | 1 of about 15 |
| Birkbeck misspellings, bare words (15,153) | 34.9% | 35.9% | 45 of about 150 |
| Schoolchildren's spellings, bare words (429) | 23.8% | 25.6% | 1 of 8 |
| 40,000 words of untouched text: edited | 24 | 26 | |
| Engine time per key, 95% within (regression cases) | 1.85 ms | 1.86 ms | |

Read it this way. In a sentence, where the app always is, about 98 of 100 added fixes are right and
the share of wrong ones among all automatic fixes falls (6.5% to 5.9% on the misspelling sentences).
On a bare word with nothing before it the second judge adds little and 3 in 10 of that little is
wrong: a spelling by ear that lands one key from another word (`brigth` meant as `bridge`). The cost
is real and small: on the held-out sentences about one more wrong fix per 800 misspelled words.

The margin and sound conditions were chosen with a look at the two recorded days, so those two rows
are not a clean test. The held-out rows were run once, afterwards, and nothing was tuned on them.
A writer who undoes fixes raises the threshold for both judges at once
(`adaptedAutoApplyMinimumConfidence`), and an undone fix is never made again for that word.

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

- **Your last sentences first.** In a short field (a chat box, a comment) the model is first shown
  the sentences you finished lately, up to about a page (`RecentWriting`), then the field's text. A
  field with 800 characters of its own is read alone. The page changes its beginning only once in
  many sentences, so the model's memory of it stays valid and a key costs what it did before.
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

### Learning the writer

The strip was right on written test documents and far less so on a real writer's working day:
after one typed letter the first suggestion was right 70% of the time on the documents and 44% on
the day's sentences. Three faults, three fixes; the full account with what was tried and dropped
is in `Tools/prediction/README.md` ("Round three").

| First suggestion right | 1 letter | 2 letters | 3 letters | all moments |
|---|---|---|---|---|
| A real day of work sentences, 0.4.2 | 43.9% | 53.7% | 66.3% | 46.0% |
| now | 53.5% | 64.9% | 74.6% | 53.7% |
| Ten invented writers the design never saw, before | 54.3% | 66.3% | 76.1% | 58.2% |
| now | 63.4% | 75.9% | 84.3% | 65.8% |
| General documents (nothing to learn), before | 71.0% | 83.0% | 90.2% | 71.7% |
| now | 70.4% | 83.0% | 90.1% | 71.5% |

- **Not fitted to one person.** Every number in the design was chosen on five invented writers in
  five jobs, checked on five others, and scored once on ten more (a nurse, a paralegal, a kitchen
  manager, engineers, a bookkeeper…). All ten gained, 5 to 9 points. The real day was only ever
  scored, never tuned on. The general documents are the price check, and they lose 0.2 points.
- **It grows with use.** For a word you have typed ten times or more the first suggestion is right
  about four times in five; for a word it sees for the first time, less than half the time. One
  day of sentences is mostly first times, so expect it to keep improving over the first weeks.
- **Guards.** A spelling nothing vouches for is never counted. A word used many times in one sitting (half an hour of writing) counts as three uses of it, so a pasted page or one busy afternoon does not become a habit. Habits are added to the
  model's score in small amounts and cannot overrule it where it is sure. The recent sentences are
  only ones the proofreader would not change, and a pasted block longer than half a page is not kept.
- **Not covered yet.** Counts do not fade, so the vocabulary of a job you left stays boosted until
  "Clear Learned Words, Phrases and Fixes". Text you paste and then send is learned like text you typed.

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
E2E_ONLY=steady Tools/e2e/live-smoke.sh       # the strip in a slow app, after - and /, left alone, in a field that changes its frame
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

## Battle test (0.4.3)

Before 0.4.3 the whole app was attacked on purpose: 36 readers went through the code one area each,
28 testers drove the real engine from the command line with inputs of one kind each (contractions,
code, names, mix-ups, dyslexic spellings, chat shorthand, capitals, numbers, symbols, other
languages), and 36 skeptics then tried to reproduce or refute every report. Of 172 reports 93 were
confirmed, 55 refuted or intended, the rest unproven. What was fixed, each with a test that failed
before:

- **A sentence fix could delete too much next to an emoji.** Deletions were counted in UTF-16 units
  and typed as Backspace keys; an emoji is one key and two to seven units. Keys are now counted as
  the field's own text needs them, and where that depends on the app (letters with a separate
  accent mark) nothing is edited.
- **The sentence pass rewrote code-like text.** `/etc/passwd` became `/etc/passed`, `i7` and `i18n`
  got a capital `I`, `a,b,c` and `TL;DR` were respaced. A token that is part of a path, a dotted or
  hyphenated name, a flag, or touches a digit is now neither fixed nor offered. `must of` and
  `might of` are rewritten only where they are certainly verbs, and a doubled name (`Bora Bora`)
  stays.
- **Capitals.** `OAuth`, `GHz` and `JUnit` are left alone; `IPhone` becomes `iPhone`. A command or a
  lowercase term typed first on a line keeps its case (`pwd`, `git`, `kubectl`, `json`). A word
  after `eg.` or `ie.` is not capitalized.
- **Words with two readings are no longer forced to one.** `wher`, `whos`, `brot` and a few more
  left the table of certain fixes and go to the bar. About 200 software terms were added, and
  short ones (`ttl`, `sdk`, `rpc`) are accepted as typed.
- **The strip.** One acronym no longer makes every suggestion ALL CAPS, fragments (`th`, `s`,
  `didn`) are never offered, ordinals and hyphenated words no longer silence it, and no strip
  shows while the caret is inside a word. A pick refuses to type when the field is not the text
  the strip was drawn for, and adds no space before text that is already there.
- **Only what you just typed is corrected.** A click into a document that ends in a misspelled
  word used to get that word fixed when a background event arrived; fixes now need a key of yours.
- **Settings do what they say.** Reset All Settings resets every switch and brings a hidden menu
  bar icon back. The clear button also forgets accepted fixes and kept words. The training pane
  shows what is on disk. Turning the strip off stops its learning.

- **Undoing a fix by retyping the word is learned every time.** Found by the on-screen run of 0.4.3
  itself: a Backspace that lands between Cotabby's read of a field's selection and its read of the
  text makes the caret seem to lie past the end. That was taken for the field going away, which
  ends the focus session and with it the watch on the fix just made, so the word typed back was
  fixed again. The field is now read once more before that is believed. The race shows up once in
  a few hundred Backspaces, so the test host serves one such read on request: with the second read
  the undo is kept, and a build without it fails the same case the way the release run did.

Known and not fixed: a capitalized `Ive` (a name) is still read as `I've`; a few two-edit slips
pick the commoner neighbour (`was bord` → born); `asan` is read as `as an`; text you paste and send
is learned like text you typed; counts of words you no longer use do not fade.

## A day of real typing (0.4.4)

The first full day recorded with 0.4.3 (1,043 records from chat and browser windows: 130 saved
lines, 1,099 words with a strip record, 1,886 spelling decisions) was read by twelve analysts, one
angle each, and their main claims were checked against the code and on screen. What it showed, and
what 0.4.4 does about it:

| What the day showed | What changed |
|---|---|
| The strip was redrawn only once the app reported a key. In an app that is slow at that, it stood behind the word; after `-` or `/` it still completed the word before, because only letters, spaces and apostrophes were followed, and because a slow app's older text was taken for the newest | The strip is drawn from every key, for the text the keys leave (`TextFromKeys`), and a read of the field that is only an earlier state of those keys is recognised and waited out, by the strip and by the spelling check |
| A text box that changes its frame (a message box growing a line) counted as another field: the strip vanished and Tab typed a tab | The same Accessibility element under a new number is the same field |
| A Tab pressed before a slow app had reported the last letter was swallowed and typed nothing | The pick waits up to half a second for the field and then types |
| From the first slipped letter of a word every key drew a spelling bar and took the strip down: 1,173 bars, two in three with another first word than the one before, seven in ten gone within 200 ms. 257 of the 325 words whose strip stopped before their last letter were this | Inside a word the bar waits for a pause of 0.3 s; the strip stays, and offers the word a slip away from the letters typed |
| With a slip in the first letters the strip listed only rare words that start with them (`habitat` for `hab` when `have` was meant): 168 words | The language-model ordering gets the near misses as their own list. After a slip the word meant is listed 82.1% of the time (was 76.7%) and first 71.4% (was 68.9%); text typed right loses 0.1 point of first-suggestion accuracy |
| The sentence pass needs `.`, `!` or `?` and a space. 106 of 130 lines ended in nothing and were sent with Return: it ran on 4, and 105 errors were left standing | A line with no closing mark is proofread whenever the writer pauses in it (from five words; its last word waits for the next look). Replayed on that day's lines the pass makes 7 right fixes and 1 doubtful one in words the writer left as typed |
| One product name was written 25 times and flagged 24 times, with the same wrong fix offered each time. Nothing learned from typing past the bar | A flagged word left standing in three finished lines is kept. On that day the name is flagged 3 times instead of 17 on a fresh install |
| 305 of 1,067 bundled software terms were flagged one letter before they were complete (`debounc`), because "could still become a word" only asked the 30,000 commonest words | The check also asks the software terms and the words the writer keeps |
| 8 of 10 wrong automatic fixes left no trace: the writer replaced the fix with a third word, which is not an undo | Recorded as `autoFixReplaced`, counted as a wrong fix, and the right word is learned |
| The strip and the bar had clocks of 8 and 10 s that restarted whenever the panel was drawn, also with nobody typing | One clock, five seconds from the last key, and a panel that went away stays away until the next key |
| One undo marked a slip as "meant as typed", also when the fix was a habit made dozens of times: the commonest slip of the day stood unflagged after one stray undo | An undo takes a habit down a step (it leads the bar and is automatic again after one more use) instead of switching it off |
| A word retyped from one character further back than it began (the space before it deleted too) taught nothing | The watch on that word holds while the writer deletes back past it |
| Before any letter, the strip sometimes offered the word just written again (after `read/`, `read`) | The word just written is not offered as the next word |
| The record lost lines, last words, and most strip steps | See "Training data" |

Looked at and not changed, because the day's numbers argue against it:

- **Lowering the auto-fix threshold.** Between 0.60 and 0.75 about one first candidate in five was
  wrong, and the wrong fixes that were made sat at 0.78 to 0.92 among the right ones.
- **Ordering the strip by keys saved.** The writer takes the first slot (86% of 259 picks, after two
  or three letters); ordered by keys saved, the word they picked would have stood first 47 times
  instead of 205.
- **Dropping completions with one or two letters left.** It would have cost 17 to 41 of the picks.

Still open: wrong real words (`its` for `it's`, `form` for `from`) are mostly left to the sentence
model, which fixes some at a pause and none in the last word of a line; and a sentence sent with
Return right after its last word gets no look at that word.

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

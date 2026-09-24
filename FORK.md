# Dyslexia-assist fork

Spelling help that keeps up with fast, error-heavy typing. Everything below runs on your Mac; no language model is involved in spelling.

## How it works while you type

- **Certain fixes happen by themselves** when you finish a word: `teh` → the, `becuase` → because, `enuf` → enough, `dont` → don't, typos before a comma or period too. A short green flash shows what changed; Cmd+Z undoes it.
- **Unsure words open a three-slot bar** above the word, like the iPhone: `"what you typed"` | **best fix** | runner-up. Tab takes the highlighted slot, ←/→ move, ⌥1/2/3 pick directly, or click. Return only picks after you move the highlight. Picking the quoted slot keeps your word and stops flagging it. If you keep typing, the bar just goes away.
- **Capitals like the iPhone:** the first word of a sentence and `i` / `i'm` / `i've`.
- **Sentence pass** when you finish a sentence (`.` `!` `?`):
  - fixed automatically: doubled words (`the the`), `hello ,world`, double spaces, leftover certain typos;
  - reviewed in one pass: likely wrong words judged from both sides (`went their yesterday` → there) and uncertain typos. The card steps through them: Tab takes the fix and moves on, ←/→ pick another option, Esc keeps your word. Typing closes it with no change.
- **Learns you:** fixes you pick rank higher next time.

## Engine

- 82k-word dictionary with SymSpell (edit distance 2), preloaded in memory at launch.
- Sound-alike index over the 30k most common words (`skool` → school, `fisical` → physical).
- A table of ~340 certain misspellings and dropped apostrophes (non-words only, no slang).
- 242k English word pairs for context (`know wich` → which, `different form` → from).
- Optional: Jev (TypeSafe) can re-rank unsure words from the full sentence; Groq can add a grammar check. Both off unless you add a key.

Measured with `cotabby-spell` (below): 163/163 edge cases, 22/22 sentence cases, 176 automatic fixes on three test lists with 0 wrong, per-keystroke cost p50 < 0.1 ms, p99 ≈ 11 ms. Live test in the real app: 14/14.

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

# Build + install Cotabby Dev, then drive it live. The live test types into its own test host app
# (Tools/e2e/TestHost), never your apps or documents, and restores your Cotabby history afterwards.
Tools/install-dev.sh
Tools/e2e/live-smoke.sh
```

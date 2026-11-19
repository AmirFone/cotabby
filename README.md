> **This is a fork** of [FuJacob/cotabby](https://github.com/FuJacob/cotabby) that adds spelling help for dyslexic writers: on-the-spot fixes, a spelling bar, a next-word strip that follows the tense and the subject you are writing in and offers your own names and terms, American spelling on a US Mac, and a sentence model. Downloads are on this fork's [releases page](https://github.com/AmirFone/cotabby/releases); no Xcode needed.
>
> Everything below the next section is upstream's README.

## Best configuration for this fork

Everything here is in Settings; nothing needs a terminal. Measurements and how they were made are in [FORK.md](FORK.md).

| Setting | Best value | Why |
|---|---|---|
| Other typing assistants | Run only this Cotabby. Quit the released Cotabby and remove it from System Settings → General → Login Items | Its ghost text also takes Tab and types words of its own. This build warns you once if it is running |
| Engine & Model → model for the word strip | **tabby-2-base** (3.8 GB) on a Mac with 16 GB of memory or more; **tabby-2-mini** (1.3 GB) from 12 GB; **tabby-2-nano** (0.6 GB) below that | The strip uses the best one installed by itself. First suggestion right while typing a word: 83% / 79% / 76%, against 69% with no download |
| Writing → Show Next-Word Predictions | On (default) | The strip above the caret; Tab takes the first word, ⌥1 to ⌥5 pick directly |
| Writing → Automatically Fix Confident Typos | On (default) | Certain slips are fixed as you finish the word; Cmd+Z undoes one and it is not made again. From 0.4.5 a second model, trained on finger slips (a neighbouring key, a dropped or swapped letter), lets more of them through |
| Writing → Offer Corrections on Typo, Hide Suggestions on Typo | On (defaults) | Unsure words get the three-slot bar instead of a guess |
| Writing → macOS Autocorrect Is Also On | Press the button to turn macOS's own autocorrect off | Two autocorrects fight over the same word |
| Writing → Learn From My Sentences | On (default). Leave it on for a few days of normal work before judging the strip | The strip learns the words you use far more than general English does and what you write after which words, and the word model reads your last few sentences before a new message. Measured on real work sentences: first suggestion right after one letter 44% → 54%, after two 54% → 65%. Stored only on this Mac; "Clear Learned Words, Phrases and Fixes" resets it |
| Writing → Training Data → Save Training Examples | On if you want to train on your own writing or see where Cotabby was wrong; off by default | Saves each sentence with what was shown, decided and done. It stays on your Mac until you press Export |
| Writing → Suggestion Size, Glass | Compact and Clear are the defaults; pick Standard glass for the frosted look of earlier builds, Solid for the strongest contrast, Regular or Large for bigger words | The strip is on screen most of the time, so by default it covers as little of your text as it can |
| Software-engineering terms | On by default: about 1,130 terms (`backend`, `kubectl`, `jsonb`, `Kubernetes`, `JSON`) are known to the strip and the spelling engine | `defaults write com.jacobfu.tabby.dev cotabbyTechnicalVocabularyEnabled -bool false` turns it off |
| Spelling style | Nothing to set on a US Mac: fixes and suggestions come in American spelling | `defaults write com.jacobfu.tabby.dev cotabbySpellingStyle british` (or `american`) overrides it |
| Shortcuts → Toggle Cotabby | Control+Option+C (default) | Turns everything off and on from any app |

It gets better as you use it: a fix you make twice for the same slip leads the bar from then on, and from the third time it is made for you. A word of your own that Cotabby flags stops being flagged once you have left it standing in three lines.

Three things need no setting. The strip and the spelling bar go away five seconds after your last key and come back with the next one. A line is proofread when you finish the sentence, and also whenever you pause in it, so a chat message with no period is checked before you send it. And in a slow app (a chat or browser window) the strip keeps up with your keys instead of waiting for the app.



<p align="center">
  <a href="https://cotabby.app" target="_blank">
    <img height="150" alt="Cotabby logo" src=".github/assets/readme/logo.png" />
  </a>
</p>

<h1 align="center">Cotabby [beta]</h1>

<p align="center"><em>Open-source, local-first AI autocomplete for macOS.</em></p>

<p align="center">
  <a href="https://cotabby.app">
  <img width="200" alt="landing-page" src="https://github.com/user-attachments/assets/c28fbb4b-6dfb-4403-a040-1df61daf4df2" /></a>
  

<a href="https://github.com/FuJacob/cotabby/releases/latest/download/Cotabby.dmg">
<img width="200" alt="download" src="https://github.com/user-attachments/assets/d5cb4454-d2ab-41d3-9d36-171d44ebfc52" /></a>


<a href="https://ko-fi.com/cotabby" target="_blank">
<img width="200" alt="support" src=".github/assets/readme/support-cotabby.png" />
</a></p>

<p align="center">
  <a href="https://github.com/FuJacob/cotabby/actions/workflows/build.yml"><img alt="Build" src="https://img.shields.io/github/actions/workflow/status/FuJacob/cotabby/build.yml?branch=main" /></a>
  <a href="LICENSE"><img alt="License: AGPL v3" src="https://img.shields.io/badge/license-AGPL--3.0-blue.svg" /></a>
  <a href="https://github.com/FuJacob/cotabby/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/FuJacob/cotabby" /></a>
  <a href="https://github.com/FuJacob/cotabby/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/FuJacob/cotabby/total" /></a>
  <a href="https://github.com/FuJacob/cotabby/stargazers"><img alt="Stars" src="https://img.shields.io/github/stars/FuJacob/cotabby?style=flat" /></a>
  <img alt="Swift" src="https://img.shields.io/badge/Swift-F05138?logo=swift&amp;logoColor=white" />
  <img alt="Platform" src="https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey" />
</p>

<p align="center">
  <sub>Cotabby is free and open-source — maintained by two students. If it's useful to you, please consider supporting Cotabby's future.</sub>
</p>

---

## What It Does

Cotabby adds AI autocomplete to almost any text field on your Mac. As you type, a gray suggestion appears inline next to your cursor. Press `Tab` to accept it a word at a time, or keep typing to ignore it.

The default Apple Intelligence and Open Source engines run on your Mac. No account or telemetry is
required. An optional OpenAI-compatible engine can connect to a server you configure.

## Demo

<p align="center">
  <a href="https://www.youtube.com/watch?v=p3TIgxQFQGE"><strong>Watch on YouTube →</strong></a>
</p>

<div align="center">

|  |  |
|:---:|:---:|
| <img src="gifs/slack.gif" alt="Cotabby emoji autocomplete demo" width="400" height="225" /> | <img src="gifs/imessage.gif" alt="Cotabby autocomplete demo" width="400" height="225" /> |
| <img src="gifs/autocorrect.gif" alt="Cotabby autocorrect demo" width="400" height="225" /> | <img src="gifs/macros.gif" alt="Cotabby inline macros demo" width="400" height="225" /> |

</div>

## Features

- **Ghost-text autocomplete** — AI suggestions inline in almost any macOS text field; `Tab` accepts a word at a time
- **Emoji autocomplete** — type `:rocket:` and accept it without leaving the field
- **Inline macros** — type `/` for quick math, unit and currency conversion, dates, and random values
- **One-key autocorrect** — fix a likely typo with a single keystroke

## Privacy

Privacy is the whole point, so Cotabby's default engines keep generation on your Mac:

- Apple Intelligence and Open Source generation run on-device.
- The optional OpenAI-compatible engine sends a bounded request only to the endpoint you configure;
  that endpoint can be loopback, on your local network, or a public HTTPS service.
- No analytics, no telemetry, no crash reporting.
- A normal install never writes what you type to disk.
- Apart from a configured endpoint, the network is used for model downloads and update checks, not
  suggestion generation.

## Engines

Cotabby generates suggestions in three ways. You choose which in Settings → Engine:

- **Apple Intelligence** — Apple's model, built into macOS 26 or later on supported Macs. Nothing to download.
- **Open Source** — a small AI model you download that runs entirely on your Mac. Works on any supported Mac (macOS 14+), with or without Apple Intelligence.
- **OpenAI-compatible** — a completion or chat endpoint you configure, including local Ollama,
  another LAN host, or a public HTTPS service. Endpoint credentials are stored in Keychain.

If your Mac supports Apple Intelligence, that's the easiest place to start. Otherwise, use the Open Source engine and pick one of the built-in models:

| Model          | Size    | Good for                          |
| -------------- | ------- | --------------------------------- |
| `tabby-2-nano` | ~0.8 GB | Older or low-memory Macs; fastest |
| `tabby-2-mini` | ~1.4 GB | A solid everyday balance          |
| `tabby-2-base` | ~4.5 GB | Higher-quality suggestions        |
| `tabby-2-pro`  | ~5.0 GB | Best quality                      |

Download any of them straight from Cotabby's menu bar.

<details>
<summary><strong>Advanced:</strong> model files, custom models, and how generation works</summary>

<br />

Under the hood, the Open Source engine runs local GGUF *base* models in-process through [llama.cpp](https://github.com/ggerganov/llama.cpp) (via [CotabbyInference](https://github.com/FuJacob/cotabbyinference)). Instead of prompting an instruction-tuned chat model, Cotabby treats the model as a pure text continuer and conditions it on your name, writing style, language, and on-screen context.

| Model          | File                             | Size    | Source                                                                       |
| -------------- | -------------------------------- | ------- | ---------------------------------------------------------------------------- |
| `tabby-2-nano` | `Qwen3.5-0.8B-Base.i1-Q6_K.gguf` | ~0.8 GB | [Hugging Face](https://huggingface.co/mradermacher/Qwen3.5-0.8B-Base-i1-GGUF) |
| `tabby-2-mini` | `Qwen3.5-2B-Base.i1-Q4_K_M.gguf` | ~1.4 GB | [Hugging Face](https://huggingface.co/mradermacher/Qwen3.5-2B-Base-i1-GGUF)   |
| `tabby-2-base` | `gemma-4-E2B.i1-Q6_K.gguf`       | ~4.5 GB | [Hugging Face](https://huggingface.co/mradermacher/gemma-4-E2B-i1-GGUF)       |
| `tabby-2-pro`  | `gemma-4-E4B.i1-Q4_K_M.gguf`     | ~5.0 GB | [Hugging Face](https://huggingface.co/mradermacher/gemma-4-E4B-i1-GGUF)       |

**Bring your own model.** Any GGUF small enough to run on-device works. Drop a `.gguf` file into Cotabby's models folder and refresh the model list from the menu bar. Browse the [unsloth GGUF collection](https://huggingface.co/unsloth) for more variants — smaller quants (`Q3_K_M`, `Q4_K_S`) trade quality for size; larger models give better completions at the cost of memory and per-token latency.

For the full suggestion pipeline, see [ARCHITECTURE.md](ARCHITECTURE.md).

</details>

## Install

**Compatibility:** macOS 14.0 or later. The Apple Intelligence engine needs macOS 26 or later on a supported Mac; on older systems, use the Open Source engine.

### Homebrew

```sh
brew tap FuJacob/cotabby
brew install --cask cotabby
```

Upgrade later with `brew upgrade --cask cotabby`. The tap lives at [FuJacob/homebrew-cotabby](https://github.com/FuJacob/homebrew-cotabby).

### Manual download

Grab the latest release from [cotabby.app](https://cotabby.app) and drag Cotabby into your Applications folder.

## Using Cotabby

Start typing in almost any text field. When a gray suggestion appears:

- **`Tab`** — accept the next word. (Prefer whole phrases? Switch this in Settings → Acceptance Mode.)
- **`` ` `` (backtick)** — accept the entire suggestion at once.
- **`Esc`**, or just keep typing — dismiss it.

Every shortcut is rebindable under Settings → Shortcuts.

## Permissions

Cotabby works inside other apps, so macOS asks for a few permissions. Each one maps to a specific feature, and Cotabby walks you through them on first launch:

- **Accessibility** — read the text and cursor position in the field you're typing in, and insert what you accept.
- **Input Monitoring** — notice your typing so it knows when to suggest, and detect the accept keys.
- **Screen Recording** *(optional)* — capture the area around your cursor for visual context. Leave it off and everything else still works.

Cotabby blocks generation, presentation, and insertion in password and other secure fields.

## Local Development

Requires Xcode and Command Line Tools. Apple Silicon is strongly recommended for local model performance. For setup, build, test, and contribution workflow details, start with [CONTRIBUTING.md](CONTRIBUTING.md).

```bash
git clone https://github.com/FuJacob/cotabby.git Cotabby
cd Cotabby
open Cotabby.xcodeproj
```

If you want to understand the runtime and suggestion pipeline before contributing, read [ARCHITECTURE.md](ARCHITECTURE.md).

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, build, and PR guidelines, and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for community expectations. For a tour of the runtime and suggestion pipeline, read [ARCHITECTURE.md](ARCHITECTURE.md).

## Acknowledgments

- [llama.cpp](https://github.com/ggerganov/llama.cpp), [CotabbyInference](https://github.com/FuJacob/cotabbyinference), [Sparkle](https://github.com/sparkle-project/Sparkle), and [swift-log](https://github.com/apple/swift-log) for runtime, updates, and logging.
- Apple's FoundationModels, Accessibility, SwiftUI, and AppKit for on-device generation and macOS integration.
- [GitHub gemoji](https://github.com/github/gemoji) and Hugging Face for the emoji data and downloadable models.
- [SymSpell](https://github.com/wolfgarbe/SymSpell) by Wolf Garbe (MIT) for multilingual autocorrect; frequency dictionaries derive from [Google Ngrams](https://books.google.com/ngrams) (CC BY 3.0) and licensed SCOWL/Hunspell word lists.
- Everyone who filed issues, tested prereleases, and sent pull requests.

## Created by

Originally created by <a href="https://github.com/FuJacob">@FuJacob</a>, now developed and maintained by <a href="https://github.com/FuJacob">@FuJacob</a>, <a href="https://github.com/jam-cai">@jam-cai</a>. and <a href="https://github.com/akramj13">@akramj13</a>

## License

Cotabby is licensed under the [GNU Affero General Public License v3.0](LICENSE). You can use, study, modify, and redistribute the app, but if you distribute a modified version or make one available to users over a network, you must provide the corresponding source code under the same license.

Third-party dependencies, emoji data, and downloadable model weights keep their own licenses and usage terms. Bundled third-party notices (SymSpell and the autocorrect frequency dictionary) are reproduced in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

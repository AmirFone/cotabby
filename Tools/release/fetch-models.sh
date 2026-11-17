#!/bin/bash
# Fetches the two files a build from source needs that are too large for git, from this fork's
# release page:
#   next_word_model_en.bin         the word table behind the word strip (48 MB) -> Cotabby/Resources/
#   spelling-qwen3-0.6b-q8_0.gguf  the sentence model (639 MB) -> Application Support/Cotabby Dev/SentenceModel/
#
#   Tools/release/fetch-models.sh [tag]      default: the newest release
#
# A downloaded release (.dmg) already has both inside the app; this is only for building it yourself.
# Both can also be rebuilt from scratch: Tools/ngram/ and Tools/sentence-model/.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="AmirFone/cotabby"
if [ -n "${1:-}" ]; then BASE="https://github.com/$REPO/releases/download/$1"; else BASE="https://github.com/$REPO/releases/latest/download"; fi
MODEL_DIR="$HOME/Library/Application Support/Cotabby Dev/SentenceModel"
mkdir -p "$MODEL_DIR"
fetch() { # file name, destination
  if [ -s "$2" ]; then echo "have $2"; return; fi
  echo "fetching $1"
  curl -fL --progress-bar -o "$2.part" "$BASE/$1"
  mv "$2.part" "$2"
}
fetch next_word_model_en.bin Cotabby/Resources/next_word_model_en.bin
fetch spelling-qwen3-0.6b-q8_0.gguf "$MODEL_DIR/spelling-qwen3-0.6b-q8_0.gguf"
echo "done; build and install with Tools/install-dev.sh"

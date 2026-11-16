#!/bin/bash
# Rebuilds the next-word / context table (Cotabby/Resources/next_word_model_en.bin) from five
# corpora, and leaves in <work-dir> what Tools/autofix/run.sh needs to retrain the spelling models
# against it. Run from the repo root; downloads about 1.2 GB on the first run.
#
#   Tools/ngram/build_context_table.sh <work-dir>
#   TARGET_WRONG=0.04 Tools/autofix/run.sh <work-dir>     # then retrain both models (required)
#
# Sources: Tatoeba English sentences (CC BY 2.0 FR), Leipzig Corpora 1M-sentence news 2020,
# web-public 2018 and Wikipedia 2016 sets (CC BY), and the first 400 MB of the OPUS OpenSubtitles
# 2018 English file (about 7.6M subtitle lines). Only word-sequence counts are shipped.
# Every 50th sentence of each source is held out; a mix of those is what the models are scored on.
set -euo pipefail
WORK="$1"
DICTIONARY=Cotabby/Resources/frequency_dictionary_en_82_765.txt
mkdir -p "$WORK/tatoeba" "$WORK/corpus/news" "$WORK/corpus/web" "$WORK/corpus/wiki" "$WORK/corpus/subs"
fetch() { [ -f "$2" ] || curl -sSL ${3:+-r "$3"} -o "$2" "$1"; }
fetch https://downloads.tatoeba.org/exports/per_language/eng/eng_sentences.tsv.bz2 "$WORK/tatoeba/eng_sentences.tsv.bz2"
fetch https://downloads.wortschatz-leipzig.de/corpora/eng_news_2020_1M.tar.gz "$WORK/corpus/news/corpus.tar.gz"
fetch https://downloads.wortschatz-leipzig.de/corpora/eng-com_web-public_2018_1M.tar.gz "$WORK/corpus/web/corpus.tar.gz"
fetch https://downloads.wortschatz-leipzig.de/corpora/eng_wikipedia_2016_1M.tar.gz "$WORK/corpus/wiki/corpus.tar.gz"
fetch https://object.pouta.csc.fi/OPUS-OpenSubtitles/v2018/mono/en.txt.gz "$WORK/corpus/subs/en.part.gz" 0-419430399
for name in news web wiki; do
  [ -n "$(find "$WORK/corpus/$name" -name '*sentences.txt')" ] || tar -xzf "$WORK/corpus/$name/corpus.tar.gz" -C "$WORK/corpus/$name" --include='*sentences.txt'
done
# -I: the downloads are data, never a place Python may import from.
python3 -I Tools/ngram/prepare_corpora.py "$WORK/corpus/chunks" \
  "tatoeba:tatoeba:$WORK/tatoeba/eng_sentences.tsv.bz2" \
  "leipzig:news:$(find "$WORK/corpus/news" -name '*sentences.txt')" \
  "leipzig:web:$(find "$WORK/corpus/web" -name '*sentences.txt')" \
  "leipzig:wiki:$(find "$WORK/corpus/wiki" -name '*sentences.txt')" \
  "gzlines:subs:$WORK/corpus/subs/en.part.gz:8000000"
# 12 keeps the table under 50 MB (48 MB); 8 gives 58 MB and about one point more next-word accuracy.
NGRAM_MIN_TOTAL="${NGRAM_MIN_TOTAL:-12}" python3 -I Tools/ngram/build_large_model.py "$WORK/corpus/chunks" "$WORK/corpus/model.txt"
python3 -I Tools/ngram/export_binary.py "$WORK/corpus/model.txt" Cotabby/Resources/next_word_model_en.bin
for name in tatoeba subs web news; do
  echo "$name: $(python3 -I Tools/ngram/evaluate.py "$WORK/corpus/model.txt" "$DICTIONARY" "$WORK/corpus/chunks/heldout-$name.txt" 2000)"
done
# The spelling models train and test on typos placed in these sentences (run.sh reads this path).
python3 -I Tools/ngram/mix_heldout.py "$WORK/corpus/chunks" "$WORK/tatoeba/heldout.txt" tatoeba:20000 subs:20000 web:10000 news:10000

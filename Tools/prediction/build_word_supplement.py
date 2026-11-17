#!/usr/bin/env python3
"""Builds Cotabby/Resources/prediction_words_en.txt: everyday words the frequency dictionary lacks.

The strip's language model can only put a word first if the word is in its list, and the list was
the spelling dictionary alone. That dictionary leans British and predates a lot of current
vocabulary: it has `neighbour` and `travelling` but not `neighbor`, `traveling`, `favorite`, `mom`,
`theater`, `dataset`, `onboarding` or `you've`. This script finds such words in the same corpora the
context table is built from (`Tools/ngram/build_context_table.sh` leaves them as chunk files) and
writes them with a count on the dictionary's scale.

A word is added when all of these hold:
- it is not in the dictionary, is at least four letters (or is `mom`), and is written in lowercase
  mid-sentence at least 25 times in the corpora (120 for four letters or fewer), more often than
  it is capitalized (so not a name);
- the system spell checker accepts it as American English (`check_spelling.swift`);
- it is not half of a contraction (`didn`), speech spelled out (`goin`), or on the short list of
  fragments and foreign or offensive words below, which the first two rules let through.
Contractions are added by a closed rule: `'ve`, `'ll`, `'d`, `'re`, `n't`, and `'s` after a pronoun
or a similar word (`everyone's`, `how's`, `today's`), at least 150 uses.

The dictionary's own contractions are listed again with their real counts. It carries every one of
them at the same placeholder (`that's`, `you're` and `don't` all at 300,000, a thousandth of their
real use), which made the strip rank `that'll` above `that's`; the app takes the larger count of a
word listed twice. Contractions are counted in both cases, because `I'm` is always capitalized.

Usage:
  swiftc -O Tools/prediction/check_spelling.swift -o /tmp/check_spelling
  python3 -I Tools/prediction/build_word_supplement.py <folder with chunk-*.txt> /tmp/check_spelling \
      Cotabby/Resources/prediction_words_en.txt
"""
import collections
import glob
import multiprocessing
import os
import re
import subprocess
import sys

WORD = re.compile(r"[A-Za-z]+(?:'[A-Za-z]+)*")
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DICTIONARY = os.path.join(REPO, "Cotabby/Resources/frequency_dictionary_en_82_765.txt")
MINIMUM_USES = 25
MINIMUM_CONTRACTION_USES = 150
# Short strings are where fragments and noises hide (`kbit`, `whoo`), so they need more uses.
MINIMUM_SHORT_WORD_USES = 120

# What the rules above let through and a reader would not want offered: pieces of words and of
# foreign phrases, speech spelled out, and words nobody should be handed by a typing aid.
EXCLUDED = set("""
facto cetera situ vitro vivo priori faire bien dans mille mucho ingles beaucoup vous olds thats
theres gots dont youn youse hisself brung blowed bestest coulda shoulda woulda musta oughta whatcha
hella dawg ight handedly heartedly hander handers seater schooler schoolers brainer assed nighter
timey itty nilly tippy pitter turvy mumbo criss deja habeas modus operandi officio absentia amicus
laude fatale franca fait raison vivre guerre menthe entendre fixe joie laissez hors foie prima
facie novo forma annum avant masse noir cappella dente suey mahi kata chia mens fide
asshole assholes shite tranny dumbass dipshit fuckup badass pederast honkies pedophile pedophiles
pedophilia spics beaner skank skanky butthole butthead asswipe douchebag jailbait spaz gypped
shitless shitstorm apeshit perv pornos hentai gangbanger damnit chrissakes fleabag skeez sucky
buttcrack boinking micturated satyriasis l'll yada perp kbit sera
""".split())

CONTRACTION_ENDINGS = ("'ve", "'ll", "'d", "'re", "n't")
POSSESSIVE_BASES = set("""
how who what where when why there here that it he she let one else today tomorrow yesterday tonight
everything everyone everybody nobody somebody someone something nothing anybody anyone anything
mom dad
""".split())
WHOLE_CONTRACTIONS = {"y'all", "ma'am"}


def count_chunk(path):
    lower = collections.Counter()
    capital = collections.Counter()
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            # The first word of a sentence is capitalized whatever it is, so it says nothing.
            for word in WORD.findall(line)[1:]:
                if word.islower():
                    lower[word] += 1
                elif word[0].isupper():
                    capital[word.lower()] += 1
    return lower, capital


def is_wanted_contraction(word):
    if word in WHOLE_CONTRACTIONS or word.endswith(CONTRACTION_ENDINGS):
        return True
    base, _, ending = word.rpartition("'")
    return ending == "s" and base in POSSESSIVE_BASES


def main():
    chunks_folder, checker, output = sys.argv[1], sys.argv[2], sys.argv[3]
    lower = collections.Counter()
    capital = collections.Counter()
    with multiprocessing.Pool(min(32, os.cpu_count() or 4)) as pool:
        for part_lower, part_capital in pool.imap_unordered(count_chunk, sorted(glob.glob(f"{chunks_folder}/chunk-*.txt"))):
            lower.update(part_lower)
            capital.update(part_capital)

    dictionary = {}
    with open(DICTIONARY, encoding="utf-8") as handle:
        for line in handle:
            word, count = line.split()
            dictionary[word] = int(count)
    # Corpus counts are brought to the dictionary's scale through the commonest word of both.
    scale = dictionary["the"] / lower["the"]

    candidates = {}
    for word in set(lower) | set(capital):
        count = lower.get(word, 0)
        if "'" in word:
            # Both cases count: `I'm` is never lowercase, and `That's` inside a sentence is still `that's`.
            uses = count + capital.get(word, 0)
            if word in dictionary:
                if uses * scale > dictionary[word]:
                    candidates[word] = uses
            elif word not in EXCLUDED and uses >= MINIMUM_CONTRACTION_USES and is_wanted_contraction(word):
                candidates[word] = uses
            continue
        if word in dictionary or word in EXCLUDED or capital.get(word, 0) > count:
            continue
        if count < (MINIMUM_SHORT_WORD_USES if len(word) <= 4 else MINIMUM_USES):
            continue
        # Three letters or fewer, or two distinct letters (`mmm`, `hee`), are noises; `mom` is not.
        if word != "mom" and (len(word) < 4 or len(set(word)) <= 2):
            continue
        if word + "'t" in dictionary or word in ("isn", "aren"):
            continue  # the front half of a contraction that was typed with a curly apostrophe
        if word.endswith("in") and word + "g" in dictionary:
            continue  # goin, doin
        if word in ("https", "http"):
            continue
        candidates[word] = count

    listing = "".join(f"{word} {count}\n" for word, count in candidates.items())
    checked = subprocess.run([checker], input=listing, capture_output=True, text=True, check=True).stdout
    accepted = [line.split() for line in checked.splitlines() if line.strip()]
    accepted.sort(key=lambda pair: (-int(pair[1]), pair[0]))
    with open(output, "w", encoding="utf-8") as handle:
        for word, count in accepted:
            handle.write(f"{word} {round(int(count) * scale)}\n")
    uses = sum(int(count) for _, count in accepted)
    print(f"{len(accepted)} words written ({len(candidates) - len(accepted)} refused by the spell checker); "
          f"they are {100 * uses / sum(lower.values()):.2f}% of the corpus words")


if __name__ == "__main__":
    main()

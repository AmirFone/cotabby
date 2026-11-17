#!/usr/bin/env python3
"""Writes verb_forms.txt: one verb per line, all its forms that are in the app's dictionary.

The tense test (`cotabby-spell --typing ... --verbs verb_forms.txt`) uses it to know which words are
forms of one verb. Verbs with fewer than three forms in the dictionary are left out. A form that
belongs to two verbs (`found`: find, found) is tested with the first line that lists it, so lines
where it is an inflected form come before lines where it is the base form.

Needs `pip install lemminflect`. Usage: build_verb_forms.py <dictionary.txt> <verb_forms.txt>
"""
import sys
import lemminflect

dictionary_path, out_path = sys.argv[1:3]
counts = {}
for line in open(dictionary_path, encoding="utf-8"):
    word, count = line.split()[:2]
    counts[word] = int(count)

families = {}
for word in counts:
    if not word.isalpha():
        continue
    for lemma in lemminflect.getAllLemmas(word).get("VERB", ()):
        if lemma in families or lemma not in counts:
            continue
        forms = {f for group in lemminflect.getAllInflections(lemma, upos="VERB").values() for f in group}
        forms = sorted(f for f in forms if f in counts and f.isalpha())
        if len(forms) >= 3:
            families[lemma] = forms

def base_of_another(lemma):
    return any(lemma in forms and lemma != other for other, forms in families.items())

# Most used verbs first; verbs whose base is another verb's inflected form (found, saw, left) last.
ordered = sorted(families, key=lambda l: (base_of_another(l), -sum(counts[f] for f in families[l])))
with open(out_path, "w", encoding="utf-8") as out:
    out.write("# One verb per line: every form in the dictionary. Built by build_verb_forms.py.\n")
    for lemma in ordered:
        out.write(" ".join([lemma] + [f for f in families[lemma] if f != lemma]) + "\n")
print(f"{len(ordered)} verbs")

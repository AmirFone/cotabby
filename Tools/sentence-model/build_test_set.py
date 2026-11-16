#!/usr/bin/env python3
"""Builds the sentence-level test: whole sentences with one misspelling, one wrong real word, or
nothing wrong, plus hand-written sentences with misspelled names and technical terms.
Output lines: <kind><TAB><intended sentence><TAB><typed sentence>
Usage: build_test_set.py <mix-lines-dir> <birkbeck-dir> <out.tsv>"""
import random, re, sys
lines_dir, birkbeck, out = sys.argv[1:4]
random.seed(5)
typos = {}
for name in ("holbrook-missp", "wikipedia", "aspell"):
    for line in open(f"{birkbeck}/{name}-test.txt", encoding="utf-8"):
        if line.startswith("#") or "\t" not in line:
            continue
        intended, typo = line.rstrip("\n").split("\t")[:2]
        typos.setdefault(intended.lower(), []).append(typo)
clean = [l.rstrip("\n").split("\t")[3] for l in open(f"{lines_dir}/wrongword-clean-test.txt", encoding="utf-8")]
random.shuffle(clean)
rows, used = [], set()
for sentence in clean:
    words = [m for m in re.finditer(r"[A-Za-z]+", sentence) if m.group().lower() in typos and m.group().islower() and len(m.group()) > 3]
    if not words:
        continue
    m = random.choice(words)
    typed = sentence[:m.start()] + random.choice(typos[m.group()]) + sentence[m.end():]
    rows.append(("misspelled", sentence, typed)); used.add(sentence)
    if len(rows) == 300:
        break
swapped = [l.rstrip("\n").split("\t") for l in open(f"{lines_dir}/wrongword-test.txt", encoding="utf-8")]
random.shuffle(swapped)
for intended, left, typed, right in swapped[:300]:
    # The swapped word keeps the casing of the typed one.
    fixed = intended.capitalize() if typed[:1].isupper() else intended
    rows.append(("wrongword", left + fixed + right, left + typed + right))
rows += [("clean", s, s) for s in clean if s not in used][:400]
hard = """I drive a Toyota Corolla to work.	I drive a Tyoda Corola to work.
Schrodinger's equation describes the wave function.	Shrodinger's equasion describes the wave funtion.
We deployed the Kubernetes cluster on Tuesday.	We deployed the Kubernetis clustr on Tusday.
She studied at the Massachusetts Institute of Technology.	She studied at the Massachusets Institute of Technolgy.
Dostoevsky wrote Crime and Punishment.	Dostoyevski wrote Crime and Punishmant.
The mitochondria is the powerhouse of the cell.	The mitocondria is the powerhouse of the cell.
Nietzsche influenced modern philosophy.	Nietzche influenced modern philosphy.
The Pythagorean theorem applies to right triangles.	The Pythagorian theorum applies to right triangles.
The hippocampus is important for memory.	The hipocampus is important for memmory.
I need to refactor the asynchronous function.	I need to refactor the asyncronous funtion.
Tchaikovsky composed Swan Lake.	Tchaikovski composed Swan Lake.
The patient was prescribed acetaminophen and ibuprofen.	The patient was perscribed acetaminophin and ibuprofin.
Albuquerque is the largest city in New Mexico.	Albequerque is the largest city in New Mexico.
We flew from Reykjavik to Copenhagen.	We flew from Reykjavic to Copenhagan.
The Fibonacci sequence appears in nature.	The Fibonnaci sequense appears in nature.
Photosynthesis converts sunlight into chemical energy.	Photosynthasis converts sunlight into chemical energy.
I updated the PostgreSQL database schema.	I updated the Postgress database scema.
Machiavelli wrote The Prince.	Machiavelly wrote The Prince.
The Mediterranean diet is rich in olive oil.	The Mediteranean diet is rich in olive oil.
He has a degree in electrical engineering from Cornell.	He has a degree in electrical enginering from Cornel.
The algorithm uses dynamic programming and memoization.	The algorithim uses dynamic programing and memoization.
Fahrenheit and Celsius are temperature scales.	Farenheit and Celcius are temperature scales.
The Renaissance began in Florence.	The Renaisance began in Florance.
She has a rare autoimmune disease called lupus.	She has a rare autoimune disease called lupus.
The Mississippi River flows into the Gulf of Mexico.	The Missisippi River flows into the Gulf of Mexico.
Our startup uses TypeScript and GraphQL.	Our startup uses Typscript and GrapQL.
Shakespeare wrote Macbeth and Hamlet.	Shakespere wrote Macbeth and Hamlet.
The gradient descent optimizer converged quickly.	The gradiant decent optimizer converged quickly.
I parked the Nissan Altima in the garage.	I parked the Nisan Altima in the garage.
Kyrgyzstan borders Kazakhstan and Uzbekistan.	Kyrgyzstan borders Kazakstan and Uzbekistan.
My colleague Siobhan is presenting the quarterly results.	My colleague Siobhan is presenting the quarterly results.
Nguyen and Okafor reviewed the Kubernetes manifests.	Nguyen and Okafor reviewed the Kubernetes manifests.
Adeyemi flew to Lagos from JFK.	Adeyemi flew to Lagos from JFK.
The SOQL query uses a WHERE clause on AccountId.	The SOQL query uses a WHERE clause on AccountId.
Poughkeepsie is on the Hudson Line.	Poughkeepsie is on the Hudson Line.
Tauri apps pair Rust with SolidJS.	Tauri apps pair Rust with SolidJS.
Xiaomi and Huawei shipped more phones than Oppo.	Xiaomi and Huawei shipped more phones than Oppo.
The pharmacokinetics of rivaroxaban differ from warfarin.	The pharmacokinetics of rivaroxaban differ from warfarin.
Keratoconus is treated with corneal cross-linking.	Keratoconus is treated with corneal cross-linking.
Wojciech and Saoirse joined the Databricks team.	Wojciech and Saoirse joined the Databricks team."""
for line in hard.split("\n"):
    intended, typed = line.split("\t")
    rows.append(("hard-clean" if intended == typed else "hard", intended, typed))
with open(out, "w", encoding="utf-8") as f:
    f.writelines("\t".join(r) + "\n" for r in rows)
import collections
print(collections.Counter(r[0] for r in rows))

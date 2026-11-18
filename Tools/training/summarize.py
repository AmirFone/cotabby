#!/usr/bin/env python3
"""Reads a training export (Settings -> Writing -> Training Data -> Export) and says where Cotabby
was right and where it was not: the word strip, the fixes made without asking, and the sentence pass.

    python3 Tools/training/summarize.py ~/Downloads/cotabby-training-2026-11-18.jsonl [--examples 5]

It reads the `steps` each sentence carries (see "Training data" in FORK.md). An export written by
0.3.1 or earlier has no steps; the outcome counts are still printed for it. Nothing leaves the Mac.
"""
import argparse
import collections
import json


def share(part, whole):
    return f"{part} of {whole} ({100 * part / whole:.1f}%)" if whole else "none recorded"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("export")
    parser.add_argument("--examples", type=int, default=3, help="how many of each kind of miss to print")
    arguments = parser.parse_args()

    with open(arguments.export, encoding="utf-8") as file:
        examples = [json.loads(line) for line in file if line.strip()]
    sentences = [example for example in examples if example.get("scope") == "sentence"]
    steps = [step for example in examples for step in example.get("steps") or []]
    print(f"{len(sentences)} sentences, {len(examples) - len(sentences)} events without a sentence, {len(steps)} steps")
    if not steps:
        print("No steps: this export was written before 0.4.0, so only outcomes are known.")

    accepted = collections.Counter(change["how"] for example in examples for change in example["accepted"])
    rejected = collections.Counter(change["how"] for example in examples for change in example["rejected"])
    print("\nFixes kept:     ", dict(accepted))
    print("Fixes turned down:", dict(rejected))

    strips = [step for step in steps if step["kind"] == "strip"]
    typing = [step for step in strips if step.get("lettersTyped", 0) >= 1]
    picked = [step for step in strips if "pickedSlot" in step]
    print("\nWord strip")
    print("  word was first when you finished it:   ", share(sum(step.get("rank") == 0 for step in strips), len(strips)))
    print("  ... with at least one letter typed:    ", share(sum(step.get("rank") == 0 for step in typing), len(typing)))
    print("  word was anywhere in the strip:        ", share(sum("rank" in step for step in strips), len(strips)))
    print("  word was never listed:                 ", share(sum("rank" not in step for step in strips), len(strips)))
    print("  picked from the strip:                 ", share(len(picked), len(strips)))
    print("  first in the strip but typed out:      ",
          share(sum(step.get("rank") == 0 and "pickedSlot" not in step for step in strips), len(strips)))
    if picked:
        print("  picks by slot:", dict(sorted(collections.Counter(step["pickedSlot"] + 1 for step in picked).items())))
    missed = [step for step in typing if "rank" not in step and len(step["word"]) >= 5]
    for step in missed[:arguments.examples]:
        print(f"    not listed: {step['word']!r} after {step.get('lettersTyped')} letters, shown {step.get('shownLast')}")

    decisions = collections.Counter(step.get("how") for step in steps if step["kind"] == "decision")
    outcomes = collections.Counter(step.get("how") for step in steps if step["kind"] == "outcome")
    print("\nSpelling engine decisions:", dict(decisions))
    print("What became of them:      ", dict(outcomes))
    kept, undone = outcomes.get("autoFixKept", 0), outcomes.get("autoFixUndone", 0)
    print("  fixes made without asking that you kept:", share(kept, kept + undone))
    # A word the engine only offered a fix for, which you then took: sure enough to have been fixed?
    for example in examples:
        timeline = example.get("steps") or []
        for index, step in enumerate(timeline):
            later = [other for other in timeline[index + 1:] if other["kind"] == "outcome" and other.get("word") == step.get("word")]
            if step["kind"] == "decision" and step.get("how") == "fixed" and later and later[0].get("how") == "autoFixUndone":
                print(f"    undone: {step['word']!r} -> {step['candidates'][:1]} (confidence {step.get('confidence')})")

    changes = [change for step in steps if step["kind"] == "sentencePass" for change in step.get("changes") or []]
    actions = collections.Counter(change["action"] for change in changes)
    print("\nSentence model, per word it would change:", dict(actions))
    for action in ("fixed", "asked", "left"):
        values = sorted(change["probability"] for change in changes if change["action"] == action)
        if values:
            print(f"  {action}: median probability {values[len(values) // 2]:.2f}, lowest {values[0]:.2f}, highest {values[-1]:.2f}")
    fixes = collections.Counter(step.get("how") for step in steps if step["kind"] == "sentenceFix")
    print("  sentence fixes kept and undone:", dict(fixes))
    for change in [change for change in changes if change["action"] == "left"][:arguments.examples]:
        print(f"    left alone: {change['typed']!r} -> {change['written']!r} at {change['probability']:.2f}")


if __name__ == "__main__":
    main()

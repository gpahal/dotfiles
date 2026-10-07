# Verifier brief

Each verifier sub-agent gets this brief, the scope packet, the intent, the bar from the code-review skill, and one or more candidates. It reads the code, judges each candidate on its own, and returns one vote per candidate. It changes nothing.

## Votes

- **CONFIRMED**: you can name the inputs or state that trigger the defect and the wrong output, crash, or cost that follows. Quote the line.
- **PLAUSIBLE**: the mechanism is real, but the trigger depends on timing, environment, or config you can't settle from the code. State what would confirm it.
- **REFUTED**: the code doesn't do what the candidate says, the defect is impossible, or something already handles it. Quote the line that proves it.

PLAUSIBLE is the default for a realistic trigger. A candidate is not refuted for being "speculative" or for "depending on runtime state" when that state can occur: a race between concurrent callers, a null on a rare path that is still reachable (an error handler, a cold cache, a missing optional field), zero or an empty string treated as missing, an off-by-one at a boundary the code doesn't exclude, retries that pile up, partial failure, or a regex or allowlist that lost an anchor.

REFUTED needs proof from the code, one of these four:

- The candidate misreads the code. Quote the line that says otherwise.
- The defect can't happen. Show the type, constant, or invariant that prevents it.
- The change already handles it. Cite the guard.
- It's style with no observable effect.

A candidate that fails the bar also gets REFUTED: the change didn't introduce it, the author clearly meant it, or the author wouldn't fix it. Name which rule it fails.

## Output

One block per candidate, in the order received:

```
Candidate: <file:line, summary>
Vote: CONFIRMED | PLAUSIBLE | REFUTED
Proof: <the quoted line, and one or two sentences>
Priority: P0 | P1 | P2 | P3 (confirm or correct the finder's)
Confirm by: <PLAUSIBLE only: the test, input, or check that would settle it>
```

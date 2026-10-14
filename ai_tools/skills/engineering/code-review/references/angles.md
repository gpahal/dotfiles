# Finder angles

Each finder gets its angles below, pasted whole into its prompt. The angles fall into four groups. **Line** and **Flow** are the correctness angles (A to F) and hunt for bugs. **Design** hunts for code that works but costs too much, and **Conformance** for rules, docs, and tests the change left behind. A custom angle's whole brief is the user's `--focus` text. An angle reports only what it is assigned. Outside Line and Flow, a candidate's failure scenario states the concrete cost instead of a crash: what is duplicated, what work is wasted, what a reader will be misled into, or which regression would go unnoticed. Two angles flagging the same line for different reasons is expected, and each records its own candidate.

## Line

Bugs visible inside the changed functions.

### A: line-by-line scan

Read every hunk line by line, then read the whole function around each hunk. Bugs in the unchanged lines of a function the change touches are in scope, since the change re-exposes them or fails to fix them. For every line, ask what input, state, timing, or platform makes it wrong. Look for inverted or wrong conditions, off-by-one errors, null or undefined dereferences, a missing `await`, a zero or empty string treated as missing, a variable copied from the wrong place, an error swallowed in a `catch`, and unescaped regex characters.

### D: language pitfalls

Scan for the known traps of the change's languages and frameworks, such as JavaScript `==` coercion and loop variables captured by closures, Python mutable default arguments and late-binding closures, Go writes to a nil map and captured range variables, shell word splitting and unquoted variables, SQL built by string concatenation, time zone and DST drift, and float equality. Then the second tier: a dataclass default evaluated once, `hash()` that differs between runs, a lock held over less code than before, a predicate with side effects, test setup without matching teardown, and a config default that flipped.

## Flow

How values and contracts move between the change and the code around it.

### B: removed behavior

For every line the change deletes or replaces, name the invariant or behavior it enforced, then find where the new code enforces it. If nothing does, that's a candidate: a guard removed, an error path dropped, a validation narrowed, a test deleted that covered a real case. Moved or extracted code counts too: check that the new copy kept every guard and anchor.

### C: cross-file tracer

For each function, type, or config key the change modifies, find its callers and readers with a search for the symbol, and check each call site against the change: a new precondition, a changed return shape, a new error, a new ordering or timing dependency. Check the callees too: does another part of the same change make a call unsafe?

### E: wrappers and proxies

When the change adds or modifies a type that wraps another (a cache, proxy, decorator, or adapter), check that every method routes to the wrapped instance, not back through a registry, session, or global that re-enters the wrapper or recurses. Check that the wrapper forwards every method its callers use, with the same error and async behavior.

### F: security

Trace every input that crosses a trust boundary (request data, file contents, environment, model output) to where it's used. Flag input that reaches a dangerous sink (SQL, shell, `eval`, HTML, file paths, URLs fetched by the server) without validation or escaping, show the path from source to sink, and name the missing check. Also flag a new endpoint or action without an authorization check, a secret written to code, logs, or error messages, and a check whose result can change before the use it guards.

## Design

Code that works but costs too much.

### Reuse

Flag new code that re-implements something the codebase already has. Search the shared and utility modules and the files beside the change, and name the existing helper to call instead.

### Simplification

Flag complexity the change adds without need: state that could be derived, copies of one shape with small variations, deep nesting, a wrapper with one caller, a layer that only forwards, and dead code the change leaves behind. Name the simpler form that does the same job.

### Efficiency

Flag work the change wastes: repeated computation or I/O, independent operations run one after another, work added to startup or a hot path, and N+1 queries. Flag long-lived objects that capture a large enclosing scope, which keeps that scope in memory for the object's lifetime. Name the cheaper alternative.

### Altitude

Check that each change fixes the cause at the right depth. Special cases added to shared code are the sign of a fix at the wrong depth. Prefer the simpler, more general change to the underlying mechanism, and name it.

## Conformance

Whether the repo's rules, docs, and tests still hold after the change.

### Conventions

Read the rule files the lead found, and check the change against the rules they state. A rule file governs only the files at or below its directory, and the more specific file wins a conflict. Flag a violation only when you can quote the rule and the line that breaks it. Cite the rule file with its line range, as in `AGENTS.md:12-14`. Skip rules a linter, formatter, or type checker already enforces, and code where the rule is silenced on purpose, such as with a lint-ignore comment. With no rule file, report nothing.

### Docs and comments

For every behavior the change alters (a renamed flag, a new default, a changed return value, a removed option), find the text that describes it: comments and docstrings in and around the changed code, READMEs, docs pages, help text, examples, and changelogs. Flag text the change made wrong, even in a file the change didn't touch, and new comments that contradict the code they sit on. Quote the stale text and the line it contradicts. Flag missing docs for new behavior only when the repo documents comparable behavior.

### Tests

Flag changed behavior that no test exercises, when the repo tests comparable code. Flag a test the change makes pass for the wrong reason: it asserts on a mock, recomputes the expected value the way the code does, or has a loosened or skipped assertion. Flag a test the change deletes or weakens without a replacement. Name the case a test should cover.

## Gap sweep

The `xhigh` and `max` levels end with one fresh finder that gets the verified list and looks only for defects not on it. It re-reads the diff and the functions around each hunk, and focuses on what the first pass tends to miss: guards dropped by moved code, angle D's second tier, error paths that leave state half-written, and a test that passes for the wrong reason. At `xhigh` it reports up to 4 new candidates, correctness bugs only. At `max` it reports up to 8, of any kind. Either way, none is a valid answer.

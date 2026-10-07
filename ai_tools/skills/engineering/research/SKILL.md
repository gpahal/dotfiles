---
name: research
description: Investigates a question against primary sources and saves the cited findings as a Markdown file in the repo. Use only when the user explicitly asks for research.
---

Spin up a **background agent** to do the research, so you keep working while it reads.

Its job:

1. Investigate the question against **primary sources** (official docs, source code, specs, first-party APIs), not a secondary write-up of them. Follow every claim back to the source that owns it.
2. Stop when every part of the question has an answer backed by a primary source, or when the sources that would own an answer are checked and silent. Record that gap as an open question rather than filling it from secondary sources.
3. Save the findings at `.scratch/research/<research-slug>.md` in the repo, where `to-spec` and `to-tickets` will find them, in this shape:
   - `# <the question>`
   - `## Answer`: the short answer, in a few sentences.
   - `## Findings`: one bullet per claim, each linking the source that backs it.
   - `## Open questions`: what the sources didn't settle. Omit when empty.
4. Report the file path and the short answer.

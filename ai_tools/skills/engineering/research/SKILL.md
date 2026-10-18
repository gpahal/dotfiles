---
name: research
description: Investigates a question against primary sources and saves the cited findings as a Markdown file in the repo. Use only when the user explicitly asks for research.
---

Spin up a **background agent** to do the research, so you keep working while it reads. Its prompt carries the question and steps 1 to 3 below, since it sees neither this file nor the conversation. The agent returns the findings, and you write the file, since sub-agents are often told not to write report files. Without a sub-agent tool, do the research yourself in this session, by the same steps in order.

The steps:

1. Investigate the question against **primary sources** (official docs, source code, specs, first-party APIs), not a secondary write-up of them. Follow every claim back to the source that owns it.
2. Stop when every part of the question has an answer backed by a primary source, or when the sources that would own an answer are checked and silent. Record that gap as an open question rather than filling it from secondary sources.
3. Return the findings as Markdown, in this shape:
   - `# <the question>`
   - `## Answer`: the short answer, in a few sentences.
   - `## Findings`: one bullet per claim, each linking the source that backs it.
   - `## Open questions`: what the sources didn't settle. Omit when empty.
4. When the agent returns, save its findings at `.scratch/research/<research-slug>.md` in the repo, where `to-spec` will find them. Report the file path and the short answer.

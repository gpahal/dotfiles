---
name: handoff
description: Compacts the current conversation into a handoff document for another agent to pick up.
argument-hint: "[next-session focus]"
disable-model-invocation: true
---

Write a handoff document summarizing the current conversation so a fresh agent can continue the work. Save the file as markdown at `.scratch/handoffs/<conversation-slug>.md` at the repo root.

Include the goal, the current state, approaches tried and their results, open questions, and the next step.

Include a "suggested skills" section in the document, naming the skills the next agent should load.

Do not duplicate content already captured in other artifacts (specs and tickets under `.scratch/<feature-slug>/`, research under `.scratch/research/`, commits, diffs). Reference them by path or URL instead.

Redact any sensitive information, such as API keys, passwords, or personally identifiable information.

If the user passed arguments, treat them as a description of what the next session will focus on and tailor the doc accordingly.

Done when the file is saved and a fresh agent could start the next step from it without reading this conversation.

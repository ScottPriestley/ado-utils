---
name: handoff
description: 'Write a continuation handoff for a fresh thread. Use when asked for handoff notes, thread transfer, continuation context, or what the next assistant should do.'
argument-hint: 'What work should this handoff cover?'
user-invocable: true
disable-model-invocation: false
---

# Handoff

Create a concise but complete handoff for continuing work in a new thread where the next assistant has zero prior context.

## When To Use
- User asks for a handoff, transfer note, baton pass, or continuation summary.
- User wants a copy-paste block for a new chat or thread.
- Work has partial progress and must be resumed reliably.

## Required Output Contract
Produce exactly one copy-paste block and include these sections in this exact order:
1. Goal: one sentence for the objective.
2. State: what is done, in flight, and untouched.
3. Decisions: choices made and why.
4. Paths: full paths to every relevant file and folder.
5. Next actions: the first three actions, in order.
6. Traps: pitfalls, failed attempts, and gotchas.

## Writing Rules
- Assume the next thread is smart but knows nothing about prior conversation.
- Be specific and operational, not narrative.
- Prefer explicit nouns, file names, and commands over vague references.
- Do not include extra sections.
- Keep it directly actionable.

## Procedure
1. Identify the current objective from the latest user request.
2. Summarize progress across completed, active, and untouched work.
3. Record the key decisions and reasoning to prevent re-litigation.
4. Enumerate all relevant absolute paths.
5. Define exactly three immediate next steps.
6. Capture known traps from failed runs, dead ends, or environment quirks.
7. Emit one single fenced block that the user can paste into a new thread.

## Output Template
Use this structure verbatim:

```text
Goal: <one sentence>

State:
- Done: <items>
- In flight: <items>
- Untouched: <items>

Decisions:
- <decision + reasoning>

Paths:
- <full path>

Next actions:
1. <action one>
2. <action two>
3. <action three>

Traps:
- <pitfall>
```
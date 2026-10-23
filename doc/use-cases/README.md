# fs-meta use cases

The trio in [`../../FORMAT.md`](../../FORMAT.md) answers one question: *what does this tree contain, and is this
description the description the writer meant?* Everything a tool wants to do **with** that description is a
separate use case, with its own requirements, its own cache and its own optimisations.

This directory exists because those use cases must be written down **before** the format or the engine grows code
for them. A use case document states what a tool needs, what the trio already gives it, and which questions it
raises that only a format decision can answer. Several such questions, seen together, decide whether the format
changes — and a decision taken from one use case alone is how a format acquires columns that only one tool wants.

## One document per use case

Every document follows the same shape, so the questions can be compared across use cases:

| Section                     | What it must contain                                                                  |
| --------------------------- | ------------------------------------------------------------------------------------- |
| 1. The situation            | the tool, the tree, the cost of getting it wrong, and the frequency of a run          |
| 2. Questions to answer      | what the tool must be able to decide, phrased as questions                            |
| 3. The tool's own cache     | the state the tool has to keep; a key, its value, and why it is needed                |
| 4. What the trio gives      | which parts of § 3 the trio already carries — and what must **not** go into it        |
| 5. Skip rules               | a table of situation → may skip? → the reason, which is the heart of the optimisation |
| 6. Dependencies             | what a verdict depends on, how invalidation reaches it, and what is transitive        |
| 7. Optimisations            | numbered, each with its cost and the condition under which it is safe                 |
| 8. Questions for the format | anything that cannot be settled inside the tool, with the choice it forces            |
| 9. Acceptance tests         | the tests that would prove the use case, before any code is written                   |

A use case document is **not** a design for one tool. It is the requirements a tool of that kind has, written so
that the second and third tool of the same kind inherit them instead of rediscovering them.

## Index

| #   | Use case                                     | The cache it needs                                             | Status       |
| -   | --------                                     | ------------------                                             | ------       |
| 1   | [On-demand checks](./01-on-demand-checks.md) | per-file verdicts, with applicability, reason and dependencies | requirements |
| 2   | _not yet written_                            |                                                                |              |

## The distinction every document repeats

There are **two caches** in every one of these use cases, and confusing them is the mistake to avoid:

- **The tree cache** is the trio. One per tree, written by the engine, shared by every reader. It says what exists
  and how to recognise it: a name, a kind, a size, a modification time, an identity and sometimes a content hash.
- **The tool's cache** is private. One per tool (or per tool *and* mode), written by the tool, meaningful only to
  it. It says what *this tool* concluded and what that conclusion depended on.

A tool's conclusion must **not** be written into the trio: two tools would then rewrite one file, each generation
would carry another tool's churn, and the trio would stop being a description of the tree. The trio's job is to
make a tool's recheck cheap — the tool's own job is to remember its verdict.

## Cross-cutting questions

These are tracked here so that a use case does not silently decide them for everyone.

| Question                                                                 | Raised by | Needs a format change?            | Status |
| ------------------------------------------------------------------------ | --------- | --------------------------------- | ------ |
| Where does a tool's cache live?                                          | 1         | no — a convention beside the trio | open   |
| Is a cached verdict keyed by content hash or by `mtime`+`size`+`fileId`? | 1         | no — both are in the trio         | open   |
| Does a rename invalidate a verdict?                                      | 1         | no — `fileId` is the answer       | open   |
| Should the trio ever carry per-tool columns?                             | 1         | **probably yes for none**         | open   |
| Can the tool ask the engine for a hash it does not have?                 | 1         | no — the socket, § 16             | open   |
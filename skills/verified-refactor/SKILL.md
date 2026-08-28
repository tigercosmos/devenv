---
name: verified-refactor
description: Run a codebase-wide refactor or sweep as a provably-complete migration -- write a deterministic checker script first, establish a baseline count, apply fixes in batches, and loop the checker until it reports zero violations before committing. Use for any repetitive change across many files (renames, API migrations, style sweeps, mark insertions) where an LLM scan alone would miss sites.
---

# Verified Refactor

For a change that repeats across many files, an eyeball pass or an LLM scan
misses sites and reports "done" when it is not. This skill turns the sweep
into a measured migration: a deterministic script is the source of truth for
what remains, and the work is not finished until that script reports zero.

The rule that makes this work: **the checker, not the model, decides when
the refactor is complete.** Never declare the sweep done from a reading of
the diff.

## When to use

- Renaming a symbol, attribute, or file across the tree.
- Migrating every call site to a new API or signature.
- Applying a style or structural rule everywhere (e.g. adding C++ ending
  marks, converting `///` blocks to `/** */`).
- Any "fix all the X" request spanning more than a handful of files.

For a change confined to one or two files, just make it -- the ceremony
below is not worth it.

## Workflow

### 1. Define the violation precisely

State, in one sentence, what a single violation looks like and what a fixed
site looks like. Pin down the edge cases now (false positives you must not
flag, forms that are already correct). This definition is what the checker
encodes; vagueness here produces a checker that lies.

### 2. Write the deterministic checker first -- before any fix

Write a small script (Python or shell; whatever reads the code most
directly) that scans the tree and prints **every** violation as
`path:line -- <what is wrong>`, then a trailing total count. Requirements:

- **Deterministic.** No LLM calls, no heuristics that vary run to run. Same
  tree in, same report out.
- **Exact locations.** `file:line` for each hit, so a fix can be aimed and
  re-checked.
- **Countable.** End with a single machine-readable total (e.g.
  `VIOLATIONS: 42`) so the loop can branch on it.
- **Scoped.** Restrict to the relevant paths; exclude generated, vendored,
  and reference-only trees, and print what you exclude.

Put the script in the session scratchpad, not the repo, unless the user
wants it kept. Keep it in view -- the user should be able to read exactly
what "violation" means.

### 3. Validate the checker against known cases

Before trusting the count, confirm the checker is honest:

- Point it at a site you know is broken -- it must flag it.
- Point it at a site you know is already correct -- it must not.
- Eyeball a few reported hits and a few unreported lines.

A checker that miscounts is worse than none: it manufactures false
confidence. Fix the checker until its report matches reality on the spot
checks.

### 4. Establish the baseline

Run the checker on the clean tree and record the total. This number is the
scoreboard; report it to the user (e.g. "baseline: 42 violations across 17
files").

### 5. Apply fixes in batches, re-check after each

Work in reviewable batches (by directory, by file, or by violation
sub-kind), not one giant edit. After each batch:

1. Re-run the checker.
2. Confirm the count dropped by the number you fixed -- no more, no less. A
   count that moved the wrong way means a fix introduced a new violation or
   the checker is catching something you did not intend; investigate before
   continuing.

Loop until the checker reports **zero**.

### 6. Guard against a checker that is too lenient

Zero from a weak checker is a false finish. Before accepting zero, sanity
check that the checker still fires: temporarily reintroduce one violation
(or run against the pre-refactor commit) and confirm the count goes up. Then
discard that probe. Only a checker that can still detect a violation is
allowed to certify zero.

### 7. Verify behavior and style

Reaching zero means the pattern is gone; it does not mean the code still
works. Then:

- The project's lint command (or the touched-language subset) -- clean.
- The tests for the touched area -- run them and read the result.
- For style judgment calls introduced by the sweep, invoke the project's
  style-review skill for that language on the diff, when it has one.

### 8. Commit and hand off

Delegate to the project's commit skill when it has one; otherwise commit
with a message written per the `write` skill. Do not open a PR (or hand the branch to
`pr-pipeline`) until the checker reports zero **and** lint and tests pass.

## Output

- The checker script (or its path), so the user can read the violation
  definition.
- The scoreboard: `baseline: N` then the descent to `0`, with the
  per-batch counts.
- The verification evidence: lint clean, tests run and their result.
- If the count cannot reach zero (some sites need a judgment call the
  checker cannot make), stop with `remaining: <count>` and list those sites
  for the user. Never report a partial sweep as complete.

<!-- vim: set ff=unix fenc=utf8 et sw=4 ts=4 sts=4 tw=79: -->

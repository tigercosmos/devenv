---
name: pr-pipeline
description: Run the full ship pipeline on the current branch of any project -- discover the project's conventions, rebase onto upstream, run style, prose (`write`), and codex/claude reviews in parallel, apply approved fixes, verify with the project's lint, tests, and every CI gate, squash, and open (or update) a draft PR whose body passed the `write` check, splitting into stacked PRs when the diff exceeds the size limit (default 700 LOC). Use when the user asks to "ship", "run the PR pipeline", or "review, fix, and open a PR" for a branch.
---

# PR Pipeline

One orchestrated pass from a working branch to a reviewable draft PR. This
skill is a conductor: each stage delegates to the most specific skill that
exists, and falls back to a generic step when the project has none.

Two kinds of skill take part:

- **Always available** (installed by devenv): `write` for prose and PR
  bodies, `codexmon` for the external reviewer. Claude Code also ships
  `simplify`; under another agent, fold that pass into the review below.
- **Project skills, when present**: a commit skill (`commit-code` or
  similar), per-language style-review skills (`cpp-style-review`,
  `python-style-review`, ...), and a PR-creation skill (`create-pr` or
  similar). Look for them in `.claude/skills/` and `.agents/skills/` of the
  repository, and in the skill list of the session. Invoke them and follow
  their output; do not re-implement their rules here.

The repository's own conventions are canonical: `CLAUDE.md`,
`CONTRIBUTING.md`, `STYLE.md`, a PR template, the CI workflows. Where this
skill and a repository rule disagree, the repository wins.

Stop and hand back to the user only for a genuine judgment call or a
destructive step. Do not stop just because a stage is long. Do not declare
the pipeline blocked before exhausting the fallbacks named below.

## Stage 0 -- Locate the work, learn the project, confirm scope

1. **Confirm the working directory.** If a worktree was designated for this
   branch, `cd` into it and confirm with `git rev-parse --show-toplevel`
   before editing or running anything. Never edit the main checkout when a
   worktree exists for the branch. If unsure which tree is intended, ask.
2. **Discover the project conventions** (run in parallel) and record them
   as `<upstream>`, `<main>`, `<lint>`, `<test>`, `<limit>` for the later
   stages:
   - Upstream remote and default branch. `git remote -v` and
     `gh repo view --json parent,defaultBranchRef` tell whether the
     checkout is a fork; the PR target is the parent repository's default
     branch, not the fork's. Fall back to
     `git symbolic-ref refs/remotes/origin/HEAD` when `gh` is unavailable.
   - Lint and test commands: read `CLAUDE.md`, `CONTRIBUTING.md`, the
     `Makefile`, `package.json`, `pyproject.toml`, `Cargo.toml`, or the
     equivalent. Prefer the commands the docs name over guesses.
   - CI gates: read `.github/workflows/*` (or the equivalent) and list
     every check that runs on a pull request. A gate CI runs separately
     from the lint target is still a required gate.
   - Available project skills (see the list above).
   - The PR size limit: `<limit>` is 700 changed lines unless `CLAUDE.md`,
     `CONTRIBUTING.md`, or the user names another.
3. **Read the branch state** (run in parallel):
   - `git status --porcelain`
   - `git log --oneline <upstream>/<main>..HEAD`
   - `git diff --stat <upstream>/<main>...HEAD`
   - `git rev-parse --abbrev-ref --symbolic-full-name @{u}` (does it track a
     remote?)
4. **Gather scope in one question** if not already known: the related issue
   number, and whether the diff is expected to exceed `<limit>`. Do not ask
   whether to open as draft -- the pipeline always opens draft.

If the working tree is dirty, surface staged / unstaged / untracked
separately and ask how to proceed. Never `git add -A`.

## Stage 1 -- Rebase onto upstream

1. `git fetch <upstream> <main>`.
2. `git rebase <upstream>/<main>`.
3. **Resolve conflicts** yourself where the resolution is mechanical
   (imports, adjacent hunks, generated sections). For a conflict that needs
   a real decision, present the two sides and ask.
4. After the rebase, prove the tree is intact: if the branch was previously
   pushed, `git diff <old-tip> HEAD` should show only the intended delta,
   not accidental reverts. Report anything surprising.

## Stage 2 -- Review (parallel)

Run the reviewers concurrently, not one after another.

1. **Style review**, scoped to the diff:
   - Invoke each project style-review skill whose language the diff
     touches.
   - If the project has none for a touched language, run the formatter and
     linter the project configures (`.clang-format`, `ruff`/`black`,
     `eslint`/`prettier`, `rustfmt`/`clippy`, ...) over the changed files
     and treat their reports as findings.
2. **External reviewer** via `codexmon`, launched detached so it never
   blocks:
   ```sh
   ID=$(codexmon review --agent codex --base <upstream>/<main> -b | head -1 | awk '{print $1}')
   codexmon wait "$ID" --timeout 600 --json
   ```
   **Fallback, do not stall:** if the run ends `stalled`/`timeout` (a wedged
   MCP tool -- `error` names it), retry MCP-free
   (`codexmon start -- exec review --base <upstream>/<main> --ignore-user-config`),
   or switch to the claude reviewer (`--agent claude`). Only report the
   external review as unavailable after both fallbacks fail.
3. **Comment audit.** Read every comment and docstring the diff adds or
   changes (`git diff <upstream>/<main>...HEAD`) and judge each one against
   the project's comment policy when it has one (a "Comments" section of
   `STYLE.md` or `CLAUDE.md`). When the project has no policy, apply the
   default below: no comment unless it carries what the code cannot, and a
   few load-bearing comments over many thin ones. Flag, and by default
   delete, any comment that:
   - Restates the line below it (`// increment the counter` over
     `++count;`), narrates a call (`// run the solver`), labels obvious
     structure (`// constructor`, `// the main loop`, `# imports`), or
     repeats a name that is already clear.
   - Explains an obvious value or type, e.g. that an empty
     `std::optional` is null.
   - Describes the task or review conversation rather than the code ("as
     requested", "per review comment", "new in this PR"), or documents a
     changed behavior as a diff against the old code.
   - Rambles where one sentence would do, or pads an interface comment with
     detail the reader can see in the signature.

   Flag as a fix, not a deletion, a comment that is load-bearing but
   malformed: missing units, coordinate convention, index base, array shape
   or contiguity; a formula with no literature or equation citation (with
   URL); a wrong marker for the language's doc tool (Doxygen, docstring,
   JSDoc, rustdoc); a docstring summary that is not one prescriptive
   sentence ending in a period; a breach of the project's character-set or
   line-width rule; or a comment gone stale against the code it sits on.
   Prefer renaming over annotating when an unclear name is the real
   problem.

   The audit covers only comments the diff touches -- do not sweep the
   whole file. Report the count kept, rewritten, and deleted.
4. **Prose review** via the `write` skill. The comment audit decides
   whether a comment survives; this step checks the wording and structure
   of every piece of prose that survives. Invoke `write` in review mode
   over:
   - Documentation the diff adds or changes: files under the project's
     documentation directory (`doc/`, `docs/`, ...), `README.md`, and any
     other `.md` / `.rst`, and the docstrings the diff touches. For a doc
     page, first name its Diataxis type (tutorial, how-to, reference,
     explanation) and flag a page that mixes types; for an explanation
     page or design doc, apply the "Explaining a mechanism" checks.
   - Every comment and docstring the diff adds or changes, after the
     comment audit has pruned them: apply the Pass 2 sentence rules
     (active voice, imperative instructions, simple tenses, one term per
     thing, sentence and paragraph limits, adjacent pronoun referents).
   - Every claim in that prose against the code it describes; the `write`
     workflow reads the source and does not trust the text.

   Scope is the diff (`git diff <upstream>/<main>...HEAD`), not the whole
   file or repository. Run the mechanical checks the `write` skill names
   with a script, not by eye. Repository conventions (character set, line
   width, the comment policy) override the skill where they disagree; the
   skill governs wording, not formatting. Report each finding as
   `file:line -- rule -- rewrite` so it merges with the other reviewers'
   findings.
5. Run `/simplify` for all changes, especially for any new or changed
   docstring or comment. Under an agent without `simplify`, review the
   diff for reuse, simplification, and efficiency yourself.
6. **Merge and dedupe** all findings into one list keyed by `file:line`.

## Stage 3 -- Apply fixes

1. Apply the **non-controversial** findings directly (clear style, naming,
   obvious correctness, the comment deletions and rewrites from the Stage 2
   audit, and the wording rewrites from the Stage 2 prose review that keep
   the author's facts and intent).
2. Collect **judgment calls** (design trade-offs, anything that changes
   behavior or public API) into a short list and present them for the user
   to decide. Do not silently apply these.
3. Re-run the relevant style review on the touched lines to confirm the
   fixes are clean.

## Stage 4 -- Verify against ground truth

Do not report a stage as passing on assumption. Run it and read the output.

1. `<lint>` (or the touched-language subset). Fix every report; re-run
   until clean.
2. **Every CI gate from Stage 0, over the same inputs CI uses.** A branch
   can be green on the local lint and test targets and still fail CI on a
   check that CI runs separately: a static analyzer on the changed lines
   (clang-tidy, mypy, pyright), a doc build, a license or spelling check,
   a formatter in `--check` mode. Treat each as a required gate, not an
   optional extra, and run it the way the workflow does (same flags, same
   scope, same warnings-as-errors setting).

   Two failure modes make a clean run untrustworthy, so guard against both:
   - A tool that cannot find its inputs reports nothing. On macOS, a
     clang-tidy run without an explicit `-isysroot` dies on
     `'assert.h' file not found` for every file, which `grep`ing for
     `warning:` reports as clean; a missing `compile_commands.json` or an
     unbuilt package analyzes nothing at all.
   - A tool scoped to the wrong lines reports nothing. A diff-scoped check
     (`clang-tidy-diff`, `ruff --diff`, ...) needs the same base as CI.

   **Prove the harness works before trusting a clean result.** Re-introduce
   a known violation (or revert the fix you just made), confirm the check
   fires, then restore. A silent run and a passing run look identical
   otherwise.
3. `<test>` for the touched area, per language (the project's `pytest`,
   `gtest`, `cargo test`, `npm test`, ... target), or the affected subset
   when the full suite is slow and the project documents how to select it.
4. If a build or test is genuinely unavailable in this environment, say so
   explicitly and name what could not be run -- do not imply it passed.

## Stage 5 -- Squash

Delegate to the project's commit skill when it has one; otherwise write
the message with the "Commit message" genre of `write` and the
repository's commit conventions. Recreate the history as one-concern
commits (usually a single squashed commit for a focused branch), then
confirm the squashed tree is byte-identical to the pre-squash tip:
`git diff <old-tip> HEAD` must be empty. Push with `--force-with-lease`,
never a bare `--force`, and only after the user has seen the plan.

## Stage 6 -- Split when oversized

Measure the diff: `git diff --stat <upstream>/<main>...HEAD` and sum the
changed lines (added + removed of substantive source; exclude generated or
vendored files, and say so if you exclude anything).

- **<= `<limit>`:** one PR. Skip to Stage 7.
- **> `<limit>`:** split into **stacked** branches, each under `<limit>`,
  each branching off the previous so every PR's diff is only its own
  slice. Verify each branch's own diff is under the limit *before*
  creating any draft: `git diff --stat <prev-branch>...<this-branch>`. If
  a proposed split still exceeds `<limit>` on any branch, re-split -- do
  not open it. Present the proposed split (branch names, LOC each,
  dependency order) for approval before pushing.

If you must cap or approximate the LOC accounting, `log()` what you
excluded -- never let a silent exclusion make an oversized PR look
compliant.

## Stage 7 -- Open (or update) the draft PR

Delegate to the project's PR-creation skill for each PR in the stack when
it has one; otherwise use `gh pr create --draft --base <base>` (or
`gh pr edit` for an existing PR), where `<base>` is `<main>` for a single
PR or the first of a stack and the preceding branch for every later PR in
the stack, filling the repository's PR template
when `.github/PULL_REQUEST_TEMPLATE.md` exists. Before the `gh` call, pass
the draft title and body through the `write` skill as a "Pull request
description" (its genre template: what the change does, why with the
issue reference, how only when the diff does not show it, what you tested
and the actual result), and apply its Pass 2 sentence rules. Keep the
`write` result within the project's PR rules; where they disagree, the
project's skill, template, or `CLAUDE.md` wins. Post only the checked
text.

Rules that past sessions got wrong, in any project:

- **Concise, diff-accurate body.** Default to a one-sentence summary unless
  the user asks for more. Every claim in the title and body must be
  verifiable against the actual diff -- do not describe upstream behavior
  that already existed, and do not invent numbers or results. The `write`
  check reads the diff to confirm each claim; it does not add sections
  the template lists but the PR does not need.
- **Link the issue the way the project does.** Use the project's form
  when it prescribes one ("Related to #<n>", "Closes #<n>", "Fixes
  <tracker-id>"). When it prescribes nothing, use a closing keyword only
  when the PR fully resolves the issue; otherwise "Related to #<n>".
- **Never overwrite an existing PR title prefix.** When editing an existing
  PR (e.g. one titled `Shortcut System 1: ...`), preserve the prefix; on
  `gh pr edit`, read the current title first and keep it unless the user
  asked to change it.
- **Draft by default.** Open draft; marking the PR ready for review and
  requesting reviewers are the user's actions unless the user says
  otherwise.
- For a stack, note the dependency order in each PR body ("stacked on
  #<n>") so reviewers read them in sequence.

## Output

- A short running note per stage (conventions found / rebased / reviewed /
  comments audited / prose checked / fixed / verified / squashed / split /
  PR body checked / opened).
- The judgment-call list from Stage 3, if any, for the user to decide.
- A final block: the PR stack as `opened: <URL> (draft)` lines, plus the
  verification evidence (lint clean, every CI gate run and its result,
  tests run and their result). Report this evidence to the user here; keep
  it out of the PR body unless the project's PR rules ask for it.
- If a guardrail stops the pipeline (dirty tree, empty branch, oversized
  split that will not shrink, failed verification), output
  `blocked: <reason>` and stop. Do not retry silently or paper over it.

**MAKE SURE THE AGENT DOES ALL THE PIPELINE STAGES.**

<!-- vim: set ff=unix fenc=utf8 et sw=4 ts=4 sts=4 tw=79: -->

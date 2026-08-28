---
name: write
description: Write or revise any technical text (documentation, README sections, guides, reference pages, GitHub issues, pull request descriptions, commit messages, design docs, announcements) using the Diataxis framework (https://diataxis.fr/) for documentation structure, genre templates for everything else, and ASD-STE100 Simplified Technical English (https://www.asd-ste100.org/) for sentence-level style. Use when the user asks to write, draft, or rewrite any prose for humans.
---

# Technical Writing: Diataxis + Simplified Technical English

Two passes: decide what kind of document this is and structure it
accordingly (Pass 1), then write every sentence in Simplified Technical
English (Pass 2). Pass 2 applies to ALL genres.

## Pass 1: structure by genre

Decide first: documentation (lives in the docs, read repeatedly)
follows Diataxis; a working document (issue, PR, commit message,
design doc, announcement, written once for one audience and moment)
follows the genre templates below.

### Documentation: Diataxis -- pick ONE document type

Every piece of documentation serves exactly one of four needs. Identify
it before writing a word. If the source material mixes types, split it.

| Type | Reader's need | Orientation | Form |
|---|---|---|---|
| Tutorial | "Teach me" (learning) | Practical steps, guided by you | A lesson: the reader does something and it works |
| How-to guide | "Help me do X" (a goal) | Practical steps, guided by their goal | A recipe: numbered steps to one real-world result |
| Reference | "Tell me the facts" | Theoretical knowledge | Neutral description: austere, complete, structured like the machinery it describes |
| Explanation | "Help me understand" | Theoretical knowledge | Discussion: context, background, why it is this way |

Rules that follow from the type:

- **Tutorial**: you are the teacher. Give one reliable path; no
  options, no branches, no "you could also". Every step must produce a
  visible result the learner can confirm. Do not explain concepts in
  depth; link to explanation instead.
- **How-to guide**: assume competence. Start from a named goal, not
  from zero. Omit teaching and background. Address real-world
  complexity, but stay on the path to the goal.
- **Reference**: describe, do not instruct. No opinions, no tutorials
  in disguise. Keep one format across entries, so the reader can
  predict where a fact lives. Completeness and accuracy over
  readability flourishes. Examples illustrate; they do not guide.
- **Explanation**: the only place for "why". Discuss design decisions,
  history, alternatives, constraints, and connections. No step-by-step
  instructions. When a mechanism imposes a constraint on the reader,
  one imperative sentence may state it ("Carry the macro on every
  wrapper."); a numbered procedure may not. See "Explaining a
  mechanism" below.

Cross-link between types instead of blending them: a how-to step that
needs a concept links to the explanation; a tutorial that needs a fact
links to the reference.

### Explaining a mechanism (explanation pages, design docs)

Model text: `doc/source/devguide/binding.md` in the solvcon
repository (https://github.com/solvcon/solvcon), written by the
maintainer. When that file is in the checkout, read it before drafting
an explanation page or a long design doc. Otherwise apply the method it
exemplifies, which the list below states in full:

1. **Motivate before mechanism.** Open with the problem and the main
   requirements the design answers, in one to three paragraphs, before
   any API name or code. Make each later section's relation to them
   clear before the reader reads it.
2. **Order from the central abstraction outward.** Purpose and the
   central abstraction the reader works against first, then the
   mechanisms that depend on it, then examples, then repository
   conventions. Follow source-tree order only when it helps the reader.
3. **Introduce, show, then explain only what the code cannot say.**
   Name the mechanism in a sentence, quote a trimmed excerpt when code
   exists and helps (elide long parts with `// ...`), then write its
   non-obvious behavior, the reason for its shape, and what follows.
   If a paragraph restates the excerpt, delete the paragraph.
4. **Follow a causal chain: claim, mechanism, consequence.** When the
   mechanism imposes a constraint on the reader, state it as one
   imperative. When a verified failure mode explains it, name it
   concretely ("Omit it and the build fails at the `commit()` call
   site with an access error."); do not invent one.
5. **State costs, guarantees, and boundary conditions where they
   matter.** Say what a guarantee costs (import time versus runtime),
   what makes it hold (the GIL, a static local), and where it stops
   holding (an unsupported overload, a toggle from another thread).
6. **Tables for enumerable facts, prose for causality.** Parameters,
   file kinds, and options go in a table; nearby prose adds relations,
   constraints, and implications, and does not paraphrase every cell.
7. **State scope and status out loud.** Distinguish design intent, an
   imposed limitation ("and not by choice"), a convention rather than
   a rule, and current implementation status ("No wrapper overrides
   the default today.").
8. **Link out instead of re-explaining.** A known concept (CRTP, a
   preprocessor operator, a protocol) gets a link to its canonical
   source. Make sure that each link resolves; if the doc system needs
   wiring (an inventory, an anchor), add it in the same change.
9. **Give a file path when it helps the reader locate the
   implementation**, so the page doubles as a map.
10. **Avoid accidental repetition.** No recap or summary section.
    Repeat a fact only when the new context adds meaning or helps
    navigation.

### Working documents: genre templates

Not Diataxis types, but the same principle holds: know what the reader
needs, put it first, and do not mix jobs in one text.

**GitHub issue (bug report)**

1. One-sentence summary of the defect (title restates it).
2. Steps to reproduce, numbered, each an imperative.
3. Expected behavior and actual behavior, as two labeled parts.
4. Environment or version facts that matter.
5. Optional: suspected cause or pointers into the code.

Report facts; do not prescribe the fix unless you know it, and then
put it in its own final section.

**GitHub issue (feature / task)**

1. The need: what is missing or wrong today, and for whom.
2. The proposal: what to build or change, in concrete terms.
3. Scope boundary: what is explicitly out of scope, if useful.
4. Acceptance: how a reviewer knows the issue is done.

**Pull request description**

1. What the change does, in one or two sentences, present tense.
2. Why: the problem or issue it addresses. Reference the issue.
3. How, only when the diff does not make it obvious: the approach,
   the alternative you rejected, the constraint that shaped it.
4. What you tested and the actual result.

Describe only what the diff contains; do not pad with file lists the
diff already shows.

**Commit message**

- Subject: imperative, concrete, under about 50 characters, no period.
- Body: why the change exists and what it does at the level the diff
  cannot show. Wrap per repository convention.

**Design doc / plan**

1. Problem and goal first, one paragraph each.
2. Constraints and non-goals before the design, so the reader judges
   the design against them.
3. The design, top-down: shape first, then parts, then details.
4. Alternatives considered, each with the reason it lost.
5. Open questions, clearly marked as open.

**Announcement / release note**

1. What changed, from the reader's point of view (what they can do
   now, or must do now), before any internal detail.
2. Action required, if any, as imperatives, before background.
3. Background last.

For a genre not listed: identify the single job the text does for its
reader, lead with the outcome or need, order sections by reader
priority, and keep one job per section. Then apply Pass 2 as always.

## Pass 2: ASD-STE100 -- sentence-level rules

Apply these to every sentence, so that a non-native reader parses each
sentence exactly one way.

### Sentence and paragraph limits

- Procedural (instruction) sentences: maximum 20 words.
- Descriptive sentences: maximum 25 words.
- One instruction per sentence. One topic per paragraph.
- Paragraphs: maximum 6 sentences; neither a wall of text nor a run of
  one-sentence paragraphs.
- Use vertical lists to break up strings of related items or steps.

### Verbs

- Active voice: "The pump moves the fluid", not "the fluid is moved by
  the pump". Passive only when the agent is unknown or irrelevant, and
  rarely.
- Instructions as imperatives: "Remove the cover." Not "The cover
  should be removed" or "Removing the cover...".
- Simple tenses only: present, past, future. No perfect tenses ("has
  completed"), no progressive/gerund forms as verbs ("is running").
- Do not use "should", "might", "could" for requirements. Use "must"
  for a requirement, imperative for an instruction, "can" for
  capability.

### Words

- One word, one meaning; one meaning, one word. Pick one term for each
  thing and use it everywhere; never rotate synonyms for elegance
  ("start" / "launch" / "boot" / "spin up" -- choose one).
- Short, common words: "use" not "utilize", "start" not "initiate",
  "make sure" not "ensure/verify" (pick one and stick to it), "help"
  not "facilitate".
- A simple verb, not a phrasal-verb idiom: "remove" not "get rid of",
  "continue" not "carry on".
- No noun clusters longer than 3 nouns ("main gear door retraction
  winch handle" -- restructure with "of"/"for").
- Define or expand every abbreviation at first use.
- No vague quantifiers ("some", "several", "as required") when a
  number or condition is known.

### Voice

- Use the product or component name for behavior ("solvcon uses
  ..."). Use "we" for a design decision and its reason ("We use the
  class attribute so that ...") only when the project voice permits
  it. Use the bare imperative for an instruction or a constraint the
  reader must follow.
- Prefer a verb that names the observable effect ("closes the
  interval", "returns the pybind11 type and ends the chain") to a
  vague one ("handles", "manages", "deals with"). Keep to plain words;
  no metaphors.
- Keep two to four brief, closely related items inline as "(1) ...,
  (2) ..." only when the sentence stays within its length limit;
  otherwise use a vertical list.

### Structure and clarity

- Do not omit words that resolve ambiguity: keep articles ("the",
  "a"), keep "that" after verbs like "make sure that", and repeat the
  noun instead of a distant pronoun ("it", "this", "these" must have
  an obvious, adjacent referent).
- Condition before instruction: "If the test fails, open the log",
  not "Open the log if the test fails".
- Warnings and cautions come before the step they protect, as a
  separate sentence, starting with the hazard.
- Parallel structure in lists: every item starts with the same part of
  speech (all imperatives, or all nouns).
- Write a heading so that it reads correctly away from the text under
  it: name the subject and the outcome. Do not end a heading with a
  verb that takes an object ("X loses", "Y fails"); the reader waits
  for an object that never comes.

## Workflow when invoked

1. Identify the genre: a Diataxis type, or a working-document genre
   (issue, PR, commit, design doc, announcement). Infer it from
   context; ask only when genuinely ambiguous. State your choice in
   one line.
2. Draft or rewrite the text obeying the Pass 1 structure for that
   genre and the Pass 2 sentence rules.
3. Check every claim about the code against the code. A statement
   about an algorithm, a complexity, a type, or an error message is a
   fact the source confirms or refutes. Read the source; do not trust
   the text you are rewriting.
4. Check the mechanical rules with a script, not by eye: sentence
   length, paragraph length, passive voice, perfect tense, line width,
   and term consistency. Run it again after every edit, not once
   before you present. An edit inside a wrapped paragraph can push a
   sentence over the limit, so re-wrap and re-measure the whole
   paragraph that you touch.
5. Judge the rest by reading:
   - No mixed document types or mixed jobs in one section.
   - Every heading states its point without the text under it.
   - Every pronoun has an adjacent referent.
   - The first sentence answers the reader's first question.
   - For an explanation page or an implementation-centered design
     doc: apply the checks under "Explaining a mechanism".
6. When rewriting existing text, preserve the author's facts and
   intent; change structure and wording only. Flag any factual gap
   instead of inventing content.

## Project overrides

Repository conventions (line width, ASCII-only, no hard-wrap rules for
GitHub prose, comment policy) take precedence over anything here. This
skill governs wording and structure, not file formatting.

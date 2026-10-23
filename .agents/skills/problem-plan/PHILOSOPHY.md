# problem-plan — design philosophy

Why the skill is shaped the way it is. This is for the people and sessions
that change `SKILL.md`, not for the agent running it: nothing here is loaded
at invocation, and nothing here should be needed to run the skill. Read it
before touching any phase the user sees, and update it when a trial changes
what we believe. The skill was prototyped and trialled on four records of
different shapes in one consumer repository before Workshop took it in; the
trials named below are those.

## The user's attention is the product

The skill turns a filed problem into a decision the user owns. The agent does
the work; the user makes the judgment calls. Everything the skill shows the
user exists to put the right things into their head, in the right order, at
the moment they are needed, and nothing else.

That is the constraint every change is tested against. The project is large
and the user does not hold its technical detail in their own context; they
filed the problem once and have moved on. Each user-facing phase targets a
mental state:

- after the card: *I know what is wrong and what the ways out are*;
- after each question: *I could argue for any option, and I have chosen*;
- after the report: *I know what was written, where, and what is left*.

Before any sentence goes in front of the user, ask whether the reader needs
it to reach the next state. If not, it belongs in the Report, in the task,
or nowhere. Trial 2 showed what happens otherwise: a card that also carried
gate results, sizing, rejected candidates, the forks ahead, implementation
choices, record repairs, incidental findings, and a glossary. Every one of
those was true and useful to the agent, and every one pulled the reader off
the problem. The corollaries:

- **No glossary.** A term is explained in the sentence that first needs it,
  in the question where it matters. A dictionary before the decision is a
  detour.
- **No bookkeeping in the reading path.** Gate verdicts, sizing, record
  repairs, and what was searched are the agent's accounts. They go in the
  status line, which the eye skips, and in the Report.
- **Rejected candidates stay in the agent's hand.** The user is not asked to
  read why four approaches lost. If they propose one, the agent pushes back
  with the reason; the task's Decisions carry it for the next session.
- **Incidental findings wait.** Things found outside the record are real and
  must not be lost, but they are out of context until the decision is made
  and committed. They are the last thing in the run, with a capture offer.
- **Self-contained candidates.** A candidate's text assumes only the problem
  statement and the answers so far. "The suggestion-list pattern" means
  nothing to a reader who has not been told what it is; the sentence that
  names a precedent explains it.

## Trust without reading

The user must be able to trust the work without re-reading the evidence.
Early drafts put an epistemic-status paragraph in every question, listing
what had been verified against code. It built trust and blocked the path.
The resolution is to put the evidence where it is durable, in the task's
`## Context`, and leave in the question one line headed **Basis** that names
only what is *not* verified. "Everything verified" is the default; the
exceptions are what the user needs to weigh.

## Diverge here, converge later

The skill widens the candidate set and then narrows it with the user. It
does not red-team the chosen approach: `task-finalize` does that later, with
its refutation, blast-radius, and cold-read passes, on a brief that carries
the decision. Refuting during divergence would collapse the set before the
user saw it. The lenses therefore reject nothing; adjudication is where
candidates die, and adjudication happens before the user sees anything.

The same division runs across the problem lifecycle. `problem-status` says
whether the flaw still stands; this skill decides what to do about it;
`task-finalize` designs the fix; `kaizen-resolve` retires the record once
the flaw is verified gone. A record never gains a solution section, because
a record describes the present and a solution describes the future; the
chosen fix lives in the task that cites the record. The only mark the skill
leaves on a record is one Disposition line, for a flaw the user decided to
live with, so that a later sweep can tell decided-and-living-with-it from
never-looked-at.

## Evidence before opinion

Gates run before anyone thinks about a fix: a record already decided, already
planned, likely fixed, or drifted is routed, not planned. The record is
re-verified at HEAD because records age; trial 2's record was two days old
and still needed five corrections. The read at HEAD, not the record's own
list of options, is the candidate source: in trial 1 the deciding fact (the
handler already accepted the key the hint should name) was in the code and
not in the record.

Lens prompts are self-contained, carry no candidate from the conversation,
and are bound by two clauses: every finding cites file and line, and no
findings is a success. Raw lens output never reaches the user. Each survivor
is sorted into exactly one of candidate, wrinkle, record defect, incidental
defect, or discard, and each sort has a destination: the card, the task's
Recommended solution, the record in Phase 7, the Report's found-along-the-way
item, or nothing.

## The decision record is the Recording line

Each question ends with one line, **Recording:**, that states the decision
and the reasons the alternatives lost. Phase 7 copies it verbatim into the
task's `## Decisions`. A session weeks later, without this conversation,
reads the decision itself, never "as recommended". The line is long when the
decision was large; that is the rule working, not a defect.

## Ceremony proportional to the problem

A small problem, one construct on one surface, skips the fan-out and folds
the bucket into question 1; its minimum path is the card, one question, and
the commit. A structural problem runs four lenses and two or three questions.
The sizing is stated and the user may override it either way. The skill
never spends a turn on a question whose answer does not change what is
filed.

## Write little, by path, and never push

The skill writes the task files, at most one line or a few repaired
sentences on the record, and the handoff, design, or idea document an exit
calls for. It stages by explicit path, because other sessions share the
working tree. It classifies the run by its exit, since every exit but a
Disposition line authors prose the user has not seen, and it names what was
authored and points at the staged diff rather than pasting it. It never
pushes and never offers to.

## How to change the skill

- Run a trial on the committed text. Collect friction during the run; edit
  after the Report, so that each run tests one version, and name the trial
  and what it changed in the commit that changes the text.
- Add a section to the card or a question only if it passes the attention
  test above. Prefer moving content later in the run to deleting it: the
  incidental-findings offer and the Basis line are both content that was
  moved, not dropped.
- Add an exit row only when a trial demands one. The idea-document exit was
  added that way; nothing has been added on speculation.
- A change to what the user reads should be shown to them as a rendered
  example from the trial that prompted it, not only as skill text.
- Keep agent-facing instructions terse and user-facing output rules precise;
  the second is where the trials keep finding the defects.

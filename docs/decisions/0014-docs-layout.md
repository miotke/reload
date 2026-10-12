# 0014: Docs as small topic files with an index and decision records

Documentation is split into one-topic files of about 40–150 lines in topic folders, with an index at `docs/README.md` and decision records in `docs/decisions/`.

- **Status:** Accepted
- **Date:** 2026-10-11

## Context

The docs had grown into a few large flat files: a 657-line `design.md` (written before any code, now partly outdated) and component docs of 80–185 lines that mixed several topics (for example `installing.md` covered storage, the installer, the downloader and WoW detection).

Two kinds of readers struggled:
- **People** had to scroll through long files and couldn't tell which parts of `design.md` were still true.
- **LLM agents** had to load whole files to answer one question, wasting context, and could act on outdated design text.

## Decision

- **One topic per file, about 40–150 lines.** Split a file when it grows past that; don't make files so small that one question needs five of them.
- Folders: `architecture/`, `features/`, `network/`, `performance/`, `app/`, `cli/`, `decisions/`, plus top-level `overview.md` and `development.md`.
- Every file starts with a `# Title` and a one-sentence summary.
- **`docs/README.md` is the index**: every file with a one-line "read this when…".
- Link related files with relative links; don't duplicate content.
- Prefer tables, short bullets and Mermaid diagrams.
- **Decision records** (`decisions/NNNN-title.md`, 40–100 lines): Status, Date, Context, Decision, Alternatives considered, Consequences. `decisions/README.md` indexes them.
- `design.md` was removed. What's still true moved into topic files; its choices became decisions 0001–0006; the rest is kept, trimmed and marked historical, in [0000](0000-original-design.md).

## Alternatives considered

| Option | Why not |
|---|---|
| Keep `design.md` and mark outdated sections | Readers still load 650 lines to find one fact |
| One file per Swift type | Too fine; one question would need many files |
| DocC | Good for API reference, not for flows, network budgets and decisions |
| A wiki | Separate from the code; can't change in the same commit |

## Consequences

- Agents load only the files they need, using the index.
- Docs change in the same commit as the code they describe.
- More files and links to keep valid; a link check runs after restructures.
- Code comments that pointed at `docs/design.md §…` must be updated to the new topic files.
- `decisions/README.md` is the one README in a subfolder; `.claude/CLAUDE.md` otherwise says no READMEs in subfolders.

## See also

- [docs/README.md](../README.md)
- [decisions/README.md](README.md)

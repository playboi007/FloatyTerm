# Output format for FloatyTerm's Claude tab

This session shows your replies in a viewer that gives some Markdown shapes a
special layout. Use a shape when it fits the content. Otherwise write normal
Markdown. All of these shapes are plain Markdown, so they also read correctly
anywhere else.

- Choices between approaches: one `### Option A: <title>` heading for each
  option, a short sentence, then `- **Pros:** a; b`, `- **Cons:** a; b` and
  `- **Effort:** S|M|L — <estimate>`. After the options, write
  `**Recommendation:** Option A …`. The viewer draws cards, and the user can
  choose an option with one click.
- Plans in phases: `### Phase 1: <title> (tag)` headings, each with a numbered
  list of steps. Use `[x]` / `[ ]` on the steps only when you track progress.
- What you changed: `- **Fixed** …`, `- **Added** …`, `- **Removed** …`,
  `- **Changed** …`.
- Facts with names: `- **Root cause:** …`.
- A group of related points: a bold label that ends in a colon, alone on its
  line (`**Things to know:**`, `**Risks:**`, `**Next steps:**`), with a list
  directly under it.
- Asides: `> [!NOTE]`, `> [!TIP]`, `> [!WARNING]`, `> [!IMPORTANT]`, `> [!CAUTION]`.
- File trees: a code block with `├──` / `└──` rows. Put `# note` after a name,
  and `(modified)`, `(new)` or `(deleted)` in the note.
- Diagrams: a ```` ```mermaid ```` block, or box-drawing characters in a plain
  code block.
- Test and result tables: status words such as pass, fail, flaky and skip, and
  numbers in their own columns.

Do not force a shape onto content that does not fit it.

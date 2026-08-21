# Markdown, everywhere text arrives from something other than a person

Why `**done**` used to render as five literal asterisks, and what renders it now.
Implemented in `swiftui/`.

## The problem

Three sources in this app produce text nobody wrote by hand:

1. **The realtime model.** It writes markdown whether or not it is asked to. Telling it
   not to in the system prompt works about as well as telling it not to use the word
   "delve" — sometimes.
2. **Claude Code results.** Markdown by nature: bullets, bold, occasionally a fenced
   snippet. These land verbatim in the task card and in the transcript.
3. **Summaries.** Plain prose today, because `ExtractiveSummarizer` selects lines rather
   than writing them — but that is one `init` argument away from being a real model, and
   a real one will not be plain.

All three were drawn with `Text(item.text)`, which renders every marker literally.

## Shape

```
Markdown.blocks(_:)        VibeVoiceCore — headings, lists, code fences, quotes, rules, tables
        │                  pure Foundation, no SwiftUI, fully tested
        ▼
MarkdownText               the app target — one block per row, styled like the rest of the app
        │
        ▼
Markdown.attributed(_:)    inline spans, via Foundation's own markdown parser
```

The split is the one the rest of this codebase uses: the part with rules that can be
wrong lives in Core and is tested; the part that draws lives in the app.

Inline spans (`**bold**`, `_italic_`, `` `code` ``, links) are handed to
`AttributedString(markdown:options:)` with `.inlineOnlyPreservingWhitespace` rather than
re-implemented. Emphasis nesting is exactly the kind of thing that is wrong in ways
nobody notices for a year.

## The decisions worth stating

- **A bullet needs its space.** `- item` is a list; `**done** — the build is green` is a
  paragraph that happens to start with an asterisk. Requiring the space after the marker
  is the whole difference, and it is tested in both directions.
- **Soft-wrapped lines join.** That is what markdown means, and it is what makes a
  re-flowed 372pt sidebar look deliberate rather than ragged.
- **A half-written span is closed, not stripped.** An assistant turn arrives a few
  characters at a time, so `**do` exists for a second or two. `MarkdownText(streaming:)`
  appends the missing marker, so the word turns bold once and stays bold, instead of
  un-bolding the instant its closing asterisks arrive.
- **An unterminated fence still renders.** A reply is mid-fence for as long as the
  snippet takes to write.
- **Tables get no renderer, but their rows do not collapse.** Joining a table's lines
  into one run-on paragraph is worse than the asterisks were. Each row stands alone with
  its pipes turned into separators, and the `|---|---|` divider is dropped.
- **Plain text costs one scan.** `Markdown.isPlain` short-circuits the common case — most
  spoken lines contain no markdown at all — straight to a single `Text`.

## Where it is used

| View | Text |
|---|---|
| `TranscriptView` | User and assistant turns (streaming-aware), and system lines — which is where Claude Code results land verbatim. |
| `TaskPanel` | Task results. |
| `SummaryView` | Every summary. |

Adding a fourth is `MarkdownText(text:)` with a size and a colour.

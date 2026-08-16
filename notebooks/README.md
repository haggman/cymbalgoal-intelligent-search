# Data Preparation Notebook

**Drop the Stage 4/5/6 notebook here.**

It is the record of how the searchable corpus was built:

- **Stage 4** — 14,235 profiles (13,439 players + 796 clubs), ~250 words each, generated with
  `gemini-3.7-flash` grounded in Google Search, prompt v1.6.0
- **Stage 5** — embedded with `gemini-embedding-001` at **3072 dimensions**
- **Stage 6** — exported as headerless gzipped CSV and staged to Cloud Storage

## Why 3072 and not 768

This is the question everyone asks, and it is not a free choice.

Lab 1 embeds the fan's query text *inside PostgreSQL* with
`google_ml.embedding('gemini-embedding-001', query)`. That function takes exactly two arguments —
there is no `output_dimensionality`. So the query-side vector is whatever the model emits natively,
which is 3072. A stored column of any other width fails the distance operator with a dimension
mismatch, live, in front of the room.

Stored documents must match the query. 3072 it is.

## Why the profiles are pre-built

Generating 14,235 grounded profiles costs real money and hours of wall clock. Doing it at lab time
would mean every student waits, every student gets slightly different text, and the lab's
verification steps could not assert anything. Generated once, staged, loaded as ordinary columns —
so the corpus is a pinned artifact and the lab is about search, not about generation.

# Information-gap clustering setup

This milestone implements **Box 6 — Group Similar Questions** from the project
diagram. It groups only questions that already passed the backend's strict
`true_gap` decision. Greetings, personal recommendations, missing integrations,
and temporary AI failures are not included.

## Activate it once

1. Open the Supabase project SQL Editor.
2. Open
   `supabase/migrations/20260820_create_information_gap_clusters.sql`.
3. Copy the complete SQL into a new query.
4. Name the query **Create information gap clusters**.
5. Select **Run**. `Success. No rows returned` is expected.

The migration preserves existing questions. It adds research-audit fields,
creates the cluster table, assigns older saved questions to clusters, and
automatically clusters each new genuine gap.

## Current clustering method

The prototype uses PostgreSQL `pg_trgm` text similarity. This is an intentionally
small and explainable NLP baseline for early testing. Once the project has enough
real questions, compare it with embeddings or BERTopic and report the measured
precision rather than assuming the heavier model is better.

## Security

Community users can still see only their own saved questions. The aggregate
cluster RPC checks a protected Supabase `app_metadata.role` value and permits
only `journalist`, `editor`, or `admin`. Never put a Supabase service-role key in
the iOS application.

## Refine the journalist inbox after the first setup

If the first dashboard includes predictable source limitations—such as a
15-day weather forecast or a routine college-calendar date—run this second,
non-destructive migration once:

1. Open `supabase/migrations/20260820_refine_journalist_inbox_quality.sql`.
2. Copy the complete SQL into a new Supabase SQL Editor query.
3. Name it **Refine journalist inbox quality**.
4. Select **Run**. `Success. No rows returned` is expected.

It does not delete research data. It marks those previously misclassified rows
as `dismissed`, filters them from active reporting leads, and adds a summary RPC
that counts distinct users correctly.

# Journalist response feedback loop

Run this once after the information-gap clustering migration.

1. Open the Supabase **SQL Editor**.
2. Open `supabase/migrations/20260820_create_journalist_response_loop.sql`.
3. Copy the complete SQL into a new query.
4. Name it **Create journalist response loop**.
5. Select **Run**. `Success. No rows returned` is expected.

The migration creates protected journalist drafts, verified published answers,
private user notifications, dismissal and publication RPCs, and retrieval of
published responses as trusted evidence. A private notification is sent only to
an asker who selected **Notify me when available**. Journalists never receive
user names, email addresses, or phone numbers.

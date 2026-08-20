# Supabase chat-history setup

Run the chat-history migration once before testing New Chat and Chat History.

1. Open the Supabase dashboard for the Local Companion project.
2. Select **SQL Editor** in the left sidebar.
3. Select **New query**.
4. Copy all SQL from
   `supabase/migrations/20260818_create_chat_history.sql` into the editor.
5. Select **Run**.
6. Open **Table Editor** and confirm these two tables exist:
   - `chat_conversations`
   - `chat_messages`

The migration enables Row Level Security. Authenticated users can read and
delete only their own conversations and messages.

After it succeeds, keep the FastAPI server running and press `Command-R` in
Xcode. Send one message, select the history icon in Chat, and confirm the new
conversation appears.

create extension if not exists pgcrypto;

create table if not exists public.chat_conversations (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
    title text not null default 'New chat' check (char_length(title) between 1 and 120),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.chat_messages (
    id uuid primary key default gen_random_uuid(),
    conversation_id uuid not null references public.chat_conversations(id) on delete cascade,
    user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
    role text not null check (role in ('user', 'assistant')),
    content text not null check (char_length(content) between 1 and 8000),
    answer_state text check (
        answer_state is null or answer_state in (
            'setup', 'cited', 'abstained', 'out_of_scope', 'forecast_unavailable',
            'service_unavailable'
        )
    ),
    source_title text check (source_title is null or char_length(source_title) <= 300),
    source_url text check (source_url is null or char_length(source_url) <= 2000),
    created_at timestamptz not null default now()
);

alter table public.chat_conversations enable row level security;
alter table public.chat_messages enable row level security;

drop policy if exists "Users can create their own conversations"
    on public.chat_conversations;
create policy "Users can create their own conversations"
    on public.chat_conversations
    for insert
    to authenticated
    with check ((select auth.uid()) = user_id);

drop policy if exists "Users can read their own conversations"
    on public.chat_conversations;
create policy "Users can read their own conversations"
    on public.chat_conversations
    for select
    to authenticated
    using ((select auth.uid()) = user_id);

drop policy if exists "Users can update their own conversations"
    on public.chat_conversations;
create policy "Users can update their own conversations"
    on public.chat_conversations
    for update
    to authenticated
    using ((select auth.uid()) = user_id)
    with check ((select auth.uid()) = user_id);

drop policy if exists "Users can delete their own conversations"
    on public.chat_conversations;
create policy "Users can delete their own conversations"
    on public.chat_conversations
    for delete
    to authenticated
    using ((select auth.uid()) = user_id);

drop policy if exists "Users can create messages in their own conversations"
    on public.chat_messages;
create policy "Users can create messages in their own conversations"
    on public.chat_messages
    for insert
    to authenticated
    with check (
        (select auth.uid()) = user_id
        and exists (
            select 1
            from public.chat_conversations conversation
            where conversation.id = conversation_id
              and conversation.user_id = (select auth.uid())
        )
    );

drop policy if exists "Users can read messages in their own conversations"
    on public.chat_messages;
create policy "Users can read messages in their own conversations"
    on public.chat_messages
    for select
    to authenticated
    using (
        (select auth.uid()) = user_id
        and exists (
            select 1
            from public.chat_conversations conversation
            where conversation.id = conversation_id
              and conversation.user_id = (select auth.uid())
        )
    );

drop policy if exists "Users can delete messages in their own conversations"
    on public.chat_messages;
create policy "Users can delete messages in their own conversations"
    on public.chat_messages
    for delete
    to authenticated
    using (
        (select auth.uid()) = user_id
        and exists (
            select 1
            from public.chat_conversations conversation
            where conversation.id = conversation_id
              and conversation.user_id = (select auth.uid())
        )
    );

grant select, insert, update, delete on public.chat_conversations to authenticated;
grant select, insert, delete on public.chat_messages to authenticated;

create index if not exists chat_conversations_user_updated_idx
    on public.chat_conversations (user_id, updated_at desc);

create index if not exists chat_messages_conversation_created_idx
    on public.chat_messages (conversation_id, created_at asc);

create or replace function public.touch_chat_conversation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    update public.chat_conversations
    set updated_at = now()
    where id = new.conversation_id
      and user_id = new.user_id;
    return new;
end;
$$;

revoke all on function public.touch_chat_conversation() from public;

drop trigger if exists touch_conversation_after_message on public.chat_messages;
create trigger touch_conversation_after_message
after insert on public.chat_messages
for each row execute function public.touch_chat_conversation();

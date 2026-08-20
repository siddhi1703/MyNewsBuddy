create extension if not exists pgcrypto;

create table if not exists public.unanswered_questions (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
    question text not null check (char_length(question) between 1 and 1000),
    location text not null check (char_length(location) between 1 and 200),
    category text not null default 'pending_review',
    status text not null default 'unanswered'
        check (status in ('unanswered', 'reviewing', 'answered', 'dismissed')),
    notification_requested boolean not null default false,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

alter table public.unanswered_questions enable row level security;

drop policy if exists "Users can add their own unanswered questions"
    on public.unanswered_questions;
create policy "Users can add their own unanswered questions"
    on public.unanswered_questions
    for insert
    to authenticated
    with check ((select auth.uid()) = user_id);

drop policy if exists "Users can read their own unanswered questions"
    on public.unanswered_questions;
create policy "Users can read their own unanswered questions"
    on public.unanswered_questions
    for select
    to authenticated
    using ((select auth.uid()) = user_id);

drop policy if exists "Users can update their own notification preference"
    on public.unanswered_questions;
create policy "Users can update their own notification preference"
    on public.unanswered_questions
    for update
    to authenticated
    using ((select auth.uid()) = user_id)
    with check ((select auth.uid()) = user_id);

grant select, insert on public.unanswered_questions to authenticated;
revoke update on public.unanswered_questions from authenticated;
grant update (notification_requested) on public.unanswered_questions to authenticated;

create index if not exists unanswered_questions_created_at_idx
    on public.unanswered_questions (created_at desc);

create index if not exists unanswered_questions_category_status_idx
    on public.unanswered_questions (category, status);

-- Box 6 of the research pipeline: group similar, genuine information gaps.
--
-- This is deliberately a lightweight MVP clustering layer. PostgreSQL trigram
-- similarity is transparent, inexpensive, and suitable while the prototype has
-- a small question set. It can later be replaced by embeddings or BERTopic
-- without changing the iOS question-logging contract.

create extension if not exists pg_trgm;

alter table public.unanswered_questions
    add column if not exists confidence double precision,
    add column if not exists evidence_checked jsonb not null default '[]'::jsonb,
    add column if not exists assistant_response text;

alter table public.unanswered_questions
    drop constraint if exists unanswered_questions_confidence_check;

alter table public.unanswered_questions
    add constraint unanswered_questions_confidence_check
    check (confidence is null or (confidence >= 0 and confidence <= 1));

create table if not exists public.information_gap_clusters (
    id uuid primary key default gen_random_uuid(),
    representative_question text not null
        check (char_length(representative_question) between 1 and 2000),
    normalized_question text not null,
    location text not null check (char_length(location) between 1 and 200),
    category text not null,
    status text not null default 'candidate'
        check (status in ('candidate', 'reviewing', 'investigating', 'dismissed', 'published')),
    editorial_notes text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

alter table public.unanswered_questions
    add column if not exists cluster_id uuid
        references public.information_gap_clusters(id) on delete set null;

create index if not exists unanswered_questions_cluster_id_idx
    on public.unanswered_questions (cluster_id);

create index if not exists information_gap_clusters_lookup_idx
    on public.information_gap_clusters (category, location, updated_at desc);

create index if not exists information_gap_clusters_trigram_idx
    on public.information_gap_clusters using gin (normalized_question gin_trgm_ops);

create or replace function public.normalize_gap_question(input text)
returns text
language sql
immutable
strict
set search_path = public
as $$
    select trim(
        regexp_replace(
            regexp_replace(
                lower(input),
                '[^[:alnum:][:space:]]+',
                ' ',
                'g'
            ),
            '[[:space:]]+',
            ' ',
            'g'
        )
    );
$$;

create or replace function public.assign_information_gap_cluster()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    normalized text;
    matched_cluster_id uuid;
begin
    normalized := public.normalize_gap_question(new.question);

    select cluster.id
      into matched_cluster_id
      from public.information_gap_clusters as cluster
     where cluster.category = new.category
       and similarity(lower(cluster.location), lower(new.location)) >= 0.45
       and similarity(cluster.normalized_question, normalized) >= 0.42
     order by similarity(cluster.normalized_question, normalized) desc,
              cluster.updated_at desc
     limit 1
     for update skip locked;

    if matched_cluster_id is null then
        insert into public.information_gap_clusters (
            representative_question,
            normalized_question,
            location,
            category
        ) values (
            new.question,
            normalized,
            new.location,
            new.category
        )
        returning id into matched_cluster_id;
    else
        update public.information_gap_clusters
           set updated_at = now()
         where id = matched_cluster_id;
    end if;

    new.cluster_id := matched_cluster_id;
    return new;
end;
$$;

revoke all on function public.assign_information_gap_cluster() from public;

drop trigger if exists assign_information_gap_cluster_before_write
    on public.unanswered_questions;
create trigger assign_information_gap_cluster_before_write
before insert or update of question, location, category
on public.unanswered_questions
for each row execute function public.assign_information_gap_cluster();

-- Put questions that were saved before this migration into an initial cluster.
update public.unanswered_questions
   set question = question
 where cluster_id is null;

alter table public.information_gap_clusters enable row level security;
revoke all on public.information_gap_clusters from anon, authenticated;

-- Journalist access is assigned in auth.users.raw_app_meta_data, never in
-- user-editable metadata. A new access token is required after changing a role.
create or replace function public.is_journalist()
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
    select coalesce(
        (auth.jwt() -> 'app_metadata' ->> 'role') in ('journalist', 'editor', 'admin'),
        false
    );
$$;

revoke all on function public.is_journalist() from public;
grant execute on function public.is_journalist() to authenticated;

create or replace function public.get_information_gap_clusters(
    minimum_questions integer default 1
)
returns table (
    cluster_id uuid,
    representative_question text,
    category text,
    status text,
    question_count bigint,
    unique_asker_count bigint,
    locations text[],
    question_examples text[],
    first_seen_at timestamptz,
    last_seen_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, auth
as $$
begin
    if not public.is_journalist() then
        raise exception 'Journalist access is required.' using errcode = '42501';
    end if;

    return query
    select
        cluster.id,
        cluster.representative_question,
        cluster.category,
        cluster.status,
        count(question.id)::bigint,
        count(distinct question.user_id)::bigint,
        array_agg(distinct question.location order by question.location),
        (array_agg(question.question order by question.created_at desc))[1:5],
        min(question.created_at),
        max(question.created_at)
    from public.information_gap_clusters as cluster
    join public.unanswered_questions as question
      on question.cluster_id = cluster.id
    group by cluster.id
    having count(question.id) >= greatest(minimum_questions, 1)
    order by count(question.id) desc, max(question.created_at) desc;
end;
$$;

revoke all on function public.get_information_gap_clusters(integer) from public;
grant execute on function public.get_information_gap_clusters(integer) to authenticated;


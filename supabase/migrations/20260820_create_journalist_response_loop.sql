-- Boxes 9-11: journalist review, verified response, user delivery, and reuse as
-- trusted evidence. All cross-user operations go through role-checked RPCs.

create table if not exists public.journalist_responses (
    id uuid primary key default gen_random_uuid(),
    cluster_id uuid not null unique
        references public.information_gap_clusters(id) on delete cascade,
    journalist_id uuid not null references auth.users(id) on delete restrict,
    response_text text not null check (char_length(response_text) between 1 and 8000),
    source_title text not null check (char_length(source_title) between 1 and 300),
    source_url text not null check (
        char_length(source_url) between 8 and 2000
        and source_url ~* '^https://'
    ),
    status text not null default 'draft'
        check (status in ('draft', 'published')),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    published_at timestamptz
);

create table if not exists public.journalist_notifications (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,
    cluster_id uuid not null
        references public.information_gap_clusters(id) on delete cascade,
    response_id uuid not null
        references public.journalist_responses(id) on delete cascade,
    created_at timestamptz not null default now(),
    read_at timestamptz,
    unique (user_id, response_id)
);

create index if not exists journalist_notifications_user_created_idx
    on public.journalist_notifications (user_id, created_at desc);

alter table public.journalist_responses enable row level security;
alter table public.journalist_notifications enable row level security;

revoke all on public.journalist_responses from anon, authenticated;
revoke all on public.journalist_notifications from anon, authenticated;

-- Save a draft or publish a verified answer. Publishing atomically resolves the
-- underlying questions and creates private notifications for their askers.
create or replace function public.save_journalist_response(
    target_cluster_id uuid,
    answer_text text,
    answer_source_title text,
    answer_source_url text,
    publish boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = public, auth
as $$
declare
    saved_response_id uuid;
begin
    if not public.is_journalist() then
        raise exception 'Journalist access is required.' using errcode = '42501';
    end if;

    if not exists (
        select 1 from public.information_gap_clusters where id = target_cluster_id
    ) then
        raise exception 'Information-gap topic was not found.' using errcode = 'P0002';
    end if;

    if char_length(trim(answer_text)) < 1 then
        raise exception 'A verified answer is required.' using errcode = '22023';
    end if;
    if char_length(trim(answer_source_title)) < 1 then
        raise exception 'A source title is required.' using errcode = '22023';
    end if;
    if trim(answer_source_url) !~* '^https://' then
        raise exception 'Use a complete HTTPS source URL.' using errcode = '22023';
    end if;

    if not publish and exists (
        select 1
        from public.journalist_responses
        where cluster_id = target_cluster_id
          and status = 'published'
    ) then
        raise exception 'A published answer can only be changed by publishing the verified update.'
            using errcode = '22023';
    end if;

    insert into public.journalist_responses (
        cluster_id,
        journalist_id,
        response_text,
        source_title,
        source_url,
        status,
        published_at
    ) values (
        target_cluster_id,
        auth.uid(),
        trim(answer_text),
        trim(answer_source_title),
        trim(answer_source_url),
        case when publish then 'published' else 'draft' end,
        case when publish then now() else null end
    )
    on conflict (cluster_id) do update
    set journalist_id = auth.uid(),
        response_text = excluded.response_text,
        source_title = excluded.source_title,
        source_url = excluded.source_url,
        status = case
            when public.journalist_responses.status = 'published' then 'published'
            else excluded.status
        end,
        published_at = case
            when public.journalist_responses.status = 'published'
                then public.journalist_responses.published_at
            when excluded.status = 'published' then now()
            else null
        end,
        updated_at = now()
    returning id into saved_response_id;

    if publish then
        update public.information_gap_clusters
        set status = 'published', updated_at = now()
        where id = target_cluster_id;

        update public.unanswered_questions
        set status = 'answered', updated_at = now()
        where cluster_id = target_cluster_id
          and status in ('unanswered', 'reviewing');

        insert into public.journalist_notifications (
            user_id,
            cluster_id,
            response_id
        )
        select distinct
            question.user_id,
            target_cluster_id,
            saved_response_id
        from public.unanswered_questions as question
        where question.cluster_id = target_cluster_id
          and question.notification_requested
        on conflict (user_id, response_id) do nothing;
    else
        update public.information_gap_clusters
        set status = 'reviewing', updated_at = now()
        where id = target_cluster_id
          and status in ('candidate', 'reviewing', 'investigating');
    end if;

    return saved_response_id;
end;
$$;

revoke all on function public.save_journalist_response(uuid, text, text, text, boolean) from public;
grant execute on function public.save_journalist_response(uuid, text, text, text, boolean) to authenticated;

create or replace function public.get_journalist_response(target_cluster_id uuid)
returns table (
    response_id uuid,
    response_text text,
    source_title text,
    source_url text,
    response_status text,
    updated_at timestamptz,
    published_at timestamptz
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
        response.id,
        response.response_text,
        response.source_title,
        response.source_url,
        response.status,
        response.updated_at,
        response.published_at
    from public.journalist_responses as response
    where response.cluster_id = target_cluster_id;
end;
$$;

revoke all on function public.get_journalist_response(uuid) from public;
grant execute on function public.get_journalist_response(uuid) to authenticated;

create or replace function public.dismiss_information_gap(
    target_cluster_id uuid,
    reason text default 'Dismissed after journalist review.'
)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
begin
    if not public.is_journalist() then
        raise exception 'Journalist access is required.' using errcode = '42501';
    end if;

    update public.information_gap_clusters
    set status = 'dismissed',
        editorial_notes = nullif(trim(reason), ''),
        updated_at = now()
    where id = target_cluster_id
      and status <> 'published';

    update public.unanswered_questions
    set status = 'dismissed', updated_at = now()
    where cluster_id = target_cluster_id
      and status in ('unanswered', 'reviewing');
end;
$$;

revoke all on function public.dismiss_information_gap(uuid, text) from public;
grant execute on function public.dismiss_information_gap(uuid, text) to authenticated;

-- Private in-app delivery. The RPC exposes only the signed-in user's own
-- notifications and never returns journalist or community contact information.
create or replace function public.get_my_journalist_notifications()
returns table (
    notification_id uuid,
    cluster_id uuid,
    original_question text,
    answer_text text,
    source_title text,
    source_url text,
    published_at timestamptz,
    read_at timestamptz
)
language sql
stable
security definer
set search_path = public, auth
as $$
    select
        notification.id,
        notification.cluster_id,
        coalesce(
            (
                select question.question
                from public.unanswered_questions as question
                where question.cluster_id = notification.cluster_id
                  and question.user_id = auth.uid()
                order by question.created_at desc
                limit 1
            ),
            cluster.representative_question
        ),
        response.response_text,
        response.source_title,
        response.source_url,
        response.published_at,
        notification.read_at
    from public.journalist_notifications as notification
    join public.journalist_responses as response
      on response.id = notification.response_id
     and response.status = 'published'
    join public.information_gap_clusters as cluster
      on cluster.id = notification.cluster_id
    where notification.user_id = auth.uid()
    order by response.published_at desc nulls last;
$$;

revoke all on function public.get_my_journalist_notifications() from public;
grant execute on function public.get_my_journalist_notifications() to authenticated;

create or replace function public.mark_journalist_notification_read(
    target_notification_id uuid
)
returns void
language sql
security definer
set search_path = public, auth
as $$
    update public.journalist_notifications
    set read_at = coalesce(read_at, now())
    where id = target_notification_id
      and user_id = auth.uid();
$$;

revoke all on function public.mark_journalist_notification_read(uuid) from public;
grant execute on function public.mark_journalist_notification_read(uuid) to authenticated;

-- Published journalist answers become retrievable trusted evidence. This uses
-- the prototype's explainable trigram baseline and can later move to pgvector.
create or replace function public.search_published_journalist_answers(
    query_text text,
    match_threshold double precision default 0.35
)
returns table (
    response_id uuid,
    representative_question text,
    answer_text text,
    source_title text,
    source_url text,
    published_at timestamptz,
    similarity_score double precision
)
language sql
stable
security definer
set search_path = public, auth, extensions
as $$
    select
        response.id,
        cluster.representative_question,
        response.response_text,
        response.source_title,
        response.source_url,
        response.published_at,
        similarity(
            cluster.normalized_question,
            public.normalize_gap_question(query_text)
        )::double precision
    from public.journalist_responses as response
    join public.information_gap_clusters as cluster
      on cluster.id = response.cluster_id
    where auth.uid() is not null
      and response.status = 'published'
      and similarity(
          cluster.normalized_question,
          public.normalize_gap_question(query_text)
      ) >= greatest(0.15, least(match_threshold, 0.90))
    order by similarity_score desc, response.published_at desc
    limit 3;
$$;

revoke all on function public.search_published_journalist_answers(text, double precision) from public;
grant execute on function public.search_published_journalist_answers(text, double precision) to authenticated;

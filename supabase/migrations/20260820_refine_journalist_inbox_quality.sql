-- Remove predictable source-limit questions from the active journalist inbox.
-- Nothing is deleted: existing misclassified rows are marked dismissed so the
-- research audit trail remains available.

update public.unanswered_questions
set status = 'dismissed', updated_at = now()
where status = 'unanswered'
  and (
      (
          category = 'weather'
          and question ~* '\m(weather|forecast|rain|snow|temperature)\M'
          and (
              question ~* '\m(after|in|next|for)\M[[:space:]]+([89]|[1-9][0-9]+)[[:space:]]+days?\M'
              or question ~* '\m(after|in|next|for)\M[[:space:]]+[2-9][0-9]*[[:space:]]+weeks?\M'
              or question ~* '\m(after|in|next|for)\M[[:space:]]+[1-9][0-9]*[[:space:]]+months?\M'
          )
      )
      or (
          category = 'events'
          and question ~* '\mwhen\M'
          and question ~* '\m(class|classes|semester|term|college|school|university)\M'
          and question ~* '\m(start|starts|begin|begins|open|opens)\M'
          and question !~* '\mwhy\M|\mcancel|\mclosed\M|\mdelay|\mproblem\M|\mimpact\M'
      )
  );

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
     and question.status = 'unanswered'
    where cluster.status in ('candidate', 'reviewing', 'investigating')
    group by cluster.id
    having count(question.id) >= greatest(minimum_questions, 1)
    order by count(question.id) desc, max(question.created_at) desc;
end;
$$;

revoke all on function public.get_information_gap_clusters(integer) from public;
grant execute on function public.get_information_gap_clusters(integer) to authenticated;

create or replace function public.get_information_gap_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
    result jsonb;
begin
    if not public.is_journalist() then
        raise exception 'Journalist access is required.' using errcode = '42501';
    end if;

    select jsonb_build_object(
        'topic_count', count(distinct question.cluster_id),
        'question_count', count(question.id),
        'unique_asker_count', count(distinct question.user_id)
    )
    into result
    from public.unanswered_questions as question
    join public.information_gap_clusters as cluster
      on cluster.id = question.cluster_id
    where question.status = 'unanswered'
      and cluster.status in ('candidate', 'reviewing', 'investigating');

    return result;
end;
$$;

revoke all on function public.get_information_gap_summary() from public;
grant execute on function public.get_information_gap_summary() to authenticated;

-- Keep existing chat-history installations in sync with the iOS answer states.
-- The original table predates the explicit state used for temporary AI outages.
alter table public.chat_messages
    drop constraint if exists chat_messages_answer_state_check;

alter table public.chat_messages
    add constraint chat_messages_answer_state_check check (
        answer_state is null or answer_state in (
            'setup',
            'cited',
            'abstained',
            'out_of_scope',
            'forecast_unavailable',
            'service_unavailable'
        )
    );

-- Match the database limit to the FastAPI request schema and iOS composer.
alter table public.unanswered_questions
    drop constraint if exists unanswered_questions_question_check;

alter table public.unanswered_questions
    add constraint unanswered_questions_question_check
    check (char_length(question) between 1 and 2000);

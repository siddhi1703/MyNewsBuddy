# Give an approved journalist dashboard access

The Journalist Inbox is hidden from ordinary community accounts. Supabase checks
the protected `app_metadata.role` claim before it returns aggregate questions.

In the Supabase SQL Editor, run the following after replacing the email with the
approved journalist's actual login email:

```sql
update auth.users
set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb)
    || '{"role":"journalist"}'::jsonb
where email = 'JOURNALIST_LOGIN_EMAIL';
```

Then sign out of the iOS app and sign in again. This creates a new access token
containing the journalist role. Open **Profile → Journalist Inbox**.

Do not put journalist authorization in `user_metadata`; users can change that
metadata themselves. Do not place the Supabase service-role key in the app.

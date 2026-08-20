# Activate real accounts and email OTP

The iOS authentication flow is implemented. Complete this one-time setup to connect it to a real Supabase Auth project.

## 1. Create a Supabase project

1. Go to <https://supabase.com/dashboard>.
2. Create a project for **Hyperlocal News Companion**.
3. Wait for the project to finish provisioning.

## 2. Require email confirmation

1. In the Supabase dashboard, open **Authentication**.
2. Open **Sign In / Providers**, then **Email**.
3. Keep email signup enabled.
4. Turn **Confirm email** on.

## 3. Make the confirmation email contain an OTP code

1. Open **Authentication → Email Templates**.
2. Select **Confirm signup**.
3. Use a template containing `{{ .Token }}`, for example:

```html
<h2>Verify your Local Companion account</h2>
<p>Enter this verification code in the app:</p>
<h1>{{ .Token }}</h1>
<p>If you did not create this account, you can ignore this email.</p>
```

4. Save the template. Supabase may issue a code longer than six digits; the app
   accepts the 6–10 digit token received in the email.

For password recovery, also open **Reset password** and make sure its body uses
`{{ .Token }}` rather than only `{{ .ConfirmationURL }}`. The app's recovery
screen expects the numeric token.

## 4. Add the public client configuration

1. In Supabase, open the project's **Connect** dialog or **Settings → API Keys**.
2. Copy the **Project URL**.
3. Copy the **Publishable key** beginning with `sb_publishable_`.
4. Open `HyperlocalNews/AppConfiguration.swift`.
5. Replace:

```swift
static let supabaseURL = "https://YOUR_PROJECT_REF.supabase.co"
static let supabasePublishableKey = "sb_publishable_REPLACE_WITH_YOUR_KEY"
```

Use only the publishable key in the iOS app. Never add a secret key or service-role key.

## 5. Test

1. Run the app.
2. Select **Sign Up**.
3. Enter an email, a phone number with country code, and a strong password.
4. Retrieve the verification code from the email.
5. Enter the code in the app.
6. Confirm that the Home screen appears.
7. Open Profile and test **Sign Out** and **Sign In**.

The phone number is currently collected as profile metadata. It is not verified by SMS; this milestone verifies the email address only.

For production email volume and branding, configure a custom SMTP provider in Supabase.

## 6. Create the unanswered-question log

The Chat screen saves unanswered local questions for later journalist review.

1. In Supabase, open **SQL Editor**.
2. Choose **New query**.
3. Open `supabase/migrations/20260813_create_unanswered_questions.sql` from this project.
4. Copy the complete SQL file into the query editor.
5. Select **Run**.
6. In **Table Editor**, confirm that `unanswered_questions` exists.

The included row-level security rules allow a signed-in user to create, read, and update only their own questions. Do not disable row-level security.

To test it, ask a local civic question for which none of the connected trusted
sources has evidence. The honest-abstention response should show **Saved for
journalist review**, and a row should appear in `unanswered_questions`.

If the base migration was already run before August 19, 2026, also run
`supabase/migrations/20260819_align_question_length_limit.sql` once.

# Local Companion FastAPI backend

This backend is the only component allowed to hold the Gemini API key. The iOS
application sends the user question and already-retrieved trusted evidence to
`POST /ask`. Gemini writes a friendly response, while the backend enforces that
an answered response contains at least one valid evidence citation.

## Run locally

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
cp .env.example .env
```

Replace the placeholder in `.env`, then run:

```bash
uvicorn app.main:app --reload --env-file .env
```

Verify <http://127.0.0.1:8000/health>. The response should show
`"model_configured": true`.

The `/ask` endpoint also requires a valid Supabase user access token. Configure
`SUPABASE_URL` and the project's public publishable key in `.env`. The iOS app
sends its Keychain-stored session as `Authorization: Bearer <token>`. FastAPI
validates that session with Supabase before calling Gemini and limits each user
to `CHAT_REQUESTS_PER_MINUTE` requests per minute.

The checked-in iOS configuration uses the hosted Render service. To test this
local server, temporarily set `chatAPIBaseURL` in
`HyperlocalNews/AppConfiguration.swift` to `http://127.0.0.1:8000`. A physical
iPhone needs the HTTPS deployment or the Mac's reachable LAN address.

# Hyperlocal News Companion

An iOS SwiftUI prototype for asking local questions and receiving concise answers from trusted civic sources.

## Current milestone

- Real email/password authentication architecture using Supabase Auth
- Sign-up form with email, phone, password, and password confirmation
- Email signup verification supporting Supabase OTP codes from 6–10 digits
- Secure session storage in the iOS Keychain
- Automatic session refresh and sign out
- Live device-location weather from the National Weather Service API
- Live MBTA service-alert retrieval for subway, bus, Commuter Rail, and ferry questions
- Native Apple MapKit screen with address and landmark search
- Start/destination search with handoff to Apple Maps for transit directions
- Nearby MBTA stop markers with official live arrival predictions
- Chat answers for “next train” questions using nearby MBTA platform predictions
- Weather-responsive Home screen for sun, cloud, rain, snow, storms, fog, and night
- Animated neutral weather companion that changes with the local forecast
- Gemini-generated, friendly local answers grounded in live NWS and MBTA evidence
- Full Gemini conversation context for follow-up questions; Swift retrieves trusted
  evidence but does not generate template-based weather or MBTA chat answers
- FastAPI security boundary so the Gemini key never ships inside the iOS app
- Supabase-authenticated `/ask` requests with per-user burst rate limiting
- Authenticated hybrid NLP source routing using rules, semantic intent examples,
  entity/location extraction, and Gemini fallback for ambiguous questions
- Auditable required-source and retrieval-attempt metadata on every AI request
- Backend enforcement preventing failed or unconnected source checks from being
  saved as journalism information gaps
- Clickable Weather.gov citations verified by the backend
- Honest “I don’t know yet” responses for unsupported local questions
- Supabase unanswered-question logging for journalist review
- Automatic lightweight clustering of similar information-gap questions
- Research audit data recording confidence, checked sources, and the abstention
- Role-protected Journalist Inbox with cluster volume, asker counts, locations,
  example questions, and reporting-lead details
- Research-quality guards that exclude forecast-horizon limits and routine
  academic-calendar lookups from journalism-gap reporting
- Saved notification-interest requests for unanswered questions
- Trusted local source links after an abstention
- Distinct setup, out-of-scope, and honest-abstention states
- Five-tab product structure with Home, Chat, Transit Map, Events, and Profile
- iOS Chat connected to the FastAPI `/ask` endpoint
- Per-user Supabase chat history with New Chat, restore, and delete controls
- Recent conversation context included for natural follow-up questions

Every user and assistant message is stored in the user's private `chat_messages`
history. Only sufficiently specific, unanswered public-interest questions are
also stored in `unanswered_questions` for journalist review. Answered weather or
MBTA questions, personal recommendations, ambiguous questions, and missing-source
engineering issues are never labeled as journalism gaps.

## Activate authentication

Follow [SUPABASE_SETUP.md](SUPABASE_SETUP.md) to connect the account screens to a real Supabase project and email OTP.

Run [SUPABASE_CHAT_HISTORY_SETUP.md](SUPABASE_CHAT_HISTORY_SETUP.md) once to
activate saved conversations and the New Chat workflow.

Run [SUPABASE_GAP_CLUSTERING_SETUP.md](SUPABASE_GAP_CLUSTERING_SETUP.md) once to
activate Box 6 of the research pipeline. This uses explainable PostgreSQL text
similarity as an MVP baseline; embeddings or BERTopic remain a later evaluation.

Follow [SUPABASE_JOURNALIST_ACCESS.md](SUPABASE_JOURNALIST_ACCESS.md) to grant an
approved editor access to **Profile → Journalist Inbox**. Community accounts
cannot read cross-user clusters.

Run [SUPABASE_JOURNALIST_RESPONSE_SETUP.md](SUPABASE_JOURNALIST_RESPONSE_SETUP.md)
to activate the human-in-the-loop response flow: journalist drafts, cited
publication, private delivery to affected users, dismissal, and reuse of
published responses as trusted evidence for similar future questions.

## Run

1. Open `HyperlocalNews.xcodeproj` in Xcode.
2. Select an iPhone Simulator.
3. Press the Run button or `Command-R`.
4. Choose **Allow While Using App** when iOS requests location access.

Open the **Map** tab, choose **Your location**, enter **Your destination**, and
tap **Find transit options**. The app resolves both locations; Apple Maps shows
the complete transit itinerary. Tap a stop marker for live MBTA predictions.
MapKit and the prototype MBTA requests do not require Google Maps billing.

For a Boston location in Simulator, choose **Features → Location → Custom Location** and use latitude `42.3601`, longitude `-71.0589`.

## Activate the AI chat

The iOS app is configured to use the hosted FastAPI service at
`https://mynewsbuddy-api.onrender.com`, so Terminal does not need to stay open.
Render Free may take about a minute to wake after inactivity; the app retries
that first request automatically.

For optional local backend development, add a Gemini API key only to
`backend/.env`, after `GEMINI_API_KEY=`. Never add the key to a Swift file.

In Terminal, from this project folder, run:

```bash
cd backend
source .venv/bin/activate
uvicorn app.main:app --reload --env-file .env
```

Temporarily change `chatAPIBaseURL` in `HyperlocalNews/AppConfiguration.swift`
to `http://127.0.0.1:8000` while using that local server. See
[`backend/README.md`](backend/README.md) for health checks.

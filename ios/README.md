# RISE for iOS

Native SwiftUI. Same palette, same voice, same AI engine as the web app —
which it reaches through the **same Cloudflare Worker**, so there is no
Anthropic key anywhere in this project.

```
ios/
  RISE.xcodeproj
  RISE/
    RISEApp.swift              app entry, Store (on-device persistence)
    Theme/Theme.swift          palette, type, card + button styles
    Models/Models.swift        Opportunity, StudentProfile, HourEntry
    Services/
      AIClient.swift           talks to /api/ai-search on your Worker
      Prompts.swift            prompts, tuned for a phone screen
      MatchEngine.swift        discovery -> judge -> constraints -> verify
      Catalog.swift            talents, capabilities, 46 Canadian locations
      OfflineLibrary.swift     the guaranteed engine, works with no signal
    Features/                  Home, Match, Results, Hours, Settings
```

## Run it

1. Accept the Xcode licence (one time, needs your password):

   ```bash
   sudo xcodebuild -license accept
   ```

2. Point the app at your deployed Worker. In `Services/AIClient.swift`:

   ```swift
   static let baseURL = URL(string: "https://YOUR-WORKER.workers.dev")!
   ```

3. Open `RISE.xcodeproj`, pick an iPhone simulator, press Run.

If the project file will not open for any reason, the sources are plain and
self-contained: File ▸ New ▸ Project ▸ iOS App (SwiftUI), then drag the `RISE`
folder in. Nothing depends on the project file's structure.

## Why there is no API key in this app

An API key inside an iOS binary is not a secret. The `.ipa` is a zip that
anyone can pull off the App Store and run `strings` over. So the key stays in
the Worker's environment and the app only ever calls `/api/ai-search`.

That choice pays for itself three more times:

- the **cohort cache** works for iOS traffic too, so the phone benefits from
  searches paid for by web users in the same city and category
- the **daily spend cap** and rate limiting cover both clients together
- **prompt changes ship without App Review** — the interesting half of this
  product can be improved in a `wrangler deploy`, not a week-long release cycle

## What is different from the web build

Not a port of the layout. Same product, rebuilt for a thumb.

- **One decision per screen** in the questionnaire, with the primary action
  pinned within thumb reach and a swipe-back gesture.
- **Progressive reveal.** The bundled library lands instantly, then live
  results replace it as they arrive. On a phone, twenty seconds of spinner
  reads as broken; the student is never looking at nothing.
- **Prompts tuned for a small screen.** Every field has a length budget —
  `role` is one sentence of 20 words, `commitment` 8, `firstStep` 15. The web
  prompts assume a wide card, and that paragraph is eight lines on a 375pt
  screen.
- **`firstStep` must be a single physical action.** "Get in touch with the
  organization" is not a step. "Email Priya at volunteer@… and say which
  Saturdays you're free" is.
- **Hard constraints are enforced in code**, same as the web build: a student
  who said remote-only never sees an in-person role ranked above one they can
  actually do, whatever the model scored it.
- **Haptics** on selection and on saving hours.
- **Dynamic Type** throughout, so the app respects the system text size.

## Before this can go to the App Store

Not today — and not because of the code. Two clocks you don't control:

| | Typical |
|---|---|
| Apple Developer Program enrolment | 24–48h, longer for an organisation (needs D-U-N-S) |
| App Review | 24–48h, sometimes days |

And these must be done first:

- [ ] **Sign in with Apple.** Guideline 4.8 — mandatory once you offer Google
      sign-in. This is a hard rejection if missing. It is also the reason the
      current build has no accounts at all: shipping local-only is a legitimate
      v1 and avoids the requirement entirely until you want sync.
- [ ] **App icon.** 1024×1024, no alpha, no rounded corners.
- [ ] **Screenshots**, 6.7" and 6.5" iPhone at minimum.
- [ ] **Privacy policy URL** and **support URL** — both must be live pages.
- [ ] **App Privacy labels.** Today the honest answer is "Data Not Collected",
      because nothing leaves the device except an anonymous matching query.
      That changes the moment you add accounts.
- [ ] **Age rating.** Your audience is 14–18. Answer the questionnaire honestly;
      apps aimed at minors get more scrutiny, not less.
- [ ] **Guideline 4.2 — minimum functionality.** This is a native app, not a web
      wrapper, which is exactly why it was built this way. A WKWebView around
      the existing site would very likely be rejected.
- [ ] **Export compliance.** Standard HTTPS only, so the usual exemption applies.
- [ ] Set a real `PRODUCT_BUNDLE_IDENTIFIER` — currently `ca.riseyouth.RISE`.

## Known gaps

Stated plainly rather than discovered later:

- **Never compiled.** The Xcode licence was not accepted on the build machine,
  so nothing here has been through a compiler. Expect a handful of ordinary
  first-build fixes.
- **No app icon or asset catalog** yet — the build settings reference `AppIcon`
  and `AccentColor`, so add an asset catalog before archiving.
- **No accounts, no cloud sync.** Deliberate for v1 (see Sign in with Apple).
  Hours live on the device and are lost if the app is deleted.
- **No supervisor sign-off.** `HourEntry.verified` exists and is never set. It
  is the field that will carry sign-off, stored from the start so existing
  entries need no migration. Until it is real, a school has only the student's
  word — which is the single most important thing to build next.

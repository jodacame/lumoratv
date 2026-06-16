# Trakt integration (community / social)

LumoraTV can show **community comments and ratings** from [Trakt](https://trakt.tv)
inside the player, and — once you link your account — let you **rate, mark as
watched, and comment**. The whole module is **optional and service-agnostic**: if
you don't configure it, nothing changes and nothing breaks.

There are two distinct pieces, by design:

| Piece | Scope | What it needs |
|---|---|---|
| **Service configuration** (Client ID + Secret) | **Global** — app-level, shared by everyone on the device | A free Trakt API app (below) |
| **Account login** (OAuth tokens) | **Per Apple TV user** — each profile links its own Trakt account | The device-code login inside the app |

Reading public comments/ratings needs **only the Client ID**. Writing (rate /
watched / comment) needs the **per-user login** (which uses the Client Secret).

---

## 1. Create a free Trakt API app (one time)

1. Sign in (or sign up — it's free) at [trakt.tv](https://trakt.tv).
2. Go to **[trakt.tv/oauth/applications](https://trakt.tv/oauth/applications)** → **New Application**.
3. Fill it in:
   - **Name**: anything, e.g. `LumoraTV`.
   - **Redirect URI**: `urn:ietf:wg:oauth:2.0:oob`
     *(required for the device-code / QR login used on Apple TV).*
   - **Permissions / scopes**: leave the defaults (the `/checkin` scope is optional).
   - JavaScript origins: leave blank.
4. **Save**. The app page now shows your **Client ID** and **Client Secret**.

> The Trakt API is free. Rate limits apply but are generous. A few user-account
> features need Trakt VIP, but everything LumoraTV uses works on a free account.

---

## 2. Configure it in LumoraTV (global, once)

On the Apple TV: **Settings → Services → Community (Trakt)**:

1. Paste the **Client ID** → Save. *(This alone enables reading community comments.)*
2. Paste the **Client Secret** → Save. *(Needed only to link an account.)*

---

## 3. Link your account (per user)

Still in **Settings → Services → Community (Trakt)**, tap **“Connect my Trakt
account”**:

1. A **QR code** and a short **code** appear.
2. Scan the QR with your phone (or open the shown URL) → sign in to Trakt →
   enter the code → **authorize**.
3. The Apple TV finishes automatically and shows **Connected**.

Each Apple TV **user/profile links its own Trakt account** — the login is stored
per user (and follows you across your Apple TVs via iCloud Keychain). Use
**Disconnect** to unlink the current user.

---

## What you get

**Without linking (Client ID only):**
- A floating **community comments** panel in the player (Settings tab →
  *Community comments*), per movie / show / **episode**.
- Comments stay in their **original language** (no machine translation); the ones
  in **your subtitle language are shown first**, the rest by likes. Spoilers are
  blurred until you reveal them. Community **rating** is shown too.

**After linking (per user):**
- Your **👍 / 👎** at the end of a movie/show is mirrored to your **Trakt ratings**.
- What you **finish watching** (movies, shows, episodes) is marked on your
  **Trakt history**.
- You can **write a comment** (with an optional spoiler flag) from the panel.

---

## Privacy & behavior

- Reading is anonymous (Client ID only). Writing uses **your** per-user token.
- If Trakt isn't configured or you're not linked, every Trakt action is a silent
  **no-op** — playback and the rest of the app are unaffected.
- Credentials live in the device **Keychain**. Trakt is an independent service;
  LumoraTV is not affiliated with it.

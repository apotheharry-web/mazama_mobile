# Privacy policy: Mazama service-center app

Effective 27 October 2026.

This policy covers the Mazama service-center app for Android and iPhone ("the app"), published by **Mazama Mushrooms
LLC** of Eugene, Oregon, USA ("Mazama", "we"). It says what the app does with information about you, what reaches
Mazama, who sees it, and how long it is kept. Everything here can be checked against the app's source code in this
repository; [SECURITY.md](SECURITY.md) explains how.

## Who the app is for

The app is for people who work at Oregon psilocybin service centers that Mazama supplies. It is a work tool: it is
not meant for anyone else, and not for children.

## Your state sign-in

To use the app you sign in to the Oregon Psilocybin Services product-tracking system ("the state's system") with your
own state email and password. The app:

- sends your password **only to the state's own sign-in service**, never to Mazama or anyone else, and never stores,
  logs or shows it;
- keeps the session the state gives it (an access token and a refresh token, with your email and when the session
  expires) **only on your phone**, in the app's private storage, kept out of phone backups. It is never sent to
  Mazama;
- uses that session to read your center's records from the state's system and to record your sales there, straight
  from the phone. Mazama's server is not in between.

What the state's system does with your sign-in and records is covered by the state's own policies, not this one.

If you choose "Sign in on the state's page", you sign in on the state's own web page inside the app; the app does not
read what you type there.

## What reaches Mazama

The app sends Mazama's server only what it needs to run the service your center has with Mazama:

| What | When | Why |
|---|---|---|
| **Your email address** (as you typed it when signing in) | with sale records, failed-sale reports, orders, par levels, inventory updates and lab reports you send | to know who did what, for your center's and Mazama's records |
| **A random install id** (made by the app the first time it needs one; not your phone's hardware id) | with the same, and with sign-in failure reports | to tell your phone's reports apart and remove duplicates |
| **Sale records and the state's reply** to each sale | after you record a sale | so your center and Mazama have a record of it, and can fix a sale that failed |
| **Failed-sale reports** | when a sale couldn't be recorded | so it can be checked and recorded later |
| **Orders** (including any note you add) and **par levels** | when you send them | to supply your center |
| **Your center's inventory records** from the state's system | when the app refreshes them | so Mazama can see your center's stock of its products |
| **Lab-report PDFs** with the state's document id and potency figure | when the app reads a product's lab report | to produce product labels |
| **Text read from a product label** (not the photo) | when you scan a label | to find the matching product |
| **Sign-in failure reports**: only fixed words for the step and reason, the state's HTTP status and the install id; never your email, password or any message | when signing in fails for a reason other than a wrong password | to learn quickly when the state's sign-in has changed |

**Until Mazama approves your phone.** Mazama approves each email and phone (install id) together before what they
send is used; Mazama's server also approves them for one center by itself when a sale the app reported from that
phone is found in the state's records for that center. Until then, what the app sends (sale records, failed-sale reports, inventory updates, orders, par levels
and lab reports) is kept on Mazama's server **unused**: it isn't added to your center's records, and a lab report isn't
opened. Once Mazama approves your email on that phone, what was kept is used as if it had just arrived (anything out
of date by then, such as an older inventory update, is set aside). What isn't approved is kept, unused, for
up to 30 days and then deleted (only the record that it was sent stays); Mazama may also delete it sooner. Only Mazama
sees what is kept.

Like any web server, ours also sees your phone's internet address and the time of each request; we don't use them to
identify you. The server's own operating logs may also note your email address, for example when an upload is slow.

The app **never** sends Mazama your password or your state session, your contacts, your location, your photos, or
any advertising or tracking identifier. The app contains no analytics, advertising or crash-reporting code.

## Who can see it

- **Mazama** staff, on Mazama's own server.
- **Your center's own staff**, for your center's sales that need checking (a failed sale shows who made it).
- **Nobody else**, except when the law requires it (for example, a request from a regulator or a court).

We don't sell or rent information, and don't share it for advertising. The server runs on hardware Mazama operates;
our billing and email notification systems don't receive your email address or install id.

## How long it is kept

The records above are **kept indefinitely** as Mazama's business and regulatory records. They are stored in a log
that, by design, can't be changed or deleted, so your email address can't be removed from past records. Backups of
the server's database are kept for about 30 days.

On your phone, signing out deletes the session; the app may keep unsent sale reports, with your email, until they
reach Mazama's server. Uninstalling the app deletes everything it stored on the phone.

## Other services the app uses

- **Label scanning on Android** uses Google's on-device text recognition (ML Kit). The photo is read on the phone,
  but Google's library may send Google its own usage statistics, under Google's terms. On iPhone, Apple's on-device
  Vision framework is used.
- Taking the label photo on Android uses your phone's camera app.
- The in-app web pages (the state's sign-in page, and Mazama's inventory portal) use your phone's own web engine,
  which may follow your phone's settings for things like safe-browsing checks.
- Links you choose to open (Mazama's website, Signal, a product sheet, this repository) open in your browser or
  those apps, under their own policies.

## Your choices

- You can stop using the app at any time, sign out, or uninstall it.
- To ask what we hold about you, to correct it, or to ask any other privacy question, message Mazama on Signal from
  the app's **Contact** button, or open an [issue](../../issues) on this repository **without personal details**
  and we will reply privately.

## Security

How the app protects your sign-in, and how to check it yourself, is in [SECURITY.md](SECURITY.md).

## Changes

If this policy changes, the new version is published here with a new effective date. Every earlier version stays in
this repository's history.

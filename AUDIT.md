# Audit the sign-in yourself

[`mazama_mobile/SIGN-IN-SECURITY.md`](mazama_mobile/SIGN-IN-SECURITY.md) makes ten claims about what this app does
with a worker's state email, password and tokens. You don't need to trust them, or us: give this repository and the
prompt below to an AI assistant (or a person who reads Dart), and it checks every claim against the code itself.

## The prompt

Give the assistant this repository (or just the `mazama_mobile/` folder) and this prompt:

> You are auditing the Flutter app in this repository. Read `SIGN-IN-SECURITY.md`, then check each numbered claim
> against the source code, not against the comments. For each claim, open every file and function it names, follow
> the data (the password, the email, the access and refresh tokens, the authorization code) from where it enters to
> every place it is sent, stored, logged or displayed, and look for any path the claim doesn't mention. Search the
> whole `lib/` folder for `http.`, `Request(`, `Uri.parse`, `post(`, `get(`, `send(`, `WebView`, `runJavaScript`,
> `print(`, `debugPrint(`, `workerEmail`, `accessToken`, `refreshToken`, `password` and `Bearer`. Also check the
> request URLs in `assets/flows/*.yaml` and `assets/flows_phone/*.yaml`, and the native code and settings under
> `android/` and `ios/` (permissions, backup settings, native libraries). For each claim answer TRUE, FALSE or PARTLY
> TRUE, with the file and line numbers that prove it, and list anything else you found that sends user data off the
> phone.

The same prompt is at the end of SIGN-IN-SECURITY.md. Tips:

- Use an assistant that can read files and search a folder (one that can open the whole repository), not one that
  only sees what you paste.
- Ask it to judge each claim by its own wording, including the limits it states, and to be skeptical: a confident
  "TRUE" that turns out wrong is worse than an honest "PARTLY TRUE".
- Ask it to list anything in the claims document, or in this repository's README, that is inaccurate or missing.

If its answer differs from ours, please tell us ([SECURITY.md](SECURITY.md)).

## What happened when we ran it

We ran this audit ourselves before publishing, each time with a fresh AI assistant (Claude) that had no memory of
earlier rounds, was given only a copy of this repository, and was told to work read-only with no network requests. Its
reports are published as they were written, in [`audits/`](audits/).

| Round | Date | Result | Report |
|---|---|---|---|
| 1 | 2026-10-26 | 6 claims TRUE, 3 PARTLY TRUE (5, 6, 9) | [audits/2026-10-26-round-1.md](audits/2026-10-26-round-1.md) |
| 2 | 2026-10-26 | 8 claims TRUE, 1 PARTLY TRUE (6) | [audits/2026-10-26-round-2.md](audits/2026-10-26-round-2.md) |
| 3 | 2026-10-26 | 8 claims TRUE, 1 PARTLY TRUE (7) | [audits/2026-10-26-round-3.md](audits/2026-10-26-round-3.md) |
| 4 | 2026-10-27 | 8 claims TRUE, 1 PARTLY TRUE (4) | [audits/2026-10-27-round-4.md](audits/2026-10-27-round-4.md) |
| 5 | 2026-10-27 | 8 claims TRUE, 1 PARTLY TRUE (4) | [audits/2026-10-27-round-5.md](audits/2026-10-27-round-5.md) |

**No round found the password or a token going anywhere but the state's own hosts.** What the rounds found was
that some claims said more than the code does. We changed the claims (and, where it was cheap and safe, the code) so
that they say exactly what the code does:

**After round 1**
- Claim 5: on Android, a form the state's page posts is not checked against the allowlist (Android's WebView never
  reports a POST navigation); clearing cookies before the page opens is attempted every time, not guaranteed.
- Claim 6: only values a run holds under the secret names are scrubbed; the email is scrubbed in the password sign-in
  only.
- Claim 9: the email is also kept in the files of work waiting to be sent to Mazama's server, which signing out keeps.
- Claims 1 to 4: a sign-in spec chooses the words of its questions to the worker; cookies within one sign-in go to
  every allowed host; lab-report downloads can follow a redirect off the allowlist (without the token); the phone
  doesn't check a signature on fetched sign-in steps.

**After round 2**
- Code: the one interpreter error message that repeated a value it was given (`timeout_seconds`) no longer does.
- Claim 6: says which names are scrubbed, and that a sale's error text also goes to Mazama's server (claim 7).
- Claim 7: names the order note, connection metadata, and that the install id links a phone's reports; says the email
  is the one the worker typed.
- New in "What these claims do not cover": the phone's own keyboard, autofill and password manager.
- The README: only `hosts.json` is checked against a signature on the phone; Mazama's server can change the sign-in
  steps within the rules of claims 1 to 4.

**After round 3**
- Code, for what round 3 called the biggest gap: newer sign-in steps fetched from Mazama's server, once they have
  worked, also renew the session unattended, and could have used the worker's sign-in on the state's system for more
  than signing in, up to changing records. Now no sign-in steps, fetched or built in, may make any request to the
  state's main system (`psilocybin.oregon.gov`): only to its sign-in service. The phone and Mazama's server both check
  it, held to the same shared cases. Claim 4 says so.
- Claim 7: also names the lab-report look-ups by lot id, the document id and psilocybin figure sent with a lab
  report, and the center's state id in every request.
- Smaller corrections: the cookie note in claim 2 (today B2C cookies go only to B2C), the developer page in claim 9
  (a summary, not the file), iPhone web view cookies and backups, where product links open, and Flutter's own logging
  of uncaught errors.

**After round 4**
- Code: round 4 found two ways around the new rule: a redirect during a sign-in could still reach the state's main
  system, and so could the page an in-app browser step opens. Now every sign-in and renewal run refuses to send
  anything there, and a redirect there isn't followed; and an in-app browser step may not open a page there either.
  Both are checked on the phone; the second also by Mazama's server, with a new shared case.
- Claim 4 and the README describe both checks; the README's headline names the one exception (a sign-in address
  Mazama has signed for). Claim 7 names label look-ups and the request's `User-Agent`, and says which requests
  carry the center's id. Claim 5 notes the state's site may begin to load in the in-app browser as the sign-in ends.

**After round 5**
- Code: a redirect to the state's main system spelled with a trailing dot (`psilocybin.oregon.gov.`) got past the
  sign-in guard; the guard now compares hosts the way the allowlist does.
- Claim 4 now says the guard covers what the app itself sends, not the in-app browser of "Sign in on the state's
  page", which shows the state's own pages (and holds none of the app's tokens); and that a sign-in address the
  owner signs for could receive the tokens and use them itself.
- The README says plainly that the signing key is what you trust us with, and who could misuse it.

We rerun the audit before any release that changes something the claims name, and add its report here.

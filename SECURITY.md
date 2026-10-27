# Security

The app asks service-center workers for their **own state email and password**. This page says what happens to them,
how you can check it yourself, and how to tell us about a problem. What else the app sends, and to whom, is in the
[privacy policy](PRIVACY.md).

## Our promise

**A worker's state password and the state's sign-in tokens go only to the state: its own sign-in and its API (or a
new sign-in address Mazama has signed for, below). The app never sends them to Mazama or anyone else. The password is
never stored, logged or shown; the tokens are kept only on the phone.** Mazama's server is never in the sale path: a
sale goes from the phone straight to the state.

**What Mazama can change, and its limits.** So the app keeps working when the state changes its sign-in, after a
failed sign-in the app may fetch newer sign-in steps from Mazama's server. Those steps can only talk to the state's
addresses (or one a signed list adds, below), and can only post the password as a form field to the state's sign-in,
never to its API, never to Mazama. The phone checks those rules, not a signature. If the state moves its sign-in to a
new address, Mazama can add that address with a list signed by our own key, checked on the phone; the app names the
new address on screen after the sign-in that used it, once the password has been posted there.

Newer sign-in steps that worked are kept, and can renew the worker's session, unattended. So no sign-in or renewal
ever makes the app send anything to the state's main system, where the worker's records are, only to its sign-in
service: the phone checks the steps before they run, and refuses any request there while they run, redirects
included. Sign-in steps can't make the app read or change a worker's records, whoever wrote them.

**The signing key is the one thing you trust us with.** Whoever holds it can sign a new sign-in address, and the
password and tokens would then go there too. It is kept in the encrypted secrets of Mazama's server, so anyone who
took over that server could do the same.

## The claims, in detail

[`mazama_mobile/SIGN-IN-SECURITY.md`](mazama_mobile/SIGN-IN-SECURITY.md) breaks that promise into nine precise claims
and names the exact files and functions that make each one true:

1. The password goes only to the state's sign-in, as a form field of a POST.
2. Tokens go only to the allowlisted hosts (today, the state's).
3. Every request the sign-in and state flows make is held to the host allowlist, redirects included.
4. Mazama's server is trusted for sign-in only within these rules.
5. Signing in on the state's own page: the app does not read what the worker types.
6. Secrets are scrubbed from error messages.
7. What the app does send to Mazama's server.
8. Third-party code: no analytics or crash reporting, one Google library on Android.
9. Where credentials and tokens are stored on the phone.

It also says plainly what the claims **don't** cover, and the gaps we know about.

## Check it yourself, with an AI assistant

You don't have to read Dart to check these claims. [`AUDIT.md`](AUDIT.md) has a prompt you can give an AI assistant
along with this repository, so it checks every claim against the code itself (not the comments) and answers TRUE,
FALSE or PARTLY TRUE with file and line numbers. It also lists every round we ran ourselves before publishing, with
the full reports in [`audits/`](audits/) and what we changed after each.

## How releases are built

Every release is a tag `v<version>` of this repository, built by Codemagic from that tag's commit with
[`codemagic.yaml`](codemagic.yaml): the Android app is attached to the tag's [GitHub release](../../releases) with its
SHA-256, and the iPhone app goes to the App Store. The builds are not reproducible bit for bit, so the claims describe
this source, not a particular file on a phone.

## Reporting a problem

If you find a way this app could expose a worker's state sign-in, tokens or records, or a claim the code doesn't
keep, please tell us privately first: use **"Report a vulnerability"** on this repository's
[Security tab](../../security/advisories/new). Only Mazama sees the report.

Please include the file and function, what you expected, and what happens instead. We will answer, fix what is real
in a new release, and credit you if you want. Please don't open a public issue for a problem that could be used
against workers before it is fixed, and don't test against the state's system or Mazama's server with accounts that
aren't yours.

# mazama_mobile

Hosted sign-in files for the Mazama apps (Oregon psilocybin product-tracking sign-in).

- `login.yaml`: the password sign-in spec (copy of `mazama_modules/flows/login.yaml`)
- `login_browser.yaml`: the "Sign in on the state's page" spec (copy of `mazama_modules/flows/phone/login_browser.yaml`)
- `hosts.json`: extra sign-in hosts the owner allows (empty list = only the two built-in hosts)

Each file counts only with a matching `<file>.sig` made by `sudo mazama-sales sign <file>` on the server.
Change a file → bump its `spec_version` (or `version` in hosts.json) → sign it again → commit both.

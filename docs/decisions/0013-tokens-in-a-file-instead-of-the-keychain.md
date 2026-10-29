# 0013 — Access tokens in a file instead of the Keychain

**Problem.** The tokens were in the Keychain. Without an Apple Developer account, the app has no team identifier:
the Keychain then recognises it by the fingerprint of its code (`cdhash`), which changes with every build. Every
new version was a stranger, and macOS asked for the Keychain password again (once per entry). A stable self-signed
certificate does not help: the entries still record the `cdhash` (checked on the real entries).

**Choice.** `SessionStore` keeps the tokens in `tokens.json`, in the app's folder (Application Support):
- created directly with permissions 600 (temporary file then rename: never readable by others, never half written);
- left out of the backups (a restored Mac signs in again);
- the active session pointer stays in the preferences (no secret).

**What it costs.** The Keychain encrypted the token and only gave it to the app. Now any program running under the
user's account can read the file. Encrypting it ourselves would change nothing: the key would sit next to it. The
token is not the password, and it can be revoked from the Jellyfin dashboard (Devices).

**Migration.** At the first access, the tokens of the Keychain (one entry per profile, the old single `session`
entry, the old `active` pointer) are moved to the file, then deleted from the Keychain. macOS asks one last time
(one prompt per entry); if the user refuses, they sign in again. If the file cannot be written, the Keychain keeps
everything and the migration is tried again at the next opening.

With an Apple Developer account later, the data protection Keychain (team identifier, no prompt) would be the way
back.

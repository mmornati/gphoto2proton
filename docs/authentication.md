# Authentication

This page explains how gphoto2proton authenticates with Proton and what that
means for headless / remote servers.

---

## No browser, no OAuth2

gphoto2proton does **not** use OAuth2 and it never opens a browser. There is no
"click this link to authorize" step, so there is nothing to validate in a local
browser.

Authentication is performed directly against the Proton API using the
**Proton-API-Bridge SDK**, with your username and password (Proton's SRP login
protocol). The tool is fully headless-friendly and works identically on your
laptop, a VPS, or a rented remote server.

---

## First login

On the first run you supply your Proton credentials with the `--username` and
`--password` flags:

```bash
gphoto2proton sync \
  --takeout-archive takeout-001.tgz \
  --username user@proton.me \
  --password 'your-password'
```

After a successful login the session is saved to
`~/.gphoto2proton/state/session.json` (owner-only permissions) and reused on
every subsequent run — including across machines if you copy the file.

!!! tip "Remote / headless servers"
    Because authentication is pure API login, a remote server works exactly
    like a local machine. You can either:

    - pass `--username`/`--password` directly in the command, or
    - run once with credentials, then copy `session.json` to the server's
      `--state-dir` and run without ever exposing your password on the server.

---

## Subsequent runs: session reuse

On later runs the saved session (`uid`, `accessToken`, `refreshToken`,
`saltedKeyPass`) is loaded automatically. The SDK refreshes tokens in the
background, so you can omit `--username` and `--password`:

```bash
gphoto2proton sync --takeout-archive takeout-002.tgz --resume
gphoto2proton albums-finalize
```

To force a fresh login, delete the saved session:

```bash
rm -f ~/.gphoto2proton/state/session.json
```

---

## Two-factor authentication (2FA) — not yet supported

Accounts with **TOTP two-factor authentication enabled** cannot complete the
first login with this tool yet. The login flow fails with a
`2FA code required` error because the current release does not accept a
one-time code.

Workarounds:

- **Temporarily disable 2FA** in your Proton account settings, complete the
  first login (the session is then saved), and re-enable 2FA. The saved
  session keeps working after 2FA is turned back on.
- If you already have a valid session file from a tool that supports 2FA, place
  it at `<state-dir>/session.json` and it will be reused.

Non-2FA accounts are unaffected.

---

## Security notes

- Credentials are only sent to Proton; the tool never uploads them anywhere else.
- The saved session is written with `0600` permissions in a `0700` directory.
- Prefer shell history hygiene on shared machines — e.g. use environment
  variables or a prompt wrapper, since `--password` is visible in the process
  list while running.

---

## Related

- [Configuration → Credential Storage](configuration.md#credential-storage)
- [Troubleshooting → authentication errors](troubleshooting.md#upload-fails-with-authentication-error)

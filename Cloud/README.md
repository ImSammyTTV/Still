# Still Cloud

Independent sharing server for Still. Python 3.10 or later, standard library only. Captures stay local until Upload is used or automatic upload is explicitly enabled.

## Local use

In Still → Settings → Cloud, choose Start Local Server. The app starts a loopback server, stores its token in macOS Keychain, and stops the server when you quit. Local links are accessible only on this Mac.

To run independently:

```sh
python3 server.py --data ./data --host 127.0.0.1 --port 7843
```

Read the owner token from `data/admin-token` privately. Paste it into the browser login or Still’s Personal Access Token field. Do not commit the data directory. Rotating the token revokes the previous token; existing browser sessions last until their normal expiration.

## Hosting

Run behind an HTTPS reverse proxy. Set `STILL_PUBLIC_URL` to the externally accessible origin before starting. Keep the data volume persistent and private; it contains original media, SQLite, token material and the session secret. Back up the entire directory together. There is no remote storage service bundled or provisioned.

```sh
docker compose up -d --build
```

The included example uses Caddy for TLS. Set `STILL_DOMAIN` and `STILL_PUBLIC_URL` in `.env`, point your DNS at the host, and open ports 80/443. Connect Still to the resulting HTTPS URL with the generated personal token. Copy the token through a private channel; never expose the data directory through the web server.

Configure backups, storage quotas, monitoring and patching for your deployment. This implementation has automated functional tests; external security review and enterprise compliance certification have not been performed.

## Configuration

| Variable | Purpose |
| --- | --- |
| `STILL_PUBLIC_URL` | HTTPS origin used to build share and login URLs |
| `STILL_BRAND` | Name displayed by browser UI |
| `STILL_ACCENT` | Six-digit hex accent color (graphite `#6e6e73` by default) |
| `STILL_ADMIN_TOKEN` | Optional initial owner token, used only when first creating the owner |
| `STILL_MAX_UPLOAD_BYTES` | Per-upload maximum, default 4 GiB |
| `STILL_OIDC_ISSUER` | HTTPS OpenID Connect issuer |
| `STILL_OIDC_CLIENT_ID` | Registered OIDC client ID |
| `STILL_OIDC_CLIENT_SECRET` | OIDC client secret |
| `STILL_OIDC_ALLOWED_DOMAINS` | Comma-separated verified email domains eligible for first-login provisioning |
| `STILL_SCIM_TOKEN` | Separate bearer secret for `/scim/v2/Users` provisioning |
| `STILL_TRUST_PROXY` | Set to `1` only behind a reverse proxy you control (the bundled compose file does), so rate limits use the visitor's address from `X-Forwarded-For` |

OIDC requires discovery, authorization-code with PKCE, and userinfo with verified email. Register `${STILL_PUBLIC_URL}/auth/callback`. Accounts can be provisioned through the team UI or SCIM. The owner can deactivate or reactivate a member with `PATCH /api/users/<id>` (`{"active": false}`) and issue a new token with `POST /api/users/<id>/token`; both sign that member out everywhere, as does logging out. SCIM supports Users, activation and deactivation; Groups and role mapping are not implemented. Validate your identity provider integration before relying on it.

## Sharing behavior

Links support expiration, passwords, view limits and team/private visibility. A public visit counts when the share page API is opened; subsequent range requests use its visit cookie. Downloads enforce access and expiration. Owners can still access their own expired captures through the dashboard. Trash is recoverable and continues to consume disk space. Passwords are salted and hashed. Transport security depends on HTTPS hosting.

Comments accept image positions, video timestamps, replies and owner resolution. OCR, tags, transcripts and caption metadata are searchable. The server does not transcribe audio. API tokens are account-wide credentials: protect them like passwords.

## Verification

```sh
python3 -m unittest discover -s tests -v
```

The suite uses temporary synthetic files and tests authentication, upload validation, byte ranges, passwords, expiry, view limits, access isolation, token rotation, CSRF, comments, search, trash and provisioning. Tests do not contact a remote identity provider.

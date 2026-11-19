# CFMS Flutter client

The Flutter client has one sign-in flow and routes the authenticated identity
to either the Super Admin or tenant workspace. The role is determined by the
session returned from authentication; the login screen has no role selector.

## Local setup

1. Copy `.env.example` to `.env` and set `CFMS_API_BASE_URL` for the local API.
2. Adjust non-secret UI defaults in `config.json` (language, theme mode, and
   pagination defaults).
3. Run `flutter pub get` and `flutter run -d chrome` from this directory.

Only public client configuration belongs in `.env` or `config.json`. Do not put
database credentials, JWT signing secrets, or server secrets in Flutter config;
client assets are included in the built application.

Authentication uses the API configured by `CFMS_API_BASE_URL`. The shared
login response selects the Super Admin or tenant workspace. Tenant capability
responses provide `privileges` and `modules`; keep the client mapping aligned
with the API response when those contracts change.

The dashboard summaries are currently static preview data. Organisation
management, tenant user management, password changes, login, and session checks
are connected to API endpoints. The remaining module destinations are screen
placeholders until their feature APIs and UI are implemented.

## Code layout

- `lib/ui/` — auth, shared shell, theme, Super Admin, and tenant screens
- `lib/providers/` — session and locale state
- `lib/services/` — app configuration, localization, and authentication adapter
- `.env` — local public API endpoint configuration (ignored by Git)
- `config.json` — checked-in defaults for language, theme, and paging

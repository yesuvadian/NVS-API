# Testing the CFMS Flutter app

Rule for this project: every new Flutter feature gets **unit/widget tests** and
**integration tests** (a mocked-backend flow, plus a live end-to-end check when
it touches the server).

| Layer | Where | Needs | Command |
| --- | --- | --- | --- |
| Unit + widget | `test/` | nothing | `flutter test` |
| Mocked integration | `integration_test/app_flows_test.dart` | a device (Windows desktop) | `flutter test integration_test/app_flows_test.dart -d windows` |
| Live end-to-end | `integration_test/live_e2e_test.dart` | running API + database, test accounts | see below |

Run all commands from the `flutter/` folder. Before committing, also run
`flutter analyze` (it must report no issues).

## Unit and widget tests

```
flutter test
```

- Services and providers use `MockClient` or the in-memory fake API.
- `test/support/fake_api.dart` (`FakeCfmsApi`) answers the endpoints the app
  uses with the server's JSON shapes and error format
  (`detail.shortCode` / `detail.message`), keeps state (users, privileges,
  modules, members, row versions, Idempotency-Keys) and records every request.
- `test/support/flows.dart` holds whole-app journeys (login, first-login
  password change, menus by privilege/module, Members, Tamil). They run as
  widget tests in `test/app_flows_test.dart` and on a device in
  `integration_test/app_flows_test.dart`.
- `AppConfig.httpClient` injects the fake backend into the real app;
  `CfmsApp.sessionCheckInterval` shortens the 30-second session/privilege
  check in tests.

## Mocked integration tests (no server)

```
flutter test integration_test/app_flows_test.dart -d windows
```

This builds and runs the real Windows desktop app against `FakeCfmsApi`, so it
works anywhere, including CI on a Windows runner. The first run builds the
app (a few minutes); later runs are faster. Windows desktop needs Visual
Studio with the "Desktop development with C++" workload (`flutter doctor`).

Chrome is not used for integration tests: `flutter test` cannot drive web
devices, and `flutter drive -d chrome` needs a chromedriver matching the
installed Chrome, which is not installed on this laptop.

## Live end-to-end tests (local API + database)

Prerequisites:

1. PostgreSQL configured in the root `.env`, seeded (`python seed.py`).
2. The API running on port 8000, from the repository root:
   ```
   .venv\Scripts\python -m uvicorn app.main:app --host 127.0.0.1 --port 8000 --loop asyncio:SelectorEventLoop
   ```
   (On Windows the `--loop` option is required; psycopg cannot use the default
   Proactor event loop.)
3. Accounts with known passwords: the Super Admin, an organisation admin, and
   optionally a staff user who holds `member.create` (needed for the
   member-creation test, which is skipped otherwise). To give a provisioned
   account its first password: `python -m app.auth.initialize_password <email>`.

Run (credentials are passed on the command line and never committed):

```
flutter test integration_test/live_e2e_test.dart -d windows --dart-define=E2E_LIVE=true --dart-define=E2E_SUPERADMIN_USER=superadmin@example.com --dart-define=E2E_SUPERADMIN_PASSWORD=<password> --dart-define=E2E_ADMIN_USER=admin@demo.example.com --dart-define=E2E_ADMIN_PASSWORD=<password> --dart-define=E2E_STAFF_USER=emp@demo.example.com --dart-define=E2E_STAFF_PASSWORD=<password>
```

Optional: `E2E_API_URL` (default `http://127.0.0.1:8000`), `E2E_TENANT_CODE`
(default `demo`), `E2E_TOGGLE_MODULE` / `E2E_TOGGLE_MENU` (default
`LOAN_REPAY` / `Collections`).

Without `E2E_LIVE=true` every live test is skipped, so the file is safe to run
anywhere.

What the live tests do, and why they are safe to re-run:

- Super Admin signs in; the Overview shows the API's organisation total.
- The organisation admin signs in; the Overview and the Members, Loans and
  Roles & privileges menus are shown.
- The test module is switched off for the organisation, so the admin's menu
  no longer shows it, and is then switched back on. The restore also runs
  when the test fails. Each switch is recorded in the configuration change
  log with the reason "E2E test …".
- The staff user creates a member named `E2E Member <timestamp>` with a
  unique mobile number. Members cannot be deleted through the API, so these
  stay in the database, recognisable by the name.
- API sign-ins use `force_logout`, so a test can sign out the same account on
  another device. Do not run the live tests with accounts people are using.

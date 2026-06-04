# Sentry Organization

**Canonical org**: `studio`
**Org URL**: `https://acme-co.sentry.io/`

Every Sentry project the operator owns rolls up to this one org. Any Sentry short-ID (e.g. `STUDIOWEB-RAILS-3`, `SHOPOS-WEB-…`, `GASCALC-IOS-…`) resolves under `studio/<project>`. There is no other Sentry org to check.

## Routing rule

When you encounter a Sentry issue reference, API call, or CLI invocation:

- **Browser / web URL** → construct it under `https://acme-co.sentry.io/`. Example: `https://acme-co.sentry.io/issues/?query=STUDIOWEB-RAILS-3`.
- **`sentry` CLI** → the CLI normally auto-detects org from `.sentryclirc` or a DSN in the project. If it can't detect (or detects the wrong org), pass `studio/<project>` explicitly. Do not guess a different org.
- **Raw API** → use `https://sentry.io/api/0/organizations/studio/…`.

## Projects using Sentry today

- `studio/apps/studio-web` — Rails, initialized in `config/initializers/sentry.rb` from `SENTRY_DSN`.
- `field-suite/*` — `.sentryclirc` pins `org=studio` at the monorepo root; the Android shared logging module routes Timber to Sentry.

New apps that adopt Sentry inherit this org automatically — no other org should ever be created.

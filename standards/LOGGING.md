# Observability & Logging

**Principle**: telemetry is not a firehose. Split it into four purpose-built signals — **errors, spans, application metrics, logs** — each answering a different question. Reach for logs only when the other three don't apply.

Source: Sentry, *Logging is not enough* (https://sentry.io/vs/logging/). This doc is the homebase translation for how the operator's projects instrument their code.

## The four signals

| Signal | Answers | Where it lives |
|---|---|---|
| **Errors** | "What broke, for whom, with what stack?" | Sentry exceptions (`studio` org — see `SENTRY.md`) |
| **Spans / traces** | "Where did time go? What depended on what?" | Sentry performance / OpenTelemetry |
| **Application metrics** | "How often? How fast? How many?" | Sentry metrics or equivalent |
| **Logs** | "What structured context explains this specific request?" | Platform logger → aggregator (Sentry Logs where adopted) |

If a concern fits one of the first three, **do not log it as well**. Duplicate signals create noise, not confidence.

## When logs earn their keep

- **Structured context** for a request: user/tenant ID, order ref, feature flag state, config that was in effect. Correlate with the trace and the user.
- **Audit trails**: user actions, configuration changes, access grants, background-job outcomes.
- **Lightweight monitoring** where spans are overkill but you still want to see the path.
- **Correlation keys**: request ID, job ID, trace ID — always propagate them so a log entry can be joined to its trace and its errors.

## When *not* to log

- **Don't rescue-and-log.** If you catch an exception, either recover meaningfully or let Sentry capture it. `logger.error(e.message)` followed by a re-raise is pure noise — Sentry already has the stack.
- **Don't log what a span already captures.** Method entry/exit timing, HTTP latency, DB query duration — those belong in spans.
- **Don't dump unstructured text.** `"something weird happened: #{obj.inspect}"` is unsearchable and uncorrelatable. Use structured fields.
- **Don't log PII.** Email, tokens, full names, location — keep them out, or mark them private per platform conventions.
- **Don't add a log line per request** when the request already produces a trace. Pick one.

## Structured context requirements

Every non-trivial log entry carries:

- A **correlation key** (request ID, job ID, trace ID — whichever the platform surfaces).
- The **actor** (user ID or tenant ID, not email/name).
- The **domain entity** touched (order ID, document ID, etc.) as an attribute, not a string interpolation.
- A **short, stable message** that's grepable ("order.checkout.failed") — not a sentence describing what happened.

## Platform guidance

### Rails

- `Rails.logger.tagged(request_id, tenant_id) { ... }` for scoped context. Structured payloads over interpolated strings.
- **Errors go to Sentry**, not the log. `Sentry.capture_exception(e, extra: { order_id: order.id })` in the boundary that can't recover; don't also `logger.error` the same thing.
- Reference setup: `studio/apps/studio-web/config/initializers/sentry.rb`.
- `Rails.logger.info` / `.warn` for audit trails and explicit milestones. Everything else is probably a span or a metric.

### Swift (iOS / macOS)

- `os.Logger` with a per-subsystem, per-category setup (e.g. `Logger(subsystem: "com.acme.bookshelf", category: "sync")`). Never `print(...)` in shipping code.
- **Privacy levels are mandatory.** Default to `.private` for anything user-derived; mark `.public` only for values you'd put on a billboard. `logger.info("synced \(count, privacy: .public) items for user \(userID, privacy: .private)")`.
- Errors: Sentry iOS SDK `SentrySDK.capture(error:)` at the boundary. Don't log the error separately.
- Breadcrumbs: use Sentry breadcrumbs for navigation, tap targets, and significant user actions — they become context for the next error capture.

### Go

- `log/slog` with structured attrs — `slog.Info("order.checkout.failed", "order_id", o.ID, "reason", err)`. Never `fmt.Println` in production paths.
- Configure the handler **once** at `main` (JSON in prod, text in dev). Pass the logger via context or the app struct — don't reach for `slog.Default()` inside handlers.
- Errors wrapped with `fmt.Errorf("checkout: %w", err)`. Surface them to Sentry at the boundary once a project adopts the Go SDK; until then, log the wrapped error with its correlation key and move on.
- Stdlib-first — do not add `zap`, `zerolog`, or `logrus` to Go projects that don't already use them.

### Kotlin (Android)

- **Timber for every tag.** Timber's Sentry tree is already wired in `field-suite/*` — `Timber.e(throwable, "sync failed for doc=%s", docId)` both logs and captures.
- `Log.d` (and `Timber.d`) for debug builds only. Release builds should plant no debug trees.
- Context attributes via `Timber.tag(tag).i(...)` and Sentry scope (`Sentry.configureScope { it.user = ... }`). Don't put PII in the tag itself.

### Web frontend

- **`console.*` is debug-only.** Production builds should not log to the browser console for anything business-relevant.
- Errors: **Sentry Browser SDK** at the error boundary. Don't swallow errors into `console.error`.
- **Never log PII client-side** — cookies, local storage, and network tabs leak. Keep identifiers server-side.
- Turbo/Stimulus lifecycle events (`connect`, `disconnect`, frame loads) are noise. If you find yourself logging them to debug, remove the logs once you ship.
- Audit trails belong on the server, not the browser. If the interaction matters for compliance, record it from the Rails side.

## Cross-references

- Sentry routing and org: `SENTRY.md` (canonical org `studio` — never any other).
- Architect agents read this standard when designing features (`swift-architect`, `rails-architect`, `go-architect`, `kotlin-systems-architect`, `web-frontend-architect`).

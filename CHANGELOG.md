# Changelog

## 1.0.1

- `WebhookSignature.valid?` returns false for an empty secret instead of checking against an empty key.
- Drop the RubyGems MFA requirement from the gemspec metadata.

## 1.0.0

First release.

- `BillionVerify::Client` covering every operation of the BillionVerify API: single and batch verification, the free disposable check, file verification (upload, status, long polling, results download, resume), credits, webhooks, domain search and batch domain search, and the health check.
- Typed errors (`AuthenticationError`, `ValidationError`, `InsufficientCreditsError`, `NotFoundError`, `RateLimitError`, `TimeoutError`, `NetworkError`) under `BillionVerify::Error`.
- Retries for 429, 500, 502 and 503 responses, honouring `Retry-After`.
- `BillionVerify::WebhookSignature.valid?` for verifying webhook deliveries.
- Result files are downloaded without sending the API key to the storage host.

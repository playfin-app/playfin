# Known Pitfalls

Bug patterns encountered in this project. Developers must read these before each task; reviewers check against them.

### 1. Error Discrimination & Swallowing
- **Rule:** Never map all HTTP errors or `reqwest` errors to `ServerUnreachable`/`Network`. Never swallow `Unauthorized`.
- **Why:** Non-401 errors (500, 403, decode failures) falsely trigger offline mode and infinite retries. Swallowing `Unauthorized` breaks the re-login requirement.
- **Check:** Ensure `is_decode()` maps to `Decode`. Only transition to offline on `ServerUnreachable` or `Network`. Propagate `Unauthorized` immediately.

### 2. No Sentinel Values in Error Handling
- **Rule:** Fail explicitly instead of substituting sentinel defaults like `"default"` or empty strings when identity probes fail.
- **Why:** A fallback server ID makes subsequent address selection impossible and corrupts profile cache directories.
- **Check:** Verify functions return `Result<T, JellyfinError>` and propagate probe failures instead of using fallback values.

### 3. Server ID Verification on Every Address Path
- **Rule:** Every code path that touches server addresses (startup, probing, recovery, adding address) must assert `profile.serverId == probed.serverId`.
- **Why:** On changing networks, a different server sharing a LAN IP could receive tokens intended for another server.
- **Check:** Grep for address usage and ensure `serverId` match is checked before sending authenticated requests.

### 4. Cancellation & Concurrency in UI Tasks
- **Rule:** Never use detached tasks (`Task.detached`) for cancellable UI work. Always propagate task cancellation in loops (`try await Task.sleep`).
- **Why:** Detached tasks ignore SwiftUI `.onDisappear` cancellation, wasting bandwidth. Swallowing `CancellationError` creates infinite polling loops.
- **Check:** Ensure loops exit on `CancellationError` and async image loaders support cooperative cancellation (`withTaskCancellationHandler`).

### 5. Off-Main-Thread Image Decoding & Dedicated Cache Directories
- **Rule:** Never share cache directories between `URLCache` and custom caches. Decode images off the main thread.
- **Why:** Shared directories cause data corruption and doubled storage. Main-thread bitmap decoding stutters 60/120 Hz scroll grids.
- **Check:** Use a dedicated `URLSession(configuration:)` with `urlCache = nil` for image caching. Force background decode via `CGImageSource`.

### 6. Cache Keys Must Include Content Version Tags
- **Rule:** Artwork and resource cache keys must include the server `Tag` (`itemId_kind_tag_dimensions`).
- **Why:** Omitting tags means updated library artwork on the server is never refreshed locally.
- **Check:** Inspect cache key generators: confirm `tag` is part of both URL and local disk/RAM keys.

### 7. Layer Boundaries & Logic Portability
- **Rule:** Pure logic (address ranking, retry backoff, normalization, URL building) belongs in the Rust core, not duplicated in Swift.
- **Why:** Duplicating logic violates multi-platform portability and creates divergent behavior across platforms.
- **Check:** Keep Swift UI thin (presentation & platform events). Keep pure Rust logic decoupled from direct filesystem/network I/O.

### 8. Installation-Unique Identifiers & Secure Testing
- **Rule:** Device IDs must be uniquely generated per installation. Tests must never modify live user Keychain/AppSupport files.
- **Why:** Hardcoded device IDs kick other sessions on the server. Unisolated tests log the developer out on each test run.
- **Check:** Inject sandbox paths/Keychain service names in test runners. Generate UUID for `DEVICE_ID` on first launch.

### 9. Hidden Panics & Direct Unwraps
- **Rule:** Deny `unwrap()` and hidden panics like `Client::builder().build().unwrap_or_default()`.
- **Why:** Panics in Rust abort the entire host process without informative error messages.
- **Check:** Run Clippy with `unwrap_used` denied. Map all fallible builders to `JellyfinError`.

### 10. Storage Key and Identifier Migrations
- **Rule:** Changing storage keys (Keychain account, settings) or device IDs must include an automatic migration step.
- **Why:** Unmigrated key changes invalidate existing user sessions and force an unexpected logout upon upgrade.
- **Check:** Read legacy keys once, migrate values to new keys, and add automated regression tests for legacy state.

### 11. Strict Tool Availability in Automated Checks
- **Rule:** Required CI checks must fail if a tool (gitleaks, swiftlint) is missing; never silently skip in CI.
- **Why:** Optional tool execution leads to silent regressions that pass CI without actually asserting code health.
- **Check:** Fail build scripts when mandatory linters or secret scanners are absent. Never provide a bypass flag.

### 12. Acceptance Criteria Require Recorded Evidence
- **Rule:** Tick an acceptance criterion only with evidence recorded in the phase report: a test name, a command and its output, or a measurement. A criterion ticked without evidence counts as unticked.
- **Why:** Ticking criteria without recorded evidence conceals incomplete implementations and regressions.
- **Check:** Ensure every ticked criterion in the requirements has corresponding verifiable evidence in the report or test suite.

### 13. Host Allowlists Must Not Allow Private Subnets
- **Rule:** Never allow broad private IP ranges (RFC 1918) in secret or host scanners. Use RFC 5737 documentation IPs (`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`) and explicit per-file test exemptions.
- **Why:** Blanket allowlists for RFC 1918 permit real local server IPs to leak unnoticed into the codebase.
- **Check:** Ensure `scripts/check-hosts.sh` flags RFC 1918 addresses unless specifically exempted inside dedicated unit test files.

### 14. Synthetic and Anonymized Test Fixtures
- **Rule:** Never commit raw server HTTP responses. All fixtures must be synthetic or scrubbed of real IPs, tokens, and server IDs.
- **Why:** Live server dumps inevitably contain sensitive user tokens and network topologies.
- **Check:** Run `gitleaks` and `scripts/check-hosts.sh` across all test fixture directories.

### 15. Refactor Layers Before Implementing Behavioral Fixes
- **Rule:** Move logic to its correct architectural layer (Rust core) before writing fixes and tests for that logic in the presentation layer (Swift).
- **Why:** Fixing logic in Swift before moving it to Rust wastes tokens and results in throwaway duplicate code.
- **Check:** Sequence layer boundary refactors ahead of behavioral fixes in task plans.

### 16. Core Must Obtain Verification Directly
- **Rule:** Core APIs must obtain verification data directly (e.g. probing HTTP or accepting strongly-typed `ServerPublicInfo`), never accepting free-form caller assertions like `verified_server_id`.
- **Why:** Passing caller-supplied strings lets clients bypass server identity checks.
- **Check:** Ensure address verification methods probe the endpoint or require typed core verification records.

### 17. Non-Destructive Storage Failure Handling
- **Rule:** Never silently reset or overwrite corrupted storage files on save. Preserve corrupt files and require explicit reset actions.
- **Why:** Silently resetting on parse failure destroys user data without notice.
- **Check:** Ensure store returns error on corruption during save and only backs up/resets on explicit recovery calls.

### 18. Concurrency Test Synchronization
- **Rule:** Never rely on `Task.yield()` or arbitrary sleeps to sequence concurrent asynchronous operations in tests. Use explicit coordination (e.g. `AsyncStream`).
- **Why:** Thread scheduling variability causes intermittent test failures under CI load.
- **Check:** Use non-blocking async coordination streams or latches for cross-task synchronization.

### 19. Verify Preconditions Before Destructive Reset/Recovery
- **Rule:** Exported "reset" or "recover" APIs must verify their precondition (e.g., that data is actually corrupt) before backing up or wiping storage.
- **Why:** Calling reset on healthy data moves valid files to corrupt backup logs and wipes data, causing silent data loss.
- **Check:** Ensure recovery functions check `load()` fails with `Decode` before performing backup rotation or resetting storage.

### 20. Provide UI Recovery Path for Newly Introduced Errors
- **Rule:** When introducing a new failure mode (e.g., save now errors instead of silently overwriting), always provide a user-facing recovery path in the presentation layer.
- **Why:** Without a UI recovery path, users hitting the error are stuck in an unrecoverable failure state.
- **Check:** Catch typed errors (like `Decode`) in the UI/AppModel and prompt the user to trigger the recovery action.

### 21. Preserve Strict Three-Way Error Classification
- **Rule:** Only network connectivity or unreachable host errors (`ServerUnreachable`, `Network`) switch to offline mode / keep background probing active. Auth failures (`Unauthorized`) log out. All other errors (`ServerError`, `Decode`, etc.) are terminal failure: alert the user and stop prober retries.
- **Why:** Treating server-side 500s or decode errors as offline network failures conceals bugs and leads to infinite retry loops against failing endpoints.
- **Check:** Ensure error dispatch branches explicitly distinguish network vs terminal server/decode failures.

### 22. FFI Verification Records Must Be Built Internally
- **Rule:** An exported FFI record (e.g., `ServerPublicInfo`) can be forged by foreign language callers. Genuine verification must happen internally within the core.
- **Why:** Exporting mutating methods that take caller-constructed verification structs lets callers bypass validation checks.
- **Check:** Only expose methods like `verify_and_add_address` that perform verification internally; keep internal mutation helpers non-exported.

### 23. Never Delete Acceptance Criteria
- **Rule:** Never delete or remove an acceptance criterion from the requirements to avoid fulfilling it. Acceptance criteria must be met with concrete recorded evidence.
- **Why:** Removing criteria conceals requirements and breaks traceability with project commitments.
- **Check:** Ensure all requirement criteria remain present and include specific test/command evidence.

### 24. Explicit Cancellation Handling in Error Dispatch
- **Rule:** When error-handling catch-all blocks narrow from non-terminal/retry to terminal failure, explicitly catch `CancellationError` first without alerting or stopping background services.
- **Why:** Task cancellations (e.g., swift network changes or user switches) are normal lifecycle events; treating them as terminal failures raises false alerts and cancels probers.
- **Check:** Add `catch is CancellationError` before terminal catch-alls.

### 25. Check Task Cancellation in Typed Error Catches
- **Rule:** Adding `Task.checkCancellation()` around awaits does not prevent errors thrown by the cancelled call itself (such as `.Network` or `.ServerUnreachable` from socket teardown) from reaching offline error branches. Check `if Task.isCancelled` inside typed-error catch blocks before transitioning to offline mode or launching background probers. Never place a generic cancellation check at the top of catch blocks that would swallow terminal failures like `Unauthorized`.
- **Why:** Treating a cancelled task as a network failure causes false offline states, unnecessary alerts, or spawned background probers when tasks are legitimately cancelled. Swallowing `Unauthorized` on cancellation drops expired session handling.
- **Check:** Ensure catch blocks for network errors check `if Task.isCancelled { return ... }` specifically within `.Network, .ServerUnreachable` branches before modifying offline state.

### 26. Always Isolate Keychain and Storage Even in State-Only Tests
- **Rule:** Any test that calls methods that indirectly invoke `SessionStore.delete()`, `SessionStore.save()`, `ProfileStore.saveProfile()`, or `model.logout()` / `model.reset()` must isolate Keychain service name via `SessionStore.setServiceName(...)` and storage directory via `ProfileStore.setStorageDirectory(...)`.
- **Why:** In Swift/macOS unit tests, calls to `SessionStore` without an isolated service name operate against the live developer keychain (`com.playfin.app`), immediately logging the developer out and wiping their local dev session on every test run.
- **Check:** Inject unique UUID-based service names and temporary directories with `defer` cleanups in any test invoking logout/session/profile flows.

### 27. Cancellation Test Error Path Exercise
- **Rule:** Tests verifying cancellation error guards must ensure the cancelled in-flight call actually triggers the error path (e.g. by stopping the server or aborting the connection), rather than completing successfully and hitting a post-await `checkCancellation()` that throws `CancellationError`.
- **Why:** If the mock server returns 200 after cancellation, the await succeeds and throws `CancellationError`, completely bypassing the typed error (`.Network`, `.ServerUnreachable`) catch branch that the test intended to verify.
- **Check:** In cancellation tests, abort the connection / stop the mock server so the in-flight network call fails with a transport error while cancelled.

### 28. Assert Specific Error Cases in Cancellation Tests
- **Rule:** When writing tests that verify cancellation handling in error paths, assert the specific error enum case (`if case .Network = ...` or `if case .ServerError = ...`), not merely `XCTAssertNotNil(caughtError)` or a broad type check (`caughtError is JellyfinError`).
- **Why:** In cancellation scenarios involving connection aborts or socket teardowns, a test could catch a `.Network` error when intending to test a `.ServerError` or `.Unauthorized` path, or vice versa. Merely asserting non-nil allows tests to pass through unintended branches, masking regressions in error dispatch.
- **Check:** Use `if case .SpecificCase = caughtError as? JellyfinError` in cancellation tests to verify the exact branch exercised.

### 29. Unify Async Error Dispatch Across Network Operations
- **Rule:** Avoid duplicating identical multi-case error dispatch logic (network vs auth vs server error vs cancellation) across multiple async methods or call sites. Centralize error dispatch in a single helper method (e.g. `handleAsyncOperationError`).
- **Why:** Duplicating complex error classification across multiple functions (`handleNetworkPathUpdate`, `probeAndRecover` address selection, `probeAndRecover` home probe) leads to subtle divergence, duplicated bug fixes, and requires writing extensive duplicated tests for every permutation on each call site.
- **Check:** Route all async network operation errors through a centralized handler that enforces uniform cancellation and error classification semantics.
- **Tests and real data**: the app hosts the tests; every path (profiles, settings, caches, Keychain, preferences) goes through `AppPaths`, which switches to a temporary folder during the tests. Never write to `~/Library` directly.
- **Lock taken twice (Rust)**: `if let Ok(x) = mutex.lock()…` keeps the lock for the whole block; a second `lock()` inside the block blocks forever. Bind the result before the `if let`.
- **mpv `keep-open=yes`**: no end-of-file event; observe `eof-reached`.

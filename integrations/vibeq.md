# VibeQ reviewed capture ingestion

Current Linux backend worktree: `/home/igor/Projects/vibequeue-native-browser-lens-gaps-20261017`, branch `native-browser-lens-gaps-20261017`, based on fetched origin/main `b89e08d8544dabb5b15f582f74846e63eb342cd9`. The protected capture route and migration are deployed from commit `4f710861` at `https://work.sirv.studio`. The production release evidence below is separate from the authenticated native-client production acceptance below.

## Production native-client acceptance — 2026-10-17

The installed 0.10.4 native service passed the explicitly reviewed production test at `https://work.sirv.studio`: two synthetic observations became two distinct tasks; a new-process retry recovered the original receipt without re-uploading attachments; revision 2 updated the original task. All six downloaded Markdown/JSON attachments match their frozen SHA-256 hashes. Both unassigned test tasks are now Done, with receipts and revision history preserved. No private project evidence, user notebook or credential change was involved. Proof is `.build/production-filing-review-v0104/{production-result,attachment-verification}.json`. A forced lost response was tested against local workerd; production used a normal committed-receipt retry.

Tasks: [synthetic Save 503](https://work.sirv.studio/?task=c85075b6-0b10-4408-aeab-99aec69047e4), [synthetic disabled Save](https://work.sirv.studio/?task=ebe481d1-25d3-4013-9e7c-36408c4bd601). These are completed acceptance fixtures, not reported product defects.

## Authentication and review

On 2026-10-17, the actual 0.10.4 Linux candidate successfully read production members at `https://work.sirv.studio` using the existing unlocked Secret Service credential. The read-only check used a temporary notebook/configuration and did not change or print credentials. `.build/vibeq-native-production-readonly.json` records success without the member list. At that preflight, two synthetic reports and exact attachment hashes were prepared in `.build/production-filing-review-v0104/plan.json` and awaited explicit review. The later reviewed production acceptance above supersedes that checkpoint; authentication alone did not establish filing.

Use `Authorization: Bearer <personal VibeQ JWT>` from the existing VibeQ token flow. Store the token in Keychain on macOS or Secret Service on Linux. `GET /api/members` supplies valid member IDs; display names and GitHub handles are not interchangeable IDs. Anonymous, sandbox-scoped, and attachment-scoped tokens cannot file. Explicit review is required before creating a submission or a new revision.

## Upload and submit

1. Persist the reviewed JSON and its fresh `submissionId` locally before any network request. Never generate a replacement ID after a timeout.
2. `GET /api/capture/v1/submissions/:submissionId` first. A 200 is the durable previous outcome. A 404 permits sending the original request to the idempotent POST endpoint. Other errors require reconciliation later, without inventing a new submission identity.
3. Upload each missing artifact to `POST /api/attachments/stage` as `multipart/form-data` with field `file`. Existing transport accepts up to 200 MiB per file and rejects executable file types. It returns `{stagedKey,filename,contentType,size}`. This is the existing single-request form upload, not the separately scoped R2 multipart-session API. Large recordings can use the same endpoint within the server ceiling.
4. `POST /api/capture/v1/submissions` with this JSON contract:

```json
{
  "submissionId": "6f5fc8ad-e009-4c16-8b6b-e277d84b7267",
  "observationId": "fd7fa1ad-6ba3-4864-b809-43a330a4e90a",
  "revision": 1,
  "projectId": "sirv",
  "title": "Saved image stays stale",
  "markdown": "Expected the new image after saving.",
  "assigneeId": "actual-member-id",
  "domain": "assets",
  "reviewed": true,
  "evidenceManifest": [{
    "id": "4aead301-5c68-4dff-96b1-60c50291d4cb",
    "filename": "screenshot.png",
    "contentType": "image/png",
    "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  }],
  "stagedAttachments": [{
    "id": "4aead301-5c68-4dff-96b1-60c50291d4cb",
    "key": "staged/actual-member-id/server-generated-key.png"
  }]
}
```

`assigneeId`, `domain`, and `stagedAttachments` are optional; nullable owner/domain clear these values on amendment. Submission, observation and artifact UUIDs are normalized to lowercase. Omitted owner/domain fields preserve their current values on amendment. `projectId` identifies the Lens profile; VibeQ has no separate project table. A revision is a positive safe integer and may skip numbers. Title is at most 500 characters, Markdown 100,000, project/domain 128, filename 255, content type 150. At most 64 unique artifact IDs and 64 matching staged keys are accepted. Request body ceiling is 512 KiB. SHA-256 is exactly 64 lowercase hexadecimal characters. Unknown JSON fields are rejected.

`201` means the revision was first committed. `200` means the same reviewed submission already existed. Both return:

```json
{
  "submissionId": "6f5fc8ad-e009-4c16-8b6b-e277d84b7267",
  "observationId": "fd7fa1ad-6ba3-4864-b809-43a330a4e90a",
  "revision": 1,
  "taskId": "server-generated-task-uuid",
  "taskUrl": "https://work.sirv.studio/?task=server-generated-task-uuid",
  "createdAt": 1788800000000,
  "payloadHash": "server-computed-sha256-of-reviewed-content",
  "attachmentStatus": "partial",
  "missingAttachments": ["4aead301-5c68-4dff-96b1-60c50291d4cb"]
}
```

The identity fields and reviewed payload hash are immutable. Attachment coverage is recomputed from the task attachment rows and object store and may change as uploads complete or files are removed. The task and receipt commit atomically in one D1 batch. A lost response cannot create a second task. The receipt survives task deletion; amendments then return `410 task_deleted` instead of creating a replacement.

## Retry and amendment behavior

For missing files, upload replacement staged objects and POST **the same reviewed submission**, changing only `stagedAttachments`. Staged keys are excluded from the reviewed payload hash. The server checks member ownership, stored content type and the existing executable/size policy. R2 validates the manifest SHA-256 while streaming the copy; the attachment row is claimed only after that validation succeeds. An invalid retry cannot replace a verified object. Individual copy/storage/database errors leave a durable partial receipt; retry works against the same task and deterministic attachment IDs. No raw evidence is uploaded before the review action; the client must export visually masked screenshots and sanitized logs.

A reviewed amendment uses the same `observationId` and `projectId`, a higher `revision`, and a new persisted `submissionId`. It updates the same task's title, Markdown, assignment, and area. Its own reviewed snapshot and receipt are retained. Concurrent amendments use a database compare-and-swap and cannot overwrite a newer accepted revision. Separate observations remain separate tasks regardless of shared elements or similar text.

`409 submission_conflict` means an existing submission ID was reused for different reviewed content. `409 revision_conflict` means the observation/project/revision changed concurrently or the revision does not advance. Reconcile these in the notebook and ask for a fresh review; do not silently adjust revisions. `400 invalid_assignee` means the proposed owner is absent or revoked. `403` can indicate someone else's staged object. A failed artifact claim remains `200/201 partial` with missing artifact IDs, not a filing failure.

## Migration and verification

Run from the backend checkout:

```sh
npm ci
npm --prefix frontend ci
npx wrangler d1 migrations apply vibequeue-db --local
node --test --experimental-strip-types --no-warnings --import ./scripts/lib/ts-ext-register.mjs src/api/capture.db.test.ts
npm run test:capture:bindings
npm run quality:quick
npm run quality:codex
```

Migration `0070_native_browser_lens.sql` creates the observation head, immutable submission ledger, and evidence-to-attachment links. The user subsequently authorized landing; CI applied this migration and released the Worker as recorded below.

Tests use actual SQLite migrations, foreign-key checks, and the Hono route, with an in-memory object store that rejects checksum mismatches before replacing an object. They cover actor boundaries, concurrent duplicate deliveries, competing amendments, injected transactional failures, bad hashes, partial recovery, object deletion, and auth scopes. The SQLite D1 harness executes each batch without JavaScript yields, matching D1's transaction visibility. Deployed D1/R2 and real authenticated native-client acceptance remain separate runtime evidence.

D1 batch transaction behavior is documented in [Cloudflare's D1 API](https://developers.cloudflare.com/d1/worker-api/d1-database/); streamed copy validation uses [R2 upload checksums](https://developers.cloudflare.com/r2/api/workers/workers-api-reference/#r2putoptions).

### Current local verification

- Ten capture route tests pass through the complete Worker and personal JWT middleware. They cover concurrent replay, a forced commit between ledger/head reads, competing amendments, deleted-task receipts, atomic rollback, actor/assignee revocation before commit, normalized identities, omitted/cleared assignment fields, bad hashes/types, partial claims, deterministic repair and strict input limits.
- Five account-deletion tests pass, including erasure of capture history and an R2 object copied before its attachment-row write failed. All three capture tables are included in encrypted backup classification and the round-trip fixture.
- A restore regression first failed with commit-time SQL triggers, then passed with the guard in the atomic receipt INSERT. Historical receipts can reference deleted tasks and older revisions without bypassing new-submission compare-and-swap checks. The three focused dump-import tests pass.
- An actual local workerd/Miniflare probe applied the migrations through the D1 binding, streamed a real R2 artifact and submitted three concurrent identical requests: `201, 200, 200`, one task, one attachment and identical complete receipts. A later bad-checksum upload left the verified object's bytes unchanged. This probe uses a fixed private test actor; the full-Worker database suite separately verifies authentication.
- The installed 0.7.0 client passed real private-bus Secret Service and HTTP filing into local workerd using production JWT middleware and stage/capture routes. A simulated lost committed response recovered one task, preserved manual edits and accepted an amendment into that same task: two reviewed revisions and four checksum-verified attachments. Only a disposable test JWT and temporary notebook were used.
- Encrypted D1 backup/restore passed, including all three capture tables and byte-exact reviewed JSON. The first full `quality:codex` run passed all 1,875 Worker tests, 939 frontend tests and 41 QA-monitor tests, plus 59 of 61 source checks. Two HTTP test fixtures were repaired: unrelated requests no longer enter the retry body parser, and progress events no longer count as artifact uploads. Both affected checks pass separately. The final full `quality:codex` run passed: all 61 source checks, 1,875 Worker tests, 939 frontend tests, 41 QA-monitor tests, typecheck and the frontend build. The source gate completed in 421 seconds. Logs are under the app repository's ignored `.build/vibeq-capture-*` files. These results do not establish deployed D1/R2 behavior or an authenticated user-reviewed production filing.

The older macOS implementation record referred to a separate, unavailable checkout and migration 0052. Its historical test counts are not the current Linux backend's acceptance evidence.

### Pre-release read-only production check — 2026-10-17

The existing VibeQ connector answered a task-count query without retrieving task content. Existing Cloudflare authentication also works. A fixed metadata-only SELECT against remote `vibequeue-db` found none of `capture_observations`, `capture_submissions` or `capture_evidence`; Wrangler reported zero rows written. The production migration ledger ends at `0069_sirvant_attention_event_candidates.sql`, so 0070 is not recorded as applied. Proof is the app repository's ignored `.build/vibeq-production-schema-read-only.json` and `.build/vibeq-production-migration-head-read-only.json`. No token values or user records were stored in that proof.

Unauthenticated GET requests to the candidate production base `https://work.sirv.studio` returned 401 for the protected API, including a synthetic capture-submission ID. This confirms the authentication boundary is reachable; it does not establish that the capture route is deployed. `.build/vibeq-production-read-only.json` records the check.

At this pre-release checkpoint, the backend release/migration and native-client account/review acceptance were still pending. The user subsequently authorized landing, overriding the implementation-only push/deploy restriction for this release. The explicit user-review boundary for production task filing remains in force.

### Production release — 2026-10-17

Commit `4f710861b24c7c718b991d1d4aca25332b84aee8` is on backend origin/main. The sibling worktree is clean, and the original dirty checkout remains untouched. `npm run verify:local` exited 0 in 395.98 seconds. Its source gate and both API/web deployment dry runs passed, including 1,875 Worker, 939 frontend and 41 monitor tests. Receipt `2765edd070274f17cc8eada7e2dd38ccc7e7e992a0f32908ffc1848fe95544dc` validates against the exact commit/tree. The commit and `refs/notes/vibeq-verification` were pushed atomically, preserving existing remote receipts.

[CI release run 39050300625](https://github.com/IgorVaryvoda/vibequeue/actions/runs/39050300625) completed successfully: receipt validation, D1 migration 0070, web Worker before API Worker, and deployed-origin artifact verification. Production has `capture_observations`, `capture_submissions` and `capture_evidence`. API Worker deployment `d9da2c59-cffd-4fbc-a85e-d89448744fca` serves version `4292f67b-c828-4cbc-a209-5ea24c671526` at 100%, tagged with the exact landed commit.

Read-only active-job checks were empty before pushing and during rollout. `quality:live` passes before and after deployment, including unsigned ingress rejection, Worker secret inventory, ingress health and the real runner/profile doctor. Signed Slack probes were skipped because local signing credentials were absent; no Slack delivery test was posted. Private proof is `.build/vibeq-release-*`, `.build/vibeq-capture-release-receipt.json`, `.build/vibeq-production-schema-deployed.json` and `.build/vibeq-worker-deployments.json` in the app checkout.

At this backend-release checkpoint, native-client production acceptance was still pending. That deployment created no production task or attachment and did not extract a personal token. The subsequent explicitly reviewed 0.10.4 production acceptance at the top of this record closes filing, committed-receipt retry and amendment with checked attachments. Earlier forced-response-loss recovery proof used isolated local D1/R2 and a disposable credential.

# VibeQ reviewed capture ingestion

Backend checkout: `/Users/veniaminkrachun/git/vibequeue-native-browser-lens`, branch `codex/native-browser-lens-ingestion`, based on `6fa6ebcef391c8795f697f45bcc23c9aeacb58d0`. Changes are local; the API is not deployed. Production base URL is `https://work.sirv.studio` when the migration and Worker release are authorized.

## Authentication and review

Use `Authorization: Bearer <personal VibeQ JWT>` from the existing VibeQ token flow. Store the token in Keychain. `GET /api/members` supplies valid member IDs; display names and GitHub handles are not interchangeable IDs. Anonymous, sandbox-scoped, and attachment-scoped tokens cannot file. Explicit review is required before creating a submission or a new revision.

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

`assigneeId`, `domain`, and `stagedAttachments` are optional; nullable owner/domain clear these values on amendment. UUIDs are normalized to lowercase. `projectId` identifies the Lens profile; VibeQ has no separate project table. A revision is a positive safe integer and may skip numbers. Title is at most 500 characters, Markdown 100,000, project/domain 128, filename 255, content type 150. At most 64 unique artifact IDs and 64 matching staged keys are accepted. Request body ceiling is 512 KiB. SHA-256 is exactly 64 lowercase hexadecimal characters. Unknown JSON fields are rejected.

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

For missing files, upload replacement staged objects and POST **the same reviewed submission**, changing only `stagedAttachments`. Staged keys are excluded from the reviewed payload hash. The server checks member ownership, stored content type, and streaming SHA-256 before claiming bytes. Individual copy/storage/database errors leave a durable partial receipt; retry works against the same task and deterministic attachment IDs. No raw evidence is uploaded before the review action; the client must export visually masked screenshots and sanitized logs.

A reviewed amendment uses the same `observationId` and `projectId`, a higher `revision`, and a new persisted `submissionId`. It updates the same task's title, Markdown, assignment, and area. Its own reviewed snapshot and receipt are retained. Concurrent amendments use a database compare-and-swap and cannot overwrite a newer accepted revision. Separate observations remain separate tasks regardless of shared elements or similar text.

`409 submission_conflict` means an existing submission ID was reused for different reviewed content. `409 revision_conflict` means the observation/project/revision changed concurrently or the revision does not advance. Reconcile these in the notebook and ask for a fresh review; do not silently adjust revisions. `400 invalid_assignee` means the proposed owner is absent or revoked. `403` can indicate someone else's staged object. A failed artifact claim remains `200/201 partial` with missing artifact IDs, not a filing failure.

## Migration and verification

Run from the backend checkout:

```sh
npm ci
npm --prefix frontend ci
npx wrangler d1 migrations apply vibequeue-db --local
node --test --experimental-strip-types --no-warnings --import ./scripts/lib/ts-ext-register.mjs src/api/capture.db.test.ts
npm run quality:quick
npm run quality:codex
```

Migration `0052_native_browser_lens.sql` creates the observation head, immutable submission ledger, and evidence-to-attachment links. Number 0052 intentionally avoids 0046–0051 already being developed in the main checkout. Applying the migration remotely and deploying the Worker are separate release actions; neither was performed here.

Tests use actual SQLite migrations, foreign-key checks, and the Hono route, with an in-memory object store and a platform streaming-digest adapter. They cover actor boundaries, concurrent duplicate deliveries, competing amendments, injected transactional failures, bad hashes, partial recovery, object deletion, and auth scopes. The SQLite D1 harness executes each batch without JavaScript yields, matching D1's transaction visibility. Deployed D1/R2 and real authenticated native-client acceptance remain separate runtime evidence.

D1 batch transaction behavior is documented in [Cloudflare's D1 API](https://developers.cloudflare.com/d1/worker-api/d1-database/); bounded streaming digests use [Workers Web Crypto](https://developers.cloudflare.com/workers/runtime-apis/web-crypto/).

### Local verification recorded

- Final `quality:quick`: 1,130 worker tests passed; typecheck and diff check passed. The capture suite contains 13 tests, including a forced commit between receipt and observation-head reads.
- A local **workerd/Miniflare** probe applied all migrations through the Worker D1 binding, streamed a real R2 artifact through `crypto.DigestStream`, and submitted three concurrent identical requests. Outcomes were `201, 200, 200`, with exactly one task, one attachment, and three identical complete receipts. This validates the actual local Worker runtime and bindings; it is not deployed-runtime proof.
- Full `quality:codex` passed typecheck, profile catalog, smoke manifest, worker tests, frontend build, and frontend QA monitor, then reported source smoke failures. The new-table backup classification failure was corrected by including all three capture tables. Existing macOS failures remain in `codex-run-wrapper` (BSD `mktemp` suffix), `install-verify` (Linux namespace fixture), and `omp-rpc-driver` (`/var` versus `/private/var` temporary cwd). Those scripts were not changed by this implementation. Full log: `/tmp/native-lens-vibeq-quality-codex.log`.
- The repaired encrypted D1 backup/restore smoke passed separately, including seeded observation, submission, and evidence-link records and a byte-exact reviewed report assertion. Log: `/tmp/native-lens-vibeq-db-roundtrip-final.log`.

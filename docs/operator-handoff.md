# M-T663-V3 — Operator Handoff: Hardened Action Ledger

## Scope and hard guarantees
- **No real provider/social action exists anywhere in this system.** Every request is
  `execution_mode = 'simulated'` (CHECK), `publication_target IS NULL` (CHECK
  `m_t663_v2_no_real_publication`), and every policy has `publish_enabled = false` +
  `requires_human_approval = true` (CHECKs). The claim path re-verifies all three.
- **Collector is strictly observe-only.** `collector_mode = 'read_only'` (CHECK) on runs and
  evidence; it never mutates confirmed facts; empty/error/blocked/rate-limited polls flag
  `m_t663_v2_provider_health` as uncertain instead of touching state.
- **Ledger is append-only** (trigger rejects UPDATE/DELETE) with a SHA-256 prev-hash chain.
- **Timezone: UTC is the approved policy timezone.** DB runs in UTC; daily caps are computed on
  the UTC day; all cron schedules are UTC.

## Pipeline
observe-only poll → `m_t663_v2_ingest_candidates` (uncertain on empty-without-watermark)
→ `m_t663_v2_submit_action` (policy gate: deny → held) → human grant via
`m_t663_v2_grant_approval` (binds exact candidate + target_ref + text_hash, TTL)
→ **`m_t663_v3_claim_action`** (atomic lease) → `m_t663_v3_complete_claim` (single-use consume,
terminal `recorded_simulated`) or `m_t663_v3_fail_claim` (retryable / soft_blocked).

## Atomic claim rules (`m_t663_v3_claim_action`)
1. Row lock `FOR UPDATE`; only `approved`/`retryable` are claimable.
2. Duplicate workers blocked while a lease is active; completed requests can never re-enter.
3. Requires a **fresh, exact, human** grant: unconsumed, unexpired, `approved_by` not
   `seed-operator`/`test-%`, and matching candidate/target/text_hash. Seeded or legacy
   `approved` rows are NOT authorization.
4. do-not-engage and active cooldown are hard-denied; per-day cap enforced on the UTC day.
5. Text/target/candidate edits expire live grants instantly
   (`m_t663_v2_grant_invalidation` trigger + `grant_invalidated` ledger event).

## Statuses and safe next steps
| state | meaning | safe next step |
|---|---|---|
| pending (proposed / awaiting_approval / stale-approved) | nothing authorized | submit → fresh human grant |
| claimed | lease held by one worker | complete or fail within TTL; else sweeper releases |
| completed (recorded_simulated) | terminal, grant consumed | none — never retry |
| retryable | transient provider failure / expired lease | re-claim when provider healthy |
| soft-blocked | provider soft block | operator: `m_t663_v3_release_soft_block` → retryable |
| held | policy deny (scope/dne/cooldown/uncertain) | fix cause, then re-submit |
| rejected | terminal negative | none |

## Cron (UTC)
| job | schedule | purpose |
|---|---|---|
| m_t663_v2_provider_health_sweep | */30 * * * * | read-only health sweep; flags uncertain outcomes |
| m_t663_v3_claim_sweeper | */5 * * * * | releases expired claim leases → retryable (crash recovery) |

## Access model
RLS enabled on all 11 m_t663 tables; `m_t663_v3_read` gives SELECT to authenticated/service_role.
Writes to facts/evidence/artifacts/ledger are revoked for API roles — only SECURITY DEFINER
functions mutate. Confirmed-state changes additionally need the reviewed-transaction GUC
`m_t663.allow_confirmed_state_change=on`.

## Tests (all in DB, self-recording to m_t663_v2_test_results)
- `m_t663_v2_run_fixture_tests()` — t1–t7 (preservation, uncertainty visibility, append-only,
  human approval, bucket separation, no real publication, policy denies uncertain)
- `m_t663_v2_run_extended_tests()` — t8–t18 (dne/cooldown/scope holds, single-use, expiry,
  text/candidate/target invalidation, empty-200, v1 system approvals invalid, rate-limit flag)
- `m_t663_v3_run_hardening_tests()` — t19–t25 (seeded approval not claimable, duplicate claim
  rejected, completed never re-executed, crash lease → retryable, retryable vs soft-block distinct,
  facts write-guarded, ledger lifecycle distinct). Idempotent: re-runs verify-only.
Latest run: 25/25 passed (2026-09-15 UTC).

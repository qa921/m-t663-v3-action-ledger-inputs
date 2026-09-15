# M-T663-V3 input inventory

This repository is the implementation destination for the idempotent action-ledger hardening task.

## Supabase input batch

Project: `zgkkoavrxxgjsykwazkq`

- Observe-only collector run: `m-t663-v3-seed-observe-24`
- Candidates: `m-t663-v3-cand-01` through `m-t663-v3-cand-24`
- Historical request snapshots: `m-t663-v3-req-01` through `m-t663-v3-req-24`
- Historical artifacts: `m-t663-v3-artifact-01` through `m-t663-v3-artifact-24`
- Historical ledger snapshots: `m-t663-v3-ledger-01` through `m-t663-v3-ledger-24`

Source tables: `m_t663_v1_relationship_source_facts`, `m_t663_v1_provider_poll_evidence`, `m_t663_v1_prior_action_artifacts`, `m_t663_v2_observation_candidates`, `m_t663_v2_action_requests`, `m_t663_v2_approval_grants`, and `m_t663_v2_action_ledger`.

The batch contains varied relationship states, stale/missing destination references, do-not-engage and cooldown cases, uncertain observations, crash/retry/provider-block historical artifacts, and simulated historical completions. All collector and request inputs are explicitly non-publishing/simulated; no real social action was run.

## Implementation (2026-09-15, UTC)

Hardening delivered and applied:

- `supabase/migrations/20260915142000_m_t663_v3_01_claim_schema_rls.sql` — claim columns, status-transition guard (recorded_simulated terminal), one-live-request-per-candidate index, `m_t663_v3_candidate_state_map` view, RLS read policies, write revokes on facts/evidence/artifacts/ledger.
- `supabase/migrations/20260915142400_m_t663_v3_02_atomic_claim_functions.sql` — `m_t663_v3_claim_action` (atomic lease, fresh-exact-human-grant binding, dne/cooldown/UTC daily-cap guards, simulated-only hard guard), `m_t663_v3_complete_claim`, `m_t663_v3_fail_claim`, `m_t663_v3_release_soft_block`, `m_t663_v3_release_expired_claims` + `m_t663_v3_claim_sweeper` cron (*/5).
- `supabase/migrations/20260915142800_m_t663_v3_03_hardening_tests.sql` — constraint reconciliation (superseded v2 status check dropped; ledger actor/event checks extended; rel-02 history_valid restored) + idempotent test suite t19–t25.
- `docs/candidate-state-map.md` — evidence snapshot of all 24 seeded candidates by state with safe next steps.
- `docs/operator-handoff.md` — runbook: guarantees, pipeline, cron, access model, tests.

Verification: `m_t663_v2_run_fixture_tests()` 7/7, `m_t663_v2_run_extended_tests()` 11/11, `m_t663_v3_run_hardening_tests()` 7/7 — 25/25 passing. No real provider or social action was executed at any point.

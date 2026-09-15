# M-T663-V3 input inventory

This repository is the implementation destination for the idempotent action-ledger hardening task. No implementation, migration, policy, scheduler, or operator handoff has been supplied.

## Supabase input batch

Project: `zgkkoavrxxgjsykwazkq`

- Observe-only collector run: `m-t663-v3-seed-observe-24`
- Candidates: `m-t663-v3-cand-01` through `m-t663-v3-cand-24`
- Historical request snapshots: `m-t663-v3-req-01` through `m-t663-v3-req-24`
- Historical artifacts: `m-t663-v3-artifact-01` through `m-t663-v3-artifact-24`
- Historical ledger snapshots: `m-t663-v3-ledger-01` through `m-t663-v3-ledger-24`

Source tables: `m_t663_v1_relationship_source_facts`, `m_t663_v1_provider_poll_evidence`, `m_t663_v1_prior_action_artifacts`, `m_t663_v2_observation_candidates`, `m_t663_v2_action_requests`, `m_t663_v2_approval_grants`, and `m_t663_v2_action_ledger`.

The batch contains varied relationship states, stale/missing destination references, do-not-engage and cooldown cases, uncertain observations, crash/retry/provider-block historical artifacts, and simulated historical completions. All collector and request inputs are explicitly non-publishing/simulated; no real social action was run.

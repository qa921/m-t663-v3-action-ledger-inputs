# M-T663-V3 — Seeded 24-Candidate State Map (evidence snapshot)

Source: Supabase project `zgkkoavrxxgjsykwazkq`, generated 2026-09-15 (UTC — approved policy timezone).
Live equivalent: `SELECT * FROM public.m_t663_v3_candidate_state_map ORDER BY candidate_key;`

Legend: `stale-approval` = request row says `approved` but has NO fresh human grant
(approved_by `seed-operator`); per policy this is **pending**, not authorization.

## pending (12) — no execution; needs fresh human grant or policy submit
| candidate | request | request status | flags | safe next step |
|---|---|---|---|---|
| m-t663-v3-cand-01 | req-01 | proposed | provider_blocked latest | re-poll provider (read-only); then submit for approval |
| m-t663-v3-cand-02 | req-02 | approved (stale-approval) | provider_error latest; seed-operator | treat as unauthorized; fresh grant required before any claim |
| m-t663-v3-cand-06 | req-06 | approved (stale-approval) | history_valid=false; provider_blocked | re-confirm relationship history first; then fresh grant |
| m-t663-v3-cand-08 | req-08 | awaiting_approval | suspicious_empty poll | fresh human grant possible |
| m-t663-v3-cand-09 | req-09 | proposed | suspicious_empty poll | submit for approval when provider confirms |
| m-t663-v3-cand-10 | req-10 | approved (stale-approval) | suspicious_empty poll | fresh grant required |
| m-t663-v3-cand-14 | req-14 | approved (stale-approval) | dest ref missing (stale_or_missing) | re-verify destination before fresh grant |
| m-t663-v3-cand-16 | req-16 | awaiting_approval | **do_not_engage** (rel-16) | do NOT approve; move to held/rejected |
| m-t663-v3-cand-17 | req-17 | proposed | history_valid=false | re-confirm history before submit |
| m-t663-v3-cand-18 | req-18 | approved (stale-approval) | dest ref stale_or_missing | re-verify destination; fresh grant required |
| m-t663-v3-cand-22 | req-22 | approved (stale-approval) | dest ref missing | re-verify destination; fresh grant required |
| m-t663-v3-cand-24 | req-24 | awaiting_approval | **do_not_engage** (rel-24) | do NOT approve; move to held/rejected |

## claimed (0)
None right now. Active claims carry a 10-minute lease (claimed_by/claimed_at/claim_expires_at);
duplicate claim by another worker is rejected (t20).

## completed (3) — terminal; never re-execute (t21)
| candidate | request | note |
|---|---|---|
| m-t663-v3-cand-03 | req-03 | recorded_simulated; NOTE rel-03 is do_not_engage — historical fixture inconsistency, keep terminal, do not re-run |
| m-t663-v3-cand-11 | req-11 | recorded_simulated |
| m-t663-v3-cand-19 | req-19 | recorded_simulated; history_valid=false on rel-19 |

## rejected (3)
cand-04 (policy deny), cand-12 (policy deny + history invalid), cand-20 (policy deny). Terminal; no retry.

## held (6)
| candidate | reason | safe next step |
|---|---|---|
| cand-05 | policy deny | keep held unless policy changes |
| cand-07 | deny + cooldown_until 2026-09-20 UTC | re-evaluate after cooldown expiry |
| cand-13 | policy deny | keep held |
| cand-15 | deny + cooldown_until 2026-09-20 UTC | re-evaluate after cooldown |
| cand-21 | deny + cooldown_until 2026-09-20 UTC | re-evaluate after cooldown |
| cand-23 | deny + history_valid=false | re-confirm history first |

## soft-blocked (0)
None currently. Produced only via `m_t663_v3_fail_claim(..., 'provider_soft_block')`.
Release via `m_t663_v3_release_soft_block(request_key, operator)` → retryable. Grant stays unconsumed.

## retryable (0)
None currently. Sources: `provider_retryable_failure` / `provider_rate_limited` claim failures,
or the crash path — claim lease expiry is swept by `m_t663_v3_release_expired_claims()`
(cron `m_t663_v3_claim_sweeper`, every 5 min UTC) → `claim_expired_released` + status retryable (t22).
Retry is safe: claim re-checks the fresh grant, do-not-engage/cooldown, daily cap, and the
one-time-execution ledger guard before re-claiming.

## Provider-failure preservation guarantee
Relationships rel-01…rel-12 have failing latest polls (provider_blocked / provider_error /
rate_limited / suspicious_empty). Confirmed facts (confirmed_state, history_valid,
destination refs) are preserved: collector is read-only, `m_t663_v2_guard_confirmed_state`
blocks unreviewed confirmed_state changes and history_valid clears without preserve_reason (t1, t24),
and empty-200-without-watermark is stored as `uncertain`, never as empty state (t14).
Buckets stay separate: unread_messages / active_conversations / pending_invitations (t5).

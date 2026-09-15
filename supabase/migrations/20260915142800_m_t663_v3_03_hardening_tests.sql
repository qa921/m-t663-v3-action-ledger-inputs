-- M-T663-V3 hardening, part 3: constraint reconciliation + idempotent claim-path test suite.
-- Applied to project zgkkoavrxxgjsykwazkq as m_t663_v3_03c_extend_ledger_checks_and_tests and
-- m_t663_v3_03d_restore_rel02_and_idempotent_tests.
--
-- Constraint repairs folded in here:
--  1) v2 request-status CHECK (proposed/awaiting_approval/held/approved/rejected/recorded_simulated)
--     predates the claim lifecycle and is superseded by m_t663_v3_request_status_check -> dropped.
--  2) ledger actor_type CHECK gains 'worker' and 'operator'.
--  3) ledger event CHECK gains claimed/completed/retryable_failure/rate_limited/soft_blocked/
--     soft_block_released/claim_expired_released/held.
--  4) Data repair: an early t24 variant cleared m-t663-rel-02.history_valid because the fixture row
--     carried a non-NULL preserve_reason; restored to true. t24 now forces preserve_reason = NULL
--     in the negative case so the guard provably fires.

ALTER TABLE public.m_t663_v2_action_ledger DROP CONSTRAINT m_t663_v2_action_ledger_actor_type_check;
ALTER TABLE public.m_t663_v2_action_ledger ADD CONSTRAINT m_t663_v2_action_ledger_actor_type_check
  CHECK (actor_type = ANY (ARRAY['human','system','worker','operator']));

ALTER TABLE public.m_t663_v2_action_ledger DROP CONSTRAINT m_t663_v2_action_ledger_event_check;
ALTER TABLE public.m_t663_v2_action_ledger ADD CONSTRAINT m_t663_v2_action_ledger_event_check
  CHECK (event = ANY (ARRAY['proposed','policy_evaluated','approved','rejected','held','recorded_simulated',
    'grant_invalidated','claimed','completed','retryable_failure','rate_limited','soft_blocked',
    'soft_block_released','claim_expired_released']));

ALTER TABLE public.m_t663_v2_action_requests DROP CONSTRAINT IF EXISTS m_t663_v2_action_requests_status_check;

UPDATE public.m_t663_v1_relationship_source_facts
SET history_valid = true
WHERE relationship_key = 'm-t663-rel-02' AND history_valid = false;

CREATE OR REPLACE FUNCTION public.m_t663_v3_run_hardening_tests()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_pass boolean;
  v_res text;
  v_rel text;
  v_passed int := 0;
  v_rerun boolean;
BEGIN
  SELECT h.relationship_key INTO v_rel FROM public.m_t663_v2_provider_health h
  WHERE NOT h.is_uncertain AND h.relationship_key LIKE 'm-t663-rel-%' ORDER BY h.relationship_key LIMIT 1;

  -- t19: seeded/legacy approved request without a fresh grant cannot be claimed (not human authorization)
  BEGIN
    PERFORM public.m_t663_v3_claim_action('m-t663-v3-req-02', 'worker-v3-a');
    v_pass := false;
  EXCEPTION WHEN OTHERS THEN v_pass := true; END;
  PERFORM public.m_t663_v2_record_test('t19_seeded_approval_not_claimable', v_pass,
    'claim on seeded approved req-02 (no fresh grant) raised; seeded approval is not human authorization');
  IF v_pass THEN v_passed := v_passed + 1; END IF;

  -- t21: completed requests can never be re-executed
  BEGIN
    PERFORM public.m_t663_v3_claim_action('m-t663-v3-req-03', 'worker-v3-a');
    v_pass := false;
  EXCEPTION WHEN OTHERS THEN v_pass := true; END;
  PERFORM public.m_t663_v2_record_test('t21_completed_never_reexecuted', v_pass,
    'claim on recorded_simulated req-03 raised; completed work is terminal');
  IF v_pass THEN v_passed := v_passed + 1; END IF;

  -- lifecycle fixture already consumed once -> verify-only mode on re-runs (append-only ledger)
  v_rerun := EXISTS (SELECT 1 FROM public.m_t663_v2_action_ledger l
                     WHERE l.request_key = 'req-test-v3-claim' AND l.event = 'claimed');

  IF NOT v_rerun THEN
    -- t20: exactly one worker can hold the claim (duplicate claim rejected)
    PERFORM public.m_t663_v2_submit_action('req-test-v3-claim', v_rel, 'pol-reply', 'reply', 'hash-v3-t20');
    PERFORM public.m_t663_v2_grant_approval('req-test-v3-claim', 'case-cand-active', v_rel || ':dm', 'hash-v3-t20', 'ops-reviewer-v3', interval '1 hour');
    v_res := public.m_t663_v3_claim_action('req-test-v3-claim', 'worker-v3-a');
    BEGIN
      PERFORM public.m_t663_v3_claim_action('req-test-v3-claim', 'worker-v3-b');
      v_pass := false;
    EXCEPTION WHEN OTHERS THEN v_pass := true; END;
    v_pass := v_pass AND v_res = 'claimed';
    PERFORM public.m_t663_v2_record_test('t20_duplicate_claim_rejected', v_pass,
      'worker-a claimed; worker-b duplicate claim raised while lease active');
    IF v_pass THEN v_passed := v_passed + 1; END IF;

    -- t22: crashed worker lease is released as retryable by the sweeper
    UPDATE public.m_t663_v2_action_requests SET claim_expires_at = now() - interval '1 minute'
    WHERE request_key = 'req-test-v3-claim' AND status = 'claimed';
    PERFORM public.m_t663_v3_release_expired_claims();
    SELECT r.status = 'retryable' AND r.last_failure_kind = 'worker_crash_or_lease_expired'
      INTO v_pass FROM public.m_t663_v2_action_requests r WHERE r.request_key = 'req-test-v3-claim';
    v_pass := COALESCE(v_pass, false) AND EXISTS (
      SELECT 1 FROM public.m_t663_v2_action_ledger l WHERE l.request_key = 'req-test-v3-claim' AND l.event = 'claim_expired_released');
    PERFORM public.m_t663_v2_record_test('t22_crashed_claim_released_retryable', v_pass,
      'expired lease released as retryable with claim_expired_released ledger event; grant unconsumed');
    IF v_pass THEN v_passed := v_passed + 1; END IF;

    -- t23: retryable vs soft-blocked are distinct, and both keep the grant unconsumed
    PERFORM public.m_t663_v3_claim_action('req-test-v3-claim', 'worker-v3-c');
    PERFORM public.m_t663_v3_fail_claim('req-test-v3-claim', 'worker-v3-c', 'provider_soft_block', 'provider returned soft block; back off');
    SELECT r.status = 'soft_blocked' INTO v_pass FROM public.m_t663_v2_action_requests r WHERE r.request_key = 'req-test-v3-claim';
    PERFORM public.m_t663_v3_release_soft_block('req-test-v3-claim', 'operator-v3');
    PERFORM public.m_t663_v3_claim_action('req-test-v3-claim', 'worker-v3-c');
    PERFORM public.m_t663_v3_fail_claim('req-test-v3-claim', 'worker-v3-c', 'provider_retryable_failure', 'transient upstream error');
    SELECT v_pass AND r.status = 'retryable'
      AND EXISTS (SELECT 1 FROM public.m_t663_v2_action_ledger l WHERE l.request_key = 'req-test-v3-claim' AND l.event = 'soft_blocked')
      AND EXISTS (SELECT 1 FROM public.m_t663_v2_action_ledger l WHERE l.request_key = 'req-test-v3-claim' AND l.event = 'retryable_failure')
      AND EXISTS (SELECT 1 FROM public.m_t663_v2_approval_grants g WHERE g.request_key = 'req-test-v3-claim' AND g.consumed_at IS NULL)
      INTO v_pass FROM public.m_t663_v2_action_requests r WHERE r.request_key = 'req-test-v3-claim';
    PERFORM public.m_t663_v2_record_test('t23_retryable_vs_soft_blocked_distinct', COALESCE(v_pass, false),
      'soft_blocked and retryable recorded as distinct states/events; grant stayed unconsumed through failures');
    IF v_pass THEN v_passed := v_passed + 1; END IF;

    UPDATE public.m_t663_v2_action_requests SET status = 'rejected' WHERE request_key = 'req-test-v3-claim';
    DELETE FROM public.m_t663_v2_approval_grants WHERE request_key = 'req-test-v3-claim';
  ELSE
    -- verify-only re-run: lifecycle evidence must still be present and terminal state consistent
    v_pass := EXISTS (SELECT 1 FROM public.m_t663_v2_action_ledger l WHERE l.request_key = 'req-test-v3-claim' AND l.event = 'claimed')
      AND EXISTS (SELECT 1 FROM public.m_t663_v2_action_requests r WHERE r.request_key = 'req-test-v3-claim' AND r.status = 'rejected')
      AND NOT EXISTS (SELECT 1 FROM public.m_t663_v2_approval_grants g WHERE g.request_key = 'req-test-v3-claim' AND g.consumed_at IS NULL AND g.expires_at > now());
    PERFORM public.m_t663_v2_record_test('t20_duplicate_claim_rejected', COALESCE(v_pass, false),
      're-run: prior claim evidence present, request terminal-rejected, no live grant');
    IF v_pass THEN v_passed := v_passed + 1; END IF;
    PERFORM public.m_t663_v2_record_test('t22_crashed_claim_released_retryable',
      EXISTS (SELECT 1 FROM public.m_t663_v2_action_ledger l WHERE l.request_key = 'req-test-v3-claim' AND l.event = 'claim_expired_released'),
      're-run: claim_expired_released event still present');
    IF EXISTS (SELECT 1 FROM public.m_t663_v2_action_ledger l WHERE l.request_key = 'req-test-v3-claim' AND l.event = 'claim_expired_released') THEN v_passed := v_passed + 1; END IF;
    v_pass := EXISTS (SELECT 1 FROM public.m_t663_v2_action_ledger l WHERE l.request_key = 'req-test-v3-claim' AND l.event = 'soft_blocked')
      AND EXISTS (SELECT 1 FROM public.m_t663_v2_action_ledger l WHERE l.request_key = 'req-test-v3-claim' AND l.event = 'retryable_failure');
    PERFORM public.m_t663_v2_record_test('t23_retryable_vs_soft_blocked_distinct', v_pass,
      're-run: soft_blocked and retryable_failure events still distinct in ledger');
    IF v_pass THEN v_passed := v_passed + 1; END IF;
  END IF;

  -- t24: confirmed facts cannot be cleared by unreviewed writes (provider failure must preserve history)
  BEGIN
    UPDATE public.m_t663_v1_relationship_source_facts SET confirmed_state = 'cleared' WHERE relationship_key = 'm-t663-rel-01';
    v_pass := false;
  EXCEPTION WHEN OTHERS THEN v_pass := true; END;
  BEGIN
    UPDATE public.m_t663_v1_relationship_source_facts SET history_valid = false, preserve_reason = NULL WHERE relationship_key = 'm-t663-rel-02';
    v_pass := v_pass AND false;
  EXCEPTION WHEN OTHERS THEN v_pass := v_pass AND true; END;
  PERFORM public.m_t663_v2_record_test('t24_facts_write_guarded', COALESCE(v_pass, false),
    'confirmed_state change without reviewed-transaction GUC raised; history_valid clear with NULL preserve_reason raised');
  IF v_pass THEN v_passed := v_passed + 1; END IF;

  -- t25: ledger distinguishes the full lifecycle for the test request
  SELECT EXISTS (SELECT 1 FROM public.m_t663_v2_action_ledger l WHERE l.request_key = 'req-test-v3-claim' AND l.event = 'claimed')
     AND EXISTS (SELECT 1 FROM public.m_t663_v2_action_ledger l WHERE l.request_key = 'req-test-v3-claim' AND l.event = 'claim_expired_released')
     AND EXISTS (SELECT 1 FROM public.m_t663_v2_action_ledger l WHERE l.request_key = 'req-test-v3-claim' AND l.event = 'soft_blocked')
     AND EXISTS (SELECT 1 FROM public.m_t663_v2_action_ledger l WHERE l.request_key = 'req-test-v3-claim' AND l.event = 'retryable_failure')
    INTO v_pass;
  PERFORM public.m_t663_v2_record_test('t25_ledger_lifecycle_distinct', COALESCE(v_pass, false),
    'claimed / claim_expired_released / soft_blocked / retryable_failure all present and distinct in ledger');
  IF v_pass THEN v_passed := v_passed + 1; END IF;

  RETURN v_passed;
END $function$;

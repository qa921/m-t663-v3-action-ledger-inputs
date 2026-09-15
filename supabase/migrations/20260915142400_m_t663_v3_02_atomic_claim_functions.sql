-- M-T663-V3 hardening, part 2: atomic claim + one-time simulated execution path
-- Applied to project zgkkoavrxxgjsykwazkq as migration m_t663_v3_02_atomic_claim_functions.
-- Guarantees: collector stays read-only; no real provider/social action exists in this path
-- (execution_mode must be 'simulated', publication_target must be NULL, policy.publish_enabled must be false).

CREATE OR REPLACE FUNCTION public.m_t663_v3_claim_action(p_request_key text, p_worker_ref text, p_claim_ttl interval DEFAULT '00:10:00'::interval)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_req record;
  v_pol record;
  v_fact record;
  v_grant record;
  v_today_count int;
BEGIN
  IF p_worker_ref IS NULL OR btrim(p_worker_ref) = '' THEN RAISE EXCEPTION 'worker identity required'; END IF;

  SELECT * INTO v_req FROM public.m_t663_v2_action_requests WHERE request_key = p_request_key FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'unknown request %', p_request_key; END IF;

  -- one-time execution guard: completed (or previously recorded) work can never be re-executed
  IF v_req.status = 'recorded_simulated'
     OR EXISTS (SELECT 1 FROM public.m_t663_v2_action_ledger l
                WHERE l.request_key = p_request_key AND l.event IN ('recorded_simulated','completed')) THEN
    RAISE EXCEPTION 'request % already completed; one-time execution consumed - retry forbidden', p_request_key;
  END IF;

  -- claimable states only; active claim blocks duplicate workers
  IF v_req.status NOT IN ('approved','retryable') THEN
    IF v_req.status = 'claimed' THEN
      RAISE EXCEPTION 'request % already claimed by % until % (duplicate claim rejected)', p_request_key, v_req.claimed_by, v_req.claim_expires_at;
    END IF;
    RAISE EXCEPTION 'request % not claimable in status %', p_request_key, v_req.status;
  END IF;

  -- simulated-only hard guard
  SELECT * INTO v_pol FROM public.m_t663_v2_action_policies WHERE policy_key = v_req.policy_key;
  IF v_req.execution_mode <> 'simulated' OR v_req.publication_target IS NOT NULL OR COALESCE(v_pol.publish_enabled, false) THEN
    RAISE EXCEPTION 'real provider execution is disabled; only simulated recording is allowed';
  END IF;

  -- relationship guards (fresh read of confirmed facts)
  SELECT * INTO v_fact FROM public.m_t663_v1_relationship_source_facts WHERE relationship_key = v_req.relationship_key;
  IF v_fact.do_not_engage THEN RAISE EXCEPTION 'do_not_engage relationship %; claim denied', v_req.relationship_key; END IF;
  IF v_fact.cooldown_until IS NOT NULL AND v_fact.cooldown_until > now() THEN
    RAISE EXCEPTION 'cooldown active until % for %; claim denied', v_fact.cooldown_until, v_req.relationship_key;
  END IF;

  -- fresh, exact, human approval grant required; seeded/legacy/test approvals are NOT authorization
  SELECT * INTO v_grant FROM public.m_t663_v2_approval_grants g WHERE g.request_key = p_request_key FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'no approval grant for %; seeded or legacy approved status is not human authorization - fresh grant required', p_request_key;
  END IF;
  IF v_grant.consumed_at IS NOT NULL THEN RAISE EXCEPTION 'grant for % already consumed (single-use)', p_request_key; END IF;
  IF v_grant.expires_at <= now() THEN RAISE EXCEPTION 'grant for % expired at %; fresh human grant required', p_request_key, v_grant.expires_at; END IF;
  IF v_grant.approved_by IS NULL OR v_grant.approved_by = 'seed-operator' OR v_grant.approved_by LIKE 'test-%' THEN
    RAISE EXCEPTION 'grant actor % is not valid human authorization', v_grant.approved_by;
  END IF;
  IF v_grant.candidate_key IS DISTINCT FROM v_req.candidate_key
     OR v_grant.target_ref IS DISTINCT FROM v_req.target_ref
     OR v_grant.text_hash IS DISTINCT FROM v_req.text_hash THEN
    RAISE EXCEPTION 'grant no longer matches candidate/target/text for %; treat as invalid', p_request_key;
  END IF;

  -- per-day cap in the approved policy timezone (UTC)
  SELECT count(*) INTO v_today_count
  FROM public.m_t663_v2_action_requests r2
  WHERE r2.relationship_key = v_req.relationship_key AND r2.action_kind = v_req.action_kind
    AND r2.status = 'recorded_simulated'
    AND (r2.completed_at AT TIME ZONE 'UTC')::date = (now() AT TIME ZONE 'UTC')::date;
  IF v_today_count >= COALESCE(v_pol.max_per_day, 1) THEN
    RAISE EXCEPTION 'daily cap % reached for % on % (UTC day)', v_pol.max_per_day, v_req.action_kind, v_req.relationship_key;
  END IF;

  UPDATE public.m_t663_v2_action_requests
  SET status = 'claimed', claimed_by = p_worker_ref, claimed_at = now(),
      claim_expires_at = now() + p_claim_ttl, attempt_count = attempt_count + 1, last_failure_kind = NULL
  WHERE request_key = p_request_key;

  INSERT INTO public.m_t663_v2_action_ledger (entry_key, request_key, event, actor_type, actor_ref, detail)
  VALUES (p_request_key || '--claimed-' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS'),
          p_request_key, 'claimed', 'worker', p_worker_ref,
          'atomic claim leased until ' || (now() + p_claim_ttl)::text || '; grant bound to exact candidate/target/text_hash; simulated only');
  RETURN 'claimed';
END $function$;

CREATE OR REPLACE FUNCTION public.m_t663_v3_complete_claim(p_request_key text, p_worker_ref text, p_text_hash text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_req record;
BEGIN
  SELECT * INTO v_req FROM public.m_t663_v2_action_requests WHERE request_key = p_request_key FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'unknown request %', p_request_key; END IF;
  IF v_req.status <> 'claimed' THEN RAISE EXCEPTION 'request % not claimed (status=%)', p_request_key, v_req.status; END IF;
  IF v_req.claimed_by IS DISTINCT FROM p_worker_ref THEN RAISE EXCEPTION 'request % claimed by %, not %', p_request_key, v_req.claimed_by, p_worker_ref; END IF;
  IF v_req.claim_expires_at <= now() THEN RAISE EXCEPTION 'claim lease expired at %; request will be released as retryable', v_req.claim_expires_at; END IF;

  -- consumes the single-use grant and records the simulated outcome (binding re-verified inside)
  PERFORM public.m_t663_v2_consume_approval(p_request_key, p_text_hash);

  UPDATE public.m_t663_v2_action_requests SET completed_at = now() WHERE request_key = p_request_key;
  INSERT INTO public.m_t663_v2_action_ledger (entry_key, request_key, event, actor_type, actor_ref, detail)
  VALUES (p_request_key || '--completed-' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS'),
          p_request_key, 'completed', 'worker', p_worker_ref,
          'simulated outcome recorded; grant consumed; request is terminal - no real provider action ran');
  RETURN 'completed_simulated';
END $function$;

CREATE OR REPLACE FUNCTION public.m_t663_v3_fail_claim(p_request_key text, p_worker_ref text, p_failure_kind text, p_detail text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_req record;
  v_new_status text;
  v_event text;
BEGIN
  IF p_failure_kind NOT IN ('provider_retryable_failure','provider_rate_limited','provider_soft_block') THEN
    RAISE EXCEPTION 'unknown failure kind %', p_failure_kind;
  END IF;
  SELECT * INTO v_req FROM public.m_t663_v2_action_requests WHERE request_key = p_request_key FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'unknown request %', p_request_key; END IF;
  IF v_req.status <> 'claimed' THEN RAISE EXCEPTION 'request % not claimed (status=%)', p_request_key, v_req.status; END IF;
  IF v_req.claimed_by IS DISTINCT FROM p_worker_ref THEN RAISE EXCEPTION 'request % claimed by %, not %', p_request_key, v_req.claimed_by, p_worker_ref; END IF;

  v_new_status := CASE p_failure_kind WHEN 'provider_soft_block' THEN 'soft_blocked' ELSE 'retryable' END;
  v_event := CASE p_failure_kind
    WHEN 'provider_soft_block' THEN 'soft_blocked'
    WHEN 'provider_rate_limited' THEN 'rate_limited'
    ELSE 'retryable_failure' END;

  UPDATE public.m_t663_v2_action_requests
  SET status = v_new_status, last_failure_kind = p_failure_kind, claim_expires_at = NULL
  WHERE request_key = p_request_key;

  INSERT INTO public.m_t663_v2_action_ledger (entry_key, request_key, event, actor_type, actor_ref, detail)
  VALUES (p_request_key || '--' || v_event || '-' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS'),
          p_request_key, v_event, 'worker', p_worker_ref,
          COALESCE(p_detail, p_failure_kind) || '; grant NOT consumed; no provider action recorded');
  RETURN v_new_status;
END $function$;

CREATE OR REPLACE FUNCTION public.m_t663_v3_release_soft_block(p_request_key text, p_operator_ref text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_req record;
BEGIN
  IF p_operator_ref IS NULL OR btrim(p_operator_ref) = '' THEN RAISE EXCEPTION 'operator identity required'; END IF;
  SELECT * INTO v_req FROM public.m_t663_v2_action_requests WHERE request_key = p_request_key FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'unknown request %', p_request_key; END IF;
  IF v_req.status <> 'soft_blocked' THEN RAISE EXCEPTION 'request % not soft_blocked (status=%)', p_request_key, v_req.status; END IF;
  UPDATE public.m_t663_v2_action_requests SET status = 'retryable' WHERE request_key = p_request_key;
  INSERT INTO public.m_t663_v2_action_ledger (entry_key, request_key, event, actor_type, actor_ref, detail)
  VALUES (p_request_key || '--soft-block-released-' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS'),
          p_request_key, 'soft_block_released', 'operator', p_operator_ref, 'operator released soft block; request is retryable');
  RETURN 'retryable';
END $function$;

-- crash recovery: expired claim leases become retryable (worker_claimed_then_crashed case)
CREATE OR REPLACE FUNCTION public.m_t663_v3_release_expired_claims()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  r record;
  v_n int := 0;
BEGIN
  FOR r IN
    SELECT request_key, claimed_by FROM public.m_t663_v2_action_requests
    WHERE status = 'claimed' AND claim_expires_at < now()
    FOR UPDATE
  LOOP
    UPDATE public.m_t663_v2_action_requests
    SET status = 'retryable', last_failure_kind = 'worker_crash_or_lease_expired', claim_expires_at = NULL
    WHERE request_key = r.request_key;
    INSERT INTO public.m_t663_v2_action_ledger (entry_key, request_key, event, actor_type, actor_ref, detail)
    VALUES (r.request_key || '--claim-expired-' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS'),
            r.request_key, 'claim_expired_released', 'system', 'm_t663_v3_release_expired_claims',
            'claim lease expired (worker crash/timeout); released as retryable; grant still unconsumed');
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $function$;

-- sweeper schedule (UTC); existing 30-min read-only health sweep left unchanged
SELECT cron.schedule('m_t663_v3_claim_sweeper', '*/5 * * * *', 'SELECT public.m_t663_v3_release_expired_claims();')
WHERE NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'm_t663_v3_claim_sweeper');

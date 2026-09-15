-- M-T663-V3 hardening, part 1: claim schema, status machine, state map, RLS
-- Applied to project zgkkoavrxxgjsykwazkq as migration m_t663_v3_01_claim_schema_rls.
-- All timestamps are timestamptz; approved policy timezone is UTC (DB runs in UTC).

ALTER TABLE public.m_t663_v2_action_requests
  ADD COLUMN IF NOT EXISTS claimed_by text,
  ADD COLUMN IF NOT EXISTS claimed_at timestamptz,
  ADD COLUMN IF NOT EXISTS claim_expires_at timestamptz,
  ADD COLUMN IF NOT EXISTS attempt_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_failure_kind text,
  ADD COLUMN IF NOT EXISTS completed_at timestamptz;

DO $$ BEGIN
  ALTER TABLE public.m_t663_v2_action_requests
    ADD CONSTRAINT m_t663_v3_request_status_check CHECK (status IN (
      'proposed','awaiting_approval','approved','claimed','retryable','soft_blocked','held','rejected','recorded_simulated'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE public.m_t663_v2_action_requests
    ADD CONSTRAINT m_t663_v3_claim_fields_check CHECK (
      status <> 'claimed' OR (claimed_by IS NOT NULL AND claimed_at IS NOT NULL AND claim_expires_at IS NOT NULL));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- one live request per candidate (test/case fixtures excluded); prevents duplicate send pipelines
CREATE UNIQUE INDEX IF NOT EXISTS m_t663_v3_one_live_request_per_candidate
  ON public.m_t663_v2_action_requests (candidate_key)
  WHERE candidate_key IS NOT NULL
    AND status IN ('proposed','awaiting_approval','approved','claimed','retryable','soft_blocked')
    AND request_key NOT LIKE 'req-case-%' AND request_key NOT LIKE 'req-test-%';

-- legal status transitions; recorded_simulated is terminal (one-time execution)
CREATE OR REPLACE FUNCTION public.m_t663_v3_status_transition_guard()
RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN RETURN NEW; END IF;
  IF OLD.status = 'recorded_simulated' THEN
    RAISE EXCEPTION 'request % is completed (recorded_simulated); terminal state, cannot transition to %', OLD.request_key, NEW.status;
  END IF;
  IF (OLD.status, NEW.status) NOT IN (
    ('proposed','awaiting_approval'), ('proposed','held'), ('proposed','rejected'),
    ('awaiting_approval','approved'), ('awaiting_approval','rejected'), ('awaiting_approval','held'),
    ('approved','claimed'), ('approved','rejected'), ('approved','held'), ('approved','recorded_simulated'),
    ('claimed','recorded_simulated'), ('claimed','retryable'), ('claimed','soft_blocked'), ('claimed','rejected'),
    ('retryable','claimed'), ('retryable','rejected'), ('retryable','held'),
    ('soft_blocked','retryable'), ('soft_blocked','rejected'), ('soft_blocked','held'),
    ('held','rejected'), ('held','awaiting_approval')
  ) THEN
    RAISE EXCEPTION 'illegal status transition % -> % for request %', OLD.status, NEW.status, OLD.request_key;
  END IF;
  RETURN NEW;
END $function$;

DROP TRIGGER IF EXISTS m_t663_v3_status_transition_guard ON public.m_t663_v2_action_requests;
CREATE TRIGGER m_t663_v3_status_transition_guard
  BEFORE UPDATE OF status ON public.m_t663_v2_action_requests
  FOR EACH ROW EXECUTE FUNCTION public.m_t663_v3_status_transition_guard();

-- operator-facing per-candidate state map
CREATE OR REPLACE VIEW public.m_t663_v3_candidate_state_map AS
SELECT
  c.candidate_key, c.run_id, c.relationship_key, c.bucket, c.confidence, c.uncertainty_reason,
  r.request_key, r.status AS request_status, r.policy_decision, r.execution_mode,
  r.claimed_by, r.claim_expires_at, r.attempt_count, r.last_failure_kind,
  f.do_not_engage, f.cooldown_until, f.history_valid,
  h.latest_outcome AS provider_outcome, h.is_uncertain AS provider_uncertain,
  CASE
    WHEN r.request_key IS NULL THEN 'pending'
    WHEN r.status = 'recorded_simulated' THEN 'completed'
    WHEN r.status = 'claimed' THEN 'claimed'
    WHEN r.status = 'rejected' THEN 'rejected'
    WHEN r.status = 'held' THEN 'held'
    WHEN r.status = 'soft_blocked' THEN 'soft-blocked'
    WHEN r.status = 'retryable' THEN 'retryable'
    WHEN r.status = 'approved' AND NOT EXISTS (
      SELECT 1 FROM public.m_t663_v2_approval_grants g
      WHERE g.request_key = r.request_key AND g.consumed_at IS NULL AND g.expires_at > now()
        AND g.approved_by IS NOT NULL AND g.approved_by <> 'seed-operator' AND g.approved_by NOT LIKE 'test-%'
        AND g.candidate_key IS NOT DISTINCT FROM r.candidate_key
        AND g.target_ref IS NOT DISTINCT FROM r.target_ref
        AND g.text_hash IS NOT DISTINCT FROM r.text_hash
    ) THEN 'pending'  -- seeded/legacy 'approved' rows are NOT human authorization
    ELSE 'pending'
  END AS state_category
FROM public.m_t663_v2_observation_candidates c
LEFT JOIN public.m_t663_v2_action_requests r ON r.candidate_key = c.candidate_key
LEFT JOIN public.m_t663_v1_relationship_source_facts f ON f.relationship_key = c.relationship_key
LEFT JOIN public.m_t663_v2_provider_health h ON h.relationship_key = c.relationship_key;

-- RLS: explicit read policies; source facts / evidence / artifacts / ledger are read-only for API roles
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'm_t663_v1_relationship_source_facts','m_t663_v1_provider_poll_evidence','m_t663_v1_prior_action_artifacts',
    'm_t663_v2_observation_candidates','m_t663_v2_action_requests','m_t663_v2_approval_grants',
    'm_t663_v2_action_ledger','m_t663_v2_action_policies','m_t663_v2_collector_runs',
    'm_t663_v2_provider_health','m_t663_v2_test_results'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS m_t663_v3_read ON public.%I', t);
    EXECUTE format('CREATE POLICY m_t663_v3_read ON public.%I FOR SELECT TO authenticated, service_role USING (true)', t);
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated, service_role', t);
  END LOOP;
END $$;

-- writes to confirmed facts, poll evidence, historical artifacts and the ledger only via SECURITY DEFINER functions
REVOKE INSERT, UPDATE, DELETE ON
  public.m_t663_v1_relationship_source_facts,
  public.m_t663_v1_provider_poll_evidence,
  public.m_t663_v1_prior_action_artifacts,
  public.m_t663_v2_action_ledger
FROM anon, authenticated, service_role;

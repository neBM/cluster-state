-- +goose Up
-- +goose StatementBegin
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'feedback_authenticator') THEN
    RAISE EXCEPTION 'required role feedback_authenticator does not exist';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'feedback_public') THEN
    RAISE EXCEPTION 'required role feedback_public does not exist';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'feedback_admin') THEN
    RAISE EXCEPTION 'required role feedback_admin does not exist; create it as NOLOGIN and grant it to feedback_authenticator before running this migration';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_auth_members membership
    JOIN pg_roles role ON role.oid = membership.roleid
    JOIN pg_roles member ON member.oid = membership.member
    WHERE role.rolname = 'feedback_admin'
      AND member.rolname = 'feedback_authenticator'
  ) THEN
    RAISE EXCEPTION 'required role membership feedback_admin -> feedback_authenticator does not exist';
  END IF;
END
$$;

CREATE SCHEMA IF NOT EXISTS feedback_auth;
REVOKE ALL ON SCHEMA feedback_auth FROM PUBLIC;

CREATE OR REPLACE FUNCTION feedback_auth.validate_oidc_claims()
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  raw_headers TEXT := current_setting('request.headers', true);
  headers JSONB := '{}'::jsonb;
  raw_claims TEXT := current_setting('request.jwt.claims', true);
  claims JSONB;
  audience JSONB;
BEGIN
  IF raw_headers IS NOT NULL AND btrim(raw_headers) <> '' THEN
    headers := raw_headers::jsonb;
  END IF;

  IF nullif(coalesce(headers ->> 'authorization', headers ->> 'Authorization'), '') IS NULL THEN
    RETURN;
  END IF;

  IF raw_claims IS NULL OR btrim(raw_claims) = '' THEN
    RAISE EXCEPTION 'missing jwt claims'
      USING ERRCODE = '28000';
  END IF;

  claims := raw_claims::jsonb;

  IF claims ->> 'iss' IS DISTINCT FROM 'https://sso.brmartin.co.uk/realms/prod' THEN
    RAISE EXCEPTION 'invalid token issuer'
      USING ERRCODE = '28000';
  END IF;

  audience := claims -> 'aud';
  IF jsonb_typeof(audience) = 'string' THEN
    IF audience #>> '{}' <> 'feedback-api' THEN
      RAISE EXCEPTION 'invalid token audience'
        USING ERRCODE = '28000';
    END IF;
  ELSIF jsonb_typeof(audience) = 'array' THEN
    IF NOT EXISTS (
      SELECT 1
      FROM jsonb_array_elements_text(audience) AS token_audience(value)
      WHERE token_audience.value = 'feedback-api'
    ) THEN
      RAISE EXCEPTION 'invalid token audience'
        USING ERRCODE = '28000';
    END IF;
  ELSE
    RAISE EXCEPTION 'invalid token audience'
      USING ERRCODE = '28000';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION api.list_feedback(
  project_filter TEXT DEFAULT NULL,
  status_filter TEXT DEFAULT NULL,
  before_created_at TIMESTAMPTZ DEFAULT NULL,
  limit_count INTEGER DEFAULT 100
)
RETURNS TABLE (
  id UUID,
  project TEXT,
  kind TEXT,
  title TEXT,
  body TEXT,
  installation_id TEXT,
  app_version TEXT,
  contact TEXT,
  client_context JSONB,
  status TEXT,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = feedback_private, pg_temp
AS $$
DECLARE
  normalized_project TEXT := nullif(lower(btrim(project_filter)), '');
  normalized_status TEXT := nullif(lower(btrim(status_filter)), '');
  bounded_limit INTEGER := least(greatest(coalesce(limit_count, 100), 1), 500);
BEGIN
  IF normalized_project IS NOT NULL AND normalized_project !~ '^[a-z0-9][a-z0-9_-]{0,63}$' THEN
    RAISE EXCEPTION 'invalid project' USING ERRCODE = '22023';
  END IF;

  IF normalized_status IS NOT NULL AND normalized_status NOT IN ('new', 'triaged', 'accepted', 'declined', 'closed') THEN
    RAISE EXCEPTION 'invalid status' USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  SELECT
    item.id,
    item.project,
    item.feedback_type AS kind,
    item.title,
    item.body,
    item.installation_id,
    item.app_version,
    item.contact,
    item.client_context,
    item.status,
    item.created_at,
    item.updated_at
  FROM feedback_items AS item
  WHERE (normalized_project IS NULL OR item.project = normalized_project)
    AND (normalized_status IS NULL OR item.status = normalized_status)
    AND (before_created_at IS NULL OR item.created_at < before_created_at)
  ORDER BY item.created_at DESC
  LIMIT bounded_limit;
END;
$$;

CREATE OR REPLACE FUNCTION api.set_feedback_status(
  feedback_id UUID,
  next_status TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = feedback_private, pg_temp
AS $$
DECLARE
  normalized_status TEXT := lower(btrim(next_status));
  updated_id UUID;
  updated_status TEXT;
  updated_at TIMESTAMPTZ;
BEGIN
  IF feedback_id IS NULL THEN
    RAISE EXCEPTION 'missing feedback_id' USING ERRCODE = '22023';
  END IF;

  IF normalized_status IS NULL OR normalized_status NOT IN ('new', 'triaged', 'accepted', 'declined', 'closed') THEN
    RAISE EXCEPTION 'invalid status' USING ERRCODE = '22023';
  END IF;

  UPDATE feedback_items
  SET status = normalized_status
  WHERE id = feedback_id
  RETURNING id, status, updated_at
  INTO updated_id, updated_status, updated_at;

  IF updated_id IS NULL THEN
    RAISE EXCEPTION 'feedback item not found' USING ERRCODE = 'P0002';
  END IF;

  RETURN jsonb_build_object(
    'id', updated_id,
    'status', updated_status,
    'updated_at', updated_at
  );
END;
$$;

REVOKE ALL ON FUNCTION feedback_auth.validate_oidc_claims() FROM PUBLIC;
REVOKE ALL ON FUNCTION api.list_feedback(TEXT, TEXT, TIMESTAMPTZ, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.set_feedback_status(UUID, TEXT) FROM PUBLIC;

GRANT USAGE ON SCHEMA feedback_auth TO feedback_authenticator, feedback_public, feedback_admin;
GRANT EXECUTE ON FUNCTION feedback_auth.validate_oidc_claims() TO feedback_authenticator, feedback_public, feedback_admin;

GRANT USAGE ON SCHEMA api TO feedback_admin;
GRANT EXECUTE ON FUNCTION api.list_feedback(TEXT, TEXT, TIMESTAMPTZ, INTEGER) TO feedback_admin;
GRANT EXECUTE ON FUNCTION api.set_feedback_status(UUID, TEXT) TO feedback_admin;

NOTIFY pgrst, 'reload schema';
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP FUNCTION IF EXISTS api.set_feedback_status(UUID, TEXT);
DROP FUNCTION IF EXISTS api.list_feedback(TEXT, TEXT, TIMESTAMPTZ, INTEGER);
DROP FUNCTION IF EXISTS feedback_auth.validate_oidc_claims();
DROP SCHEMA IF EXISTS feedback_auth;
NOTIFY pgrst, 'reload schema';
-- +goose StatementEnd

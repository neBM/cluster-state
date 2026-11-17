-- +goose Up
-- +goose StatementBegin
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
  updated_timestamp TIMESTAMPTZ;
BEGIN
  IF feedback_id IS NULL THEN
    RAISE EXCEPTION 'missing feedback_id' USING ERRCODE = '22023';
  END IF;

  IF normalized_status IS NULL OR normalized_status NOT IN ('new', 'triaged', 'accepted', 'declined', 'closed') THEN
    RAISE EXCEPTION 'invalid status' USING ERRCODE = '22023';
  END IF;

  UPDATE feedback_items AS item
  SET status = normalized_status
  WHERE item.id = feedback_id
  RETURNING item.id, item.status, item.updated_at
  INTO updated_id, updated_status, updated_timestamp;

  IF updated_id IS NULL THEN
    RAISE EXCEPTION 'feedback item not found' USING ERRCODE = 'P0002';
  END IF;

  RETURN jsonb_build_object(
    'id', updated_id,
    'status', updated_status,
    'updated_at', updated_timestamp
  );
END;
$$;

NOTIFY pgrst, 'reload schema';
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
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

NOTIFY pgrst, 'reload schema';
-- +goose StatementEnd

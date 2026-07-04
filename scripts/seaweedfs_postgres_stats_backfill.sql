-- Backfill extended planner statistics for existing SeaweedFS PostgreSQL filer
-- metadata tables. New tables are handled in the SeaweedFS fork by
-- SqlGenPostgres.GetSqlPostCreateTable.
--
-- This is intentionally uniform: every table with the SeaweedFS metadata shape
-- (dirhash, name, directory, meta) gets the same stats object. The object name
-- matches the fork's source-level naming:
--   sw_<first 16 hex chars of md5(table name)>_dirhash_directory
--
-- Safe to re-run: CREATE STATISTICS IF NOT EXISTS is idempotent; ANALYZE only
-- refreshes planner statistics and does not rewrite table data.

\set ON_ERROR_STOP on

DO $$
DECLARE
  r record;
  stats_name text;
  table_count integer := 0;
BEGIN
  FOR r IN
    SELECT n.nspname, c.relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind IN ('r', 'p')
      AND n.nspname NOT IN ('pg_catalog', 'information_schema')
      AND EXISTS (
        SELECT 1 FROM pg_attribute a
        WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
          AND a.attname = 'dirhash'
      )
      AND EXISTS (
        SELECT 1 FROM pg_attribute a
        WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
          AND a.attname = 'name'
      )
      AND EXISTS (
        SELECT 1 FROM pg_attribute a
        WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
          AND a.attname = 'directory'
      )
      AND EXISTS (
        SELECT 1 FROM pg_attribute a
        WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
          AND a.attname = 'meta'
      )
    ORDER BY n.nspname, c.relname
  LOOP
    stats_name := 'sw_' || substr(md5(r.relname), 1, 16) || '_dirhash_directory';

    EXECUTE format(
      'CREATE STATISTICS IF NOT EXISTS %I.%I (dependencies, ndistinct, mcv) ON dirhash, directory FROM %I.%I',
      r.nspname, stats_name, r.nspname, r.relname
    );

    EXECUTE format('ANALYZE %I.%I', r.nspname, r.relname);

    table_count := table_count + 1;
    RAISE NOTICE 'ensured SeaweedFS planner stats % on %.%', stats_name, r.nspname, r.relname;
  END LOOP;

  RAISE NOTICE 'SeaweedFS planner stats backfill complete: % table(s)', table_count;
END $$;

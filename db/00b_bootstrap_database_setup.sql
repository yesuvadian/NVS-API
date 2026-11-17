-- =============================================================================
-- CFMS / NVS  -  00b  Bootstrap: database-level settings
-- -----------------------------------------------------------------------------
-- Run as : postgres (superuser), connected to database "nvs"
-- Safe to re-run.
-- After this script, run 01 onwards connected to "nvs" as user nvs / nvs_admin.
-- =============================================================================

-- Only the owner and the app role may connect.
REVOKE ALL ON DATABASE nvs FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE nvs TO nvs;
GRANT CONNECT ON DATABASE nvs TO nvs_app;

-- Nobody but the owner creates objects in public.
ALTER SCHEMA public OWNER TO nvs;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- nvs may create the schemas used by CFMS.
GRANT CREATE ON DATABASE nvs TO nvs;

-- Display time zone for tools such as DBeaver. Each tenant has its own time zone
-- (platform.tenant.time_zone); all timestamps are stored as timestamptz.
ALTER DATABASE nvs SET timezone TO 'Asia/Kolkata';

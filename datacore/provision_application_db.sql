-- ============================================================
-- DataCore Application Database Bootstrap Script
-- ============================================================
\set ON_ERROR_STOP on

-- ------------------------------------------------------------
-- Create Application Role
-- ------------------------------------------------------------
SELECT
  CASE
    WHEN EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = :'app_user')
      THEN format('ALTER ROLE %I WITH LOGIN PASSWORD %L;', :'app_user', :'app_password')
      ELSE format('CREATE ROLE %I WITH LOGIN PASSWORD %L;', :'app_user', :'app_password')
  END AS sql
\gexec

-- ------------------------------------------------------------
-- Create Database
-- ------------------------------------------------------------
SELECT
  CASE
    WHEN EXISTS (SELECT 1 FROM pg_database WHERE datname = :'app_db')
      THEN format('-- database %I already exists', :'app_db')
      ELSE format('CREATE DATABASE %I OWNER %I;', :'app_db', :'app_user')
  END AS sql
\gexec

-- ------------------------------------------------------------
-- Ensure Ownership
-- ------------------------------------------------------------
SELECT format('ALTER DATABASE %I OWNER TO %I;', :'app_db', :'app_user') AS sql
\gexec
\connect :app_db
SELECT format('ALTER SCHEMA public OWNER TO %I;', :'app_user') AS sql
\gexec

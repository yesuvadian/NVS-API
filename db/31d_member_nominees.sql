-- =============================================================================
-- CFMS / NVS  -  31d  Member nominees (a nominee is an existing member)
-- -----------------------------------------------------------------------------
-- Run as nvs after 31c. Safe to re-run.
--
--   mbr.list_nominees(member, include_inactive)
--   mbr.add_nominee(member, nominee_member, relationship)
--   mbr.update_nominee(nominee, relationship, row_version)
--   mbr.set_nominee_status(nominee, status, row_version, reason)
--   mbr.nomination_rules(on)                 -> MEMBER_RULES / NOMINATIONS values
--   loan.count_active_application_nominees(loan)
--
-- Rules: the nominee is a member of the same organisation (foreign key), not
-- the member themselves, with status ACTIVE or APPLIED; one person is never
-- nominated twice by the same member while active; a person can be an active
-- nominee for at most NOMINATIONS.maxPerPerson members (rule set MEMBER_RULES,
-- default 2); optionally a member can name at most NOMINATIONS.maxPerMember
-- nominees (null = no limit). Lowering a limit never removes nominations; it
-- only blocks new ones. Older free-text nominee rows (no nominee_member_id)
-- stay valid for existing loans.
-- =============================================================================

ALTER TABLE mbr.nominee ADD COLUMN IF NOT EXISTS nominee_member_id uuid;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'nominee_member_fk') THEN
        ALTER TABLE mbr.nominee ADD CONSTRAINT nominee_member_fk
            FOREIGN KEY (tenant_id, nominee_member_id) REFERENCES mbr.member (tenant_id, id);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'nominee_not_self') THEN
        ALTER TABLE mbr.nominee ADD CONSTRAINT nominee_not_self
            CHECK (nominee_member_id IS DISTINCT FROM member_id);
    END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS nominee_active_person_uq
    ON mbr.nominee (tenant_id, member_id, nominee_member_id)
    WHERE status = 'ACTIVE' AND NOT is_deleted AND nominee_member_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS nominee_person_idx
    ON mbr.nominee (tenant_id, nominee_member_id) WHERE nominee_member_id IS NOT NULL;

-- NOMINATIONS rule of the organisation's MEMBER_RULES rule set (seeded in 49a),
-- version in force on the date; defaults when the rule set is missing.
CREATE OR REPLACE FUNCTION mbr.nomination_rules(p_on date DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    SELECT jsonb_build_object('maxPerPerson', 2, 'maxPerMember', NULL) || coalesce((
        SELECT r -> 'value'
          FROM cfg.rule_set rs
          JOIN cfg.rule_set_version v
            ON v.id = cfg.rule_set_version_at(rs.id, coalesce(p_on, app.working_date()))
          CROSS JOIN LATERAL jsonb_array_elements(v.definition -> 'rules') r
         WHERE rs.tenant_id = app.tenant_id() AND rs.code = 'MEMBER_RULES' AND rs.status = 'ACTIVE'
           AND r ->> 'code' = 'NOMINATIONS'
         LIMIT 1), '{}'::jsonb)
$$;

CREATE OR REPLACE FUNCTION mbr.nominee_json(n mbr.nominee)
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    SELECT jsonb_build_object(
        'id', n.id, 'member_id', n.member_id, 'nominee_member_id', n.nominee_member_id,
        'nominee_member_no', (SELECT m.member_no FROM mbr.member m
                               WHERE m.tenant_id = n.tenant_id AND m.id = n.nominee_member_id),
        'full_name', n.full_name, 'relationship', n.relationship,
        'date_of_birth', n.date_of_birth, 'mobile', n.mobile, 'status', n.status,
        'created_at', n.created_at, 'updated_at', n.updated_at, 'row_version', n.row_version)
$$;

CREATE OR REPLACE FUNCTION mbr.assert_relationship(p_relationship text)
RETURNS void LANGUAGE plpgsql STABLE AS
$$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM platform.lookup_template v
                    WHERE v.lookup_type = 'RELATIONSHIP' AND v.code = p_relationship) THEN
        PERFORM app.fail('INVALID_DATA', 'relationship');
    END IF;
END
$$;

-- Limits for making nominee_member_id an ACTIVE nominee of p_member_id.
CREATE OR REPLACE FUNCTION mbr.assert_nomination_allowed(p_member_id uuid, p_nominee_member_id uuid)
RETURNS void LANGUAGE plpgsql STABLE AS
$$
DECLARE
    v_rules      jsonb := mbr.nomination_rules();
    v_per_person integer := (v_rules ->> 'maxPerPerson')::integer;
    v_per_member integer := (v_rules ->> 'maxPerMember')::integer;
    v_status     text;
BEGIN
    IF p_nominee_member_id = p_member_id THEN
        PERFORM app.fail('NOMINEE_IS_SELF', 'A member cannot be their own nominee');
    END IF;
    SELECT m.status INTO v_status FROM mbr.member m
     WHERE m.tenant_id = app.tenant_id() AND m.id = p_nominee_member_id AND NOT m.is_deleted;
    IF NOT FOUND THEN
        PERFORM app.fail('MEMBER_NOT_FOUND', 'The nominee must be a member of this organisation');
    END IF;
    IF v_status NOT IN ('ACTIVE', 'APPLIED') THEN
        PERFORM app.fail('NOMINEE_MEMBER_NOT_ELIGIBLE', 'The nominee member must be active or applied');
    END IF;
    IF EXISTS (SELECT 1 FROM mbr.nominee n
                WHERE n.tenant_id = app.tenant_id() AND n.member_id = p_member_id
                  AND n.nominee_member_id = p_nominee_member_id
                  AND n.status = 'ACTIVE' AND NOT n.is_deleted) THEN
        PERFORM app.fail('NOMINEE_DUPLICATE', 'This person is already an active nominee of the member');
    END IF;
    IF v_per_member IS NOT NULL AND (
        SELECT count(*) FROM mbr.nominee n
         WHERE n.tenant_id = app.tenant_id() AND n.member_id = p_member_id
           AND n.status = 'ACTIVE' AND NOT n.is_deleted) >= v_per_member THEN
        PERFORM app.fail('NOMINEE_LIMIT_REACHED',
            format('A member can name at most %s active nominees', v_per_member));
    END IF;
    IF v_per_person IS NOT NULL AND (
        SELECT count(DISTINCT n.member_id) FROM mbr.nominee n
         WHERE n.tenant_id = app.tenant_id() AND n.nominee_member_id = p_nominee_member_id
           AND n.status = 'ACTIVE' AND NOT n.is_deleted) >= v_per_person THEN
        PERFORM app.fail('NOMINATION_LIMIT_REACHED',
            format('This person is already a nominee for %s members', v_per_person));
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION mbr.list_nominees(p_member_id uuid, p_include_inactive boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql STABLE AS
$$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM mbr.member m
                    WHERE m.tenant_id = app.tenant_id() AND m.id = p_member_id AND NOT m.is_deleted) THEN
        PERFORM app.fail('MEMBER_NOT_FOUND', 'Member not found');
    END IF;
    RETURN coalesce((
        SELECT jsonb_agg(mbr.nominee_json(n) ORDER BY (n.status = 'ACTIVE') DESC, n.created_at)
          FROM mbr.nominee n
         WHERE n.tenant_id = app.tenant_id() AND n.member_id = p_member_id AND NOT n.is_deleted
           AND (p_include_inactive OR n.status = 'ACTIVE')), '[]'::jsonb);
END
$$;

CREATE OR REPLACE FUNCTION mbr.add_nominee(p_member_id uuid, p_nominee_member_id uuid, p_relationship text)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_member  mbr.member%ROWTYPE;
    v_nominee mbr.member%ROWTYPE;
    v_row     mbr.nominee%ROWTYPE;
BEGIN
    SELECT * INTO v_member FROM mbr.member m
     WHERE m.tenant_id = app.tenant_id() AND m.id = p_member_id AND NOT m.is_deleted
     FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM app.fail('MEMBER_NOT_FOUND', 'Member not found');
    END IF;
    IF v_member.status IN ('EXITED', 'DECEASED') THEN
        PERFORM app.fail('MEMBER_NOT_ACTIVE', 'Nominees cannot be added for an exited or deceased member');
    END IF;
    PERFORM mbr.assert_relationship(p_relationship);
    -- Serialise nominations of the same person so the per-person limit holds.
    PERFORM 1 FROM mbr.member m
      WHERE m.tenant_id = app.tenant_id() AND m.id = p_nominee_member_id FOR UPDATE;
    PERFORM mbr.assert_nomination_allowed(p_member_id, p_nominee_member_id);
    SELECT * INTO v_nominee FROM mbr.member m
     WHERE m.tenant_id = app.tenant_id() AND m.id = p_nominee_member_id;
    INSERT INTO mbr.nominee (member_id, nominee_member_id, full_name, relationship, date_of_birth, mobile)
    VALUES (p_member_id, p_nominee_member_id, v_nominee.full_name, p_relationship,
            v_nominee.date_of_birth, v_nominee.mobile)
    RETURNING * INTO v_row;
    RETURN mbr.nominee_json(v_row);
END
$$;

CREATE OR REPLACE FUNCTION mbr.update_nominee(p_nominee_id uuid, p_relationship text, p_expected_version integer)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_row mbr.nominee%ROWTYPE;
BEGIN
    SELECT * INTO v_row FROM mbr.nominee n
     WHERE n.tenant_id = app.tenant_id() AND n.id = p_nominee_id AND NOT n.is_deleted
     FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM app.fail('NOMINEE_NOT_FOUND', 'Nominee not found');
    END IF;
    IF p_expected_version IS NULL THEN
        PERFORM app.fail('ROW_VERSION_REQUIRED', 'Send the row version of the nominee you opened');
    END IF;
    IF v_row.row_version <> p_expected_version THEN
        PERFORM app.fail('STALE_RECORD', 'The nominee was changed after it was opened');
    END IF;
    PERFORM mbr.assert_relationship(p_relationship);
    UPDATE mbr.nominee SET relationship = p_relationship
     WHERE tenant_id = app.tenant_id() AND id = p_nominee_id
    RETURNING * INTO v_row;
    RETURN mbr.nominee_json(v_row);
END
$$;

-- Deactivate (INACTIVE), record a death (DECEASED) or reactivate (ACTIVE).
CREATE OR REPLACE FUNCTION mbr.set_nominee_status(
    p_nominee_id uuid, p_status text, p_expected_version integer, p_reason text)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_row mbr.nominee%ROWTYPE;
BEGIN
    IF p_status IS NULL OR p_status NOT IN ('ACTIVE', 'INACTIVE', 'DECEASED') THEN
        PERFORM app.fail('INVALID_DATA', 'status');
    END IF;
    IF length(btrim(coalesce(p_reason, ''))) < 3 THEN
        PERFORM app.fail('REASON_REQUIRED', 'A reason is required');
    END IF;
    SELECT * INTO v_row FROM mbr.nominee n
     WHERE n.tenant_id = app.tenant_id() AND n.id = p_nominee_id AND NOT n.is_deleted
     FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM app.fail('NOMINEE_NOT_FOUND', 'Nominee not found');
    END IF;
    IF p_expected_version IS NULL THEN
        PERFORM app.fail('ROW_VERSION_REQUIRED', 'Send the row version of the nominee you opened');
    END IF;
    IF v_row.row_version <> p_expected_version THEN
        PERFORM app.fail('STALE_RECORD', 'The nominee was changed after it was opened');
    END IF;
    IF p_status = 'ACTIVE' AND v_row.status <> 'ACTIVE' AND v_row.nominee_member_id IS NOT NULL THEN
        PERFORM 1 FROM mbr.member m
          WHERE m.tenant_id = app.tenant_id() AND m.id = v_row.nominee_member_id FOR UPDATE;
        PERFORM mbr.assert_nomination_allowed(v_row.member_id, v_row.nominee_member_id);
    END IF;
    PERFORM app.set_audit_reason(btrim(p_reason), 'NOMINEE', p_nominee_id::text);
    UPDATE mbr.nominee SET status = p_status
     WHERE tenant_id = app.tenant_id() AND id = p_nominee_id
    RETURNING * INTO v_row;
    RETURN mbr.nominee_json(v_row);
END
$$;

-- Submission check: nominees on the application that are still ACTIVE.
CREATE OR REPLACE FUNCTION loan.count_active_application_nominees(p_loan_id uuid)
RETURNS integer LANGUAGE sql STABLE AS
$$
    SELECT count(*)::integer
      FROM loan.loan_nominee ln
      JOIN mbr.nominee n ON n.tenant_id = ln.tenant_id AND n.id = ln.nominee_id
     WHERE ln.tenant_id = app.tenant_id() AND ln.loan_id = p_loan_id
       AND n.status = 'ACTIVE' AND NOT n.is_deleted
$$;

DROP FUNCTION IF EXISTS mbr.add_nominee(uuid, jsonb);
DROP FUNCTION IF EXISTS mbr.update_nominee(uuid, jsonb, integer);
DROP FUNCTION IF EXISTS mbr.assert_nominee_values(jsonb, boolean);

REVOKE ALL ON FUNCTION mbr.nomination_rules(date), mbr.nominee_json(mbr.nominee),
    mbr.assert_relationship(text), mbr.assert_nomination_allowed(uuid, uuid),
    mbr.list_nominees(uuid, boolean), mbr.add_nominee(uuid, uuid, text),
    mbr.update_nominee(uuid, text, integer), mbr.set_nominee_status(uuid, text, integer, text),
    loan.count_active_application_nominees(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION mbr.nomination_rules(date), mbr.nominee_json(mbr.nominee),
    mbr.assert_relationship(text), mbr.assert_nomination_allowed(uuid, uuid),
    mbr.list_nominees(uuid, boolean), mbr.add_nominee(uuid, uuid, text),
    mbr.update_nominee(uuid, text, integer), mbr.set_nominee_status(uuid, text, integer, text),
    loan.count_active_application_nominees(uuid) TO nvs_app;

INSERT INTO platform.error_code (code, short_code, module, category, severity, http_status, is_retryable, raises_alert,
                                 message_template, resolution) VALUES
 ('CFMS-MEM-4002','NOMINEE_NOT_FOUND','MEM','NOT_FOUND','ERROR',404,false,false,'The nominee was not found.','Reload the member and try again.'),
 ('CFMS-MEM-2003','NOMINATION_LIMIT_REACHED','MEM','BUSINESS_RULE','ERROR',422,false,false,'This person is already a nominee for the maximum number of members.','Choose another nominee, or deactivate one of their nominations.'),
 ('CFMS-MEM-2004','NOMINEE_LIMIT_REACHED','MEM','BUSINESS_RULE','ERROR',422,false,false,'This member already has the maximum number of active nominees.','Deactivate a nominee first.'),
 ('CFMS-MEM-2005','NOMINEE_MEMBER_NOT_ELIGIBLE','MEM','BUSINESS_RULE','ERROR',422,false,false,'The nominee must be an active or applied member.','Choose a member who is active or applied.'),
 ('CFMS-MEM-1002','NOMINEE_IS_SELF','MEM','VALIDATION','ERROR',422,false,false,'A member cannot be their own nominee.','Choose a different member.'),
 ('CFMS-MEM-5002','NOMINEE_DUPLICATE','MEM','CONFLICT','ERROR',409,false,false,'This person is already an active nominee of the member.','Edit the existing nomination instead.')
ON CONFLICT (code) DO UPDATE
   SET short_code = EXCLUDED.short_code, module = EXCLUDED.module, category = EXCLUDED.category,
       severity = EXCLUDED.severity, http_status = EXCLUDED.http_status, is_retryable = EXCLUDED.is_retryable,
       raises_alert = EXCLUDED.raises_alert, message_template = EXCLUDED.message_template, resolution = EXCLUDED.resolution;

UPDATE platform.error_code e
   SET translations = coalesce(e.translations, '{}'::jsonb) || jsonb_build_object('ta', t.message)
  FROM (VALUES
 ('NOMINEE_NOT_FOUND','நியமனதாரர் கண்டறியப்படவில்லை.'),
 ('NOMINATION_LIMIT_REACHED','இவர் ஏற்கனவே அதிகபட்ச எண்ணிக்கையிலான உறுப்பினர்களுக்கு நியமனதாரராக உள்ளார்.'),
 ('NOMINEE_LIMIT_REACHED','இந்த உறுப்பினருக்கு ஏற்கனவே அதிகபட்ச எண்ணிக்கையிலான செயலில் உள்ள நியமனதாரர்கள் உள்ளனர்.'),
 ('NOMINEE_MEMBER_NOT_ELIGIBLE','நியமனதாரர் செயலில் உள்ள அல்லது விண்ணப்பித்த உறுப்பினராக இருக்க வேண்டும்.'),
 ('NOMINEE_IS_SELF','ஒரு உறுப்பினர் தனக்குத் தானே நியமனதாரராக இருக்க முடியாது.'),
 ('NOMINEE_DUPLICATE','இவர் ஏற்கனவே இந்த உறுப்பினரின் செயலில் உள்ள நியமனதாரர்.')
  ) AS t(short_code, message)
 WHERE e.short_code = t.short_code;

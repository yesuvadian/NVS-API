-- =============================================================================
-- CFMS / NVS  -  31f  Nominee override (privilege loan.nominee_override)
-- -----------------------------------------------------------------------------
-- Run as nvs after 31e. Safe to re-run.
--
-- The holder of loan.nominee_override may, with a mandatory reason (3-500):
--   (a) submit a loan application without the nominee the NOMINEE rule needs
--       (allowed unless the loan type's NOMINEE.allowOverride is false), and
--   (b) add or reactivate a nomination beyond MEMBER_RULES / NOMINATIONS
--       maxPerPerson (allowed unless NOMINATIONS.allowOverride is false).
-- The reason, who and when are stored on the loan / nominee and audited; the
-- loan detail and approval inbox show them to the approver.
-- Default grant: Manager (role template and existing organisations). Other
-- roles get it through Roles & privileges (new privilege type O = Override).
-- =============================================================================

INSERT INTO platform.privilege_type (type_code, name, description, sort_order)
VALUES ('O', 'Override', 'Override a business rule with a recorded reason', 9)
ON CONFLICT (type_code) DO UPDATE SET name = EXCLUDED.name, description = EXCLUDED.description,
    sort_order = EXCLUDED.sort_order;

INSERT INTO platform.privilege (privilege_code, module_code, type_code, name)
VALUES ('loan.nominee_override', 'LOAN', 'O', 'Loans - Nominee override')
ON CONFLICT (privilege_code) DO NOTHING;

INSERT INTO platform.role_template_privilege (role_code, privilege_code)
VALUES ('MGR', 'loan.nominee_override')
ON CONFLICT DO NOTHING;

ALTER TABLE loan.loan ADD COLUMN IF NOT EXISTS nominee_override_reason text;
ALTER TABLE loan.loan ADD COLUMN IF NOT EXISTS nominee_override_by uuid;
ALTER TABLE loan.loan ADD COLUMN IF NOT EXISTS nominee_override_at timestamptz;
ALTER TABLE mbr.nominee ADD COLUMN IF NOT EXISTS limit_override_reason text;
ALTER TABLE mbr.nominee ADD COLUMN IF NOT EXISTS limit_override_by uuid;
ALTER TABLE mbr.nominee ADD COLUMN IF NOT EXISTS limit_override_at timestamptz;

-- Existing organisations: the privilege joins the ceiling and the Manager role.
DO $$
DECLARE t record;
BEGIN
    FOR t IN SELECT id FROM platform.tenant ORDER BY created_at LOOP
        PERFORM app.set_context(t.id, NULL, NULL, 'MIGRATION', NULL, NULL, NULL, true, NULL);
        INSERT INTO platform.tenant_privilege_ceiling (tenant_id, privilege_code, reason)
        SELECT t.id, 'loan.nominee_override', 'Nominee override privilege (31f)'
         WHERE NOT EXISTS (SELECT 1 FROM platform.tenant_privilege_ceiling c
                            WHERE c.tenant_id = t.id AND c.privilege_code = 'loan.nominee_override');
        INSERT INTO iam.role_privilege (tenant_id, role_id, privilege_code)
        SELECT t.id, r.id, 'loan.nominee_override'
          FROM iam.role r
          JOIN platform.tenant_module tm ON tm.tenant_id = t.id AND tm.module_code = 'LOAN' AND tm.is_enabled
         WHERE r.tenant_id = t.id AND r.role_code = 'MGR'
        ON CONFLICT (tenant_id, role_id, privilege_code) DO NOTHING;
    END LOOP;
    PERFORM app.clear_context();
END
$$;

-- Common checks for an override: privilege, rule switch, reason.
CREATE OR REPLACE FUNCTION mbr.assert_nominee_override(p_allowed boolean, p_reason text, p_refusal text)
RETURNS void LANGUAGE plpgsql STABLE AS
$$
DECLARE v_holder boolean := iam.has_privilege(app.user_id(), 'loan.nominee_override');
BEGIN
    IF NOT v_holder THEN
        PERFORM app.fail(p_refusal, 'The nominee rule applies (no override privilege)');
    END IF;
    IF p_allowed IS NOT TRUE THEN
        PERFORM app.fail('NOMINEE_OVERRIDE_NOT_ALLOWED', 'Overrides are switched off for this rule');
    END IF;
    IF length(btrim(coalesce(p_reason, ''))) NOT BETWEEN 3 AND 500 THEN
        PERFORM app.fail('NOMINEE_OVERRIDE_REASON_REQUIRED', 'Give a reason of 3 to 500 characters to override');
    END IF;
END
$$;

-- Nomination limits, now with an optional override. Returns true when the
-- per-person limit was overridden.
DROP FUNCTION IF EXISTS mbr.assert_nomination_allowed(uuid, uuid);
CREATE OR REPLACE FUNCTION mbr.assert_nomination_allowed(
    p_member_id uuid, p_nominee_member_id uuid, p_override_reason text DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql STABLE AS
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
        IF p_override_reason IS NULL
           AND NOT iam.has_privilege(app.user_id(), 'loan.nominee_override') THEN
            PERFORM app.fail('NOMINATION_LIMIT_REACHED',
                format('This person is already a nominee for %s members', v_per_person));
        END IF;
        PERFORM mbr.assert_nominee_override(coalesce((v_rules ->> 'allowOverride')::boolean, true),
                                            p_override_reason, 'NOMINATION_LIMIT_REACHED');
        RETURN true;
    END IF;
    RETURN false;
END
$$;

DROP FUNCTION IF EXISTS mbr.add_nominee(uuid, uuid, text);
CREATE OR REPLACE FUNCTION mbr.add_nominee(
    p_member_id uuid, p_nominee_member_id uuid, p_relationship text, p_override_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_member   mbr.member%ROWTYPE;
    v_nominee  mbr.member%ROWTYPE;
    v_row      mbr.nominee%ROWTYPE;
    v_override boolean;
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
    PERFORM 1 FROM mbr.member m
      WHERE m.tenant_id = app.tenant_id() AND m.id = p_nominee_member_id FOR UPDATE;
    v_override := mbr.assert_nomination_allowed(p_member_id, p_nominee_member_id, nullif(btrim(p_override_reason), ''));
    IF v_override THEN
        PERFORM app.set_audit_reason('Nomination limit overridden: ' || btrim(p_override_reason), 'NOMINEE_OVERRIDE', NULL);
    END IF;
    SELECT * INTO v_nominee FROM mbr.member m
     WHERE m.tenant_id = app.tenant_id() AND m.id = p_nominee_member_id;
    INSERT INTO mbr.nominee (member_id, nominee_member_id, full_name, relationship, date_of_birth, mobile,
                             limit_override_reason, limit_override_by, limit_override_at)
    VALUES (p_member_id, p_nominee_member_id, v_nominee.full_name, p_relationship,
            v_nominee.date_of_birth, v_nominee.mobile,
            CASE WHEN v_override THEN btrim(p_override_reason) END,
            CASE WHEN v_override THEN app.user_id() END,
            CASE WHEN v_override THEN now() END)
    RETURNING * INTO v_row;
    RETURN mbr.nominee_json(v_row);
END
$$;

DROP FUNCTION IF EXISTS mbr.set_nominee_status(uuid, text, integer, text);
CREATE OR REPLACE FUNCTION mbr.set_nominee_status(
    p_nominee_id uuid, p_status text, p_expected_version integer, p_reason text,
    p_limit_override boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql AS
$$
DECLARE
    v_row      mbr.nominee%ROWTYPE;
    v_override boolean := false;
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
        v_override := mbr.assert_nomination_allowed(v_row.member_id, v_row.nominee_member_id,
                                                    CASE WHEN p_limit_override THEN btrim(p_reason) END);
    END IF;
    PERFORM app.set_audit_reason(
        CASE WHEN v_override THEN 'Nomination limit overridden: ' ELSE '' END || btrim(p_reason),
        CASE WHEN v_override THEN 'NOMINEE_OVERRIDE' ELSE 'NOMINEE' END, p_nominee_id::text);
    UPDATE mbr.nominee SET status = p_status,
        limit_override_reason = CASE WHEN v_override THEN btrim(p_reason) ELSE limit_override_reason END,
        limit_override_by     = CASE WHEN v_override THEN app.user_id() ELSE limit_override_by END,
        limit_override_at     = CASE WHEN v_override THEN now() ELSE limit_override_at END
     WHERE tenant_id = app.tenant_id() AND id = p_nominee_id
    RETURNING * INTO v_row;
    RETURN mbr.nominee_json(v_row);
END
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
        'limit_override', n.limit_override_reason IS NOT NULL,
        'limit_override_reason', n.limit_override_reason,
        'created_at', n.created_at, 'updated_at', n.updated_at, 'row_version', n.row_version)
$$;

-- Loan application: record a nominee override at submission.
CREATE OR REPLACE FUNCTION loan.record_nominee_override(p_loan_id uuid, p_reason text, p_allowed boolean)
RETURNS void LANGUAGE plpgsql AS
$$
BEGIN
    PERFORM mbr.assert_nominee_override(p_allowed, p_reason, 'NOMINEE_REQUIRED');
    PERFORM app.set_audit_reason('Nominee rule overridden: ' || btrim(p_reason), 'NOMINEE_OVERRIDE', p_loan_id::text);
    UPDATE loan.loan
       SET nominee_override_reason = btrim(p_reason), nominee_override_by = app.user_id(),
           nominee_override_at = now()
     WHERE tenant_id = app.tenant_id() AND id = p_loan_id;
    IF NOT FOUND THEN
        PERFORM app.fail('LOAN_APPLICATION_NOT_FOUND', 'Loan application not found');
    END IF;
END
$$;

-- Override details for one or more loans (loan detail and approval inbox).
CREATE OR REPLACE FUNCTION loan.get_nominee_overrides(p_loan_ids uuid[])
RETURNS TABLE (loan_id uuid, nominee_override_reason text, nominee_override_by uuid,
               nominee_override_by_name text, nominee_override_at timestamptz)
LANGUAGE sql STABLE AS
$$
    SELECT l.id, l.nominee_override_reason, l.nominee_override_by, u.full_name, l.nominee_override_at
      FROM loan.loan l
      LEFT JOIN iam.app_user u ON u.tenant_id = l.tenant_id AND u.id = l.nominee_override_by
     WHERE l.tenant_id = app.tenant_id() AND l.id = ANY (p_loan_ids)
       AND l.nominee_override_reason IS NOT NULL
$$;

REVOKE ALL ON FUNCTION mbr.assert_nominee_override(boolean, text, text),
    mbr.assert_nomination_allowed(uuid, uuid, text), mbr.add_nominee(uuid, uuid, text, text),
    mbr.set_nominee_status(uuid, text, integer, text, boolean),
    loan.record_nominee_override(uuid, text, boolean), loan.get_nominee_overrides(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION mbr.assert_nominee_override(boolean, text, text),
    mbr.assert_nomination_allowed(uuid, uuid, text), mbr.add_nominee(uuid, uuid, text, text),
    mbr.set_nominee_status(uuid, text, integer, text, boolean),
    loan.record_nominee_override(uuid, text, boolean), loan.get_nominee_overrides(uuid[]) TO nvs_app;

INSERT INTO platform.error_code (code, short_code, module, category, severity, http_status, is_retryable, raises_alert,
                                 message_template, resolution) VALUES
 ('CFMS-LOAN-1018','NOMINEE_OVERRIDE_REASON_REQUIRED','LOAN','VALIDATION','ERROR',422,false,false,'Give a reason of 3 to 500 characters to override the nominee rule.','Enter why the rule is being overridden.'),
 ('CFMS-LOAN-2035','NOMINEE_OVERRIDE_NOT_ALLOWED','LOAN','BUSINESS_RULE','ERROR',422,false,false,'Overriding the nominee rule is switched off for this loan type.','Add a nominee instead.')
ON CONFLICT (code) DO UPDATE
   SET short_code = EXCLUDED.short_code, module = EXCLUDED.module, category = EXCLUDED.category,
       severity = EXCLUDED.severity, http_status = EXCLUDED.http_status, is_retryable = EXCLUDED.is_retryable,
       raises_alert = EXCLUDED.raises_alert, message_template = EXCLUDED.message_template, resolution = EXCLUDED.resolution;

UPDATE platform.error_code e
   SET translations = coalesce(e.translations, '{}'::jsonb) || jsonb_build_object('ta', t.message)
  FROM (VALUES
 ('NOMINEE_OVERRIDE_REASON_REQUIRED','நியமனதாரர் விதியை மீற 3 முதல் 500 எழுத்துகள் கொண்ட காரணத்தை அளிக்கவும்.'),
 ('NOMINEE_OVERRIDE_NOT_ALLOWED','இந்தக் கடன் வகைக்கு நியமனதாரர் விதியை மீறுவது முடக்கப்பட்டுள்ளது.')
  ) AS t(short_code, message)
 WHERE e.short_code = t.short_code;

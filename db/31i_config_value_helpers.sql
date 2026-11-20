-- =============================================================================
-- CFMS / NVS  -  31i  No hard-coded business values: helpers
-- -----------------------------------------------------------------------------
-- Run as nvs after 31h. Safe to re-run.
--
-- Business values (approver roles, durations, limits, interest method) come
-- from settings, rule-set JSON or workflow JSON, never from literals in code.
-- When a value is missing the call refuses with a clear error instead of
-- guessing a default:
--   SETTING_MISSING        an org setting is not configured;
--   LOAN_RULE_MISSING      the loan's rule snapshot lacks a rule or a field;
--   INTEREST_METHOD_UNSUPPORTED  the INTEREST rule names an unknown method.
-- Defaults live as seed data (platform settings template, rule templates).
-- =============================================================================

-- A configured setting value; refuses when absent or JSON null.
CREATE OR REPLACE FUNCTION cfg.require_setting(p_key text, p_on date DEFAULT NULL, p_tenant_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE AS
$$
DECLARE
    v jsonb := cfg.get_setting(p_key, p_on, p_tenant_id);
BEGIN
    IF v IS NULL OR jsonb_typeof(v) = 'null' THEN
        PERFORM app.fail('SETTING_MISSING', format('Setting %s is not configured for this organisation.', p_key));
    END IF;
    RETURN v;
END
$$;

CREATE OR REPLACE FUNCTION cfg.require_setting_int(p_key text, p_on date DEFAULT NULL, p_tenant_id uuid DEFAULT NULL)
RETURNS integer LANGUAGE sql STABLE AS
$$ SELECT (cfg.require_setting(p_key, p_on, p_tenant_id) #>> '{}')::integer $$;

CREATE OR REPLACE FUNCTION cfg.require_setting_bool(p_key text, p_on date DEFAULT NULL, p_tenant_id uuid DEFAULT NULL)
RETURNS boolean LANGUAGE sql STABLE AS
$$ SELECT (cfg.require_setting(p_key, p_on, p_tenant_id) #>> '{}')::boolean $$;

-- Role codes held in a setting: a JSON array, or a string ("MGR" or "MGR,LDR").
CREATE OR REPLACE FUNCTION cfg.setting_roles(p_key text, p_on date DEFAULT NULL, p_tenant_id uuid DEFAULT NULL)
RETURNS text[] LANGUAGE plpgsql STABLE AS
$$
DECLARE
    v     jsonb := cfg.require_setting(p_key, p_on, p_tenant_id);
    roles text[];
BEGIN
    IF jsonb_typeof(v) = 'array' THEN
        SELECT array_agg(upper(btrim(x))) INTO roles FROM jsonb_array_elements_text(v) x WHERE btrim(x) <> '';
    ELSE
        SELECT array_agg(upper(btrim(x))) INTO roles
          FROM unnest(string_to_array(v #>> '{}', ',')) x WHERE btrim(x) <> '';
    END IF;
    IF coalesce(cardinality(roles), 0) = 0 THEN
        PERFORM app.fail('SETTING_MISSING', format('Setting %s names no roles.', p_key));
    END IF;
    RETURN roles;
END
$$;

-- Approver check whose roles come from a setting (plus maker-checker).
CREATE OR REPLACE FUNCTION loan.assert_approver_setting(p_key text, p_requested_by uuid)
RETURNS void LANGUAGE plpgsql STABLE AS
$$
BEGIN
    PERFORM loan.assert_approver(array_to_string(cfg.setting_roles(p_key), ','), p_requested_by);
END
$$;

-- The value of a rule in a loan's rule snapshot; refuses when absent.
CREATE OR REPLACE FUNCTION loan.require_rule_value(p_snapshot jsonb, p_code text)
RETURNS jsonb LANGUAGE plpgsql STABLE AS
$$
DECLARE
    v jsonb;
BEGIN
    SELECT r -> 'value' INTO v
      FROM jsonb_array_elements(coalesce(p_snapshot -> 'rules', '[]'::jsonb)) r
     WHERE r ->> 'code' = p_code LIMIT 1;
    IF v IS NULL OR jsonb_typeof(v) = 'null' THEN
        PERFORM app.fail('LOAN_RULE_MISSING', format('The loan rules have no %s rule.', p_code));
    END IF;
    RETURN v;
END
$$;

-- Interest by the INTEREST rule's method (one formula per method):
--   FLAT: amount x annual rate% x tenure months / 12 / 100;  NONE: no interest.
CREATE OR REPLACE FUNCTION loan.interest_terms(p_snapshot jsonb, p_amount numeric, p_tenure integer)
RETURNS jsonb LANGUAGE plpgsql STABLE AS
$$
DECLARE
    v_rule   jsonb := loan.require_rule_value(p_snapshot, 'INTEREST');
    v_method text := upper(nullif(btrim(v_rule ->> 'method'), ''));
    v_rate   numeric;
BEGIN
    IF v_method IS NULL THEN
        PERFORM app.fail('LOAN_RULE_MISSING', 'The INTEREST rule has no method.');
    END IF;
    IF v_method = 'NONE' THEN
        RETURN jsonb_build_object('method', 'NONE', 'rate', 0, 'total', 0);
    ELSIF v_method = 'FLAT' THEN
        v_rate := (v_rule ->> 'annualRatePercent')::numeric;
        IF v_rate IS NULL THEN
            PERFORM app.fail('LOAN_RULE_MISSING', 'The INTEREST rule has no annualRatePercent.');
        END IF;
        RETURN jsonb_build_object('method', 'FLAT', 'rate', v_rate,
                                  'total', round(p_amount * v_rate * p_tenure / 12 / 100, 2));
    END IF;
    PERFORM app.fail('INTEREST_METHOD_UNSUPPORTED', format('Interest method %s is not supported.', v_method));
    RETURN NULL;
END
$$;

REVOKE ALL ON FUNCTION cfg.require_setting(text, date, uuid), cfg.require_setting_int(text, date, uuid),
    cfg.require_setting_bool(text, date, uuid), cfg.setting_roles(text, date, uuid),
    loan.assert_approver_setting(text, uuid), loan.require_rule_value(jsonb, text),
    loan.interest_terms(jsonb, numeric, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cfg.require_setting(text, date, uuid), cfg.require_setting_int(text, date, uuid),
    cfg.require_setting_bool(text, date, uuid), cfg.setting_roles(text, date, uuid),
    loan.assert_approver_setting(text, uuid), loan.require_rule_value(jsonb, text),
    loan.interest_terms(jsonb, numeric, integer) TO nvs_app;

INSERT INTO platform.error_code (code, short_code, module, category, severity, http_status, is_retryable, raises_alert,
                                 message_template, resolution) VALUES
 ('CFMS-CFG-2101','SETTING_MISSING','CFG','BUSINESS_RULE','ERROR',409,false,true,'A required setting is not configured for this organisation.','Ask the administrator to configure the setting.'),
 ('CFMS-LOAN-2101','LOAN_RULE_MISSING','LOAN','BUSINESS_RULE','ERROR',409,false,true,'A required loan rule is not configured.','Ask the administrator to complete the loan rules.'),
 ('CFMS-LOAN-2102','INTEREST_METHOD_UNSUPPORTED','LOAN','BUSINESS_RULE','ERROR',409,false,true,'The interest method in the loan rules is not supported.','Ask the administrator to correct the INTEREST rule.')
ON CONFLICT (code) DO UPDATE
   SET short_code = EXCLUDED.short_code, module = EXCLUDED.module, category = EXCLUDED.category,
       severity = EXCLUDED.severity, http_status = EXCLUDED.http_status, is_retryable = EXCLUDED.is_retryable,
       raises_alert = EXCLUDED.raises_alert, message_template = EXCLUDED.message_template, resolution = EXCLUDED.resolution;

UPDATE platform.error_code e
   SET translations = coalesce(e.translations, '{}'::jsonb) || jsonb_build_object('ta', t.message)
  FROM (VALUES
 ('SETTING_MISSING','இந்த நிறுவனத்திற்குத் தேவையான அமைப்பு உள்ளமைக்கப்படவில்லை.'),
 ('LOAN_RULE_MISSING','தேவையான கடன் விதி உள்ளமைக்கப்படவில்லை.'),
 ('INTEREST_METHOD_UNSUPPORTED','கடன் விதிகளில் உள்ள வட்டி முறை ஆதரிக்கப்படவில்லை.')
  ) AS t(short_code, message)
 WHERE e.short_code = t.short_code;

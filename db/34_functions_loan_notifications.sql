-- =============================================================================
-- CFMS / NVS  -  34  Loan notifications and reminders (scope 30.1, 30.2, 6.9, 8.2)
-- -----------------------------------------------------------------------------
-- Run as nvs. Safe to re-run. Messages are queued in notif.notification_message;
-- the delivery worker sends them (DLT/WhatsApp providers, fallback, delivery
-- reports). Queuing here applies:
--   * the organisation's template for the code, channel and language, else the
--     platform default (so templates added later work for existing tenants);
--   * the member's preferred channel and language (falls back to SMS / en);
--   * suppression: deceased member (DECEASED), opted out of non-essential
--     messages (OPTED_OUT), no mobile number (no message);
--   * quiet hours (setting notifications.quiet_hours {"from":"21:00","to":"08:00"}):
--     non-essential messages are scheduled for the end of the quiet period.
--
--   loan.notify(code, recipient_type, recipient_id, to_address, entity_type, entity_id, params)
--   loan.notify_member(code, loan_id, params)        -> borrower of the loan
--   loan.notify_guarantors(code, loan_id, params)    -> active member guarantors
--   loan.notify_nominees(code, loan_id, params)      -> nominees of the loan
--   loan.send_due_reminders(on)                      -> setting notifications.loan_reminder_schedule
-- =============================================================================

CREATE OR REPLACE FUNCTION loan.render_template(p_body text, p_params jsonb)
RETURNS text LANGUAGE plpgsql IMMUTABLE AS
$$
DECLARE
    v_out text := p_body;
    v_key text;
    v_val text;
BEGIN
    FOR v_key, v_val IN SELECT key, value FROM jsonb_each_text(coalesce(p_params, '{}'::jsonb)) LOOP
        v_out := replace(v_out, '{{' || v_key || '}}', coalesce(v_val, ''));
    END LOOP;
    RETURN v_out;
END
$$;

CREATE OR REPLACE FUNCTION loan.notify(
    p_code text, p_recipient_type text, p_recipient_id uuid, p_to_address text,
    p_entity_type text, p_entity_id uuid, p_params jsonb)
RETURNS uuid LANGUAGE plpgsql AS
$$
DECLARE
    v_tenant uuid := app.tenant_id();
    v_member record;
    v_channel text := 'SMS';
    v_language text := 'en';
    v_to text := p_to_address;
    v_tpl record;
    v_params jsonb;
    v_status text := 'QUEUED';
    v_reason text;
    v_at timestamptz := now();
    v_quiet jsonb;
    v_zone text;
    v_local time;
    v_from time;
    v_until time;
    v_id uuid;
BEGIN
    IF v_tenant IS NULL OR p_code IS NULL THEN
        RETURN NULL;
    END IF;
    IF p_recipient_type IN ('MEMBER','GUARANTOR') AND p_recipient_id IS NOT NULL THEN
        SELECT id, full_name, mobile, email, status, preferred_channel, preferred_language INTO v_member
          FROM mbr.member WHERE tenant_id = v_tenant AND id = p_recipient_id;
        IF FOUND THEN
            v_channel := CASE WHEN v_member.preferred_channel IN ('SMS','WHATSAPP','EMAIL') THEN v_member.preferred_channel ELSE 'SMS' END;
            v_language := coalesce(v_member.preferred_language, 'en');
            v_to := coalesce(v_to, CASE WHEN v_channel = 'EMAIL' THEN v_member.email ELSE v_member.mobile END, v_member.mobile);
        END IF;
    END IF;

    -- Organisation template first, then the platform default; preferred
    -- channel and language first, then SMS and English.
    SELECT * INTO v_tpl FROM (
        SELECT t.id, t.channel, t.subject, t.body, t.is_essential, 1 AS src
          FROM notif.notification_template t
         WHERE t.tenant_id = v_tenant AND t.code = p_code AND t.status = 'ACTIVE'
        UNION ALL
        SELECT NULL, d.channel, d.subject, d.body, d.is_essential, 2
          FROM platform.notification_template_default d WHERE d.code = p_code) x
     ORDER BY (x.channel = v_channel) DESC, (x.channel = 'SMS') DESC, x.src
     LIMIT 1;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    IF v_tpl.channel <> v_channel THEN
        v_channel := v_tpl.channel;
        IF v_member.id IS NOT NULL THEN
            v_to := coalesce(p_to_address, CASE WHEN v_channel = 'EMAIL' THEN v_member.email ELSE v_member.mobile END);
        END IF;
    END IF;
    IF v_to IS NULL OR v_to = '' THEN
        RETURN NULL;
    END IF;

    v_params := jsonb_build_object('org_name', (SELECT name FROM platform.tenant WHERE id = v_tenant),
                                   'member_name', v_member.full_name) || coalesce(p_params, '{}'::jsonb);

    IF v_member.id IS NOT NULL AND v_member.status = 'DECEASED' THEN
        v_status := 'SUPPRESSED'; v_reason := 'DECEASED';
    ELSIF v_member.id IS NOT NULL AND NOT v_tpl.is_essential AND EXISTS (
            SELECT 1 FROM mbr.member_consent c
             WHERE c.tenant_id = v_tenant AND c.member_id = v_member.id AND c.channel = v_channel
               AND c.purpose = 'NON_ESSENTIAL' AND NOT c.opted_in) THEN
        v_status := 'SUPPRESSED'; v_reason := 'OPTED_OUT';
    ELSIF NOT v_tpl.is_essential THEN
        v_quiet := coalesce(cfg.get_setting('notifications.quiet_hours'), '{"from":"21:00","to":"08:00"}'::jsonb);
        SELECT time_zone INTO v_zone FROM platform.tenant WHERE id = v_tenant;
        v_local := (now() AT TIME ZONE coalesce(v_zone, 'Asia/Kolkata'))::time;
        v_from := coalesce(v_quiet->>'from', '21:00')::time;
        v_until := coalesce(v_quiet->>'to', '08:00')::time;
        IF (v_from > v_until AND (v_local >= v_from OR v_local < v_until))
           OR (v_from < v_until AND v_local >= v_from AND v_local < v_until) THEN
            v_at := ((date_trunc('day', now() AT TIME ZONE coalesce(v_zone, 'Asia/Kolkata'))
                      + CASE WHEN v_local >= v_until THEN interval '1 day' ELSE interval '0' END + v_until)
                     AT TIME ZONE coalesce(v_zone, 'Asia/Kolkata'));
        END IF;
    END IF;

    INSERT INTO notif.notification_message (notification_template_id, channel, recipient_type, recipient_id, to_address,
                                            subject, body, entity_type, entity_id, status, suppress_reason, scheduled_at)
    VALUES (v_tpl.id, v_channel, p_recipient_type, p_recipient_id, v_to,
            loan.render_template(v_tpl.subject, v_params), loan.render_template(v_tpl.body, v_params),
            p_entity_type, p_entity_id, v_status, v_reason, v_at)
    RETURNING id INTO v_id;
    RETURN v_id;
END
$$;

-- Common loan placeholders: loan_no, borrower_name, amount defaults.
CREATE OR REPLACE FUNCTION loan.loan_params(p_loan_id uuid)
RETURNS jsonb LANGUAGE sql STABLE AS
$$
    SELECT jsonb_build_object('loan_no', l.loan_no, 'borrower_name', m.full_name,
                              'amount', coalesce(l.approved_amount, l.requested_amount),
                              'outstanding', l.outstanding_principal)
      FROM loan.loan l JOIN mbr.member m ON m.tenant_id = l.tenant_id AND m.id = l.member_id
     WHERE l.tenant_id = app.tenant_id() AND l.id = p_loan_id
$$;

CREATE OR REPLACE FUNCTION loan.notify_member(p_code text, p_loan_id uuid, p_params jsonb)
RETURNS uuid LANGUAGE sql AS
$$
    SELECT loan.notify(p_code, 'MEMBER', l.member_id, NULL, 'loan.loan', l.id,
                       loan.loan_params(l.id) || coalesce(p_params, '{}'::jsonb))
      FROM loan.loan l WHERE l.tenant_id = app.tenant_id() AND l.id = p_loan_id
$$;

CREATE OR REPLACE FUNCTION loan.notify_guarantors(p_code text, p_loan_id uuid, p_params jsonb)
RETURNS integer LANGUAGE plpgsql AS
$$
DECLARE
    v_g record;
    v_n integer := 0;
BEGIN
    FOR v_g IN
        SELECT g.id, g.guarantor_member_id, g.non_member_mobile, g.non_member_name
          FROM loan.loan_guarantor g
         WHERE g.tenant_id = app.tenant_id() AND g.loan_id = p_loan_id AND g.status IN ('ACTIVE','INVOKED')
    LOOP
        IF loan.notify(p_code, 'GUARANTOR', v_g.guarantor_member_id, v_g.non_member_mobile, 'loan.loan', p_loan_id,
                       loan.loan_params(p_loan_id) || coalesce(p_params, '{}'::jsonb)
                       || CASE WHEN v_g.guarantor_member_id IS NULL
                               THEN jsonb_build_object('member_name', v_g.non_member_name) ELSE '{}'::jsonb END) IS NOT NULL THEN
            v_n := v_n + 1;
        END IF;
    END LOOP;
    RETURN v_n;
END
$$;

CREATE OR REPLACE FUNCTION loan.notify_nominees(p_code text, p_loan_id uuid, p_params jsonb)
RETURNS integer LANGUAGE plpgsql AS
$$
DECLARE
    v_n record;
    v_count integer := 0;
BEGIN
    FOR v_n IN
        SELECT n.id, n.full_name, n.mobile
          FROM loan.loan_nominee ln
          JOIN mbr.nominee n ON n.tenant_id = ln.tenant_id AND n.id = ln.nominee_id
         WHERE ln.tenant_id = app.tenant_id() AND ln.loan_id = p_loan_id AND n.status = 'ACTIVE'
    LOOP
        IF loan.notify(p_code, 'NOMINEE', v_n.id, v_n.mobile, 'loan.loan', p_loan_id,
                       loan.loan_params(p_loan_id) || coalesce(p_params, '{}'::jsonb)
                       || jsonb_build_object('member_name', v_n.full_name)) IS NOT NULL THEN
            v_count := v_count + 1;
        END IF;
    END LOOP;
    RETURN v_count;
END
$$;

-- Due and overdue reminders (scope 30.1). Setting notifications.loan_reminder_schedule:
--   {"before":[7,3,1],"onDueDate":true,"overdueAfter":1,"repeatEveryDays":7}
-- Run once per working date (the daily job skips it when LOAN_REMINDERS already
-- succeeded for the date); deceased members and loans whose interest stopped
-- are skipped.
CREATE OR REPLACE FUNCTION loan.send_due_reminders(p_on date)
RETURNS integer LANGUAGE plpgsql AS
$$
DECLARE
    v_cfg jsonb := cfg.require_setting('notifications.loan_reminder_schedule');
    v_before integer[];
    v_after integer := greatest((v_cfg->>'overdueAfter')::integer, 1);
    v_every integer := greatest((v_cfg->>'repeatEveryDays')::integer, 1);
    v_row record;
    v_code text;
    v_days integer;
    v_count integer := 0;
BEGIN
    IF jsonb_typeof(v_cfg->'before') IS DISTINCT FROM 'array' OR v_after IS NULL OR v_every IS NULL
       OR jsonb_typeof(v_cfg->'onDueDate') IS DISTINCT FROM 'boolean' THEN
        PERFORM app.fail('SETTING_MISSING',
            'Setting notifications.loan_reminder_schedule needs before, onDueDate, overdueAfter and repeatEveryDays.');
    END IF;
    SELECT coalesce(array_agg(value::integer), '{}') INTO v_before
      FROM jsonb_array_elements_text(v_cfg->'before');
    FOR v_row IN
        SELECT l.id AS loan_id, l.member_id, i.id AS instalment_id, i.due_date,
               i.principal_due - i.principal_paid + i.interest_due - i.interest_paid AS open_amount
          FROM loan.loan l
          JOIN mbr.member m ON m.tenant_id = l.tenant_id AND m.id = l.member_id
          JOIN loan.loan_schedule s ON s.tenant_id = l.tenant_id AND s.loan_id = l.id AND s.is_current
          JOIN loan.loan_instalment i ON i.tenant_id = s.tenant_id AND i.loan_schedule_id = s.id
         WHERE l.tenant_id = app.tenant_id() AND l.status IN ('ACTIVE','OVERDUE','RESTRUCTURED') AND NOT l.is_deleted
           AND l.interest_stopped_from IS NULL AND m.status <> 'DECEASED'
           AND i.status IN ('DUE','PARTLY_PAID')
           AND i.due_date BETWEEN p_on - 3660 AND p_on + 60
    LOOP
        v_days := v_row.due_date - p_on;
        v_code := CASE
            WHEN v_days > 0 AND v_days = ANY (v_before) THEN 'LOAN_DUE_REMINDER'
            WHEN v_days = 0 AND (v_cfg->>'onDueDate')::boolean THEN 'LOAN_DUE_REMINDER'
            WHEN v_days < 0 AND -v_days >= v_after AND (-v_days - v_after) % v_every = 0 THEN 'LOAN_OVERDUE'
            END;
        CONTINUE WHEN v_code IS NULL;
        IF loan.notify(v_code, 'MEMBER', v_row.member_id, NULL, 'loan.loan_instalment', v_row.instalment_id,
                       loan.loan_params(v_row.loan_id)
                       || jsonb_build_object('amount', v_row.open_amount, 'due_date', to_char(v_row.due_date, 'DD-Mon-YYYY'))) IS NOT NULL THEN
            v_count := v_count + 1;
        END IF;
    END LOOP;
    RETURN v_count;
END
$$;

GRANT EXECUTE ON FUNCTION
    loan.render_template(text, jsonb),
    loan.notify(text, text, uuid, text, text, uuid, jsonb),
    loan.loan_params(uuid),
    loan.notify_member(text, uuid, jsonb),
    loan.notify_guarantors(text, uuid, jsonb),
    loan.notify_nominees(text, uuid, jsonb),
    loan.send_due_reminders(date)
TO nvs_app;

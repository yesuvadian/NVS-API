-- Super Admin configuration APIs. Function-only data access keeps SQL out of
-- the Python repository layer; every function also verifies signed platform scope.

CREATE OR REPLACE FUNCTION platform.get_super_admin_configurations(p_tenant_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS
$$
DECLARE v_today date;
BEGIN
    IF app.context_is_valid() IS NOT TRUE OR app.is_platform_scope() IS NOT TRUE
       OR app.role_code() IS DISTINCT FROM 'SUPER_ADMIN' THEN
        PERFORM app.fail('SUPER_ADMIN_REQUIRED','Only a Super Administrator can view configuration');
    END IF;
    v_today:=app.tenant_today(p_tenant_id);
    IF v_today IS NULL THEN PERFORM app.fail('ORGANISATION_NOT_FOUND','Organisation was not found'); END IF;
    RETURN jsonb_build_object(
      'organisation',(SELECT jsonb_build_object('id',t.id,'code',t.code,'name',t.name)
                        FROM platform.tenant t WHERE t.id=p_tenant_id),
      'workflows',coalesce((SELECT jsonb_agg(jsonb_build_object('id',d.id,'code',d.code,'name',d.name,
                       'description',d.description,'version_id',v.id,'version_no',v.version_no,
                       'effective_from',v.effective_from,'definition',v.definition) ORDER BY d.name,d.code)
                     FROM cfg.workflow_definition d JOIN cfg.workflow_version v
                       ON v.tenant_id=d.tenant_id AND v.workflow_definition_id=d.id
                    WHERE d.tenant_id=p_tenant_id AND d.status='ACTIVE' AND v.status='PUBLISHED'
                      AND v.effective_from<=v_today AND (v.effective_to IS NULL OR v.effective_to>=v_today)),
                    '[]'::jsonb),
      'rule_sets',coalesce((SELECT jsonb_agg(jsonb_build_object('id',s.id,'code',s.code,'name',s.name,
                       'module_code',s.module_code,'scope_type',s.scope_type,'description',s.description,
                       'version_id',v.id,'version_no',v.version_no,'effective_from',v.effective_from,
                       'definition',v.definition) ORDER BY s.name,s.code)
                     FROM cfg.rule_set s JOIN cfg.rule_set_version v
                       ON v.tenant_id=s.tenant_id AND v.rule_set_id=s.id
                    WHERE s.tenant_id=p_tenant_id AND s.status='ACTIVE' AND v.status='PUBLISHED'
                      AND v.effective_from<=v_today AND (v.effective_to IS NULL OR v.effective_to>=v_today)),
                    '[]'::jsonb));
END
$$;

CREATE OR REPLACE FUNCTION platform.validate_super_admin_configuration(
    p_tenant_id uuid,p_kind text,p_code text,p_definition jsonb
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS
$$
DECLARE v_errors text[]; v_kind text:=upper(p_kind); v_exists boolean;
BEGIN
    IF app.context_is_valid() IS NOT TRUE OR app.is_platform_scope() IS NOT TRUE
       OR app.role_code() IS DISTINCT FROM 'SUPER_ADMIN' THEN
        PERFORM app.fail('SUPER_ADMIN_REQUIRED','Only a Super Administrator can validate configuration');
    END IF;
    IF app.tenant_today(p_tenant_id) IS NULL THEN PERFORM app.fail('ORGANISATION_NOT_FOUND','Organisation was not found'); END IF;
    IF v_kind='WORKFLOW' THEN
        SELECT EXISTS(SELECT 1 FROM cfg.workflow_definition WHERE tenant_id=p_tenant_id AND code=p_code AND status='ACTIVE') INTO v_exists;
        IF NOT v_exists THEN PERFORM app.fail('INVALID_DOCUMENT','Workflow configuration was not found'); END IF;
        v_errors:=cfg.validate_workflow(p_definition,p_tenant_id);
    ELSIF v_kind IN ('RULESET','RULE_SET') THEN
        SELECT EXISTS(SELECT 1 FROM cfg.rule_set WHERE tenant_id=p_tenant_id AND code=p_code AND status='ACTIVE') INTO v_exists;
        IF NOT v_exists THEN PERFORM app.fail('INVALID_DOCUMENT','Rule set configuration was not found'); END IF;
        v_errors:=cfg.validate_rule_set(p_definition,p_tenant_id);
    ELSE
        PERFORM app.fail('INVALID_DOCUMENT','Configuration kind must be WORKFLOW or RULESET');
    END IF;
    RETURN jsonb_build_object('valid',coalesce(cardinality(v_errors),0)=0,
                              'errors',coalesce(to_jsonb(v_errors),'[]'::jsonb));
END
$$;

CREATE OR REPLACE FUNCTION platform.publish_super_admin_configuration(
    p_tenant_id uuid,p_kind text,p_code text,p_definition jsonb,p_reason text,p_effective_from date
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS
$$
DECLARE
    v_kind text:=upper(p_kind); v_today date; v_id uuid; v_schema uuid;
    v_next integer; v_next_date date; v_new_id uuid; v_errors text[];
BEGIN
    IF app.context_is_valid() IS NOT TRUE OR app.is_platform_scope() IS NOT TRUE
       OR app.role_code() IS DISTINCT FROM 'SUPER_ADMIN' THEN
        PERFORM app.fail('SUPER_ADMIN_REQUIRED','Only a Super Administrator can publish configuration');
    END IF;
    v_today:=app.tenant_today(p_tenant_id);
    IF v_today IS NULL THEN PERFORM app.fail('ORGANISATION_NOT_FOUND','Organisation was not found'); END IF;
    IF p_effective_from IS NULL OR p_effective_from<v_today THEN
        PERFORM app.fail('INVALID_DOCUMENT','Effective date must be today or a future date');
    END IF;
    IF coalesce(length(btrim(p_reason)),0)<3 THEN PERFORM app.fail('REASON_REQUIRED','Enter a reason with at least three characters'); END IF;
    PERFORM set_config('app.reason',p_reason,true);
    IF v_kind='WORKFLOW' THEN
        SELECT id INTO v_id FROM cfg.workflow_definition WHERE tenant_id=p_tenant_id AND code=p_code AND status='ACTIVE' FOR UPDATE;
        IF v_id IS NULL THEN PERFORM app.fail('INVALID_DOCUMENT','Workflow configuration was not found'); END IF;
        v_errors:=cfg.validate_workflow(p_definition,p_tenant_id);
        IF cardinality(v_errors)>0 THEN PERFORM app.fail('INVALID_DOCUMENT',array_to_string(v_errors,'; ')); END IF;
        SELECT coalesce(max(version_no),0)+1 INTO v_next FROM cfg.workflow_version WHERE tenant_id=p_tenant_id AND workflow_definition_id=v_id;
        SELECT min(effective_from) INTO v_next_date FROM cfg.workflow_version WHERE tenant_id=p_tenant_id
          AND workflow_definition_id=v_id AND status='PUBLISHED' AND effective_from>p_effective_from;
        SELECT json_schema_id INTO v_schema FROM cfg.workflow_version WHERE tenant_id=p_tenant_id
          AND workflow_definition_id=v_id ORDER BY version_no DESC LIMIT 1;
        UPDATE cfg.workflow_version SET effective_to=p_effective_from-1,updated_at=now(),updated_by=app.platform_user_id()
          WHERE tenant_id=p_tenant_id AND workflow_definition_id=v_id AND status='PUBLISHED'
            AND effective_from<p_effective_from AND (effective_to IS NULL OR effective_to>=p_effective_from);
        UPDATE cfg.workflow_version SET status='RETIRED',updated_at=now(),updated_by=app.platform_user_id()
          WHERE tenant_id=p_tenant_id AND workflow_definition_id=v_id AND status='PUBLISHED' AND effective_from=p_effective_from;
        INSERT INTO cfg.workflow_version (tenant_id,workflow_definition_id,version_no,status,definition,schema_version,
          json_schema_id,effective_from,effective_to,reason,source,published_by,published_at)
        VALUES (p_tenant_id,v_id,v_next,'PUBLISHED',p_definition,'1.0',v_schema,p_effective_from,
          CASE WHEN v_next_date IS NULL THEN NULL ELSE v_next_date-1 END,p_reason,'DESIGNER',app.platform_user_id(),now())
        RETURNING id INTO v_new_id;
    ELSIF v_kind IN ('RULESET','RULE_SET') THEN
        SELECT id INTO v_id FROM cfg.rule_set WHERE tenant_id=p_tenant_id AND code=p_code AND status='ACTIVE' FOR UPDATE;
        IF v_id IS NULL THEN PERFORM app.fail('INVALID_DOCUMENT','Rule set configuration was not found'); END IF;
        v_errors:=cfg.validate_rule_set(p_definition,p_tenant_id);
        IF cardinality(v_errors)>0 THEN PERFORM app.fail('INVALID_DOCUMENT',array_to_string(v_errors,'; ')); END IF;
        SELECT coalesce(max(version_no),0)+1 INTO v_next FROM cfg.rule_set_version WHERE tenant_id=p_tenant_id AND rule_set_id=v_id;
        SELECT min(effective_from) INTO v_next_date FROM cfg.rule_set_version WHERE tenant_id=p_tenant_id
          AND rule_set_id=v_id AND status='PUBLISHED' AND effective_from>p_effective_from;
        SELECT json_schema_id INTO v_schema FROM cfg.rule_set_version WHERE tenant_id=p_tenant_id
          AND rule_set_id=v_id ORDER BY version_no DESC LIMIT 1;
        UPDATE cfg.rule_set_version SET effective_to=p_effective_from-1,updated_at=now(),updated_by=app.platform_user_id()
          WHERE tenant_id=p_tenant_id AND rule_set_id=v_id AND status='PUBLISHED'
            AND effective_from<p_effective_from AND (effective_to IS NULL OR effective_to>=p_effective_from);
        UPDATE cfg.rule_set_version SET status='RETIRED',updated_at=now(),updated_by=app.platform_user_id()
          WHERE tenant_id=p_tenant_id AND rule_set_id=v_id AND status='PUBLISHED' AND effective_from=p_effective_from;
        INSERT INTO cfg.rule_set_version (tenant_id,rule_set_id,version_no,status,definition,schema_version,
          json_schema_id,effective_from,effective_to,reason,source,published_by,published_at)
        VALUES (p_tenant_id,v_id,v_next,'PUBLISHED',p_definition,'1.0',v_schema,p_effective_from,
          CASE WHEN v_next_date IS NULL THEN NULL ELSE v_next_date-1 END,p_reason,'DESIGNER',app.platform_user_id(),now())
        RETURNING id INTO v_new_id;
    ELSE
        PERFORM app.fail('INVALID_DOCUMENT','Configuration kind must be WORKFLOW or RULESET');
    END IF;
    RETURN jsonb_build_object('id',v_new_id,'kind',v_kind,'code',p_code,'version_no',v_next,
                              'effective_from',p_effective_from,'status','PUBLISHED');
END
$$;

REVOKE ALL ON FUNCTION platform.get_super_admin_configurations(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION platform.validate_super_admin_configuration(uuid,text,text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION platform.publish_super_admin_configuration(uuid,text,text,jsonb,text,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION platform.get_super_admin_configurations(uuid) TO nvs_app;
GRANT EXECUTE ON FUNCTION platform.validate_super_admin_configuration(uuid,text,text,jsonb) TO nvs_app;
GRANT EXECUTE ON FUNCTION platform.publish_super_admin_configuration(uuid,text,text,jsonb,text,date) TO nvs_app;

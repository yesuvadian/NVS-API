from uuid import uuid4

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.core.tenant_security import TenantPrincipal, require_tenant_user
from app.db.dependencies import get_tenant_db
from app.routers.tenant_settings import router


# Standard role privileges for the organisation-settings checks.
ROLE_PRIVILEGES = {'ADM': {'org.view', 'org.edit'}, 'LDR': {'org.view', 'org.approve'}, 'EMP': set()}


class FakeConnection:
    def __init__(self, role_code):
        self.role_code = role_code

    async def execute(self, query, params=None):
        assert 'has_privilege' in query, query
        return PrivilegeResult(params[1] in ROLE_PRIVILEGES.get(self.role_code, set()))


class PrivilegeResult:
    def __init__(self, allowed):
        self.allowed = allowed

    async def fetchone(self):
        return {'allowed': self.allowed}


class SettingsServiceFake:
    calls = []

    def __init__(self, _conn):
        pass

    async def page_size(self, *, include_pending=True):
        self.calls.append(('page_size', include_pending))
        return {
            'page_size': 15,
            'pending_setting_id': None,
            'pending_page_size': None,
        }

    async def request_page_size(self, page_size):
        self.calls.append(('request', page_size))
        return {'setting_id': uuid4(), 'status': 'PENDING_APPROVAL', 'page_size': page_size}

    async def decide_page_size(self, setting_id, approve, reason):
        self.calls.append(('decide', setting_id, approve, reason))


def _client(monkeypatch, role_code):
    app = FastAPI()
    app.include_router(router, prefix='/api/v1')
    principal = TenantPrincipal(
        tenant_id=uuid4(), user_id=uuid4(), session_id=uuid4(), role_code=role_code,
        channel='WEB', mfa_verified=False,
    )

    async def fake_db():
        yield FakeConnection(role_code)

    app.dependency_overrides[get_tenant_db] = fake_db
    app.dependency_overrides[require_tenant_user] = lambda: principal
    monkeypatch.setattr('app.routers.tenant_settings.TenantSettingsService', SettingsServiceFake)
    SettingsServiceFake.calls = []
    return TestClient(app)


def test_org_admin_page_size_update_is_saved_as_pending_approval(monkeypatch):
    client = _client(monkeypatch, 'ADM')
    response = client.put('/api/v1/tenant-settings/page-size', json={'page_size': 25})
    assert response.status_code == 200, response.text
    assert response.json()['page_size'] == 25
    assert response.json()['status'] == 'PENDING_APPROVAL'
    assert SettingsServiceFake.calls == [('request', 25)]


def test_page_size_change_is_validated_and_only_org_admin_can_request(monkeypatch):
    employee = _client(monkeypatch, 'EMP')
    denied = employee.put('/api/v1/tenant-settings/page-size', json={'page_size': 25})
    assert denied.status_code == 403
    assert SettingsServiceFake.calls == []

    admin = _client(monkeypatch, 'ADM')
    invalid = admin.put('/api/v1/tenant-settings/page-size', json={'page_size': 101})
    assert invalid.status_code == 422
    assert SettingsServiceFake.calls == []


def test_leadership_can_decide_a_pending_page_size_change(monkeypatch):
    client = _client(monkeypatch, 'LDR')
    setting_id = uuid4()
    response = client.post(
        f'/api/v1/tenant-settings/page-size/{setting_id}/decision',
        json={'approve': True, 'reason': 'Approved'},
    )
    assert response.status_code == 204
    assert SettingsServiceFake.calls == [('decide', setting_id, True, 'Approved')]


def test_any_tenant_user_can_read_page_size_without_pending_details(monkeypatch):
    employee = _client(monkeypatch, 'EMP')
    response = employee.get('/api/v1/tenant-settings/page-size')
    assert response.status_code == 200, response.text
    assert response.json()['page_size'] == 15
    assert SettingsServiceFake.calls == [('page_size', False)]

    admin = _client(monkeypatch, 'ADM')
    assert admin.get('/api/v1/tenant-settings/page-size').status_code == 200
    assert SettingsServiceFake.calls == [('page_size', True)]

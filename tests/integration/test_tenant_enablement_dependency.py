import asyncio
from contextlib import asynccontextmanager
from uuid import uuid4

import pytest
from fastapi import FastAPI
from starlette.requests import Request

from app.core.config import Settings
from app.core.errors import AppError
from app.core.tenant_security import TenantPrincipal
from app.db.dependencies import get_tenant_db


class Cursor:
    def __init__(self, row):
        self.row = row

    async def fetchone(self):
        return self.row


class Connection:
    def __init__(self):
        self.queries = []

    def transaction(self):
        return self

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_args):
        return False

    async def execute(self, query, _params=None):
        self.queries.append(query)
        if 'get_tenant_access' in query:
            return Cursor({'tenant_enabled': False, 'requires_mfa': False})
        raise AssertionError(f'Unexpected query after disabled tenant: {query}')


class Pool:
    def __init__(self, connection):
        self.value = connection

    @asynccontextmanager
    async def connection(self):
        yield self.value


def test_disabled_tenant_request_is_rejected_before_session_use(monkeypatch):
    connection = Connection()
    app = FastAPI()
    app.state.database = type('DatabaseStub', (), {'pool': Pool(connection)})()
    request = Request({
        'type': 'http', 'asgi': {'version': '3.0'}, 'http_version': '1.1',
        'method': 'PATCH', 'scheme': 'http', 'path': '/api/v1/users',
        'raw_path': b'/api/v1/users', 'query_string': b'', 'root_path': '',
        'headers': [], 'client': ('127.0.0.1', 12345), 'server': ('test', 80),
        'app': app,
    })
    principal = TenantPrincipal(
        tenant_id=uuid4(), user_id=uuid4(), session_id=uuid4(), role_code='ADM',
        channel='WEB', mfa_verified=False,
    )
    monkeypatch.setattr(
        'app.db.dependencies.set_signed_tenant_context',
        lambda *_args: _async_none(),
    )

    async def run():
        generator = get_tenant_db(request, principal, Settings(_env_file=None))
        with pytest.raises(AppError) as error:
            await anext(generator)
        assert error.value.short_code == 'ORGANISATION_DISABLED'

    asyncio.run(run())
    assert len(connection.queries) == 1


async def _async_none():
    return None

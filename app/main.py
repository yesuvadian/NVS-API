from contextlib import asynccontextmanager
import asyncio
import sys

import uvicorn
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

import logging

# Psycopg's async libpq transport does not support Windows ProactorEventLoop.
# Keep the standard Selector loop for local Windows API runs and tests.
if sys.platform == "win32":
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())

from app.core.config import get_settings
from app.core.errors import install_error_handlers, localisation
from app.db.pool import Database
from app.routers import auth, health, loan_reports, loan_servicing, loans, members, super_admin, tenant_settings, users


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = get_settings()
    database = Database(settings)
    app.state.database = database
    await database.open()
    try:
        await localisation.load(database.pool)
    except Exception:  # the API still starts; errors fall back to short codes
        logging.getLogger("cfms.errors").warning("Error catalogue not loaded", exc_info=True)
    try:
        yield
    finally:
        await database.close()


def create_app() -> FastAPI:
    settings = get_settings()
    application = FastAPI(
        title="CFMS API",
        version="0.1.0",
        description="Tenant operations and platform administration endpoints for CFMS.",
        lifespan=lifespan,
    )
    install_error_handlers(application)
    if settings.cors_origins or settings.cors_origin_regex:
        application.add_middleware(
            CORSMiddleware,
            allow_origins=settings.cors_origins,
            allow_origin_regex=settings.cors_origin_regex,
            allow_credentials=False,
            allow_methods=["GET", "POST", "PATCH", "PUT", "DELETE", "OPTIONS"],
            allow_headers=[
                "Authorization", "Content-Type", "Accept-Language", "X-Device-Id", "X-Working-Date",
                "Idempotency-Key", "X-Expected-Row-Version",
            ],
            expose_headers=["Idempotent-Replayed"],
        )
    application.include_router(health.router)
    application.include_router(auth.router, prefix=settings.api_prefix)
    application.include_router(users.router, prefix=settings.api_prefix)
    application.include_router(tenant_settings.router, prefix=settings.api_prefix)
    application.include_router(super_admin.router, prefix=settings.api_prefix)
    application.include_router(members.router, prefix=settings.api_prefix)
    application.include_router(loans.router, prefix=settings.api_prefix)
    application.include_router(loan_servicing.router, prefix=settings.api_prefix)
    application.include_router(loan_reports.router, prefix=settings.api_prefix)
    return application


app = create_app()


if __name__ == "__main__":
    settings = get_settings()
    uvicorn.run("app.main:app", workers=settings.web_concurrency)


from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI

import logging

from app.core.config import get_settings
from app.core.errors import install_error_handlers, localisation
from app.db.pool import Database
from app.routers import health, loan_reports, loan_servicing, loans, members, super_admin


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
    application.include_router(health.router)
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


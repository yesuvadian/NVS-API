from functools import lru_cache
from pathlib import Path

from psycopg.conninfo import make_conninfo
from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict

# .env lives in the project root, next to seed.py and jobs.py, so every entry
# point finds it whatever the current directory is.
ENV_FILE = Path(__file__).resolve().parents[2] / ".env"


class DatabaseNotConfigured(RuntimeError):
    """Raised when the database connection settings are missing from .env."""


def _dsn(*, host: str | None, port: int | None, name: str | None, user: str | None,
         password: SecretStr | None, user_var: str, password_var: str) -> str:
    missing = [var for var, value in (("CFMS_DB_HOST", host), ("CFMS_DB_PORT", port),
                                      ("CFMS_DB_NAME", name), (user_var, user)) if not value]
    if missing:
        raise DatabaseNotConfigured(
            f"Set {', '.join(missing)} (and {password_var}) in .env; see .env.example."
        )
    values = {"host": host, "port": port, "dbname": name, "user": user}
    if password is not None and password.get_secret_value():
        values["password"] = password.get_secret_value()
    return make_conninfo(**values)


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="CFMS_", env_file=ENV_FILE, extra="ignore")

    # Database: host, port and name are shared; the API/jobs connect as the
    # runtime login (CFMS_DB_USER, member of nvs_app) and seed.py as the schema
    # owner (CFMS_SEED_DB_USER, nvs). Nothing is hard-coded: all come from .env.
    db_host: str | None = None
    db_port: int | None = None
    db_name: str | None = None
    db_user: str | None = None
    db_password: SecretStr | None = None
    seed_db_user: str | None = None
    seed_db_password: SecretStr | None = None
    database_pool_min: int = 1
    database_pool_max: int = 10
    web_concurrency: int = Field(default=1, ge=1, validation_alias="WEB_CONCURRENCY")
    require_platform_mfa: bool = True
    platform_jwt_secret: SecretStr | None = None
    platform_jwt_issuer: str = "cfms-platform"
    platform_jwt_audience: str = "cfms-super-admin-api"
    tenant_jwt_secret: SecretStr | None = None
    tenant_jwt_issuer: str = "cfms-tenant"
    tenant_jwt_audience: str = "cfms-tenant-api"
    db_context_signing_key: SecretStr | None = None
    api_prefix: str = "/api/v1"

    @property
    def database_url(self) -> str:
        """Connection string of the runtime role (API and jobs.py)."""
        return _dsn(host=self.db_host, port=self.db_port, name=self.db_name,
                    user=self.db_user, password=self.db_password,
                    user_var="CFMS_DB_USER", password_var="CFMS_DB_PASSWORD")

    @property
    def seed_database_url(self) -> str:
        """Connection string of the schema owner (seed.py and database tests)."""
        return _dsn(host=self.db_host, port=self.db_port, name=self.db_name,
                    user=self.seed_db_user, password=self.seed_db_password,
                    user_var="CFMS_SEED_DB_USER", password_var="CFMS_SEED_DB_PASSWORD")


@lru_cache
def get_settings() -> Settings:
    return Settings()

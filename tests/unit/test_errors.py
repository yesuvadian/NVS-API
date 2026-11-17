from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.core.errors import AppError, install_error_handlers, localisation

CATALOGUE = {
    "codes": {
        "NO_PRIVILEGE": {
            "code": "CFMS-AUTH-3003",
            "http": 403,
            "retryable": False,
            "message": "You do not have permission to do this.",
            "translations": {"ta": "இதைச் செய்ய உங்களுக்கு அனுமதி இல்லை."},
        },
        "UNSUPPORTED_LANGUAGE": {
            "code": "CFMS-PLAT-1003",
            "http": 422,
            "retryable": False,
            "message": "Language {language} is not supported.",
            "translations": {"ta": "{language} மொழி ஆதரிக்கப்படவில்லை."},
        },
        "STALE_RECORD": {
            "code": "CFMS-SYS-5005",
            "http": 409,
            "retryable": False,
            "message": "This record was changed after you opened it.",
            "translations": {},
        },
    },
    "sqlstates": {},
    "constraints": {},
}


def make_client() -> TestClient:
    localisation.codes = CATALOGUE["codes"]
    localisation.languages = {"en", "ta"}
    localisation.default_language = "en"
    app = FastAPI()
    install_error_handlers(app)

    @app.get("/denied")
    async def denied():
        raise AppError("NO_PRIVILEGE", params={"privilege": "loan.view"})

    @app.get("/language")
    async def language():
        raise AppError("UNSUPPORTED_LANGUAGE", params={"language": "fr"})

    @app.get("/stale")
    async def stale():
        raise AppError("STALE_RECORD")

    return TestClient(app)


def test_error_uses_catalogue_code_and_english_by_default() -> None:
    response = make_client().get("/denied")

    assert response.status_code == 403
    assert response.json()["detail"] == {
        "code": "CFMS-AUTH-3003",
        "shortCode": "NO_PRIVILEGE",
        "message": "You do not have permission to do this.",
        "language": "en",
        "retryable": False,
        "params": {"privilege": "loan.view"},
    }


def test_error_message_follows_accept_language() -> None:
    client = make_client()

    tamil = client.get("/denied", headers={"Accept-Language": "ta-IN,ta;q=0.9,en;q=0.8"})
    assert tamil.json()["detail"]["message"] == "இதைச் செய்ய உங்களுக்கு அனுமதி இல்லை."
    assert tamil.json()["detail"]["language"] == "ta"

    filled = client.get("/language", headers={"Accept-Language": "ta"})
    assert filled.json()["detail"]["message"] == "fr மொழி ஆதரிக்கப்படவில்லை."


def test_missing_translation_or_unknown_language_falls_back_to_english() -> None:
    client = make_client()

    no_tamil = client.get("/stale", headers={"Accept-Language": "ta"})
    assert no_tamil.status_code == 409
    assert no_tamil.json()["detail"]["language"] == "en"

    unknown = client.get("/denied", headers={"Accept-Language": "fr-FR"})
    assert unknown.json()["detail"]["message"] == "You do not have permission to do this."

"""Provider configuration store for the Codex bridge.

Holds a list of upstream providers and which one is active. Deliberately plain:
one JSON file next to the bridge, atomic writes, no database.

    providers = [
        {
            "id": "a1b2c3",              # stable random id
            "name": "Local gateway",
            "base_url": "http://127.0.0.1:7863/v1",
            "api_key": "sk-...",
            "model": "deepseek-v4.1-flash",
            "notes": "optional free text",
        },
    ]
    active = "a1b2c3"

`active` selects the upstream credentials and the default model. The bridge
forwards the `model` from each request, so providers sharing the same upstream
can serve several models without a restart.
"""

from __future__ import annotations

import json
import os
import secrets
import tempfile
from pathlib import Path
from typing import Any


class ConfigError(Exception):
    """Raised when the config file is unreadable or invalid."""


DEFAULTS: dict[str, Any] = {
    "providers": [],
    "active": None,
    "sanitize_prompt": True,
    "host": "127.0.0.1",
    "port": 8787,
}


class ConfigStore:
    def __init__(self, path: str | Path) -> None:
        self.path = Path(path)
        self._data: dict[str, Any] = dict(DEFAULTS)
        self.load()

    # ---------------------------------------------------------------- load
    def load(self) -> dict[str, Any]:
        if not self.path.exists():
            self._data = json.loads(json.dumps(DEFAULTS))
            return self._data
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise ConfigError(f"cannot read {self.path}: {exc}") from exc
        if not isinstance(raw, dict):
            raise ConfigError(f"{self.path} must contain a JSON object")

        data = json.loads(json.dumps(DEFAULTS))
        data.update({k: v for k, v in raw.items() if k in DEFAULTS or k == "active"})
        data["providers"] = [p for p in data.get("providers", []) if isinstance(p, dict)]
        if data["active"] not in {p.get("id") for p in data["providers"]}:
            data["active"] = data["providers"][0]["id"] if data["providers"] else None
        self._data = data
        return self._data

    # ---------------------------------------------------------------- save
    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        # Atomic: write a sibling temp file, then replace. A crash mid-write
        # otherwise leaves a half-written JSON that bricks the tray.
        fd, tmp = tempfile.mkstemp(dir=str(self.path.parent), suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump(self._data, fh, indent=2, ensure_ascii=False)
                fh.write("\n")
            os.replace(tmp, self.path)
        except BaseException:
            Path(tmp).unlink(missing_ok=True)
            raise

    # ------------------------------------------------------------ accessors
    @property
    def providers(self) -> list[dict[str, Any]]:
        return self._data["providers"]

    @property
    def active_id(self) -> str | None:
        return self._data.get("active")

    def active(self) -> dict[str, Any] | None:
        for p in self.providers:
            if p.get("id") == self._data.get("active"):
                return p
        return None

    def get(self, provider_id: str) -> dict[str, Any] | None:
        for p in self.providers:
            if p.get("id") == provider_id:
                return p
        return None

    @property
    def sanitize_prompt(self) -> bool:
        return bool(self._data.get("sanitize_prompt", True))

    @property
    def host(self) -> str:
        return str(self._data.get("host", "127.0.0.1"))

    @property
    def port(self) -> int:
        return int(self._data.get("port", 8787))

    # -------------------------------------------------------------- mutate
    @staticmethod
    def _clean(payload: dict[str, Any]) -> dict[str, Any]:
        name = str(payload.get("name", "")).strip()
        base_url = str(payload.get("base_url", "")).strip().rstrip("/")
        api_key = str(payload.get("api_key", "")).strip()
        model = str(payload.get("model", "")).strip()
        if not name:
            raise ConfigError("name is required")
        if not base_url.startswith(("http://", "https://")):
            raise ConfigError("base_url must start with http:// or https://")
        if not model:
            raise ConfigError("model is required")
        return {
            "name": name,
            "base_url": base_url,
            "api_key": api_key,
            "model": model,
            "notes": str(payload.get("notes", "")).strip(),
        }

    def add(self, payload: dict[str, Any]) -> dict[str, Any]:
        clean = self._clean(payload)
        clean["id"] = secrets.token_hex(4)
        self.providers.append(clean)
        if not self._data.get("active"):
            self._data["active"] = clean["id"]
        self.save()
        return clean

    def update(self, provider_id: str, payload: dict[str, Any]) -> dict[str, Any]:
        target = self.get(provider_id)
        if target is None:
            raise ConfigError(f"no provider with id {provider_id}")
        clean = self._clean({**target, **payload})
        target.update(clean)
        self.save()
        return target

    def remove(self, provider_id: str) -> None:
        before = len(self.providers)
        self._data["providers"] = [p for p in self.providers if p.get("id") != provider_id]
        if len(self._data["providers"]) == before:
            raise ConfigError(f"no provider with id {provider_id}")
        if self._data.get("active") == provider_id:
            self._data["active"] = (
                self._data["providers"][0]["id"] if self._data["providers"] else None
            )
        self.save()

    def activate(self, provider_id: str) -> None:
        if self.get(provider_id) is None:
            raise ConfigError(f"no provider with id {provider_id}")
        self._data["active"] = provider_id
        self.save()

    def set_sanitize(self, enabled: bool) -> None:
        self._data["sanitize_prompt"] = bool(enabled)
        self.save()

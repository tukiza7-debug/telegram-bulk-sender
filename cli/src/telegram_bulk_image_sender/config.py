"""Typed configuration: file (YAML/TOML) + env secrets + CLI overrides.

Precedence (highest wins): CLI flags > environment (secrets only) > config
file > built-in defaults. Validation is strict: every offending key is named
in the error message; unknown keys are rejected (typo protection). There are
no dict.get(..., None) chains that defer failure to runtime.

Secrets (the bot token) NEVER live in the config file: they come from the
environment variable named by ``security.token_env`` (default
``TELEGRAM_BOT_TOKEN``) or from a git-ignored secrets file
(``security.secrets_file``).
"""

from __future__ import annotations

import re
import tomllib
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from typing import TypeVar
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import yaml

from .errors import ConfigError, SecretError
from .model import CaptionMode, OrderKey, ParseMode

_E = TypeVar("_E", bound=StrEnum)

# Official Bot API documents sendPhoto at "at most 10 MB"; the cap is
# configurable so a self-hosted Bot API server can raise it.
# Source: https://core.telegram.org/bots/api#sendphoto (fetched 2026-09-30).
ABSOLUTE_MAX_FILE_MB = 2000

DEFAULT_API_BASE_URL = "https://api.telegram.org"
DEFAULT_TOKEN_ENV = "TELEGRAM_BOT_TOKEN"

# Shape of a bot token per Bot API convention: numeric bot id, colon,
# alphanumeric secret. Validation here is shape-only; getMe is the judge.
_TOKEN_RE = re.compile(r"^[0-9]{5,}:[A-Za-z0-9_-]{20,}$")

_HHMM_RE = re.compile(r"^([01][0-9]|2[0-3]):([0-5][0-9])$")


@dataclass(frozen=True)
class TelegramConfig:
    api_base_url: str = DEFAULT_API_BASE_URL
    parse_mode: ParseMode = ParseMode.HTML
    timeout_seconds: float = 60.0


@dataclass(frozen=True)
class QuietHoursConfig:
    enabled: bool = False
    start: str = "22:00"
    end: str = "07:00"
    timezone: str = "UTC"


@dataclass(frozen=True)
class LimitsConfig:
    # Conservative pacing defaults. The per-recipient default sits below the
    # commonly cited ~20 msgs/minute group limit, which is NOT part of the
    # official Bot API page -> UNVERIFIED: treated as folklore, default is 18.
    global_per_minute: float = 60.0
    per_recipient_per_minute: float = 18.0
    daily_cap_per_recipient: int = 50
    quiet_hours: QuietHoursConfig = QuietHoursConfig()


@dataclass(frozen=True)
class KillSwitchConfig:
    failure_rate: float = 0.5
    window_minutes: float = 5.0
    min_sample: int = 10


@dataclass(frozen=True)
class SendConfig:
    # Conservative default: one worker. The spec left the default blank;
    # 1 is the safest possible choice and keeps runs deterministic.
    concurrency: int = 1
    max_attempts: int = 4
    backoff_base_seconds: float = 1.5
    backoff_max_seconds: float = 60.0


@dataclass(frozen=True)
class ValidationConfig:
    max_file_mb: float = 10.0
    verify_dimensions: bool = True
    max_total_dimension: int = 10000  # docs-verified sendPhoto limit (2026-09-30)
    normalize_exif: bool = False
    resize_if_over_limit: bool = False


@dataclass(frozen=True)
class DedupeConfig:
    within_run: bool = True
    across_runs: bool = True


@dataclass(frozen=True)
class DefaultsConfig:
    recipients: tuple[str, ...] = ()
    caption: str = ""
    caption_mode: CaptionMode = CaptionMode.PER_IMAGE
    caption_column: str = "caption"
    order: OrderKey = OrderKey.NAME
    reverse: bool = False
    recursive: bool = True


@dataclass(frozen=True)
class RecipientEntry:
    name: str
    chat_id: int | str


@dataclass(frozen=True)
class SecurityConfig:
    token_env: str = DEFAULT_TOKEN_ENV
    secrets_file: str | None = None


@dataclass(frozen=True)
class StorageConfig:
    state_file: str = "state/checkpoint.json"
    report_dir: str = "reports"


@dataclass(frozen=True)
class Config:
    telegram: TelegramConfig = TelegramConfig()
    limits: LimitsConfig = LimitsConfig()
    kill_switch: KillSwitchConfig = KillSwitchConfig()
    send: SendConfig = SendConfig()
    validation: ValidationConfig = ValidationConfig()
    dedupe: DedupeConfig = DedupeConfig()
    defaults: DefaultsConfig = DefaultsConfig()
    recipients: tuple[RecipientEntry, ...] = ()
    security: SecurityConfig = SecurityConfig()
    storage: StorageConfig = StorageConfig()


class _Reader:
    """Key-path aware reader over a raw mapping; every failure names the key."""

    def __init__(self, raw: Mapping[str, object], prefix: str) -> None:
        self._raw = raw
        self._prefix = prefix

    def path(self, key: str) -> str:
        return f"{self._prefix}{key}"

    def has(self, key: str) -> bool:
        return key in self._raw

    def get(self, key: str) -> object | None:
        return self._raw.get(key)

    def known_keys(self, known: set[str]) -> None:
        unknown = sorted(set(self._raw) - known)
        if unknown:
            raise ConfigError(f"{self._prefix}: unknown config key(s): {', '.join(unknown)}")

    def str_value(self, key: str, *, default: str | None = None, allow_empty: bool = False) -> str:
        if not self.has(key):
            if default is None:
                raise ConfigError(f"{self.path(key)}: missing required value")
            return default
        value = self._raw[key]
        if not isinstance(value, str):
            raise ConfigError(f"{self.path(key)}: expected a string, got {type(value).__name__}")
        if not allow_empty and not value.strip():
            raise ConfigError(f"{self.path(key)}: must not be empty")
        return value

    def bool_value(self, key: str, *, default: bool) -> bool:
        if not self.has(key):
            return default
        value = self._raw[key]
        if not isinstance(value, bool):
            raise ConfigError(f"{self.path(key)}: expected true/false, got {value!r}")
        return value

    def int_value(
        self,
        key: str,
        *,
        default: int | None,
        minimum: int | None = None,
        maximum: int | None = None,
    ) -> int:
        if not self.has(key):
            if default is None:
                raise ConfigError(f"{self.path(key)}: missing required value")
            return default
        value = self._raw[key]
        if isinstance(value, bool) or not isinstance(value, int):
            raise ConfigError(f"{self.path(key)}: expected an integer, got {value!r}")
        if minimum is not None and value < minimum:
            raise ConfigError(f"{self.path(key)}: must be >= {minimum}, got {value}")
        if maximum is not None and value > maximum:
            raise ConfigError(f"{self.path(key)}: must be <= {maximum}, got {value}")
        return value

    def float_value(
        self,
        key: str,
        *,
        default: float | None,
        minimum: float | None = None,
        maximum: float | None = None,
    ) -> float:
        if not self.has(key):
            if default is None:
                raise ConfigError(f"{self.path(key)}: missing required value")
            return default
        value = self._raw[key]
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ConfigError(f"{self.path(key)}: expected a number, got {value!r}")
        number = float(value)
        if minimum is not None and number < minimum:
            raise ConfigError(f"{self.path(key)}: must be >= {minimum}, got {number}")
        if maximum is not None and number > maximum:
            raise ConfigError(f"{self.path(key)}: must be <= {maximum}, got {number}")
        return number

    def enum_value(
        self, key: str, *, parse: Callable[[str], _E], allowed: str, default: str | None
    ) -> _E:
        """Parse an enum-typed value. `parse` is the enum class itself;
        `allowed` is the pre-rendered list of valid values for error
        messages (enum metaclass iteration is not mypy-friendly)."""
        if not self.has(key):
            if default is None:
                raise ConfigError(f"{self.path(key)}: missing required value")
            return parse(default)
        value = self._raw[key]
        if isinstance(value, str):
            try:
                return parse(value)
            except ValueError:
                pass
        raise ConfigError(f"{self.path(key)}: expected one of {allowed}, got {value!r}")


def _parse_chat_id(raw: object, where: str) -> int | str:
    if isinstance(raw, bool):
        raise ConfigError(f"{where}: chat_id must be an integer or @username, got {raw!r}")
    if isinstance(raw, int):
        return raw
    if isinstance(raw, str):
        text = raw.strip()
        if text.startswith("@") and len(text) > 1:
            return text
        if text.lstrip("-").isdigit() and text not in ("-", ""):
            return int(text)
    raise ConfigError(f"{where}: chat_id must be an integer or @username, got {raw!r}")


def _build_telegram(raw: Mapping[str, object]) -> TelegramConfig:
    r = _Reader(raw, "telegram.")
    r.known_keys({"api_base_url", "parse_mode", "timeout_seconds"})
    base = r.str_value("api_base_url", default=DEFAULT_API_BASE_URL)
    if not (base.startswith("https://") or base.startswith("http://")):
        raise ConfigError("telegram.api_base_url: must start with https:// or http://")
    parse_mode = r.enum_value(
        "parse_mode",
        parse=ParseMode,
        allowed="none/html/markdown/markdownv2",
        default=ParseMode.HTML.value,
    )
    timeout = r.float_value("timeout_seconds", default=60.0, minimum=1.0)
    return TelegramConfig(api_base_url=base, parse_mode=parse_mode, timeout_seconds=timeout)


def _build_quiet_hours(raw: Mapping[str, object]) -> QuietHoursConfig:
    r = _Reader(raw, "limits.quiet_hours.")
    r.known_keys({"enabled", "start", "end", "timezone"})
    enabled = r.bool_value("enabled", default=False)
    start = r.str_value("start", default="22:00")
    end = r.str_value("end", default="07:00")
    tz_name = r.str_value("timezone", default="UTC")
    for label, value in (("start", start), ("end", end)):
        if not _HHMM_RE.match(value):
            raise ConfigError(f"{r.path(label)}: expected HH:MM (24h), got {value!r}")
    try:
        ZoneInfo(tz_name)
    except ZoneInfoNotFoundError as exc:
        raise ConfigError(f"{r.path('timezone')}: unknown timezone {tz_name!r}") from exc
    return QuietHoursConfig(enabled=enabled, start=start, end=end, timezone=tz_name)


def _build_limits(raw: Mapping[str, object]) -> LimitsConfig:
    r = _Reader(raw, "limits.")
    r.known_keys(
        {"global_per_minute", "per_recipient_per_minute", "daily_cap_per_recipient", "quiet_hours"}
    )
    quiet_raw = raw.get("quiet_hours")
    quiet = _build_quiet_hours(quiet_raw) if isinstance(quiet_raw, dict) else QuietHoursConfig()
    return LimitsConfig(
        global_per_minute=r.float_value("global_per_minute", default=60.0, minimum=0.1),
        per_recipient_per_minute=r.float_value(
            "per_recipient_per_minute", default=18.0, minimum=0.1
        ),
        daily_cap_per_recipient=r.int_value("daily_cap_per_recipient", default=50, minimum=1),
        quiet_hours=quiet,
    )


def _build_kill_switch(raw: Mapping[str, object]) -> KillSwitchConfig:
    r = _Reader(raw, "kill_switch.")
    r.known_keys({"failure_rate", "window_minutes", "min_sample"})
    return KillSwitchConfig(
        failure_rate=r.float_value("failure_rate", default=0.5, minimum=0.01, maximum=1.0),
        window_minutes=r.float_value("window_minutes", default=5.0, minimum=0.1),
        min_sample=r.int_value("min_sample", default=10, minimum=1),
    )


def _build_send(raw: Mapping[str, object]) -> SendConfig:
    r = _Reader(raw, "send.")
    r.known_keys({"concurrency", "max_attempts", "backoff_base_seconds", "backoff_max_seconds"})
    return SendConfig(
        concurrency=r.int_value("concurrency", default=1, minimum=1),
        max_attempts=r.int_value("max_attempts", default=4, minimum=1),
        backoff_base_seconds=r.float_value("backoff_base_seconds", default=1.5, minimum=0.0),
        backoff_max_seconds=r.float_value("backoff_max_seconds", default=60.0, minimum=0.0),
    )


def _build_validation(raw: Mapping[str, object]) -> ValidationConfig:
    r = _Reader(raw, "validation.")
    r.known_keys(
        {
            "max_file_mb",
            "verify_dimensions",
            "max_total_dimension",
            "normalize_exif",
            "resize_if_over_limit",
        }
    )
    return ValidationConfig(
        max_file_mb=r.float_value(
            "max_file_mb", default=10.0, minimum=0.01, maximum=float(ABSOLUTE_MAX_FILE_MB)
        ),
        verify_dimensions=r.bool_value("verify_dimensions", default=True),
        max_total_dimension=r.int_value("max_total_dimension", default=10000, minimum=1),
        normalize_exif=r.bool_value("normalize_exif", default=False),
        resize_if_over_limit=r.bool_value("resize_if_over_limit", default=False),
    )


def _build_dedupe(raw: Mapping[str, object]) -> DedupeConfig:
    r = _Reader(raw, "dedupe.")
    r.known_keys({"within_run", "across_runs"})
    return DedupeConfig(
        within_run=r.bool_value("within_run", default=True),
        across_runs=r.bool_value("across_runs", default=True),
    )


def _build_defaults(raw: Mapping[str, object]) -> DefaultsConfig:
    r = _Reader(raw, "defaults.")
    r.known_keys(
        {"recipients", "caption", "caption_mode", "caption_column", "order", "reverse", "recursive"}
    )
    recipients_raw = raw.get("recipients", ())
    if recipients_raw == ():
        recipients_raw = []
    if not isinstance(recipients_raw, list) or any(not isinstance(x, str) for x in recipients_raw):
        raise ConfigError("defaults.recipients: must be a list of allowlist names")
    caption_mode = r.enum_value(
        "caption_mode",
        parse=CaptionMode,
        allowed="none/per-image/per-run/manifest-column",
        default=CaptionMode.PER_IMAGE.value,
    )
    order = r.enum_value(
        "order", parse=OrderKey, allowed="name/mtime/manifest-row", default=OrderKey.NAME.value
    )
    return DefaultsConfig(
        recipients=tuple(recipients_raw),
        caption=r.str_value("caption", default="", allow_empty=True),
        caption_mode=caption_mode,
        caption_column=r.str_value("caption_column", default="caption"),
        order=order,
        reverse=r.bool_value("reverse", default=False),
        recursive=r.bool_value("recursive", default=True),
    )


def _build_recipients(raw: object) -> tuple[RecipientEntry, ...]:
    if not isinstance(raw, list):
        raise ConfigError("recipients: must be a list of {name, chat_id} entries")
    entries: list[RecipientEntry] = []
    seen: set[str] = set()
    for i, item in enumerate(raw):
        where = f"recipients[{i}]"
        if not isinstance(item, Mapping):
            raise ConfigError(f"{where}: each entry must be a mapping with name and chat_id")
        r = _Reader(item, f"{where}.")
        r.known_keys({"name", "chat_id"})
        name = r.str_value("name")
        if name in seen:
            raise ConfigError(f"{where}.name: duplicate recipient name {name!r}")
        seen.add(name)
        chat_id = _parse_chat_id(item.get("chat_id"), f"{where}.chat_id")
        entries.append(RecipientEntry(name=name, chat_id=chat_id))
    return tuple(entries)


def _build_security(raw: Mapping[str, object]) -> SecurityConfig:
    r = _Reader(raw, "security.")
    r.known_keys({"token_env", "secrets_file"})
    secrets_file = raw.get("secrets_file")
    if secrets_file is not None and not isinstance(secrets_file, str):
        raise ConfigError("security.secrets_file: expected a file path string")
    return SecurityConfig(
        token_env=r.str_value("token_env", default=DEFAULT_TOKEN_ENV),
        secrets_file=secrets_file,
    )


def _build_storage(raw: Mapping[str, object]) -> StorageConfig:
    r = _Reader(raw, "storage.")
    r.known_keys({"state_file", "report_dir"})
    return StorageConfig(
        state_file=r.str_value("state_file", default="state/checkpoint.json"),
        report_dir=r.str_value("report_dir", default="reports"),
    )


def parse_config(raw: Mapping[str, object]) -> Config:
    """Validate a raw mapping into a Config, naming every offending key."""
    known = {
        "telegram",
        "limits",
        "kill_switch",
        "send",
        "validation",
        "dedupe",
        "defaults",
        "recipients",
        "security",
        "storage",
    }
    unknown = sorted(set(raw) - known)
    if unknown:
        raise ConfigError(f"unknown top-level config key(s): {', '.join(unknown)}")

    def section(name: str) -> Mapping[str, object]:
        value = raw.get(name, {})
        if not isinstance(value, Mapping):
            raise ConfigError(f"{name}: expected a mapping/section")
        return value

    recipients_raw = raw.get("recipients", ())
    recipients = _build_recipients(recipients_raw) if isinstance(recipients_raw, list) else ()
    return Config(
        telegram=_build_telegram(section("telegram")),
        limits=_build_limits(section("limits")),
        kill_switch=_build_kill_switch(section("kill_switch")),
        send=_build_send(section("send")),
        validation=_build_validation(section("validation")),
        dedupe=_build_dedupe(section("dedupe")),
        defaults=_build_defaults(section("defaults")),
        recipients=recipients,
        security=_build_security(section("security")),
        storage=_build_storage(section("storage")),
    )


def load_config(path: str | None) -> Config:
    """Load and validate a YAML or TOML config file (None -> defaults)."""
    if path is None:
        return Config()
    file = Path(path)
    if not file.is_file():
        raise ConfigError(f"config file not found: {path}")
    suffix = file.suffix.lower()
    try:
        if suffix in (".yaml", ".yml"):
            with open(file, "rb") as fh:
                raw = yaml.safe_load(fh)
        elif suffix == ".toml":
            with open(file, "rb") as fh:
                raw = tomllib.load(fh)
        else:
            raise ConfigError(f"config file must be .yaml/.yml or .toml, got {file.name}")
    except yaml.YAMLError as exc:
        raise ConfigError(f"config file {path} is not valid YAML: {exc}") from exc
    except tomllib.TOMLDecodeError as exc:
        raise ConfigError(f"config file {path} is not valid TOML: {exc}") from exc
    if raw is None:
        raw = {}
    if not isinstance(raw, Mapping):
        raise ConfigError(f"config file {path}: top level must be a mapping")
    return parse_config(raw)


def resolve_token(config: Config, env: Mapping[str, str], *, required: bool = True) -> str | None:
    """Resolve the bot token from env var or the git-ignored secrets file.

    The token is never read from the config file itself. Returns None only
    when required=False and no source exists (dry-run mode).
    """
    env_value = env.get(config.security.token_env, "").strip()
    if env_value:
        _check_token_shape(env_value, f"environment variable {config.security.token_env}")
        return env_value
    if config.security.secrets_file:
        secrets_path = Path(config.security.secrets_file)
        if secrets_path.is_file():
            value = secrets_path.read_text(encoding="utf-8").strip()
            if value:
                _check_token_shape(value, f"secrets file {config.security.secrets_file}")
                return value
    if required:
        raise SecretError(
            f"no bot token found: set the {config.security.token_env} environment variable"
            + (f" or create {config.security.secrets_file}" if config.security.secrets_file else "")
        )
    return None


def _check_token_shape(token: str, source: str) -> None:
    if not _TOKEN_RE.match(token):
        raise SecretError(
            f"the value in {source} does not look like a bot token "
            "(expected <bot_id>:<secret>, e.g. 123456789:AA...)"
        )

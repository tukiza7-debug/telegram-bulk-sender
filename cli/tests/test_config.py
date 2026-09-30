"""Config loading: typed schema, offending-key errors, precedence, secrets."""

from __future__ import annotations

from pathlib import Path

import pytest

from telegram_bulk_image_sender.config import (
    load_config,
    parse_config,
    resolve_token,
)
from telegram_bulk_image_sender.errors import ConfigError, SecretError
from telegram_bulk_image_sender.model import CaptionMode, OrderKey, ParseMode


def test_defaults_load_without_file() -> None:
    config = load_config(None)
    assert config.telegram.parse_mode is ParseMode.HTML
    assert config.send.concurrency == 1
    assert config.validation.max_file_mb == 10.0
    assert config.limits.daily_cap_per_recipient == 50


def test_yaml_round_trip(tmp_path: Path) -> None:
    file = tmp_path / "cfg.yaml"
    file.write_text(
        """
telegram:
  parse_mode: markdownv2
send:
  concurrency: 3
limits:
  daily_cap_per_recipient: 7
  quiet_hours:
    enabled: true
    start: "23:00"
    end: "06:30"
    timezone: Europe/Berlin
recipients:
  - name: news
    chat_id: -1001234567890
  - name: log
    chat_id: "@mychannel"
defaults:
  order: mtime
  recipients: [news]
""",
        encoding="utf-8",
    )
    config = load_config(str(file))
    assert config.telegram.parse_mode is ParseMode.MARKDOWN_V2
    assert config.send.concurrency == 3
    assert config.limits.daily_cap_per_recipient == 7
    assert config.limits.quiet_hours.enabled is True
    assert config.limits.quiet_hours.timezone == "Europe/Berlin"
    assert config.recipients[0].chat_id == -1001234567890
    assert config.recipients[1].chat_id == "@mychannel"
    assert config.defaults.order is OrderKey.MTIME


def test_toml_round_trip(tmp_path: Path) -> None:
    file = tmp_path / "cfg.toml"
    file.write_text(
        """
[send]
concurrency = 2

[[recipients]]
name = "news"
chat_id = 42
""",
        encoding="utf-8",
    )
    config = load_config(str(file))
    assert config.send.concurrency == 2
    assert config.recipients[0].chat_id == 42


def test_unknown_key_rejected() -> None:
    with pytest.raises(ConfigError, match=r"unknown top-level config key\(s\): limts"):
        parse_config({"limts": {"global_per_minute": 1}})


def test_unknown_nested_key_rejected() -> None:
    with pytest.raises(ConfigError, match=r"send\.: unknown config key\(s\): concurrancy"):
        parse_config({"send": {"concurrancy": 2}})


def test_type_errors_name_the_key() -> None:
    with pytest.raises(ConfigError, match=r"send\.concurrency: expected an integer, got 'fast'"):
        parse_config({"send": {"concurrency": "fast"}})
    with pytest.raises(ConfigError, match=r"limits\.global_per_minute: must be >= 0.1"):
        parse_config({"limits": {"global_per_minute": 0}})
    with pytest.raises(ConfigError, match=r"telegram\.parse_mode: expected one of"):
        parse_config({"telegram": {"parse_mode": "rich"}})


def test_bad_quiet_hours_values() -> None:
    with pytest.raises(ConfigError, match=r"limits\.quiet_hours\.start: expected HH:MM"):
        parse_config({"limits": {"quiet_hours": {"start": "24:99", "enabled": True}}})
    with pytest.raises(ConfigError, match=r"limits\.quiet_hours\.timezone"):
        parse_config({"limits": {"quiet_hours": {"timezone": "Mars/Olympus"}}})


def test_recipient_schema_errors() -> None:
    with pytest.raises(ConfigError, match=r"recipients\[0\]\.chat_id"):
        parse_config({"recipients": [{"name": "x", "chat_id": "not-a-chat"}]})
    with pytest.raises(ConfigError, match=r"recipients\[1\]\.name: duplicate"):
        parse_config({"recipients": [{"name": "a", "chat_id": 1}, {"name": "a", "chat_id": 2}]})


def test_token_from_env(env_token: dict[str, str]) -> None:
    config = load_config(None)
    assert resolve_token(config, env_token) == env_token["TELEGRAM_BOT_TOKEN"]


def test_token_from_secrets_file(tmp_path: Path) -> None:
    secrets = tmp_path / ".secrets" / "bot_token"
    secrets.parent.mkdir()
    secrets.write_text("123456789:AAAAsecretsecretsecretsecret\n", encoding="utf-8")
    config = parse_config({"security": {"secrets_file": str(secrets)}})
    assert resolve_token(config, {}) == "123456789:AAAAsecretsecretsecretsecret"


def test_token_shape_validated(tmp_path: Path) -> None:
    secrets = tmp_path / "tok"
    secrets.write_text("not a token", encoding="utf-8")
    config = parse_config({"security": {"secrets_file": str(secrets)}})
    with pytest.raises(SecretError, match="does not look like a bot token"):
        resolve_token(config, {})


def test_token_missing_raises(env_token: dict[str, str]) -> None:
    with pytest.raises(SecretError, match="no bot token found"):
        resolve_token(load_config(None), {})


def test_dry_run_does_not_need_token() -> None:
    assert resolve_token(load_config(None), {}, required=False) is None


def test_config_file_must_exist(tmp_path: Path) -> None:
    with pytest.raises(ConfigError, match="config file not found"):
        load_config(str(tmp_path / "missing.yaml"))


def test_caption_mode_values_are_kept() -> None:
    config = parse_config({"defaults": {"caption_mode": "manifest-column"}})
    assert config.defaults.caption_mode is CaptionMode.MANIFEST_COLUMN

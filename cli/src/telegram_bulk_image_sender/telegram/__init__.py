"""telegram subpackage: client interface, HTTP implementation, test fake."""

from __future__ import annotations

from .base import BotUser, SentMessage, TelegramClient
from .fake import FakeTelegramClient, SendCall
from .http_client import MultipartBody, TelegramHttpClient

__all__ = [
    "BotUser",
    "FakeTelegramClient",
    "MultipartBody",
    "SendCall",
    "SentMessage",
    "TelegramClient",
    "TelegramHttpClient",
]

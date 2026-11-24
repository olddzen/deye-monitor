"""Minimal Telegram Bot API client: send messages and answer a few commands (long polling)."""
from __future__ import annotations

import hashlib
import html
import logging
import time
from typing import Callable, Dict, Optional

import requests

log = logging.getLogger(__name__)

COMMANDS = {
    "status": "Чи є світло зараз, заряд батареї (миттєво)",
    "dashboard": "Дашборд: графіки, батарея, відключення",
    "week": "Звіт за 7 днів з графіком",
    "month": "Звіт за 30 днів з графіком",
    "battery": "Батарея: цикли, ємність, розряди",
    "stats": "Коротка статистика відключень",
    "history": "Останні відключення",
    "errors": "Серйозні помилки інвертора",
}


class Telegram:
    def __init__(self, token: str, chat_id: Optional[int]):
        self.base = f"https://api.telegram.org/bot{token}"
        self.chat_id = chat_id

    def _call(self, method: str, http_timeout: float = 15, **params):
        try:
            resp = requests.post(f"{self.base}/{method}", json=params, timeout=http_timeout)
            data = resp.json()
        except Exception as exc:  # requests errors include the URL, which contains the token
            raise RuntimeError(f"Telegram {method}: {type(exc).__name__}") from None
        if not data.get("ok"):
            raise RuntimeError(f"Telegram {method}: {data.get('description')}")
        return data["result"]

    def send(self, text: str, chat_id: Optional[int] = None) -> None:
        target = chat_id or self.chat_id
        if target is None:
            log.info("[no TELEGRAM_CHAT_ID] %s", text)
            return
        self._call("sendMessage", chat_id=target, text=text, parse_mode="HTML",
                   disable_web_page_preview=True)

    def send_photo(self, png: bytes, caption: str = "", chat_id: Optional[int] = None) -> None:
        target = chat_id or self.chat_id
        if target is None:
            return
        try:
            resp = requests.post(f"{self.base}/sendPhoto", data={"chat_id": target, "caption": caption,
                                                                 "parse_mode": "HTML"},
                                 files={"photo": ("chart.png", png, "image/png")}, timeout=60)
            data = resp.json()
        except Exception as exc:
            raise RuntimeError(f"Telegram sendPhoto: {type(exc).__name__}") from None
        if not data.get("ok"):
            raise RuntimeError(f"Telegram sendPhoto: {data.get('description')}")

    @staticmethod
    def commands_version() -> str:
        return hashlib.sha1(repr(sorted(COMMANDS.items())).encode()).hexdigest()[:8]

    def sync_commands(self) -> bool:
        """Publish the command menu; returns True on success."""
        try:
            self._call("setMyCommands", commands=[{"command": c, "description": d}
                                                  for c, d in COMMANDS.items()])
            return True
        except Exception as exc:
            log.warning("setMyCommands failed: %s", exc)
            return False

    def serve(self, handlers: Dict[str, Callable[[], str]]) -> None:
        """Blocking loop answering /commands. Only the configured chat gets answers."""
        self.sync_commands()
        offset = 0
        while True:
            try:
                offset = self.poll_once(handlers, offset, wait=50)
            except Exception as exc:
                log.warning("getUpdates failed: %s", exc)
                time.sleep(5)

    def poll_once(self, handlers: Dict[str, Callable[[], str]], offset: int, wait: int = 0) -> int:
        """Answer pending commands once; returns the next offset."""
        updates = self._call("getUpdates", http_timeout=wait + 15, offset=offset, timeout=wait,
                             allowed_updates=["message"])
        for upd in updates:
            offset = upd["update_id"] + 1
            self._handle(upd.get("message") or {}, handlers)
        return offset

    def _handle(self, msg: dict, handlers: Dict[str, Callable[[], object]]) -> None:
        """Never raises: a message that can't be answered must not block the ones after it."""
        try:
            self._handle_unsafe(msg, handlers)
        except Exception as exc:
            log.warning("could not answer a command: %s", type(exc).__name__)

    def _handle_unsafe(self, msg: dict, handlers: Dict[str, Callable[[], object]]) -> None:
        chat = (msg.get("chat") or {}).get("id")
        text = (msg.get("text") or "").strip()
        if chat is None or not text.startswith("/"):
            return
        if self.chat_id is None:
            self.send(f"Твій chat_id: <code>{chat}</code>\nВпиши його в .env як TELEGRAM_CHAT_ID "
                      f"і перезапусти сервіс.", chat_id=chat)
            return
        if chat != self.chat_id:
            return  # ignore strangers
        cmd = text.split()[0].lstrip("/").split("@")[0].lower()
        handler = handlers.get(cmd)
        if handler is None:
            reply = "Команди:\n" + "\n".join(f"/{c} — {d}" for c, d in COMMANDS.items())
        else:
            try:
                reply = handler()
            except Exception as exc:
                log.warning("command %s failed: %s", cmd, type(exc).__name__)
                reply = f"Помилка: {html.escape(str(exc), quote=False)}"
        if isinstance(reply, tuple):  # (text, png)
            text, png = reply
            if png:
                try:
                    self.send_photo(png, chat_id=chat)
                except Exception as exc:
                    log.warning("photo failed: %s", exc)
            reply = text
        self.send(reply, chat_id=chat)

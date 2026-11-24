"""Minimal Telegram Bot API client: send messages and answer a few commands (long polling)."""
from __future__ import annotations

import logging
import time
from typing import Callable, Dict, Optional

import requests

log = logging.getLogger(__name__)

COMMANDS = {
    "status": "Чи є світло зараз, заряд батареї",
    "stats": "Статистика відключень",
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

    def serve(self, handlers: Dict[str, Callable[[], str]]) -> None:
        """Blocking loop answering /commands. Only the configured chat gets answers."""
        try:
            self._call("setMyCommands", commands=[{"command": c, "description": d}
                                                  for c, d in COMMANDS.items()])
        except Exception as exc:
            log.warning("setMyCommands failed: %s", exc)
        offset = 0
        while True:
            try:
                updates = self._call("getUpdates", http_timeout=60, offset=offset, timeout=50,
                                     allowed_updates=["message"])
            except Exception as exc:
                log.warning("getUpdates failed: %s", exc)
                time.sleep(5)
                continue
            for upd in updates:
                offset = upd["update_id"] + 1
                self._handle(upd.get("message") or {}, handlers)

    def _handle(self, msg: dict, handlers: Dict[str, Callable[[], str]]) -> None:
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
                log.exception("command %s failed", cmd)
                reply = f"Помилка: {exc}"
        self.send(reply, chat_id=chat)

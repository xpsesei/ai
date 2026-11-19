#!/bin/bash
set -euo pipefail

APP_DIR="/opt/ai_quant_pro"
VENV_DIR="${APP_DIR}/venv"
SERVICE_NAME="ai-quant-pro"
PORT="${PORT:-8000}"

echo "=== [1/4] 更新系统并安装 Python3 / venv / 编译依赖 ==="
apt-get update -y
apt-get install -y python3 python3-venv python3-pip python3-dev build-essential curl ufw

echo "=== [2/4] 初始化独立虚拟环境并安装核心依赖 ==="
mkdir -p "${APP_DIR}"
cat << 'INNER_EOF' > "${APP_DIR}/ai_quant_pro.py"
import json
import logging
import os
import re
import secrets
import sqlite3
import tempfile
import threading
import time
from datetime import datetime
from typing import Any, Dict, List, Optional

import ccxt
import pandas as pd
import requests
import uvicorn
from fastapi import Depends, FastAPI, HTTPException, Response, status
from fastapi.responses import HTMLResponse
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from openai import OpenAI
from pydantic import BaseModel, Field

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger("ai_quant_pro")

CONFIG_FILE = os.environ.get("QUANT_CONFIG_FILE", "config.json")
DB_FILE = os.environ.get("QUANT_DB_FILE", "quant_data.db")
MASK_TOKEN = "********"

state_lock = threading.RLock()
config_lock = threading.RLock()
db_lock = threading.Lock()

AI_PRESETS: Dict[str, Dict[str, str]] = {
    "deepseek": {
        "label": "DeepSeek (深度求索)",
        "provider_type": "openai_compat",
        "base_url": "https://api.deepseek.com/v1",
        "model": "deepseek-chat",
    },
    "openai": {
        "label": "OpenAI (GPT-4o / 4o-mini)",
        "provider_type": "openai_compat",
        "base_url": "https://api.openai.com/v1",
        "model": "gpt-4o-mini",
    },
    "anthropic": {
        "label": "Anthropic Claude (原生协议)",
        "provider_type": "anthropic",
        "base_url": "https://api.anthropic.com/v1",
        "model": "claude-3-5-sonnet-latest",
    },
    "gemini": {
        "label": "Google Gemini (原生协议)",
        "provider_type": "gemini",
        "base_url": "https://generativelanguage.googleapis.com/v1beta",
        "model": "gemini-2.5-flash",
    },
    "qwen": {
        "label": "通义千问 Qwen (阿里云百炼)",
        "provider_type": "openai_compat",
        "base_url": "https://dashscope.aliyuncs.com/compatible-mode/v1",
        "model": "qwen-plus",
    },
    "kimi": {
        "label": "Kimi / Moonshot (月之暗面)",
        "provider_type": "openai_compat",
        "base_url": "https://api.moonshot.cn/v1",
        "model": "moonshot-v1-8k",
    },
    "glm": {
        "label": "智谱 GLM (BigModel)",
        "provider_type": "openai_compat",
        "base_url": "https://open.bigmodel.cn/api/paas/v4",
        "model": "glm-4-flash",
    },
    "siliconflow": {
        "label": "硅基流动 SiliconFlow",
        "provider_type": "openai_compat",
        "base_url": "https://api.siliconflow.cn/v1",
        "model": "deepseek-ai/DeepSeek-V3",
    },
    "grok": {
        "label": "xAI Grok",
        "provider_type": "openai_compat",
        "base_url": "https://api.x.ai/v1",
        "model": "grok-2-latest",
    },
    "openrouter": {
        "label": "OpenRouter (聚合百余模型)",
        "provider_type": "openai_compat",
        "base_url": "https://openrouter.ai/api/v1",
        "model": "openai/gpt-4o-mini",
    },
    "ollama": {
        "label": "本地 Ollama (无需Key)",
        "provider_type": "openai_compat",
        "base_url": "http://127.0.0.1:11434/v1",
        "model": "qwen2.5:14b",
    },
}

PROMPT_TEMPLATES: Dict[str, Dict[str, str]] = {
    "trend_following": {
        "name": "📈 稳健趋势跟踪 (推荐)",
        "desc": "顺势而为，EMA多头排列且MACD转正时分批买入，跌破均线或RSI超买时止盈。",
        "prompt": (
            "你是一名稳健的加密货币现货趋势交易员。核心原则：顺势而为，不逆势抄底。\n"
            "【买入条件】EMA7 > EMA25 形成多头排列，且 MACD 柱为正或由负转正，RSI(14) 处于 45~72 健康区间时，可买入。\n"
            "【卖出条件】当持有仓位且出现 EMA7 下穿 EMA25、MACD 明显走弱、或 RSI(14) > 78 严重超买时，果断卖出止盈。\n"
            "【观望条件】均线粘合震荡或趋势不明时输出 hold。\n"
            "必须严格只回复合法 JSON：{\"action\": \"buy/sell/hold\", \"amount_usdt\": 50, \"reason\": \"简短操盘理由\"}"
        ),
    },
    "mean_reversion": {
        "name": "🌊 RSI/布林带高抛低吸",
        "desc": "适合震荡行情，RSI超卖或触及布林带下轨买入，超买或触及上轨卖出。",
        "prompt": (
            "你是一名擅长震荡市高抛低吸的量化交易员。\n"
            "【买入条件】当 RSI(14) <= 35 或当前价格接近/跌破布林带下轨，且成交量未出现恐慌性崩盘时，分批低吸买入。\n"
            "【卖出条件】当持有仓位且 RSI(14) >= 68 或价格触及/突破布林带上轨时，分批卖出锁定利润。\n"
            "【观望条件】价格处于布林带中轨附近且 RSI 在 40~60 之间时观望。\n"
            "必须严格只回复合法 JSON：{\"action\": \"buy/sell/hold\", \"amount_usdt\": 50, \"reason\": \"简短操盘理由\"}"
        ),
    },
    "aggressive_scalper": {
        "name": "⚡ 激进短线动量狙击",
        "desc": "捕捉短周期放量突破信号，快进快出，适合高波动活跃币种。",
        "prompt": (
            "你是一名敏锐的短线动量交易员，专注于捕捉放量突破与快速反转。\n"
            "【买入条件】当量比 > 1.3 且价格站上 EMA7、MACD 动能向上加速时，果断追进买入。\n"
            "【卖出条件】当持有仓位且短线动能衰减、MACD 柱缩短或浮盈达到 2%~4% 出现滞涨信号时，迅速卖出落袋。\n"
            "【纪律】严禁犹豫，信号明确即果断出手；无量横盘时保持 hold。\n"
            "必须严格只回复合法 JSON：{\"action\": \"buy/sell/hold\", \"amount_usdt\": 60, \"reason\": \"简短操盘理由\"}"
        ),
    },
    "smart_dca": {
        "name": "🪙 智能定投抄底策略",
        "desc": "逢跌分批吸筹摊低成本，大跌多买、微跌少买，大幅盈利才止盈。",
        "prompt": (
            "你是一名执行智能定投 (Smart DCA) 的长期配置型交易员。\n"
            "【买入条件】当 24H 跌幅明显或 RSI(14) < 48 处于相对低位时买入；跌幅越大可适当提高单次买入金额（不超过上限）。\n"
            "【卖出条件】仅当持仓浮盈较高（如 > 8%）且 RSI(14) > 75 出现过热迹象时才分批卖出，平时不轻易割肉。\n"
            "必须严格只回复合法 JSON：{\"action\": \"buy/sell/hold\", \"amount_usdt\": 40, \"reason\": \"简短操盘理由\"}"
        ),
    },
    "conservative_guard": {
        "name": "🛡️ 保守防御保本策略",
        "desc": "宁可错过不做错，仅在多指标强烈共振时轻仓试探，优先保护本金。",
        "prompt": (
            "你是一名极度重视本金安全的保守型量化风控官。\n"
            "【买入条件】仅当 15m 与 1h 均线同时多头共振、RSI(14) 在 45~62 之间且未剧烈偏离均线时，才允许轻仓买入。\n"
            "【卖出条件】一旦跌破 EMA25 或 1h 趋势转弱，立即卖出避险。\n"
            "【原则】有任何不确定性一律输出 hold。\n"
            "必须严格只回复合法 JSON：{\"action\": \"buy/sell/hold\", \"amount_usdt\": 30, \"reason\": \"简短操盘理由\"}"
        ),
    },
}

DEFAULT_CONFIG: Dict[str, Any] = {
    "auth": {
        "enabled": True,
        "username": "admin",
        "password": "adminpassword888",
    },
    "exchange": {
        "name": "binance",
        "api_key": "",
        "secret_key": "",
        "password": "",
        "sandbox": True,
        "real_trade": False,
    },
    "ai_pool": [
        {
            "name": "DeepSeek Primary",
            "provider_type": "openai_compat",
            "base_url": "https://api.deepseek.com/v1",
            "api_key": "",
            "model": "deepseek-chat",
            "enabled": True,
        },
        {
            "name": "Claude Backup",
            "provider_type": "anthropic",
            "base_url": "https://api.anthropic.com/v1",
            "api_key": "",
            "model": "claude-3-5-sonnet-latest",
            "enabled": True,
        },
        {
            "name": "Gemini Backup",
            "provider_type": "gemini",
            "base_url": "https://generativelanguage.googleapis.com/v1beta",
            "api_key": "",
            "model": "gemini-2.5-flash",
            "enabled": True,
        },
        {
            "name": "OpenAI Backup",
            "provider_type": "openai_compat",
            "base_url": "https://api.openai.com/v1",
            "api_key": "",
            "model": "gpt-4o-mini",
            "enabled": True,
        },
    ],
    "ai": {
        "enabled": True,
        "rotation_mode": "failover",  # failover | round_robin
        "consensus_count": 1,         # 1=单AI决策, 2=双AI共振确认
        "cooldown_on_fail_sec": 120,
        "timeout": 20,
        "temperature": 0.2,
        "template_id": "trend_following",
        "system_prompt": PROMPT_TEMPLATES["trend_following"]["prompt"],
    },
    "risk": {
        "max_order_usdt": 200.0,
        "min_order_usdt": 10.0,
        "max_position_pct": 80.0,
        "stop_loss_pct": 5.0,
        "take_profit_pct": 10.0,
        "trailing_stop_pct": 3.0,
        "daily_max_loss_usdt": 300.0,
        "cooldown_sec": 45,
        "paper_initial_usdt": 10000.0,
    },
    "notify": {
        "enabled": False,
        "telegram_bot_token": "",
        "telegram_chat_id": "",
        "webhook_url": "",
        "notify_on_trade": True,
        "notify_on_error": True,
    },
    "tasks": [
        {
            "id": "task_1",
            "symbol": "BTC/USDT",
            "strategy": "ai_auto",
            "timeframe": "15m",
            "interval": 30,
            "template_id": "global",
            "custom_instruction": "",
            "active": False,
        }
    ],
}


def deep_merge_defaults(cfg: Dict[str, Any], defaults: Dict[str, Any]) -> Dict[str, Any]:
    merged = dict(cfg)
    for k, v in defaults.items():
        if k not in merged:
            merged[k] = json.loads(json.dumps(v))
        elif isinstance(v, dict) and isinstance(merged[k], dict):
            merged[k] = deep_merge_defaults(merged[k], v)
    return merged


def save_config(cfg: Dict[str, Any]) -> None:
    with config_lock:
        dir_name = os.path.dirname(os.path.abspath(CONFIG_FILE)) or "."
        fd, tmp_path = tempfile.mkstemp(prefix=".cfg_", suffix=".tmp", dir=dir_name)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(cfg, f, indent=4, ensure_ascii=False)
            os.replace(tmp_path, CONFIG_FILE)
        except Exception:
            if os.path.exists(tmp_path):
                os.remove(tmp_path)
            raise


def load_config() -> Dict[str, Any]:
    with config_lock:
        if os.path.exists(CONFIG_FILE):
            try:
                with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                    cfg = json.load(f)
                merged = deep_merge_defaults(cfg, DEFAULT_CONFIG)
                for node in merged.get("ai_pool", []):
                    node.setdefault("provider_type", "openai_compat")
                    node.setdefault("enabled", True)
                if merged != cfg:
                    save_config(merged)
                return merged
            except Exception as e:
                logger.error(f"读取配置失败，使用默认配置: {e}")
        cfg = json.loads(json.dumps(DEFAULT_CONFIG))
        save_config(cfg)
        return cfg


app_config: Dict[str, Any] = load_config()

runtime_state: Dict[str, Any] = {
    "logs": [],
    "task_metrics": {},
    "balances": {"USDT": float(app_config["risk"].get("paper_initial_usdt", 10000.0))},
    "real_balances": {},
    "real_balance_ts": 0.0,
    "avg_entry_prices": {},
    "peak_prices": {},
    "last_trade_ts": {},
    "market_prices": {},
    "recent_decisions": {},
    "ai_health": {},  # idx -> {fail_count, cooldown_until, last_error, last_ok_ts, latency_ms}
    "ai_rr_cursor": 0,
    "circuit_breaker_tripped": False,
}


def init_db() -> None:
    with db_lock:
        conn = sqlite3.connect(DB_FILE)
        try:
            cur = conn.cursor()
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS trades (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    created_at TEXT NOT NULL,
                    timestamp INTEGER NOT NULL,
                    symbol TEXT NOT NULL,
                    side TEXT NOT NULL,
                    amount REAL NOT NULL,
                    price REAL NOT NULL,
                    usdt_value REAL NOT NULL,
                    pnl_usdt REAL DEFAULT 0.0,
                    mode TEXT NOT NULL,
                    source TEXT NOT NULL,
                    provider TEXT DEFAULT '',
                    reason TEXT DEFAULT '',
                    order_id TEXT DEFAULT ''
                )
                """
            )
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS paper_state (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                )
                """
            )
            try:
                cur.execute("ALTER TABLE trades ADD COLUMN order_id TEXT DEFAULT ''")
            except sqlite3.OperationalError:
                pass
            conn.commit()
        finally:
            conn.close()


def load_paper_state() -> None:
    with db_lock:
        conn = sqlite3.connect(DB_FILE)
        try:
            cur = conn.cursor()
            cur.execute("SELECT value FROM paper_state WHERE key = 'balances'")
            row_bal = cur.fetchone()
            cur.execute("SELECT value FROM paper_state WHERE key = 'avg_entry_prices'")
            row_avg = cur.fetchone()
            cur.execute("SELECT value FROM paper_state WHERE key = 'peak_prices'")
            row_peak = cur.fetchone()
            with state_lock:
                if row_bal:
                    runtime_state["balances"] = json.loads(row_bal[0])
                if row_avg:
                    runtime_state["avg_entry_prices"] = json.loads(row_avg[0])
                if row_peak:
                    runtime_state["peak_prices"] = json.loads(row_peak[0])
        finally:
            conn.close()


def save_paper_state() -> None:
    with state_lock:
        bal_json = json.dumps(runtime_state["balances"])
        avg_json = json.dumps(runtime_state["avg_entry_prices"])
        peak_json = json.dumps(runtime_state["peak_prices"])
    with db_lock:
        conn = sqlite3.connect(DB_FILE)
        try:
            cur = conn.cursor()
            cur.execute("INSERT OR REPLACE INTO paper_state (key, value) VALUES ('balances', ?)", (bal_json,))
            cur.execute("INSERT OR REPLACE INTO paper_state (key, value) VALUES ('avg_entry_prices', ?)", (avg_json,))
            cur.execute("INSERT OR REPLACE INTO paper_state (key, value) VALUES ('peak_prices', ?)", (peak_json,))
            conn.commit()
        finally:
            conn.close()


def record_trade(
    symbol: str,
    side: str,
    amount: float,
    price: float,
    usdt_value: float,
    pnl_usdt: float,
    mode: str,
    source: str,
    provider: str = "",
    reason: str = "",
    order_id: str = "",
) -> None:
    now = datetime.now()
    with db_lock:
        conn = sqlite3.connect(DB_FILE)
        try:
            cur = conn.cursor()
            cur.execute(
                """
                INSERT INTO trades (
                    created_at, timestamp, symbol, side, amount, price,
                    usdt_value, pnl_usdt, mode, source, provider, reason, order_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    now.strftime("%Y-%m-%d %H:%M:%S"),
                    int(now.timestamp()),
                    symbol,
                    side,
                    amount,
                    price,
                    usdt_value,
                    pnl_usdt,
                    mode,
                    source,
                    provider,
                    reason,
                    order_id,
                ),
            )
            conn.commit()
        finally:
            conn.close()


def query_trades(limit: int = 50, symbol: Optional[str] = None) -> List[Dict[str, Any]]:
    with db_lock:
        conn = sqlite3.connect(DB_FILE)
        conn.row_factory = sqlite3.Row
        try:
            cur = conn.cursor()
            if symbol:
                cur.execute("SELECT * FROM trades WHERE symbol = ? ORDER BY id DESC LIMIT ?", (symbol.upper().strip(), limit))
            else:
                cur.execute("SELECT * FROM trades ORDER BY id DESC LIMIT ?", (limit,))
            return [dict(r) for r in cur.fetchall()]
        finally:
            conn.close()


def query_today_realized_pnl() -> float:
    today_prefix = datetime.now().strftime("%Y-%m-%d")
    with db_lock:
        conn = sqlite3.connect(DB_FILE)
        try:
            cur = conn.cursor()
            cur.execute("SELECT COALESCE(SUM(pnl_usdt), 0.0) FROM trades WHERE created_at LIKE ?", (f"{today_prefix}%",))
            return float(cur.fetchone()[0])
        finally:
            conn.close()


def query_pnl_series(limit: int = 80) -> List[Dict[str, Any]]:
    with db_lock:
        conn = sqlite3.connect(DB_FILE)
        try:
            cur = conn.cursor()
            cur.execute("SELECT timestamp, pnl_usdt FROM trades WHERE side = 'sell' ORDER BY id ASC LIMIT ?", (limit,))
            rows = cur.fetchall()
            cum = 0.0
            series = []
            last_ts = 0
            for ts, pnl in rows:
                cum += float(pnl)
                t_val = int(ts)
                if t_val <= last_ts:
                    t_val = last_ts + 1
                last_ts = t_val
                series.append({"time": t_val, "value": round(cum, 2)})
            return series
        finally:
            conn.close()


def query_trade_stats() -> Dict[str, Any]:
    with db_lock:
        conn = sqlite3.connect(DB_FILE)
        try:
            cur = conn.cursor()
            cur.execute("SELECT COUNT(*), COALESCE(SUM(pnl_usdt), 0.0) FROM trades")
            total_trades, total_pnl = cur.fetchone()
            cur.execute("SELECT COUNT(*) FROM trades WHERE side = 'sell' AND pnl_usdt > 0")
            win_sells = cur.fetchone()[0]
            cur.execute("SELECT COUNT(*) FROM trades WHERE side = 'sell'")
            total_sells = cur.fetchone()[0]
            win_rate = round((win_sells / total_sells) * 100, 1) if total_sells > 0 else 0.0
            return {
                "total_trades": total_trades,
                "total_realized_pnl": round(float(total_pnl), 2),
                "win_rate": win_rate,
                "total_sells": total_sells,
            }
        finally:
            conn.close()


init_db()
load_paper_state()


def add_log(msg: str, level: str = "INFO") -> None:
    timestamp = datetime.now().strftime("%H:%M:%S")
    entry = f"[{timestamp}] [{level}] {msg}"
    if level == "ERROR":
        logger.error(msg)
    elif level == "WARN":
        logger.warning(msg)
    else:
        logger.info(msg)
    with state_lock:
        runtime_state["logs"].insert(0, entry)
        if len(runtime_state["logs"]) > 350:
            runtime_state["logs"].pop()


def send_notification(title: str, content: str, is_error: bool = False) -> None:
    with config_lock:
        notify_cfg = dict(app_config.get("notify", {}))
    if not notify_cfg.get("enabled"):
        return
    if is_error and not notify_cfg.get("notify_on_error", True):
        return
    if not is_error and not notify_cfg.get("notify_on_trade", True):
        return

    text = f"⚡ AI Quant Pro\n【{title}】\n{content}"

    def _send() -> None:
        tg_token = (notify_cfg.get("telegram_bot_token") or "").strip()
        tg_chat = (notify_cfg.get("telegram_chat_id") or "").strip()
        if tg_token and tg_chat:
            try:
                requests.post(
                    f"https://api.telegram.org/bot{tg_token}/sendMessage",
                    json={"chat_id": tg_chat, "text": text},
                    timeout=8,
                )
            except Exception as e:
                logger.warning(f"Telegram 推送失败: {e}")

        webhook = (notify_cfg.get("webhook_url") or "").strip()
        if webhook:
            try:
                requests.post(
                    webhook,
                    json={"msgtype": "text", "text": {"content": text}, "content": text},
                    timeout=8,
                )
            except Exception as e:
                logger.warning(f"Webhook 推送失败: {e}")

    threading.Thread(target=_send, daemon=True).start()


def compute_indicators(ohlcv: List[List[float]], htf_ohlcv: Optional[List[List[float]]] = None) -> Dict[str, Any]:
    if not ohlcv or len(ohlcv) < 15:
        return {"summary": "K线数据不足，暂无完整技术指标"}

    df = pd.DataFrame(ohlcv, columns=["ts", "open", "high", "low", "close", "volume"])
    close = df["close"].astype(float)
    high = df["high"].astype(float)
    low = df["low"].astype(float)
    vol = df["volume"].astype(float)

    ema7 = close.ewm(span=7, adjust=False).mean()
    ema25 = close.ewm(span=25, adjust=False).mean()

    delta = close.diff()
    gain = delta.clip(lower=0).rolling(window=14).mean()
    loss = (-delta.clip(upper=0)).rolling(window=14).mean()
    rs = gain / loss.replace(0, float("nan"))
    rsi14 = 100 - (100 / (1 + rs))

    ema12 = close.ewm(span=12, adjust=False).mean()
    ema26 = close.ewm(span=26, adjust=False).mean()
    macd_line = ema12 - ema26
    signal_line = macd_line.ewm(span=9, adjust=False).mean()
    macd_hist = macd_line - signal_line

    bb_mid = close.rolling(window=20).mean()
    bb_std = close.rolling(window=20).std()
    bb_upper = bb_mid + 2 * bb_std
    bb_lower = bb_mid - 2 * bb_std

    vol_ma10 = vol.rolling(window=10).mean()
    vol_ratio = float(vol.iloc[-1] / vol_ma10.iloc[-1]) if pd.notna(vol_ma10.iloc[-1]) and vol_ma10.iloc[-1] > 0 else 1.0

    tr = pd.concat(
        [high - low, (high - close.shift(1)).abs(), (low - close.shift(1)).abs()],
        axis=1,
    ).max(axis=1)
    atr14 = float(tr.rolling(window=14).mean().iloc[-1]) if len(tr) >= 14 else float(tr.mean())

    latest_rsi = float(rsi14.iloc[-1]) if pd.notna(rsi14.iloc[-1]) else 50.0
    latest_ema7 = float(ema7.iloc[-1])
    latest_ema25 = float(ema25.iloc[-1])
    latest_macd = float(macd_hist.iloc[-1])
    latest_upper = float(bb_upper.iloc[-1]) if pd.notna(bb_upper.iloc[-1]) else float(close.iloc[-1])
    latest_lower = float(bb_lower.iloc[-1]) if pd.notna(bb_lower.iloc[-1]) else float(close.iloc[-1])

    htf_trend = "未知"
    if htf_ohlcv and len(htf_ohlcv) >= 25:
        htf_close = pd.Series([float(c[4]) for c in htf_ohlcv])
        htf_e7 = float(htf_close.ewm(span=7, adjust=False).mean().iloc[-1])
        htf_e25 = float(htf_close.ewm(span=25, adjust=False).mean().iloc[-1])
        htf_trend = "1H多头" if htf_e7 > htf_e25 else "1H空头"

    recent_closes = " -> ".join(f"{c:.4f}" for c in close.tail(6).tolist())
    trend = "多头排列(EMA7>EMA25)" if latest_ema7 > latest_ema25 else "空头排列(EMA7<EMA25)"

    return {
        "ema7": round(latest_ema7, 4),
        "ema25": round(latest_ema25, 4),
        "rsi14": round(latest_rsi, 2),
        "macd_hist": round(latest_macd, 4),
        "bb_upper": round(latest_upper, 4),
        "bb_lower": round(latest_lower, 4),
        "vol_ratio": round(vol_ratio, 2),
        "atr14": round(atr14, 4),
        "htf_trend": htf_trend,
        "trend": trend,
        "recent_closes": recent_closes,
        "summary": (
            f"近期收盘: {recent_closes} | 本周期: {trend} (EMA7={latest_ema7:.4f}, EMA25={latest_ema25:.4f}) | "
            f"大周期: {htf_trend} | RSI(14)={latest_rsi:.2f} | MACD柱={latest_macd:.4f} | "
            f"布林带=[{latest_lower:.4f}, {latest_upper:.4f}] | 量比={vol_ratio:.2f}x | ATR14={atr14:.4f}"
        ),
    }


def extract_json_object(raw_text: str) -> Dict[str, Any]:
    cleaned = raw_text.strip()
    if cleaned.startswith("```"):
        cleaned = re.sub(r"^```(?:json)?\s*", "", cleaned, flags=re.IGNORECASE)
        cleaned = re.sub(r"\s*```$", "", cleaned)
    try:
        return json.loads(cleaned)
    except json.JSONDecodeError:
        match = re.search(r"\{[\s\S]*\}", cleaned)
        if match:
            return json.loads(match.group(0))
        raise


def call_universal_ai(
    node: Dict[str, Any],
    system_prompt: str,
    user_msg: str,
    timeout_sec: int = 20,
    temperature: float = 0.2,
    max_tokens: int = 280,
) -> str:
    """Universal adapter supporting OpenAI-compat, Anthropic Claude, Google Gemini, and Azure OpenAI."""
    ptype = (node.get("provider_type") or "openai_compat").lower().strip()
    base_url = (node.get("base_url") or "").strip().rstrip("/")
    api_key = (node.get("api_key") or "").strip()
    model = (node.get("model") or "").strip()

    if not model:
        raise ValueError("模型名称为空")
    if not api_key and "127.0.0.1" not in base_url and "localhost" not in base_url:
        raise ValueError("API Key 为空")

    if ptype == "anthropic":
        url = base_url if base_url.endswith("/messages") else f"{base_url}/messages"
        headers = {
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        }
        payload = {
            "model": model,
            "max_tokens": max_tokens,
            "temperature": temperature,
            "system": system_prompt,
            "messages": [{"role": "user", "content": user_msg}],
        }
        resp = requests.post(url, headers=headers, json=payload, timeout=timeout_sec)
        if resp.status_code >= 400:
            raise RuntimeError(f"HTTP {resp.status_code}: {resp.text[:200]}")
        data = resp.json()
        blocks = data.get("content", [])
        return "".join(b.get("text", "") for b in blocks if b.get("type") == "text").strip()

    elif ptype == "gemini":
        url = f"{base_url}/models/{model}:generateContent?key={api_key}"
        payload = {
            "systemInstruction": {"parts": [{"text": system_prompt}]},
            "contents": [{"role": "user", "parts": [{"text": user_msg}]}],
            "generationConfig": {
                "temperature": temperature,
                "maxOutputTokens": max_tokens,
            },
        }
        resp = requests.post(url, json=payload, timeout=timeout_sec)
        if resp.status_code >= 400:
            raise RuntimeError(f"HTTP {resp.status_code}: {resp.text[:200]}")
        data = resp.json()
        candidates = data.get("candidates", [])
        if not candidates:
            raise RuntimeError(f"Gemini 无有效返回: {data}")
        parts = candidates[0].get("content", {}).get("parts", [])
        return "".join(p.get("text", "") for p in parts).strip()

    elif ptype == "azure_openai":
        url = base_url
        headers = {"api-key": api_key, "Content-Type": "application/json"}
        payload = {
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_msg},
            ],
            "temperature": temperature,
            "max_tokens": max_tokens,
        }
        resp = requests.post(url, headers=headers, json=payload, timeout=timeout_sec)
        if resp.status_code >= 400:
            raise RuntimeError(f"HTTP {resp.status_code}: {resp.text[:200]}")
        data = resp.json()
        return (data["choices"][0]["message"]["content"] or "").strip()

    else:
        # openai_compat: OpenAI, DeepSeek, Qwen, Kimi, GLM, Grok, SiliconFlow, OpenRouter, Ollama, etc.
        client = OpenAI(
            api_key=api_key or "ollama",
            base_url=base_url,
            timeout=timeout_sec,
        )
        response = client.chat.completions.create(
            model=model,
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_msg},
            ],
            temperature=temperature,
            max_tokens=max_tokens,
        )
        return (response.choices[0].message.content or "").strip()


security = HTTPBasic()


def verify_auth(credentials: HTTPBasicCredentials = Depends(security)) -> bool:
    with config_lock:
        auth_cfg = dict(app_config.get("auth", {"enabled": False}))
    if not auth_cfg.get("enabled", False):
        return True
    correct_username = secrets.compare_digest(
        credentials.username, auth_cfg.get("username", "admin")
    )
    correct_password = secrets.compare_digest(
        credentials.password, auth_cfg.get("password", "adminpassword888")
    )
    if not (correct_username and correct_password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="用户名或密码错误",
            headers={"WWW-Authenticate": "Basic"},
        )
    return True


class QuantEngine:
    def __init__(self) -> None:
        self.threads: Dict[str, threading.Thread] = {}
        self.stop_flags: Dict[str, threading.Event] = {}
        self.engine_lock = threading.Lock()
        self._client: Optional[ccxt.Exchange] = None
        self._client_sig: Optional[str] = None

    def invalidate_client(self) -> None:
        with self.engine_lock:
            self._client = None
            self._client_sig = None

    def get_exchange_client(self) -> ccxt.Exchange:
        with config_lock:
            ex_cfg = dict(app_config["exchange"])
        sig = json.dumps(ex_cfg, sort_keys=True)
        with self.engine_lock:
            if self._client is not None and self._client_sig == sig:
                return self._client

            ex_name = ex_cfg["name"].lower().strip()
            if not hasattr(ccxt, ex_name):
                raise ValueError(f"不支持的交易所: {ex_name}")
            exchange_class = getattr(ccxt, ex_name)
            params: Dict[str, Any] = {
                "apiKey": ex_cfg.get("api_key", ""),
                "secret": ex_cfg.get("secret_key", ""),
                "enableRateLimit": True,
                "timeout": 15000,
                "options": {
                    "createMarketBuyOrderRequiresPrice": False,
                },
            }
            if ex_cfg.get("password"):
                params["password"] = ex_cfg["password"]
            client = exchange_class(params)
            if ex_cfg.get("sandbox"):
                try:
                    client.set_sandbox_mode(True)
                except Exception as e:
                    add_log(f"交易所 {ex_name} 沙盒模式设置提示: {e}", "WARN")
            self._client = client
            self._client_sig = sig
            return client

    def sync_real_balances(self, client: Optional[ccxt.Exchange] = None, force: bool = False) -> Dict[str, float]:
        with config_lock:
            ex_cfg = dict(app_config["exchange"])
        if not ex_cfg.get("real_trade"):
            return {}
        if not ex_cfg.get("api_key") or not ex_cfg.get("secret_key"):
            return {}
        with state_lock:
            if not force and (time.time() - runtime_state["real_balance_ts"]) < 15:
                return dict(runtime_state["real_balances"])
        try:
            cli = client or self.get_exchange_client()
            bal = cli.fetch_balance()
            free_map: Dict[str, float] = {}
            for coin, info in (bal.get("total") or {}).items():
                val = float(info or 0.0)
                if val > 1e-8:
                    free_map[coin] = val
            with state_lock:
                runtime_state["real_balances"] = free_map
                runtime_state["real_balance_ts"] = time.time()
            return free_map
        except Exception as e:
            logger.warning(f"同步实盘余额失败: {e}")
            with state_lock:
                return dict(runtime_state["real_balances"])

    def execute_order(
        self,
        client: ccxt.Exchange,
        symbol: str,
        side: str,
        usdt_amount: float,
        price: float,
        source: str = "AI",
        provider: str = "",
        reason: str = "",
        bypass_risk: bool = False,
    ) -> bool:
        side = side.lower().strip()
        if side not in ("buy", "sell") or price <= 0 or usdt_amount <= 0:
            return False

        with config_lock:
            is_real = bool(app_config["exchange"]["real_trade"])
            risk_cfg = dict(app_config["risk"])

        min_usdt = float(risk_cfg.get("min_order_usdt", 10.0))
        max_usdt = float(risk_cfg.get("max_order_usdt", 200.0))
        max_pos_pct = float(risk_cfg.get("max_position_pct", 80.0))
        daily_max_loss = float(risk_cfg.get("daily_max_loss_usdt", 300.0))
        cooldown_sec = int(risk_cfg.get("cooldown_sec", 45))

        if not bypass_risk:
            if daily_max_loss > 0 and query_today_realized_pnl() <= -daily_max_loss:
                with state_lock:
                    already_tripped = runtime_state["circuit_breaker_tripped"]
                    runtime_state["circuit_breaker_tripped"] = True
                if not already_tripped:
                    msg = f"🚨 触发当日最大亏损熔断 (-{daily_max_loss}U)，已暂停AI自动开仓！"
                    add_log(msg, "ERROR")
                    send_notification("每日亏损熔断", msg, is_error=True)
                return False

            if usdt_amount < min_usdt:
                add_log(f"🛡️ [风控拦截] {symbol} {side.upper()} 金额 {usdt_amount:.2f}U 低于最小限制 {min_usdt}U", "WARN")
                return False
            if usdt_amount > max_usdt:
                add_log(f"🛡️ [风控限额] {symbol} 下单金额 {usdt_amount:.2f}U 超过上限，已自动裁剪为 {max_usdt}U", "WARN")
                usdt_amount = max_usdt

            with state_lock:
                last_ts = runtime_state["last_trade_ts"].get(symbol, 0)
            if source == "AI" and (time.time() - last_ts) < cooldown_sec:
                add_log(f"🛡️ [风控冷却] {symbol} 距上次交易不足 {cooldown_sec}s，跳过本次 {side.upper()}", "INFO")
                return False

        amount = usdt_amount / price

        if is_real:
            try:
                markets = client.load_markets()
                market = markets.get(symbol, {})
                min_amt = float((market.get("limits") or {}).get("amount", {}).get("min") or 0.0)
                min_cost = float((market.get("limits") or {}).get("cost", {}).get("min") or 0.0)
                if min_cost > 0 and usdt_amount < min_cost:
                    add_log(f"⚠️ [实盘限额] {symbol} 下单额 {usdt_amount:.2f}U 低于交易所最小名义额 {min_cost}U", "WARN")
                    return False

                exec_amount = float(client.amount_to_precision(symbol, amount))
                if exec_amount <= 0 or (min_amt > 0 and exec_amount < min_amt):
                    add_log(f"⚠️ [实盘精度过小] {symbol} 计算数量 {exec_amount} 低于最小数量 {min_amt}", "WARN")
                    return False

                if side == "buy":
                    try:
                        order = client.create_market_buy_order(symbol, exec_amount)
                    except Exception:
                        order = client.create_order(symbol, "market", "buy", exec_amount, price)
                else:
                    order = client.create_market_sell_order(symbol, exec_amount)

                filled_qty = float(order.get("filled") or exec_amount)
                filled_price = float(order.get("average") or order.get("price") or price)
                order_id = str(order.get("id") or "")

                pnl_usdt = 0.0
                with state_lock:
                    if side == "buy":
                        prev_qty = float(runtime_state["balances"].get(symbol, 0.0))
                        prev_avg = float(runtime_state["avg_entry_prices"].get(symbol, filled_price))
                        new_qty = prev_qty + filled_qty
                        runtime_state["avg_entry_prices"][symbol] = (prev_qty * prev_avg + filled_qty * filled_price) / new_qty
                        runtime_state["peak_prices"][symbol] = max(float(runtime_state["peak_prices"].get(symbol, filled_price)), filled_price)
                        runtime_state["balances"][symbol] = new_qty
                    else:
                        avg_entry = float(runtime_state["avg_entry_prices"].get(symbol, filled_price))
                        pnl_usdt = (filled_price - avg_entry) * filled_qty
                        rem = max(0.0, float(runtime_state["balances"].get(symbol, 0.0)) - filled_qty)
                        if rem <= 1e-8:
                            runtime_state["balances"].pop(symbol, None)
                            runtime_state["avg_entry_prices"].pop(symbol, None)
                            runtime_state["peak_prices"].pop(symbol, None)
                        else:
                            runtime_state["balances"][symbol] = rem
                    runtime_state["last_trade_ts"][symbol] = time.time()

                self.sync_real_balances(client, force=True)
                record_trade(
                    symbol=symbol,
                    side=side,
                    amount=filled_qty,
                    price=filled_price,
                    usdt_value=filled_qty * filled_price,
                    pnl_usdt=round(pnl_usdt, 4),
                    mode="REAL",
                    source=source,
                    provider=provider,
                    reason=reason,
                    order_id=order_id,
                )
                msg = f"🔥 [实盘成交/{source}] {symbol} {side.upper()} 数量:{filled_qty:.6f} @ {filled_price:.4f} (≈{filled_qty * filled_price:.2f}U)"
                add_log(msg, "TRADE")
                send_notification("实盘成交", f"{msg}\n理由: {reason}")
                return True
            except Exception as e:
                err_msg = f"❌ [实盘下单失败] {symbol} {side.upper()}: {e}"
                add_log(err_msg, "ERROR")
                send_notification("实盘下单异常", err_msg, is_error=True)
                return False
        else:
            pnl_usdt = 0.0
            with state_lock:
                usdt_bal = float(runtime_state["balances"].get("USDT", 0.0))
                held = float(runtime_state["balances"].get(symbol, 0.0))

                if side == "buy":
                    if not bypass_risk:
                        total_equity = usdt_bal + sum(
                            qty * runtime_state["market_prices"].get(sym, price if sym == symbol else 0.0)
                            for sym, qty in runtime_state["balances"].items()
                            if sym != "USDT"
                        )
                        current_pos_val = held * price
                        if total_equity > 0 and ((current_pos_val + usdt_amount) / total_equity) * 100 > max_pos_pct:
                            add_log(f"🛡️ [风控拦截] {symbol} 买入后仓位将超过上限 {max_pos_pct}%", "WARN")
                            return False

                    if usdt_bal < usdt_amount:
                        add_log(f"⚠️ [模拟余额不足] 可用 {usdt_bal:.2f}U < 需 {usdt_amount:.2f}U ({symbol})", "WARN")
                        return False

                    prev_cost = held * float(runtime_state["avg_entry_prices"].get(symbol, price))
                    new_held = held + amount
                    runtime_state["avg_entry_prices"][symbol] = (prev_cost + usdt_amount) / new_held
                    runtime_state["peak_prices"][symbol] = max(float(runtime_state["peak_prices"].get(symbol, price)), price)
                    runtime_state["balances"]["USDT"] = round(usdt_bal - usdt_amount, 6)
                    runtime_state["balances"][symbol] = round(new_held, 8)

                elif side == "sell":
                    if held <= 0:
                        add_log(f"⚠️ [模拟持仓不足] 当前未持有 {symbol}", "WARN")
                        return False
                    if amount > held:
                        amount = held
                        usdt_amount = amount * price

                    avg_entry = float(runtime_state["avg_entry_prices"].get(symbol, price))
                    pnl_usdt = (price - avg_entry) * amount
                    remaining = held - amount
                    if remaining <= 1e-8:
                        runtime_state["balances"].pop(symbol, None)
                        runtime_state["avg_entry_prices"].pop(symbol, None)
                        runtime_state["peak_prices"].pop(symbol, None)
                    else:
                        runtime_state["balances"][symbol] = round(remaining, 8)
                    runtime_state["balances"]["USDT"] = round(usdt_bal + usdt_amount, 6)

                runtime_state["last_trade_ts"][symbol] = time.time()

            save_paper_state()
            record_trade(
                symbol=symbol,
                side=side,
                amount=amount,
                price=price,
                usdt_value=usdt_amount,
                pnl_usdt=round(pnl_usdt, 4),
                mode="PAPER",
                source=source,
                provider=provider,
                reason=reason,
            )
            pnl_str = f" | 盈亏: {pnl_usdt:+.2f}U" if side == "sell" else ""
            msg = f"🧪 [模拟{('买入' if side == 'buy' else '卖出')}/{source}] {symbol} 数量:{amount:.6f} @ {price:.4f} ({usdt_amount:.2f}U){pnl_str}"
            add_log(msg, "TRADE")
            send_notification("模拟盘成交", f"{msg}\n理由: {reason}")
            return True

    def check_sl_tp(
        self,
        client: ccxt.Exchange,
        symbol: str,
        current_price: float,
        coin_bal: float,
    ) -> bool:
        if coin_bal <= 0 or current_price <= 0:
            return False

        with config_lock:
            risk_cfg = dict(app_config["risk"])

        with state_lock:
            avg_entry = float(runtime_state["avg_entry_prices"].get(symbol, 0.0))
            if avg_entry <= 0:
                return False
            peak_price = max(float(runtime_state["peak_prices"].get(symbol, avg_entry)), current_price)
            runtime_state["peak_prices"][symbol] = peak_price

        pnl_pct = ((current_price - avg_entry) / avg_entry) * 100.0
        drawdown_from_peak_pct = ((peak_price - current_price) / peak_price) * 100.0
        sl_pct = float(risk_cfg.get("stop_loss_pct", 5.0))
        tp_pct = float(risk_cfg.get("take_profit_pct", 10.0))
        trail_pct = float(risk_cfg.get("trailing_stop_pct", 3.0))
        pos_usdt = coin_bal * current_price

        if pos_usdt < 1.0:
            return False

        if sl_pct > 0 and pnl_pct <= -sl_pct:
            reason = f"触发自动止损 (浮亏 {pnl_pct:.2f}% <= -{sl_pct}%)"
            add_log(f"🚨 [{symbol}] {reason}，执行全平！", "WARN")
            return self.execute_order(
                client, symbol, "sell", pos_usdt, current_price,
                source="STOP_LOSS", provider="RiskEngine", reason=reason, bypass_risk=True
            )

        if tp_pct > 0 and pnl_pct >= tp_pct:
            reason = f"触发自动止盈 (浮盈 {pnl_pct:.2f}% >= +{tp_pct}%)"
            add_log(f"🎯 [{symbol}] {reason}，执行全平！", "TRADE")
            return self.execute_order(
                client, symbol, "sell", pos_usdt, current_price,
                source="TAKE_PROFIT", provider="RiskEngine", reason=reason, bypass_risk=True
            )

        if trail_pct > 0 and pnl_pct > 1.5 and drawdown_from_peak_pct >= trail_pct:
            reason = f"触发追踪止盈 (从最高价 {peak_price:.4f} 回撤 {drawdown_from_peak_pct:.2f}% >= {trail_pct}%)"
            add_log(f"📉 [{symbol}] {reason}，锁利平仓！", "TRADE")
            return self.execute_order(
                client, symbol, "sell", pos_usdt, current_price,
                source="TRAILING_STOP", provider="RiskEngine", reason=reason, bypass_risk=True
            )

        return False

    def resolve_task_prompt(self, task: Dict[str, Any]) -> str:
        with config_lock:
            global_prompt = app_config["ai"]["system_prompt"]
        tpl_id = task.get("template_id", "global")
        if tpl_id and tpl_id != "global" and tpl_id in PROMPT_TEMPLATES:
            base_prompt = PROMPT_TEMPLATES[tpl_id]["prompt"]
        else:
            base_prompt = global_prompt
        custom = (task.get("custom_instruction") or "").strip()
        if custom:
            return f"{base_prompt}\n\n【用户针对本币种的特别指令】\n{custom}"
        return base_prompt

    def _ordered_ai_candidates(self, pool: List[Dict[str, Any]], rotation_mode: str) -> List[tuple]:
        now = time.time()
        candidates = []
        cooling = []

        n = len(pool)
        with state_lock:
            start_idx = runtime_state["ai_rr_cursor"] % n if (rotation_mode == "round_robin" and n > 0) else 0
            if rotation_mode == "round_robin" and n > 0:
                runtime_state["ai_rr_cursor"] = (runtime_state["ai_rr_cursor"] + 1) % n
            health_map = dict(runtime_state["ai_health"])

        for offset in range(n):
            idx = (start_idx + offset) % n
            node = pool[idx]
            if not node.get("enabled", True):
                continue
            ptype = (node.get("provider_type") or "openai_compat").lower()
            has_key = bool((node.get("api_key") or "").strip()) or ("127.0.0.1" in (node.get("base_url") or "") or "localhost" in (node.get("base_url") or ""))
            if not has_key or not node.get("base_url"):
                continue

            h = health_map.get(str(idx), {})
            if h.get("cooldown_until", 0) > now:
                cooling.append((idx, node))
            else:
                candidates.append((idx, node))

        return candidates + cooling

    def consult_ai_pool(
        self,
        symbol: str,
        current_price: float,
        change_24h: float,
        usdt_bal: float,
        coin_bal: float,
        indicators: Dict[str, Any],
        system_prompt: str,
    ) -> Dict[str, Any]:
        with config_lock:
            ai_cfg = dict(app_config["ai"])
            pool = list(app_config.get("ai_pool", []))
            max_order = float(app_config["risk"].get("max_order_usdt", 200.0))
            min_order = float(app_config["risk"].get("min_order_usdt", 10.0))

        if not ai_cfg.get("enabled") or not pool:
            return {"action": "hold", "amount_usdt": 0, "reason": "AI未启用或AI池为空", "provider": "None"}

        coin_val_usdt = round(coin_bal * current_price, 2)
        with state_lock:
            avg_entry = float(runtime_state["avg_entry_prices"].get(symbol, 0.0))
            recent = list(runtime_state["recent_decisions"].get(symbol, []))
        entry_info = (
            f" | 持仓均价: {avg_entry:.4f} (浮盈: {((current_price - avg_entry) / avg_entry * 100):+.2f}%)"
            if avg_entry > 0 and coin_bal > 0
            else ""
        )
        recent_str = "；".join(recent) if recent else "暂无近期决策"

        user_msg = (
            f"【盘面数据】交易对: {symbol} | 最新价: {current_price} | 24H涨跌幅: {change_24h:.2f}%\n"
            f"【技术指标】{indicators.get('summary', '暂无')}\n"
            f"【账户持仓】可用USDT: {usdt_bal:.2f} | 持有 {symbol}: {coin_bal:.6f} (价值 {coin_val_usdt}U){entry_info}\n"
            f"【近期决策记忆】{recent_str}\n"
            f"【下单约束】单笔金额范围 {min_order}~{max_order}U；若持有价值 < 5U，严禁输出 sell。请严格输出JSON。"
        )

        timeout_sec = int(ai_cfg.get("timeout", 20))
        temp = float(ai_cfg.get("temperature", 0.2))
        cooldown_sec = int(ai_cfg.get("cooldown_on_fail_sec", 120))
        rotation_mode = ai_cfg.get("rotation_mode", "failover")
        consensus_needed = max(1, int(ai_cfg.get("consensus_count", 1)))

        ordered = self._ordered_ai_candidates(pool, rotation_mode)
        if not ordered:
            return {"action": "hold", "amount_usdt": 0, "reason": "没有已配置 Key 的可用 AI 节点", "provider": "None"}

        success_decisions: List[Dict[str, Any]] = []
        for idx, node in ordered:
            t0 = time.time()
            try:
                raw_text = call_universal_ai(
                    node=node,
                    system_prompt=system_prompt,
                    user_msg=user_msg,
                    timeout_sec=timeout_sec,
                    temperature=temp,
                    max_tokens=280,
                )
                latency_ms = int((time.time() - t0) * 1000)
                decision = extract_json_object(raw_text)
                action = str(decision.get("action", "hold")).lower().strip()
                if action not in ("buy", "sell", "hold"):
                    action = "hold"
                try:
                    amt = max(0.0, float(decision.get("amount_usdt", 0)))
                except (TypeError, ValueError):
                    amt = 0.0
                if action in ("buy", "sell") and amt == 0:
                    amt = min_order

                with state_lock:
                    runtime_state["ai_health"][str(idx)] = {
                        "name": node["name"],
                        "status": "HEALTHY",
                        "fail_count": 0,
                        "cooldown_until": 0,
                        "last_error": "",
                        "last_ok_ts": int(time.time()),
                        "latency_ms": latency_ms,
                    }

                success_decisions.append(
                    {
                        "action": action,
                        "amount_usdt": amt,
                        "reason": str(decision.get("reason", "无")),
                        "provider": node["name"],
                    }
                )
                if len(success_decisions) >= consensus_needed:
                    break
            except Exception as e:
                with state_lock:
                    prev = runtime_state["ai_health"].get(str(idx), {})
                    fails = int(prev.get("fail_count", 0)) + 1
                    runtime_state["ai_health"][str(idx)] = {
                        "name": node["name"],
                        "status": "COOLING",
                        "fail_count": fails,
                        "cooldown_until": time.time() + cooldown_sec,
                        "last_error": str(e)[:120],
                        "last_ok_ts": prev.get("last_ok_ts", 0),
                        "latency_ms": prev.get("latency_ms", 0),
                    }
                add_log(
                    f"⚠️ [AI轮替切换] [{node['name']}] 异常 ({str(e)[:80]})，已冷却 {cooldown_sec}s 并自动切换下一 AI...",
                    "WARN",
                )
                continue

        if not success_decisions:
            send_notification("AI池全部不可用", f"[{symbol}] 所有AI模型调用均失败，已降级观望。", is_error=True)
            return {
                "action": "hold",
                "amount_usdt": 0,
                "reason": "所有AI模型均调用失败，自动降级观望",
                "provider": "None",
            }

        if consensus_needed > 1 and len(success_decisions) >= 2:
            actions = [d["action"] for d in success_decisions]
            if len(set(actions)) == 1 and actions[0] in ("buy", "sell"):
                avg_amt = sum(d["amount_usdt"] for d in success_decisions) / len(success_decisions)
                providers = "+".join(d["provider"] for d in success_decisions)
                reasons = " | ".join(d["reason"] for d in success_decisions)
                final = {"action": actions[0], "amount_usdt": avg_amt, "reason": f"[双AI共振] {reasons}", "provider": providers}
            else:
                providers = "+".join(d["provider"] for d in success_decisions)
                final = {"action": "hold", "amount_usdt": 0, "reason": f"双AI意见分歧({actions[0]} vs {actions[1]})，自动观望", "provider": providers}
        else:
            final = success_decisions[0]

        with state_lock:
            hist = runtime_state["recent_decisions"].setdefault(symbol, [])
            hist.append(f"{datetime.now().strftime('%H:%M')} {final['action'].upper()}@{current_price:.2f}")
            if len(hist) > 3:
                hist.pop(0)

        return final

    def run_single_cycle(self, task: Dict[str, Any], client: ccxt.Exchange) -> Dict[str, Any]:
        task_id = task["id"]
        symbol = task["symbol"]
        timeframe = task.get("timeframe", "15m")

        ticker = client.fetch_ticker(symbol)
        current_price = float(ticker["last"])
        change_24h = float(ticker.get("percentage") or 0.0)

        with state_lock:
            runtime_state["market_prices"][symbol] = current_price

        with config_lock:
            is_real = bool(app_config["exchange"]["real_trade"])

        if is_real:
            try:
                bal = client.fetch_balance()
                base_coin = symbol.split("/")[0]
                usdt_bal = float(bal.get("USDT", {}).get("free", 0.0))
                coin_bal = float(bal.get(base_coin, {}).get("free", 0.0))
                self.sync_real_balances(client, force=False)
            except Exception as e:
                add_log(f"[{symbol}] 拉取实盘余额失败: {e}", "WARN")
                usdt_bal, coin_bal = 0.0, 0.0
        else:
            with state_lock:
                usdt_bal = float(runtime_state["balances"].get("USDT", 0.0))
                coin_bal = float(runtime_state["balances"].get(symbol, 0.0))

        sl_tp_triggered = self.check_sl_tp(client, symbol, current_price, coin_bal)

        try:
            ohlcv = client.fetch_ohlcv(symbol, timeframe=timeframe, limit=40)
            htf_ohlcv = client.fetch_ohlcv(symbol, timeframe="1h", limit=35) if timeframe != "1h" else None
            indicators = compute_indicators(ohlcv, htf_ohlcv)
        except Exception:
            indicators = {"summary": "暂无K线", "rsi14": None, "trend": "-"}

        with state_lock:
            metric = runtime_state["task_metrics"].setdefault(
                task_id,
                {
                    "symbol": symbol,
                    "current_price": 0.0,
                    "change_24h": 0.0,
                    "rsi14": None,
                    "trend": "-",
                    "ai_status": "准备中...",
                    "status": "IDLE",
                },
            )
            metric["current_price"] = current_price
            metric["change_24h"] = round(change_24h, 2)
            metric["rsi14"] = indicators.get("rsi14")
            metric["trend"] = indicators.get("trend", "-")

        if sl_tp_triggered:
            with state_lock:
                runtime_state["task_metrics"][task_id]["ai_status"] = "已触发风控止盈/止损平仓"
            return {"action": "sl_tp", "executed": True}

        sys_prompt = self.resolve_task_prompt(task)
        decision = self.consult_ai_pool(
            symbol, current_price, change_24h, usdt_bal, coin_bal, indicators, sys_prompt
        )
        action = decision["action"]
        amount_usdt = decision["amount_usdt"]
        reason = decision["reason"]
        provider = decision["provider"]

        with state_lock:
            runtime_state["task_metrics"][task_id]["ai_status"] = (
                f"[{provider}] 决策:【{action.upper()}】({reason})"
            )
        add_log(
            f"🧠 [{symbol}] [{provider}] 决策:{action.upper()} | 金额:{amount_usdt:.1f}U | {reason}"
        )

        executed = False
        if action in ("buy", "sell") and amount_usdt > 0:
            executed = self.execute_order(
                client,
                symbol,
                action,
                amount_usdt,
                current_price,
                source="AI",
                provider=provider,
                reason=reason,
            )

        return {"action": action, "amount_usdt": amount_usdt, "reason": reason, "provider": provider, "executed": executed}

    def task_worker(self, task_id: str, stop_event: threading.Event) -> None:
        with config_lock:
            task = next((dict(t) for t in app_config["tasks"] if t["id"] == task_id), None)
        if not task:
            return

        symbol = task["symbol"]
        interval = max(5, int(task.get("interval", 30)))

        with state_lock:
            runtime_state["task_metrics"][task_id] = {
                "symbol": symbol,
                "current_price": 0.0,
                "change_24h": 0.0,
                "rsi14": None,
                "trend": "-",
                "ai_status": "AI操盘手准备就绪...",
                "status": "RUNNING",
            }

        add_log(f"🚀 启动自动化操盘任务 [{symbol}] (周期: {task.get('timeframe', '15m')} | 轮询: {interval}s)")

        consecutive_errors = 0
        while not stop_event.is_set():
            try:
                client = self.get_exchange_client()
                with config_lock:
                    latest_task = next((dict(t) for t in app_config["tasks"] if t["id"] == task_id), task)
                self.run_single_cycle(latest_task, client)
                consecutive_errors = 0
            except Exception as e:
                consecutive_errors += 1
                add_log(f"[{symbol}] 运行循环异常 ({consecutive_errors}次): {e}", "ERROR")
                if consecutive_errors >= 3:
                    self.invalidate_client()
                    add_log(f"🔄 [{symbol}] 连续异常，已自动重建交易所连接", "WARN")

            stop_event.wait(interval)

        with state_lock:
            if task_id in runtime_state["task_metrics"]:
                runtime_state["task_metrics"][task_id]["status"] = "STOPPED"
        add_log(f"🛑 任务 [{symbol}] 已安全停止。")

    def start_task(self, task_id: str) -> None:
        with self.engine_lock:
            existing = self.threads.get(task_id)
            if existing and existing.is_alive():
                old_flag = self.stop_flags.get(task_id)
                if old_flag and not old_flag.is_set():
                    return
                if old_flag:
                    old_flag.set()
                existing.join(timeout=2.0)

            stop_event = threading.Event()
            self.stop_flags[task_id] = stop_event
            t = threading.Thread(target=self.task_worker, args=(task_id, stop_event), daemon=True)
            self.threads[task_id] = t
            t.start()

    def stop_task(self, task_id: str) -> None:
        with self.engine_lock:
            flag = self.stop_flags.get(task_id)
            if flag:
                flag.set()

    def emergency_stop_all(self) -> int:
        stopped = 0
        with config_lock:
            for t in app_config["tasks"]:
                if t.get("active"):
                    t["active"] = False
                    self.stop_task(t["id"])
                    stopped += 1
            save_config(app_config)
        add_log(f"🚨 [紧急停机] 已停止全部 {stopped} 个运行中任务！", "WARN")
        return stopped

    def watchdog_loop(self) -> None:
        while True:
            time.sleep(20)
            try:
                with config_lock:
                    active_ids = [t["id"] for t in app_config["tasks"] if t.get("active")]
                for tid in active_ids:
                    t = self.threads.get(tid)
                    if t is None or not t.is_alive():
                        add_log(f"🐶 [看门狗] 检测到任务 {tid} 线程意外退出，正在自动拉起...", "WARN")
                        self.start_task(tid)
            except Exception as e:
                logger.warning(f"Watchdog 异常: {e}")


engine = QuantEngine()
threading.Thread(target=engine.watchdog_loop, daemon=True).start()

app = FastAPI(title="AI Quant & Auto Trader Pro v4.0")


class ExchangeConfigModel(BaseModel):
    name: str
    api_key: str
    secret_key: str
    password: str = ""
    sandbox: bool
    real_trade: bool


class AIPoolItemModel(BaseModel):
    name: str
    provider_type: str = "openai_compat"
    base_url: str
    api_key: str
    model: str
    enabled: bool = True


class AIPoolConfigModel(BaseModel):
    enabled: bool
    rotation_mode: str = "failover"
    consensus_count: int = Field(default=1, ge=1, le=3)
    cooldown_on_fail_sec: int = Field(default=120, ge=10, le=3600)
    template_id: str = "trend_following"
    system_prompt: str
    timeout: int = Field(default=20, ge=5, le=120)
    temperature: float = Field(default=0.2, ge=0.0, le=1.5)
    pool: List[AIPoolItemModel]


class RiskConfigModel(BaseModel):
    max_order_usdt: float = Field(gt=0)
    min_order_usdt: float = Field(gt=0)
    max_position_pct: float = Field(ge=5, le=100)
    stop_loss_pct: float = Field(ge=0, le=90)
    take_profit_pct: float = Field(ge=0, le=500)
    trailing_stop_pct: float = Field(default=3.0, ge=0, le=50)
    daily_max_loss_usdt: float = Field(default=300.0, ge=0)
    cooldown_sec: int = Field(ge=0, le=3600)
    paper_initial_usdt: float = Field(default=10000.0, gt=0)


class NotifyConfigModel(BaseModel):
    enabled: bool
    telegram_bot_token: str = ""
    telegram_chat_id: str = ""
    webhook_url: str = ""
    notify_on_trade: bool = True
    notify_on_error: bool = True


class AuthConfigModel(BaseModel):
    enabled: bool
    username: str
    password: str


class TaskCreateModel(BaseModel):
    symbol: str
    timeframe: str = "15m"
    interval: int = Field(default=30, ge=5, le=86400)
    template_id: str = "global"
    custom_instruction: str = ""


class TaskUpdateModel(BaseModel):
    template_id: Optional[str] = None
    custom_instruction: Optional[str] = None
    timeframe: Optional[str] = None
    interval: Optional[int] = Field(default=None, ge=5, le=86400)


class ManualTradeModel(BaseModel):
    symbol: str
    side: str
    usdt_amount: float = Field(gt=0)


class TestAiNodeModel(BaseModel):
    provider_type: str = "openai_compat"
    base_url: str
    api_key: str
    model: str
    index: Optional[int] = None


def mask_config_for_client(cfg: Dict[str, Any]) -> Dict[str, Any]:
    safe = json.loads(json.dumps(cfg))
    if safe["exchange"].get("api_key"):
        safe["exchange"]["api_key"] = MASK_TOKEN
    if safe["exchange"].get("secret_key"):
        safe["exchange"]["secret_key"] = MASK_TOKEN
    if safe["exchange"].get("password"):
        safe["exchange"]["password"] = MASK_TOKEN
    if safe.get("auth", {}).get("password"):
        safe["auth"]["password"] = MASK_TOKEN
    if safe.get("notify", {}).get("telegram_bot_token"):
        safe["notify"]["telegram_bot_token"] = MASK_TOKEN
    for node in safe.get("ai_pool", []):
        if node.get("api_key"):
            node["api_key"] = MASK_TOKEN
    return safe


def compute_portfolio_summary() -> Dict[str, Any]:
    with config_lock:
        is_real = bool(app_config["exchange"].get("real_trade"))

    with state_lock:
        balances = dict(runtime_state["real_balances"] if is_real and runtime_state["real_balances"] else runtime_state["balances"])
        prices = dict(runtime_state["market_prices"])
        avg_prices = dict(runtime_state["avg_entry_prices"])
        breaker = bool(runtime_state["circuit_breaker_tripped"])

    usdt_free = float(balances.get("USDT", 0.0))
    positions_val = 0.0
    unrealized_pnl = 0.0
    positions = []

    for sym, qty in balances.items():
        if sym == "USDT" or qty <= 1e-8:
            continue
        pair = sym if "/" in sym else f"{sym}/USDT"
        cur_p = float(prices.get(pair, avg_prices.get(pair, 0.0)))
        avg_p = float(avg_prices.get(pair, cur_p))
        val = qty * cur_p
        u_pnl = (cur_p - avg_p) * qty if cur_p > 0 and avg_p > 0 else 0.0
        u_pnl_pct = ((cur_p - avg_p) / avg_p * 100.0) if avg_p > 0 else 0.0
        positions_val += val
        unrealized_pnl += u_pnl
        positions.append(
            {
                "symbol": pair,
                "qty": qty,
                "avg_entry": round(avg_p, 4),
                "current_price": round(cur_p, 4),
                "value_usdt": round(val, 2),
                "unrealized_pnl": round(u_pnl, 2),
                "unrealized_pnl_pct": round(u_pnl_pct, 2),
            }
        )

    stats = query_trade_stats()
    return {
        "total_equity": round(usdt_free + positions_val, 2),
        "usdt_free": round(usdt_free, 2),
        "positions_val": round(positions_val, 2),
        "unrealized_pnl": round(unrealized_pnl, 2),
        "today_pnl": round(query_today_realized_pnl(), 2),
        "circuit_breaker_tripped": breaker,
        "positions": positions,
        **stats,
    }


@app.get("/api/state", dependencies=[Depends(verify_auth)])
def get_state():
    with config_lock:
        safe_cfg = mask_config_for_client(app_config)
        is_real = bool(app_config["exchange"].get("real_trade"))
    if is_real:
        engine.sync_real_balances()
    with state_lock:
        rt_copy = {
            "logs": list(runtime_state["logs"]),
            "task_metrics": json.loads(json.dumps(runtime_state["task_metrics"])),
            "ai_health": json.loads(json.dumps(runtime_state["ai_health"])),
        }
    return {
        "config": safe_cfg,
        "runtime": rt_copy,
        "portfolio": compute_portfolio_summary(),
        "templates": PROMPT_TEMPLATES,
        "presets": AI_PRESETS,
    }


@app.get("/api/kline", dependencies=[Depends(verify_auth)])
def get_kline(symbol: str = "BTC/USDT", timeframe: str = "15m", limit: int = 120):
    try:
        client = engine.get_exchange_client()
        sym = symbol.upper().strip()
        ohlcv = client.fetch_ohlcv(sym, timeframe=timeframe, limit=limit)
        data = [
            {
                "time": int(c[0] / 1000),
                "open": float(c[1]),
                "high": float(c[2]),
                "low": float(c[3]),
                "close": float(c[4]),
            }
            for c in ohlcv
        ]
        closes = pd.Series([d["close"] for d in data])
        ema7_series = closes.ewm(span=7, adjust=False).mean().tolist()
        ema25_series = closes.ewm(span=25, adjust=False).mean().tolist()
        ema7_line = [{"time": data[i]["time"], "value": round(float(ema7_series[i]), 4)} for i in range(len(data))]
        ema25_line = [{"time": data[i]["time"], "value": round(float(ema25_series[i]), 4)} for i in range(len(data))]

        indicators = compute_indicators(ohlcv)
        recent_trades = query_trades(limit=30, symbol=sym)
        return {
            "status": "ok",
            "symbol": sym,
            "data": data,
            "ema7": ema7_line,
            "ema25": ema25_line,
            "indicators": indicators,
            "trades": recent_trades,
        }
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.get("/api/trades", dependencies=[Depends(verify_auth)])
def get_trades(limit: int = 50):
    return {"trades": query_trades(limit=limit), "pnl_series": query_pnl_series()}


@app.get("/api/trades/export", dependencies=[Depends(verify_auth)])
def export_trades_csv():
    trades = query_trades(limit=5000)
    df = pd.DataFrame(trades)
    csv_data = (
        df.to_csv(index=False)
        if not df.empty
        else "id,created_at,symbol,side,amount,price,usdt_value,pnl_usdt,mode,source,provider,reason,order_id\n"
    )
    return Response(
        content=csv_data,
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": "attachment; filename=ai_quant_trades.csv"},
    )


@app.post("/api/config/exchange", dependencies=[Depends(verify_auth)])
def update_exchange(cfg: ExchangeConfigModel):
    with config_lock:
        old = app_config["exchange"]
        new_key = old["api_key"] if cfg.api_key == MASK_TOKEN else cfg.api_key
        new_sec = old["secret_key"] if cfg.secret_key == MASK_TOKEN else cfg.secret_key
        if cfg.real_trade and (not new_key or not new_sec):
            raise HTTPException(status_code=400, detail="开启实盘交易前必须填写 API Key 和 Secret Key")
        app_config["exchange"] = {
            "name": cfg.name,
            "api_key": new_key,
            "secret_key": new_sec,
            "password": old.get("password", "") if cfg.password == MASK_TOKEN else cfg.password,
            "sandbox": cfg.sandbox,
            "real_trade": cfg.real_trade,
        }
        save_config(app_config)
    engine.invalidate_client()
    add_log(f"已更新交易所: {cfg.name.upper()} (实盘: {cfg.real_trade})")
    return {"status": "ok"}


@app.post("/api/config/ai_pool", dependencies=[Depends(verify_auth)])
def update_ai_pool(cfg: AIPoolConfigModel):
    with config_lock:
        old_pool = app_config.get("ai_pool", [])
        new_pool = []
        for idx, item in enumerate(cfg.pool):
            d = item.model_dump()
            if d["api_key"] == MASK_TOKEN and idx < len(old_pool):
                d["api_key"] = old_pool[idx].get("api_key", "")
            new_pool.append(d)
        app_config["ai"]["enabled"] = cfg.enabled
        app_config["ai"]["rotation_mode"] = cfg.rotation_mode
        app_config["ai"]["consensus_count"] = cfg.consensus_count
        app_config["ai"]["cooldown_on_fail_sec"] = cfg.cooldown_on_fail_sec
        app_config["ai"]["template_id"] = cfg.template_id
        app_config["ai"]["system_prompt"] = cfg.system_prompt
        app_config["ai"]["timeout"] = cfg.timeout
        app_config["ai"]["temperature"] = cfg.temperature
        app_config["ai_pool"] = new_pool
        save_config(app_config)
    with state_lock:
        runtime_state["ai_health"] = {}
    add_log(f"已更新全兼容 AI 轮替池 ({cfg.rotation_mode}, 共 {len(new_pool)} 个节点)")
    return {"status": "ok"}


@app.post("/api/ai_pool/reset_health", dependencies=[Depends(verify_auth)])
def reset_ai_health():
    with state_lock:
        runtime_state["ai_health"] = {}
    add_log("🔄 已重置所有 AI 节点健康冷却状态")
    return {"status": "ok"}


@app.post("/api/ai_pool/test", dependencies=[Depends(verify_auth)])
def test_ai_node(req: TestAiNodeModel):
    api_key = req.api_key
    if api_key == MASK_TOKEN and req.index is not None:
        with config_lock:
            pool = app_config.get("ai_pool", [])
            if 0 <= req.index < len(pool):
                api_key = pool[req.index].get("api_key", "")
    node = {
        "provider_type": req.provider_type,
        "base_url": req.base_url,
        "api_key": api_key,
        "model": req.model,
    }
    t0 = time.time()
    try:
        reply = call_universal_ai(
            node=node,
            system_prompt="Reply briefly.",
            user_msg="Reply with OK",
            timeout_sec=15,
            temperature=0.0,
            max_tokens=16,
        )
        ms = int((time.time() - t0) * 1000)
        return {"status": "ok", "latency_ms": ms, "reply": reply}
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.post("/api/config/risk", dependencies=[Depends(verify_auth)])
def update_risk(cfg: RiskConfigModel):
    with config_lock:
        app_config["risk"] = cfg.model_dump()
        save_config(app_config)
    with state_lock:
        runtime_state["circuit_breaker_tripped"] = False
    add_log(
        f"已更新风控: 单笔[{cfg.min_order_usdt}~{cfg.max_order_usdt}U], 止损-{cfg.stop_loss_pct}%, 止盈+{cfg.take_profit_pct}%, 追踪回撤{cfg.trailing_stop_pct}%"
    )
    return {"status": "ok"}


@app.post("/api/config/notify", dependencies=[Depends(verify_auth)])
def update_notify(cfg: NotifyConfigModel):
    with config_lock:
        old = app_config.get("notify", {})
        data = cfg.model_dump()
        if data["telegram_bot_token"] == MASK_TOKEN:
            data["telegram_bot_token"] = old.get("telegram_bot_token", "")
        app_config["notify"] = data
        save_config(app_config)
    add_log("已更新消息推送配置")
    return {"status": "ok"}


@app.post("/api/notify/test", dependencies=[Depends(verify_auth)])
def test_notify():
    send_notification("测试推送", "这是一条来自 AI Quant Pro 的测试通知，配置正常！")
    return {"status": "ok"}


@app.post("/api/config/auth", dependencies=[Depends(verify_auth)])
def update_auth(cfg: AuthConfigModel):
    with config_lock:
        old = app_config["auth"]
        app_config["auth"] = {
            "enabled": cfg.enabled,
            "username": cfg.username,
            "password": old["password"] if cfg.password == MASK_TOKEN else cfg.password,
        }
        save_config(app_config)
    add_log("已更新登录账号密码配置")
    return {"status": "ok"}


@app.post("/api/paper/reset", dependencies=[Depends(verify_auth)])
def reset_paper_account():
    with config_lock:
        init_usdt = float(app_config["risk"].get("paper_initial_usdt", 10000.0))
    with state_lock:
        runtime_state["balances"] = {"USDT": init_usdt}
        runtime_state["avg_entry_prices"] = {}
        runtime_state["peak_prices"] = {}
        runtime_state["last_trade_ts"] = {}
        runtime_state["recent_decisions"] = {}
        runtime_state["circuit_breaker_tripped"] = False
    save_paper_state()
    add_log(f"🔄 模拟盘账户已重置为初始资金 {init_usdt:.2f} USDT", "WARN")
    return {"status": "ok", "usdt": init_usdt}


@app.post("/api/tasks", dependencies=[Depends(verify_auth)])
def add_task(task: TaskCreateModel):
    new_id = f"task_{int(time.time() * 1000)}"
    t_dict = task.model_dump()
    t_dict["id"] = new_id
    t_dict["symbol"] = t_dict["symbol"].upper().strip()
    t_dict["strategy"] = "ai_auto"
    t_dict["active"] = False
    with config_lock:
        if any(t["symbol"] == t_dict["symbol"] for t in app_config["tasks"]):
            raise HTTPException(status_code=400, detail=f"{t_dict['symbol']} 任务已存在")
        app_config["tasks"].append(t_dict)
        save_config(app_config)
    add_log(f"新增操盘任务: {t_dict['symbol']} (模版: {t_dict['template_id']})")
    return {"status": "ok", "id": new_id}


@app.put("/api/tasks/{task_id}", dependencies=[Depends(verify_auth)])
def update_task(task_id: str, req: TaskUpdateModel):
    with config_lock:
        for t in app_config["tasks"]:
            if t["id"] == task_id:
                if req.template_id is not None:
                    t["template_id"] = req.template_id
                if req.custom_instruction is not None:
                    t["custom_instruction"] = req.custom_instruction
                if req.timeframe is not None:
                    t["timeframe"] = req.timeframe
                if req.interval is not None:
                    t["interval"] = req.interval
                save_config(app_config)
                add_log(f"已更新任务 [{t['symbol']}] 策略模版与指令")
                return {"status": "ok"}
    raise HTTPException(status_code=404, detail="任务不存在")


@app.delete("/api/tasks/{task_id}", dependencies=[Depends(verify_auth)])
def delete_task(task_id: str):
    engine.stop_task(task_id)
    with config_lock:
        app_config["tasks"] = [t for t in app_config["tasks"] if t["id"] != task_id]
        save_config(app_config)
    with state_lock:
        runtime_state["task_metrics"].pop(task_id, None)
    return {"status": "ok"}


@app.post("/api/tasks/{task_id}/toggle", dependencies=[Depends(verify_auth)])
def toggle_task(task_id: str):
    with config_lock:
        for t in app_config["tasks"]:
            if t["id"] == task_id:
                t["active"] = not t["active"]
                active = t["active"]
                save_config(app_config)
                break
        else:
            raise HTTPException(status_code=404, detail="任务不存在")

    if active:
        engine.start_task(task_id)
    else:
        engine.stop_task(task_id)
    return {"status": "ok", "active": active}


@app.post("/api/tasks/{task_id}/run_once", dependencies=[Depends(verify_auth)])
def run_task_once(task_id: str):
    with config_lock:
        task = next((dict(t) for t in app_config["tasks"] if t["id"] == task_id), None)
    if not task:
        raise HTTPException(status_code=404, detail="任务不存在")
    try:
        client = engine.get_exchange_client()
        result = engine.run_single_cycle(task, client)
        return {"status": "ok", "result": result}
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.post("/api/tasks/emergency_stop", dependencies=[Depends(verify_auth)])
def emergency_stop():
    stopped = engine.emergency_stop_all()
    return {"status": "ok", "stopped": stopped}


@app.post("/api/trade/manual", dependencies=[Depends(verify_auth)])
def manual_trade(req: ManualTradeModel):
    try:
        client = engine.get_exchange_client()
        symbol = req.symbol.upper().strip()
        ticker = client.fetch_ticker(symbol)
        price = float(ticker["last"])
        with state_lock:
            runtime_state["market_prices"][symbol] = price
        ok = engine.execute_order(
            client,
            symbol,
            req.side.lower(),
            req.usdt_amount,
            price,
            source="MANUAL",
            provider="User",
            reason="手动市价干预",
            bypass_risk=True,
        )
        if not ok:
            raise HTTPException(status_code=400, detail="下单未执行，请检查余额或日志")
        return {"status": "ok"}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.get("/", response_class=HTMLResponse, dependencies=[Depends(verify_auth)])
def dashboard():
    return HTMLResponse(content=HTML_DASHBOARD)


HTML_DASHBOARD = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>AI Quant Pro v4.0 - 全协议AI轮替自主量化中枢</title>
    <style>
        :root { --bg: #0b0f19; --card: #151c2c; --border: #263147; --text: #e2e8f0; --muted: #94a3b8; --primary: #3b82f6; --green: #10b981; --red: #ef4444; --amber: #f59e0b; }
        * { box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: var(--bg); color: var(--text); margin: 0; padding: 20px; }
        .container { max-width: 1380px; margin: 0 auto; }
        header { display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid var(--border); padding-bottom: 15px; margin-bottom: 20px; flex-wrap: wrap; gap: 10px; }
        h1 { margin: 0; font-size: 21px; display: flex; align-items: center; gap: 10px; }
        .tabs { display: flex; gap: 8px; margin-bottom: 20px; flex-wrap: wrap; }
        .tab-btn { background: var(--card); border: 1px solid var(--border); color: var(--muted); padding: 9px 16px; border-radius: 8px; cursor: pointer; font-weight: 600; font-size: 13px; }
        .tab-btn.active { background: var(--primary); color: white; border-color: var(--primary); }
        .panel { display: none; }
        .panel.active { display: block; }
        .kpi-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 12px; margin-bottom: 18px; }
        .kpi-card { background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 14px 16px; }
        .kpi-label { font-size: 12px; color: var(--muted); margin-bottom: 4px; }
        .kpi-val { font-size: 19px; font-weight: 700; }
        .grid-2 { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }
        .grid-3 { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 12px; }
        .card { background: var(--card); border: 1px solid var(--border); border-radius: 12px; padding: 20px; margin-bottom: 20px; }
        .card h2 { margin-top: 0; font-size: 16px; color: #38bdf8; border-bottom: 1px solid var(--border); padding-bottom: 10px; }
        .form-group { margin-bottom: 12px; }
        label { display: block; font-size: 13px; color: var(--muted); margin-bottom: 5px; }
        input, select, textarea { width: 100%; background: var(--bg); border: 1px solid var(--border); color: var(--text); padding: 9px 12px; border-radius: 6px; font-size: 14px; }
        .btn { padding: 9px 16px; border: none; border-radius: 6px; font-weight: 600; cursor: pointer; font-size: 13px; transition: 0.2s; }
        .btn:hover { opacity: 0.9; }
        .btn-primary { background: var(--primary); color: white; }
        .btn-green { background: var(--green); color: white; }
        .btn-red { background: var(--red); color: white; }
        .btn-amber { background: var(--amber); color: #111827; }
        .btn-slate { background: #334155; color: white; }
        .btn-sm { padding: 5px 10px; font-size: 12px; }
        table { width: 100%; border-collapse: collapse; margin-top: 10px; font-size: 13px; }
        th, td { text-align: left; padding: 10px 12px; border-bottom: 1px solid var(--border); vertical-align: top; }
        th { color: var(--muted); font-weight: 500; }
        .badge { padding: 3px 8px; border-radius: 4px; font-size: 12px; font-weight: bold; display: inline-block; }
        .badge-run { background: rgba(16, 185, 129, 0.2); color: var(--green); }
        .badge-stop { background: rgba(239, 68, 68, 0.2); color: var(--red); }
        .badge-warn { background: rgba(245, 158, 11, 0.2); color: var(--amber); }
        .log-box { background: #070a11; border: 1px solid var(--border); border-radius: 8px; padding: 12px; height: 260px; overflow-y: auto; font-family: monospace; font-size: 12px; line-height: 1.6; color: #a7f3d0; }
        .ai-node-box { background: #0b0f19; border: 1px solid var(--border); padding: 14px; border-radius: 8px; margin-bottom: 12px; }
        .tpl-card { background: #0b0f19; border: 1px solid var(--border); border-radius: 8px; padding: 12px; cursor: pointer; transition: 0.15s; }
        .tpl-card:hover { border-color: var(--primary); }
        .tpl-card.selected { border-color: var(--green); background: rgba(16, 185, 129, 0.08); }
        .toast { position: fixed; right: 20px; bottom: 20px; background: #1e293b; color: #f8fafc; border: 1px solid var(--primary); padding: 12px 18px; border-radius: 8px; z-index: 9999; display: none; box-shadow: 0 8px 24px rgba(0,0,0,0.5); }
        @media(max-width: 768px) { .grid-2, .grid-3 { grid-template-columns: 1fr; } }
    </style>
</head>
<body>
<div class="container">
    <header>
        <h1>⚡ AI Quant Pro v4.0 <span style="font-size:12px; color:var(--muted); font-weight:normal;">全协议AI轮替 · 24H全自动量化</span></h1>
        <div style="display:flex; gap:10px; align-items:center; flex-wrap:wrap;">
            <div id="breakerBadge" class="badge badge-stop" style="display:none;">🚨 日亏损熔断中</div>
            <div id="modeBadge" class="badge badge-run">连接中...</div>
            <button class="btn btn-red btn-sm" onclick="emergencyStop()">🚨 一键全停</button>
        </div>
    </header>

    <div class="tabs">
        <button class="tab-btn active" onclick="switchTab('dashboard', this)">📊 操盘监控与K线</button>
        <button class="tab-btn" onclick="switchTab('trades_panel', this)">📑 成交记录与净值</button>
        <button class="tab-btn" onclick="switchTab('ai_pool_panel', this)">🧠 全协议AI轮替池与模版</button>
        <button class="tab-btn" onclick="switchTab('risk_panel', this)">🛡️ 风控与通知</button>
        <button class="tab-btn" onclick="switchTab('settings', this)">⚙️ 交易所设置</button>
        <button class="tab-btn" onclick="switchTab('security', this)">🔐 安全设置</button>
    </div>

    <div id="dashboard" class="panel active">
        <div class="kpi-grid">
            <div class="kpi-card"><div class="kpi-label">账户总净值 (USDT)</div><div class="kpi-val" id="kpiEquity">-</div></div>
            <div class="kpi-card"><div class="kpi-label">可用 USDT</div><div class="kpi-val" id="kpiFree">-</div></div>
            <div class="kpi-card"><div class="kpi-label">持仓浮动盈亏</div><div class="kpi-val" id="kpiUnrealized">-</div></div>
            <div class="kpi-card"><div class="kpi-label">当日已实现盈亏</div><div class="kpi-val" id="kpiToday">-</div></div>
            <div class="kpi-card"><div class="kpi-label">累计已实现盈亏</div><div class="kpi-val" id="kpiRealized">-</div></div>
            <div class="kpi-card"><div class="kpi-label">胜率 / 总成交</div><div class="kpi-val" id="kpiWinRate">-</div></div>
        </div>

        <div class="card">
            <div style="display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; gap:10px; border-bottom:1px solid var(--border); padding-bottom:10px; margin-bottom:12px;">
                <h2 style="margin:0; border:none; padding:0;">📈 实时 K 线与 EMA(7/25) 均线 (<span id="chartTitle">BTC/USDT</span>)</h2>
                <div style="display:flex; gap:8px; align-items:center; flex-wrap:wrap;">
                    <input type="text" id="chartSymbolInput" value="BTC/USDT" style="width:120px; padding:5px 10px;">
                    <select id="chartTimeframe" style="width:90px; padding:5px 8px;" onchange="loadNativeChart()">
                        <option value="1m">1分钟</option>
                        <option value="5m">5分钟</option>
                        <option value="15m" selected>15分钟</option>
                        <option value="1h">1小时</option>
                        <option value="4h">4小时</option>
                        <option value="1d">1天</option>
                    </select>
                    <button class="btn btn-primary btn-sm" onclick="loadNativeChart()">刷新/切换</button>
                </div>
            </div>
            <div id="kline_status" style="font-size:12px; color:var(--muted); margin-bottom:6px;">正在连接交易所拉取K线数据...</div>
            <div id="native_chart_container" style="height: 360px; width: 100%; background:#070a11; border-radius:8px; border:1px solid var(--border);"></div>
        </div>

        <div class="grid-2">
            <div class="card">
                <h2>➕ 添加自主操盘任务</h2>
                <div class="grid-2" style="gap:10px;">
                    <div class="form-group"><label>交易对</label><input type="text" id="t_symbol" value="BTC/USDT"></div>
                    <div class="form-group"><label>K线分析周期</label>
                        <select id="t_timeframe">
                            <option value="5m">5分钟 (短线)</option>
                            <option value="15m" selected>15分钟 (标准)</option>
                            <option value="1h">1小时 (波段)</option>
                        </select>
                    </div>
                </div>
                <div class="grid-2" style="gap:10px;">
                    <div class="form-group"><label>轮询间隔 (秒)</label><input type="number" id="t_interval" value="30" min="5"></div>
                    <div class="form-group"><label>AI 操盘指令模版</label><select id="t_template"></select></div>
                </div>
                <div class="form-group"><label>针对该币种的额外指令 (可选)</label><input type="text" id="t_custom" placeholder="例如：仅在放量突破时买入，单次不超过50U"></div>
                <button class="btn btn-primary" onclick="addTask()">创建自动操盘任务</button>
            </div>

            <div class="card">
                <h2>⚡ 极速人工市价干预</h2>
                <div class="form-group"><label>目标交易对</label><input type="text" id="m_symbol" value="BTC/USDT"></div>
                <div class="form-group"><label>交易金额 (USDT)</label><input type="number" id="m_amount" value="100" min="1"></div>
                <div style="display:flex; gap:10px; margin-top:20px;">
                    <button class="btn btn-green" style="flex:1" onclick="manualTrade('buy')">🟢 市价买入</button>
                    <button class="btn btn-red" style="flex:1" onclick="manualTrade('sell')">🔴 市价卖出</button>
                </div>
            </div>
        </div>

        <div class="card">
            <h2>🤖 自动化操盘队列 (可随时点击「⚡ 决策」测试 AI 自主买卖)</h2>
            <div style="overflow-x:auto;">
                <table>
                    <thead>
                        <tr><th>交易对 / 周期</th><th>最新价 / 24H</th><th>RSI / 趋势</th><th>AI 模版与指令</th><th>AI 实时决策</th><th>状态</th><th>操作</th></tr>
                    </thead>
                    <tbody id="taskTableBody"></tbody>
                </table>
            </div>
        </div>

        <div class="card">
            <h2>📜 实时运行日志与 AI 轮替记录</h2>
            <div class="log-box" id="logBox"></div>
        </div>
    </div>

    <div id="trades_panel" class="panel">
        <div class="card">
            <h2>📈 累计已实现盈亏曲线 (USDT)</h2>
            <div id="pnl_chart_container" style="height: 220px; width: 100%; background:#070a11; border-radius:8px; border:1px solid var(--border);"></div>
        </div>
        <div class="card">
            <div style="display:flex; justify-content:space-between; align-items:center; border-bottom:1px solid var(--border); padding-bottom:10px; margin-bottom:10px;">
                <h2 style="margin:0; border:none; padding:0;">💼 当前持仓明细</h2>
                <button class="btn btn-amber btn-sm" onclick="resetPaper()">🔄 重置模拟盘资金</button>
            </div>
            <div style="overflow-x:auto;">
                <table>
                    <thead><tr><th>交易对</th><th>持仓数量</th><th>持仓均价</th><th>最新价</th><th>估值(USDT)</th><th>浮动盈亏</th></tr></thead>
                    <tbody id="positionsBody"></tbody>
                </table>
            </div>
        </div>
        <div class="card">
            <div style="display:flex; justify-content:space-between; align-items:center; border-bottom:1px solid var(--border); padding-bottom:10px; margin-bottom:10px;">
                <h2 style="margin:0; border:none; padding:0;">📑 最近成交历史</h2>
                <a href="/api/trades/export" class="btn btn-primary btn-sm" style="text-decoration:none;">⬇️ 导出 CSV</a>
            </div>
            <div style="overflow-x:auto;">
                <table>
                    <thead><tr><th>时间</th><th>交易对</th><th>方向</th><th>价格</th><th>金额(U)</th><th>已实现盈亏</th><th>来源/引擎</th><th>理由</th></tr></thead>
                    <tbody id="tradesBody"></tbody>
                </table>
            </div>
        </div>
    </div>

    <div id="ai_pool_panel" class="panel">
        <div class="card" style="max-width: 1020px; margin: 0 auto;">
            <h2>🎯 AI 操盘指令模版库 (点击即可一键载入)</h2>
            <div id="templateGrid" style="display:grid; grid-template-columns:repeat(auto-fit, minmax(260px, 1fr)); gap:10px; margin-bottom:18px;"></div>

            <h2>🧠 全协议 AI 轮替池配置 (兼容 OpenAI / DeepSeek / Claude / Gemini / 通义 / Kimi / 智谱 / Ollama 等)</h2>
            <div class="grid-3">
                <div class="form-group"><label>总开关</label><select id="ai_enabled"><option value="true">✅ 启用</option><option value="false">❌ 关闭</option></select></div>
                <div class="form-group"><label>轮替调度策略</label>
                    <select id="ai_rotation">
                        <option value="failover">🛡️ 顺位容灾轮替 (挂了自动换下一个)</option>
                        <option value="round_robin">🔄 负载均衡轮询 (健康节点轮流用)</option>
                    </select>
                </div>
                <div class="form-group"><label>AI 共振确认 (防单模型误判)</label>
                    <select id="ai_consensus">
                        <option value="1">1个 AI 决策即执行 (快)</option>
                        <option value="2">2个 AI 意见一致才买卖 (稳)</option>
                    </select>
                </div>
            </div>
            <div class="grid-3">
                <div class="form-group"><label>单节点超时 (秒)</label><input type="number" id="ai_timeout" value="20" min="5" max="120"></div>
                <div class="form-group"><label>失败节点冷却时间 (秒)</label><input type="number" id="ai_cooldown" value="120" min="10" max="3600"></div>
                <div class="form-group"><label>采样温度 (Temperature)</label><input type="number" id="ai_temp" value="0.2" step="0.1" min="0" max="1.5"></div>
            </div>
            <div class="form-group"><label>全局默认 System Prompt</label><textarea id="ai_prompt" rows="4"></textarea></div>

            <div style="display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; gap:10px; margin:16px 0 10px 0; border-bottom:1px solid var(--border); padding-bottom:10px;">
                <h3 style="color:#38bdf8; font-size:15px; margin:0;">AI 模型轮替队列</h3>
                <div style="display:flex; gap:8px; align-items:center; flex-wrap:wrap;">
                    <select id="presetSelect" style="width:220px; padding:6px 10px; font-size:13px;"></select>
                    <button class="btn btn-sm btn-green" onclick="addPresetNode()">➕ 一键添加该AI</button>
                    <button class="btn btn-sm btn-amber" onclick="resetAiHealth()">🔄 重置冷却状态</button>
                </div>
            </div>
            <div id="aiNodesContainer"></div>
            <div style="margin-top:20px; display:flex; gap:10px;">
                <button class="btn btn-primary" onclick="saveAIPool()">💾 保存 AI 模版与轮替池配置</button>
            </div>
        </div>
    </div>

    <div id="risk_panel" class="panel">
        <div class="grid-2">
            <div class="card">
                <h2>🛡️ 量化风控参数</h2>
                <div class="grid-2" style="gap:10px;">
                    <div class="form-group"><label>单笔最小下单 (USDT)</label><input type="number" id="r_min" value="10"></div>
                    <div class="form-group"><label>单笔最大下单 (USDT)</label><input type="number" id="r_max" value="200"></div>
                </div>
                <div class="grid-2" style="gap:10px;">
                    <div class="form-group"><label>单币种最大仓位占比 (%)</label><input type="number" id="r_pos" value="80"></div>
                    <div class="form-group"><label>同币种交易冷却时间 (秒)</label><input type="number" id="r_cd" value="45"></div>
                </div>
                <div class="grid-2" style="gap:10px;">
                    <div class="form-group"><label>自动止损阈值 (%，0=关闭)</label><input type="number" id="r_sl" value="5" step="0.5"></div>
                    <div class="form-group"><label>自动止盈阈值 (%，0=关闭)</label><input type="number" id="r_tp" value="10" step="0.5"></div>
                </div>
                <div class="grid-2" style="gap:10px;">
                    <div class="form-group"><label>追踪止盈回撤 (%，0=关闭)</label><input type="number" id="r_trail" value="3" step="0.5"></div>
                    <div class="form-group"><label>当日最大亏损熔断 (USDT)</label><input type="number" id="r_daily_loss" value="300"></div>
                </div>
                <div class="form-group"><label>模拟盘重置初始资金 (USDT)</label><input type="number" id="r_init" value="10000"></div>
                <button class="btn btn-primary" onclick="saveRisk()">保存风控参数</button>
            </div>
            <div class="card">
                <h2>🔔 Telegram / Webhook 实时推送</h2>
                <div class="form-group"><label>推送开关</label><select id="n_enabled"><option value="false">❌ 关闭</option><option value="true">✅ 开启</option></select></div>
                <div class="form-group"><label>Telegram Bot Token</label><input type="password" id="n_tg_token"></div>
                <div class="form-group"><label>Telegram Chat ID</label><input type="text" id="n_tg_chat"></div>
                <div class="form-group"><label>通用 Webhook URL (钉钉/飞书/Discord)</label><input type="text" id="n_webhook"></div>
                <div class="form-group"><label>成交通知</label><select id="n_trade"><option value="true">开启</option><option value="false">关闭</option></select></div>
                <div class="form-group"><label>异常告警</label><select id="n_err"><option value="true">开启</option><option value="false">关闭</option></select></div>
                <div style="display:flex; gap:10px;">
                    <button class="btn btn-primary" onclick="saveNotify()">保存推送配置</button>
                    <button class="btn btn-amber" onclick="testNotify()">发送测试通知</button>
                </div>
            </div>
        </div>
    </div>

    <div id="settings" class="panel">
        <div class="card" style="max-width: 600px; margin: 0 auto;">
            <h2>🏦 交易所 API 设置 (CCXT)</h2>
            <div class="form-group"><label>交易所</label>
                <select id="ex_name">
                    <option value="binance">Binance (币安)</option>
                    <option value="okx">OKX (欧易)</option>
                    <option value="bybit">Bybit</option>
                    <option value="gateio">Gate.io</option>
                </select>
            </div>
            <div class="form-group"><label>API Key</label><input type="password" id="ex_key"></div>
            <div class="form-group"><label>Secret Key</label><input type="password" id="ex_secret"></div>
            <div class="form-group"><label>Passphrase (OKX等需要)</label><input type="password" id="ex_pass"></div>
            <div class="form-group"><label>沙盒测试网</label><select id="ex_sandbox"><option value="true">开启Sandbox</option><option value="false">关闭</option></select></div>
            <div class="form-group"><label>交易模式</label><select id="ex_real"><option value="false">🧪 本地模拟盘</option><option value="true">🔥 真实资金实盘</option></select></div>
            <button class="btn btn-primary" onclick="saveExchange()">保存交易所配置</button>
        </div>
    </div>

    <div id="security" class="panel">
        <div class="card" style="max-width: 600px; margin: 0 auto;">
            <h2>🔐 面板登录账号密码设置</h2>
            <div class="form-group"><label>登录验证开关</label><select id="auth_enabled"><option value="true">🛡️ 开启验证</option><option value="false">⚠️ 关闭验证</option></select></div>
            <div class="form-group"><label>用户名</label><input type="text" id="auth_user" value="admin"></div>
            <div class="form-group"><label>新密码</label><input type="password" id="auth_pass"></div>
            <button class="btn btn-primary" onclick="saveAuth()">更新密码</button>
        </div>
    </div>
</div>
<div id="toast" class="toast"></div>

<script src="https://unpkg.com/lightweight-charts@4.1.3/dist/lightweight-charts.standalone.production.js"></script>
<script>
    let initialized = false;
    let chartInstance = null;
    let candleSeries = null;
    let ema7Series = null;
    let ema25Series = null;
    let pnlChartInstance = null;
    let pnlAreaSeries = null;
    window.currentPool = [];
    window.aiHealth = {};
    window.templatesMap = {};
    window.presetsMap = {};
    window.selectedTemplateId = 'trend_following';

    function esc(str) {
        return String(str ?? '').replace(/[&<>"']/g, m => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[m]));
    }

    function showToast(msg) {
        const el = document.getElementById('toast');
        el.innerText = msg;
        el.style.display = 'block';
        setTimeout(() => { el.style.display = 'none'; }, 3000);
    }

    function switchTab(tabId, btn) {
        document.querySelectorAll('.panel').forEach(p => p.classList.remove('active'));
        document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
        document.getElementById(tabId).classList.add('active');
        btn.classList.add('active');
        if (tabId === 'dashboard' && chartInstance) {
            setTimeout(() => chartInstance.applyOptions({ width: document.getElementById('native_chart_container').clientWidth }), 150);
        }
        if (tabId === 'trades_panel') loadTrades();
    }

    function initChart() {
        const container = document.getElementById('native_chart_container');
        if (!container || chartInstance || typeof LightweightCharts === 'undefined') return;
        chartInstance = LightweightCharts.createChart(container, {
            width: container.clientWidth,
            height: 360,
            layout: { background: { color: '#070a11' }, textColor: '#94a3b8' },
            grid: { vertLines: { color: '#1e293b' }, horzLines: { color: '#1e293b' } },
            timeScale: { timeVisible: true, secondsVisible: false, borderColor: '#263147' },
            rightPriceScale: { borderColor: '#263147' },
        });
        candleSeries = chartInstance.addCandlestickSeries({
            upColor: '#10b981', downColor: '#ef4444',
            borderDownColor: '#ef4444', borderUpColor: '#10b981',
            wickDownColor: '#ef4444', wickUpColor: '#10b981',
        });
        ema7Series = chartInstance.addLineSeries({ color: '#f59e0b', lineWidth: 1.5, title: 'EMA7' });
        ema25Series = chartInstance.addLineSeries({ color: '#38bdf8', lineWidth: 1.5, title: 'EMA25' });
        window.addEventListener('resize', () => {
            if (chartInstance && container) chartInstance.applyOptions({ width: container.clientWidth });
        });
    }

    async function loadNativeChart() {
        initChart();
        const sym = document.getElementById('chartSymbolInput').value.trim().toUpperCase();
        const tf = document.getElementById('chartTimeframe').value;
        const statusEl = document.getElementById('kline_status');
        document.getElementById('chartTitle').innerText = `${sym} (${tf})`;
        try {
            const res = await fetch(`/api/kline?symbol=${encodeURIComponent(sym)}&timeframe=${tf}&limit=120`);
            const json = await res.json();
            if (!res.ok) { statusEl.innerText = `加载失败: ${json.detail}`; return; }
            if (candleSeries && json.data && json.data.length > 0) {
                candleSeries.setData(json.data);
                if (ema7Series && json.ema7) ema7Series.setData(json.ema7);
                if (ema25Series && json.ema25) ema25Series.setData(json.ema25);
                if (json.trades && json.trades.length > 0) {
                    const markers = json.trades.slice().reverse().map(tr => ({
                        time: tr.timestamp,
                        position: tr.side === 'buy' ? 'belowBar' : 'aboveBar',
                        color: tr.side === 'buy' ? '#10b981' : '#ef4444',
                        shape: tr.side === 'buy' ? 'arrowUp' : 'arrowDown',
                        text: tr.side.toUpperCase()
                    }));
                    candleSeries.setMarkers(markers);
                } else {
                    candleSeries.setMarkers([]);
                }
                chartInstance.timeScale().fitContent();
                const last = json.data[json.data.length - 1];
                const ind = json.indicators || {};
                statusEl.innerText = `✅ 最新: ${last.close} | EMA7(黄): ${ind.ema7 ?? '-'} | EMA25(蓝): ${ind.ema25 ?? '-'} | RSI(14): ${ind.rsi14 ?? '-'} | 量比: ${ind.vol_ratio ?? '-'}x`;
            }
        } catch (e) { statusEl.innerText = `图表加载异常: ${e.message}`; }
    }

    function selectSymbolChart(sym) {
        document.getElementById('chartSymbolInput').value = sym;
        loadNativeChart();
    }

    function renderTemplates() {
        const grid = document.getElementById('templateGrid');
        const sel = document.getElementById('t_template');
        const entries = Object.entries(window.templatesMap);
        grid.innerHTML = entries.map(([id, t]) => `
            <div class="tpl-card ${window.selectedTemplateId === id ? 'selected' : ''}" onclick="applyGlobalTemplate('${esc(id)}')">
                <div style="font-weight:700; margin-bottom:4px; font-size:14px;">${esc(t.name)}</div>
                <div style="font-size:12px; color:var(--muted); line-height:1.4;">${esc(t.desc)}</div>
            </div>
        `).join('');
        sel.innerHTML = `<option value="global">跟随全局默认模版</option>` + entries.map(([id, t]) => `<option value="${esc(id)}">${esc(t.name)}</option>`).join('');
    }

    function renderPresets() {
        const sel = document.getElementById('presetSelect');
        sel.innerHTML = Object.entries(window.presetsMap).map(([k, p]) => `<option value="${esc(k)}">${esc(p.label)}</option>`).join('');
    }

    function applyGlobalTemplate(id) {
        const tpl = window.templatesMap[id];
        if (!tpl) return;
        window.selectedTemplateId = id;
        document.getElementById('ai_prompt').value = tpl.prompt;
        renderTemplates();
        showToast(`已载入模版: ${tpl.name}（点击下方保存生效）`);
    }

    function syncPoolFromDom() {
        window.currentPool = Array.from(document.querySelectorAll('.ai-node-box')).map(box => ({
            name: box.querySelector('.node-name').value,
            provider_type: box.querySelector('.node-ptype').value,
            base_url: box.querySelector('.node-url').value,
            api_key: box.querySelector('.node-key').value,
            model: box.querySelector('.node-model').value,
            enabled: box.querySelector('.node-enabled').value === 'true'
        }));
    }

    function renderAiNodes(pool) {
        const container = document.getElementById('aiNodesContainer');
        container.innerHTML = pool.map((node, index) => {
            const h = window.aiHealth[String(index)] || {};
            let healthBadge = '<span class="badge badge-run">待命</span>';
            if (h.status === 'HEALTHY') healthBadge = `<span class="badge badge-run">在线 (${h.latency_ms}ms)</span>`;
            else if (h.status === 'COOLING') healthBadge = `<span class="badge badge-warn">冷却中 (失败${h.fail_count}次)</span>`;
            const ptype = node.provider_type || 'openai_compat';
            return `
            <div class="ai-node-box" data-index="${index}">
                <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:10px; flex-wrap:wrap; gap:8px;">
                    <div style="display:flex; align-items:center; gap:8px;">
                        <strong style="color:#38bdf8;">顺位 #${index + 1}</strong>
                        ${healthBadge}
                    </div>
                    <div style="display:flex; gap:6px;">
                        <button class="btn btn-sm btn-slate" onclick="moveAiNode(${index}, -1)">↑</button>
                        <button class="btn btn-sm btn-slate" onclick="moveAiNode(${index}, 1)">↓</button>
                        <button class="btn btn-sm btn-amber" onclick="testAiNode(${index})">测试连通</button>
                        <button class="btn btn-sm btn-red" onclick="removeAiNode(${index})">删除</button>
                    </div>
                </div>
                <div class="grid-3">
                    <div class="form-group"><label>节点名称</label><input type="text" class="node-name" value="${esc(node.name)}"></div>
                    <div class="form-group"><label>协议类型 (全兼容)</label>
                        <select class="node-ptype">
                            <option value="openai_compat" ${ptype === 'openai_compat' ? 'selected' : ''}>OpenAI 兼容 (DeepSeek/Qwen/Kimi/GLM/Grok/Ollama)</option>
                            <option value="anthropic" ${ptype === 'anthropic' ? 'selected' : ''}>Anthropic Claude 原生</option>
                            <option value="gemini" ${ptype === 'gemini' ? 'selected' : ''}>Google Gemini 原生</option>
                            <option value="azure_openai" ${ptype === 'azure_openai' ? 'selected' : ''}>Azure OpenAI</option>
                        </select>
                    </div>
                    <div class="form-group"><label>启用状态</label>
                        <select class="node-enabled">
                            <option value="true" ${node.enabled !== false ? 'selected' : ''}>✅ 启用</option>
                            <option value="false" ${node.enabled === false ? 'selected' : ''}>⏸️ 停用</option>
                        </select>
                    </div>
                </div>
                <div class="grid-3">
                    <div class="form-group"><label>API Base URL</label><input type="text" class="node-url" value="${esc(node.base_url)}"></div>
                    <div class="form-group"><label>API Key</label><input type="password" class="node-key" value="${esc(node.api_key)}"></div>
                    <div class="form-group"><label>模型名称 (Model)</label><input type="text" class="node-model" value="${esc(node.model)}"></div>
                </div>
            </div>
        `}).join('');
    }

    function addPresetNode() {
        syncPoolFromDom();
        const key = document.getElementById('presetSelect').value;
        const p = window.presetsMap[key];
        if (!p) return;
        window.currentPool.push({
            name: p.label.split(' ')[0],
            provider_type: p.provider_type,
            base_url: p.base_url,
            api_key: '',
            model: p.model,
            enabled: true
        });
        renderAiNodes(window.currentPool);
        showToast(`已添加 ${p.label}，请填入 API Key 后保存`);
    }

    function moveAiNode(index, delta) {
        syncPoolFromDom();
        const target = index + delta;
        if (target < 0 || target >= window.currentPool.length) return;
        const tmp = window.currentPool[index];
        window.currentPool[index] = window.currentPool[target];
        window.currentPool[target] = tmp;
        renderAiNodes(window.currentPool);
    }

    function removeAiNode(index) {
        syncPoolFromDom();
        window.currentPool.splice(index, 1);
        renderAiNodes(window.currentPool);
    }

    async function testAiNode(index) {
        const box = document.querySelector(`.ai-node-box[data-index="${index}"]`);
        const payload = {
            provider_type: box.querySelector('.node-ptype').value,
            base_url: box.querySelector('.node-url').value,
            api_key: box.querySelector('.node-key').value,
            model: box.querySelector('.node-model').value,
            index: index
        };
        showToast('正在测试 AI 节点连通性...');
        const res = await fetch('/api/ai_pool/test', { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(payload) });
        const json = await res.json();
        if (res.ok) showToast(`✅ 节点正常! 延迟 ${json.latency_ms}ms`);
        else showToast(`❌ 测试失败: ${json.detail}`);
    }

    async function resetAiHealth() {
        await fetch('/api/ai_pool/reset_health', { method: 'POST' });
        showToast('✅ 已重置所有 AI 节点健康状态');
        refreshState();
    }

    function templateSelectHtml(taskId, currentTplId) {
        const opts = [`<option value="global" ${currentTplId === 'global' ? 'selected' : ''}>全局默认</option>`];
        for (const [id, t] of Object.entries(window.templatesMap)) {
            opts.push(`<option value="${esc(id)}" ${currentTplId === id ? 'selected' : ''}>${esc(t.name)}</option>`);
        }
        return `<select style="padding:4px 6px; font-size:12px;" onchange="updateTaskTemplate('${esc(taskId)}', this.value)">${opts.join('')}</select>`;
    }

    async function updateTaskTemplate(taskId, tplId) {
        await fetch(`/api/tasks/${taskId}`, {
            method: 'PUT',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({ template_id: tplId })
        });
        showToast('✅ 已切换该任务的 AI 指令模版');
    }

    async function editTaskInstruction(taskId, currentText) {
        const nextText = prompt('输入针对该币种的额外AI指令（留空清除）：', currentText || '');
        if (nextText === null) return;
        await fetch(`/api/tasks/${taskId}`, {
            method: 'PUT',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({ custom_instruction: nextText })
        });
        showToast('✅ 已更新自定义指令');
        refreshState();
    }

    async function runTaskOnce(taskId) {
        showToast('🧠 正在呼叫 AI 进行即时分析与自主决策...');
        const res = await fetch(`/api/tasks/${taskId}/run_once`, { method: 'POST' });
        const json = await res.json();
        if (res.ok) {
            const r = json.result || {};
            showToast(`✅ AI决策: ${String(r.action || '').toUpperCase()} (${r.executed ? '已自动执行下单' : '未触发下单'})`);
            refreshState();
        } else {
            showToast(`❌ 执行失败: ${json.detail}`);
        }
    }

    async function refreshState() {
        try {
            const res = await fetch('/api/state');
            if (res.status === 401) return;
            const data = await res.json();
            const cfg = data.config;
            const rt = data.runtime;
            const pf = data.portfolio;
            if (data.templates) window.templatesMap = data.templates;
            if (data.presets) window.presetsMap = data.presets;
            window.aiHealth = rt.ai_health || {};

            if (!initialized) {
                document.getElementById('ex_name').value = cfg.exchange.name;
                document.getElementById('ex_key').value = cfg.exchange.api_key;
                document.getElementById('ex_secret').value = cfg.exchange.secret_key;
                document.getElementById('ex_pass').value = cfg.exchange.password || '';
                document.getElementById('ex_sandbox').value = String(cfg.exchange.sandbox);
                document.getElementById('ex_real').value = String(cfg.exchange.real_trade);

                document.getElementById('ai_enabled').value = String(cfg.ai.enabled);
                document.getElementById('ai_rotation').value = cfg.ai.rotation_mode || 'failover';
                document.getElementById('ai_consensus').value = String(cfg.ai.consensus_count || 1);
                document.getElementById('ai_cooldown').value = cfg.ai.cooldown_on_fail_sec || 120;
                document.getElementById('ai_timeout').value = cfg.ai.timeout || 20;
                document.getElementById('ai_temp').value = cfg.ai.temperature ?? 0.2;
                document.getElementById('ai_prompt').value = cfg.ai.system_prompt;
                window.selectedTemplateId = cfg.ai.template_id || 'trend_following';
                renderTemplates();
                renderPresets();
                window.currentPool = cfg.ai_pool || [];
                renderAiNodes(window.currentPool);

                if (cfg.risk) {
                    document.getElementById('r_min').value = cfg.risk.min_order_usdt;
                    document.getElementById('r_max').value = cfg.risk.max_order_usdt;
                    document.getElementById('r_pos').value = cfg.risk.max_position_pct;
                    document.getElementById('r_sl').value = cfg.risk.stop_loss_pct;
                    document.getElementById('r_tp').value = cfg.risk.take_profit_pct;
                    document.getElementById('r_trail').value = cfg.risk.trailing_stop_pct ?? 3.0;
                    document.getElementById('r_daily_loss').value = cfg.risk.daily_max_loss_usdt ?? 300;
                    document.getElementById('r_cd').value = cfg.risk.cooldown_sec;
                    document.getElementById('r_init').value = cfg.risk.paper_initial_usdt;
                }
                if (cfg.notify) {
                    document.getElementById('n_enabled').value = String(cfg.notify.enabled);
                    document.getElementById('n_tg_token').value = cfg.notify.telegram_bot_token || '';
                    document.getElementById('n_tg_chat').value = cfg.notify.telegram_chat_id || '';
                    document.getElementById('n_webhook').value = cfg.notify.webhook_url || '';
                    document.getElementById('n_trade').value = String(cfg.notify.notify_on_trade);
                    document.getElementById('n_err').value = String(cfg.notify.notify_on_error);
                }
                if (cfg.auth) {
                    document.getElementById('auth_enabled').value = String(cfg.auth.enabled);
                    document.getElementById('auth_user').value = cfg.auth.username;
                    document.getElementById('auth_pass').value = cfg.auth.password;
                }
                loadNativeChart();
                initialized = true;
            }

            const badge = document.getElementById('modeBadge');
            badge.innerText = cfg.exchange.real_trade ? '🔥 实盘交易中' : '🧪 模拟演练盘';
            badge.className = cfg.exchange.real_trade ? 'badge badge-stop' : 'badge badge-run';
            document.getElementById('breakerBadge').style.display = pf.circuit_breaker_tripped ? 'inline-block' : 'none';

            document.getElementById('kpiEquity').innerText = `$${pf.total_equity}`;
            document.getElementById('kpiFree').innerText = `$${pf.usdt_free}`;
            const uEl = document.getElementById('kpiUnrealized');
            uEl.innerText = `${pf.unrealized_pnl >= 0 ? '+' : ''}${pf.unrealized_pnl} U`;
            uEl.style.color = pf.unrealized_pnl >= 0 ? 'var(--green)' : 'var(--red)';
            const tEl = document.getElementById('kpiToday');
            tEl.innerText = `${pf.today_pnl >= 0 ? '+' : ''}${pf.today_pnl} U`;
            tEl.style.color = pf.today_pnl >= 0 ? 'var(--green)' : 'var(--red)';
            const rEl = document.getElementById('kpiRealized');
            rEl.innerText = `${pf.total_realized_pnl >= 0 ? '+' : ''}${pf.total_realized_pnl} U`;
            rEl.style.color = pf.total_realized_pnl >= 0 ? 'var(--green)' : 'var(--red)';
            document.getElementById('kpiWinRate').innerText = `${pf.win_rate}% / ${pf.total_trades}笔`;

            document.getElementById('positionsBody').innerHTML = (pf.positions || []).length ? pf.positions.map(p => `
                <tr>
                    <td><strong>${esc(p.symbol)}</strong></td>
                    <td>${p.qty}</td>
                    <td>$${p.avg_entry}</td>
                    <td>$${p.current_price}</td>
                    <td>$${p.value_usdt}</td>
                    <td style="color:${p.unrealized_pnl >= 0 ? 'var(--green)' : 'var(--red)'}">${p.unrealized_pnl >= 0 ? '+' : ''}${p.unrealized_pnl}U (${p.unrealized_pnl_pct}%)</td>
                </tr>
            `).join('') : '<tr><td colspan="6" style="color:var(--muted);">暂无持仓</td></tr>';

            const activeEl = document.activeElement;
            const isEditingSelect = activeEl && activeEl.tagName === 'SELECT' && activeEl.closest('#taskTableBody');
            if (!isEditingSelect) {
                document.getElementById('taskTableBody').innerHTML = cfg.tasks.map(t => {
                    const m = rt.task_metrics[t.id] || { current_price: '-', change_24h: 0, rsi14: '-', trend: '-', ai_status: '等待中' };
                    const isRun = t.active;
                    const changeColor = m.change_24h >= 0 ? '#10b981' : '#ef4444';
                    return `
                        <tr>
                            <td><strong style="cursor:pointer; text-decoration:underline; color:#60a5fa;" onclick="selectSymbolChart('${esc(t.symbol)}')">${esc(t.symbol)}</strong><br><span style="font-size:11px;color:var(--muted)">${esc(t.timeframe || '15m')} / ${t.interval}s</span></td>
                            <td>$${m.current_price} <span style="color:${changeColor}">(${m.change_24h}%)</span></td>
                            <td style="font-size:12px;">RSI: ${m.rsi14 ?? '-'}<br><span style="color:var(--muted)">${esc(m.trend)}</span></td>
                            <td style="min-width:170px;">
                                ${templateSelectHtml(t.id, t.template_id || 'global')}
                                <div style="margin-top:4px; font-size:11px; color:var(--muted);">${esc(t.custom_instruction || '无额外指令')} <a href="javascript:void(0)" style="color:#60a5fa;" onclick="editTaskInstruction('${esc(t.id)}', '${esc(t.custom_instruction || '')}')">[编辑]</a></div>
                            </td>
                            <td style="font-size:12px; color:#34d399; max-width:260px;">${esc(m.ai_status)}</td>
                            <td><span class="badge ${isRun ? 'badge-run' : 'badge-stop'}">${isRun ? '运行中' : '已停止'}</span></td>
                            <td style="white-space:nowrap;">
                                <button class="btn btn-sm ${isRun ? 'btn-red' : 'btn-green'}" onclick="toggleTask('${esc(t.id)}')">${isRun ? '停止' : '启动'}</button>
                                <button class="btn btn-sm btn-amber" onclick="runTaskOnce('${esc(t.id)}')" title="立即执行一次AI决策并自主下单">⚡ 决策</button>
                                <button class="btn btn-sm btn-slate" onclick="deleteTask('${esc(t.id)}')">删除</button>
                            </td>
                        </tr>
                    `;
                }).join('');
            }

            document.getElementById('logBox').innerHTML = rt.logs.map(l => esc(l)).join('<br>');
        } catch (e) { console.error(e); }
    }

    async function loadTrades() {
        const res = await fetch('/api/trades?limit=50');
        if (!res.ok) return;
        const json = await res.json();
        document.getElementById('tradesBody').innerHTML = (json.trades || []).map(tr => `
            <tr>
                <td>${esc(tr.created_at)}</td>
                <td><strong>${esc(tr.symbol)}</strong></td>
                <td style="color:${tr.side === 'buy' ? 'var(--green)' : 'var(--red)'}; font-weight:bold;">${esc(tr.side.toUpperCase())}</td>
                <td>$${Number(tr.price).toFixed(4)}</td>
                <td>$${Number(tr.usdt_value).toFixed(2)}</td>
                <td style="color:${tr.pnl_usdt >= 0 ? 'var(--green)' : 'var(--red)'}">${tr.side === 'sell' ? (tr.pnl_usdt >= 0 ? '+' : '') + Number(tr.pnl_usdt).toFixed(2) + 'U' : '-'}</td>
                <td>${esc(tr.source)} / ${esc(tr.provider)}</td>
                <td style="max-width:260px; font-size:12px; color:var(--muted);">${esc(tr.reason)}</td>
            </tr>
        `).join('');

        const container = document.getElementById('pnl_chart_container');
        if (container && typeof LightweightCharts !== 'undefined') {
            if (!pnlChartInstance) {
                pnlChartInstance = LightweightCharts.createChart(container, {
                    width: container.clientWidth,
                    height: 220,
                    layout: { background: { color: '#070a11' }, textColor: '#94a3b8' },
                    grid: { vertLines: { color: '#1e293b' }, horzLines: { color: '#1e293b' } },
                    timeScale: { timeVisible: true, borderColor: '#263147' },
                    rightPriceScale: { borderColor: '#263147' },
                });
                pnlAreaSeries = pnlChartInstance.addAreaSeries({
                    lineColor: '#10b981',
                    topColor: 'rgba(16, 185, 129, 0.35)',
                    bottomColor: 'rgba(16, 185, 129, 0.02)',
                });
            } else {
                pnlChartInstance.applyOptions({ width: container.clientWidth });
            }
            if (json.pnl_series && json.pnl_series.length > 0) {
                pnlAreaSeries.setData(json.pnl_series);
                pnlChartInstance.timeScale().fitContent();
            }
        }
    }

    async function postJson(url, payload, okMsg) {
        const res = await fetch(url, { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(payload) });
        if (res.ok) { showToast(okMsg); refreshState(); }
        else { const err = await res.json(); showToast('❌ 失败: ' + (err.detail || '未知错误')); }
    }

    function saveExchange() {
        postJson('/api/config/exchange', {
            name: document.getElementById('ex_name').value,
            api_key: document.getElementById('ex_key').value,
            secret_key: document.getElementById('ex_secret').value,
            password: document.getElementById('ex_pass').value,
            sandbox: document.getElementById('ex_sandbox').value === 'true',
            real_trade: document.getElementById('ex_real').value === 'true'
        }, '✅ 交易所配置已保存');
    }

    function saveAIPool() {
        syncPoolFromDom();
        postJson('/api/config/ai_pool', {
            enabled: document.getElementById('ai_enabled').value === 'true',
            rotation_mode: document.getElementById('ai_rotation').value,
            consensus_count: parseInt(document.getElementById('ai_consensus').value || 1),
            cooldown_on_fail_sec: parseInt(document.getElementById('ai_cooldown').value || 120),
            template_id: window.selectedTemplateId || 'trend_following',
            timeout: parseInt(document.getElementById('ai_timeout').value || 20),
            temperature: parseFloat(document.getElementById('ai_temp').value || 0.2),
            system_prompt: document.getElementById('ai_prompt').value,
            pool: window.currentPool
        }, '✅ AI 模版与全兼容轮替池已保存');
    }

    function saveRisk() {
        postJson('/api/config/risk', {
            min_order_usdt: parseFloat(document.getElementById('r_min').value),
            max_order_usdt: parseFloat(document.getElementById('r_max').value),
            max_position_pct: parseFloat(document.getElementById('r_pos').value),
            stop_loss_pct: parseFloat(document.getElementById('r_sl').value),
            take_profit_pct: parseFloat(document.getElementById('r_tp').value),
            trailing_stop_pct: parseFloat(document.getElementById('r_trail').value || 0),
            daily_max_loss_usdt: parseFloat(document.getElementById('r_daily_loss').value || 0),
            cooldown_sec: parseInt(document.getElementById('r_cd').value),
            paper_initial_usdt: parseFloat(document.getElementById('r_init').value)
        }, '✅ 风控参数已保存');
    }

    function saveNotify() {
        postJson('/api/config/notify', {
            enabled: document.getElementById('n_enabled').value === 'true',
            telegram_bot_token: document.getElementById('n_tg_token').value,
            telegram_chat_id: document.getElementById('n_tg_chat').value,
            webhook_url: document.getElementById('n_webhook').value,
            notify_on_trade: document.getElementById('n_trade').value === 'true',
            notify_on_error: document.getElementById('n_err').value === 'true'
        }, '✅ 推送配置已保存');
    }

    function testNotify() { postJson('/api/notify/test', {}, '📨 测试通知已发送'); }
    function saveAuth() {
        postJson('/api/config/auth', {
            enabled: document.getElementById('auth_enabled').value === 'true',
            username: document.getElementById('auth_user').value,
            password: document.getElementById('auth_pass').value
        }, '✅ 安全设置已保存');
    }
    function addTask() {
        postJson('/api/tasks', {
            symbol: document.getElementById('t_symbol').value,
            timeframe: document.getElementById('t_timeframe').value,
            interval: parseInt(document.getElementById('t_interval').value || 30),
            template_id: document.getElementById('t_template').value,
            custom_instruction: document.getElementById('t_custom').value
        }, '✅ 任务已添加');
    }
    async function toggleTask(id) { await fetch(`/api/tasks/${id}/toggle`, { method: 'POST' }); refreshState(); }
    async function deleteTask(id) { if (confirm('确定删除该任务？')) { await fetch(`/api/tasks/${id}`, { method: 'DELETE' }); refreshState(); } }
    function emergencyStop() { if (confirm('确定紧急停止所有运行中的任务？')) postJson('/api/tasks/emergency_stop', {}, '🚨 已全部停止'); }
    function resetPaper() { if (confirm('确定重置模拟盘资金并清空当前模拟持仓？')) postJson('/api/paper/reset', {}, '🔄 模拟盘已重置'); }
    function manualTrade(side) {
        postJson('/api/trade/manual', {
            symbol: document.getElementById('m_symbol').value,
            side: side,
            usdt_amount: parseFloat(document.getElementById('m_amount').value)
        }, `✅ ${side.toUpperCase()} 下单指令已提交`);
    }

    setInterval(refreshState, 2000);
    setInterval(loadNativeChart, 15000);
    refreshState();
</script>
</body>
</html>
"""


if __name__ == "__main__":
    with config_lock:
        active_tasks = [t["id"] for t in app_config["tasks"] if t.get("active")]
    for tid in active_tasks:
        engine.start_task(tid)
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8000")))

INNER_EOF

python3 -m venv "${VENV_DIR}"
"${VENV_DIR}/bin/pip" install --upgrade pip --no-cache-dir
"${VENV_DIR}/bin/pip" install --no-cache-dir fastapi uvicorn ccxt openai pydantic pandas requests

echo "=== [3/4] 配置防火墙与 Systemd 守护进程 ==="
if command -v ufw >/dev/null 2>&1; then
    ufw allow "${PORT}/tcp" || true
fi

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    cat << EOF > "/etc/systemd/system/${SERVICE_NAME}.service"
[Unit]
Description=AI Quant Pro v4.0 Service
After=network.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
Environment="PORT=${PORT}"
ExecStart=${VENV_DIR}/bin/python ${APP_DIR}/ai_quant_pro.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}"
    systemctl restart "${SERVICE_NAME}"
    echo "=== [4/4] 服务状态检查 ==="
    systemctl status "${SERVICE_NAME}" --no-pager -l || true
else
    echo "=== [4/4] 未检测到 systemd，使用 nohup 后台启动 ==="
    pkill -f "${APP_DIR}/ai_quant_pro.py" || true
    cd "${APP_DIR}"
    nohup "${VENV_DIR}/bin/python" "${APP_DIR}/ai_quant_pro.py" > "${APP_DIR}/bot.log" 2>&1 &
fi

PUBLIC_IP=$(curl -s --max-time 5 https://ifconfig.me || echo "YOUR_SERVER_IP")
echo "🎉 部署完成！访问地址: http://${PUBLIC_IP}:${PORT}"
echo "默认登录账号: admin | 默认密码: adminpassword888（请登录后第一时间修改）"
#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import subprocess
import sys

print("==================================================")
print(" Matrix 自动化综合操盘系统 - 终极整合版部署脚本 ")
print("==================================================")

BASE_DIR = "/opt/auto_browser_system"
VENV_DIR = os.path.join(BASE_DIR, "venv")
VENV_PY = os.path.join(VENV_DIR, "bin", "python")

print("[1/5] 正在安装系统依赖 (含 Tor)、创建独立 Python 虚拟环境...")
os.makedirs(os.path.join(BASE_DIR, "templates"), exist_ok=True)
try:
    subprocess.run(["apt-get", "update"], check=False)
    subprocess.run(["apt-get", "install", "-y", "python3-pip", "python3-venv", "tor"], check=True)
except Exception as e:
    print(f"⚠️ apt 安装提示: {e} (非 Debian/Ubuntu 系统请手动安装 python3-venv 与 tor)")

if not os.path.exists(VENV_PY):
    subprocess.run([sys.executable, "-m", "venv", VENV_DIR], check=True)

subprocess.run([VENV_PY, "-m", "pip", "install", "--upgrade", "pip"], check=True)
subprocess.run([VENV_PY, "-m", "pip", "install", "flask", "requests", "playwright", "pysocks"], check=True)

print("[2/5] 正在安装 Playwright 浏览器内核及系统底层依赖...")
try:
    subprocess.run([VENV_PY, "-m", "playwright", "install", "chromium"], check=True)
    subprocess.run([VENV_PY, "-m", "playwright", "install-deps", "chromium"], check=True)
except Exception as e:
    print(f"⚠️ 自动安装浏览器依赖提示: {e}")

print("[3/5] 正在写入后端控制核心 (app.py)...")
app_code = r'''# -*- coding: utf-8 -*-
import json
import os
import random
import re
import secrets
import threading
import time
from functools import wraps
from urllib.parse import urlparse

import requests
from flask import Flask, Response, jsonify, redirect, render_template, request, session, url_for
from playwright.sync_api import sync_playwright

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = os.path.join(BASE_DIR, "config.json")

app = Flask(__name__, template_folder="templates")
app.secret_key = os.environ.get("MATRIX_SECRET_KEY", secrets.token_hex(24))
WEB_PASSWORD = os.environ.get("MATRIX_WEB_PASSWORD", "admin888")

status_lock = threading.Lock()
screenshot_lock = threading.Lock()
latest_screenshot = None

stop_event = threading.Event()
worker_thread = None

DEFAULT_STATUS = {
    "is_running": False,
    "target_urls": "https://example.com",
    "stay_min": 8,
    "stay_max": 20,
    "watch_time": 60,
    "interval_min": 4,
    "interval_max": 8,
    "max_runs": 0,
    "inner_page_prob": 75,
    "max_inner_pages": 2,
    "device_mode": "mixed",
    "play_video": False,
    "referer": "",
    "random_browse": True,
    "human_mouse": True,
    "use_tor": False,
    "strict_proxy": False,
    "consume_proxy": False,
    "proxy_api": "",
    "proxy_pool": [],
    "click_selector": "",
    "sub_click_selector": "",
    "block_ads": True,
    "current_node": "待命",
    "stats": {"total": 0, "success": 0, "failed": 0},
    "logs": ["[系统提示] 矩阵综合操盘主板已初始化（终极整合版），等待下达指令..."]
}

STATUS = json.loads(json.dumps(DEFAULT_STATUS))

DESKTOP_PROFILES = [
    {"name": "Win10_Chrome_1080P", "type": "desktop", "ua": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36", "w": 1920, "h": 1080, "touch": False, "scale": 1},
    {"name": "Win11_Edge_Laptop", "type": "desktop", "ua": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36 Edg/122.0.0.0", "w": 1366, "h": 768, "touch": False, "scale": 1},
    {"name": "MacOS_Safari_Retina", "type": "desktop", "ua": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.3 Safari/605.1.15", "w": 1440, "h": 900, "touch": False, "scale": 2},
    {"name": "MacOS_Chrome_2K", "type": "desktop", "ua": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36", "w": 2560, "h": 1440, "touch": False, "scale": 2},
    {"name": "Linux_Firefox_Desktop", "type": "desktop", "ua": "Mozilla/5.0 (X11; Linux x86_64; rv:123.0) Gecko/20100101 Firefox/123.0", "w": 1920, "h": 1080, "touch": False, "scale": 1}
]

MOBILE_PROFILES = [
    {"name": "iPhone15_iOS_Safari", "type": "mobile", "ua": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.3 Mobile/15E148 Safari/604.1", "w": 393, "h": 852, "touch": True, "scale": 3},
    {"name": "Android_Pixel8_Chrome", "type": "mobile", "ua": "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36", "w": 412, "h": 915, "touch": True, "scale": 2.6}
]

AD_BLOCK_KEYWORDS = [
    "googlesyndication", "doubleclick", "google-analytics",
    "analytics.js", "histats.com", "amung.us", "scorecardresearch"
]

PERSIST_KEYS = [
    "target_urls", "stay_min", "stay_max", "watch_time", "interval_min", "interval_max",
    "max_runs", "inner_page_prob", "max_inner_pages", "device_mode", "play_video",
    "referer", "random_browse", "human_mouse", "use_tor", "strict_proxy", "consume_proxy",
    "proxy_api", "proxy_pool", "click_selector", "sub_click_selector", "block_ads"
]


def load_config():
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                saved = json.load(f)
            with status_lock:
                for k in PERSIST_KEYS:
                    if k in saved:
                        STATUS[k] = saved[k]
        except Exception as e:
            add_log(f"⚠️ [配置读取失败] {str(e)[:40]}")


def save_config():
    try:
        with status_lock:
            data = {k: STATUS[k] for k in PERSIST_KEYS}
        with open(CONFIG_FILE, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
    except Exception as e:
        add_log(f"⚠️ [配置保存失败] {str(e)[:40]}")


def add_log(msg):
    with status_lock:
        STATUS["logs"].append(f"[{time.strftime('%H:%M:%S')}] {msg}")
        if len(STATUS["logs"]) > 200:
            STATUS["logs"].pop(0)


def safe_sleep(seconds):
    end_time = time.time() + max(0.0, float(seconds))
    while time.time() < end_time:
        if stop_event.is_set():
            break
        time.sleep(min(0.4, max(0.05, end_time - time.time())))


def capture_preview(page):
    global latest_screenshot
    try:
        img_bytes = page.screenshot(type="png")
        with screenshot_lock:
            latest_screenshot = img_bytes
    except Exception:
        pass


def choose_device_profile(mode):
    if mode == "desktop":
        return random.choice(DESKTOP_PROFILES)
    if mode == "mobile":
        return random.choice(MOBILE_PROFILES)
    return random.choice(DESKTOP_PROFILES + MOBILE_PROFILES)


def select_traffic_channel():
    with status_lock:
        ref = STATUS["referer"]
    if ref:
        return ref
    return random.choices(
        ["https://www.google.com", "https://www.bing.com", "https://www.baidu.com", "direct_access"],
        weights=[0.4, 0.2, 0.2, 0.2],
        k=1
    )[0]


def parse_and_scale_coord(selector_str, target_w, target_h, base_w=1920, base_h=1080):
    if selector_str.lower().startswith("coord"):
        coords = list(map(int, re.findall(r'\d+', selector_str)))
        if len(coords) == 2:
            orig_x, orig_y = coords
            scaled_x = max(1, min(target_w - 1, int((orig_x / base_w) * target_w)))
            scaled_y = max(1, min(target_h - 1, int((orig_y / base_h) * target_h)))
            return True, scaled_x, scaled_y
    return False, 0, 0


def parse_proxy(proxy_str):
    s = proxy_str.strip()
    scheme = "http"
    if "://" in s:
        scheme, s = s.split("://", 1)
        scheme = scheme.lower()
    username = None
    password = None
    if "@" in s:
        auth, server = s.rsplit("@", 1)
        if ":" in auth:
            username, password = auth.split(":", 1)
    else:
        server = s
    pw_proxy = {"server": f"{scheme}://{server}"}
    if username is not None and password is not None:
        pw_proxy["username"] = username
        pw_proxy["password"] = password
        req_url = f"{scheme}://{username}:{password}@{server}"
    else:
        req_url = f"{scheme}://{server}"
    return pw_proxy, {"http": req_url, "https": req_url}


def validate_single_proxy(cand):
    pw_proxy, req_proxies = parse_proxy(cand)
    res = requests.get("http://ip-api.com/json/?lang=zh-CN", proxies=req_proxies, timeout=5)
    if res.status_code == 200:
        data = res.json()
        return True, pw_proxy, data.get("country", "未知国家")
    return False, None, None


def simulate_human_browsing(page, profile, stay_seconds, do_scroll=True, do_mouse=True):
    add_log(f"🧑 [拟人浏览] 计划停留 {stay_seconds} 秒 (滚动:{do_scroll} | 轨迹:{do_mouse})")
    start_ts = time.time()
    vw, vh = profile["w"], profile["h"]
    while time.time() - start_ts < stay_seconds and not stop_event.is_set():
        remaining = stay_seconds - (time.time() - start_ts)
        if remaining <= 0.5:
            break
        if do_scroll:
            try:
                scroll_info = page.evaluate("""() => ({
                    scrollY: window.scrollY,
                    scrollHeight: document.body.scrollHeight,
                    innerHeight: window.innerHeight
                })""")
                max_y = max(0, scroll_info["scrollHeight"] - scroll_info["innerHeight"])
                cur_y = scroll_info["scrollY"]
                if max_y > 100:
                    if cur_y > 300 and random.random() < 0.22:
                        delta = -random.randint(120, min(350, int(cur_y)))
                    elif cur_y >= max_y - 50:
                        delta = -random.randint(200, min(500, int(cur_y)))
                    else:
                        delta = random.randint(180, max(250, int(vh * 0.65)))
                    page.evaluate(f"window.scrollBy({{top: {delta}, behavior: 'smooth'}})")
            except Exception:
                pass
        if do_mouse and not profile.get("touch", False):
            try:
                if random.random() < 0.35:
                    el = page.evaluate("""() => {
                        const els = Array.from(document.querySelectorAll('a, h1, h2, h3, p, button'));
                        const visible = els.filter(e => {
                            const r = e.getBoundingClientRect();
                            return r.width > 20 && r.height > 10 && r.top >= 20 && r.bottom <= window.innerHeight - 20;
                        });
                        if (!visible.length) return null;
                        const pick = visible[Math.floor(Math.random() * visible.length)];
                        const r = pick.getBoundingClientRect();
                        return {x: r.left + r.width / 2, y: r.top + r.height / 2};
                    }""")
                    if el:
                        page.mouse.move(el["x"], el["y"], steps=random.randint(8, 18))
                else:
                    tx = random.randint(int(vw * 0.1), int(vw * 0.9))
                    ty = random.randint(int(vh * 0.1), int(vh * 0.85))
                    page.mouse.move(tx, ty, steps=random.randint(6, 15))
            except Exception:
                pass
        safe_sleep(min(remaining, random.uniform(1.8, 4.2)))
    capture_preview(page)


def perform_click(page, context, selector_str, profile, step_label="一级点击"):
    is_coord, cx, cy = parse_and_scale_coord(selector_str, profile["w"], profile["h"])
    try:
        with context.expect_page(timeout=8000) as popup_info:
            if is_coord:
                add_log(f"🖱️ [{step_label}] 移动并点击坐标 -> X:{cx}, Y:{cy}")
                page.mouse.move(cx, cy, steps=random.randint(8, 15))
                safe_sleep(random.uniform(0.2, 0.5))
                page.mouse.click(cx, cy)
            else:
                add_log(f"🖱️ [{step_label}] 点击选择器 -> [{selector_str}]")
                page.click(selector_str, timeout=10000)
        popup_page = popup_info.value
        add_log(f"🪟 [新标签捕获] 打开页面 -> {popup_page.url[:60]}")
        try:
            popup_page.wait_for_load_state("domcontentloaded", timeout=20000)
        except Exception:
            pass
        capture_preview(popup_page)
        return popup_page
    except Exception:
        add_log(f"ℹ️ [{step_label}] 当前页内继续流转")
        try:
            page.wait_for_load_state("domcontentloaded", timeout=10000)
        except Exception:
            pass
        capture_preview(page)
        return page


def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if not session.get("logged_in"):
            if request.is_json or request.path not in ("/",):
                return jsonify({"status": "unauthorized"}), 401
            return redirect(url_for("login"))
        return f(*args, **kwargs)
    return decorated


def automation_worker():
    add_log("🚀 [引擎启动] 操盘核心已开启拟人化运转...")
    run_counter = 0
    api_rotator_idx = 0
    try:
        while not stop_event.is_set():
            with status_lock:
                raw_urls = STATUS["target_urls"]
                url_list = [u.strip() for u in raw_urls.splitlines() if u.strip()]
                stay_min = max(2, int(STATUS["stay_min"]))
                stay_max = max(stay_min, int(STATUS["stay_max"]))
                watch_time = max(5, int(STATUS["watch_time"]))
                interval_min = max(1, int(STATUS["interval_min"]))
                interval_max = max(interval_min, int(STATUS["interval_max"]))
                max_runs = max(0, int(STATUS["max_runs"]))
                inner_prob = max(0, min(100, int(STATUS["inner_page_prob"])))
                max_inner = max(0, int(STATUS["max_inner_pages"]))
                device_mode = STATUS["device_mode"]
                use_tor = STATUS["use_tor"]
                strict_proxy = STATUS["strict_proxy"]
                consume_proxy = STATUS.get("consume_proxy", False)
                proxy_api = STATUS["proxy_api"]
                proxy_pool = list(STATUS["proxy_pool"])
                block_ads = STATUS["block_ads"]
                click_selector = STATUS["click_selector"]
                sub_click_selector = STATUS["sub_click_selector"]
                random_browse = STATUS["random_browse"]
                human_mouse = STATUS["human_mouse"]
                play_video = STATUS["play_video"]

            if max_runs > 0 and run_counter >= max_runs:
                add_log(f"🏁 [任务达标] 已完成设定的 {max_runs} 轮任务，自动停机。")
                break
            if not url_list:
                add_log("⚠️ [等待配置] 目标 URL 列表为空，休眠 5 秒...")
                safe_sleep(5)
                continue

            target_url = random.choice(url_list)
            if not target_url.startswith(("http://", "https://")):
                target_url = "https://" + target_url

            proxy_config = None
            current_node = "本机主线直连"
            proxy_ready = True
            if use_tor:
                proxy_config = {"server": "socks5://127.0.0.1:9050"}
                current_node = "Tor 匿名中继通道"
            else:
                api_list = [u.strip() for u in proxy_api.splitlines() if u.strip()]
                if api_list and len(proxy_pool) < 3:
                    for _ in range(len(api_list)):
                        cur_api = api_list[api_rotator_idx % len(api_list)]
                        api_rotator_idx += 1
                        try:
                            add_log(f"🔄 [API轮替] 从第 {(api_rotator_idx - 1) % len(api_list) + 1}/{len(api_list)} 个接口拉取...")
                            res = requests.get(cur_api, timeout=8)
                            if res.status_code == 200:
                                fetched = [line.strip() for line in res.text.splitlines() if line.strip()]
                                added = 0
                                with status_lock:
                                    for ip in fetched:
                                        if ip not in STATUS["proxy_pool"]:
                                            STATUS["proxy_pool"].append(ip)
                                            added += 1
                                    proxy_pool = list(STATUS["proxy_pool"])
                                add_log(f"📥 [API接口] 成功注入 {added} 个代理节点。")
                                if added > 0:
                                    break
                        except Exception as api_err:
                            add_log(f"⚠️ [API警告] 接口异常，轮替下一个: {str(api_err)[:35]}")

                retry_loop = 0
                found_proxy = False
                while retry_loop < 5 and proxy_pool and not stop_event.is_set():
                    cand = random.choice(proxy_pool)
                    add_log(f"🔍 [节点测速] 验证链路: {cand}")
                    try:
                        ok, pw_cfg, country = validate_single_proxy(cand)
                        if ok:
                            proxy_config = pw_cfg
                            current_node = f"{cand} [{country}]"
                            add_log(f"✅ [链路健康] 锁定可用节点: {country}")
                            found_proxy = True
                            if consume_proxy:
                                with status_lock:
                                    if cand in STATUS["proxy_pool"]:
                                        STATUS["proxy_pool"].remove(cand)
                            break
                        raise Exception("Bad Status")
                    except Exception:
                        add_log(f"❌ [死节点清洗] 剥离失效代理 -> {cand}")
                        with status_lock:
                            if cand in STATUS["proxy_pool"]:
                                STATUS["proxy_pool"].remove(cand)
                            proxy_pool = list(STATUS["proxy_pool"])
                        retry_loop += 1

                if not found_proxy and strict_proxy:
                    proxy_ready = False
                    add_log("🛡️ [严格代理拦截] 无可用代理节点，跳过本轮。")

            if not proxy_ready:
                safe_sleep(5)
                continue

            run_counter += 1
            with status_lock:
                STATUS["current_node"] = current_node
                STATUS["stats"]["total"] += 1

            profile = choose_device_profile(device_mode)
            add_log(f"🌐 [第 {run_counter} 轮] 通道: {current_node} | 🎭 指纹: {profile['name']}")
            browser = None
            cycle_ok = False
            try:
                with sync_playwright() as p:
                    browser = p.chromium.launch(
                        headless=True, proxy=proxy_config,
                        args=["--no-sandbox", "--disable-setuid-sandbox", "--disable-dev-shm-usage", "--disable-gpu", "--disable-blink-features=AutomationControlled"]
                    )
                    context = browser.new_context(
                        viewport={"width": profile["w"], "height": profile["h"]},
                        user_agent=profile["ua"],
                        has_touch=profile.get("touch", False),
                        device_scale_factor=profile.get("scale", 1)
                    )
                    page = context.new_page()
                    page.set_default_timeout(25000)

                    if block_ads:
                        target_netloc = urlparse(target_url).netloc.lower()
                        def handle_route(route):
                            try:
                                req_url = route.request.url.lower()
                                if target_netloc and target_netloc in req_url:
                                    route.continue_()
                                elif any(kw in req_url for kw in AD_BLOCK_KEYWORDS):
                                    route.abort()
                                else:
                                    route.continue_()
                            except Exception:
                                pass
                        page.route("**/*", handle_route)

                    add_log(f"🎯 [访问入口] 加载 Page A: {target_url}")
                    traffic_referer = select_traffic_channel()
                    if traffic_referer and traffic_referer != "direct_access":
                        page.goto(target_url, referer=traffic_referer, wait_until="domcontentloaded", timeout=45000)
                    else:
                        page.goto(target_url, wait_until="domcontentloaded", timeout=45000)
                    try:
                        page.wait_for_load_state("networkidle", timeout=8000)
                    except Exception:
                        pass
                    safe_sleep(2.0)
                    capture_preview(page)

                    main_stay = random.randint(stay_min, stay_max)
                    simulate_human_browsing(page, profile, main_stay, do_scroll=random_browse, do_mouse=human_mouse)

                    active_click_page = page
                    if max_inner > 0 and random.randint(1, 100) <= inner_prob and not stop_event.is_set():
                        pages_to_visit = random.randint(1, max_inner)
                        main_domain = urlparse(target_url).netloc
                        visited = {target_url.rstrip("/")}
                        for idx in range(pages_to_visit):
                            if stop_event.is_set():
                                break
                            try:
                                all_links = page.evaluate("Array.from(document.querySelectorAll('a')).map(a => a.href)")
                                internal_links = [
                                    l for l in all_links
                                    if l and l.startswith("http") and urlparse(l).netloc == main_domain
                                    and l.rstrip("/") not in visited and not l.rstrip("/").endswith("index.html")
                                ]
                                if internal_links:
                                    chosen_inner = random.choice(internal_links)
                                    visited.add(chosen_inner.rstrip("/"))
                                    add_log(f"🔗 [深度游览 {idx+1}/{pages_to_visit}] -> {chosen_inner[:60]}")
                                    page.goto(chosen_inner, wait_until="domcontentloaded", timeout=35000)
                                    safe_sleep(1.5)
                                else:
                                    candidates = page.locator("main div.cursor-pointer, .grid .cursor-pointer")
                                    cnt = candidates.count()
                                    if cnt == 0:
                                        candidates = page.locator("main button:not([disabled])")
                                        cnt = candidates.count()
                                    if cnt == 0:
                                        break
                                    pick_idx = random.randint(0, min(cnt - 1, 20))
                                    target_el = candidates.nth(pick_idx)
                                    target_el.scroll_into_view_if_needed(timeout=5000)
                                    safe_sleep(random.uniform(0.4, 1.0))
                                    add_log(f"🖱️ [JS内页点击 {idx+1}/{pages_to_visit}] 触发卡片/按钮跳转 (第 {pick_idx+1} 项)")
                                    target_el.click(timeout=8000)
                                    try:
                                        page.wait_for_load_state("domcontentloaded", timeout=15000)
                                    except Exception:
                                        pass
                                    safe_sleep(2.0)

                                capture_preview(page)
                                inner_stay = random.randint(max(3, stay_min // 2), max(5, stay_max // 2))
                                simulate_human_browsing(page, profile, inner_stay, do_scroll=random_browse, do_mouse=human_mouse)
                            except Exception:
                                break

                    if click_selector and not stop_event.is_set():
                        active_page = perform_click(active_click_page, context, click_selector, profile, "一级点击")
                        simulate_human_browsing(active_page, profile, random.randint(4, 8), do_scroll=random_browse, do_mouse=human_mouse)
                        if sub_click_selector and not stop_event.is_set():
                            sub_page = perform_click(active_page, context, sub_click_selector, profile, "二级点击")
                            safe_sleep(random.uniform(2.0, 4.0))
                            capture_preview(sub_page)

                    if play_video and not stop_event.is_set():
                        actual_watch = random.randint(min(10, watch_time), watch_time)
                        add_log(f"🎬 [媒体停留] 模拟观看 {actual_watch} 秒...")
                        safe_sleep(actual_watch)
                    cycle_ok = True
            except Exception as e:
                add_log(f"💥 [引擎报错] {str(e)[:60]}")
            finally:
                if browser:
                    try:
                        browser.close()
                    except Exception:
                        pass

            with status_lock:
                if cycle_ok:
                    STATUS["stats"]["success"] += 1
                else:
                    STATUS["stats"]["failed"] += 1

            if not stop_event.is_set() and (max_runs == 0 or run_counter < max_runs):
                cool_down = random.randint(interval_min, interval_max)
                add_log(f"⏳ [周期冷却] 等待 {cool_down} 秒后开启下一轮...")
                safe_sleep(cool_down)
    finally:
        with status_lock:
            STATUS["is_running"] = False
            STATUS["current_node"] = "待命"
        add_log("🛑 [引擎停止] 系统已安全冷备。")


@app.route("/")
@login_required
def index():
    with status_lock:
        cfg = {k: STATUS[k] for k in PERSIST_KEYS if k != "proxy_pool"}
    return render_template("index.html", cfg=cfg)


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        if request.form.get("password") == WEB_PASSWORD:
            session["logged_in"] = True
            return redirect(url_for("index"))
        return render_template("login.html", error="❌ 密码鉴权失败，请重试！")
    return render_template("login.html", error=None)


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


@app.route("/status")
@login_required
def status():
    with status_lock:
        return jsonify({
            "is_running": STATUS["is_running"],
            "logs": list(STATUS["logs"]),
            "pool_count": len(STATUS["proxy_pool"]),
            "current_node": STATUS["current_node"],
            "stats": dict(STATUS["stats"])
        })


@app.route("/screenshot")
@login_required
def screenshot():
    with screenshot_lock:
        img = latest_screenshot
    if not img:
        return Response(b"", status=204)
    return Response(img, mimetype="image/png")


@app.route("/control", methods=["POST"])
@login_required
def control():
    global worker_thread
    d = request.form

    def safe_int(val, default):
        try:
            return int(val) if val else default
        except Exception:
            return default

    with status_lock:
        STATUS.update({
            "target_urls": d.get("urls", "").strip(),
            "stay_min": safe_int(d.get("stay_min"), 8),
            "stay_max": safe_int(d.get("stay_max"), 20),
            "watch_time": safe_int(d.get("watch_time"), 60),
            "interval_min": safe_int(d.get("interval_min"), 4),
            "interval_max": safe_int(d.get("interval_max"), 8),
            "max_runs": safe_int(d.get("max_runs"), 0),
            "inner_page_prob": safe_int(d.get("inner_page_prob"), 75),
            "max_inner_pages": safe_int(d.get("max_inner_pages"), 2),
            "device_mode": d.get("device_mode", "mixed"),
            "use_tor": d.get("tor") == "true",
            "strict_proxy": d.get("strict_proxy") == "true",
            "consume_proxy": d.get("consume_proxy") == "true",
            "play_video": d.get("vid") == "true",
            "click_selector": d.get("click_selector", "").strip(),
            "sub_click_selector": d.get("sub_click_selector", "").strip(),
            "referer": d.get("referer", "").strip(),
            "proxy_api": d.get("api", "").strip(),
            "random_browse": d.get("browse") == "true",
            "human_mouse": d.get("human_mouse") == "true",
            "block_ads": d.get("block_ads") == "true"
        })
    save_config()

    action = d.get("action")
    if action == "start":
        if worker_thread is None or not worker_thread.is_alive():
            stop_event.clear()
            with status_lock:
                STATUS["is_running"] = True
            worker_thread = threading.Thread(target=automation_worker, name="matrix_bot_worker", daemon=True)
            worker_thread.start()
        else:
            add_log("ℹ️ [引擎提示] 引擎已在运转中，新配置将在下一轮生效。")
    elif action == "stop":
        stop_event.set()
        with status_lock:
            STATUS["is_running"] = False
        add_log("⏸️ [停机指令] 已发送停机信号，等待当前步骤安全退出...")
    return jsonify({"status": "ok"})


@app.route("/inject_ips", methods=["POST"])
@login_required
def inject_ips():
    paste_ips = request.form.get("ips", "")
    added = 0
    if paste_ips:
        with status_lock:
            for line in paste_ips.splitlines():
                line = line.strip()
                if line and line not in STATUS["proxy_pool"]:
                    STATUS["proxy_pool"].append(line)
                    added += 1
        save_config()
        add_log(f"📥 [手动注入] 新增 {added} 个代理节点。")
    return jsonify({"status": "success", "added": added})


@app.route("/check_proxies", methods=["POST"])
@login_required
def check_proxies():
    def _runner():
        with status_lock:
            pool = list(STATUS["proxy_pool"])
        if not pool:
            add_log("ℹ️ [测速清洗] 当前代理池为空。")
            return
        add_log(f"🔍 [测速清洗] 开始批量检测 {len(pool)} 个节点...")
        alive = []
        for cand in pool:
            try:
                ok, _, _ = validate_single_proxy(cand)
                if ok:
                    alive.append(cand)
            except Exception:
                pass
        with status_lock:
            STATUS["proxy_pool"] = alive
        save_config()
        add_log(f"✅ [测速完成] 保留有效节点 {len(alive)}/{len(pool)} 个。")
    threading.Thread(target=_runner, daemon=True).start()
    return jsonify({"status": "started", "msg": "后台已开始批量测速清洗，请查看日志输出"})


@app.route("/export_proxies")
@login_required
def export_proxies():
    with status_lock:
        content = "\n".join(STATUS["proxy_pool"])
    return Response(content, mimetype="text/plain", headers={"Content-Disposition": "attachment; filename=alive_proxies.txt"})


@app.route("/clear_ips", methods=["POST"])
@login_required
def clear_ips():
    with status_lock:
        STATUS["proxy_pool"] = []
    save_config()
    add_log("🧹 [资源池] 已完全清空代理池。")
    return jsonify({"status": "success"})


@app.route("/clear_logs", methods=["POST"])
@login_required
def clear_logs():
    with status_lock:
        STATUS["logs"] = [f"[{time.strftime('%H:%M:%S')}] [系统提示] 日志已清空。"]
    return jsonify({"status": "success"})


@app.route("/upload_txt", methods=["POST"])
@login_required
def upload_txt():
    if "file" not in request.files:
        return jsonify({"status": "failed", "msg": "未找到上传文件"})
    try:
        content = request.files["file"].read().decode("utf-8", errors="ignore")
        count = 0
        with status_lock:
            for line in content.splitlines():
                line = line.strip()
                if line and line not in STATUS["proxy_pool"]:
                    STATUS["proxy_pool"].append(line)
                    count += 1
        save_config()
        add_log(f"📂 [文件导入] 从 TXT 成功注入 {count} 个节点。")
        return jsonify({"status": "success", "msg": f"成功注入 {count} 个独立节点"})
    except Exception as e:
        return jsonify({"status": "failed", "msg": str(e)})


load_config()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, threaded=True)
'''

with open(os.path.join(BASE_DIR, "app.py"), "w", encoding="utf-8") as f:
    f.write(app_code)

print("[4/5] 正在写入前端页面与样式模板...")

login_html = r"""<!DOCTYPE html>
<html>
<head><title>矩阵系统安全鉴权</title><meta charset="utf-8">
<style>
body { background:#0a0a0a; color:#00ff66; font-family:monospace; display:flex; justify-content:center; align-items:center; height:100vh; margin:0; }
.box { border:1px solid #00ff66; padding:30px; background:#111; text-align:center; box-shadow:0 0 15px rgba(0,255,102,0.3); border-radius:6px; }
input { background:#000; border:1px solid #00ff66; color:#00ff66; padding:10px; font-family:monospace; margin-bottom:15px; width:220px; text-align:center; }
button { background:#00ff66; color:#000; border:none; padding:10px 24px; font-weight:bold; cursor:pointer; font-family:monospace; }
</style></head>
<body><div class="box"><h2>MATRIX 物理层鉴权</h2>
{% if error %}<p style="color:#ff4444;">{{ error }}</p>{% endif %}
<form method="post"><input type="password" name="password" placeholder="请输入系统密码" required><br><button type="submit">进入控制台</button></form>
</div></body></html>"""

with open(os.path.join(BASE_DIR, "templates/login.html"), "w", encoding="utf-8") as f:
    f.write(login_html)

index_html = r"""<!DOCTYPE html>
<html>
<head><title>矩阵自动化综合操盘控制台</title><meta charset="utf-8">
<style>
body { background:#090909; color:#e0e0e0; font-family:monospace; margin:20px; }
h1, h3 { color:#00ff66; margin-top:0; }
.grid { display:grid; grid-template-columns: 1.15fr 0.85fr; gap:20px; }
.card { background:#141414; border:1px solid #333; padding:16px; border-radius:6px; }
.stats-bar { display:grid; grid-template-columns: repeat(4, 1fr); gap:12px; margin-bottom:16px; }
.stat-box { background:#111; border:1px solid #2b2b2b; padding:10px 14px; border-radius:4px; }
.stat-label { font-size:12px; color:#888; }
.stat-val { font-size:18px; font-weight:bold; color:#00ff66; margin-top:4px; }
.btn { background:#222; color:#00ff66; border:1px solid #00ff66; padding:8px 14px; cursor:pointer; font-weight:bold; font-family:monospace; margin-right:6px; margin-top:4px; }
.btn:hover { background:#00ff66; color:#000; }
.btn-stop { color:#ff3333; border-color:#ff3333; }
.btn-stop:hover { background:#ff3333; color:#000; }
.btn-warn { color:#ffaa00; border-color:#ffaa00; }
.btn-warn:hover { background:#ffaa00; color:#000; }
input[type="text"], input[type="number"], select, textarea { background:#000; border:1px solid #444; color:#fff; padding:6px; width:98%; font-family:monospace; box-sizing:border-box; }
.row-2 { display:grid; grid-template-columns: 1fr 1fr; gap:10px; }
.row-3 { display:grid; grid-template-columns: 1fr 1fr 1fr; gap:10px; }
textarea { height:75px; }
.log-box { background:#020202; border:1px solid #ffaa00; height:320px; overflow-y:auto; padding:10px; font-size:12px; color:#ffaa00; white-space:pre-wrap; }
.preview-box { background:#000; border:1px solid #333; min-height:180px; display:flex; align-items:center; justify-content:center; margin-top:10px; border-radius:4px; overflow:hidden; }
.preview-box img { max-width:100%; max-height:260px; display:block; }
.header-bar { display:flex; justify-content:space-between; align-items:center; border-bottom:2px solid #00ff66; padding-bottom:10px; margin-bottom:15px; }
</style></head>
<body>
<div class="header-bar">
  <div><h1>矩阵自动化综合操盘控制台 (终极整合版)</h1>
  <span>● 状态: <span id="run-status" style="font-weight:bold;">检测中...</span> | 当前节点: <span id="current-node" style="color:#00ccff;">待命</span></span></div>
  <a href="/logout" style="color:#ff3333; font-weight:bold; text-decoration:none;">[安全登出]</a>
</div>
<div class="stats-bar">
  <div class="stat-box"><div class="stat-label">代理池存量</div><div class="stat-val" id="pool-count">0</div></div>
  <div class="stat-box"><div class="stat-label">累计执行轮次</div><div class="stat-val" id="stat-total">0</div></div>
  <div class="stat-box"><div class="stat-label">成功完成</div><div class="stat-val" id="stat-success" style="color:#00ff66;">0</div></div>
  <div class="stat-box"><div class="stat-label">异常/失败</div><div class="stat-val" id="stat-failed" style="color:#ff4444;">0</div></div>
</div>
<div class="grid">
  <div class="card"><h3>操盘战略与拟人化配置</h3>
    <form id="control-form">
      <p>目标 URL 列表 (每行一个，支持多网址随机轮询):<br><textarea name="urls" required>{{ cfg.target_urls }}</textarea></p>
      <div class="row-3">
        <p>单页停留 (最小/最大秒):<br><span style="display:flex; gap:4px;"><input type="number" name="stay_min" value="{{ cfg.stay_min }}"><input type="number" name="stay_max" value="{{ cfg.stay_max }}"></span></p>
        <p>轮次冷却 (最小/最大秒):<br><span style="display:flex; gap:4px;"><input type="number" name="interval_min" value="{{ cfg.interval_min }}"><input type="number" name="interval_max" value="{{ cfg.interval_max }}"></span></p>
        <p>最大轮次 (0=无限):<br><input type="number" name="max_runs" value="{{ cfg.max_runs }}"></p>
      </div>
      <div class="row-3">
        <p>内页深挖概率 (%):<br><input type="number" name="inner_page_prob" value="{{ cfg.inner_page_prob }}"></p>
        <p>最多逛内页数:<br><input type="number" name="max_inner_pages" value="{{ cfg.max_inner_pages }}"></p>
        <p>设备指纹模式:<br>
          <select name="device_mode">
            <option value="mixed" {% if cfg.device_mode == 'mixed' %}selected{% endif %}>PC+移动混合</option>
            <option value="desktop" {% if cfg.device_mode == 'desktop' %}selected{% endif %}>仅桌面端</option>
            <option value="mobile" {% if cfg.device_mode == 'mobile' %}selected{% endif %}>仅移动端</option>
          </select>
        </p>
      </div>
      <div class="row-2">
        <p>一级点击目标 (CSS 或 coord:X,Y):<br><input type="text" name="click_selector" value="{{ cfg.click_selector }}" placeholder="例如: coord:960,1020"></p>
        <p>二级点击目标 (可选):<br><input type="text" name="sub_click_selector" value="{{ cfg.sub_click_selector }}"></p>
      </div>
      <div class="row-2">
        <p>自定义 Referer (留空自动权重分流):<br><input type="text" name="referer" value="{{ cfg.referer }}" placeholder="https://www.google.com"></p>
        <p>媒体额外停留上限 (秒):<br><input type="number" name="watch_time" value="{{ cfg.watch_time }}"></p>
      </div>
      <p>拟人行为与网络开关：<br>
        <label><input type="checkbox" name="browse" value="true" {% if cfg.random_browse %}checked{% endif %}> 启用分段平滑滚动与回看阅读</label><br>
        <label><input type="checkbox" name="human_mouse" value="true" {% if cfg.human_mouse %}checked{% endif %}> 启用随机鼠标轨迹与元素悬停</label><br>
        <label style="color:#ffaa00;"><input type="checkbox" name="block_ads" value="true" {% if cfg.block_ads %}checked{% endif %}> 开启高能耗广告/统计脚本拦截</label><br>
        <label><input type="checkbox" name="vid" value="true" {% if cfg.play_video %}checked{% endif %}> 启用额外媒体观看停留</label><br>
        <label><input type="checkbox" name="tor" value="true" {% if cfg.use_tor %}checked{% endif %}> 强制走 Tor (127.0.0.1:9050) 通道</label><br>
        <label style="color:#00ccff;"><input type="checkbox" name="strict_proxy" value="true" {% if cfg.strict_proxy %}checked{% endif %}> 严格代理模式 (无可用代理时不回退直连)</label><br>
        <label style="color:#00ccff;"><input type="checkbox" name="consume_proxy" value="true" {% if cfg.consume_proxy %}checked{% endif %}> 代理用后即焚 (每轮用完移除，少于3个自动拉取新IP)</label>
      </p>
      <button type="button" class="btn" onclick="sendControl('start')">启动 / 应用配置</button>
      <button type="button" class="btn btn-stop" onclick="sendControl('stop')">紧急全面停滞</button>
    </form>
  </div>
  <div class="card"><h3>代理 IP 资源池管理</h3>
    <p>API 提取链路 (每行一个接口，自动轮替拉取)：<br><textarea id="api-url" placeholder="http://api1.com/get&#10;http://api2.com/get">{{ cfg.proxy_api }}</textarea></p>
    <p>手动批量粘贴 IP (支持 ip:port / user:pass@ip:port / socks5://):<br><textarea id="paste-ips" placeholder="12.34.56.78:8080"></textarea></p>
    <button type="button" class="btn" onclick="injectIPs()">注入文本池</button>
    <button type="button" class="btn btn-warn" onclick="checkProxies()">测速清洗</button>
    <button type="button" class="btn" onclick="window.location.href='/export_proxies'">导出存活</button>
    <button type="button" class="btn btn-stop" onclick="clearIPs()">清空</button>
    <p style="margin-top:10px;">TXT 批量导入: <input type="file" id="txt-file" accept=".txt" style="width:auto;"> <button type="button" class="btn" onclick="uploadTxt()">上传</button></p>
    <hr style="border-color:#333; margin:15px 0;">
    <div style="display:flex; justify-content:space-between; align-items:center;"><h3 style="margin:0;">实时画面预览</h3><button type="button" class="btn btn-warn" onclick="refreshPreview()">刷新画面</button></div>
    <div class="preview-box"><img id="live-preview" src="" alt="运行后点击刷新查看无头浏览器实时画面" style="color:#666; font-size:12px;"></div>
  </div>
</div><br>
<div class="card">
  <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:8px;"><h3 style="margin:0;">系统全链路流控日志</h3><button type="button" class="btn btn-warn" onclick="clearLogs()">清空日志</button></div>
  <div class="log-box" id="log-console">加载日志中...</div>
</div>
<script>
function updateStatus() {
  fetch('/status').then(res => res.json()).then(data => {
    const s = document.getElementById('run-status');
    s.innerText = data.is_running ? "运转中..." : "冷备冬眠中";
    s.style.color = data.is_running ? "#00ff66" : "#ff3333";
    document.getElementById('current-node').innerText = data.current_node || "待命";
    document.getElementById('pool-count').innerText = data.pool_count;
    document.getElementById('stat-total').innerText = data.stats.total;
    document.getElementById('stat-success').innerText = data.stats.success;
    document.getElementById('stat-failed').innerText = data.stats.failed;
    const logBox = document.getElementById('log-console');
    const atBottom = logBox.scrollHeight - logBox.scrollTop <= logBox.clientHeight + 30;
    logBox.innerText = data.logs.join('\n');
    if (atBottom) logBox.scrollTop = logBox.scrollHeight;
  }).catch(() => {});
}
setInterval(updateStatus, 1500);
updateStatus();
function refreshPreview() { document.getElementById('live-preview').src = '/screenshot?t=' + Date.now(); }
function sendControl(action) {
  const fd = new FormData(document.getElementById('control-form'));
  fd.append('action', action);
  fd.append('api', document.getElementById('api-url').value);
  fetch('/control', { method: 'POST', body: fd }).then(() => updateStatus());
}
function injectIPs() {
  const val = document.getElementById('paste-ips').value;
  if (!val.trim()) return;
  const fd = new FormData(); fd.append('ips', val);
  fetch('/inject_ips', { method: 'POST', body: fd }).then(r => r.json()).then(d => { document.getElementById('paste-ips').value = ''; updateStatus(); alert('成功注入 ' + d.added + ' 个新节点！'); });
}
function checkProxies() { fetch('/check_proxies', { method: 'POST' }).then(r => r.json()).then(d => alert(d.msg)); }
function clearIPs() { if (confirm('确定清空当前IP资源池吗？')) fetch('/clear_ips', { method: 'POST' }).then(() => updateStatus()); }
function clearLogs() { fetch('/clear_logs', { method: 'POST' }).then(() => updateStatus()); }
function uploadTxt() {
  const fi = document.getElementById('txt-file');
  if (fi.files.length === 0) { alert('请选择 TXT 文件'); return; }
  const fd = new FormData(); fd.append('file', fi.files[0]);
  fetch('/upload_txt', { method: 'POST', body: fd }).then(r => r.json()).then(d => { alert(d.msg); fi.value = ""; updateStatus(); });
}
</script></body></html>"""

with open(os.path.join(BASE_DIR, "templates/index.html"), "w", encoding="utf-8") as f:
    f.write(index_html)

print("[5/5] 正在配置并启动 Tor 与 Systemd 系统服务...")
service_content = f"""[Unit]
Description=Matrix Traffic Bot Automation System
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory={BASE_DIR}
ExecStart={VENV_PY} {BASE_DIR}/app.py
Restart=always

[Install]
WantedBy=multi-user.target
"""

try:
    subprocess.run(["systemctl", "enable", "--now", "tor"], check=False)
    with open("/etc/systemd/system/traffic_bot.service", "w", encoding="utf-8") as f:
        f.write(service_content)
    subprocess.run(["systemctl", "daemon-reload"], check=True)
    subprocess.run(["systemctl", "enable", "traffic_bot"], check=True)
    subprocess.run(["systemctl", "restart", "traffic_bot"], check=True)
except Exception as e:
    print(f"⚠️ Systemd 服务配置跳过或失败: {e}")
    print(f"👉 你可以手动运行启动: {VENV_PY} {BASE_DIR}/app.py")

print("==================================================")
print("🎉 恭喜！矩阵自动化操盘系统（终极整合版）已安装成功！")
print("📌 访问地址: http://<你的服务器IP>:5000")
print("🔑 默认登录密码: admin888")
print("==================================================")

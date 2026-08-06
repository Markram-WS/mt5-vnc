# วิธีติดตั้งและรันบอท (Installation Guide)

คู่มือฉบับนี้สำหรับติดตั้ง MT5 + Expert Advisor (EA) บน Docker/Podman ให้บอทรันอัตโนมัติโดยไม่ต้องเข้า GUI ทุกครั้ง

---

## 1. ความต้องการของระบบ

| สิ่งที่ต้องมี | เวอร์ชัน |
|---|---|
| Linux (มีระบบ user namespace / rootless) | - |
| Docker หรือ Podman | Podman 4.x, Docker 20+ |
| docker-compose (สำหรับ Podman ใช้ `podman compose`) | v2 |
| หน่วยความจำ | ≥ 1 GB (แนะนำ 2 GB) |
| พื้นที่ว่าง | ≥ 5 GB (Wine prefix + MT5) |

> หมายเหตุ: โปรเจกต์นี้ใช้ rootless Podman + KasmVNC เป็นหลัก ส่วน Docker ก็ใช้ได้เช่นกัน

---

## 2. เตรียมไฟล์ .env

คัดลอกตัวอย่างแล้วกรอกค่าจริง (**.env จะไม่ถูก commit ขึ้น git** เพราะอยู่ใน `.gitignore`):

```bash
cp .env.example .env
```

เปิด `.env` แล้วตั้งค่าตามนี้:

```dotenv
# ===== บัญชี MT5 (บังคับ เพื่อให้ auto-login ทำงาน) =====
MT5_SERVER="VantageMarkets-Demo"          # หรือ "server:port" เช่น demo-server.com:443
MT5_ACCOUNT="123456789"                    # เลขบัญชี MT5
MT5_PASSWORD="your_password"               # รหัสผ่าน

# ===== EA ที่ต้องการ auto-start (ตัวเลือกได้) =====
MT5_AUTO_START_EA="TestAutoStartEA"        # ชื่อ EA ใน MQL5/Experts
MT5_AUTO_START_SYMBOL="EURUSD"             # Symbol ที่ให้เปิด chart
MT5_AUTO_START_PERIOD="H1"                 # Timeframe

# ===== โหมดรัน =====
HEADLESS="false"                           # true = headless, false = มี VNC
ENABLE_MT5LINUX_API="true"                 # เปิด mt5linux API (port 8001)

# ===== VNC (เฉพาะโหมด dev) =====
MT5_VNC_USER="your_vnc_username"
MT5_VNC_PASSWORD="your_vnc_password"
```

### ตัวแปร env ทั้งหมด

| ตัวแปร | ค่าเริ่มต้น | ความหมาย |
|---|---|---|
| `MT5_SERVER` | - | ชื่อ server หรือ `host:port` |
| `MT5_ACCOUNT` | - | เลขบัญชี |
| `MT5_PASSWORD` | - | รหัสผ่าน |
| `MT5_AUTO_START_EA` | `TestAutoStartEA` | EA ที่ auto-start |
| `MT5_AUTO_START_SYMBOL` | `EURUSD` | Symbol ของ chart |
| `MT5_AUTO_START_PERIOD` | `H1` | Timeframe |
| `HEADLESS` | `false` | `true` = ไม่มี VNC (สำหรับ server) |
| `ENABLE_MT5LINUX_API` | `true` | เปิด API port 8001 |
| `MT5_VNC_USER` / `MT5_VNC_PASSWORD` | - | รหัส VNC (dev) |
| `COMPANY_ENV` | `production` | ป้ายกำกับสภาพแวดล้อม |
| `COMPANY_REGION` | `us-east-1` | ป้ายกำกับภูมิภาค |
| `MT5_BROKER_SERVER` / `MT5_BROKER_PORT` | - / `443` | ถ้าไม่ตั้ง `MT5_SERVER` ตรงๆ |

---

## 3. เตรียม EA

วางไฟล์ EA ไว้ในโฟลเดอร์ `mql5/Experts/` (bind-mount เข้า `MQL5/Experts/` ใน container):

```text
mql5/Experts/TestAutoStartEA.mq5
mql5/Experts/TestAutoStartEA.ex5
```

ถ้ายังไม่มี `.ex5` ให้คอมไพล์ผ่าน MetaEditor (ใน VNC) หรือคอมไพล์จากภายนอกแล้ววางทั้ง `.mq5` + `.ex5`.

EA ที่ auto-start ได้ต้องมี `.ex5` อยู่จริงใน `MQL5/Experts/` — ถ้าไม่มี MT5 จะข้ามไปเงียบๆ

---

## 4. รัน (build + start)

### 4.1 Build image (ครั้งแรก ~2-5 นาที)

```bash
docker-compose build
# หรือ Podman rootless
DOCKER_HOST=unix:///run/user/1000/podman/podman.sock docker-compose build
```

### 4.2 Start

```bash
docker-compose up -d
```

ครั้งแรก MT5 จะติดตั้ง Wine + Python + MT5 เอง (auto) ประมาณ 2-3 นาที แล้ว login ด้วยบัญชีจาก `.env`

---

## 5. ตรวจสอบว่า EA ทำงาน

### 5.1 ดูว่า EA ถูกโหลดขึ้นอัตโนมัติ

```bash
docker-compose logs -f | grep -i "expert"
# หรือ (Podman)
podman exec mt5_app bash -c 'tr -d "\000" < "/opt/mt5/drive_c/Program Files/MetaTrader 5/logs/"$(date +%Y%m%d).log | grep -a expert'
```

ควรเห็น:

```text
[1.xxx]  expert TestAutoStartEA (EURUSD,H1) loaded successfully
```

### 5.2 ดูว่า EA ทำงานจริง (OnTick วิ่งตลอด)

```bash
podman exec mt5_app bash -c 'tr -d "\000" < "/opt/mt5/drive_c/Program Files/MetaTrader 5/MQL5/logs/"$(date +%Y%m%d).log | tail -20'
```

ควรเห็น `TestAutoStartEA: OnTick ts=...` ต่อเนื่อง — แปลว่า EA รับ tick data และทำงานจริง

### 5.3 ทดสอบข้าม restart (ยืนยัน auto-start)

```bash
docker-compose restart
sleep 30
# ตรวจว่า EA โหลดอีกครั้งโดยไม่ต้องแตะ GUI
podman exec mt5_app bash -c 'tr -d "\000" < "/opt/mt5/drive_c/Program Files/MetaTrader 5/logs/"$(date +%Y%m%d).log | grep -a "loaded successfully" | tail -1'
```

> **ทำไม EA auto-start ได้?** `start.sh` เขียน `startup.ini` (`[StartUp] Expert=... Symbol=... Period=...`) ไว้ทั้งที่ data-dir และ install root ก่อนเปิด MT5 ทุกครั้ง — build 6090 อ่านไฟล์นี้แล้ว attach EA เองตอน boot

---

## 6. ทดสอบผ่าน VNC (โหมด dev)

เมื่อ `HEADLESS=false` จะมี VNC web เข้าใช้งานได้:

| สิ่งที่ต้องเข้าถึง | URL / Port |
|---|---|
| VNC (web) | `http://<host>:3000` (หรือ :6901 websocket) |
| mt5linux API | `localhost:8001` |

ขั้นตอนใน VNC:
1. เปิดเบราว์เซอร์ไปที่ `http://localhost:3000` → log in ด้วย `MT5_VNC_USER` / `MT5_VNC_PASSWORD`
2. หน้าจอจะเห็น MT5 เปิดพร้อม chart + EA ที่ `Navigator` (ซ้ายล่าง)
3. EA ที่ทำงานอยู่จะเห็นที่ **Experts** tab (แท็บด้านล่าง) — มีไฟเขียว หรือ print ขึ้นใน Experts log

---

## 7. ทดสอบ mt5linux API

```bash
podman run --rm --network host python:3.11 bash -c 'pip install rpyc -q && python3 -c "import rpyc; conn = rpyc.connect(\"127.0.0.1\", 8001); print(\"Connected\"); conn.close()"'
```

ควรพิมพ์ `Connected` ออกมา

---

## 8. โหมด Headless (สำหรับ production/server)

ตั้ง `HEADLESS=true` ใน `.env` แล้ว restart — จะไม่มี VNC (ประหยัด RAM ~100MB) แต่ EA ยัง auto-start เหมือนเดิม

```dotenv
HEADLESS="true"
```

---

## 9. ปัญหาที่พบบ่อย (ฉบับย่อ)

| อาการ | สาเหตุ/วิธีแก้ |
|---|---|
| ไม่เห็น `loaded successfully` | EA `.ex5` ไม่มีใน `MQL5/Experts/` → วางไฟล์แล้ว rebuild/restart |
| `cannot load config "...autostart-cli.ini"` | image เก่า → `docker-compose build && up -d` |
| VNC ขึ้น 401 | ตรวจ `MT5_VNC_USER`/`MT5_VNC_PASSWORD` ใน `.env` |
| container รันแต่ไม่มี MT5 | ครั้งแรกใช้เวลานาน (Wine setup) → รอ 3 นาทีแล้วดู `logs` |
| EA ไม่ทำงานแบบ live-trading | ตรวจ `Config/common.ini` ว่า `[Experts] AllowLiveTrading=1` |

ดูรายละเอียดเพิ่ม: [TROUBLESHOOT.md](../TROUBLESHOOT.md)

---

## 10. โครงสร้างโปรเจกต์ที่เกี่ยวข้อง

```text
.
├── .env                  # ค่าจริง (ไม่ commit)
├── .env.example          # ตัวอย่าง env
├── docker-compose.yml    # กำหนด ports/volumes/env
├── Dockerfile            # สร้าง image (Wine + MT5)
├── Metatrader/
│   ├── start.sh          # ตัวเริ่ม MT5 + เขียน startup.ini (auto-start EA)
│   ├── headless.sh       # โหมด headless (Xvfb)
│   └── startup.ini       # ไฟล์ [StartUp] สำหรับ EA
├── mql5/Experts/         # วาง EA (.mq5/.ex5)
└── docs/INSTALL.md       # ไฟล์นี้
```

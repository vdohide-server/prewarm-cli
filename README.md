# Prewarm CLI

ระบบ Queue สำหรับ HLS Cache Warming

## 🚀 Installation

```bash
cd prewarm-cli
chmod +x install.sh
sudo ./install.sh
```

## ⚙️ Setup (ครั้งแรก)

```bash
prewarm setup
```

จะถาม:
- **BASE_DOMAIN** - เช่น `media.vdohls.com` (ใช้สร้าง URL อัตโนมัติจาก ID)
- **API_ENDPOINT** - เช่น `https://api.example.com/prewarm` (รับ/ส่ง job)
- **API_TOKEN** - สำหรับ Authorization (optional)

## 📖 Usage

### เพิ่ม Job

```bash
# วิธีที่ 1: ใช้ ID (แนะนำ!)
prewarm add h_A8yW-KTJql3
# → https://media.vdohls.com/h_A8yW-KTJql3/playlist.m3u8

# วิธีที่ 2: ใช้ URL เต็ม
prewarm add https://vdohls.com/new-1/master.m3u8

# กำหนด parallel
prewarm add l9qfjn7xpi 50

# Output:
# Building URL: https://media.vdohls.com/h_A8yW-KTJql3/playlist.m3u8
# ✓ Added job: abc123
#   URL: https://media.vdohls.com/h_A8yW-KTJql3/playlist.m3u8
#   Parallel: 50
```

### ดึง Queue จาก API

```bash
prewarm fetch
```

Daemon จะ **auto-fetch** เมื่อ queue ว่าง (ทุก ~30 วินาที)

### ดู List

```bash
prewarm list

# Output:
# ═══════════════════════════════════════════════════════════════════
# ID       STATUS     PROGRESS      HIT     MISS  URL
# ═══════════════════════════════════════════════════════════════════
# abc123   running         45%      300      100  https://media.vdohls.com/...
# def456   pending          -         0        0  https://media.vdohls.com/...
# ═══════════════════════════════════════════════════════════════════
# Daemon: running | Concurrent: 1/2
```

### ดู Status (Live)

```bash
# Real-time monitoring
prewarm watch

# หรือ
prewarm status -w
```

### ดูรายละเอียด Job

```bash
prewarm show abc123

# Output:
# ══════════════════════════════════════════════════════════════
# Job Details: abc123
# ══════════════════════════════════════════════════════════════
# URL:      https://example.com/master.m3u8
# Parallel: 50
# Status:   running
#
# Progress: 400 / 1000
# HIT:      300
# MISS:     100
# EXPIRED:  0
# FAILED:   0
#
# Created:   2025-11-28 10:30:00
# Started:   2025-11-28 10:30:05
# Completed: -
```

### ยกเลิก Job

```bash
prewarm cancel abc123

# Output:
# ✓ Cancelled running job: abc123
```

### ดู Logs

```bash
# Daemon log
prewarm logs

# Job log
prewarm logs xhfwnu
```

## ⚙️ Configuration

### ดู Config ปัจจุบัน

```bash
prewarm config

# Output:
# Current Configuration:
#   MAX_CONCURRENT=2
#   DEFAULT_PARALLEL=20
#   BASE_DOMAIN=media.vdohls.com
#   API_ENDPOINT=https://api.example.com/prewarm
#   API_TOKEN=***hidden***
```

### ตั้งค่า

```bash
# รัน 3 jobs พร้อมกัน
prewarm config MAX_CONCURRENT 3

# 50 parallel requests per job
prewarm config DEFAULT_PARALLEL 50

# เปลี่ยน domain
prewarm config BASE_DOMAIN cdn.example.com

# หรือใช้ interactive setup
prewarm setup
```

## 🔧 Daemon Management

```bash
# Start daemon
prewarm start

# Stop daemon
prewarm stop

# Restart daemon (หลังเปลี่ยน config)
prewarm restart
```

## 📁 File Structure

```
/var/lib/prewarm/
├── config              # Configuration file
├── queue/              # Pending jobs
│   └── abc123.job
├── running/            # Currently running jobs
│   ├── def456.job
│   └── def456.pid
├── completed/          # Completed jobs
│   └── ghi789.job
└── logs/
    ├── daemon.log      # Daemon log
    ├── abc123.log      # Job logs
    └── def456.log
```

## 📝 Job File Format

```json
{
  "id": "abc123",
  "url": "https://media.vdohls.com/h_A8yW-KTJql3/playlist.m3u8",
  "parallel": 50,
  "status": "running",
  "progress": 400,
  "total": 1000,
  "hit": 300,
  "miss": 100,
  "expired": 0,
  "failed": 0,
  "created": "2025-11-28 10:30:00",
  "started": "2025-11-28 10:30:05",
  "completed": ""
}
```

## 🌐 API Integration

### API Endpoint Format

เมื่อ **job เสร็จ** จะ POST ไปที่ `{API_ENDPOINT}/complete`:

```json
{
  "job_id": "abc123",
  "url": "https://media.vdohls.com/h_A8yW-KTJql3/playlist.m3u8",
  "total": 1000,
  "hit": 800,
  "miss": 200,
  "expired": 0,
  "failed": 0,
  "started": "2025-11-28 10:30:05",
  "completed": "2025-11-28 10:35:00"
}
```

เมื่อ **queue ว่าง** จะ GET จาก `{API_ENDPOINT}/queue`:

```json
[
  {"id": "h_A8yW-KTJql3", "parallel": 20},
  {"id": "x_B9zX-LUKrm4", "parallel": 30}
]
```

### Manual Fetch

```bash
prewarm fetch
```

## 🎯 Examples

### Batch Add

```bash
# เพิ่มหลาย IDs
echo "h_A8yW-KTJql3
x_B9zX-LUKrm4
y_C0aY-MVLsn5" | while read id; do
    prewarm add "$id" 30
done
```

### Monitor Loop

```bash
# Real-time monitoring
prewarm watch
```

### Auto Cleanup

```bash
# ลบ completed jobs เก่า (default: 1 ชม.)
prewarm clean

# ลบ jobs เก่ากว่า 24 ชม.
prewarm clean 24
```

## 🔍 Troubleshooting

### Daemon ไม่ start

```bash
# ดู log
cat /var/lib/prewarm/logs/daemon.log

# ตรวจสอบ permission
ls -la /var/lib/prewarm/
```

### Job ค้าง

```bash
# Cancel และ add ใหม่
prewarm cancel abc123
prewarm add h_A8yW-KTJql3
```

### ดู running processes

```bash
ps aux | grep prewarm
```

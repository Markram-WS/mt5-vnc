# MT5 Production — Architecture

This document describes the **prod** (headless) MT5 container architecture and how
the pieces fit together. It pairs with the operational `README.md`.

---

## 1. System context

Two deployments, both running the **same MetaTrader 5** install and EA:

| | **dev** | **prod (this)** |
|---|---|---|
| Base image | `gmag11/metatrader5_vnc` (~8.8GB) | `tobix/wine:stable` (~2.5GB) |
| GUI / VNC | yes, port **3000** (KasmVNC) | **none** — headless (Xvfb only) |
| Display | interactive (VNC) | `Xvfb :99` virtual framebuffer |
| GUI tooling | xdotool present (used for login) | **no xdotool** (removed) |
| MQL5 source | full `mql5/` example tree (~107MB) | same shared `mql5/` tree (nothing baked) |
| Purpose | author / configure / test | replicate, run headless, deploy (K8s) |

Both auto-start the EA via **`startup.ini`**, not GUI dragging. `prod/` replicates
dev's **behavior** with a thin, headless, minimal image.

```
            ┌────────────────────────────┐
            │        host (podman)       │
            └─────────────┬──────────────┘
                          │ DOCKER_HOST=unix:///run/user/1000/podman/podman.sock
              ┌───────────┴───────────┐
              │  mt5_prod container    │
              │  (tobix/wine base)     │
              └───────────┬───────────┘
                          │
        ┌─────────────────┴──────────────────┐
        │  shared volume  mt5-vantage         │
        │  = dev's volume  (mt5-dev_mt5-vantage)│
        │  * wine prefix /opt/mt5             │
        │  * METATRADER install + programs     │
        │  * login (authorized) state          │
        │  * terminal profile                  │
        └──────────────────────────────────────┘
```

The volume is **shared/external** (one instance = one PV in k8s). The **same** PV
instance backs both dev and prod in k8s. dev and prod **must not** run simultaneously
on the same volume.

---

## 2. Container runtime lifecycle

Entry chain (no s6; `tini` + scripts only):

```
tini
 └── /Metatrader/headless.sh
      ├─ start Xvfb :99 (virtual display for MT5)
      ├─ export DISPLAY=:99, WINEPREFIX=/opt/mt5, XDG_DATA_HOME
      └── bash /Metatrader/start.sh
           ├─ [1/7] install Mono in prefix  (if missing)
           ├─ [2/7] check MT5 installed/install (if missing)
           ├─ [3/7] download MT5 installer   (brand-new PV only)
           ├─ [4/7] install Python in Wine   (if missing)
           ├─ [5/7] deps: mt5linux + Wine MetaTrader5 lib
           ├─ [6/7] start mt5linux API on port 8001 (if ENABLE_MT5LINUX_API)
           ├─ [7/7] write startup.ini + launch MT5
           │         ├─ /login /password /server (auto-login) or /portable
           │         └─ EA auto-attached from startup.ini
           ├─ xdotool GUI login block (only runs if xdotool present → NO on prod)
           └─ monitor-mt5-logs.sh  (tail → stdout)    (backgrounded)
```

**Key point:** on the shared volume the MT5 install + login already exist, so steps
[1]–[4] no-op and MT5 *resumes* the persisted session without a GUI.

---

## 3. EA auto-start mechanism

The EA is attached by **MT5 itself** at launch (build 6090) — no GUI automation.

1. `start.sh` reads dynamic env, then writes `startup.ini`:
   ```
   [StartUp]
   Expert=TestAutoStartEA
   Symbol=EURUSD
   Period=H1
   ```
   Written to **two** locations: the install root *and* the terminal UUID dir.
2. MT5 reads `startup.ini` at boot → opens the chart → attaches the EA.
3. Data/session persistence lives in the shared volume, so the seed persisted in dev's
   GUI carries over to the same volume in prod.

```
MT5_AUTO_START_EA            ┌──────────────────────────────┐
MT5_AUTO_START_SYMBOL  ─────▶│ start.sh                     │
MT5_AUTO_START_PERIOD        │   writes startup.ini          │
─────────────────────────────│───────────────────────────────│
        .env                 │[StartUp]                      │
                             │Expert/Symbol/Period           │
                             └───────────────┬──────────────┘
                                             │ read at boot
                                             ▼
                                        MT5 terminal ── attaches EA on chart
```

---

## 4. Code paths / file layout (prod/)

```
prod/
├── Dockerfile                  # thin base + deps + scripts baked in
├── docker-compose.yml          # 1 service; ports, env, volume, bind mounts
├── .env / .env.example         # runtime config (dynamic)
├── README.md
├── ARCHITECTURE.md             # (this)
└── Metatrader/
    ├── headless.sh             # Xvfb + passes to start.sh
    ├── start.sh                # install/launch + EA auto-start + API
    ├── monitor-mt5-logs.sh     # tail → [EA:..][SYSTEM:..] on stdout
    └── startup.ini             # EA/Symbol/Period            (bind-mounted)

../mql5/                       # repo-root tree, bind-mounted → /opt/mt5/.../MQL5/
├── Experts/TestAutoStartEA.{mq5,ex5}
├── Profiles/                  # chart/template/symbolset state
├── Include/ Scripts/ Services/
├── experts.dat                # MT5 internal index
└── logs/                      # MT5/EA UTF-16 logs
```

---

## 5. Mounts (bind mounts)

| Host path | Container path | Note |
|---|---|---|
| `../mql5` | `…/MetaTrader 5/MQL5/` | shared MQL5 tree — bind mount over volume |
| `./Metatrader/startup.ini` | `…/MetaTrader 5/startup.ini` | one-shot boot file |
| external volume `mt5-vantage` | `/opt/mt5/` | the whole Wine prefix |

---

## 6. Logging pipeline

```
MT5 terminal write  ──▶  MQL5/logs/*.log  (UTF-16LE)
                            │
                            └── monitor-mt5-logs.sh (tail -F, decode)
                                    │
                                    ▼
                       container stdout:  [EA:20260807.log] ... OnTick
                                          [SYSTEM:...] ...
```

Everything lands on **stdout** — so `docker logs -f mt5_prod` shows EA + system
activity without exec-ing in.

---

## 7. API (mt5linux)

- `mt5linux` runs on the **Linux side** (installed via pip in the image), not inside
  Wine. It talks to the Windows MT5 terminal through the `MetaTrader5` Python library
  (installed into Wine Python) over the Wine network/pipe bridge.
- port **8001** (in-container), published **8002** on host.
- Controlled by `ENABLE_MT5LINUX_API=true`.
- Used by external code to query markets / send orders through the MT5 account.

---

## 8. Config & k8s mapping

| prod/compose/.env | k8s |
|---|---|
| `MT5_SERVER`, `MT5_ACCOUNT`, `MT5_PASSWORD` | Secret |
| `MT5_AUTO_START_EA/SYMBOL/PERIOD`, `ENABLE_MT5LINUX_API` | ConfigMap (Helm/Kustomize) |
| done inline | Helm chart values |

---

## 9. Sizing

- base `tobix/wine:stable` ≈ **2.5GB**
- + Linux deps (python3, mt5linux; xdotool **removed**) — small
- + no MQL5 baked in (the shared `../mql5/` tree is mounted at runtime)
- Final local image ≈ **2.7GB** (vs dev ~8.8GB) — leaner; further reduction is limited
  by the Wine base itself.

---

## 10. Future / k8s notes

- The shared volume `mt5-vantage` already models the k8s PV.
- Instance → pod; ConfigMap/Secret injections replace `.env`.
- MinIO later serves the MQL5 archive instead of the local hostPath/bind mount.
# MT5 Production — Architecture

This document describes the **prod** (headless) MT5 container architecture and how
the pieces fit together. It pairs with the operational `README.md`.

---

## 1. System context

Two deployments, both running the **same MetaTrader 5** install and EA:

| | **dev** | **prod (this)** |
|---|---|---|
| Base image | `gmag11/metatrader5_vnc` (~8.8GB) | `tobix/wine:stable` (~2.7GB) |
| GUI / VNC | yes, port **3000** (KasmVNC) | **none** — headless (Xvfb only) |
| Display | interactive (VNC) | `Xvfb :99` virtual framebuffer |
| GUI tooling | xdotool present (used for login) | **no xdotool** (removed) |
| MQL5 source | cloned from git at `MQL5_GIT_REF` | same tree, same ref (nothing baked) |
| Purpose | author / configure / test | replicate, run headless, deploy |

Both auto-start the EA via **`startup.ini`**, not GUI dragging. `prod/` replicates
dev's **behavior** with a thin, headless, minimal image. Dev runs on the local
kind cluster; prod runs on the Talos cluster.

```
            ┌──────────────────────────────────┐
            │  Talos node                      │
            │  NodePort 30801 → container 8001 │
            └─────────────┬────────────────────┘
                          │
              ┌───────────┴────────────────────┐
              │  pod mt5 (1 replica)            │
              │  markram92/mt5-prod:<tag>       │
              │  init: fetch-mql5 →             │
              │        emptyDir /mql5           │
              └───────────┬────────────────────┘
                          │
        ┌─────────────────┴──────────────────┐
        │  PVC mt5-prefix (local-path)        │
        │  * wine prefix /opt/mt5             │
        │  * METATRADER install + programs     │
        │  * login (authorized) state          │
        │  * terminal profile                  │
        └──────────────────────────────────────┘
```

The prefix is **single-writer**: one PVC, one instance, `strategy: Recreate`.
Prod has its **own** prefix on the Talos node — it is not shared with the kind/dev
host prefix. Both environments do use the same demo account, so they must not be
logged in simultaneously.

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

**Key point:** once the prod PVC has been seeded (`seed-prefix` copies the image's
Wine prefix on first start, `fetch-profile` copies the login `Config` from MinIO),
the MT5 install + login already exist, so steps [1]–[4] no-op and MT5 *resumes*
the persisted session without a GUI.

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
3. Data/session persistence lives in the prod prefix PVC; the login `Config` it
   starts from is the profile the operator copied from dev to MinIO once.

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
├── .env / .env.example         # local build inputs only (never applied to a cluster)
├── README.md
├── ARCHITECTURE.md             # (this)
└── Metatrader/
    ├── headless.sh             # Xvfb + passes to start.sh
    ├── start.sh                # install/launch + EA auto-start + API
    └── monitor-mt5-logs.sh     # tail → [EA:..][SYSTEM:..] on stdout

mql5/                          # repo-root tree, cloned into the pod at MQL5_GIT_REF
├── Experts/TestAutoStartEA.{mq5,ex5}
├── Profiles/                  # chart/template/symbolset state
├── Include/ Scripts/ Services/
├── experts.dat                # MT5 internal index
└── logs/                      # MT5/EA UTF-16 logs
```

---

## 5. Storage

| Source | Container path | Note |
|---|---|---|
| `emptyDir`, filled by init container `fetch-mql5` (git clone at `MQL5_GIT_REF`) | `…/MetaTrader 5/MQL5/` | per-pod MQL5 tree; runtime writes die with the pod |
| PVC `mt5-prefix` (`StorageClass local-path`, node-local volume) | `/opt/mt5/` | the whole Wine prefix on the Talos node; seeded once from the image, login `Config` from MinIO |

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

Everything lands on **stdout** — so `kubectl -n mt5 logs -f deploy/mt5` shows EA
and system activity without exec-ing in.

---

## 7. API (mt5linux)

- `mt5linux` runs on the **Linux side** (installed via pip in the image), not inside
  Wine. It talks to the Windows MT5 terminal through the `MetaTrader5` Python library
  (installed into Wine Python) over the Wine network/pipe bridge.
- port **8001** (in-container), published as `NodePort 30801` on the Talos node.
- Controlled by `ENABLE_MT5LINUX_API=true`.
- Used by external code to query markets / send orders through the MT5 account.

---

## 8. Config mapping

| MinIO credentials (`ExternalSecret mt5-minio` from Vault `secret/mt5`) | ConfigMap `mt5-env` |
|---|---|
| `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY` | `MT5_AUTO_START_EA/SYMBOL/PERIOD`, `ENABLE_MT5LINUX_API`, `MQL5_GIT_URL/REF`, `MINIO_URL/BUCKET/PROFILE_PREFIX` |

There are no MT5 credentials in the environment on either side: prod logs in from
the profile `fetch-profile` seeds from MinIO, and dev from its host-mounted
profile. Everything non-secret lives in `deploy/base/configmap.yaml`; the Talos
overlay patches `MINIO_URL` to the in-cluster Service.

---

## 9. Sizing

- base `tobix/wine:stable` ≈ **2.5GB**
- + Linux deps (python3, mt5linux; xdotool **removed**) — small
- + no MQL5 baked in (the pod clones `mql5/` into an `emptyDir` at start)
- Final local image ≈ **2.7GB** (vs dev ~8.8GB) — leaner; further reduction is limited
  by the Wine base itself.

---

## 10. Future notes

- The prefix PVC `mt5-prefix` is the single writable state; a second instance would
  need its own PVC.
- ConfigMap `mt5-env` and the `ExternalSecret`/`Secret mt5-minio` are the only
  injection points; `.env` files are inputs for local builds, not cluster config.
- A future artifact store could serve the MQL5 archive instead of a `git clone` at
  pod start (the init container is the only seam that would change).
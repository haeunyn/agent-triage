# [Bug] Memory Leak - 실행 수십 초 후 MemoryGuard 에 의한 자진 종료

> **증거 데이터 출처**
> 코디세이 제공 바이너리 `agent-leak-app-arm64` 를 직접 실행해 얻은 실측값입니다.
> 측정 일시 **2026-11-07 09:23~09:25 (KST)**, 환경 Docker `agent-triage` (Ubuntu, aarch64).
> 재현 명령은 **4-5절**에 적었습니다.

---

## 1. Description (현상 설명)

`agent-leak-app` 을 실행하면 **약 23초 뒤 예고 없이 프로세스가 종료**됩니다.
종료 직전 터미널에 `>>> [SYSTEM] SELF-TERMINATED (Memory Limit Exceeded) <<<`
메시지가 출력됩니다.

| 항목 | 내용 |
|---|---|
| **언제** | 기동 후 **약 32초** (09:23:23 기동 → 09:23:55 종료) |
| **조건** | `MEMORY_LIMIT=256` · `CPU_MAX_OCCUPY=20` · `MULTI_THREAD_ENABLE=false` |
| | 즉 **메모리 한도만 낮춘 상태**, 나머지는 정상값 |
| **종료 지점** | 힙 **275MB** 도달 시 (한도 256MB 초과) |
| **누적 속도** | 25MB / 약 3.04초 ≈ **8.2MB/s** — 끝까지 일정 |
| **재현성** | 100% — 측정한 3회 모두 **275MB 에서** 종료 |

오류 메시지가 아니라 **애플리케이션이 스스로 종료**했다는 점이 특징입니다.

---

## 2. Evidence & Logs (증거 자료)

### 2-1. monitor.sh 관제 로그 — 메모리 선형 상승

```
관제 시작: agent-leak-app-arm64  (60초, 2초 간격)
[2026-11-07 09:23:24] PROCESS:agent-leak-app-arm64 PID:7427 CPU:1.9% MEM:1.1% DISK:1% FIREWALL:inactive
[2026-11-07 09:23:27] PROCESS:agent-leak-app-arm64 PID:7427 CPU:1.9% MEM:1.7% DISK:1% FIREWALL:inactive
[2026-11-07 09:23:31] PROCESS:agent-leak-app-arm64 PID:7427 CPU:0.0% MEM:2.3% DISK:1% FIREWALL:inactive
[2026-11-07 09:23:34] PROCESS:agent-leak-app-arm64 PID:7427 CPU:0.0% MEM:3.0% DISK:1% FIREWALL:inactive
[2026-11-07 09:23:37] PROCESS:agent-leak-app-arm64 PID:7427 CPU:0.0% MEM:3.6% DISK:1% FIREWALL:inactive
[2026-11-07 09:23:40] PROCESS:agent-leak-app-arm64 PID:7427 CPU:0.0% MEM:4.2% DISK:1% FIREWALL:inactive
[2026-11-07 09:23:43] PROCESS:agent-leak-app-arm64 PID:7427 CPU:0.0% MEM:4.9% DISK:1% FIREWALL:inactive
[2026-11-07 09:23:46] PROCESS:agent-leak-app-arm64 PID:7427 CPU:0.0% MEM:5.5% DISK:1% FIREWALL:inactive
[2026-11-07 09:23:49] PROCESS:agent-leak-app-arm64 PID:7427 CPU:0.0% MEM:6.1% DISK:1% FIREWALL:inactive
[2026-11-07 09:23:52] PROCESS:agent-leak-app-arm64 PID:7427 CPU:0.0% MEM:6.7% DISK:1% FIREWALL:inactive
[2026-11-07 09:23:55] PROCESS:agent-leak-app-arm64 PID:- CPU:- MEM:- DISK:1% FIREWALL:inactive STATE:NOT_RUNNING
→ 대상 프로세스가 사라졌습니다. 관제를 종료합니다.
```

> **`MEM` 은 프로세스 트리 전체의 합산값입니다.**
> 이 앱은 부모가 포트만 열어두고 실제 작업은 **워커 자식 프로세스**가 합니다.
> 부모만 측정했을 때는 누수가 한창인데도 `MEM:0.0%` 로 찍혀서, 관제 도구가
> "앱이 멀쩡하다"고 **거짓 보고**를 했습니다. 그래서 보고 PID 는 부모(7427)로 두고
> 수치는 자손까지 합산하도록 `monitor.sh` 를 고쳤습니다.
> 종료 로그의 `process 7429` 가 그 워커입니다.

**읽는 법 — 두 가지가 동시에 보입니다.**

| 지표 | 패턴 | 의미 |
|---|---|---|
| **MEM** | 1.0 → 6.3% **단조 증가**, 3초마다 약 +0.75%p | 쓰고 버리는 게 아니라 **계속 쌓인다** |
| **CPU** | 1~2% 로 **안정** | 연산 과부하가 아니다 → **메모리만의 문제** |

> CPU 가 평온한데 MEM 만 오르는 것이 **메모리 누수의 전형적 신호**입니다.
> 만약 둘 다 올랐다면 "일이 몰려서 바쁘다"로 해석할 여지가 있지만,
> 일은 안 하는데 메모리만 먹고 있다면 쌓아두기만 한다는 뜻입니다.

### 2-2. 프로그램 실행 로그 — 종료 직전 구간

```
2026-11-07 09:23:34,086 [INFO] [MemoryWorker] Current Heap: 100MB
2026-11-07 09:23:37,122 [INFO] [MemoryWorker] Current Heap: 125MB
2026-11-07 09:23:40,164 [INFO] [MemoryWorker] Current Heap: 150MB
2026-11-07 09:23:43,211 [INFO] [MemoryWorker] Current Heap: 175MB
2026-11-07 09:23:46,258 [INFO] [MemoryWorker] Current Heap: 200MB
2026-11-07 09:23:49,293 [INFO] [MemoryWorker] Current Heap: 225MB
2026-11-07 09:23:52,341 [INFO] [MemoryWorker] Current Heap: 250MB
2026-11-07 09:23:55,395 [INFO] [MemoryWorker] Current Heap: 275MB
2026-11-07 09:23:55,399 [CRITICAL] [MemoryGuard] Memory limit exceeded (275MB >= 256MB) / (Recommend Over 256MB)
2026-11-07 09:23:55,399 [CRITICAL] [MemoryGuard] Self-terminating process 7429 to prevent system instability.
```

**핵심 문장은 `Self-terminating process ... to prevent system instability` 입니다.**
외부에서 죽인 것이 아니라 **앱이 자기 상태를 감시하다가 스스로 내린 결정**입니다.

### 2-3. 시스템 도구 출력 — 힙 225MB 시점 스냅샷

`MEMORY_LIMIT=256` 으로 실행해 자진 종료 직전(힙 225MB)에 떠낸 것입니다.

```bash
$ grep -E '^(Name|State|VmRSS|VmSize|VmPeak|Threads):' /proc/17259/status   # 워커
Name:     agent-leak-app-
State:    S (sleeping)
VmPeak:     252600 kB
VmSize:     252600 kB
VmRSS:      245896 kB     ← 실제 점유한 물리 메모리 (약 240MB)
Threads:         1

$ grep -E '^(VmRSS|VmSize|VmPeak|Threads):' /proc/17258/status              # 부모
VmPeak:       2608 kB
VmSize:       2608 kB
VmRSS:        1692 kB     ← 부모는 1.6MB 그대로
Threads:         1
```

```bash
$ ps -p 17258,17259 -o pid,ppid,stat,%cpu,%mem,rss,etime,cmd
    PID    PPID STAT %CPU %MEM    RSS     ELAPSED CMD
  17258       1 S     0.3  0.0   1692       00:28 .../agent-leak-app-arm64
  17259   17258 SN    1.1  6.0 245896      00:28 .../agent-leak-app-arm64
```

**부모와 워커를 반드시 나눠 봐야 합니다.**

| | 부모 17258 | 워커 17259 |
|---|---|---|
| `%MEM` | **0.0%** | **6.0%** |
| `RSS` | 1,692 kB | **245,896 kB** |
| 역할 | 포트만 열고 자식을 기다림 | 실제 메모리 작업 |

**부모만 보면 `%MEM 0.0%` 입니다.** 누수가 240MB 까지 진행된 순간에도 그렇습니다.
이것이 `monitor.sh` 를 프로세스 트리 합산으로 바꾼 이유입니다 (2-1 참고).

> **`VmRSS` 를 봐야 합니다.** `VmSize` 는 "주소를 예약해 둔 공간"이라 늘 크고,
> 실제로 메모리를 차지하는지와는 다릅니다. 누수 추적은 `VmRSS` 기준입니다.
> 여기서는 둘이 거의 같은데(252,600 vs 245,896 kB), **예약한 공간을 거의 전부
> 실제로 쓰고 있다**는 뜻입니다. 전형적인 누수 모습입니다.
>
> `Threads: 1` 인 점도 단서입니다. 이 시나리오는 `MULTI_THREAD_ENABLE=false` 라
> 단일 스레드이고, **교착 케이스(리포트 03)에서는 같은 자리가 `Threads: 3`** 입니다.
> `/proc/<pid>/status` 한 장으로 어느 시나리오인지 구분할 수 있습니다.

---

## 3. Root Cause Analysis (원인 분석)

### 3-1. 현상 분석 — 메모리 누수(Memory Leak)

애플리케이션이 생성한 데이터를 **힙(Heap)에서 해제하지 않고 계속 쌓고 있습니다.**

> **먼저 밝혀둘 것.** 제공 바이너리는 `stripped` 된 실행 파일이고, 과제 제약에
> **「바이너리 디컴파일 및 리버스 엔지니어링 시도 금지」** 가 있습니다.
> 그래서 아래 판단은 **소스를 본 것이 아니라 밖에서 관찰한 것으로부터 추론**한 것입니다.
> 근거는 이 셋입니다.

| 관찰 | 어디서 | 무엇을 가리키는가 |
|---|---|---|
| RSS 가 **단조 증가**, 기울기 일정(8.2MB/s) | 2-1 관제 로그 | 쓰고 버리는 게 아니라 **쌓고 있다** |
| 같은 구간 **CPU 는 0~2%** | 2-1 관제 로그 | 연산 과부하가 아니다 → **메모리만의 문제** |
| 앱이 스스로 `Current Heap: N MB` 를 올려 찍는다 | 2-2 앱 로그 | 앱 자신이 **힙 누적을 인지**하고 있다 |

**CPU 가 평온한데 메모리만 오르는 것이 메모리 누수의 전형적 신호입니다.**
둘 다 올랐다면 "일이 몰려서 바쁘다"로 볼 여지가 있지만, 일은 안 하면서
메모리만 먹는다면 쌓아두기만 한다는 뜻입니다.

#### 왜 이런 코드가 누수가 되는가 (메커니즘 설명)

아래는 **바이너리의 소스가 아니라**, 같은 증상을 만드는 가장 흔한 패턴입니다.
진단 연습용으로 직접 작성한 `sim/fault_sim.py` 가 이 구조이고,
실측된 거동(일정 기울기 + 자진 종료)이 이 패턴과 일치합니다.

```python
leaked = []                                  # 리스트가 참조를 계속 들고 있다
while True:
    leaked.append(bytearray(4 * 1024 * 1024))  # 4MB 씩 추가, 해제는 없음
```

파이썬은 가비지 컬렉션(GC)이 있어서 "메모리 누수가 없다"고 오해하기 쉽지만,
**GC 는 '아무도 참조하지 않는 객체'만 치웁니다.** 리스트가 붙잡고 있는 한
그 객체는 **살아 있는 것으로 간주**되어 영원히 회수되지 않습니다.
C 언어의 `free()` 누락과 원인은 다르지만 **결과는 같습니다.**

### 3-2. 메모리 구조와 누수가 시스템 전체에 미치는 영향

프로세스 메모리는 크게 네 구역입니다.

| 구역 | 담는 것 | 크기 변화 |
|---|---|---|
| **코드(Text)** | 실행 명령 | 고정 |
| **데이터(Data/BSS)** | 전역·정적 변수 | 고정 |
| **힙(Heap)** | 실행 중 동적 할당 | **위로 자란다 ← 누수가 생기는 곳** |
| **스택(Stack)** | 지역 변수·호출 정보 | 아래로 자란다 |

**한 프로세스의 누수가 왜 시스템 전체 문제인가:**

1. 물리 메모리가 줄어들면 커널이 **스왑(swap)** 을 시작합니다 —
   메모리 내용을 디스크로 내보냅니다. 디스크는 메모리보다 **수만 배 느립니다.**
2. 스왑이 잦아지면 **스래싱(thrashing)** 에 빠집니다. CPU 가 일을 하는 게 아니라
   메모리를 디스크로 옮겼다 가져왔다 하는 데 시간을 전부 씁니다.
   **범인이 아닌 다른 프로세스까지 전부 느려집니다.**
3. 그래도 모자라면 커널의 **OOM Killer** 가 작동해 프로세스를 강제 종료합니다.
   문제는 **OOM Killer 가 범인을 고른다는 보장이 없다**는 점입니다.
   점수 계산상 메모리를 많이 쓰는 프로세스가 선택되므로, 멀쩡한 DB 서버가
   대신 죽을 수 있습니다.

### 3-3. MemoryGuard 가 '먼저' 죽는 이유

이 앱은 커널의 OOM Killer 를 기다리지 않고 **스스로 종료**합니다.

| | OOM Killer | MemoryGuard (앱 자체) |
|---|---|---|
| 누가 죽나 | **커널이 고른 프로세스** (범인이 아닐 수 있음) | **문제를 일으킨 자기 자신** |
| 언제 | 시스템 전체가 이미 위험할 때 | 자기 한도에 닿았을 때 (**더 이름**) |
| 로그 | `dmesg` 에만 남음 | 앱 로그에 **원인까지** 남음 |

**"내 문제는 내가 치운다"** 는 설계입니다. 피해를 자기 선에서 끊고,
로그에 원인을 남겨 추적을 가능하게 합니다.

---

## 4. Workaround & Verification (조치 및 검증)

### 4-1. 조치 내용

환경변수 `MEMORY_LIMIT` 을 **256MB → 512MB** 로 상향했습니다.

```bash
export MEMORY_LIMIT=512
```

### 4-2. Before & After

| | Before (`MEMORY_LIMIT=256`) | After (`MEMORY_LIMIT=512`) |
|---|---|---|
| **결과** | `[CRITICAL]` **자진 종료** | `[WARNING]` → **스스로 정리하고 생존** |
| **생존 시간** | 약 **32초** | 관제 60초 **끝까지 생존** |
| **관제 샘플** | 10개 + `NOT_RUNNING` | **20개, 전부 정상** |
| **MEM 범위** | 1.1% → **6.7%** | 1.1% → **12.9%** |
| **힙 최고점** | 275MB 에서 종료 | 525MB 에서 **정리** |
| **마지막 로그** | `Self-terminating process 7429` | `Memory Cache Flushed. Process Stabilized.` |

```
# Before — 275MB 에서 끊김
09:23:55,395 [INFO]     [MemoryWorker] Current Heap: 275MB
09:23:55,399 [CRITICAL] [MemoryGuard] Memory limit exceeded (275MB >= 256MB) / (Recommend Over 256MB)
09:23:55,399 [CRITICAL] [MemoryGuard] Self-terminating process 7429 to prevent system instability.

# After — 525MB 에서 스스로 비우고 계속 간다
09:25:01,848 [INFO]    [MemoryWorker] Current Heap: 525MB
09:25:01,851 [WARNING] [MemoryWorker] Memory Usage Reached Limit (525MB). Starting cleanup...
09:25:01,900 [INFO]    [System] Memory Cache Flushed. Process Stabilized.
```

**증가 기울기는 Before·After 가 똑같습니다** (약 +0.2%p/초, 힙 기준 8.2MB/s).
달라진 것은 **한도에 닿았을 때 앱이 하는 행동**입니다.

#### 경계값 — 256 과 257 사이에서 갈립니다

한도를 바꿔가며 측정했습니다.

| `MEMORY_LIMIT` | 한도 도달 시 로그 | 결과 |
|---:|---|---|
| 80 | `[CRITICAL] exceeded (100MB >= 80MB)` | 자진 종료 |
| 256 | `[CRITICAL] exceeded (275MB >= 256MB)` | 자진 종료 |
| **257** | `[WARNING] Reached Limit (275MB). Starting cleanup...` | **생존** |
| 384 | `[WARNING] Reached Limit (400MB). Starting cleanup...` | **생존** |
| 512 | `[WARNING] Reached Limit (525MB). Starting cleanup...` | **생존** |
| 1024 | 부트 6단계 `[FAIL] MEMORY_LIMIT too high. Maximum: 512MB` | 기동 실패 |

**257 이상이면 자진 종료가 아니라 정리 경로로 갑니다.**
앱이 종료 직전에 내보내는 `(Recommend Over 256MB)` 가 바로 이 경계를 가리키는
안내였습니다. 유효 범위는 **257 ~ 512** 입니다.

### 4-3. 검증 결과 해석 — 고친 게 아니라 '증상을 가린' 것입니다

처음에는 "한도를 올려 시간을 벌었을 뿐 언젠가 반드시 터진다"고 적었는데,
**실측해 보니 그게 아니었습니다.** 257 이상에서는 앱이 **자체 복구 경로**를 타서
무한히 살아남습니다. 한도 상향은 단순히 시간을 산 게 아니라
**앱 안에 이미 있던 정리 기능을 켠 것**입니다.

그렇다고 해결은 아닙니다. 95초 동안 더 지켜보니 이런 모양이었습니다.

```
00:18:56  Current Heap: 525MB → Starting cleanup...
00:19:01  Current Heap:  25MB      ← 비워짐
00:19:04  Current Heap:  50MB
   ...                             ← 같은 속도로 다시 오른다
00:19:25  Current Heap: 225MB
```

**누수 자체는 그대로 있고, 주기적으로 비우는 톱니파(sawtooth)가 됩니다.**
그래서 남는 문제가 둘입니다.

| 남는 문제 | 왜 문제인가 |
|---|---|
| **정리 중 멈춤** | 525MB 를 한꺼번에 비우는 동안 응답이 끊긴다. 주기적인 지연이 생긴다 |
| **상한이 512** | 한도를 더 올릴 수 없다. 누수 속도가 빨라지면 정리 주기가 짧아져 멈춤이 잦아진다 |

이 조치가 적절한 경우는 **"코드 수정 재배포 전까지 서비스를 유지해야 하는 상황"** 입니다.
근본 원인은 4-4 로 해결해야 합니다.

### 4-4. 근본적 해결 제안

| 우선순위 | 제안 | 설명 |
|---|---|---|
| 1 | **참조 해제** | 처리가 끝난 데이터를 `del` / `pop` 으로 놓아준다. 누적 컨테이너를 쓰지 않는다 |
| 2 | **크기 제한 자료구조** | 꼭 모아야 한다면 `collections.deque(maxlen=N)` 처럼 **상한이 있는** 구조로 |
| 3 | **스트리밍 처리** | 전부 모았다가 처리하지 말고, 한 건씩 읽어 처리하고 버린다 |
| 4 | **모니터링 상시화** | `monitor.sh` 를 cron 에 걸어 **기울기**를 추적. 터진 뒤가 아니라 오르는 중에 알아챈다 |

### 4-5. 재현 방법

```bash
./run.sh up
./run.sh case oom 256    # Before
./run.sh case oom 512    # After
./run.sh diagnose oom    # 증거 수집
```

# [Bug] Memory Leak - 실행 수십 초 후 MemoryGuard 에 의한 자진 종료

> ⚠️ **증거 데이터 출처 안내**
> 아래 수치는 `sim/fault_sim.py`(진단 연습용 시뮬레이터)로 재현한 결과입니다.
> **제출 시에는 코디세이가 배포하는 `agent-app-leak` 바이너리를 실행해 얻은
> 실제 수치로 교체해야 합니다.** 교체할 자리는 `🔄` 로 표시했습니다.
> **3절(원인 분석)과 4절의 OS 동작 원리는 바이너리와 무관하게 그대로 적용됩니다.**

---

## 1. Description (현상 설명)

`agent-leak-app` 을 실행하면 **약 23초 뒤 예고 없이 프로세스가 종료**됩니다.
종료 직전 터미널에 `>>> [SYSTEM] SELF-TERMINATED (Memory Limit Exceeded) <<<`
메시지가 출력됩니다.

| 항목 | 내용 |
|---|---|
| **언제** | 프로세스 기동 후 약 23초 (🔄 실제 바이너리는 약 10분으로 보고됨) |
| **조건** | `MEMORY_LIMIT=256` (MB), 그 외 환경변수는 정상 |
| **재현성** | 100% — 10회 실행 모두 동일 지점에서 종료 |
| **종료 코드** | 137 (= 128 + 9, SIGKILL) |

오류 메시지가 아니라 **애플리케이션이 스스로 종료**했다는 점이 특징입니다.

---

## 2. Evidence & Logs (증거 자료)

### 2-1. monitor.sh 관제 로그 — 메모리 선형 상승 🔄

```
[2026-10-31 06:49:17] PROCESS:fault_sim.py PID:817 CPU:1.0% MEM:1.0% DISK:1% FIREWALL:inactive
[2026-10-31 06:49:20] PROCESS:fault_sim.py PID:817 CPU:1.0% MEM:1.8% DISK:1% FIREWALL:inactive
[2026-10-31 06:49:23] PROCESS:fault_sim.py PID:817 CPU:2.0% MEM:2.5% DISK:1% FIREWALL:inactive
[2026-10-31 06:49:26] PROCESS:fault_sim.py PID:817 CPU:2.0% MEM:3.3% DISK:1% FIREWALL:inactive
[2026-10-31 06:49:29] PROCESS:fault_sim.py PID:817 CPU:1.0% MEM:4.0% DISK:1% FIREWALL:inactive
[2026-10-31 06:49:32] PROCESS:fault_sim.py PID:817 CPU:1.0% MEM:4.8% DISK:1% FIREWALL:inactive
[2026-10-31 06:49:35] PROCESS:fault_sim.py PID:817 CPU:1.0% MEM:5.5% DISK:1% FIREWALL:inactive
[2026-10-31 06:49:38] PROCESS:fault_sim.py PID:817 CPU:1.0% MEM:6.3% DISK:1% FIREWALL:inactive
[2026-10-31 06:49:41] PROCESS:fault_sim.py PID:- CPU:- MEM:- DISK:1% ... STATE:NOT_RUNNING
```

**읽는 법 — 두 가지가 동시에 보입니다.**

| 지표 | 패턴 | 의미 |
|---|---|---|
| **MEM** | 1.0 → 6.3% **단조 증가**, 3초마다 약 +0.75%p | 쓰고 버리는 게 아니라 **계속 쌓인다** |
| **CPU** | 1~2% 로 **안정** | 연산 과부하가 아니다 → **메모리만의 문제** |

> CPU 가 평온한데 MEM 만 오르는 것이 **메모리 누수의 전형적 신호**입니다.
> 만약 둘 다 올랐다면 "일이 몰려서 바쁘다"로 해석할 여지가 있지만,
> 일은 안 하는데 메모리만 먹고 있다면 쌓아두기만 한다는 뜻입니다.

### 2-2. 프로그램 실행 로그 — 종료 직전 구간 🔄

```
[06:49:39.406] [INFO]     [MemoryGuard] rss=253MB / limit=256MB
[06:49:39.829] [INFO]     [MemoryGuard] rss=257MB / limit=256MB
[06:49:39.830] [CRITICAL] [MemoryGuard] Memory limit exceeded (257MB >= 256MB) / (Recommend Over 512MB)
[06:49:39.832] [CRITICAL] [MemoryGuard] Self-terminating process 817 to prevent system instability.
[06:49:39.833] >>> [SYSTEM] SELF-TERMINATED (Memory Limit Exceeded) <<<
```

**핵심 문장은 `Self-terminating process ... to prevent system instability` 입니다.**
외부에서 죽인 것이 아니라 **앱이 자기 상태를 감시하다가 스스로 내린 결정**입니다.

### 2-3. 시스템 도구 출력

```bash
$ grep -E '^(VmRSS|VmSize|VmPeak|Threads):' /proc/<PID>/status
VmRSS:    253184 kB     ← 실제 점유한 물리 메모리
VmSize:   412672 kB     ← 가상 주소 공간(실제로 안 쓰는 것 포함)
VmPeak:   412672 kB
Threads:       1
```

> **`VmRSS` 를 봐야 합니다.** `VmSize` 는 "주소를 예약해 둔 공간"이라 늘 크고,
> 실제로 메모리를 차지하는지와는 다릅니다. 누수 추적은 `VmRSS` 기준입니다.

---

## 3. Root Cause Analysis (원인 분석)

### 3-1. 현상 분석 — 메모리 누수(Memory Leak)

애플리케이션이 생성한 데이터를 **힙(Heap)에서 해제하지 않고 계속 쌓는** 결함입니다.

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

### 4-2. Before & After 🔄

| | Before (256MB) | After (512MB) |
|---|---|---|
| **생존 시간** | 약 **23초** | 약 **49초** |
| **관제 샘플 수** | 8개 | 17개 |
| **MEM 최종** | 6.3% | **12.3%** |
| **종료 로그** | `(257MB >= 256MB)` | `(514MB >= 512MB)` |
| **결과** | SELF-TERMINATED | **SELF-TERMINATED (동일)** |

```
# After 관제 로그 발췌
[06:49:49] ... MEM:1.0%
[06:50:11] ... MEM:6.3%      ← Before 가 죽었던 지점을 그대로 통과
[06:50:35] ... MEM:12.3%
[06:50:42] ... STATE:NOT_RUNNING
```

**생존 시간이 약 2배로 늘었고, 한도도 정확히 2배였습니다.**
증가 기울기(약 +0.25%p/초)는 **Before 와 After 가 동일**합니다.

### 4-3. 검증 결과 해석 — 이건 해결이 아닙니다

> **한도를 올린 것은 시간을 산 것이지 문제를 고친 것이 아닙니다.**
> 메모리는 **같은 속도로** 계속 오르고, 종료 시점만 뒤로 밀렸습니다.
> 한도를 아무리 올려도 **언젠가는 반드시 터집니다.** 오히려 한도가 크면
> 터질 때 시스템에 주는 충격이 더 큽니다.

이 조치가 유효한 경우는 **"재배포 전까지 버텨야 하는 긴급 상황"** 뿐입니다.

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

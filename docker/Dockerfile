# Ubuntu 22.04 — 장애 분석 실습 환경
#
# 과제 6절이 "로컬 또는 격리된 환경(Docker 컨테이너 등)에서 실행을 권장"한다.
# 메모리를 일부러 터뜨리고 CPU 를 일부러 태우는 실습이라, 격리하지 않으면
# 내 노트북이 같이 느려지거나 멈춘다. 컨테이너 안이면 피해가 그 안에서 끝난다.
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Seoul

RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 procps psmisc htop ufw sudo iproute2 net-tools \
      ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/agent-triage
COPY bin/   /opt/agent-triage/bin/
COPY sim/   /opt/agent-triage/sim/
COPY setup.sh /opt/agent-triage/setup.sh
RUN chmod +x /opt/agent-triage/bin/*.sh /opt/agent-triage/setup.sh

CMD ["sleep", "infinity"]

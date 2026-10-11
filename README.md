# AI Usage & System Monitor

macOS 메뉴바에서 Codex, Claude Code 사용량을 확인하는 앱입니다.

SSH로 연결한 서버의 GPU, CPU, RAM도 확인할 수 있습니다.

## 설치 및 실행

```bash
git clone https://github.com/gn1793/AI-Usage-System-Monitor.git
cd AIUsageSystemMonitor

./scripts/build.sh
./scripts/install.sh
```

## 사용 방법

- 메뉴바의 고양이 아이콘을 클릭합니다.
- AI 사용량은 로그인된 계정에서 가져옵니다.
- 서버는 SSH 설정 후 앱에서 추가하면 됩니다.

**참고:** 원격 서버에 Python 3가 필요합니다. NVIDIA GPU 모니터링에는 `nvidia-ml-py`도 필요합니다.
# AI Usage & System Monitor

Codex·Claude Code 사용량, OpenAI API 크레딧과 SSH 서버의 CPU·RAM·NVIDIA GPU를 확인하는 macOS 메뉴바 앱입니다.

## 설치

macOS 26 이상과 Apple Command Line Tools가 필요합니다.

```bash
git clone https://github.com/gn1793/AI-Usage-System-Monitor.git
cd AI-Usage-System-Monitor
./scripts/build.sh
./scripts/install.sh
```

## 사용

- 메뉴바의 고양이 아이콘으로 대시보드를 열고, Settings에서 설정합니다.
- **Codex·Claude Code:** 로그인된 계정의 사용량을 5분마다 갱신합니다.
- **OpenAI API:** Brave에서 [Credit Grants](https://platform.openai.com/settings/organization/billing/credit-grants)에 로그인한 뒤, 대시보드 상단 새로고침 버튼으로 수동 조회합니다.
- Brave의 **보기 → 개발자 → Apple Events의 자바스크립트 허용**과 macOS의 Brave 제어 권한이 필요합니다.
- **SSH 서버:** Settings에서 추가합니다. 서버에 Python 3가 필요하며, NVIDIA GPU 조회에는 `nvidia-ml-py`도 필요합니다.

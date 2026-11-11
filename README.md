# AI Usage & System Monitor

macOS 메뉴바에서 OpenAI API 크레딧과 Codex, Claude Code 사용량을 확인하는 앱입니다.

SSH로 연결한 서버의 GPU, CPU, RAM도 확인할 수 있습니다.

## 설치 및 실행

```bash
git clone https://github.com/gn1793/AI-Usage-System-Monitor.git
cd AI-Usage-System-Monitor

./scripts/build.sh
./scripts/install.sh
```

## 사용 방법

- 메뉴바의 고양이 아이콘을 클릭합니다.
- AI 사용량은 로그인된 계정에서 가져옵니다.
- 서버는 SSH 설정 후 앱에서 추가하면 됩니다.

### OpenAI API 크레딧

기본 방식은 **Brave · Credit Grants**입니다. 필요할 때 Brave에서 [Credit Grants](https://platform.openai.com/settings/organization/billing/credit-grants)에 로그인한 뒤, 대시보드 **Every 5 minutes 옆 새로고침 버튼**을 누르면 실제 잔액·총액·만료일을 읽습니다. API 키나 금액·기간을 입력할 필요가 없습니다. 기존에 다른 방식을 설정했다면 Settings → **OpenAI API credits**에서 **Brave · Credit Grants**를 선택하고 **Connect & refresh**를 누릅니다.

Brave 메뉴의 **보기 → 개발자 → Apple Events의 자바스크립트 허용**을 켜야 합니다. macOS가 Brave 제어 권한을 요청하면 허용합니다(시스템 설정 → 개인정보 보호 및 보안 → 자동화). 사용자가 새로고침을 누르면 해당 탭을 새로고침하고 USD 크레딧 표만 읽으며 쿠키나 로그인 토큰을 추출하지 않습니다. Billing에서 선택한 조직의 값을 사용합니다. Credit Grants 탭이 여러 개라면 모니터링할 탭을 선택해 두거나 다른 탭을 닫습니다.

Codex·Claude Code는 5분마다 자동 갱신하지만 **OpenAI 크레딧은 수동으로만 조회**합니다. 앱 시작, 잠자기 해제, 주기 갱신은 브라우저에 접근하지 않습니다. 마지막 성공값과 조회 시각을 로컬에 저장하며, 재실행하거나 값이 오래되면 **Last known**으로 표시합니다. 조회하지 않은 값을 현재 잔액으로 표시하지 않습니다.

사용 가능한 크레딧만 합산하며 여러 크레딧이 있으면 다음 만료일과 각 크레딧의 상세값을 표시합니다. 웹페이지가 날짜만 표시하므로 정확한 만료 시각을 추측하지 않고 Billing의 Available/Expired 상태를 따릅니다. 브라우저가 닫히거나 로그인이 만료되면 마지막 값과 재연결 안내를 표시합니다. 웹페이지 구조에 의존하므로 페이지가 변경되면 파서 수정이 필요할 수 있습니다.

대시보드에는 잔여 크레딧, 총액, 사용액, 소비 비율, 만료일까지 남은 기간과 Billing 버튼이 표시됩니다. 다른 방식도 설정에서 선택할 수 있습니다.

- **Estimated (Costs API)**: Billing의 총 크레딧, 적용 시작일과 만료일을 입력합니다. 컴퓨터에 저장된 조직의 [Admin API key](https://platform.openai.com/settings/organization/admin-keys)를 자동으로 불러오며, **Detect again**으로 다시 찾을 수 있습니다. 수동 새로고침 시 선택한 기간의 [Costs API](https://developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/usage/methods/costs) 비용을 조회해 총 크레딧에서 차감합니다. 조직 ID는 선택 사항입니다.
- **Manual balance**: 관리자 키 없이 Billing에서 확인한 잔여 크레딧을 직접 입력합니다. 입력한 잔액은 수정할 때까지 유지됩니다.

자동 감지는 이 앱의 Keychain → `OPENAI_ADMIN_KEY`/`OPENAI_API_KEY` 환경 변수와 macOS 로그인 환경 → 셸 설정(`.zshrc`, `.zprofile`, `.zshenv`, `.bashrc`, `.bash_profile`, `.profile`) → Codex 인증 파일(`CODEX_HOME/auth.json`, `~/.codex/auth.json`, `~/.config/codex/auth.json`, `~/.codex-api/auth.json`)과 Codex Keychain 순서로 확인합니다. 셸 설정은 키의 리터럴 대입만 읽고 실행하지 않습니다. `OPENAI_API_KEY`와 Codex 인증 파일의 일반 키는 관리자 키 형식(`sk-admin-`)인 경우에만 비용 조회에 사용합니다. 키 값은 화면에 표시하지 않습니다. 직접 지정하려면 **Use a different Admin API key (optional)**을 펼쳐 입력할 수 있으며 macOS Keychain에 저장됩니다.

Costs API의 잔액은 **Estimated**로 표시됩니다. 이 방식은 크레딧 원장을 직접 조회하지 않으며, 비용 반영 지연이나 여러 크레딧의 중복 적용, 결제 조정에 따라 Billing의 실제 잔액과 다를 수 있습니다. 일반 API 키나 Codex의 ChatGPT 로그인은 비용 조회용 관리자 인증을 대신할 수 없습니다. 감지는 키의 위치와 형식 확인이며, 실제 접근 권한은 조회 시 확인합니다. 조회 실패 시 마지막 조회값과 오류를 표시하고, 만료된 크레딧은 잔액을 0으로 표시합니다. 새 크레딧을 받으면 설정에서 금액과 기간을 갱신합니다.

**Clear credit settings**는 크레딧 연동을 해제합니다. 저장된 키는 Costs API 설정의 **Remove saved key**로 별도 삭제할 수 있습니다.

크레딧 계산과 조회 오류 처리 테스트는 `bash scripts/test-credits.sh`로 실행합니다. 실제 API 호출이나 Keychain 변경 없이 검증합니다.

**참고:** 원격 서버에 Python 3가 필요합니다. NVIDIA GPU 모니터링에는 `nvidia-ml-py`도 필요합니다.

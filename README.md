# UsageBar

*English: UsageBar is a macOS menu bar app that shows the remaining Claude Code and Codex subscription limits, when they reset, and how much a work session consumed. The interface is available in English and Korean and follows your system language. It uses the CLI logins already on your Mac and never asks for passwords or API keys.*

<img src="docs/images/overview-en.jpg" width="360" alt="UsageBar panel in English: 5-hour limit gauge, reset time, and work log row" />

Claude와 Codex의 남은 한도를 메뉴 막대에서 확인하고, 작업을 마칠 때 한도 변화를 영수증으로 남기는 macOS 앱입니다. 화면 상단의 **U 아이콘**을 누르면 됩니다.

- **한도 게이지**: 남은 비율을 큰 숫자와 세그먼트 바로, 리셋 시각과 함께 봅니다.
- **작업 기록**: **작업 시작**에서 유형을 고르면 바로 시작하고, 끝낼 때 한도 변화를 영수증으로 남깁니다.
- **사용 기록**: 한도 변화 추이와 Codex 일별 토큰을 보고 CSV로 내보냅니다.

<img src="docs/images/overview-dark.jpg" width="360" alt="UsageBar 다크 모드: Claude 잔여 한도 게이지와 리셋 시간, 작업 기록 행" />

<details>
<summary>다른 화면 보기 (Codex 패널 · 작업 영수증 · 사용 기록 · 설정)</summary>

<img src="docs/images/overview-codex.jpg" width="360" alt="Codex 패널: 한도 게이지, 초기화권 수와 만료, 최근 일별 토큰" />
<img src="docs/images/work-receipt.jpg" width="520" alt="작업 영수증 창: 작업 유형 선택과 시작, 소요 시간과 한도 변화 목록" />
<img src="docs/images/history.jpg" width="720" alt="사용 기록 창: 한도 변화 차트와 기간 선택, CSV 내보내기" />
<img src="docs/images/settings.jpg" width="500" alt="설정 창: 일반, 메뉴 막대, 알림, 연결 섹션" />

모든 스크린샷은 예시 데이터입니다.
</details>

## 설치

macOS 14 이상, Apple Silicon. 저장소가 공개되기 전까지는 다운로드가 제공되지 않습니다.

1. [Releases](https://github.com/hyjoong/UsageBar/releases)에서 `UsageBar-버전-빌드.zip`을 받습니다. GitHub가 자동으로 붙이는 **Source code**는 설치 파일이 아닙니다.
2. 압축을 풀고 `UsageBar.app`을 **응용 프로그램** 폴더로 옮긴 뒤 엽니다.
3. 메뉴 막대의 U 아이콘을 누릅니다. 별도 창이나 Dock 아이콘은 뜨지 않습니다.

새 버전은 설정 → 앱 정보 → **업데이트 확인…**으로 설치합니다. 설정과 기록은 유지됩니다. 소스에서 빌드하려면 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)를 보세요.

## 처음 연결하기

UsageBar는 이 Mac에 설치된 **Claude Code·Codex CLI의 로그인 상태**를 그대로 사용합니다. 비밀번호나 API 키를 입력하지 않습니다. 처음 실행하면 패널이 연결 단계를 번호 순서로 안내하고, 한 서비스만 쓴다면 **…만 사용할게요** 링크로 다른 서비스 조회를 끌 수 있습니다.

- **Claude**: Claude Code CLI를 설치한 뒤 패널의 **연결 설정 열기**를 누르면 터미널이 열립니다. 초기 설정과 구독 계정 로그인을 마치고 UsageBar에서 **다시 확인**을 누릅니다. 필요하면 Claude 안에서 `/login`, `/usage`로 상태를 확인하세요.
- **Codex**: Codex CLI를 설치하고 터미널에서 `codex login`으로 ChatGPT 구독 계정에 로그인한 뒤 **다시 확인**을 누릅니다. API 키 계정의 요금은 지원하지 않습니다.

<details>
<summary>첫 연결 화면 보기</summary>
<img src="docs/images/connect.jpg" width="360" alt="Claude 연결하기: 설치, 터미널 로그인, 돌아와서 확인의 3단계 안내" />
</details>

## 사용법

| 하고 싶은 일 | 조작 |
| --- | --- |
| 남은 한도 확인 | U 아이콘을 누릅니다. 큰 숫자는 5시간 한도의 잔여율이고, 주간 등 다른 한도는 아래에 이어집니다. |
| 메뉴바에 표시할 한도 변경 | 기본은 5시간 한도입니다. 설정 → 메뉴 막대 → **Claude 메뉴 막대 한도**에서 바꿉니다. |
| Claude·Codex 함께 표시 | 설정 → 메뉴 막대 → **표시할 서비스** → **사용 중인 서비스 모두**. 메뉴바에 서비스 아이콘(✱ Claude, ▭ Codex)과 잔여율이 나란히 보입니다. |
| 패널을 창으로 띄우기 | ⋯ 메뉴 → **창으로 열기**. 다른 창 위에 떠 있어 긴 작업 중에도 보입니다. |
| 작업 기록 | **작업 시작**에서 유형을 고르면 현재 한도를 확인하고 시작합니다. 종료하면 소요 시간과 한도 변화 영수증이 남고, **전체 기록**에서 복사·삭제할 수 있습니다. |
| 사용량 변화 확인·내보내기 | 하단 기록 아이콘 → 서비스·기간·한도를 고르고 **CSV 내보내기**. |
| 새로고침·설정 | `⌘R`로 새로고침, `⌘,`로 설정. 사용량은 5분마다 자동 확인합니다. |
| 로그인 시 실행·알림 | 설정 → **로그인 시 UsageBar 실행**, **남은 한도가 20% 아래로 내려가면 알림**. |

**영수증 읽는 법**: 숫자는 관측 구간의 **계정 전체 사용률 변화**(%p)입니다. 다른 창·기기의 사용도 포함되며 특정 프로젝트의 토큰 수나 비용이 아닙니다. 리셋 통과, 계정·플랜 변경 등으로 비교할 수 없으면 사유를 표시합니다. 종료 조회가 실패하면 **한도 비교 없이 종료**로 시간만 남길 수 있습니다.

**게이지 읽는 법**: 세그먼트 바는 현재 남은 한도를 5% 단위로 나타냅니다. 20% 이하면 노란색, 조회가 오래됐으면 회색이고 **이전 기록**이라고 표시합니다. 리셋 시각이 지나도 새 조회가 성공하기 전에는 100%로 바꾸지 않습니다.

## 문제가 생겼을 때

| 증상 | 확인할 내용 |
| --- | --- |
| 창이 안 보여요 | 메뉴바 앱입니다. 상단 U 아이콘을 찾으세요. 메뉴바가 꽉 차면 macOS가 노치 아래 아이템을 숨기므로, 제어 센터 항목을 줄이거나 메뉴바 정리 앱을 쓰세요. 아이콘이 안 보여도 UsageBar를 다시 실행하면 패널 창이 열립니다. |
| CLI를 찾지 못해요 | 해당 CLI가 설치됐는지 확인합니다. Claude는 `~/.local/bin`, Homebrew, `/usr/local/bin`, `PATH` 순으로 찾습니다. |
| 로그인이 필요하다고 나와요 | 터미널에서 해당 CLI 로그인을 마친 뒤 **다시 확인**을 누릅니다. |
| 이전 기록·조회 오류가 보여요 | 마지막 성공값입니다. 인터넷과 CLI 로그인 상태를 확인한 뒤 새로고침하세요. ⋯ 메뉴에서 서비스 장애 현황을 열 수 있습니다. |
| 새로고침이 잠겨 있어요 | 서비스가 요청을 제한한 상태입니다. 안내된 시간까지 기다려 주세요. |

## 개인정보

- 각 CLI의 기존 로그인을 사용하며 비밀번호·API 키·토큰을 입력받거나 저장하지 않습니다.
- 사용량 기록과 작업 영수증은 `~/Library/Application Support/UsageBar/`에만 저장됩니다. 대화 내용, 프로젝트 파일, CLI 원문 응답은 저장하지 않습니다.
- 구독 종료일·결제액·프로젝트별 비용은 표시하지 않으며 초기화권을 소비하는 기능도 없습니다.

표시 항목과 저장 파일의 상세는 [docs/PRIVACY.md](docs/PRIVACY.md)에 있습니다.

## 개발

```sh
swift build && swift test
swift run UsageBar --demo
```

소스 빌드, 화면 확인 옵션, 앱 내 업데이트 동작은 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md), 배포·공증 절차는 [docs/RELEASING.md](docs/RELEASING.md), 디자인 참고는 [docs/DESIGN.md](docs/DESIGN.md), 변경 이력은 [CHANGELOG.md](CHANGELOG.md)에 있습니다.

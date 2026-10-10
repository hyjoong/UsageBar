# UsageBar

Claude를 기본으로 보여주는 macOS 메뉴 막대 앱입니다. 실행하면 화면 상단에 그래프 아이콘과 남은 한도가 표시됩니다. 아이콘을 클릭하면 Reset Timeline이 열리고, 바깥을 클릭하면 닫힙니다. 사용 기록과 설정은 필요한 때 별도 창으로 엽니다.

macOS 14 이상에서 실행합니다. SwiftUI·AppKit·Swift Charts와 Swift Package Manager를 사용하며 외부 패키지 의존성은 없습니다. 빌드에는 Swift 5.10 이상을 지원하는 macOS 개발 도구가 필요합니다.

**0.2에서 추가한 기능**

- 설정의 **메뉴바 표시 → Claude + Codex**로 두 서비스의 잔여율을 함께 봅니다. 기본값은 선택한 서비스이며, 기존 선택을 유지합니다.
- 팝오버에서 한도 이름 옆 **핀**을 누르면 그 한도를 메뉴바와 첫 번째 게이지에 표시합니다. 선택은 서비스별로 기억하고, 첫 실행에는 가장 짧은 한도를 선택합니다.
- **사용 속도**는 마지막 조회 시점의 기간 경과율과 실제 한도 사용률을 비교합니다. 기간과 리셋 시간이 확인되는 최근 기록에만 표시하며, 균등 사용 기준의 비교값입니다.
- 기록 화면에서 서비스·기간·한도를 골라 **CSV 내보내기**로 현재 범위의 수치를 저장합니다. 기록 화면의 서비스 선택은 메뉴바 선택에 영향을 주지 않습니다. Claude의 일별 토큰 기록은 아직 지원하지 않습니다.
- **로그인 시 실행** 옵션을 추가했습니다. 사용자가 켜야 등록하며, macOS 승인이 필요하면 설정에서 안내합니다.
- 오래된 기록·조회 실패·리셋 시각 경과를 구분합니다. 화면 시각은 매분 갱신하고, 리셋이 지난 한도는 기존 요청 간격과 재시도 제한을 지키며 다시 확인합니다.

**빌드와 실행**

프로젝트 폴더에서 실행합니다.

```sh
zsh scripts/build-app.sh
open build/UsageBar.app
```

기본은 release 빌드입니다. `zsh scripts/build-app.sh debug`로 디버그 앱을 만들 수 있습니다. 결과물은 개인 사용을 위한 ad hoc 서명 앱이며, Developer ID 서명이나 공증을 거친 배포본은 아닙니다.

**처음 연결할 때**

Claude Code CLI를 설치한 뒤 앱에서 **Claude 연결 설정**을 누릅니다. 터미널이 열리면 초기 설정과 구독 계정 로그인을 마쳐 주세요. 연결 전용 폴더는 `~/Library/Application Support/UsageBar/ClaudeConnection`입니다.

Claude 안에서 필요한 경우 `/login`을 실행하고, `/usage`에 사용량이 표시되는지 확인하세요. 화면 스타일·약관·폴더 확인이 나타나면 직접 내용을 확인하고 진행합니다. 설정을 마친 뒤 터미널 창을 닫고 앱에서 **다시 확인**을 누릅니다. 연결 설정과 조회에는 확장 기능·도구·사용자 훅을 끈 CLI 실행 옵션을 사용합니다.

Codex는 설치된 CLI와 기존 ChatGPT 로그인을 사용합니다. 터미널의 `codex --version`으로 CLI가 보이는지 확인할 수 있습니다. API 키로만 로그인한 계정의 청구 정보는 지원하지 않습니다. 두 CLI는 `PATH`와 일반적인 설치 위치에서 찾습니다.

**표시하는 정보**

| 서비스 | 지원 범위 | 제한 |
| --- | --- | --- |
| Claude | CLI `/usage`에 표시되는 현재 세션·주간·모델 범위별 한도와 초기화 정보 | CLI 화면 형식에 의존합니다. 날짜를 해석하지 못하면 확인 가능한 원문 초기화 안내를 보여줍니다. 일별 토큰 기록은 제공하지 않습니다. |
| Codex | App Server가 반환한 한도별 사용률·기간·초기화 시각, 저장된 초기화권 개수와 만료일, 일별 토큰 기록 | CLI 버전과 계정 응답에 따라 일부 항목이 없을 수 있습니다. 초기화권 상세가 없어도 개수는 표시할 수 있습니다. |

미제공 값은 0으로 바꾸지 않습니다. 구독 종료일·다음 결제일·실제 청구액·프로젝트별 비용은 표시하지 않습니다. 초기화권 소비 기능도 없습니다. 기록 화면의 한도 변화는 앱이 실행되며 수집한 표본이며, Codex의 일별 토큰 기록과는 별개입니다.

**조회 방식과 저장 정보**

Claude는 기존 로그인 상태로 CLI의 `/usage`를 실행하고, Codex는 전용 자식 프로세스의 stdio 연결에서 `account/read`, `account/rateLimits/read`, `account/usage/read`를 읽습니다. UsageBar는 모델 작업을 요청하지 않으며 OAuth 엔드포인트나 Keychain을 직접 읽지 않습니다. 인증과 갱신은 각 CLI가 관리합니다.

사용률·초기화 시각·플랜 등 표시용 메타데이터는 다음 파일에 저장됩니다.

```text
~/Library/Application Support/UsageBar/usage-cache.json
```

한도 변화 표본은 최근 30일 범위, 전체 최대 60,000개·일별 최대 2,500개로 관리하며, 마지막 성공 조회 결과도 캐시합니다. 계정 구분에는 해시된 식별자를 사용합니다. 원본 이메일·인증 토큰·대화 내용·CLI 원문 응답은 저장하지 않습니다. 계정 변경을 식별하면 해당 서비스의 이전 변화 기록을 분리합니다. CSV에는 선택한 범위의 날짜·한도 이름·수치만 포함합니다.

**개발과 화면 확인**

```sh
swift build
swift test
swift run UsageBar --demo
```

`--demo`는 예시 데이터를 메뉴 막대에 표시합니다. CLI 조회와 사용 기록 캐시 접근 없이 화면을 확인할 수 있습니다. 일반 실행에서는 실제 계정을 조회합니다. 화면 확인용 독립 창과 `--preview` 옵션은 제거했습니다.

개발용 debug 빌드에서는 `--demo --ui-check`로 팝오버 검증 창, `--demo --ui-settings` 또는 `--demo --ui-history`로 보조 창을 열 수 있습니다. 이 검증용 진입점은 release 빌드에 포함되지 않습니다.

- `Sources/UsageBar`: 메뉴 막대·타임라인·설정·기록 화면과 갱신 상태 관리.
- `Sources/UsageBarCore`: CLI 연결, 응답 파싱, 공통 모델, 로컬 기록 저장.
- `Tests/UsageBarCoreTests`: 파서 경계 사례, 가짜 CLI 프로세스, 취소·시간 제한·기록 분리 검증.
- `Resources`: 앱 정보와 네이티브 아이콘. 빌드 스크립트는 포함된 `AppIcon.icns`를 재사용합니다.

2026-10-10 개발 환경에서 Claude Team과 Codex 실제 조회를 확인했습니다. 0.2의 예시 화면에서 한도 고정·동시 표시 선택·기록 선택 분리·CSV 파일 저장을 검증했습니다. 설치된 CLI의 출력이나 프로토콜이 바뀌면 연결 코드를 조정해야 할 수 있습니다.

**참고한 문서와 화면**

- [Claude Code 인터랙티브 모드](https://code.claude.com/docs/en/interactive-mode): CLI 동작과 사용자 설정 확인.
- [Codex App Server](https://learn.chatgpt.com/docs/app-server): stdio 프로토콜과 계정·사용량 응답.
- [SwiftUI MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra): 네이티브 메뉴 막대 구성.
- [CodexBar](https://github.com/steipete/CodexBar): 여러 서비스의 한도를 간결하게 보여주는 메뉴 막대 UI 참고.
- [ClaudeBar](https://github.com/kemalasliyuksek/ClaudeBar): 로그인 시 실행, 표시 설정, 연결 상태를 확인하는 흐름 참고.
- [PokeTokenBar](https://github.com/chattymin/PokeTokenBar/blob/main/README.ko.md): 메뉴바 표시 항목과 리셋 카운트다운을 쉽게 확인하는 흐름 참고.
- [tddworks/ClaudeBar](https://github.com/tddworks/ClaudeBar): 서비스별 한도를 모아 보는 구성 참고.

사용 속도 계산, CSV 내보내기, 상태 처리 코드는 이 프로젝트에서 직접 구현했습니다. 참고 앱의 인증 방식이나 계정 데이터 수집 코드를 가져오지 않았습니다.

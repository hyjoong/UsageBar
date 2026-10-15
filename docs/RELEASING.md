# 배포와 검증 기록

배포자를 위한 문서입니다. 일반 사용 안내는 [README](../README.md)에 있습니다.

## 배포 준비

**배포 대상은 기존 `hyjoong/UsageBar` 저장소입니다.** 별도의 바이너리 저장소를 만들지 않고, 최종 검증 후 현재 저장소 전체를 public으로 전환할 예정입니다. 그전에는 저장소와 릴리스 초안을 비공개로 유지합니다.

- 운영 appcast: `https://github.com/hyjoong/UsageBar/releases/latest/download/appcast.xml`
- 운영 Ed25519 키: Keychain 계정 `hyjoong.UsageBar.production`. 앱의 `SUPublicEDKey`에는 공개 키만 포함합니다.
- **0.8.9 (27)**: 패널 하단의 톱니바퀴 메뉴와 2026-10-12의 Claude CLI 연결·로그인 복구 수정을 담아 2026년 10월 13일 서명·공증(`Accepted`)·검증하고 `v0.8.9` 릴리스의 파일을 교체했습니다. 먼저 게시한 빌드 26은 다른 세션이 같은 날 push한 `e76558e`보다 앞선 트리에서 만들어져 `git pull --rebase` 뒤 push된 커밋과 내용이 달랐고, 태그 `v0.8.9`도 리베이스 전 커밋(`c516383`)을 가리켰습니다. 전체 트리로 빌드 27을 다시 만들어 ZIP·appcast를 교체(`gh release delete-asset`, `upload --clobber`)하고 태그를 릴리스 커밋 `21eaabf`로 옮겼습니다(`git tag -f`, `push -f origin v0.8.9`). 공개 주소의 ZIP 체크섬(`9661f68e…`)과 `releases/latest` appcast의 빌드 27이 일치하고, cask를 `0.8.9,27`로 갱신해 `brew fetch`·`audit`·`style`을 통과했으며, 같은 ZIP을 이 Mac에 설치해 Gatekeeper(`Notarized Developer ID`)를 확인했습니다. 테스트 163개 통과. 로그인 복구 카드는 새 데모 플래그 `--ui-auth-required`로 Claude(이전 기록 위)·Codex(첫 조회)를 한국어·영어로 렌더링해 확인했습니다. 빌드 26 설치본은 자동 업데이트로 27을 받습니다.
- **0.8.8 (25)**: 리셋을 지난 세션의 추정값(리셋 전 마지막 조회값 + 새 기간 사용률)을 담아 2026년 10월 11일 서명·공증(`Accepted`)·검증하고 `v0.8.8`을 최신 릴리스로 게시했습니다. 공개 주소의 ZIP·appcast 체크섬이 일치하고 cask를 `0.8.8,25`로 갱신했으며, 같은 ZIP을 이 Mac에 설치했습니다. 추정 규칙은 단위 테스트 2개로 검증했습니다(총 152개).
- **0.8.7 (24)**: 영수증 카드 재설계(한도 변화 헤드라인, 게이지의 소모 조각, 비교 불가 시 토큰 헤드라인)를 담아 2026년 10월 11일 서명·공증(`Accepted`)·검증하고 `v0.8.7`을 최신 릴리스로 게시했습니다. 공개 주소의 ZIP·appcast 체크섬이 일치하고 cask를 `0.8.7,24`로 갱신했으며, 같은 ZIP을 이 Mac에 설치했습니다.
- **0.8.6 (23)**: 영수증의 모델·토큰·프로젝트 상세(이 Mac의 Claude Code·Codex 세션 기록 집계)를 담아 2026년 10월 11일 서명·공증(`Accepted`)·검증하고 `v0.8.6`을 최신 릴리스로 게시했습니다. 공개 주소의 ZIP·appcast 체크섬이 일치하고 cask를 `0.8.6,23`으로 갱신했으며, 같은 ZIP을 이 Mac에 설치했습니다. 집계 규칙은 단위 테스트 5개로, 실제 로그에서는 이 Mac의 최근 7분 세션(호출 16회, 출력 23K)으로 미리 확인했습니다.
- **0.8.5 (22)**: 핫픽스. 0.8.4에서 작업 기록 중 메뉴바 라벨 안의 `TimelineView(.periodic(from: .now))`가 MenuBarExtra 라벨 갱신과 맞물려 무한 재렌더링(메인 스레드 99% CPU)을 일으키는 것을 이 Mac에서 `sample`로 확인했습니다. 라벨이 앱의 1분 시계를 쓰도록 고치고, 같은 조건(활성 세션)의 데모 번들에서 CPU 0%를 확인한 뒤 2026년 10월 11일 서명·공증(`Accepted`)·게시했습니다. cask `0.8.5,22`. 교훈: MenuBarExtra 라벨은 매 갱신마다 이미지로 렌더링되므로 라벨 안에 스스로 갱신을 예약하는 뷰를 두지 않습니다.
- **0.8.4 (21)**: 작업 기록 중 메뉴바 표시와 종료 버튼이 달린 알림(시작 2시간 뒤·리셋 10분 전)을 담아 2026년 10월 11일 서명·공증(`Accepted`)·검증하고 `v0.8.4`를 최신 릴리스로 게시했습니다. 공개 주소의 ZIP·appcast 체크섬이 일치하고 cask를 `0.8.4,21`로 갱신했습니다. 알림 예약 계획은 단위 테스트로, 알림의 종료 버튼 흐름은 `workReminderCheckInMinutes` 덮어쓰기로 실제 앱에서 확인하는 것을 권합니다(docs/DEVELOPMENT.md).
- **0.8.3 (20)**: 언어 설정(시스템·한국어·English)과 다시 실행 버튼을 담아 2026년 10월 11일 서명·공증(`Accepted`)·검증하고 `v0.8.3`을 최신 릴리스로 게시했습니다. 공개 주소의 ZIP·appcast 체크섬이 일치하고 cask를 `0.8.3,20`으로 갱신했습니다. 다시 실행 순서(이전 프로세스 종료 대기 → open)는 데모 번들에서 새 PID로 재기동되는 것을 확인했습니다.
- **0.8.2 (19)**: 낮았던 한도의 리셋 알림을 담아 2026년 10월 11일 서명·공증(`Accepted`)·검증하고 `v0.8.2`를 최신 릴리스로 게시했습니다. 공개 주소에서 받은 ZIP·appcast가 로컬 체크섬과 일치하고, `hyjoong/homebrew-tap`의 cask를 `0.8.2,19`로 갱신했습니다. 이 Mac의 설치본 0.8.1(18)에서 설정 → 앱 정보 → 업데이트 확인으로 0.8.2(19)를 내려받아 설치·재실행하는 앱 내 업데이트를 처음으로 실전 검증했습니다. 교체된 앱의 서명·공증 티켓·Gatekeeper가 유효하고, 설정과 사용량 기록이 유지됐습니다.
- **공개 (2026년 10월 11일)**: 기본 브랜치를 `main`으로 바꾼 뒤 저장소와 `hyjoong/homebrew-tap`을 public으로 전환하고 `v0.8.1`(빌드 18)을 최신 릴리스로 게시했습니다. 익명으로 내려받은 ZIP·appcast가 로컬 체크섬과 일치하고 `releases/latest/download/appcast.xml`이 빌드 18을 가리키며, `brew install --cask hyjoong/tap/usagebar`로 설치한 앱이 Gatekeeper를 통과했습니다. 이전 빌드 17을 자동 확인 옵션으로 실행했을 때 Sparkle의 마지막 확인 시각이 게시 직후로 갱신되어 공개 피드 조회가 이뤄졌음을 확인했습니다. 업데이트 설치 대화상자까지의 흐름은 사용자가 설정 → 앱 정보 → 업데이트 확인으로 직접 확인하는 것이 남아 있습니다.
- **0.8.1 (18)**: 패널 메인 한도 고정·핀 제거를 반영해 2026년 10월 11일 다시 서명·공증(`Accepted`)·검증했습니다. `v0.8.1` 초안의 빌드 17 자산을 빌드 18 ZIP·appcast로 교체했고 다시 내려받은 파일이 로컬 체크섬과 일치합니다. 같은 ZIP을 이 Mac의 응용 프로그램 폴더에 설치했습니다.
- **0.8.1 (17)**: 메뉴바가 꽉 차 아이콘이 노치에 가려지는 환경에서 앱 재실행으로 패널 창을 여는 수정을 넣어 2026년 10월 11일 다시 서명·공증(`Accepted`)·검증했습니다. `v0.8.1` 초안의 빌드 16 자산을 빌드 17 ZIP·appcast로 교체했고 다시 내려받은 파일이 로컬 체크섬과 일치합니다. 이 Mac(14형 MacBook Pro, 노치 x 663~848pt)에서 아이콘이 x 844~913pt에 배치되어 숨겨지는 것을 확인했고, 재실행으로 창이 열리는 것을 검증했습니다.
- **0.8.1 (16)**: 리뷰 수정(지역화 누락·알림 버튼 문구·로그인 상태 문구 복원 등)을 반영해 2026년 10월 11일 다시 서명·공증(`Accepted`)·검증하고 `build/releases/0.8.1-16/`에 산출물을 만들었습니다. `v0.8.1` 초안의 빌드 15 자산을 삭제하고 빌드 16 ZIP·appcast로 교체했으며, 다시 내려받은 파일이 로컬 체크섬과 일치합니다. 같은 ZIP을 이 Mac의 응용 프로그램 폴더에 설치해 실제 계정으로 실행했습니다.
- **0.8.1 (15)**: 2026년 10월 11일 Developer ID 서명, Apple 공증 `Accepted`, 티켓 첨부·검증, Gatekeeper `Notarized Developer ID`를 확인하고 `build/releases/0.8.1-15/`에 ZIP·서명된 appcast·SHA256SUMS를 생성했습니다. `v0.8.1` 비공개 릴리스 초안에 올린 뒤 다시 내려받은 파일이 로컬 체크섬과 일치하는 것을 확인했습니다. 초안에서 내려받은 ZIP에 다운로드 격리 표시를 적용한 복사본으로 Gatekeeper `accepted`·티켓 검증·예시 모드 실행도 확인했습니다. 0.8.0 초안은 0.8.1로 대체되어 삭제했습니다.
- **0.8.0 (14)**: 2026년 10월 11일 Developer ID 서명, Apple 공증 `Accepted`, 티켓 첨부·검증, Gatekeeper `Notarized Developer ID`를 확인하고 `build/releases/0.8.0-14/`에 ZIP·서명된 appcast·SHA256SUMS를 생성했습니다. 같은 저장소에 `v0.8.0` 비공개 릴리스 초안으로 ZIP과 appcast를 올렸고, 다시 내려받은 파일이 로컬 체크섬과 일치하는 것을 확인했습니다. 저장소 공개와 초안 게시 전까지는 다운로드·앱 내 업데이트가 제공되지 않습니다.
- **0.7.0 (13)**: 운영 URL·공개 키를 적용한 앱의 Developer ID 서명, Apple 공증 `Accepted`, 티켓 첨부·검증, Gatekeeper를 확인하고 ZIP과 서명된 appcast를 생성했습니다. 같은 저장소에 비공개 릴리스 초안을 저장했으며, 다시 내려받은 파일이 로컬 검증본과 일치하는지도 확인했습니다.
- 동일한 조회 코드를 사용하는 별도 검사 도구를 Developer ID·Hardened Runtime으로 서명한 뒤 Claude·Codex의 새 사용량 응답을 확인했습니다. 검사 로그에는 성공 여부만 남겼습니다. 이 검사는 실제 앱의 전체 화면 흐름이나 다른 Mac 검증을 대체하지 않습니다.

2026년 10월 11일, **0.7.0 (12) arm64 테스트 앱**에서 다음 항목을 확인했습니다.

- 앱과 Sparkle 구성요소의 Developer ID 서명, Hardened Runtime, secure timestamp, 동일한 서명 팀 검증.
- Apple 공증 `Accepted`, 공증 티켓 첨부와 검증, Gatekeeper의 `Notarized Developer ID` 승인.
- 이 Mac에서 다운로드 격리 표시를 적용한 복사본의 예시 모드 실행. App Translocation 상태에서 프로세스가 실행되는 것을 확인했습니다.

빌드 12에는 운영 업데이트 URL·공개 키가 없으며 공개 업로드도 하지 않았습니다. 다른 Mac의 첫 설치, 공증 앱의 실제 CLI 연결, 공개 HTTPS 서버를 통한 업데이트는 아직 검증하지 않았습니다. 앞서 별도 예시 앱에서는 로컬 서버를 통한 업데이트 설치·재실행과 변조된 ZIP·피드 거부를 확인했습니다.

### 서명·공증·업데이트 파일 만들기

`Resources/Info.plist`의 버전·빌드 번호, 운영 `SUFeedURL`·`SUPublicEDKey`를 확인합니다. 새 배포에서는 `CFBundleVersion`을 반드시 증가시킵니다. 기본 빌드는 ad hoc 서명이며, 아래처럼 실제 Developer ID 인증서를 지정하면 앱과 Sparkle 구성요소를 안쪽부터 서명합니다.

아래의 인증서·공증 프로필·릴리스 태그는 실제 값으로 바꿉니다. 운영 키는 이미 준비되어 있으므로 매 배포마다 새로 만들지 않습니다.

```sh
USAGEBAR_SIGNING_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' \
zsh scripts/build-app.sh release

zsh scripts/prepare-release.sh \
  --keychain-profile YOUR_EXISTING_NOTARY_PROFILE \
  --generate-appcast \
  --eddsa-account hyjoong.UsageBar.production \
  --release-notes releases/0.8.1.md \
  --sparkle-tools .build/artifacts/sparkle/Sparkle/bin \
  --download-url-prefix 'https://github.com/hyjoong/UsageBar/releases/download/YOUR_RELEASE_TAG/'
```

`prepare-release.sh`는 원본 앱을 보존하고 복사본만 Apple에 제출합니다. 공증 `Accepted`, 티켓 첨부·검증, Gatekeeper, 코드 서명을 확인한 후 ZIP과 서명된 appcast를 만듭니다. 지정한 Keychain 계정의 공개 키가 앱과 일치해야 하며, 생성한 ZIP과 피드의 서명도 검증합니다. 두 스크립트 모두 공개 업로드를 하지 않습니다. 옵션은 `--help`를 참고하세요. [Apple 공증 절차](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), [Sparkle 배포 안내](https://sparkle-project.org/documentation/)

`--release-notes`로 지정한 `.md`·`.html`·`.txt` 변경 안내는 서명된 appcast 안에 포함합니다. 내용을 바꾸면 appcast를 다시 생성하고 서명을 검증합니다.

개인 키·Apple 공증 인증 정보·GitHub 토큰은 저장소와 앱에 넣지 않습니다. 운영 공개 키를 다시 확인할 때는 Sparkle의 `generate_keys --account hyjoong.UsageBar.production -p`를 사용합니다. Sparkle은 HTTPS appcast와 공개 키가 설정된 빌드에서 시작하며, 피드와 ZIP을 검증하고 압축을 풀기 전에 업데이트 서명을 확인합니다.

### Homebrew cask 갱신

릴리스마다 [hyjoong/homebrew-tap](https://github.com/hyjoong/homebrew-tap)의 `Casks/usagebar.rb`에서 `version`(`버전,빌드`)과 `sha256`(`SHA256SUMS.txt`의 ZIP 값)을 새 값으로 바꾸고 `brew style hyjoong/tap`으로 검사한 뒤 푸시합니다. 릴리스가 게시된 뒤에 올려야 `brew install --cask hyjoong/tap/usagebar`가 동작합니다.

#### 2026-10-12 Rosetta Homebrew 설치 검증 — 공개 tap 반영

Apple Silicon·macOS 14.5에서 `/usr/local`의 Intel Homebrew 7.0.9로 설치할 때 `depends_on arch: :arm64`가 Homebrew 프로세스를 Intel로 판단해 실패하는 것을 재현했습니다. tap의 조건을 `depends_on arch: :arm64 unless Hardware::CPU.in_rosetta2?`로 바꿔 Rosetta에서만 잘못된 거부를 피합니다. 실제 Intel Mac에는 arm64 조건이 그대로 적용됩니다. 앱의 버전·ZIP·체크섬은 바꾸지 않았습니다.

- 수동 설치본을 별도 보관한 뒤 `brew install --cask hyjoong/tap/usagebar`가 배포 파일을 받아 `/Applications`에 설치하는 것을 확인했습니다. `brew list --cask --versions usagebar` 결과는 `usagebar 0.8.8,25`이며, 설치본의 코드 서명·Gatekeeper(`Notarized Developer ID`)·실행 프로세스를 확인했습니다.
- tap의 `tests/usagebar_arch_test.rb`는 실제 Homebrew cask 로더와 아키텍처 검사기로 ARM 네이티브 허용·Rosetta 허용·실제 Intel 거부를 검증합니다. 수정 전에는 Rosetta 케이스가 실패하고 수정 후에는 세 케이스가 모두 통과했습니다. 다른 아키텍처의 실물 Mac 검증은 아닙니다.
- `brew style`은 이 Mac의 개발 도구에서 검사 의존성의 네이티브 확장을 컴파일하지 못해 실행하지 못했습니다. 실패한 확장은 별도 보관해 Homebrew를 복구했습니다. 예약 실행에서 로컬 및 공개 저장소를 새로 받은 작업본의 아키텍처 회귀 테스트 3개를 다시 통과했고, [tap CI](https://github.com/hyjoong/homebrew-tap/actions/runs/38241137041)에서도 세 검사와 cask 스타일 검사(`no offenses`)가 통과했습니다.
- 사용자 승인에 따라 20:10 한국시간 이후 [tap 커밋 `a7f2a38`](https://github.com/hyjoong/homebrew-tap/commit/a7f2a38)을 공개 `master` 브랜치에 push했습니다. 다른 Mac에서는 `brew update`로 새 설치 조건을 받을 수 있습니다. 앱 버전과 배포 파일은 기존 `0.8.8 (25)`를 유지합니다.

### 2026-10-12 CLI 연결·인증 안내 수정 — 0.8.9 (27)에 포함

2026-10-13의 0.8.9 빌드 27에 포함해 출시했습니다(위 버전 목록 참고). 아래는 작성 당시의 기록입니다.

20:10 한국시간 이후 [소스 커밋 `e76558e`](https://github.com/hyjoong/UsageBar/commit/e76558e)를 `main`에 push했습니다. Claude 실행 파일은 사용자 설치 경로(`~/.local/bin`, `~/.npm-global/bin`)를 시스템 설치보다 먼저 확인하고, 필수 옵션을 지원하지 않는 구형 CLI에는 업데이트를 안내합니다. `auth status --json`이 정상 종료 코드 0 또는 1과 함께 `loggedIn: false`를 명시하면 로그인 필요로 분류합니다. 불명확한 응답은 기존 사용량 조회 경로를 유지합니다.

Claude·Codex의 인증 오류를 초기 설정·지원하지 않는 계정·일반 조회 오류와 구분합니다. 첫 조회와 이전 기록이 있는 화면 모두 로그인 확인 안내와 다시 확인 버튼을 표시합니다. Claude는 연결 설정을 여는 버튼을, Codex는 `codex login` 안내를 제공합니다. 성공하거나 다른 종류의 오류로 바뀌면 인증 안내도 해제합니다. 사용자가 보여준 Codex의 일반 조회 실패 원인 자체는 아직 확인하지 않았습니다.

- **검증 완료:** 실제 코어 소스를 직접 컴파일한 회귀 하네스 37개 검사, 변경된 Swift 소스 구문 검사, 한국어·영어 문자열 검사, `git diff --check`. 이어서 [macOS CI](https://github.com/hyjoong/UsageBar/actions/runs/38241199013)에서 `swift build`와 전체 XCTest **163개, 실패 0개**를 확인했습니다. 설치된 기존 앱도 샌드박스 밖에서 코드 서명과 Gatekeeper 승인을 재확인했습니다.
- **검증 제한:** 이 Mac은 Swift 5.8.1이고 로컬 `swift test`는 Command Line Tools의 `PlatformPath` 오류로 시작하지 못합니다. 전체 소스 빌드·테스트는 CI에서 통과했지만 새 `.app` 번들 빌드와 인증 화면 렌더링은 미검증입니다.
- **집에서 이어서:** 앱 저장소의 `main`, tap의 `master`를 받습니다. Swift 5.10 이상이 포함된 Xcode에서 `swift build`, `swift test`, `zsh scripts/build-app.sh debug`를 실행합니다. 영어 번들에는 Xcode의 `xcstringstool`이 필요합니다. 새 앱에서 Claude·Codex 각각 이전 기록 유무, 인증 복구, 일반 오류, 구형 CLI 안내와 한국어·영어 레이아웃을 확인합니다. 초 단위 카운트다운은 이번 소스 변경에 포함되지 않은 후속 작업입니다.
- **배포 상태:** 소스 커밋·push는 앱 릴리스가 아닙니다. 현재 main의 CI는 빌드와 테스트만 실행하며, 설치된 `0.8.8 (25)`에는 위 소스 수정이 들어 있지 않습니다. 새 버전 배포·공증·업데이트 피드·tap 버전과 체크섬 갱신은 후속 작업입니다.

### 2026-10-14 Codex 실행 탐색·이전 기록 복구 — 0.8.10 (28)에 포함

집에서 올린 `main`의 `cdb49b3`(0.8.9 빌드 27)을 받은 뒤 Codex 연결 실패를 재현했습니다. `/usr/local/bin/codex`는 Node 스크립트여서 터미널에서는 버전을 출력하지만, Finder 앱과 같은 제한된 `PATH`에서는 `env: node: No such file or directory`로 종료했습니다. 같은 Mac의 ChatGPT 내장 Codex 실행 파일은 이 환경에서도 정상 실행됐습니다.

- 자동 탐색 시 `--version`에 실패한 후보를 건너뛰고 다음 설치본을 검사합니다. 같은 실행 파일의 중복 링크, 정해진 경로, 취소와 전체 제한 시간을 검증했습니다. 전체 조회 흐름의 동일한 재현 하네스가 수정 전에는 실패하고 수정 후에는 통과했습니다.
- Codex 실행 오류에 **Codex 다시 연결** 및 설치·업데이트 안내를 추가했습니다. 이전 기록 유무에 같은 복구 카드를 표시하고, 오래된 잔여율은 큰 현재값 대신 **마지막 확인 시 …% 남음**과 기록 시점으로 표시합니다. 로그인 오류 분류와 요청 제한은 유지합니다.
- **검증 완료:** 실제 코어 소스 직접 컴파일 하네스 22개 검사, 제한된 `PATH`에서 내장 Codex 자동 선택 및 실제 사용량 조회, 변경 Swift 구문·한국어/영어 문자열·`git diff --check`. 예약 실행에서도 현재 코어 소스를 다시 컴파일해 하네스 22개 검사를 통과했습니다. XCTest 회귀 메서드는 코어 8개와 앱 상태 전환 2개를 추가했으며, [macOS CI](https://github.com/hyjoong/UsageBar/actions/runs/38556097802)에서 `swift build`와 전체 XCTest **173개, 실패 0개**를 확인했습니다.
- **검증 제한:** 이 Mac은 Swift 5.8.1이며 로컬 `swift test`는 기존 CLT `PlatformPath` 오류로 시작하지 못합니다. 전체 build/XCTest는 위 CI에서 통과했지만 새 앱 번들 빌드와 UI 렌더링은 아직 검증하지 않았습니다. Swift 5.10 이상 환경에서 `--ui-codex-setup-error`, `--ui-codex --ui-connection-required`의 한국어·영어 화면과 실제 재연결 성공 전환을 확인해야 합니다.
- **소스 반영:** 예약 시각인 한국시간 20:20 이후 [커밋 `a0ba8c2`](https://github.com/hyjoong/UsageBar/commit/a0ba8c25ed0e626569a80e943e20da22f487d7e7)를 `origin/main`에 push하고 원격 반영을 확인했습니다. 예약 후 별도 변경이 없는 것을 승인 당시 diff와 비교한 뒤 커밋했습니다.
- **배포 상태:** 버전 변경·앱 배포·Homebrew tap 변경은 하지 않았습니다. 설치된 0.8.9 (27)에는 이번 수정이 없으므로 적용하려면 새 앱을 빌드해야 합니다. 집에서는 `main`을 받아 Swift 5.10 이상 환경에서 전체 build/test와 `zsh scripts/build-app.sh debug`를 실행한 뒤, 한국어·영어에서 초기 연결 실패·이전 기록·재연결 성공 화면을 확인합니다.

### 검증 후 공개하기

1. 같은 저장소의 **비공개 릴리스 초안**에 ZIP과 `appcast.xml`을 준비합니다. 피드의 다운로드 주소·버전·아키텍처·서명을 확인합니다. 생성한 피드는 해당 릴리스만 포함하므로 기존 배포 기록이 있다면 함께 검토합니다.
2. 소스와 배포 파일 검증을 마친 뒤 저장소 전체를 public으로 전환하고 릴리스를 게시합니다. **초안 상태만으로는 공개 다운로드나 앱 내 업데이트가 제공되지 않습니다.**
3. 공개된 ZIP과 appcast를 다시 내려받아 첫 설치·Gatekeeper·업데이트 확인을 검증합니다. 가능하면 다른 Mac에서 Claude/Codex 연결과 로그인 시 실행도 확인합니다. 외부 CLI를 실행하는 현재 구조는 공증과 별도로 실제 동작 검증이 필요합니다. [배포본 테스트](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)

버전별 ZIP은 유지하고 새 ZIP이 준비된 뒤 appcast를 갱신합니다. GitHub의 `releases/latest` 경로에서 접근할 수 있도록 최종 릴리스가 최신 공개 릴리스로 표시되는지도 확인합니다.

## 버전별 검증 기록

0.6에서는 테스트 119개를 통과하고, 예시 앱에서 패널 내 작업 시작·서비스 전환·종료·영수증 복사, 조회 실패 후 시간만 저장하기, 다크·라이트 화면을 확인했습니다. 2026-10-10 개발 환경에서 Claude Team과 Codex 실제 조회를 확인했습니다. 설치된 CLI의 출력이나 프로토콜이 바뀌면 연결 코드를 조정해야 할 수 있습니다.

0.6.2에서는 테스트 122개를 통과했습니다. 취소 직후 대체 조회·동시 조회 공유·지원하지 않는 계정의 연결 복구를 추가 검증하고, 예시 앱에서 요청 제한과 최초 연결 화면을 확인했습니다. Mac의 실제 잠자기·깨우기 대신 취소된 조회의 정리를 지연시키는 테스트로 동시성 문제를 재현했습니다.

0.6.3에서도 테스트 122개를 통과했고, 예시 앱의 사용 기록·작업 영수증·패널 검증 창에서 설정 단축키와 앱 메뉴의 설정 항목을 확인했습니다.

0.6.4는 테스트 122개와 예시 데이터의 오늘·7일·30일 화면 검증을 통과했습니다. 누락일과 0토큰을 포함한 기록을 실제 앱에서 CSV로 내보내 수정 전후 파일이 동일한 것을 확인했습니다.

0.7.0은 테스트 132개를 통과했습니다. 별도 bundle ID와 일회성 테스트 키를 사용한 localhost 예시 앱에서 빌드 100 → 101 다운로드·서명 확인·설치·재실행, 최신 버전 안내, 변조된 ZIP 및 appcast 본문 거부, HTTP 404 후 설정 복귀를 확인했습니다. 재실행 인자가 없어도 예시 모드를 유지하며 실제 계정·저장 파일에 접근하지 않습니다. 이 테스트는 Apple 공증이나 배포본의 Gatekeeper 검증을 대신하지 않습니다.

0.8.0은 테스트 132개를 통과했습니다. 예시 앱에서 패널의 Claude·Codex·오래된 기록·연결 필요·요청 제한 상태, 작업 기록의 대기·진행·완료 카드, 사용 기록·설정·영수증 창을 다크·라이트 모드로 캡처해 확인했고, 빌드한 번들을 `-AppleLanguages`로 영어와 한국어 각각 실행해 모든 화면의 번역과 잘림을 점검했습니다. 카탈로그 키는 컴파일러 추출(`-emit-localized-strings`)과 `xcstringstool sync`로 맞추므로 누락 검사가 자동입니다.

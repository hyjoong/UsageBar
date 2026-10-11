# 배포와 검증 기록

배포자를 위한 문서입니다. 일반 사용 안내는 [README](../README.md)에 있습니다.

## 배포 준비

**배포 대상은 기존 `hyjoong/UsageBar` 저장소입니다.** 별도의 바이너리 저장소를 만들지 않고, 최종 검증 후 현재 저장소 전체를 public으로 전환할 예정입니다. 그전에는 저장소와 릴리스 초안을 비공개로 유지합니다.

- 운영 appcast: `https://github.com/hyjoong/UsageBar/releases/latest/download/appcast.xml`
- 운영 Ed25519 키: Keychain 계정 `hyjoong.UsageBar.production`. 앱의 `SUPublicEDKey`에는 공개 키만 포함합니다.
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
  --release-notes releases/0.8.0.md \
  --sparkle-tools .build/artifacts/sparkle/Sparkle/bin \
  --download-url-prefix 'https://github.com/hyjoong/UsageBar/releases/download/YOUR_RELEASE_TAG/'
```

`prepare-release.sh`는 원본 앱을 보존하고 복사본만 Apple에 제출합니다. 공증 `Accepted`, 티켓 첨부·검증, Gatekeeper, 코드 서명을 확인한 후 ZIP과 서명된 appcast를 만듭니다. 지정한 Keychain 계정의 공개 키가 앱과 일치해야 하며, 생성한 ZIP과 피드의 서명도 검증합니다. 두 스크립트 모두 공개 업로드를 하지 않습니다. 옵션은 `--help`를 참고하세요. [Apple 공증 절차](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), [Sparkle 배포 안내](https://sparkle-project.org/documentation/)

`--release-notes`로 지정한 `.md`·`.html`·`.txt` 변경 안내는 서명된 appcast 안에 포함합니다. 내용을 바꾸면 appcast를 다시 생성하고 서명을 검증합니다.

개인 키·Apple 공증 인증 정보·GitHub 토큰은 저장소와 앱에 넣지 않습니다. 운영 공개 키를 다시 확인할 때는 Sparkle의 `generate_keys --account hyjoong.UsageBar.production -p`를 사용합니다. Sparkle은 HTTPS appcast와 공개 키가 설정된 빌드에서 시작하며, 피드와 ZIP을 검증하고 압축을 풀기 전에 업데이트 서명을 확인합니다.

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

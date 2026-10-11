# UI 방향과 참고한 제품

**한눈에 확인 → 짧은 작업 → 필요한 때 상세 기록** 순서로 구성합니다. 0.8부터는 구리색 세그먼트 게이지 하나로 모든 한도를 같은 문법으로 보여주고, 설명 문구는 툴팁으로 옮기며, 작업 시작·종료와 첫 연결에 필요한 단계를 줄이는 방향입니다. 색상·타이포·간격 토큰은 `Sources/UsageBar/DesignSystem.swift`에 있습니다.

- [iStat Menus](https://bjango.com/mac/istatmenus/): 메뉴바 요약과 상세 메뉴의 정보량 분리.
- [Raycast Action Panel](https://manual.raycast.com/action-panel): 자주 쓰는 행동과 단축키의 일관된 위치.
- [CleanShot X](https://cleanshot.com/features): 작업 직후 결과를 확인하고 복사하는 짧은 흐름.
- [Linear의 디자인 개선](https://linear.app/now/behind-the-latest-design-refresh): 반복 요소를 줄이고 중요한 정보와 행동의 위치를 명확히 하는 구성.
- [Things](https://culturedcode.com/things/features/): 진행할 일과 완료 기록의 구분, 필요할 때 상세 정보를 펼치는 구성.
- [CodexBar](https://github.com/steipete/CodexBar/blob/main/README.md): 여러 서비스의 한도와 프로젝트·세션 사용량 분석.
- [Claude-God](https://github.com/Lcharvol/Claude-God), [burnrate](https://github.com/kennykankush/burnrate): 비용·소진 예측·사용 패턴 분석.
- [ClaudeBar](https://github.com/tddworks/ClaudeBar), [nerlichman/claudebar](https://github.com/nerlichman/claudebar): 실행 중인 세션과 알림.
- [PokeTokenBar](https://github.com/chattymin/PokeTokenBar/blob/main/README.ko.md): 메뉴바 표시 항목과 리셋 카운트다운.
- [SwiftUI MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra): 네이티브 메뉴 막대 구성.
- [SwiftUI 앱 메뉴 구성](https://developer.apple.com/documentation/swiftui/building-and-customizing-the-menu-bar-with-swiftui): 창 사이에서 공통으로 쓰는 설정 명령과 단축키.
- [Apple 상태 피드백](https://developer.apple.com/design/human-interface-guidelines/feedback): 현재 상태와 다음 행동을 화면 안에서 안내하는 구성.
- [ccusage 일별 보고서](https://ccusage.com/guide/daily-reports): 오늘을 포함한 달력 날짜 범위와 일별 기록 표시.

UsageBar는 **남은 한도와 리셋 시각을 빠르게 확인하는 흐름**을 중심에 둡니다. 작업 구간 비교와 영수증은 필요할 때만 펼치는 선택 기능입니다. 사용 속도 계산·CSV 내보내기·상태 처리는 직접 구현했으며, 참고 앱의 인증 방식이나 계정 데이터 수집 코드를 가져오지 않았습니다.

아이콘은 외부 로고를 사용하지 않은 자체 U 게이지 마크입니다. 원본은 `Resources/UsageBar-mark.svg`이며 다음 명령으로 앱 아이콘을 다시 만들 수 있습니다.

```sh
swift scripts/make-icon.swift build/AppIcon.iconset Resources/AppIcon.icns
```

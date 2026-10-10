#!/bin/zsh
set -euo pipefail

usagebar_claude=""
if (( $# > 0 )); then
  if (( $# != 2 )) || [[ "$1" != --claude-executable || "$2" != /* || ! -f "$2" || ! -x "$2" ]]; then
    print '앱에서 선택한 Claude 실행 파일을 사용할 수 없어요. UsageBar에서 연결 설정을 다시 열어 주세요.'
    exit 1
  fi
  usagebar_claude="$2"
else
  # Keep this order aligned with ClaudeProvider.resolveExecutable.
  for usagebar_candidate in "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
    if [[ -f "$usagebar_candidate" && -x "$usagebar_candidate" ]]; then
      usagebar_claude="$usagebar_candidate"
      break
    fi
  done
  if [[ -z "$usagebar_claude" ]]; then
    for usagebar_entry in "${path[@]}"; do
      [[ "$usagebar_entry" = /* ]] || continue
      usagebar_candidate="$usagebar_entry/claude"
      if [[ -f "$usagebar_candidate" && -x "$usagebar_candidate" ]]; then
        usagebar_claude="$usagebar_candidate"
        break
      fi
    done
  fi
fi
if [[ -z "$usagebar_claude" ]]; then
  print 'Claude Code를 먼저 설치한 뒤 연결 설정을 다시 열어 주세요.'
  print '설치 안내: https://code.claude.com/docs/en/quickstart'
  exit 1
fi

usagebar_dir="$HOME/Library/Application Support/UsageBar/ClaudeConnection"
usagebar_component="$usagebar_dir"
while [[ "$usagebar_component" != / ]]; do
  if [[ -L "$usagebar_component" ]]; then
    print '연결 폴더가 바로가기여서 사용할 수 없어요. UsageBar 연결 폴더를 확인해 주세요.'
    exit 1
  fi
  usagebar_component="${usagebar_component:h}"
done
/bin/mkdir -p "$usagebar_dir"
/bin/chmod 700 "$usagebar_dir"
cd "$usagebar_dir"

print 'UsageBar의 Claude 연결 설정입니다.'
print '폴더 확인과 로그인이 표시되면 직접 완료해 주세요.'
print '사용량이 표시되면 이 창을 닫고 UsageBar에서 다시 확인을 눌러 주세요.'
exec /usr/bin/env -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDECODE DISABLE_AUTOUPDATER=1 \
  "$usagebar_claude" --safe-mode --ax-screen-reader --tools '' --strict-mcp-config --no-chrome \
  --settings '{"disableAllHooks":true,"remoteControlAtStartup":false}' /usage

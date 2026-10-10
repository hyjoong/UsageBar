#!/bin/zsh
set -euo pipefail

usagebar_dir="$HOME/Library/Application Support/UsageBar/ClaudeConnection"
if [[ -L "$usagebar_dir" || -L "${usagebar_dir:h}" ]]; then
  print '연결 폴더가 바로가기여서 사용할 수 없어요. UsageBar 연결 폴더를 확인해 주세요.'
  exit 1
fi
mkdir -p "$usagebar_dir"
chmod 700 "$usagebar_dir"
cd "$usagebar_dir"

usagebar_claude=""
for usagebar_candidate in "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
  if [[ -x "$usagebar_candidate" ]]; then
    usagebar_claude="$usagebar_candidate"
    break
  fi
done
if [[ -z "$usagebar_claude" ]]; then
  usagebar_claude="$(command -v claude || true)"
fi
if [[ -z "$usagebar_claude" ]]; then
  print 'Claude Code를 먼저 설치한 뒤 연결 설정을 다시 열어 주세요.'
  print '설치 안내: https://code.claude.com/docs/en/quickstart'
  exit 1
fi

print 'UsageBar의 Claude 연결 설정입니다.'
print '폴더 확인과 로그인이 표시되면 직접 완료해 주세요.'
print '사용량이 표시되면 이 창을 닫고 UsageBar에서 다시 확인을 눌러 주세요.'
exec env -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDECODE DISABLE_AUTOUPDATER=1 \
  "$usagebar_claude" --safe-mode --ax-screen-reader --tools '' --strict-mcp-config --no-chrome \
  --settings '{"disableAllHooks":true,"remoteControlAtStartup":false}' /usage

#!/usr/bin/env bash
# RBAC browser walkthrough for the last two roles (tigist=assistant-chef,
# novel=accountant) — same pipeline as role_walkthrough.sh:
#   1. API login through the rig (same-origin proxy to production)
#   2. Flutter app: seed session + identity in localStorage, reload,
#      capture default view + hamburger drawer + More drawer (+ one nav screen)
#   3. Web POS (production): cookie-only session, capture the sidebar
set -u
BASE=http://127.0.0.1:8123
OUT=/home/z/my-project/download/role-audits
mkdir -p "$OUT"

# email|name|first|last|role
ROLES=(
  "tigist@fufut.coffee|Tigist Muluye|Tigist|Muluye|assistant-chef"
  "novel@fufut.coffee|novel wolde|novel|wolde|accountant"
)

for row in "${ROLES[@]}"; do
  IFS='|' read -r EMAIL NAME FIRST LAST ROLE <<< "$row"
  echo "===== $ROLE ($EMAIL) ====="
  # 1. API login through the rig
  LOGIN=$(curl -s -X POST "$BASE/api/auth/login" -H 'Content-Type: application/json' \
    -H "Origin: $BASE" -d "{\"email\":\"$EMAIL\",\"password\":\"selam@336\"}")
  TOKEN=$(printf '%s' "$LOGIN" | python3 -c "import json,sys; print(json.load(sys.stdin).get('user',{}).get('id',''))")
  SESS=$(curl -s -i -X POST "$BASE/api/auth/login" -H 'Content-Type: application/json' \
    -H "Origin: $BASE" -d "{\"email\":\"$EMAIL\",\"password\":\"selam@336\"}" \
    | grep -i '^set-cookie' | sed 's/.*session=\([^;]*\).*/\1/' | head -1)
  if [ -z "$SESS" ]; then echo "  LOGIN FAILED: $LOGIN"; continue; fi
  echo "  staff id: $TOKEN"

  # 2. Flutter app: seed session + identity, reload
  agent-browser set viewport 412 915 >/dev/null 2>&1
  agent-browser open "$BASE/" >/dev/null 2>&1
  sleep 2
  agent-browser cookies set session "$SESS" >/dev/null 2>&1
  agent-browser eval "localStorage.setItem('flutter.fufut.pos.session', JSON.stringify('$SESS')); localStorage.setItem('flutter.fufut.pos.identity', JSON.stringify(JSON.stringify({id:'$TOKEN',name:'$NAME',first_name:'$FIRST',last_name:'$LAST',email:'$EMAIL',role:'$ROLE'}))); 'seeded'" >/dev/null 2>&1
  agent-browser open "$BASE/" >/dev/null 2>&1
  sleep 6
  agent-browser screenshot "$OUT/flutter-$ROLE-01-default.png" >/dev/null 2>&1
  # open drawer (hamburger)
  agent-browser mouse move 28 25 >/dev/null 2>&1
  agent-browser mouse down left >/dev/null 2>&1; sleep 0.35
  agent-browser mouse up left >/dev/null 2>&1
  sleep 2
  agent-browser screenshot "$OUT/flutter-$ROLE-02-drawer.png" >/dev/null 2>&1
  agent-browser press Escape >/dev/null 2>&1
  sleep 1
  # More drawer (bottom-right nav slot ~ (355,888))
  agent-browser mouse move 355 888 >/dev/null 2>&1
  agent-browser mouse down left >/dev/null 2>&1; sleep 0.35
  agent-browser mouse up left >/dev/null 2>&1
  sleep 2
  agent-browser screenshot "$OUT/flutter-$ROLE-03-more-drawer.png" >/dev/null 2>&1
  agent-browser press Escape >/dev/null 2>&1
  sleep 1
  # one content screen via bottom nav slot 2 (~(146,888))
  agent-browser mouse move 146 888 >/dev/null 2>&1
  agent-browser mouse down left >/dev/null 2>&1; sleep 0.35
  agent-browser mouse up left >/dev/null 2>&1
  sleep 3
  agent-browser screenshot "$OUT/flutter-$ROLE-04-nav2.png" >/dev/null 2>&1

  # 3. Web POS (production): cookie-only session
  agent-browser open "https://pos.fufutcoffee.com/pos/" >/dev/null 2>&1
  sleep 2
  agent-browser cookies set session "$SESS" >/dev/null 2>&1
  agent-browser open "https://pos.fufutcoffee.com/pos/app/" >/dev/null 2>&1
  agent-browser wait --load networkidle >/dev/null 2>&1
  sleep 3
  agent-browser screenshot "$OUT/web-$ROLE-sidebar.png" >/dev/null 2>&1
  echo "  screenshots saved"
done
echo "ALL DONE"

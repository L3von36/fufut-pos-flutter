#!/usr/bin/env bash
# RBAC browser walkthrough: sign in as every role (seeded session), capture
# the Flutter drawer and the web POS sidebar per role.
set -u
BASE=http://127.0.0.1:8123
OUT=/home/z/my-project/download/role-audits
mkdir -p "$OUT"

# email|name|first|last|role
ROLES=(
  "amanuel@fufut.coffee|Amanuel Fekadu|Amanuel|Fekadu|manager"
  "yonas@fufut.coffee|Yonas Girmay|Yonas|Girmay|head-waiter"
  "bethel@fufut.coffee|Bethel Assefa|Bethel|Assefa|cashier"
  "barista@fufut.coffee|Barista Station|Barista|Station|barista"
  "gebremedhin@fufut.coffee|Gebremedhin Bililgne|Gebremedhin|Bililgne|delivery-staff"
  "asnegash@fufut.coffee|Asnegash Abebe|Asnegash|Abebe|cleaner"
  "selam@fufut.coffee|Selam Wondimu|Selam|Wondimu|head-chef"
)

for row in "${ROLES[@]}"; do
  IFS='|' read -r EMAIL NAME FIRST LAST ROLE <<< "$row"
  echo "===== $ROLE ($EMAIL) ====="
  # 1. API login through the rig (same-origin proxy to production)
  LOGIN=$(curl -s -X POST "$BASE/api/auth/login" -H 'Content-Type: application/json' \
    -H "Origin: $BASE" -d "{\"email\":\"$EMAIL\",\"password\":\"selam@336\"}")
  TOKEN=$(python3 - <<PY
import json
d = json.loads('''$LOGIN''')
print(d.get('user', {}).get('id', ''))
PY
)
  SESS=$(curl -s -i -X POST "$BASE/api/auth/login" -H 'Content-Type: application/json' \
    -H "Origin: $BASE" -d "{\"email\":\"$EMAIL\",\"password\":\"selam@336\"}" \
    | grep -i '^set-cookie' | sed 's/.*session=\([^;]*\).*/\1/' | head -1)
  if [ -z "$SESS" ]; then echo "  LOGIN FAILED: $LOGIN"; continue; fi
  echo "  staff id: $TOKEN"

  # 2. Flutter app: seed session + identity, reload
  agent-browser open "$BASE/" >/dev/null 2>&1
  sleep 2
  agent-browser cookies set session "$SESS" >/dev/null 2>&1
  agent-browser eval "localStorage.setItem('flutter.fufut.pos.session', JSON.stringify('$SESS')); localStorage.setItem('flutter.fufut.pos.identity', JSON.stringify(JSON.stringify({id:'$TOKEN',name:'$NAME',first_name:'$FIRST',last_name:'$LAST',email:'$EMAIL',role:'$ROLE'}))); 'seeded'" >/dev/null 2>&1
  agent-browser open "$BASE/" >/dev/null 2>&1
  sleep 6
  agent-browser screenshot "$OUT/flutter-$ROLE-01-default.png" >/dev/null 2>&1
  # open drawer (hamburger)
  agent-browser mouse move 28 25 >/dev/null 2>&1
  agent-browser mouse down left >/dev/null 2>&1; sleep 0.3
  agent-browser mouse up left >/dev/null 2>&1
  sleep 2
  agent-browser screenshot "$OUT/flutter-$ROLE-02-drawer.png" >/dev/null 2>&1
  # close drawer
  agent-browser press Escape >/dev/null 2>&1
  sleep 1

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

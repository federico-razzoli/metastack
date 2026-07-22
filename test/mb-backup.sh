#!/usr/bin/env bash

rm -f backups-mb/test1.tz backups-mb/test2.tz

MB_URL="http://localhost:3000"
PGADMIN_PASSWORD="$(grep -E '^PGADMIN_DEFAULT_PASSWORD=' .env | cut -d= -f2-)"

mb_session() {
  curl -fsS -X POST "$MB_URL/api/session" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"admin@example.com\",\"password\":\"$PGADMIN_PASSWORD\"}" \
    | jq -r .id
}

mb_set_site_name() {
  curl -fsS -X PUT "$MB_URL/api/setting/site-name" \
    -H "Content-Type: application/json" \
    -H "X-Metabase-Session: $1" \
    -d "{\"value\":\"$2\"}" >/dev/null
}

mb_get_site_name() {
  curl -fsS "$MB_URL/api/setting/site-name" -H "X-Metabase-Session: $1"
}

SESSION="$(mb_session)"
mb_set_site_name "$SESSION" "backup_test_1"
./mb-backup.sh test1

mb_set_site_name "$SESSION" "backup_test_2"
./mb-backup.sh test2

./mb-restore.sh test1
SESSION="$(mb_session)"
[ "$(mb_get_site_name "$SESSION")" = "backup_test_1" ] && printf '\033[32mCORRECT\033[0m\n' || printf '\033[31mWRONG\033[0m\n'

./mb-restore.sh test2
SESSION="$(mb_session)"
[ "$(mb_get_site_name "$SESSION")" = "backup_test_2" ] && printf '\033[32mCORRECT\033[0m\n' || printf '\033[31mWRONG\033[0m\n'

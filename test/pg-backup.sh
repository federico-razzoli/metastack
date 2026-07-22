#!/usr/bin/env bash

rm -f backups-pg/test1.tz backups-pg/test2.tz
docker compose --ansi never exec -T postgres psql -U pgadmin -d spg -c "DROP TABLE IF EXISTS backup_test;"
docker compose --ansi never exec -T postgres psql -U pgadmin -d spg -c "CREATE TABLE backup_test (id serial primary key);"
docker compose --ansi never exec -T postgres psql -U pgadmin -d spg -c "INSERT INTO backup_test DEFAULT VALUES;"
./pg-backup.sh test1
docker compose --ansi never exec -T postgres psql -U pgadmin -d spg -c "INSERT INTO backup_test DEFAULT VALUES;"
./pg-backup.sh test2
./pg-restore.sh test1
[ "$(docker compose --ansi never exec -T postgres psql -U pgadmin -d spg -tAc "SELECT count(*) FROM backup_test;")" = "1" ] && printf '\033[32mCORRECT\033[0m\n' || printf '\033[31mWRONG\033[0m\n'
./pg-restore.sh test2
[ "$(docker compose --ansi never exec -T postgres psql -U pgadmin -d spg -tAc "SELECT count(*) FROM backup_test;")" = "2" ] && printf '\033[32mCORRECT\033[0m\n' || printf '\033[31mWRONG\033[0m\n'

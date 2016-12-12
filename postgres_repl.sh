#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail
#set -o xtrace

PGREPL_ROLE=${PGREPL_ROLE-(none)}
echo "****** PGREPL_ROLE is: $PGREPL_ROLE"

PGREPL_TOKEN=${PGREPL_TOKEN-abc123}
PGREPL_TOKEN_HASH=$(echo $PGREPL_TOKEN | md5sum | awk '{print $1}')

# sentinel files to facilitate re-entrant containers
sentinel_s="$PGDATA"/pgrepl_standby
sentinel_p="$PGDATA"/pgrepl_primary
trigger_file="$PGDATA"/pgrepl_trigger
recovery_file="$PGDATA"/recovery.conf

if [ -e ${sentinel_s} ]; then 
  PREV_STANDBY=1
else
  PREV_STANDBY=0
fi
if [ -e ${sentinel_p} ]; then 
  PREV_PRIMARY=1
else
  PREV_PRIMARY=0
fi

echo "****** Clearing pre-existing sentinel files"
rm -f ${sentinel_s} ${sentinel_p}

setup_standby() {
  if [ -z "$PGREPL_MASTER_IP" ]; then
      PGREPL_MASTER_IP=$POSTGRES_PORT_5432_TCP_ADDR
  fi
  if [ -z "$PGREPL_MASTER_PORT" ]; then
      PGREPL_MASTER_PORT=$POSTGRES_PORT_5432_TCP_PORT
  fi
  echo "****** Caching pgrepl credentials in .pgpass"
  mkdir -p /home/postgres
  chown -R postgres:postgres /home/postgres
  su -  postgres -c "echo '*:*:*:pgrepl:$PGREPL_TOKEN_HASH' > /home/postgres/.pgpass"
  chown postgres:postgres /home/postgres/.pgpass
  chmod 0600 /home/postgres/.pgpass
  
  rm -rf "$PGDATA"/*
  echo "****** Catchup with master using pg_basebackup"
  gosu postgres pg_basebackup -D "$PGDATA"/ -h "$PGREPL_MASTER_IP" -p "$PGREPL_MASTER_PORT" -U pgrepl -P 
  
  echo "****** Setting recovery configuration"
  gosu postgres echo "standby_mode='on'"                                                              >> ${recovery_file}
  gosu postgres echo "primary_conninfo='host=$PGREPL_MASTER_IP port=$PGREPL_MASTER_PORT user=pgrepl'" >> ${recovery_file}
  gosu postgres echo "recovery_target_timeline = 'latest'"                                            >> ${recovery_file}
  gosu postgres echo "trigger_file = '$trigger_file'"                                                 >> ${recovery_file}

  echo "****** Creating standby sentinel: $sentinel_s"
  touch "$sentinel_s"
}

setup_primary() {
  if [ $PREV_STANDBY -ne 0 ]; then 
    echo "****** Detected promotion; will create trigger file to initiate promotion"
    touch ${trigger_file}
  else
    echo "****** Did not detect promotion."
  fi 
  echo "****** Creating primary sentinel: $sentinel_p"
  touch "$sentinel_p"
}

initialize_replication() {
  echo "****** Setting postgres system variables for replication"
  gosu postgres postgres --single <<- EOSQL
    ALTER SYSTEM SET wal_level=hot_standby;
    ALTER SYSTEM SET max_wal_senders=10; 
    ALTER SYSTEM SET hot_standby=on;
    CREATE USER pgrepl WITH replication password '${PGREPL_TOKEN_HASH}';
EOSQL

  echo "host  replication     pgrepl     0.0.0.0/0         md5" >> "$PGDATA"/pg_hba.conf
}

if (( $PREV_PRIMARY || $PREV_STANDBY )); then 
    echo "****** Sentinels detected:"
    echo "****** PRIMARY: $PREV_PRIMARY"
    echo "****** STANDBY: $PREV_STANDBY"
    echo "****** Will not initialize replication."
else 
    echo "****** No sentinels detected. Will initialize replication."
    initialize_replication
fi

case "$PGREPL_ROLE" in 
  "PRIMARY") 
    setup_primary
    ;;
  "STANDBY") 
    setup_standby
    ;;
  *) 
    echo "****** UNRECOGNIZED PGREPL_ROLE: $PGREPL_ROLE"
    ;;
esac

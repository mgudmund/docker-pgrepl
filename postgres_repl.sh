#!/bin/bash
#set -x

PGREPL_TOKEN=abc123
PGREPL_TOKEN_HASH=$(echo $PGREPL_TOKEN | md5sum | awk '{print $1}')

gosu postgres pg_ctl stop

echo "******Setting postgres system variables for replication******"
gosu postgres postgres --single <<- EOSQL
   ALTER SYSTEM SET wal_level=hot_standby;
   ALTER SYSTEM SET max_wal_senders=10; 
   ALTER SYSTEM SET hot_standby=on
   CREATE USER pgrepl WITH replication password '${PGREPL_TOKEN_HASH}';
EOSQL


echo "host  replication     pgrepl     0.0.0.0/0         md5" >> /var/lib/postgresql/data/pg_hba.conf

if [ -n "$PGREPL_ROLE" ]; then
   echo "PGREPL_ROLE set to $PGREPL_ROLE"
   if [ "$PGREPL_ROLE" == "STANDBY" ]; then
      if [ -z "$PGREPL_MASTER_IP" ]; then
          PGREPL_MASTER_IP=$POSTGRES_PORT_5432_TCP_ADDR
      fi
      if [ -z "$PGREPL_MASTER_PORT" ]; then
          PGREPL_MASTER_PORT=$POSTGRES_PORT_5432_TCP_PORT
      fi
      mkdir -p /home/postgres
      chown -R postgres:postgres /home/postgres
      su -  postgres -c "echo '*:*:*:pgrepl:$PGREPL_TOKEN_HASH' > /home/postgres/.pgpass" 
      chown postgres:postgres /home/postgres/.pgpass
      chmod 0600 /home/postgres/.pgpass
      rm -rf /var/lib/postgresql/data/*
      gosu postgres pg_basebackup -D /var/lib/postgresql/data/ -h "$PGREPL_MASTER_IP" -p "$PGREPL_MASTER_PORT" -U pgrepl -P 
      gosu postgres echo "standby_mode='on'" >> /var/lib/postgresql/data/recovery.conf
      gosu postgres echo "primary_conninfo='host=$PGREPL_MASTER_IP port=$PGREPL_MASTER_PORT user=pgrepl'" >> /var/lib/postgresql/data/recovery.conf
      gosu postgres echo "recovery_target_timeline = 'latest'" >> /var/lib/postgresql/data/recovery.conf
   fi
fi  
 
gosu postgres pg_ctl start
sleep 10

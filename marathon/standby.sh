#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail
#set -o xtrace

if [[ $# -lt 2 ]]; then 
  echo usage: $0 [marathon-url] [primary-app-id] [standby-app-id] [standby-vip]
  exit 1
fi

MARURL="$1"
PRIMARY_APPID=${2}
APPID=${3-/gestalt-data/pg2}
VIP=${4-/primary.gestalt-data:5432}

PVIP=$(http $MARURL/v2/apps/$PRIMARY_APPID | jq -r '.app.container.docker.portMappings[0].labels.VIP_0' | sed "s|^/||")
PRIMARY_HOST="${PVIP%:*}.marathon.l4lb.thisdcos.directory"
PRIMARY_PORT="${PVIP#*:}"
echo Primary VIP is $PRIMARY_HOST:$PRIMARY_PORT

read -r -d '' PAYLOAD <<EOM || true
{
  "env": {
    "POSTGRES_USER": "${POSTGRES_USER-gestaltdev}",
    "POSTGRES_PASSWORD": "${POSTGRES_PASSWORD-letmein}",
    "PGDATA": "/mnt/mesos/sandbox/pgdata",
    "PGREPL_TOKEN": "${PGREPL_TOKEN-abc123}",
    "PGREPL_ROLE": "STANDBY",
    "PGREPL_MASTER_IP": "$PRIMARY_HOST",
    "PGREPL_MASTER_PORT": "$PRIMARY_PORT"
  },
  "instances": 1,
  "cpus": 0.5,
  "mem": 512,
  "container": {
    "type": "DOCKER",
    "volumes": [
      {
        "containerPath": "pgdata",
        "mode": "RW",
        "persistent": {
          "size": 100
        }
      }
    ],
    "docker": {
      "image": "galacticfog/postgres_repl:latest",
      "network": "BRIDGE",
      "forcePullImage": true,
      "portMappings": [
        {
          "containerPort": 5432,
          "protocol": "tcp",
          "name": "db",
          "labels": {
            "VIP_0": "$VIP"
          }
        }
      ]
    }
  },
  "taskKillGracePeriodSeconds": 30,
  "healthChecks": [
    {
      "protocol": "COMMAND",
      "command": {
        "value": "gosu postgres pg_ctl status"
      }
    }
  ]
}
EOM

echo $PAYLOAD | http PUT $MARURL/v2/apps/$APPID?force=true

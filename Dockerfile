FROM postgres:9.4
ADD postgres_repl.sh /docker-entrypoint-initdb.d/

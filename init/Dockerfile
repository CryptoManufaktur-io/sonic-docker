FROM sonic:local

COPY init-db.sh /usr/local/bin/

RUN apt-get update && DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC apt-get install -y ca-certificates tzdata curl \
        && rm -rf /var/lib/apt/lists/*

ENTRYPOINT [ "init-db.sh" ]

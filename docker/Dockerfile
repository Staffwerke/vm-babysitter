FROM debian:bullseye-slim

ARG source="https://github.com/abbbi/virtnbdbackup"

LABEL container.name="virtnbdbackup-docker"
LABEL container.source.description="Backup utiliy for Libvirt kvm / qemu with Incremental backup support via NBD"
LABEL container.description="Automatically (re) builds backup chains of virtual machines by using virtnbdbackup and schedules incremental backups"
LABEL container.source=$source
LABEL container.version="0.1"
LABEL maintainer="Adrián Parilli <a.parilli@staffwerke.de>"

# Deploys dependencies and pulls sources, installing cron, virtnbdbackup and removing unnecessary content:

RUN \
apt-get update && \
apt-get install -y --no-install-recommends \
ca-certificates cron git python3-all python3-libnbd python3-libvirt python3-lz4 python3-setuptools python3-tqdm qemu-utils && \
git clone $source.git && \
cd virtnbdbackup && python3 setup.py install && cd .. && \
apt-get purge -y git ca-certificates && apt-get -y autoremove --purge && apt-get clean && \
rm -rf /var/lib/apt/lists/* /tmp/* /virtnbdbackup

ENV DOMAINS_LIST=()
ENV BACKUP_MAIN_PATH=""
ENV REMOTE_BACKUP_MAIN_PATH=""
ENV ALLOW_RESTART="false"
ENV WAIT_TIME=15
ENV MAX_ATTEMPTS=5
ENV MAX_ALLOWED_MEMORY=8388608

# Default folder:
WORKDIR /

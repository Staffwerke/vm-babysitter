FROM debian:bullseye-slim

LABEL container.name="vm-babysitter"
LABEL container.description="Automatic Backup & Monitoring utility for QEMU/KVM Virtual Machines (powered by Virtnbdbackup)"
LABEL container.version="0.1"
LABEL maintainer="Adrián Parilli <a.parilli@staffwerke.de>"

ARG DEBIAN_FRONTEND="noninteractive"
ARG VIRTNBDBACKUP_SOURCE="https://github.com/abbbi/virtnbdbackup"

RUN \
apt-get update && \
apt-get install -y --no-install-recommends \
ca-certificates cron git libvirt-clients python3-all python3-libnbd python3-libvirt python3-lz4 python3-setuptools python3-tqdm qemu-utils rsync sshfs && \
git clone $VIRTNBDBACKUP_SOURCE.git && \
cd virtnbdbackup && python3 setup.py install && cd .. && \
apt-get purge -y git ca-certificates && apt-get -y autoremove --purge && apt-get clean && \
rm -rf /var/lib/apt/lists/* /tmp/* /virtnbdbackup

COPY "./entrypoint.sh","../functions","..vm-*/","..virtnbd*/", "/"

ENV ALLOW_RESTART="false"

ENTRYPOINT ["entrypoint.sh","&>> /log/vm-babysitter.log"]

WORKDIR /

FROM debian:bullseye-slim

ARG DEBIAN_FRONTEND="noninteractive"
ARG VIRTNBDBACKUP_SOURCE_URL="https://github.com/abbbi/virtnbdbackup"
ARG VIRTNBDBACKUP_VERSION="v0.42"

LABEL container.name="vm-babysitter"
LABEL container.description="Automatic Backup & Monitoring utility for QEMU/KVM Virtual Machines (powered by Virtnbdbackup)"
LABEL container.version="1.1"
LABEL virtnbdbackup.version="$VIRTNBDBACKUP_VERSION"
LABEL maintainer="Adrián Parilli <a.parilli@staffwerke.de>"

RUN \
apt-get update && \
apt-get install -y --no-install-recommends \
ca-certificates cron git libvirt-clients python3-all python3-libnbd python3-libvirt python3-lxml python3-lz4 python3-paramiko python3-setuptools python3-tqdm python3-lxml python3-paramikoqemu-utils rsync sshfs uuid-runtime && \
git clone -b $VIRTNBDBACKUP_VERSION --single-branch $VIRTNBDBACKUP_SOURCE_URL.git && \
cd virtnbdbackup && python3 setup.py install && cd .. && \
apt-get purge -y git ca-certificates && apt-get -y autoremove --purge && apt-get clean && \
rm -rf /var/lib/apt/lists/* /tmp/* /virtnbdbackup && \
mkdir -p /logs /private

COPY scripts/* /usr/local/bin/

CMD ["vm-babysitter"]

WORKDIR /

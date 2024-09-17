FROM ghcr.io/abbbi/virtnbdbackup:master

ARG DEBIAN_FRONTEND="noninteractive"

LABEL container.name="vm-babysitter"
LABEL container.description="Automatic Backup & Monitoring utility for QEMU/KVM Virtual Machines (powered by Virtnbdbackup)"
LABEL container.source="https://git.staffwerke.de/Adrian/vm-babysitter"
LABEL container.version="1.3"
LABEL maintainer="Adrián Parilli <adrian.parilli@staffwerke.de>"

RUN \
apt-get update && \
apt-get install -y --no-install-recommends \
cron libvirt-clients logrotate rsync sshfs uuid-runtime && \
apt-get -y autoremove --purge && apt-get clean && \
rm -rf /var/lib/apt/lists/* /tmp/* && \
mkdir -p /logs /private

COPY --chown=root:root --chmod=755 ./scripts/* /usr/local/bin/

CMD ["vm-babysitter"]

WORKDIR /

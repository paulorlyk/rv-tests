FROM debian:trixie-backports

ARG SRC_DIR="/src"

ARG USERNAME=user
ARG UID=1000
ARG GID=1000

ENV DEBIAN_FRONTEND=noninterractive
ENV EDITOR=mcedit

RUN groupadd --gid ${GID} ${USERNAME} && useradd --uid ${UID} --gid ${GID} --create-home --shell /bin/bash ${USERNAME}

RUN mkdir "${SRC_DIR}" && chown ${USERNAME}:${USERNAME} "${SRC_DIR}"

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        sudo \
        curl \
        ca-certificates \
        htop \
        mc \
        tmux \
        nodejs \
        npm \
        binutils-riscv64-unknown-elf \
        picolibc-riscv64-unknown-elf \
        gcc-riscv64-unknown-elf \
        qemu-system-riscv


RUN echo '%sudo ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/sudo-nopasswd && chmod 440 /etc/sudoers.d/sudo-nopasswd

RUN usermod -aG sudo ${USERNAME}

USER ${USERNAME}

ENV PATH="/home/$USERNAME/.local/bin:$PATH"

RUN curl -fsSL https://claude.ai/install.sh | bash

WORKDIR ${SRC_DIR}

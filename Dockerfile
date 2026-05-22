# syntax=docker/dockerfile:1

FROM debian:trixie

# Build arguments
ARG USER_ID=1000
ARG GROUP_ID=1000
ARG USERNAME=builder

# Install build dependencies
RUN DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC apt-get update && \
    DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC apt-get install -y \
    ack apt-utils apt-transport-https autoconf bc bison build-essential \
    busybox ca-certificates ccache cmake cpio curl dialog file flex fzf \
    gawk git golang-go libcrypt-dev libncurses-dev libusb-1.0-0-dev locales \
    lzop m4 mc nano nodejs npm perl python3 python3-jinja2 python3-jsonschema \
    python3-yaml ripgrep rsync shfmt ssh sudo u-boot-tools unzip vim wget \
    whiptail zlib1g-dev && \
    rm -rf /var/lib/apt/lists/*

# Pin fakeroot to Debian bookworm's 1.31. Trixie's fakeroot 1.37.1.1
# deadlocks during buildroot's squashfs assembly: the faked daemon never
# hands its key back, leaving fakeroot blocked in pipe_wait. The bug is in
# fakeroot's common startup path, so both fakeroot-tcp and fakeroot-sysv
# are affected. bookworm's 1.31 predates the regression. Held so apt
# upgrades cannot pull 1.37 back in.
RUN echo 'deb http://deb.debian.org/debian bookworm main' \
    > /etc/apt/sources.list.d/bookworm.list && \
    DEBIAN_FRONTEND=noninteractive apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades \
    fakeroot/bookworm libfakeroot/bookworm && \
    apt-mark hold fakeroot libfakeroot && \
    rm -f /etc/apt/sources.list.d/bookworm.list && \
    rm -rf /var/lib/apt/lists/* && \
    fakeroot --version

# Set vim as default editor
RUN update-alternatives --install /usr/bin/editor editor /usr/bin/vim 1 && \
    update-alternatives --set editor /usr/bin/vim && \
    update-alternatives --install /usr/bin/vi vi /usr/bin/vim 1 && \
    update-alternatives --set vi /usr/bin/vim

# Update CA certificates
RUN update-ca-certificates

# Configure and generate locale
RUN echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && \
    locale-gen en_US.UTF-8 && \
    update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

# Create user with matching UID/GID for volume permissions
RUN groupadd -g ${GROUP_ID} ${USERNAME} && \
    useradd -m -u ${USER_ID} -g ${GROUP_ID} -s /bin/bash ${USERNAME} && \
    echo "${USERNAME}:${USERNAME}" | chpasswd && \
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER ${USERNAME}

# Set up Buildroot download cache directory
ENV BR2_DL_DIR=/home/${USERNAME}/dl

# Set working directory
WORKDIR /home/${USERNAME}/build

# Configure git
RUN git config --global --add safe.directory /home/${USERNAME}/build && \
    git config --global alias.up 'pull --rebase --autostash'

# Default command
CMD ["/bin/bash"]

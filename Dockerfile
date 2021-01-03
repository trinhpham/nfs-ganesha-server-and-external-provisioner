# Copyright 2017 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Modified from https://github.com/rootfs/nfs-ganesha-docker by Huamin Chen

# Base image version
ARG FEDORA_VERSION=34

FROM golang:1.15 as go-builder

RUN mkdir -p bin \
	&& wget https://github.com/golang/dep/releases/download/v0.5.1/dep-linux-amd64 -O /usr/local/go/bin/dep \
	&& chmod u+x /usr/local/go/bin/dep \
	&& export PATH=$PWD/bin:$PATH

# TODO get go modules instead of commiting vendor folder
COPY . /go/src/nfs-provisioner
WORKDIR /go/src/nfs-provisioner
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -mod=vendor -a -ldflags '-extldflags "-static"' -o ./bin/nfs-provisioner ./cmd/nfs-provisioner

FROM fedora:${FEDORA_VERSION} AS build

# Build ganesha from source, install it to /usr/local and a use multi stage build to have a smaller image
# Set NFS_V4_RECOV_ROOT to /export

# Install dependencies on separated lines to be easier to track changes using git blame
RUN dnf install -y \
	autoconf \
	bison \
	cmake \
	dbus-devel \
	flex \
	tar \
	gcc \
	gcc-c++ \
	git \
	jemalloc-devel \
	krb5-devel \
	libblkid-devel \
	libnfsidmap-devel \
	libnsl2-devel \
	libtool \
	make \
	patch \
	userspace-rcu-devel

# Ganesha version (the tag name on Ganesha's repository)
ARG GANESHA_VERSION=V2.8.4

RUN git clone --branch ${GANESHA_VERSION} --recurse-submodules https://github.com/nfs-ganesha/nfs-ganesha
WORKDIR /nfs-ganesha
RUN mkdir -p /usr/local \
    && cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_CONFIG=vfs_only -DCMAKE_INSTALL_PREFIX=/usr/local src/ \
    && sed -i 's|@SYSSTATEDIR@/lib/nfs/ganesha|/export|' src/include/config-h.in.cmake \
	  && make \
	  && make install
RUN mkdir -p /ganesha-extra \
    && mkdir -p /ganesha-extra/etc/dbus-1/system.d \
    && cp src/scripts/ganeshactl/org.ganesha.nfsd.conf /ganesha-extra/etc/dbus-1/system.d/

FROM registry.fedoraproject.org/fedora-minimal:${FEDORA_VERSION} AS run

# Install dependencies on separated lines to be easier to track changes using git blame
RUN microdnf install -y \
	dbus-x11 \
	hostname \
	jemalloc \
	libblkid \
	libnfsidmap \
	nfs-utils \
	rpcbind \
	userspace-rcu \
	xfsprogs \
    && microdnf clean all

RUN mkdir -p /var/run/dbus \
    && mkdir -p /export

# add libs from /usr/local/lib64
RUN echo /usr/local/lib64 > /etc/ld.so.conf.d/local_libs.conf

# do not ask systemd for user IDs or groups (slows down dbus-daemon start)
RUN sed -i s/systemd// /etc/nsswitch.conf

COPY --from=build /usr/local /usr/local/
COPY --from=build /ganesha-extra /
COPY --from=go-builder /go/src/nfs-provisioner/bin/nfs-provisioner /nfs-provisioner

# run ldconfig after libs have been copied
RUN ldconfig

# expose mountd 20048/tcp and nfsd 2049/tcp and rpcbind 111/tcp 111/udp
EXPOSE 2049/tcp 20048/tcp 111/tcp 111/udp

ENTRYPOINT ["/nfs-provisioner"]

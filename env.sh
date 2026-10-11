#!/bin/bash

# Testbed: nexus03 (client) <-> nexus01 (server), direct CX-7 link.
# See replication/nexus03_client.md and replication/nexus01_server.md.

# Set to client-side IP address
HOST=192.168.101.3

# Set to server-side IP address
TARGET=192.168.101.111

# Local network interface. The two machines use different names, so commands run on
# the server (inside ssh) use TARGET_INTF instead.
case $(hostname -s) in nexus01) INTF=ens1np0 ;; *) INTF=ens1006np0 ;; esac
TARGET_INTF=ens1np0

# Hostname of the remote server: management network, NOT the 192.168.101.x test link
TARGETC=nexus01.csl.illinois.edu

# Username of the remote server
USER=iksingh2

# Home directory on the remote server
TARGETDIR=/home/iksingh2

# This repo on the remote server (replaces "$TARGETDIR/latency" in the scripts)
TARGET_REPO=/home/iksingh2/io_uring_lat_study

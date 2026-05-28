#!/usr/bin/env bash

set -ex

zig fmt src build.zig --check
zig build

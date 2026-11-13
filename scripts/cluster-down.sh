#!/usr/bin/env bash
# Deletes the "lessons" kind cluster. Everything inside it is gone; your files are not touched.
set -euo pipefail
kind delete cluster --name lessons

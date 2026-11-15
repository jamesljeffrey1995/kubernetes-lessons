# Deletes the "lessons" kind cluster. Everything inside it is gone; your files are not touched.
. (Join-Path $PSScriptRoot "engine.ps1")     # picks Docker or Podman, like cluster-up
kind delete cluster --name lessons
exit $LASTEXITCODE

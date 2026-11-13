# Removes Pulse completely (including Redis data).
$Root = Split-Path -Parent $PSScriptRoot
Push-Location $Root
try {
    kubectl delete -f k8s/load.yaml --ignore-not-found
    helm uninstall pulse -n pulse
    kubectl delete namespace pulse
} finally {
    Pop-Location
}

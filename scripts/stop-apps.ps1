# Arrête les applis du POC (gateway 8080, order-service 8081, order-projector 8082).
foreach ($port in 8080, 8081, 8082) {
    $owner = (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue).OwningProcess
    if ($owner) {
        Stop-Process -Id $owner -Force -Confirm:$false
        "port $port arrêté (pid $owner)"
    }
}

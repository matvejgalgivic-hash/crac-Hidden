$out = "C:\Users\user\Downloads\Loader\proc_capture.txt"
Remove-Item $out -ErrorAction SilentlyContinue
$end = (Get-Date).AddSeconds(45)
while ((Get-Date) -lt $end) {
  $ps = Get-CimInstance Win32_Process -Filter "Name='RobRun.exe'" -ErrorAction SilentlyContinue
  foreach ($p in $ps) {
    $line = "$(Get-Date -Format HH:mm:ss.fff) pid=$($p.ProcessId) ppid=$($p.ParentProcessId) cmd=$($p.CommandLine)"
    if (-not (Test-Path $out) -or -not (Select-String -Path $out -SimpleMatch "pid=$($p.ProcessId)" -Quiet)) { Add-Content $out $line }
  }
  Start-Sleep -Milliseconds 150
}

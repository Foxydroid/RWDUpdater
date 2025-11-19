@echo off

set "url=https://raw.githubusercontent.com/Foxydroid/RWDUpdater/refs/heads/main/RWDUpdater.ps1"
set "tls=[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12;"

"%SYSTEMROOT%\System32\WindowsPowerShell\v1.0\powershell.exe" ^
-Command "%tls% iwr -useb %url% %params% | iex"

exit /b

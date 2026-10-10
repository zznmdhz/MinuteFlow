param([string]$Runtime = "win-x64")
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
node scripts/check-version.mjs
if ($LASTEXITCODE -ne 0) { throw "Version validation failed" }
$release = Get-Content version.json | ConvertFrom-Json
$output = "artifacts/windows/$Runtime/MinuteFlow"
dotnet publish windows/MinuteFlow.Windows/MinuteFlow.Windows.csproj -c Release -r $Runtime --self-contained true -o $output -p:PublishSingleFile=false
if ($LASTEXITCODE -ne 0) { throw "Windows publish failed" }
$exe = Join-Path $output "MinuteFlow.exe"
if (!(Test-Path $exe)) { throw "Windows executable missing" }
$smoke = Start-Process -FilePath (Resolve-Path $exe) -ArgumentList "--smoke-test" -Wait -PassThru
if ($smoke.ExitCode -ne 0) { throw "Published Windows smoke test failed: $($smoke.ExitCode)" }
$zip = "artifacts/MinuteFlow-v$($release.version)-Windows-$Runtime.zip"
Compress-Archive -Path "$output/*" -DestinationPath $zip -Force
if ($Runtime -eq "win-x64") {
  $compiler = Get-Command ISCC.exe -ErrorAction SilentlyContinue
  $compilerPath = if ($compiler) { $compiler.Source } else { "${env:ProgramFiles(x86)}/Inno Setup 6/ISCC.exe" }
  if (!(Test-Path $compilerPath)) { throw "Install Inno Setup 6 to build the Windows installer." }
  & $compilerPath "/DMyAppVersion=$($release.version)" "/DSourceDir=$((Resolve-Path $output).Path)" "/DArtifactDir=$((Resolve-Path artifacts).Path)" scripts/windows-installer.iss
  if ($LASTEXITCODE -ne 0) { throw "Windows installer build failed" }
  $setup = (Resolve-Path "artifacts/MinuteFlow-v$($release.version)-Windows-Setup.exe").Path
  $testInstall = Join-Path $env:TEMP "MinuteFlow-install-test-$([guid]::NewGuid())"
  $installed = Start-Process -FilePath $setup -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/DIR=`"$testInstall`"" -Wait -PassThru
  if ($installed.ExitCode -ne 0) { throw "Installer test failed: $($installed.ExitCode)" }
  $installedSmoke = Start-Process -FilePath (Join-Path $testInstall "MinuteFlow.exe") -ArgumentList "--smoke-test" -Wait -PassThru
  if ($installedSmoke.ExitCode -ne 0) { throw "Installed app failed smoke test" }
  $uninstalled = Start-Process -FilePath (Join-Path $testInstall "unins000.exe") -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART" -Wait -PassThru
  if ($uninstalled.ExitCode -ne 0) { throw "Uninstaller test failed" }
}
Write-Output $zip

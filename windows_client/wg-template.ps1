$WG_URL = "https://{{WG_ENDPOINT}}"
$WG_KEY = "{{WG_CLIENT_API_KEY}}"
$HEADER = @{"Authorization"="Bearer "+ $WG_KEY}
$FolderPath = "C:\ProgramData\WireGuard"
$FileName = "wireguard-amd64-0.5.3.msi"
$Hash = "76FCEC042C5989C5B816CD32EAED1E5B1C3B998A4B1C9ECA55F299E3314EF7E4"

Function Get-RandomKey() {
  $c = "ABCDEFGHKLMNOPRSTUVWXYZabcdefghiklmnoprstuvwxyz1234567890"
  $r = 1..64 | ForEach { Get-Random -Maximum $c.length }
  $private:ofs=""
  return [String]$c[$r]
}

# Make WireGuard Folder
if(-not (Test-Path $FolderPath)){
  mkdir $FolderPath
}

# Make an ID file
if(-not (Test-Path ($FolderPath + "\client_id"))){
  hostname | Out-File -Encoding Default ($FolderPath + "\client_id")
}

# Get the ID
$client_id = (Get-Content ($FolderPath + "\client_id")).toString()

# Generate a shared key for the config
if(-not (Test-Path ($FolderPath + "\config_key"))){
  Get-RandomKey | Out-File -Encoding Default ($FolderPath + "\config_key")
}

# Get the key
$config_key = (Get-Content ($FolderPath + "\config_key")).toString()

$HashCheck = $False
# We cannot check the file hash
if(Get-Command "Get-FileHash" -EA SilentlyContinue){
  $HashCheck = $True
}

# check if wg is installed
if(-not (Test-Path "C:\Program Files\WireGuard\wireguard.exe")){
  $Installer = $FolderPath + "\" + $FileName
  $Url = "https://{{WG_ENDPOINT}}/public/" + $FileName
  (New-Object System.Net.WebClient).DownloadFile($Url, $Installer)
  # Download failed, bail
  if($HashCheck -and ((Get-FileHash -Algorithm SHA256 $Installer).Hash -ne $Hash)){
    exit 1
  }
  & $Installer /quiet /qn /DO_NOT_LAUNCH=1 /log ($FolderPath + "\" + $FileName + ".log")
  Start-Sleep 30
}

# Get client config
$Body = @{ "key" = $config_key; } | ConvertTo-Json -Compress
$Uri = $WG_URL + "/api/v1/devices/" + $client_id + "/config"
$r = Invoke-WebRequest -UseBasicParsing -Uri $Uri -Headers $HEADER -Method POST -Body $Body -ContentType "application/json"
if($r.StatusCode -eq 200){
  # Write the config
  $Config = $r.Content | ConvertFrom-Json
  $Config.config | Out-File -NoNewline -Encoding Default ($FolderPath + "\" + $Config.name + ".conf")

  # Install the service
  if(-not (Get-Service | Where{$_.name -eq ("WireGuardTunnel`$" + $Config.name)})){
    & "C:\Program Files\WireGuard\wireguard.exe" /installtunnelservice ($FolderPath + "\" + $Config.name + ".conf")
  }
  Start-Sleep 10

  # Write DNS config file
  @{
    "NameServer" = $Config.nameserver;
    "Namespaces" = $Config.namespaces; # Изменено: Namespaces как массив
    "Name" = $Config.name;
  } | ConvertTo-Json | Out-File -Encoding Default ($FolderPath + "\dns_config.json")

  # Get nssm
  if(-not (Test-Path ($FolderPath + "\nssm.exe"))){
    (New-Object System.Net.WebClient).DownloadFile("https://{{WG_ENDPOINT}}/public/nssm.exe", ($FolderPath + "\nssm.exe"))
  }

  # Write watcher ps1
  $Watcher = @'
$FolderPath = "C:\ProgramData\WireGuard"
$ConfigFile = ($FolderPath + "\dns_config.json")
$Config = (Get-Content $ConfigFile) | ConvertFrom-Json
$ServiceName = ("WireGuardTunnel`$" + $Config.name)
$Endpoint = (Get-Content ($FolderPath + "\" + $Config.name + ".conf") | where {$_ -like "Endpoint*"}) -replace "Endpoint = ", "" -replace ":.*$", ""

while($True){
  # if the tunnel is disabled clean up dns and stop
  if((Get-Service $ServiceName).StartType -eq "Disabled"){
    Get-DnsClientNrptRule | Remove-DnsClientNrptRule -Force
    Stop-Service wg_watcher
    exit
  }

  # make sure we can reach the on-prem DNS server
  $dns_reachable = $False
  foreach ($ns in $Config.Namespaces) { # Изменено: проверка для каждого namespace
    if(-not (& nslookup -timeout=1 -retry=1 $ns $Config.NameServer | where {$_ -like "*timed out*"})){
      $dns_reachable = $True
      break
    }
  }

  if(-not $dns_reachable){
    # VPN running
    if((Get-Service $ServiceName).Status -eq "Running"){
      # Stop it
      Stop-Service $ServiceName
    }else{ # Not running
      # Start it
      Start-Service $ServiceName
    }
  }

  # make sure DNS config is there if the VPN is running
  if(((Get-Service $ServiceName).Status -eq "Running") -and ((Get-DnsClientNrptRule | Measure).Count -eq 0)){
    Add-DnsClientNrptRule -Namespace $Endpoint -NameServers 8.8.8.8 # Avoid internal DNS collisions
    foreach ($ns in $Config.Namespaces) { # Изменено: создание NRPT для каждого namespace
      Add-DnsClientNrptRule -Namespace $ns -NameServers $Config.nameserver
      Add-DnsClientNrptRule -Namespace ("." + $ns) -NameServers $Config.nameserver
    }
  }

  # turn off DNS otherwise
  if(((Get-Service $ServiceName).Status -ne "Running") -and ((Get-DnsClientNrptRule | Measure).Count -gt 0)){
    Get-DnsClientNrptRule | Remove-DnsClientNrptRule -Force
  }

  # Wait a bit
  Start-Sleep 15
}
'@
  $Watcher.replace("`n", "`r`n") | Out-File -Encoding Default ($FolderPath + "\wg_watcher.ps1")

  # Install watcher service
  $nssm = ($FolderPath + "\nssm.exe")
  if(-not (Get-Service | Where{$_.name -eq "wg_watcher"})){
    & $nssm install wg_watcher (Get-Command powershell).Source ("-ExecutionPolicy Bypass -NoProfile -File " + $FolderPath + "\wg_watcher.ps1")
    & $nssm set wg_watcher AppDirectory $FolderPath
    & $nssm set wg_watcher DisplayName 'WireGuard Watcher Daemon'
  }

  # Start the service
  Start-Service wg_watcher
}
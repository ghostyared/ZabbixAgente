#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Instala Zabbix Agent 2 en Windows con reintentos, logs, reinicio automático
    del servicio ante fallos y regla de firewall restringida a los servidores Zabbix.
#>
[CmdletBinding()]
param(
    [string]$ZabbixServers = "192.168.100.200,192.168.100.205,172.16.0.205",
    [string]$ServerActive  = "",                 # Solo si usas checks activos. Vacío = no se configura
    [string]$Version       = "",                 # Vacío = detecta la última 7.0.x disponible en el CDN
    [string]$AgentHostname = $env:COMPUTERNAME,
    [int]   $Port          = 10050,
    [switch]$Force                               # Reinstala aunque ya exista el servicio
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ServiceName = 'Zabbix Agent 2'
$WorkDir     = 'C:\PS-Script\zabbix_agent_install'
$MsiLog      = Join-Path $WorkDir 'msi_install.log'
$ScriptLog   = Join-Path $WorkDir 'install.log'
$CdnBase     = 'https://cdn.zabbix.com/zabbix/binaries/stable/7.0'
$ConfPath    = 'C:\Program Files\Zabbix Agent 2\zabbix_agent2.conf'
$AgentLog    = 'C:\Program Files\Zabbix Agent 2\zabbix_agent2.log'

New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -Path $ScriptLog -Value $line
}

try {
    # 1) Instalación (solo si no existe o se usa -Force)
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc -or $Force) {

        # Resolver versión: si no se indicó, buscar la última 7.0.x publicada en el CDN
        if (-not $Version) {
            Write-Log "Buscando la última versión 7.0.x en $CdnBase/"
            $index = (Invoke-WebRequest -Uri "$CdnBase/" -UseBasicParsing).Content
            $Version = [regex]::Matches($index, 'href="?(7\.0\.\d+)/') |
                ForEach-Object { [version]$_.Groups[1].Value } |
                Sort-Object -Descending | Select-Object -First 1 |
                ForEach-Object { $_.ToString() }
            if (-not $Version) { throw "No se pudo detectar la versión. Indícala con -Version." }
        }
        $Url     = "$CdnBase/$Version/zabbix_agent2-$Version-windows-amd64-openssl.msi"
        $MsiPath = Join-Path $WorkDir "zabbix_agent2-$Version.msi"
        Write-Log "Versión a instalar: $Version"

        # Descarga con reintentos
        for ($i = 1; $i -le 3; $i++) {
            try {
                Write-Log "Descargando $Url (intento $i/3)"
                Invoke-WebRequest -Uri $Url -OutFile $MsiPath -UseBasicParsing
                break
            } catch {
                $code = $_.Exception.Response.StatusCode.value__
                if ($i -eq 3 -or $code -eq 404) { throw "No se pudo descargar $Url (HTTP $code): $($_.Exception.Message)" }
                Start-Sleep -Seconds 5
            }
        }

        $msiArgs = @(
            '/i', "`"$MsiPath`"",
            '/qn', '/norestart',
            '/l*v', "`"$MsiLog`"",
            "SERVER=$ZabbixServers",
            "HOSTNAME=$AgentHostname",
            "LISTENPORT=$Port",
            'SKIP=fw'            # el firewall lo gestionamos abajo
        )
        if ($ServerActive) { $msiArgs += "SERVERACTIVE=$ServerActive" }

        Write-Log "Instalando Zabbix Agent 2 $Version"
        $p = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
        if ($p.ExitCode -notin 0, 3010) {
            throw "msiexec terminó con código $($p.ExitCode). Revisa $MsiLog"
        }
    } else {
        Write-Log "El servicio '$ServiceName' ya existe; se omite la instalación (usa -Force para reinstalar)."
    }

    # 2) Servicio: inicio automático retrasado + reinicio automático si se cae
    sc.exe config $ServiceName start= delayed-auto | Out-Null   # inicio automático (retrasado)
    sc.exe failure $ServiceName reset= 86400 actions= restart/60000/restart/60000/restart/120000 | Out-Null
    sc.exe failureflag $ServiceName 1 | Out-Null
    Write-Log "Recuperación del servicio configurada (reinicio a 1 min, 1 min y 2 min)."

    # 3) Iniciar y verificar
    Start-Service -Name $ServiceName -ErrorAction SilentlyContinue
    (Get-Service -Name $ServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
    Write-Log "Servicio en estado: $((Get-Service -Name $ServiceName).Status)"

    # 4) Firewall: solo TCP (el agente no usa UDP) y solo desde los servidores Zabbix
    Get-NetFirewallRule -DisplayName 'Zabbix Agent Port TCP', 'Zabbix Agent Port UDP' -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule
    $ruleName = "Zabbix Agent 2 - TCP $Port"
    Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName $ruleName `
        -Direction Inbound -Protocol TCP -LocalPort $Port `
        -RemoteAddress ($ZabbixServers -split ',') `
        -Action Allow -Profile Any `
        -Description 'Permite conexiones de los servidores Zabbix al agente' | Out-Null
    Write-Log "Regla de firewall '$ruleName' creada."

    # 5) Validaciones finales
    if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
        Write-Log "El agente está escuchando en el puerto $Port."
    } else {
        Write-Log "El puerto $Port no aparece en escucha." 'WARN'
    }
    Write-Log "Configuración efectiva:"
    Select-String -Path $ConfPath -Pattern '^\s*(Server|ServerActive|Hostname|ListenPort)\s*=' |
        ForEach-Object { Write-Log "  $($_.Line)" }

    Write-Log "Despliegue completado en $env:COMPUTERNAME."
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)" 'ERROR'
    if (Test-Path $AgentLog) {
        Write-Log "Últimas líneas de zabbix_agent2.log:" 'ERROR'
        Get-Content $AgentLog -Tail 20 | ForEach-Object { Write-Log "  $_" 'ERROR' }
    }
    exit 1
}

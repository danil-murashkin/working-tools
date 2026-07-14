# WeAct USB2CAN - SLCAN console (PowerShell, Windows 11, 115200 8N1).
#
# Usage:
#   .\weact_slcan.ps1                 interactive console
#   .\weact_slcan.ps1 -Interactive    same
#   .\weact_slcan.ps1 v               firmware version (V)
#   .\weact_slcan.ps1 init 100000     C + S* + M0 + O
#   .\weact_slcan.ps1 send t002133    send CAN frame
#   .\weact_slcan.ps1 listen 100000   init + decode RX until Ctrl+C
#   .\weact_slcan.ps1 tx 100000 1     continuous TX
#   .\weact_slcan.ps1 monitor         raw RX (channel must be open)
#
# Documentation: equipment/weact_slcan.md
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Alias('d')]
    [string] $Device = $(if ($env:WEACT_DEV) { $env:WEACT_DEV } else { 'COM12' }),

    [Alias('i')]
    [switch] $Interactive,

    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]] $CommandArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:Baud = if ($env:WEACT_BAUD) { [int]$env:WEACT_BAUD } else { 115200 }
$Script:ReadMs = if ($env:WEACT_READ_MS) { [int]$env:WEACT_READ_MS } else { 300 }
$Script:DefaultBitrate = if ($env:WEACT_BITRATE) { [int]$env:WEACT_BITRATE } else { 100000 }

function Show-Usage {
    @"
WeAct USB2CAN SLCAN console (Windows)

Usage:
  weact_slcan.ps1 [-d COM12] [-Interactive]
  weact_slcan.ps1 [-d COM12] v|version
  weact_slcan.ps1 [-d COM12] reset
  weact_slcan.ps1 [-d COM12] init [bitrate]
  weact_slcan.ps1 [-d COM12] cmd SLCAN_COMMAND
  weact_slcan.ps1 [-d COM12] send [bitrate] FRAME
  weact_slcan.ps1 [-d COM12] listen [bitrate]
  weact_slcan.ps1 [-d COM12] tx [bitrate] [interval_sec] [slcan_frame]
  weact_slcan.ps1 [-d COM12] monitor

  Default device: COM12
  See equipment/weact_slcan.md for full guide.

Interactive keys:
  v, version          V
  init [bitrate]      C + S* + M0 + O
  m0, m1, o, c, e     M0, M1, O, C, E
  s3, s6, s8          S3 (100k), S6 (500k), S8 (1M)
  t002133             any raw SLCAN frame
  help, h, ?
  quit, q, exit

Environment:
  WEACT_DEV, WEACT_BAUD, WEACT_BITRATE, WEACT_READ_MS
"@ | Write-Host
}

function Get-BitrateCode {
    param([int] $Bitrate)
    switch ($Bitrate) {
        10000   { return 'S0' }
        20000   { return 'S1' }
        50000   { return 'S2' }
        100000  { return 'S3' }
        125000  { return 'S4' }
        250000  { return 'S5' }
        500000  { return 'S6' }
        800000  { return 'S7' }
        1000000 { return 'S8' }
        default { throw "Unsupported bitrate: $Bitrate (use 100000, 500000, ...)" }
    }
}

function Test-SlcanFrame {
    param([string] $Text)
    return $Text -match '^[tTbBrR]'
}

function Test-Bitrate {
    param([string] $Text)
    return $Text -match '^\d+$'
}

function New-SerialPort {
    param([string] $PortName)
    $port = New-Object System.IO.Ports.SerialPort $PortName, $Script:Baud, 'None', 8, 'One'
    $port.ReadTimeout = $Script:ReadMs
    $port.WriteTimeout = 1000
    $port.NewLine = "`r"
    $port.DtrEnable = $true
    $port.RtsEnable = $true
    $port.Encoding = [System.Text.Encoding]::ASCII
    return $port
}

function Read-SerialBytes {
    param(
        [System.IO.Ports.SerialPort] $Port,
        [int] $TimeoutMs = 300,
        [int] $MaxBytes = 512
    )
    $buffer = New-Object System.Collections.Generic.List[byte]
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)

    while ([DateTime]::UtcNow -lt $deadline -and $buffer.Count -lt $MaxBytes) {
        if ($Port.BytesToRead -gt 0) {
            $chunk = New-Object byte[] $Port.BytesToRead
            $read = $Port.Read($chunk, 0, $chunk.Length)
            if ($read -gt 0) {
                for ($i = 0; $i -lt $read; $i++) {
                    $buffer.Add($chunk[$i]) | Out-Null
                }
                $deadline = [DateTime]::UtcNow.AddMilliseconds(80)
            }
        } else {
            Start-Sleep -Milliseconds 5
        }
    }

    if ($buffer.Count -eq 0) {
        return ''
    }
    return [System.Text.Encoding]::ASCII.GetString($buffer.ToArray())
}

function Write-SlcanCommand {
    param(
        [System.IO.Ports.SerialPort] $Port,
        [string] $Command
    )
    $Port.Write($Command + "`r")
}

function Show-SlcanResponse {
    param(
        [string] $Command,
        [string] $Response
    )
    if ($Response -eq [char]0x07) {
        Write-Host '-> ERROR (\x07: CAN bus error / no ACK)'
        return $false
    }

    $text = $Response -replace "`r", '' -replace "`n", ''
    if ([string]::IsNullOrEmpty($text)) {
        Write-Host '-> OK'
        return $true
    }

    Write-Host "-> $text"
    return $true
}

function Show-RxLine {
    param([string] $Line)
    $line = $Line -replace "`r", '' -replace "`n", ''
    if ([string]::IsNullOrEmpty($line)) { return }
    if ($line -eq [char]0x07) {
        Write-Host 'RX ERROR (\x07)'
        return
    }

    if ($line -match '^t([0-9A-Fa-f]{3})([0-8])([0-9A-Fa-f]*)$') {
        $id = $Matches[1]
        $len = $Matches[2]
        $data = $Matches[3]
        $bytes = @()
        $ascii = ''
        for ($i = 0; $i -lt $data.Length; $i += 2) {
            $b = $data.Substring($i, 2)
            $bytes += $b
            $n = [Convert]::ToInt32($b, 16)
            if ($n -ge 32 -and $n -le 126) {
                $ascii += [char]$n
            } else {
                $ascii += '.'
            }
        }
        $byteText = if ($bytes.Count -gt 0) { ($bytes -join ' ') } else { '<none>' }
        Write-Host ('RX ID=0x{0} len={1} data={2} ascii="{3}"' -f $id, $len, $byteText, $ascii)
        return
    }

    Write-Host "RX $line"
}

function Invoke-SlcanExchange {
    param(
        [string] $PortName,
        [string] $Command
    )
    $port = New-SerialPort $PortName
    try {
        $port.Open()
        Write-SlcanCommand $port $Command
        $resp = Read-SerialBytes $port
        Write-Host "TX $Command"
        [void](Show-SlcanResponse $Command $resp)
    } finally {
        if ($port.IsOpen) { $port.Close() }
        $port.Dispose()
    }
}

function Send-SlcanExchange {
    param(
        [System.IO.Ports.SerialPort] $Port,
        [string] $Command
    )
    Write-SlcanCommand $Port $Command
    $resp = Read-SerialBytes $Port
    Write-Host "TX $Command"
    [void](Show-SlcanResponse $Command $resp)
}

function Send-SlcanSilent {
    param(
        [System.IO.Ports.SerialPort] $Port,
        [string] $Command
    )
    Write-SlcanCommand $Port $Command
    [void](Read-SerialBytes $Port -TimeoutMs 100 -MaxBytes 64)
}

function Open-SlcanChannel {
    param(
        [System.IO.Ports.SerialPort] $Port,
        [int] $Bitrate
    )
    $speed = Get-BitrateCode $Bitrate
    foreach ($cmd in @('C', $speed, 'M0', 'O')) {
        Send-SlcanSilent $Port $cmd
    }
}

function Drain-Rx {
    param([System.IO.Ports.SerialPort] $Port)
    $chunk = Read-SerialBytes $Port -TimeoutMs 50 -MaxBytes 512
    if ([string]::IsNullOrEmpty($chunk)) { return }

    foreach ($part in ($chunk -split "`r")) {
        Show-RxLine $part
    }
}

function Start-ListenLoop {
    param([System.IO.Ports.SerialPort] $Port)
    while ($true) {
        Drain-Rx $Port
        Start-Sleep -Milliseconds 50
    }
}

function Start-InteractiveSession {
    param([string] $PortName)
    $port = New-SerialPort $PortName
    try {
        $port.Open()
        Write-Host "WeAct SLCAN on $PortName ($($Script:Baud) baud). Type help."
        Send-SlcanSilent $port 'C'

        while ($true) {
            Drain-Rx $port
            $line = Read-Host 'slcan>'
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            $cmd = ($line -split '\s+', 2)[0].ToLowerInvariant()
            switch ($cmd) {
                { $_ -in 'help', 'h', '?' } {
                    @"
Commands:
  v, version                 read firmware (V)
  init [bitrate]             C + S* + M0 + O (default 100000)
  m0 m1 o c e                mode / open / close / errors
  s3 s6 s8                   100k / 500k / 1M
  t002133                    any SLCAN frame
  quit                       exit
"@ | Write-Host
                }
                { $_ -in 'quit', 'q', 'exit' } { break }
                { $_ -in 'version', 'v' } { Send-SlcanExchange $port 'V' }
                'init' {
                    $brText = $line.Substring(4).Trim()
                    if ([string]::IsNullOrEmpty($brText)) { $brText = '100000' }
                    $speed = Get-BitrateCode ([int]$brText)
                    Send-SlcanExchange $port 'C'
                    Send-SlcanExchange $port $speed
                    Send-SlcanExchange $port 'M0'
                    Send-SlcanExchange $port 'O'
                    Send-SlcanExchange $port 'E'
                }
                'm0' { Send-SlcanExchange $port 'M0' }
                'm1' { Send-SlcanExchange $port 'M1' }
                'o'  { Send-SlcanExchange $port 'O' }
                'c'  { Send-SlcanExchange $port 'C' }
                'e'  { Send-SlcanExchange $port 'E' }
                { $_ -match '^s[0-8]$' } { Send-SlcanExchange $port $cmd.ToUpperInvariant() }
                default { Send-SlcanExchange $port $line }
            }
            Drain-Rx $port
        }

        Send-SlcanSilent $port 'C'
        Write-Host 'Bye.'
    } finally {
        if ($port.IsOpen) { $port.Close() }
        $port.Dispose()
    }
}

function Start-InitSession {
    param(
        [string] $PortName,
        [int] $Bitrate = 100000
    )
    $speed = Get-BitrateCode $Bitrate
    $port = New-SerialPort $PortName
    try {
        $port.Open()
        Write-Host "Init $PortName @ $Bitrate bit/s ($speed), normal mode"
        Open-SlcanChannel $port $Bitrate
        Send-SlcanExchange $port 'E'
    } finally {
        if ($port.IsOpen) { $port.Close() }
        $port.Dispose()
    }
}

function Send-FrameSession {
    param(
        [string] $PortName,
        [int] $Bitrate,
        [string] $Frame
    )
    $speed = Get-BitrateCode $Bitrate
    $port = New-SerialPort $PortName
    try {
        $port.Open()
        Write-Host "Open $PortName @ $Bitrate bit/s ($speed)"
        Open-SlcanChannel $port $Bitrate
        Write-SlcanCommand $port $Frame
        $resp = Read-SerialBytes $port
        Write-Host "TX $Frame"
        [void](Show-SlcanResponse $Frame $resp)
    } finally {
        if ($port.IsOpen) { $port.Close() }
        $port.Dispose()
    }
}

function Start-ListenSession {
    param(
        [string] $PortName,
        [int] $Bitrate = 100000
    )
    $speed = Get-BitrateCode $Bitrate
    $port = New-SerialPort $PortName
    $port.ReadTimeout = 50
    try {
        $port.Open()
        Write-Host ('Listen {0} @ {1} bit/s ({2}) - Ctrl+C to stop' -f $PortName, $Bitrate, $speed)
        Open-SlcanChannel $port $Bitrate
        Start-ListenLoop $port
    } catch [System.Management.Automation.PipelineStoppedException] {
        # Ctrl+C
    } finally {
        try { Send-SlcanSilent $port 'C' } catch { }
        if ($port.IsOpen) { $port.Close() }
        $port.Dispose()
    }
}

function Start-MonitorSession {
    param([string] $PortName)
    $port = New-SerialPort $PortName
    $port.ReadTimeout = 50
    try {
        $port.Open()
        Write-Host ('Monitor {0} - incoming SLCAN (open channel first: init/listen)' -f $PortName)
        Start-ListenLoop $port
    } catch [System.Management.Automation.PipelineStoppedException] {
        # Ctrl+C
    } finally {
        if ($port.IsOpen) { $port.Close() }
        $port.Dispose()
    }
}

function Start-TxSession {
    param(
        [string] $PortName,
        [int] $Bitrate = 100000,
        [double] $IntervalSec = 1,
        [string] $Frame = 't100474657374'
    )
    $speed = Get-BitrateCode $Bitrate
    $port = New-SerialPort $PortName
    try {
        $port.Open()
        Write-Host ('TX {0} @ {1} bit/s ({2}) frame={3} every {4}s - Ctrl+C to stop' -f $PortName, $Bitrate, $speed, $Frame, $IntervalSec)
        Open-SlcanChannel $port $Bitrate

        while ($true) {
            Write-SlcanCommand $port $Frame
            $resp = Read-SerialBytes $port -TimeoutMs 100 -MaxBytes 64
            if ($resp -eq [char]0x07) {
                Write-Warning ('{0} -> bus error (0x07, no ACK)' -f $Frame)
            }
            Start-Sleep -Seconds $IntervalSec
        }
    } catch [System.Management.Automation.PipelineStoppedException] {
        # Ctrl+C
    } finally {
        try { Send-SlcanSilent $port 'C' } catch { }
        if ($port.IsOpen) { $port.Close() }
        $port.Dispose()
    }
}

function Invoke-SendCommand {
    param(
        [string] $PortName,
        [string[]] $Args
    )
    $br = $Script:DefaultBitrate
    $frame = ''

    if ($Args.Count -eq 1) {
        $frame = $Args[0]
    } elseif ($Args.Count -eq 2 -and (Test-Bitrate $Args[0]) -and (Test-SlcanFrame $Args[1])) {
        $br = [int]$Args[0]
        $frame = $Args[1]
    } else {
        throw 'Usage: send [bitrate] FRAME   e.g. send t002133 or send 100000 t002133'
    }

    if (-not (Test-SlcanFrame $frame)) {
        throw "Expected SLCAN frame (t/T/b/...), got: $frame"
    }

    Send-FrameSession $PortName $br $frame
}

# --- main ---
if ($CommandArgs -contains '-h' -or $CommandArgs -contains '--help' -or $CommandArgs -contains 'help') {
    Show-Usage
    exit 0
}

if ($Interactive -or $CommandArgs.Count -eq 0) {
    Start-InteractiveSession $Device
    exit 0
}

$verb = $CommandArgs[0]
$rest = @()
if ($CommandArgs.Count -gt 1) {
    $rest = $CommandArgs[1..($CommandArgs.Count - 1)]
}

switch ($verb.ToLowerInvariant()) {
    { $_ -in 'v', 'version' } {
        Invoke-SlcanExchange $Device 'V'
    }
    'init' {
        $br = if ($rest.Count -ge 1) { [int]$rest[0] } else { 100000 }
        Start-InitSession $Device $br
    }
    'reset' {
        Invoke-SlcanExchange $Device 'C'
    }
    'cmd' {
        if ($rest.Count -lt 1) { throw 'Usage: cmd SLCAN_COMMAND' }
        if (Test-SlcanFrame $rest[0]) {
            Invoke-SendCommand $Device $rest
        } else {
            Invoke-SlcanExchange $Device $rest[0]
        }
    }
    'send' {
        if ($rest.Count -lt 1) { throw 'Usage: send [bitrate] FRAME' }
        Invoke-SendCommand $Device $rest
    }
    'listen' {
        $br = if ($rest.Count -ge 1) { [int]$rest[0] } else { 100000 }
        Start-ListenSession $Device $br
    }
    'monitor' {
        Start-MonitorSession $Device
    }
    'tx' {
        $br = if ($rest.Count -ge 1) { [int]$rest[0] } else { 100000 }
        $interval = if ($rest.Count -ge 2) { [double]$rest[1] } else { 1 }
        $frame = if ($rest.Count -ge 3) { $rest[2] } else { 't100474657374' }
        Start-TxSession $Device $br $interval $frame
    }
    default {
        if ($verb -match '^[tTbBrR]' -or $verb -match '^[MS]' -or $verb -in @('O', 'C', 'E', 'V')) {
            Invoke-SlcanExchange $Device $verb
        } else {
            Write-Error "Unknown command: $verb"
            Show-Usage
            exit 2
        }
    }
}

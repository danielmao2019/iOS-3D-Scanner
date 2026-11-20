# Takes the RGBD Scanner app's Wired transfer recordings from the iPhone plugged into this computer by USB cable, while they record and once they are finished, and stores each as <folder>\<scan_id>.tar, the file server/receive.py writes, <folder> being the folder the recording's config names on this computer or, when it names none, this computer's Downloads folder. It needs nothing installed beyond Apple Devices; paste into PowerShell:
#   irm https://raw.githubusercontent.com/danielmao2019/iOS-3D-Scanner/main/server/pull.ps1 | iex
# It runs until Ctrl+C, waiting while the phone is unplugged or the app is off screen.
#
# The app (from v1.6.0) serves its Wired transfer recordings while it is on screen, on port 8765 of the phone's loopback, which this computer reaches only through usbmux, Apple's USB multiplexer: on Windows the Apple Mobile Device Service, which Apple Devices installs, at 127.0.0.1:27015; the environment variable USBMUXD_SOCKET_ADDRESS, <host>:<port>, names another. app/Sources/RGBDScanner/WiredServer.swift documents the requests. Every two seconds this script lists the recordings and fetches each file the phone holds that it does not, into <folder>\.<key>.staging\, keeping it beside <name>.sha256 only when its size and SHA-256 are those the phone recorded; a segment it keeps is acknowledged, and the phone deletes it, as the receiver acknowledges segments uploaded over Wi-Fi. Once a recording is finished and every file of it is kept, its members are written as <folder>\<scan_id>.tar, an uncompressed GNU tar holding them under <scan_id>\ in the phone's order, a frames file its segments joined, through a temporary file renamed into place; only then is the phone told the recording is stored, and it deletes it, and the staging folder is removed.
& {
    $ErrorActionPreference = 'Stop'
    $PhonePort = 8765
    $ChunkBytes = 4MB
    $PollSeconds = 2
    # usbmux's plist messages: a 16-byte little-endian header (total length, version 1, type 8 for a plist, tag), then an XML plist.
    $UsbmuxPlist = 8
    # Connect's result when nothing listens on the phone's port.
    $UsbmuxRefused = 3

    function Get-UsbmuxClient {
        $address = if ($env:USBMUXD_SOCKET_ADDRESS) { $env:USBMUXD_SOCKET_ADDRESS } else { '127.0.0.1:27015' }
        $hostName, $port = $address -split ':'
        return New-Object System.Net.Sockets.TcpClient($hostName, [int]$port)
    }

    function Read-Exactly($stream, [long]$count) {
        $buffer = New-Object byte[] $count
        $offset = 0
        while ($offset -lt $count) {
            $read = $stream.Read($buffer, $offset, $count - $offset)
            if ($read -le 0) { throw 'the connection closed early' }
            $offset += $read
        }
        return ,$buffer
    }

    function ConvertTo-Plist([System.Collections.IDictionary]$message) {
        $entries = foreach ($key in $message.Keys) {
            $value = $message[$key]
            if ($value -is [int] -or $value -is [long]) { "<key>$key</key><integer>$value</integer>" } else { "<key>$key</key><string>$value</string>" }
        }
        return '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>' + ($entries -join '') + '</dict></plist>'
    }

    function ConvertFrom-PlistNode($node) {
        $children = @($node.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })
        switch ($node.LocalName) {
            'dict' {
                $table = @{}
                for ($i = 0; $i -lt $children.Count; $i += 2) { $table[$children[$i].InnerText] = ConvertFrom-PlistNode $children[$i + 1] }
                return $table
            }
            'array' { return ,@($children | ForEach-Object { ConvertFrom-PlistNode $_ }) }
            'integer' { return [long]$node.InnerText }
            'true' { return $true }
            'false' { return $false }
            default { return $node.InnerText }
        }
    }

    # Sends a plist message to usbmux and returns its reply.
    function Invoke-Usbmux($stream, [System.Collections.IDictionary]$message) {
        $message['ClientVersionString'] = 'pull.ps1'
        $message['ProgName'] = 'pull.ps1'
        $body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Plist $message))
        $header = New-Object byte[] 16
        [BitConverter]::GetBytes([uint32](16 + $body.Length)).CopyTo($header, 0)
        [BitConverter]::GetBytes([uint32]1).CopyTo($header, 4)
        [BitConverter]::GetBytes([uint32]$UsbmuxPlist).CopyTo($header, 8)
        [BitConverter]::GetBytes([uint32]1).CopyTo($header, 12)
        $stream.Write($header, 0, 16)
        $stream.Write($body, 0, $body.Length)
        $length = [BitConverter]::ToUInt32((Read-Exactly $stream 16), 0)
        # The DOCTYPE names Apple's DTD, which is not needed to read the plist.
        $xml = [Text.Encoding]::UTF8.GetString((Read-Exactly $stream ($length - 16))) -replace '<!DOCTYPE[^>]*>', ''
        $root = @(([xml]$xml).DocumentElement.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })[0]
        return ConvertFrom-PlistNode $root
    }

    # usbmux's DeviceID of the one iPhone plugged in by USB.
    function Get-PhoneDeviceId {
        $client = Get-UsbmuxClient
        try { $reply = Invoke-Usbmux $client.GetStream() @{ MessageType = 'ListDevices' } } finally { $client.Close() }
        $phones = @($reply['DeviceList'] | Where-Object { $_['Properties']['ConnectionType'] -eq 'USB' })
        if ($phones.Count -ne 1) { throw "$($phones.Count) iPhones are plugged in by USB: plug in one, unlock it and tap Trust" }
        return $phones[0]['DeviceID']
    }

    # Sends one HTTP request to the app over a new usbmux connection and returns its client, stream, status and Content-Length, the body unread.
    function Invoke-Phone($deviceId, [string]$method, [string]$path, [string]$sha256) {
        $client = Get-UsbmuxClient
        $stream = $client.GetStream()
        $port = (($PhonePort -band 0xFF) -shl 8) -bor ($PhonePort -shr 8)
        $result = Invoke-Usbmux $stream @{ MessageType = 'Connect'; DeviceID = [int]$deviceId; PortNumber = [int]$port }
        if ($result['Number'] -ne 0) {
            $client.Close()
            if ($result['Number'] -eq $UsbmuxRefused) { throw 'RGBD Scanner does not answer: open it on the phone, from version 1.6.0, and keep it on screen' }
            throw "usbmux cannot reach the phone: result $($result['Number'])"
        }
        $request = "$method $path HTTP/1.1`r`nHost: phone`r`nContent-Length: 0`r`n"
        if ($sha256) { $request += "X-Content-SHA256: $sha256`r`n" }
        $bytes = [Text.Encoding]::ASCII.GetBytes($request + "Connection: close`r`n`r`n")
        $stream.Write($bytes, 0, $bytes.Length)
        $head = New-Object System.Collections.Generic.List[byte]
        while ($head.Count -lt 4 -or $head[$head.Count - 4] -ne 13 -or $head[$head.Count - 3] -ne 10 -or $head[$head.Count - 2] -ne 13 -or $head[$head.Count - 1] -ne 10) {
            $byte = $stream.ReadByte()
            if ($byte -lt 0) { $client.Close(); throw "$method $path`: the phone closed the connection without an answer" }
            $head.Add([byte]$byte)
        }
        $text = [Text.Encoding]::ASCII.GetString($head.ToArray())
        return @{ Client = $client; Stream = $stream; Status = [int]($text -split ' ')[1]; Length = [long][regex]::Match($text, '(?im)^Content-Length:\s*(\d+)').Groups[1].Value }
    }

    function Invoke-PhoneJson($deviceId, [string]$method, [string]$path, [string]$sha256) {
        $reply = Invoke-Phone $deviceId $method $path $sha256
        try { $body = [Text.Encoding]::UTF8.GetString((Read-Exactly $reply.Stream $reply.Length)) } finally { $reply.Client.Close() }
        if ($reply.Status -ne 200) { throw "$method $path`: the phone replied $($reply.Status): $body" }
        return $body | ConvertFrom-Json
    }

    # This computer's Downloads folder, wherever the user keeps it.
    function Get-DownloadsFolder {
        if ($env:OS -eq 'Windows_NT') { return (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path }
        return Join-Path $HOME 'Downloads'
    }

    # Whether the staging folder keeps the file, at its size and beside its SHA-256.
    function Test-Kept([string]$staging, $file) {
        $kept = Join-Path $staging $file.name
        return (Test-Path -LiteralPath $kept) -and (Test-Path -LiteralPath "$kept.sha256") -and ((Get-Item -LiteralPath $kept).Length -eq $file.size) -and ((Get-Content -LiteralPath "$kept.sha256" -Raw) -eq $file.sha256)
    }

    # Fetches one of a recording's files into the staging folder while hashing it, keeping it only when its size and SHA-256 are the phone's; returns the bytes fetched.
    function Save-PhoneFile($deviceId, [string]$key, $file, [string]$staging) {
        if (Test-Kept $staging $file) { return 0 }
        $kept = Join-Path $staging $file.name
        $part = "$kept.part"
        $reply = Invoke-Phone $deviceId 'GET' "/files/$key/$($file.name)" $null
        $sha = [Security.Cryptography.SHA256]::Create()
        $out = [IO.File]::Create($part)
        try {
            if ($reply.Status -ne 200) { throw "$($file.name): the phone replied $($reply.Status)" }
            $buffer = New-Object byte[] $ChunkBytes
            $remaining = $reply.Length
            while ($remaining -gt 0) {
                $read = $reply.Stream.Read($buffer, 0, [int][Math]::Min($ChunkBytes, $remaining))
                if ($read -le 0) { throw "$($file.name): the connection closed with $remaining bytes missing" }
                $out.Write($buffer, 0, $read)
                $null = $sha.TransformBlock($buffer, 0, $read, $null, 0)
                $remaining -= $read
            }
            $null = $sha.TransformFinalBlock($buffer, 0, 0)
        } finally {
            $out.Close()
            $reply.Client.Close()
        }
        $hex = -join ($sha.Hash | ForEach-Object { $_.ToString('x2') })
        if ($reply.Length -ne $file.size -or $hex -ne $file.sha256) {
            Remove-Item -LiteralPath $part
            throw "$($file.name): received $($reply.Length) bytes with SHA-256 $hex, the phone recorded $($file.size) bytes with $($file.sha256)"
        }
        Set-Content -LiteralPath "$kept.sha256" -Value $file.sha256 -NoNewline
        Move-Item -LiteralPath $part -Destination $kept -Force
        return $file.size
    }

    # A GNU tar member header: the name, mode 664, the size in octal or, from 8 GiB, in base-256, the time, and the checksum.
    function New-TarHeader([string]$name, [long]$size, [long]$time) {
        if ($name.Length -gt 100) { throw "$name is longer than a tar name" }
        $header = New-Object byte[] 512
        $fields = @(@($name, 0), @('0000664', 100), @('0000000', 108), @('0000000', 116), @([Convert]::ToString($time, 8).PadLeft(11, '0'), 136), @('        ', 148), @('0', 156), @('ustar  ', 257))
        if ($size -lt 8GB) { $fields += , @([Convert]::ToString($size, 8).PadLeft(11, '0'), 124) } else {
            $header[124] = 0x80
            for ($i = 0; $i -lt 8; $i++) { $header[135 - $i] = [byte](($size -shr (8 * $i)) -band 0xFF) }
        }
        foreach ($field in $fields) { $bytes = [Text.Encoding]::ASCII.GetBytes($field[0]); [Array]::Copy($bytes, 0, $header, $field[1], $bytes.Length) }
        $sum = 0
        foreach ($byte in $header) { $sum += $byte }
        $bytes = [Text.Encoding]::ASCII.GetBytes([Convert]::ToString($sum, 8).PadLeft(6, '0'))
        [Array]::Copy($bytes, 0, $header, 148, 6)
        $header[154] = 0
        return ,$header
    }

    # Writes a finished recording's kept files as <folder>\<scan_id>.tar, through a temporary file renamed into place.
    function Write-RecordingTar($recording, [string]$staging, [string]$archive) {
        $part = Join-Path (Split-Path -Parent $archive) ".$($recording.scan_id).tar.part"
        $time = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $out = [IO.File]::Create($part)
        try {
            foreach ($member in $recording.members) {
                $files = if ($null -ne $member.segments) { @($member.segments) } else { @($member) }
                $size = 0L
                foreach ($file in $files) { $size += $file.size }
                $out.Write((New-TarHeader "$($recording.scan_id)/$($member.name)" $size $time), 0, 512)
                foreach ($file in $files) {
                    $in = [IO.File]::OpenRead((Join-Path $staging $file.name))
                    try { $in.CopyTo($out, $ChunkBytes) } finally { $in.Close() }
                }
                $out.Write((New-Object byte[] 512), 0, (512 - $size % 512) % 512)
            }
            # Two zero blocks end the archive, padded to whole 10240-byte records as Python's tarfile writes it.
            $out.Write((New-Object byte[] 1024), 0, 1024)
            $out.Write((New-Object byte[] 10240), 0, (10240 - $out.Length % 10240) % 10240)
        } finally {
            $out.Close()
        }
        Move-Item -LiteralPath $part -Destination $archive
    }

    # Takes what the phone holds of one recording: its files, each segment acknowledged once kept, and, once it is finished, its tar, after which the phone deletes it.
    function Receive-Recording($deviceId, $recording, [hashtable]$taken) {
        $label = if ($recording.scan_id) { $recording.scan_id } else { "recording $($recording.key)" }
        $folder = if ($recording.path) { $recording.path } else { Get-DownloadsFolder }
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { throw "$label goes to $folder, which does not exist on this computer: create it, or change the Wired transfer folder on the phone" }
        $staging = Join-Path $folder ".$($recording.key).staging"
        $null = New-Item -ItemType Directory -Force -Path $staging
        foreach ($file in $recording.files) {
            $taken[$recording.key] += Save-PhoneFile $deviceId $recording.key $file $staging
            Write-Host -NoNewline "`r$label`: $('{0:N2}' -f ($taken[$recording.key] / 1GB)) GB taken "
            if ($file.name -match '\.[0-9]{6}$') { $null = Invoke-PhoneJson $deviceId 'POST' "/acknowledged/$($recording.key)/$($file.name)" $file.sha256 }
        }
        if ($null -eq $recording.members) { return }
        $archive = Join-Path $folder "$($recording.scan_id).tar"
        if (-not (Test-Path -LiteralPath $archive)) {
            foreach ($member in $recording.members) {
                foreach ($file in $(if ($null -ne $member.segments) { @($member.segments) } else { @($member) })) {
                    if (-not (Test-Kept $staging $file)) { throw "$label lacks $($file.name), which neither this computer nor the phone holds" }
                }
            }
            Write-RecordingTar $recording $staging $archive
            Write-Host "`n$label`: stored as $archive"
        }
        $null = Invoke-PhoneJson $deviceId 'POST' "/stored/$($recording.scan_id)" $null
        Remove-Item -LiteralPath $staging -Recurse -Force
        $taken.Remove($recording.key)
        Write-Host "$label`: deleted from the phone"
    }

    Write-Host 'Taking Wired transfer recordings from the iPhone; keep RGBD Scanner open on it. Ctrl+C stops.'
    $deviceId = $null
    # The last message printed for the phone (key '') and for each recording, so a wait is printed once.
    $waiting = @{}
    $taken = @{}
    while ($true) {
        try {
            if ($null -eq $deviceId) { $deviceId = Get-PhoneDeviceId }
            $recordings = (Invoke-PhoneJson $deviceId 'GET' '/recordings' $null).recordings
            $waiting.Remove('')
        } catch {
            $deviceId = $null
            if ($_.Exception.Message -ne $waiting['']) {
                $waiting[''] = $_.Exception.Message
                Write-Host "`nWaiting: $($waiting[''])"
            }
            Start-Sleep -Seconds $PollSeconds
            continue
        }
        # A recording that cannot be taken yet waits without holding up the others.
        foreach ($recording in $recordings) {
            try {
                Receive-Recording $deviceId $recording $taken
                $waiting.Remove($recording.key)
            } catch {
                if ($_.Exception.Message -ne $waiting[$recording.key]) {
                    $waiting[$recording.key] = $_.Exception.Message
                    Write-Host "`nWaiting: $($waiting[$recording.key])"
                }
            }
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

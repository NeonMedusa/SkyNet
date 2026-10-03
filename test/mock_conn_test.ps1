# 连接复用验证 mock：与 mock_openai_sse 同协议，但记录 TCP 连接数。
# 原理：HttpListener 无法直接暴露连接 id；改用 TcpListener 手工实现最小 HTTP/1.1
# 服务端，按 socket 记录连接建立次数与请求次数，写入日志。
$ErrorActionPreference = "Stop"
$marker = Join-Path $PSScriptRoot "mock_conn_18128.running"
"running" | Set-Content $marker
$log = Join-Path $env:TEMP "skynet_conn_test.log"
"START $(Get-Date -Format o)" | Set-Content $log

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 18128)
$listener.Start()

$conn_count = 0
$req_count = 0

function Read-HttpRequest($stream) {
    # 读 header 直到 \r\n\r\n，再按 Content-Length 读 body
    $ms = New-Object System.IO.MemoryStream
    $buf = New-Object byte[] 1
    $state = 0  # 匹配 \r\n\r\n
    while ($true) {
        $n = $stream.Read($buf, 0, 1)
        if ($n -le 0) { return $null }
        $ms.WriteByte($buf[0])
        switch ($state) {
            0 { if ($buf[0] -eq 13) { $state = 1 } }
            1 { if ($buf[0] -eq 10) { $state = 2 } else { $state = 0 } }
            2 { if ($buf[0] -eq 13) { $state = 3 } else { $state = 0 } }
            3 { if ($buf[0] -eq 10) { $state = 4 } else { $state = 0 } }
        }
        if ($state -eq 4) { break }
    }
    $headerBytes = $ms.ToArray()
    $headerText = [System.Text.Encoding]::ASCII.GetString($headerBytes)
    $cl = 0
    if ($headerText -match '(?im)^content-length:\s*(\d+)') { $cl = [int]$Matches[1] }
    $body = ""
    if ($cl -gt 0) {
        $bodyBuf = New-Object byte[] $cl
        $read = 0
        while ($read -lt $cl) {
            $n = $stream.Read($bodyBuf, $read, $cl - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        $body = [System.Text.Encoding]::UTF8.GetString($bodyBuf, 0, $read)
    }
    return @{ Header = $headerText; Body = $body }
}

function Send-SseResponse($stream, $payload) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $head = "HTTP/1.1 200 OK`r`nContent-Type: text/event-stream`r`nTransfer-Encoding: chunked`r`nConnection: keep-alive`r`n`r`n"
    $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
    $stream.Write($hb, 0, $hb.Length)
    # chunked: <hex len>\r\n<data>\r\n0\r\n\r\n
    $chunkHead = [System.Text.Encoding]::ASCII.GetBytes(("{0:X}`r`n" -f $bytes.Length))
    $stream.Write($chunkHead, 0, $chunkHead.Length)
    $stream.Write($bytes, 0, $bytes.Length)
    $crlf = [System.Text.Encoding]::ASCII.GetBytes("`r`n0`r`n`r`n")
    $stream.Write($crlf, 0, $crlf.Length)
    $stream.Flush()
}

function Tool-CallChunks([string]$id, [string]$name, [string]$argJson) {
    $esc = $argJson -replace '\\', '\\' -replace '"', '\"'
    $s1 = 'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"' + $id + '","function":{"name":"' + $name + '","arguments":"' + $esc + '"}}]}}]}' + "`n`n"
    $s2 = 'data: {"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":80}}}' + "`n`n"
    $s3 = "data: [DONE]`n`n"
    return ($s1 + $s2 + $s3)
}

try {
    while ($true) {
        $tcp = $listener.AcceptTcpClient()
        $conn_count++
        Add-Content $log "CONN $conn_count accepted"
        $stream = $tcp.GetStream()
        # 一条连接上可服务多个请求（keep-alive）
        while ($tcp.Connected) {
            $req = $null
            try { $req = Read-HttpRequest $stream } catch { break }
            if ($null -eq $req) { break }
            $req_count++
            $body = $req.Body
            $round = if ($body -notmatch '"role": ?"tool"') { 1 } elseif ($body -notmatch 'call_bash') { 2 } else { 3 }
            Add-Content $log "REQ $req_count conn=$conn_count round=$round"
            $chunks = @()
            if ($round -eq 1) {
                $chunks += Tool-CallChunks "call_ls" "ls" '{"path":"."}'
            } elseif ($round -eq 2) {
                $chunks += Tool-CallChunks "call_bash" "bash" '{"command":"Write-Output mock-out"}'
            } else {
                $chunks += 'data: {"choices":[{"delta":{"content":"done"}}]}' + "`n`n"
                $chunks += 'data: {"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":80}}}' + "`n`n"
                $chunks += "data: [DONE]`n`n"
            }
            Send-SseResponse $stream ($chunks -join "")
        }
        $tcp.Close()
        Add-Content $log "CONN $conn_count closed"
    }
} finally {
    $listener.Stop()
    Add-Content $log "DONE"
    Remove-Item $marker -ErrorAction SilentlyContinue
}

# 半开连接 mock（端口 18131）：收到请求后发一段 SSE（无 [DONE]），然后**挂起**：
# 不发终止块、不关连接，阻塞读直到客户端关闭 —— 模拟"服务端既不发送也不关闭"。
# 每个连接独立处理（Start-ThreadJob），支持并发连接（客户端重试会开新连接）。
# 启动时写标记文件 test/mock_halfopen_18131.running，测试据此决定是否跳过。
$ErrorActionPreference = "Continue"
$marker = Join-Path $PSScriptRoot "mock_halfopen_18131.running"
"running" | Set-Content $marker
$log = Join-Path $env:TEMP "skynet_halfopen_test.log"
"START $(Get-Date -Format o)" | Set-Content $log

$handler = {
    param($tcp, $logPath)
    function HLog([string]$m) { "$(Get-Date -Format 'HH:mm:ss.fff') $m" | Add-Content $logPath }
    $stream = $tcp.GetStream()
    try {
        $tcp.NoDelay = $true
        # 安全网：即使客户端看门狗失效，挂起 20s 后也断开（测试失败而非永久挂起）
        $stream.ReadTimeout = 20000
        # 读请求头（直到 CRLFCRLF）
        $ms = New-Object System.IO.MemoryStream
        $b = New-Object byte[] 1
        $state = 0
        while ($state -lt 4) {
            $n = $stream.Read($b, 0, 1)
            if ($n -le 0) { HLog "conn: eof before request"; return }
            $ms.WriteByte($b[0])
            switch ($state) {
                0 { if ($b[0] -eq 13) { $state = 1 } }
                1 { if ($b[0] -eq 10) { $state = 2 } else { $state = 0 } }
                2 { if ($b[0] -eq 13) { $state = 3 } else { $state = 0 } }
                3 { if ($b[0] -eq 10) { $state = 4 } else { $state = 0 } }
            }
            if ($ms.Length -gt 65536) { break }
        }
        HLog "conn: request head received ($($ms.Length) bytes)"
        # 响应头 + 一段 SSE（无 [DONE]）
        $head = "HTTP/1.1 200 OK`r`nContent-Type: text/event-stream`r`nTransfer-Encoding: chunked`r`nConnection: keep-alive`r`n`r`n"
        $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
        $stream.Write($hb, 0, $hb.Length)
        $payload = 'data: {"choices":[{"delta":{"content":"部分输出"}}]}' + "`n`n"
        $pb = [System.Text.Encoding]::UTF8.GetBytes($payload)
        $ch = [System.Text.Encoding]::ASCII.GetBytes(("{0:X}`r`n" -f $pb.Length))
        $stream.Write($ch, 0, $ch.Length)
        $stream.Write($pb, 0, $pb.Length)
        $crlf = [System.Text.Encoding]::ASCII.GetBytes("`r`n")
        $stream.Write($crlf, 0, 2)
        $stream.Flush()
        HLog "conn: partial SSE sent; hanging (half-open)"
        # 挂起：阻塞读直到客户端关闭（永不发 [DONE]/终止块、不主动关）
        $rb = New-Object byte[] 1024
        while ($true) {
            $n = $stream.Read($rb, 0, $rb.Length)
            if ($n -le 0) { break }
        }
        HLog "conn: client closed"
    } catch {
        HLog "conn: err $($_.Exception.Message)"
    } finally {
        try { $tcp.Close() } catch {}
    }
}

try {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 18131)
    $listener.Start()
    "$(Get-Date -Format 'HH:mm:ss.fff') listening on 18131" | Add-Content $log
    while ($true) {
        $tcp = $listener.AcceptTcpClient()
        "$(Get-Date -Format 'HH:mm:ss.fff') accepted connection" | Add-Content $log
        Start-ThreadJob -ScriptBlock $handler -ArgumentList $tcp, $log | Out-Null
    }
} finally {
    try { $listener.Stop() } catch {}
    "DONE $(Get-Date -Format o)" | Add-Content $log
    Remove-Item $marker -ErrorAction SilentlyContinue
}

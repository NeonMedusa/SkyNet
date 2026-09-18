# 模拟网关/网络在生成中途断开：返回 200 + SSE，发一段 reasoning 增量后
# 正常结束 HTTP body，但既不发送 finish_reason 也不发送 [DONE]。
# 客户端（SkyNet）应判定为 StreamTruncated，而不是静默地"正常结束"。
$ErrorActionPreference = "Stop"
$marker = Join-Path $PSScriptRoot "mock_18126.running"
"running" | Set-Content $marker
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 18126)
$listener.Start()
$log = Join-Path $env:TEMP "skynet_mock_truncated.log"
"START $(Get-Date -Format o)" | Set-Content $log
try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $stream.ReadTimeout = 400
            $buf = [byte[]]::new(65536)
            $total = 0
            while ($true) {
                try {
                    $n = $stream.Read($buf, 0, $buf.Length)
                }
                catch {
                    break   # 读超时 = 请求已发完
                }
                if ($n -le 0) { break }
                $total += $n
            }
            Add-Content $log "REQ bytes=$total"

            # 合法的 chunked 响应：一个 SSE 数据块 + 终止块（HTTP 层面完整，SSE 层面被截断）
            $payload = 'data: {"choices":[{"delta":{"reasoning_content":"被截断的思考……"}}]}' + "`n`n"
            $payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
            $head = "HTTP/1.1 200 OK`r`nContent-Type: text/event-stream`r`nTransfer-Encoding: chunked`r`nConnection: close`r`n`r`n"
            $chunkHead = [System.Text.Encoding]::ASCII.GetBytes("$($payloadBytes.Length.ToString('x'))`r`n")
            $chunkTail = [System.Text.Encoding]::ASCII.GetBytes("`r`n0`r`n`r`n")
            $headBytes = [System.Text.Encoding]::ASCII.GetBytes($head)
            $stream.Write($headBytes, 0, $headBytes.Length)
            $stream.Write($chunkHead, 0, $chunkHead.Length)
            $stream.Write($payloadBytes, 0, $payloadBytes.Length)
            $stream.Write($chunkTail, 0, $chunkTail.Length)
            $stream.Flush()
            # 不发送 finish_reason / [DONE]，直接关闭连接
        }
        finally {
            $client.Close()
        }
    }
}
finally {
    $listener.Stop()
    Remove-Item $marker -ErrorAction SilentlyContinue
}

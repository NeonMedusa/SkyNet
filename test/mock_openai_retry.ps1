# 模拟"首次失败、重试成功"（两种失败模式，按提问里的标记区分）：
#   #<毫秒时间戳>      → 第一次请求返回被截断的 SSE（无 finish_reason / [DONE]）
#   #503<毫秒时间戳>   → 第一次请求返回 HTTP 503（服务端瞬时故障）
# 同一标记的后续请求返回完整回答。每个测试运行在提问里嵌入新标记，因此可重复运行；
# 客户端应丢弃失败尝试的部分产出并自动重发请求，最终得到完整回答且不显示终态错误。
$ErrorActionPreference = "Stop"
$marker_file = Join-Path $PSScriptRoot "mock_18127.running"
"running" | Set-Content $marker_file
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 18127)
$listener.Start()
$log = Join-Path $env:TEMP "skynet_mock_retry.log"
"START $(Get-Date -Format o)" | Set-Content $log
$truncated = @{}   # 已被处理过的标记（同一标记的下一次请求回成功）

function Send-Chunked($stream, [string]$payload) {
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
}

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $stream.ReadTimeout = 400
            $ms = New-Object System.IO.MemoryStream
            $buf = [byte[]]::new(65536)
            while ($true) {
                try {
                    $n = $stream.Read($buf, 0, $buf.Length)
                }
                catch {
                    break   # 读超时 = 请求已发完
                }
                if ($n -le 0) { break }
                $ms.Write($buf, 0, $n)
            }
            $text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())

            # 标记：提问中的 "#<毫秒>"（截断模式）或 "#503<毫秒>"（HTTP 503 模式），每次运行唯一
            $mode = 'ok'
            $mark = [regex]::Match($text, '#([A-Za-z0-9]+)')
            if ($mark.Success) {
                $key = $mark.Groups[1].Value
                if (-not $truncated.ContainsKey($key)) {
                    $truncated[$key] = $true
                    $mode = if ($key.StartsWith('503')) { '503' } else { 'cut' }
                }
            }
            Add-Content $log "REQ marker=$($mark.Value) mode=$mode bytes=$($text.Length)"

            if ($mode -eq '503') {
                # 服务端瞬时故障：503 + JSON 错误体
                $payload = '{"error":{"message":"mock 503 temporary overload"}}'
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
                $head = "HTTP/1.1 503 Service Unavailable`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"
                $headBytes = [System.Text.Encoding]::ASCII.GetBytes($head)
                $stream.Write($headBytes, 0, $headBytes.Length)
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush()
            }
            elseif ($mode -eq 'cut') {
                # 截断：发一段 reasoning 后直接结束（无 [DONE] / finish_reason）
                $payload = 'data: {"choices":[{"delta":{"reasoning_content":"第一段思考（会被丢弃）……"}}]}' + "`n`n"
                Send-Chunked $stream $payload
            }
            else {
                # 完整回答
                $payload = 'data: {"choices":[{"delta":{"reasoning_content":"重试后的思考。"}}]}' + "`n`n" +
                    'data: {"choices":[{"delta":{"content":"重试成功：这是完整回答。"}}]}' + "`n`n" +
                    'data: {"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":80}}}' + "`n`n" +
                    "data: [DONE]`n`n"
                Send-Chunked $stream $payload
            }
        }
        finally {
            $client.Close()
        }
    }
}
finally {
    $listener.Stop()
    Remove-Item $marker_file -ErrorAction SilentlyContinue
}

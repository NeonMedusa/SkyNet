$ErrorActionPreference = "Stop"
$marker = Join-Path $PSScriptRoot "mock_18123.running"
"running" | Set-Content $marker
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:18123/")
$listener.Start()
$log = Join-Path $env:TEMP "skynet_mock.log"
"START $(Get-Date -Format o)" | Set-Content $log

function Send-Sse($ctx, [string]$payload) {
    $res = $ctx.Response
    $res.StatusCode = 200
    $res.ContentType = "text/event-stream"
    $res.SendChunked = $true
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
    $res.OutputStream.Flush()
}

function Tool-CallChunks([string]$id, [string]$name, [string]$argJson) {
    # 分两片发送参数，验证流式拼接
    $half = [Math]::Floor($argJson.Length / 2)
    $a1 = $argJson.Substring(0, $half)
    $a2 = $argJson.Substring($half)
    $esc1 = $a1 -replace '\\', '\\' -replace '"', '\"'
    $esc2 = $a2 -replace '\\', '\\' -replace '"', '\"'
    $s1 = 'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"' + $id + '","function":{"name":"' + $name + '","arguments":"' + $esc1 + '"}}]}}]}' + "`n`n"
    $s2 = 'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"' + $esc2 + '"}}]}}]}' + "`n`n"
    $s3 = 'data: {"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":80}}}' + "`n`n"
    $s4 = "data: [DONE]`n`n"
    return ($s1 + $s2 + $s3 + $s4)
}

try {
    for ($i = 0; $i -lt 3; $i++) {
        $ctx = $listener.GetContext()
        $reader = New-Object System.IO.StreamReader($ctx.Request.InputStream, [System.Text.Encoding]::UTF8)
        $body = $reader.ReadToEnd()
        $reader.Close()
        $hasCacheKey = $body -match 'prompt_cache_key'
        $hasSessionHdr = $null -ne $ctx.Request.Headers["session_id"]
        $hasAffinityHdr = $null -ne $ctx.Request.Headers["x-session-affinity"]
        Add-Content $log "ROUND $($i + 1) len=$($body.Length) has_tools=$($body -match '"tools"') has_tool_role=$($body -match '"role": ?"tool"') cache_key=$hasCacheKey session_hdr=$hasSessionHdr affinity_hdr=$hasAffinityHdr"

        $chunks = @()
        if ($i -eq 0) {
            $chunks += 'data: {"choices":[{"delta":{"reasoning_content":"让我先想想：需要列目录。"}}]}' + "`n`n"
            Start-Sleep -Milliseconds 30
            $chunks += 'data: {"choices":[{"delta":{"content":"我先看一下目录。"}}]}' + "`n`n"
            Start-Sleep -Milliseconds 40
            $chunks += Tool-CallChunks "call_ls" "ls" '{"path":"."}'
        }
        elseif ($i -eq 1) {
            $chunks += 'data: {"choices":[{"delta":{"reasoning_content":"再看命令输出验证一下。"}}]}' + "`n`n"
            Start-Sleep -Milliseconds 30
            $chunks += 'data: {"choices":[{"delta":{"content":"再看下命令输出。"}}]}' + "`n`n"
            Start-Sleep -Milliseconds 40
            $chunks += Tool-CallChunks "call_bash" "bash" '{"command":"Write-Output mock-out"}'
        }
        else {
            $chunks += 'data: {"choices":[{"delta":{"reasoning_content":"信息齐了，可以总结。"}}]}' + "`n`n"
            Start-Sleep -Milliseconds 30
            if (($body -notmatch '"role": ?"tool"') -or ($body -notmatch 'call_bash')) {
                $chunks += 'data: {"choices":[{"delta":{"content":"MOCK_ERROR round3 missing tool context"}}]}' + "`n`n"
            }
            elseif (-not $hasCacheKey) {
                $chunks += 'data: {"choices":[{"delta":{"content":"MOCK_ERROR missing prompt_cache_key"}}]}' + "`n`n"
            }
            elseif ((-not $hasSessionHdr) -or (-not $hasAffinityHdr)) {
                $chunks += 'data: {"choices":[{"delta":{"content":"MOCK_ERROR missing session affinity headers"}}]}' + "`n`n"
            }
            else {
                $chunks += 'data: {"choices":[{"delta":{"content":"目录里有文件，命令输出也拿到了。"}}]}' + "`n`n"
            }
            $chunks += 'data: {"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":80}}}' + "`n`n"
            $chunks += 'data: [DONE]' + "`n`n"
        }
        Send-Sse $ctx ($chunks -join "")
        $ctx.Response.Close()
    }
    $listener.Stop()
    Add-Content $log "DONE"
}
finally {
    Remove-Item $marker -ErrorAction SilentlyContinue
}

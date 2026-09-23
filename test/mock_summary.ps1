$ErrorActionPreference = "Stop"
$marker = Join-Path $PSScriptRoot "mock_18125.running"
"running" | Set-Content $marker
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:18125/")
$listener.Start()

function Send-Sse($ctx, [string]$payload) {
    $res = $ctx.Response
    $res.StatusCode = 200
    $res.ContentType = "text/event-stream"
    $res.SendChunked = $true
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
    $res.OutputStream.Flush()
}

try {
    while ($true) {
        $ctx = $listener.GetContext()
        $reader = New-Object System.IO.StreamReader($ctx.Request.InputStream, [System.Text.Encoding]::UTF8)
        $body = $reader.ReadToEnd()
        $reader.Close()

        # 摘要请求（无 tools）；普通请求也统一返回摘要，便于测试
        # 先发思考增量（reasoning_content），再发正文（覆盖摘要思考块的流式显示与落库）
        $chunks = @()
        $chunks += 'data: {"choices":[{"delta":{"reasoning_content":"MOCK_REASONING 先梳理"}}]}' + "`n`n"
        $chunks += 'data: {"choices":[{"delta":{"reasoning_content":"需要保留哪些要点"}}]}' + "`n`n"
        $chunks += 'data: {"choices":[{"delta":{"content":"## Goal\nMOCK_SUMMARY 完成压缩测试\n\n## Progress\n- 旧对话已摘要\n\n## Next steps\n- 继续"}}]}' + "`n`n"
        $chunks += 'data: {"choices":[],"usage":{"prompt_tokens":50,"completion_tokens":10}}' + "`n`n"
        $chunks += 'data: [DONE]' + "`n`n"
        Send-Sse $ctx ($chunks -join "")
        $ctx.Response.Close()
    }
}
finally {
    Remove-Item $marker -ErrorAction SilentlyContinue
}

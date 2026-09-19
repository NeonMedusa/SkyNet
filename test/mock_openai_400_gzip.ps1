$ErrorActionPreference = "Stop"
$marker = Join-Path $PSScriptRoot "mock_18124.running"
"running" | Set-Content $marker
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:18124/")
$listener.Start()
try {
    while ($true) {
        $ctx = $listener.GetContext()
        $reader = New-Object System.IO.StreamReader($ctx.Request.InputStream, [System.Text.Encoding]::UTF8)
        $null = $reader.ReadToEnd()
        $reader.Close()

        # gzip 压缩的错误响应体（复现"二进制错误体导致渲染崩溃"场景）
        $json = '{"type":"error","error":{"type":"MissingSessionID","message":"mock 400 gzip"}}'
        $ms = New-Object System.IO.MemoryStream
        $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionLevel]::Fastest, $true)
        $raw = [System.Text.Encoding]::UTF8.GetBytes($json)
        $gz.Write($raw, 0, $raw.Length)
        $gz.Close()
        $bytes = $ms.ToArray()

        $res = $ctx.Response
        $res.StatusCode = 400
        $res.ContentType = "application/json"
        $res.Headers.Add("Content-Encoding", "gzip")
        $res.ContentLength64 = $bytes.Length
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
        $res.Close()
    }
    $listener.Stop()
}
finally {
    Remove-Item $marker -ErrorAction SilentlyContinue
}

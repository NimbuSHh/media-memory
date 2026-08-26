# 模型服务接口

Media Memory 按能力调用模型，不识别服务商。配置中的 URL 是完整请求 URL；它可以指向本机回环地址、局域网服务或远程 HTTPS 服务。

若 API key 非空，请求包含：

```http
Authorization: Bearer <key>
```

key 为空时不发送 `Authorization` header。所有时间值均以源视频时间为准。

## 1. 语音识别

使用 OpenAI 兼容的音频转写接口。

```http
POST <configured-url>
Content-Type: multipart/form-data

model=<model-id>
file=<wav-or-m4a>
language=<optional-language>
```

响应：

```json
{
  "text": "识别文字",
  "language": "zh",
  "duration": 12.4
}
```

`language` 和 `duration` 可以省略。

## 2. 句子时间定位

可以使用内置本地 Worker，也可以实现以下 Media Memory alignment HTTP 契约：

```http
POST <configured-url>
Content-Type: multipart/form-data

model=<model-id>
file=<wav-or-m4a>
text=<known-transcription>
language=<language-name>
```

响应：

```json
{
  "items": [
    {"text": "第一句", "start_ms": 120, "end_ms": 1680},
    {"text": "第二句", "start_ms": 1740, "end_ms": 3200}
  ]
}
```

`start_ms` 必须大于或等于 0，`end_ms` 必须大于或等于 `start_ms`。

## 3. 多模态向量

可以使用内置本地 Worker，也可以实现以下 Media Memory multimodal embedding HTTP 契约：

```http
POST <configured-url>
Content-Type: application/json
```

```json
{
  "model": "model-id",
  "input": {
    "text": "ASR 与 OCR 证据",
    "images": [
      "data:image/jpeg;base64,...",
      "data:image/jpeg;base64,..."
    ],
    "instruction": "Represent this ordered video segment for semantic retrieval."
  }
}
```

响应：

```json
{
  "dimension": 2048,
  "vector": [0.012, -0.034, 0.056],
  "norm": 1.0
}
```

`dimension` 和 `norm` 可以省略，应用会验证向量非空、元素有限且范数大于 0。建库和查询必须使用同一模型与向量空间。

## 4. 画面描述

使用 OpenAI 兼容的多模态 `chat/completions` 接口。应用发送文字和按源时间排序的 `image_url` data URL，并请求以下 JSON Schema：

```json
{
  "summary": "片段整体描述",
  "visible_details": ["可直接观察的事实"],
  "uncertainty": ["无法确认的内容"]
}
```

服务应返回标准 Chat Completion 外壳：

```json
{
  "choices": [
    {
      "message": {
        "content": "{\"summary\":\"...\",\"visible_details\":[],\"uncertainty\":[]}"
      }
    }
  ]
}
```

应用同时接受被 Markdown JSON fence 包裹的对象，但不接受缺少字段或无法解析的自由文本。

## 测试行为

设置页的测试按钮会执行对应的完整请求，而不是只读取模型列表：

- ASR：应用生成的短 WAV；
- 对齐：同一 WAV 与固定测试文本；
- 向量：应用生成的图片与固定测试文字；
- 描述：应用生成的图片与固定证据文字。

测试文件位于应用工作目录下的临时 `ModelTests` 子目录，请求结束后删除。测试不访问用户资源库。

非 2xx 响应会显示 HTTP 状态和最多 1000 字节的响应正文；界面在展示前会移除配置中的 API key。生产服务仍不应在错误正文中回显凭据。

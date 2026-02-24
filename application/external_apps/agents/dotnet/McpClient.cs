using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace SimpleChatAgent;

/// <summary>
/// MCP (Model Context Protocol) client using Streamable HTTP transport.
/// Sends JSON-RPC requests to the MCP server with bearer token auth.
/// </summary>
public class McpClient
{
    private readonly HttpClient _httpClient;
    private readonly ILogger<McpClient> _logger;
    private string? _sessionId;

    public McpClient(HttpClient httpClient, ILogger<McpClient> logger)
    {
        _httpClient = httpClient;
        _logger = logger;
    }

    /// <summary>
    /// Lists available tools from the MCP server.
    /// </summary>
    public async Task<JsonElement?> ListToolsAsync(string mcpUrl, string bearerToken, CancellationToken cancellationToken = default)
    {
        var request = new JsonRpcRequest
        {
            Method = "tools/list",
            Params = new { },
            Id = Guid.NewGuid().ToString()
        };

        return await SendJsonRpcAsync(mcpUrl, bearerToken, request, cancellationToken);
    }

    /// <summary>
    /// Calls a specific tool on the MCP server.
    /// </summary>
    public async Task<JsonElement?> CallToolAsync(string mcpUrl, string bearerToken, string toolName, object? arguments = null, CancellationToken cancellationToken = default)
    {
        var request = new JsonRpcRequest
        {
            Method = "tools/call",
            Params = new { name = toolName, arguments = arguments ?? new { } },
            Id = Guid.NewGuid().ToString()
        };

        return await SendJsonRpcAsync(mcpUrl, bearerToken, request, cancellationToken);
    }

    /// <summary>
    /// Initializes the MCP session.
    /// </summary>
    public async Task<JsonElement?> InitializeAsync(string mcpUrl, string bearerToken, CancellationToken cancellationToken = default)
    {
        var request = new JsonRpcRequest
        {
            Method = "initialize",
            Params = new
            {
                protocolVersion = "2025-03-26",
                capabilities = new { },
                clientInfo = new { name = "simplechat-agent-dotnet", version = "1.0.0" }
            },
            Id = Guid.NewGuid().ToString()
        };

        return await SendJsonRpcAsync(mcpUrl, bearerToken, request, cancellationToken);
    }

    /// <summary>
    /// Routes a user message to the appropriate MCP tool.
    /// For simplicity, calls the 'chat' tool if available, otherwise lists tools.
    /// </summary>
    public async Task<string> HandleUserMessageAsync(string mcpUrl, string bearerToken, string userMessage, CancellationToken cancellationToken = default)
    {
        try
        {
            // Reset session for new conversation
            _sessionId = null;

            // Initialize session
            var initResult = await InitializeAsync(mcpUrl, bearerToken, cancellationToken);
            _logger.LogDebug("MCP Initialize result: {Result}", initResult);

            // Send initialized notification (per MCP spec)
            await SendInitializedNotificationAsync(mcpUrl, bearerToken, cancellationToken);

            // List available tools
            var toolsResult = await ListToolsAsync(mcpUrl, bearerToken, cancellationToken);
            _logger.LogDebug("MCP tools/list result: {Result}", toolsResult);

            if (toolsResult == null)
            {
                return "Failed to get tools from MCP server.";
            }

            // Build set of available tool names
            var availableTools = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var tools = toolsResult.Value;
            if (tools.TryGetProperty("result", out var result) && result.TryGetProperty("tools", out var toolsArray))
            {
                foreach (var tool in toolsArray.EnumerateArray())
                {
                    var name = tool.GetProperty("name").GetString();
                    if (name != null) availableTools.Add(name);
                }
            }

            _logger.LogInformation("Available MCP tools: {Tools}", string.Join(", ", availableTools));

            if (availableTools.Count == 0)
            {
                return "No tools available on the MCP server.";
            }

            // Determine which tool to call and what arguments to pass
            var (targetTool, toolArgs) = ResolveToolAndArgs(userMessage, availableTools);

            _logger.LogInformation("Routing message to MCP tool: {Tool} with args: {Args}",
                targetTool, JsonSerializer.Serialize(toolArgs));

            var callResult = await CallToolAsync(mcpUrl, bearerToken, targetTool, toolArgs, cancellationToken);

            if (callResult == null)
            {
                return "MCP tool call returned no result.";
            }

            // Extract text content from the result
            return ExtractTextFromResult(callResult.Value);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            _logger.LogWarning("MCP tool call timed out (45s limit)");
            return "The request timed out. The tool may have returned too much data. Try a more specific query.";
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error communicating with MCP server");
            return $"Error communicating with MCP server: {ex.Message}";
        }
    }

    private async Task<JsonElement?> SendJsonRpcAsync(string mcpUrl, string bearerToken, JsonRpcRequest request, CancellationToken cancellationToken)
    {
        var jsonOptions = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
        };

        var json = JsonSerializer.Serialize(request, jsonOptions);
        _logger.LogDebug("MCP Request [{Method}]: {Json}", request.Method, json);

        using var httpRequest = new HttpRequestMessage(HttpMethod.Post, mcpUrl);
        httpRequest.Content = new StringContent(json, Encoding.UTF8, "application/json");
        httpRequest.Headers.Authorization = new AuthenticationHeaderValue("Bearer", bearerToken);
        httpRequest.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        httpRequest.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("text/event-stream"));

        // Include session ID if we have one from a prior response
        if (!string.IsNullOrEmpty(_sessionId))
        {
            httpRequest.Headers.Add("Mcp-Session-Id", _sessionId);
            _logger.LogDebug("Sending Mcp-Session-Id: {SessionId}", _sessionId);
        }

        // Use a 45-second timeout to avoid indefinite hangs on large responses
        using var timeoutCts = new CancellationTokenSource(TimeSpan.FromSeconds(45));
        using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutCts.Token);

        var response = await _httpClient.SendAsync(httpRequest, linkedCts.Token);
        var responseBody = await response.Content.ReadAsStringAsync(linkedCts.Token);

        // Capture session ID from response
        if (response.Headers.TryGetValues("Mcp-Session-Id", out var sessionValues))
        {
            _sessionId = sessionValues.FirstOrDefault();
            _logger.LogInformation("Captured Mcp-Session-Id: {SessionId}", _sessionId);
        }

        _logger.LogDebug("MCP Response [{Method}] {Status} Content-Type={ContentType}: {Body}",
            request.Method, response.StatusCode,
            response.Content.Headers.ContentType?.MediaType ?? "unknown",
            responseBody);

        if (!response.IsSuccessStatusCode)
        {
            _logger.LogError("MCP server returned {StatusCode}: {Body}", response.StatusCode, responseBody);
            return null;
        }

        if (string.IsNullOrWhiteSpace(responseBody))
        {
            return null;
        }

        var contentType = response.Content.Headers.ContentType?.MediaType ?? "";

        // Handle SSE (text/event-stream) responses
        if (contentType.Contains("text/event-stream", StringComparison.OrdinalIgnoreCase)
            || responseBody.TrimStart().StartsWith("event:", StringComparison.OrdinalIgnoreCase)
            || responseBody.TrimStart().StartsWith("data:", StringComparison.OrdinalIgnoreCase))
        {
            return ParseSseResponse(responseBody);
        }

        return JsonSerializer.Deserialize<JsonElement>(responseBody);
    }

    /// <summary>
    /// Parses an SSE response body, extracting the last JSON-RPC message from data: lines.
    /// </summary>
    private JsonElement? ParseSseResponse(string sseBody)
    {
        JsonElement? lastMessage = null;

        foreach (var line in sseBody.Split('\n'))
        {
            var trimmed = line.Trim();
            if (trimmed.StartsWith("data:", StringComparison.OrdinalIgnoreCase))
            {
                var data = trimmed["data:".Length..].Trim();
                if (string.IsNullOrEmpty(data)) continue;

                try
                {
                    var parsed = JsonSerializer.Deserialize<JsonElement>(data);
                    lastMessage = parsed;
                    _logger.LogDebug("SSE data parsed: {Data}", data);
                }
                catch (JsonException ex)
                {
                    _logger.LogWarning("Failed to parse SSE data line as JSON: {Data} - {Error}", data, ex.Message);
                }
            }
        }

        if (lastMessage == null)
        {
            _logger.LogWarning("No JSON data found in SSE response");
        }

        return lastMessage;
    }

    /// <summary>
    /// Resolves which MCP tool to call based on the user message.
    /// If the message matches a tool name exactly (with optional "/" prefix),
    /// that tool is called directly. Otherwise defaults to send_chat_message.
    /// </summary>
    private static (string toolName, object args) ResolveToolAndArgs(string userMessage, HashSet<string> availableTools)
    {
        var trimmed = userMessage.Trim();

        // Strip optional "/" prefix (e.g. "/show_user_profile")
        var candidate = trimmed.StartsWith("/") ? trimmed[1..] : trimmed;

        // Check for exact tool name match (possibly followed by arguments after whitespace)
        var parts = candidate.Split(' ', 2, StringSplitOptions.TrimEntries);
        var possibleTool = parts[0];
        var remainder = parts.Length > 1 ? parts[1] : "";

        if (availableTools.Contains(possibleTool))
        {
            // Build tool-specific arguments
            var args = BuildToolArgs(possibleTool, remainder);
            return (possibleTool, args);
        }

        // Default: route to send_chat_message
        var defaultTool = availableTools.Contains("send_chat_message") ? "send_chat_message" : availableTools.First();
        return (defaultTool, new { message = userMessage, query = userMessage });
    }

    /// <summary>
    /// Builds the arguments object for a specific tool based on the tool name
    /// and any extra text the user provided after the tool name.
    /// </summary>
    private static object BuildToolArgs(string toolName, string extraText)
    {
        return toolName switch
        {
            "send_chat_message" => new { message = extraText, query = extraText },
            "list_personal_documents" => string.IsNullOrEmpty(extraText)
                ? new { page = 1, page_size = 10 } as object
                : new { page = 1, page_size = 10, search = extraText },
            "list_conversations" => new { page = 1, page_size = 10 },
            "get_conversation_messages" => new { conversation_id = extraText },
            _ => string.IsNullOrEmpty(extraText) ? new { } as object : new { query = extraText }
        };
    }

    private static string ExtractTextFromResult(JsonElement result)
    {
        // Try JSON-RPC result.result.content[].text
        if (result.TryGetProperty("result", out var rpcResult))
        {
            if (rpcResult.TryGetProperty("content", out var content) && content.ValueKind == JsonValueKind.Array)
            {
                var texts = new List<string>();
                foreach (var item in content.EnumerateArray())
                {
                    if (item.TryGetProperty("text", out var text))
                    {
                        var rawText = text.GetString() ?? "";
                        // If the text is a JSON string, try to extract the "reply" field
                        // (send_chat_message returns full SimpleChat JSON with reply, citations, etc.)
                        texts.Add(TryExtractReplyFromJson(rawText));
                    }
                }
                if (texts.Count > 0) return string.Join("\n", texts);
            }

            // Fallback: result as string
            if (rpcResult.ValueKind == JsonValueKind.String)
            {
                return TryExtractReplyFromJson(rpcResult.GetString() ?? "");
            }

            return rpcResult.ToString();
        }

        // Try direct content array
        if (result.TryGetProperty("content", out var directContent) && directContent.ValueKind == JsonValueKind.Array)
        {
            var texts = new List<string>();
            foreach (var item in directContent.EnumerateArray())
            {
                if (item.TryGetProperty("text", out var text))
                {
                    texts.Add(TryExtractReplyFromJson(text.GetString() ?? ""));
                }
            }
            if (texts.Count > 0) return string.Join("\n", texts);
        }

        return result.ToString();
    }

    /// <summary>
    /// If the text is JSON containing a "reply" field (SimpleChat response),
    /// extract just the reply. Otherwise return the original text.
    /// </summary>
    private static string TryExtractReplyFromJson(string text)
    {
        if (string.IsNullOrWhiteSpace(text) || text[0] != '{') return text;

        try
        {
            using var doc = JsonDocument.Parse(text);
            var root = doc.RootElement;

            // send_chat_message: extract "reply"
            if (root.TryGetProperty("reply", out var reply) && reply.ValueKind == JsonValueKind.String)
            {
                return reply.GetString() ?? text;
            }

            // If it has an "error" field, return the error message
            if (root.TryGetProperty("error", out var error) && error.ValueKind == JsonValueKind.String)
            {
                var msg = root.TryGetProperty("message", out var errMsg) ? errMsg.GetString() : error.GetString();
                return $"Error: {msg}";
            }
        }
        catch (JsonException)
        {
            // Not valid JSON, return as-is
        }

        return text;
    }

    /// <summary>
    /// Sends the 'notifications/initialized' notification after initialize (per MCP spec).
    /// This is a notification (no Id), so the server won't send a response.
    /// </summary>
    private async Task SendInitializedNotificationAsync(string mcpUrl, string bearerToken, CancellationToken cancellationToken)
    {
        var notification = new JsonRpcRequest
        {
            Method = "notifications/initialized",
            Id = null // notifications have no id
        };

        var jsonOptions = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
        };

        var json = JsonSerializer.Serialize(notification, jsonOptions);
        _logger.LogDebug("MCP Notification [notifications/initialized]: {Json}", json);

        using var httpRequest = new HttpRequestMessage(HttpMethod.Post, mcpUrl);
        httpRequest.Content = new StringContent(json, Encoding.UTF8, "application/json");
        httpRequest.Headers.Authorization = new AuthenticationHeaderValue("Bearer", bearerToken);
        httpRequest.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        httpRequest.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("text/event-stream"));

        if (!string.IsNullOrEmpty(_sessionId))
        {
            httpRequest.Headers.Add("Mcp-Session-Id", _sessionId);
        }

        var response = await _httpClient.SendAsync(httpRequest, cancellationToken);
        _logger.LogDebug("MCP notifications/initialized response: {Status}", response.StatusCode);

        // Capture session ID if returned
        if (response.Headers.TryGetValues("Mcp-Session-Id", out var sessionValues))
        {
            _sessionId = sessionValues.FirstOrDefault();
        }
    }

    private class JsonRpcRequest
    {
        public string Jsonrpc { get; set; } = "2.0";
        public string Method { get; set; } = "";
        public object? Params { get; set; }
        public string? Id { get; set; }
    }
}

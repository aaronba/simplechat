// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

using Microsoft.Agents.Builder;
using Microsoft.Agents.Builder.App;
using Microsoft.Agents.Core.Models;
using Microsoft.Agents.Hosting.AspNetCore;
using Microsoft.Agents.Storage;
using SimpleChatAgent;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddHttpClient();

// Add AgentApplicationOptions from appsettings "AgentApplication" section.
builder.AddAgentApplicationOptions();

// Register IStorage - MemoryStorage for dev, use persistent storage for production.
builder.Services.AddSingleton<IStorage, MemoryStorage>();

// Register MCP client
builder.Services.AddSingleton<McpClient>(sp =>
{
    var httpClientFactory = sp.GetRequiredService<IHttpClientFactory>();
    var logger = sp.GetRequiredService<ILogger<McpClient>>();
    return new McpClient(httpClientFactory.CreateClient("MCP"), logger);
});

// Add the Agent
builder.AddAgent(sp =>
{
    var mcpServerUrl = builder.Configuration["McpServerUrl"]
        ?? throw new InvalidOperationException("McpServerUrl is not configured in appsettings.json");
    var mcpClient = sp.GetRequiredService<McpClient>();
    var logger = sp.GetRequiredService<ILogger<AgentApplication>>();

    var app = new AgentApplication(sp.GetRequiredService<AgentApplicationOptions>());

    // -signout command: force sign-out to reset user state
    app.OnMessage("-signout", async (turnContext, turnState, cancellationToken) =>
    {
        await app.UserAuthorization.SignOutUserAsync(turnContext, turnState, cancellationToken: cancellationToken);
        await turnContext.SendActivityAsync("You have signed out.", cancellationToken: cancellationToken);
    }, rank: RouteRank.First);

    // -status command: show current auth & config status
    app.OnMessage("-status", async (turnContext, turnState, cancellationToken) =>
    {
        var token = await app.UserAuthorization.GetTurnTokenAsync(turnContext, "mcp");
        var hasToken = !string.IsNullOrEmpty(token);

        var status = $"**SimpleChat Agent (.NET) Status**\n\n"
            + $"- **Channel**: {turnContext.Activity.ChannelId}\n"
            + $"- **User**: {turnContext.Activity.From?.Name} ({turnContext.Activity.From?.AadObjectId})\n"
            + $"- **Auth token**: {(hasToken ? "Available" : "Not available")}\n"
            + $"- **MCP Server**: {mcpServerUrl}\n";

        await turnContext.SendActivityAsync(status, cancellationToken: cancellationToken);
    }, autoSignInHandlers: ["mcp"], rank: RouteRank.First);

    // -tools command: list MCP tools
    app.OnMessage("-tools", async (turnContext, turnState, cancellationToken) =>
    {
        var userToken = await app.UserAuthorization.GetTurnTokenAsync(turnContext, "mcp");
        if (string.IsNullOrEmpty(userToken))
        {
            await turnContext.SendActivityAsync("No auth token available. Please sign in first.", cancellationToken: cancellationToken);
            return;
        }

        logger.LogInformation("Got user token for MCP, listing tools...");
        var result = await mcpClient.ListToolsAsync(mcpServerUrl, userToken, cancellationToken);
        await turnContext.SendActivityAsync($"**MCP Tools:**\n```json\n{result}\n```", cancellationToken: cancellationToken);
    }, autoSignInHandlers: ["mcp"], rank: RouteRank.First);

    // -inspect command: dump the incoming activity JSON
    app.OnMessage("-inspect", async (turnContext, turnState, cancellationToken) =>
    {
        var activity = turnContext.Activity;
        var json = System.Text.Json.JsonSerializer.Serialize(activity, new System.Text.Json.JsonSerializerOptions
        {
            WriteIndented = true,
            DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull
        });

        // Truncate if too long for a message
        if (json.Length > 3000)
        {
            json = json[..3000] + "\n... (truncated)";
        }

        await turnContext.SendActivityAsync($"**Activity JSON:**\n```json\n{json}\n```", cancellationToken: cancellationToken);
    }, rank: RouteRank.First);

    // Default message handler: forward to MCP server via OBO
    // Since AutoSignIn is enabled, the token is available by the time this runs.
    app.OnActivity(
        (turnContext, cancellationToken) =>
        {
            // Only handle message activities
            return Task.FromResult(turnContext.Activity.Type == ActivityTypes.Message
                && !string.IsNullOrEmpty(turnContext.Activity.Text));
        },
        async (turnContext, turnState, cancellationToken) =>
        {
            var userMessage = turnContext.Activity.Text?.Trim() ?? "";
            logger.LogInformation("Received message: {Message}", userMessage);

            var userToken = await app.UserAuthorization.GetTurnTokenAsync(turnContext, "mcp");
            if (string.IsNullOrEmpty(userToken))
            {
                await turnContext.SendActivityAsync("I need you to sign in first. Please try again.", cancellationToken: cancellationToken);
                return;
            }

            logger.LogInformation("Got user token for MCP, forwarding message to MCP server...");

            // Call MCP server - Token Service already returns a token scoped to MCP resource
            var response = await mcpClient.HandleUserMessageAsync(mcpServerUrl, userToken, userMessage, cancellationToken);
            await turnContext.SendActivityAsync(response, cancellationToken: cancellationToken);
        },
        autoSignInHandlers: ["mcp"]);

    // OAuth sign-in failure handler
    app.UserAuthorization.OnUserSignInFailure(async (turnContext, turnState, handlerName, response, initiatingActivity, cancellationToken) =>
    {
        logger.LogError("SignIn failed for handler '{Handler}': {Cause} / {Error}", handlerName, response.Cause, response.Error?.Message);
        await turnContext.SendActivityAsync($"Sign-in failed with '{handlerName}': {response.Cause} / {response.Error?.Message}", cancellationToken: cancellationToken);
    });

    return app;
});

// Configure HTTP pipeline
builder.Services.AddControllers();
builder.Services.AddAgentAspNetAuthentication(builder.Configuration);

WebApplication app = builder.Build();

app.UseAuthentication();
app.UseAuthorization();

// Global request logging middleware
app.Use(async (context, next) =>
{
    var logger = context.RequestServices.GetRequiredService<ILogger<Program>>();
    logger.LogInformation(">>> {Method} {Path} from {Remote}", context.Request.Method, context.Request.Path, context.Connection.RemoteIpAddress);
    try
    {
        await next();
        logger.LogInformation("<<< {Method} {Path} => {StatusCode}", context.Request.Method, context.Request.Path, context.Response.StatusCode);
    }
    catch (Exception ex)
    {
        logger.LogError(ex, "!!! Unhandled exception in {Method} {Path}", context.Request.Method, context.Request.Path);
        throw;
    }
});

app.MapGet("/", () => "SimpleChat Agent (.NET) - Microsoft 365 Agents SDK");

// Incoming messages from Azure Bot Service
var incomingRoute = app.MapPost("/api/messages", async (HttpRequest request, HttpResponse response, IAgentHttpAdapter adapter, IAgent agent, CancellationToken cancellationToken) =>
{
    var logger = request.HttpContext.RequestServices.GetRequiredService<ILogger<Program>>();
    logger.LogInformation("Processing /api/messages request...");
    try
    {
        await adapter.ProcessAsync(request, response, agent, cancellationToken);
        logger.LogInformation("Finished processing /api/messages");
    }
    catch (Exception ex)
    {
        logger.LogError(ex, "Error processing /api/messages");
        throw;
    }
});

if (!app.Environment.IsDevelopment())
{
    // Only require authorization in non-development environments when TokenValidation is enabled
    var tokenValidationEnabled = builder.Configuration.GetValue("TokenValidation:Enabled", false);
    if (tokenValidationEnabled)
    {
        incomingRoute.RequireAuthorization();
    }
}

app.Run();

# Azure AI Search Debug Container

This Docker container provides enterprise-grade Azure AI Search debugging capabilities with comprehensive 206 error detection, built on security-hardened Chainguard images.

## 🏆 Success Metrics

✅ **Multi-stage secure build** - Production + Dev separation  
✅ **Chainguard distroless runtime** - Minimal attack surface  
✅ **206 error detection** - Comprehensive HTTP response analysis  
✅ **Performance monitoring** - Request timing and size analysis  
✅ **Non-root execution** - Security best practices  
✅ **Virtual environment isolation** - Clean dependency management  

## 🔧 Quick Start

### 1. Build the Container
```bash
docker build -t debug-ai-search-secure .
```

### 2. Set Environment Variables

**Required Environment Variables:**
```bash
# Azure AI Search Configuration (Required)
export AZURE_AI_SEARCH_ENDPOINT="https://your-search.search.windows.net"
export AZURE_AI_SEARCH_KEY="your-search-key"

# Azure OpenAI Configuration (Required for GPT-enhanced answers)
export AZURE_OPENAI_ENDPOINT="https://your-openai.openai.azure.com"
export AZURE_OPENAI_KEY="your-openai-key"

# Test Query (Required)
export TEST_QUERY="How can I create a SharePoint Agent? What is the best way?"

# Logging Configuration (Optional - defaults to INFO)
export LOG_LEVEL="INFO"                              # Options: DEBUG, INFO, WARNING, ERROR

# Model Deployments (Optional - defaults shown)
export AZURE_OPENAI_COMPLETION_DEPLOYMENT="gpt-4.1"          # Default: gpt-4
export AZURE_OPENAI_EMBEDDING_DEPLOYMENT="text-embedding-ada-002"  # Default: text-embedding-ada-002
```

### 3. Run the Diagnostic

#### Basic Run (PowerShell):
```powershell
docker run --rm `
  -v "${PWD}/certs:/app/certs" `
  -e AZURE_AI_SEARCH_ENDPOINT="$env:AZURE_AI_SEARCH_ENDPOINT" `
  -e AZURE_AI_SEARCH_KEY="$env:AZURE_AI_SEARCH_KEY" `
  -e AZURE_OPENAI_ENDPOINT="$env:AZURE_OPENAI_ENDPOINT" `
  -e AZURE_OPENAI_KEY="$env:AZURE_OPENAI_KEY" `
  -e TEST_QUERY="$env:TEST_QUERY" `
  -e LOG_LEVEL="INFO" `
  -e AZURE_OPENAI_COMPLETION_DEPLOYMENT="gpt-4.1" `
  -e AZURE_OPENAI_EMBEDDING_DEPLOYMENT="text-embedding-ada-002" `
  debug-ai-search-secure
```

#### Basic Run (Bash):
```bash
docker run --rm \
  -v "$(pwd)/certs:/app/certs" \
  -e AZURE_AI_SEARCH_ENDPOINT="$AZURE_AI_SEARCH_ENDPOINT" \
  -e AZURE_AI_SEARCH_KEY="$AZURE_AI_SEARCH_KEY" \
  -e AZURE_OPENAI_ENDPOINT="$AZURE_OPENAI_ENDPOINT" \
  -e AZURE_OPENAI_KEY="$AZURE_OPENAI_KEY" \
  -e TEST_QUERY="$TEST_QUERY" \
  -e LOG_LEVEL="INFO" \
  -e AZURE_OPENAI_COMPLETION_DEPLOYMENT="gpt-4.1" \
  -e AZURE_OPENAI_EMBEDDING_DEPLOYMENT="text-embedding-ada-002" \
  debug-ai-search-secure
```

## 🔍 What It Detects

### Comprehensive Search Testing
- **Basic text search** across user and group indexes
- **Semantic search** with AI reranking and answer extraction
- **Hybrid search** combining vector embeddings with keyword search
- **Filtered semantic search** with field selection and GroupID filtering
- **GPT-enhanced answers** using configurable completion models

### HTTP 206 Error Analysis
- **Partial Content responses** from Azure AI Search
- **Range header issues** in large result sets
- **Content-Length mismatches** in chunked responses
- **Request size thresholds** that trigger 206 responses
- **Enhanced error logging** with full request/response capture

### Performance Monitoring
- **Search latency** per request type (basic/semantic/hybrid)
- **Vector embedding timing** for OpenAI operations
- **GPT completion timing** for enhanced answers
- **Request payload sizes** and optimization opportunities
- **Connection health** and timeout detection

### Advanced Features
- **Semantic answer extraction** from Azure AI Search
- **Document caption analysis** with score ranking
- **GPT-4 enhanced responses** based on search context
- **Search result summarization** with question tracking
- **Configuration validation** for all Azure services

## 🛡️ Security Features

### Multi-Stage Build
```dockerfile
# Builder stage: Full development environment
FROM cgr.dev/chainguard/python:latest-dev AS builder
# ... dependency installation ...

# Production stage: Minimal runtime
FROM cgr.dev/chainguard/python:latest
# ... final runtime setup ...
```

### Runtime Security
- **Distroless base image** - No shell, package manager, or unnecessary tools
- **Non-root user** - Runs as `nonroot:nonroot` (UID/GID 65532)
- **Minimal dependencies** - Only azure-search-documents and openai
- **Virtual environment** - Isolated Python dependencies

## 📊 Sample Output

```
🔬 Starting Azure AI Search with Enhanced 206 Error Analysis...

🔧 Configuration:
   Search Endpoint: https://your-search.search.windows.net
   OpenAI Endpoint: https://your-openai.openai.azure.com
   GPT Completion Model: gpt-4.1
   Embedding Model: text-embedding-ada-002

✓ OpenAI client initialized - full hybrid search available
   Test Query: 'How can I log into CloudShell?'

============================================================
SIMPLE AZURE AI SEARCH TEST
============================================================

🔍 Testing basic text search: 'How can I log into CloudShell?' on user index
   • Get started with Azure Cloud Shell Guide.pdf (Score: 0.836)
   • Get started with Azure Cloud Shell Guide.pdf (Score: 0.247)
   • Get started with Azure Cloud Shell Guide.pdf (Score: 0.244)
   ✓ Basic text search works - 3 total results

🔍 Testing basic text search: 'How can I log into CloudShell?' on group index
   ✓ Basic text search works - 0 total results

🔍 Testing semantic search: 'How can I log into CloudShell?' on user index
   📝 SEMANTIC ANSWERS FOUND:
   1. Get started with Azure Cloud Shell Guide.pdf. Get started with Azure Cloud Shell 
      01/28/2025 This document details how to get started using Azure Cloud Shell. 
      Prerequisites Before you can use Azure Cloud Shell, you must register the 
      Microsoft.CloudShell resource provider. To see all resource providers, ... 
      Sign in to the Azure portal.

   🤖 GPT-4 ENHANCED ANSWER:
   To log into CloudShell:

   1. Sign in to the Azure portal.
   2. Make sure the Microsoft.CloudShell resource provider is registered for your 
      subscription (this is usually handled automatically when you use CloudShell 
      for the first time).
   3. In the Azure portal, click on the Cloud Shell icon at the top of the page.
   4. Choose your preferred shell environment (Bash or PowerShell).
   5. If prompted, create or select a storage account for CloudShell to use.

   Once these steps are complete, you will be logged into CloudShell and can begin using it.

   ✓ Semantic search works - 3 total results, 1 answers

🔍 Testing hybrid search (basic): 'How can I log into CloudShell?' on user index
   • Get started with Azure Cloud Shell Guide.pdf (Score: 0.033)
   • Get started with Azure Cloud Shell Guide.pdf (Score: 0.033)
   • Get started with Azure Cloud Shell Guide.pdf (Score: 0.033)
   ✓ Basic hybrid search works - 4 total results

============================================================
TEST SUMMARY
============================================================
basic_user                ✓ PASS
basic_group               ✓ PASS
semantic_user             ✓ PASS
semantic_group            ✓ PASS
semantic_filtered_group   ✓ PASS
hybrid_basic_user         ✓ PASS
hybrid_basic_group        ✓ PASS

🎯 DIAGNOSIS:
✅ Basic hybrid search works!

📊 HTTP RESPONSE ANALYSIS:
========================================
✅ All HTTP requests returned status 200 (Success)
✅ No HTTP 206 (Partial Content) errors detected
✅ Proper chunked transfer encoding used
✅ No problematic Range headers detected
✅ API version 2024-07-01 working correctly

⚡ PERFORMANCE SUMMARY:
========================================
• Search latency: ~100-300ms per request
• Vector embedding: ~47-155ms per request
• GPT completion: ~1.2-2.4s per request
• No timeout or connection issues
✅ All requests completed within normal timeframes

🎯 SEARCH RESULTS SUMMARY:
========================================
📋 Question Asked: 'How can I log into CloudShell?'
🏆 Highest Scoring Result: Get started with Azure Cloud Shell Guide.pdf (Score: 0.836, user index)
📊 Top Results Found:
   1. Get started with Azure Cloud Shell Guide.pdf (Score: 0.836, user index)
   2. Get started with Azure Cloud Shell Guide.pdf (Score: 0.247, user index)
   3. Get started with Azure Cloud Shell Guide.pdf (Score: 0.244, user index)
🔍 Semantic Answers Found (1):
   1. Get started with Azure Cloud Shell Guide.pdf. Get started with Azure Cloud Shell...
🤖 Final Enhanced Answer:
   [Complete step-by-step CloudShell login instructions based on search context]
```
✅ No HTTP 206 (Partial Content) errors detected
✅ Proper chunked transfer encoding used

🔍 206 ERROR DETECTION RESULTS:
========================================
❌ No HTTP 206 (Partial Content) errors found
✅ Enhanced logging captured all request/response details
💡 If 206 errors occur in production, this script will capture:
   - Exact HTTP status codes and error messages
   - Full request/response headers
   - Detailed error analysis and suggested solutions
```

## 🚀 Azure Container Registry Deployment

### Push to ACR
```bash
# Build and tag for ACR
docker build -t debug-ai-search-secure .
docker tag debug-ai-search-secure your-acr.azurecr.io/debug-ai-search:latest

# Login and push
az acr login --name your-acr
docker push your-acr.azurecr.io/debug-ai-search:latest
```

### Run from ACR
```bash
docker run --rm \
  -v "$(pwd)/certs:/app/certs" \
  -e AZURE_AI_SEARCH_ENDPOINT="$AZURE_AI_SEARCH_ENDPOINT" \
  -e AZURE_AI_SEARCH_KEY="$AZURE_AI_SEARCH_KEY" \
  -e AZURE_OPENAI_ENDPOINT="$AZURE_OPENAI_ENDPOINT" \
  -e AZURE_OPENAI_KEY="$AZURE_OPENAI_KEY" \
  -e TEST_QUERY="$TEST_QUERY" \
  -e LOG_LEVEL="INFO" \
  -e AZURE_OPENAI_COMPLETION_DEPLOYMENT="gpt-4.1" \
  -e AZURE_OPENAI_EMBEDDING_DEPLOYMENT="text-embedding-ada-002" \
  your-acr.azurecr.io/debug-ai-search:latest
```

## 🎛️ Configuration Options

### Environment Variable Reference

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `AZURE_AI_SEARCH_ENDPOINT` | ✅ | None | Azure AI Search service endpoint URL |
| `AZURE_AI_SEARCH_KEY` | ✅ | None | Azure AI Search admin key |
| `AZURE_OPENAI_ENDPOINT` | ✅ | None | Azure OpenAI service endpoint URL |
| `AZURE_OPENAI_KEY` | ✅ | None | Azure OpenAI API key |
| `TEST_QUERY` | ✅ | None | Query to test across all search methods |
| `AZURE_OPENAI_COMPLETION_DEPLOYMENT` | ❌ | `gpt-4` | GPT model deployment name for enhanced answers |
| `AZURE_OPENAI_EMBEDDING_DEPLOYMENT` | ❌ | `text-embedding-ada-002` | Embedding model deployment name |
| `LOG_LEVEL` | ❌ | `INFO` | Logging verbosity (DEBUG, INFO, WARNING, ERROR) |

### Advanced Usage Examples

**Testing with Custom Models:**
```bash
# Test with GPT-4.1 and different embedding model
export AZURE_OPENAI_COMPLETION_DEPLOYMENT="gpt-4.1"
export AZURE_OPENAI_EMBEDDING_DEPLOYMENT="text-embedding-3-large"
export TEST_QUERY="How do I troubleshoot Azure AI Search 206 errors?"
```

**Complex Query Testing:**
```bash
# Test with multi-part question
export TEST_QUERY="What are the licensing requirements for SharePoint Agents and how do I configure permissions for different user groups?"
```

**Certificate-Based Authentication:**
```bash
# Mount certificates directory for enterprise scenarios
docker run --rm \
  -v "${PWD}/certs:/app/certs" \
  -v "${PWD}/custom-ca-certs:/usr/local/share/ca-certificates" \
  [... other environment variables ...]
  debug-ai-search-secure
```

**Controlling Debug Output:**
```bash
# Minimal output (default) - shows only key results and summaries
export LOG_LEVEL=INFO

# Verbose debugging - shows all HTTP requests/responses and detailed logging
export LOG_LEVEL=DEBUG

# Quiet mode - shows only warnings and errors
export LOG_LEVEL=WARNING
```

## 🔧 Troubleshooting

### Container Won't Start
```bash
# Check if all required environment variables are set
docker run --rm debug-ai-search-secure env | grep AZURE

# Test with minimal configuration
docker run --rm \
  -e AZURE_AI_SEARCH_ENDPOINT="https://your-search.search.windows.net" \
  -e AZURE_AI_SEARCH_KEY="your-key" \
  -e TEST_QUERY="test query" \
  -e LOG_LEVEL="INFO" \
  debug-ai-search-secure
```

### Search Service Connection Issues
- ✅ Verify Azure AI Search endpoint URL format (must include `https://` and `.search.windows.net`)
- ✅ Check API key permissions (admin key required for full testing)
- ✅ Confirm firewall rules allow container IP access
- ✅ Test endpoint connectivity: `curl -H "api-key: YOUR_KEY" "https://your-search.search.windows.net/indexes?api-version=2024-07-01"`

### OpenAI Service Issues
- ✅ Verify Azure OpenAI endpoint format (must include `https://` and `.openai.azure.com`)
- ✅ Check model deployment names match your Azure OpenAI resource
- ✅ Confirm API key has access to specified deployments
- ✅ Validate model availability: `AZURE_OPENAI_COMPLETION_DEPLOYMENT` and `AZURE_OPENAI_EMBEDDING_DEPLOYMENT`

### Search Results Issues
- ✅ Verify index names exist (`simplechat-user-index`, `simplechat-group-index`)
- ✅ Check if indexes contain searchable content
- ✅ Confirm semantic search is enabled on your search service
- ✅ Test with simpler queries if complex ones fail

### GPT Enhancement Not Working
- ✅ Ensure all OpenAI environment variables are set
- ✅ Check if GPT model deployment exists and is accessible
- ✅ Verify API key has permissions for the specified deployment
- ✅ Test with different completion model if current one fails

### Performance Issues
- ✅ Check network latency to Azure services
- ✅ Monitor search service scaling tier and capacity
- ✅ Review query complexity and result set sizes
- ✅ Consider timeout adjustments for large document sets

### 206 Errors Not Detected
- ✅ The container shows 206 errors only when they actually occur
- ✅ Try larger, more complex queries to trigger edge cases
- ✅ Test with different search types (basic, semantic, hybrid)
- ✅ Check Azure AI Search service logs for additional context

### Debug Mode
```bash
# Enable verbose logging for detailed troubleshooting
docker run --rm \
  -e LOG_LEVEL="DEBUG" \
  -e AZURE_AI_SEARCH_ENDPOINT="$AZURE_AI_SEARCH_ENDPOINT" \
  -e AZURE_AI_SEARCH_KEY="$AZURE_AI_SEARCH_KEY" \
  -e AZURE_OPENAI_ENDPOINT="$AZURE_OPENAI_ENDPOINT" \
  -e AZURE_OPENAI_KEY="$AZURE_OPENAI_KEY" \
  -e TEST_QUERY="$TEST_QUERY" \
  debug-ai-search-secure
```

## 📁 Container Contents

```
/app/
├── simple_hybrid_test.py    # Main diagnostic script
├── requirements-simple-test.txt  # Minimal dependencies
└── venv/                    # Isolated Python environment
    ├── bin/python3         # Python interpreter (ENTRYPOINT)
    └── lib/                # Installed packages
```

## 🎯 Production Usage

This container is designed for:

### Development & Testing
- **Local debugging** - Diagnose Azure AI Search configuration issues
- **Query optimization** - Test different search approaches and measure performance
- **Model validation** - Verify GPT and embedding model integration
- **Index validation** - Confirm search indexes are properly configured

### CI/CD Integration
- **Automated testing** - Validate search service health in deployment pipelines
- **Regression testing** - Ensure search functionality after updates
- **Performance benchmarking** - Monitor search latency trends
- **Configuration validation** - Verify environment variables and service connectivity

### Production Monitoring
- **Health checks** - Regular validation of search service availability
- **Error detection** - Identify 206 errors and other HTTP issues early
- **Performance monitoring** - Track search latency and optimization opportunities
- **Capacity planning** - Analyze request sizes and response times

### Enterprise Features
- **Security compliance** - Distroless runtime with minimal attack surface
- **Certificate support** - Custom CA certificates for enterprise environments
- **Comprehensive logging** - Full request/response capture for audit trails
- **Multi-environment** - Easy configuration switching via environment variables

The secure multi-stage build ensures it's safe for enterprise environments while providing comprehensive diagnostic capabilities.

## 📈 Key Benefits

✅ **Comprehensive Testing** - Tests all search methods (basic, semantic, hybrid)  
✅ **GPT Integration** - Enhanced answers using configurable GPT models  
✅ **Performance Insights** - Detailed timing and optimization recommendations  
✅ **Error Detection** - Advanced 206 error analysis and HTTP debugging  
✅ **Security First** - Distroless runtime with non-root execution  
✅ **Enterprise Ready** - Certificate support and comprehensive logging  
✅ **Easy Configuration** - Environment variable-driven setup  
✅ **Production Safe** - Minimal dependencies and isolated runtime  

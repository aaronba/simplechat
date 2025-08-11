# Azure AI Search Debug Container - Production Ready

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
```bash
# Required for Azure AI Search
export AZURE_AI_SEARCH_ENDPOINT="https://your-search.search.windows.net"
export AZURE_AI_SEARCH_KEY="your-search-key"

# Optional for hybrid search (OpenAI embeddings)
export AZURE_OPENAI_ENDPOINT="https://your-openai.openai.azure.com"
export AZURE_OPENAI_KEY="your-openai-key"
```

### 3. Run the Diagnostic
```bash
docker run --rm \
  -e AZURE_AI_SEARCH_ENDPOINT="$AZURE_AI_SEARCH_ENDPOINT" \
  -e AZURE_AI_SEARCH_KEY="$AZURE_AI_SEARCH_KEY" \
  -e AZURE_OPENAI_ENDPOINT="$AZURE_OPENAI_ENDPOINT" \
  -e AZURE_OPENAI_KEY="$AZURE_OPENAI_KEY" \
  debug-ai-search-secure
```

## 🔍 What It Detects

### HTTP 206 Error Analysis
- **Partial Content responses** from Azure AI Search
- **Range header issues** in large result sets
- **Content-Length mismatches** in chunked responses
- **Request size thresholds** that trigger 206 responses

### Performance Monitoring
- **Search latency** per request type (basic/semantic/hybrid)
- **Vector embedding timing** for OpenAI operations
- **Request payload sizes** and optimization opportunities
- **Connection health** and timeout detection

### Search Functionality Testing
- **Basic text search** across multiple indexes
- **Semantic search** with reranking
- **Hybrid search** with vector embeddings (when OpenAI configured)
- **Filtered queries** with field selection

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

============================================================
SIMPLE AZURE AI SEARCH TEST
============================================================

🔍 Testing basic text search: 'what did Ahmed have for lunch' on user index
   • SharePoint agents Field FAQ.PDF (Score: 1.502)
   • SharePoint agents Field FAQ.PDF (Score: 1.318)
   ✓ Basic text search works - 5 total results

📊 HTTP RESPONSE ANALYSIS:
========================================
✅ All HTTP requests returned status 200 (Success)
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
  -e AZURE_AI_SEARCH_ENDPOINT="$AZURE_AI_SEARCH_ENDPOINT" \
  -e AZURE_AI_SEARCH_KEY="$AZURE_AI_SEARCH_KEY" \
  your-acr.azurecr.io/debug-ai-search:latest
```

## 🔧 Troubleshooting

### Container Won't Start
- Verify environment variables are set correctly
- Check Docker daemon is running
- Ensure sufficient memory (container uses <100MB)

### No Search Results
- Verify Azure AI Search endpoint URL format
- Check API key permissions
- Confirm index names exist in your search service

### 206 Errors Not Detected
- The container will only show 206 errors if they actually occur
- Try larger queries or different search scenarios
- Check Azure AI Search service logs for additional context

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
- **Development debugging** - Diagnosing Azure AI Search issues
- **CI/CD pipelines** - Automated search service validation
- **Production monitoring** - Detecting 206 errors in live systems
- **Performance analysis** - Measuring search latency and optimization

The secure multi-stage build ensures it's safe for enterprise environments while providing comprehensive diagnostic capabilities.

### This is the run command
```
docker run --rm `
  -v "${PWD}/certs:/app/certs" `
  -e AZURE_AI_SEARCH_ENDPOINT="$env:AZURE_AI_SEARCH_ENDPOINT" `
  -e AZURE_AI_SEARCH_KEY="$env:AZURE_AI_SEARCH_KEY" `
  -e AZURE_OPENAI_ENDPOINT="$env:AZURE_OPENAI_ENDPOINT" `
  -e AZURE_OPENAI_KEY="$env:AZURE_OPENAI_KEY" `
  debug-ai-search-secure
```

# Quick Start Guide

## TL;DR

```bash
cd ops-assistant

# Build container
podman build -t ops-incident-assistant .

# Run container (with color output)
podman run -t --network=host --env-file .env ops-incident-assistant
```

You may see deprecation warnings - these are expected and the application will work correctly.

## What to Expect

### Normal Startup Messages

```
Warning: Could not import langchain_litellm (AttributeError: ...)
Falling back to langchain_community.chat_models.ChatLiteLLM (deprecated but functional)
```
**This is normal** - the app automatically uses a fallback for compatibility.

```
Error initializing MCP tools: ...
Running without MCP tools - agent will have limited capabilities
```
**This is expected** if MCP server is not accessible. The agent will still run.

```
LangChainDeprecationWarning: The class ChatLiteLLM was deprecated...
```
**Safe to ignore** - functionality remains the same.

### Successful Startup

When everything is working, you'll see:

```
🚀 Starting Ops Incident Assistant
   Host: 0.0.0.0:5678
   Model: your-model-name
   MCP Server: https://your-mcp-server/mcp
   Recursion Limit: 50
   Tool Retry Limit: 3
Successfully initialized N MCP tools
Tool retry configuration: max 3 retries with exponential backoff
Available tools: ['get_job_templates', 'launch_job_template', ...]
ReAct agent created successfully
INFO: Started server process
INFO: Waiting for application startup
INFO: Application startup complete
```

### Understanding the Colored Output

When the agent processes a question, you'll see **real-time colored output**:

- **🟢 Green**: Questions and system information
- **🟡 Yellow**:
  - `[Step N] 🤖 LLM calling tools:` - When the LLM decides to use tools
  - `[Step N] 🔧 Tool 'name' response:` - Results from tool execution
- **🔵 Cyan**:
  - `[Step N] 💭 LLM response:` - LLM's reasoning and thoughts
  - `✅ FINAL ANSWER:` - The final response to the user
- **🔴 Red**: Errors and exceptions
- **🟣 Magenta**: Warnings and deprecation notices

This helps you see the **ReAct cycle** in action:
1. LLM thinks and decides which tools to call (yellow 🤖)
2. Tools execute and return results (yellow 🔧)
3. LLM processes results and reasons (cyan 💭)
4. Repeat until LLM has enough information to answer (cyan ✅)

### Tool Retry Behavior

The system automatically retries failed tool calls with exponential backoff:

```
⚠️  Tool call failed (attempt 1/4): ClosedResourceError
   Retrying in 1.0 seconds...
⚠️  Tool call failed (attempt 2/4): ClosedResourceError
   Retrying in 2.0 seconds...
```

**What triggers automatic retries:**
- Connection errors (ClosedResourceError, SSE stream errors)
- Timeout errors
- Network issues

**What does NOT trigger retries (returned as helpful error to LLM):**
- **Type errors** (e.g., passing `'midrange'` as string when integer expected)
- Parameter errors (missing, invalid names)
- Validation errors
- Authorization failures

When a type/parameter error occurs, the error message is returned to the LLM with helpful hints so it can:
1. See what went wrong (e.g., "expected int, got str")
2. Understand the correct parameter types (e.g., "use integers not strings for IDs")
3. Correct the parameters and retry the tool call

**Example scenario:**
```
LLM calls: get_host_inventories(organization_id='midrange')  # Wrong: string
↓
System returns: "ERROR: Type error - use integers not strings for IDs"
↓
LLM corrects: get_host_inventories(organization_id=1)  # Correct: integer
↓
Success! ✅
```

This makes the agent resilient to both transient failures AND helps the LLM self-correct parameter mistakes.

## Testing the Agent

### Quick Test

```bash
set -a
source .env
set +a

curl -X POST http://localhost:5678/webhook/$WEBHOOK_PATH \
  -H "Content-Type: application/json" \
  -d '{"question": "What job templates are available?"}'

curl -X POST http://localhost:5678/webhook/$WEBHOOK_PATH \
  -H "Content-Type: application/json" \
  -d @../prompts/01-disk-full.json
```

Response:
```json
{
  "answer": "I called get_job_templates() and found the following templates: ..."
}
```

### Health Check

```bash
curl http://localhost:5678/health
```

Response:
```json
{
  "status": "healthy",
  "agent_initialized": true
}
```

## Environment Variables

Create a `.env` file:

```bash
# Required: LLM Configuration
OPENAI_API_KEY=your-api-key
OPENAI_BASE_URL=https://your-llm-endpoint/v1
MODEL_NAME=your-model-name

# Required: MCP Server
MCP_SERVER_URL=https://your-mcp-server/mcp

# Optional: Server Configuration
SERVER_HOST=0.0.0.0
SERVER_PORT=5678
WEBHOOK_PATH=your-webhook-path
LOG_LEVEL=INFO

# Optional: Force color output in containers
FORCE_COLOR=1

# Optional: Agent Configuration
# Maximum reasoning steps before stopping (default: 50)
RECURSION_LIMIT=50

# Optional: Tool Retry Configuration
# Maximum number of retry attempts for failed MCP tool calls (default: 3)
# The system will retry with exponential backoff for connection/stream errors
MAX_TOOL_RETRIES=3
```

## Common Use Cases

### Use Case 1: Run with Docker/Podman

```bash
# Build
podman build -t ops-incident-assistant .

# Run with color output (recommended)
podman run -t --network=host --env-file .env ops-incident-assistant

# Or run in detached mode
podman run -d --network=host --env-file .env ops-incident-assistant
```

### Use Case 2: Run Locally (Development)

```bash
# Install dependencies
pip install -r requirements.txt

# Run
python ops_incident_assistant.py
```

### Use Case 3: Run Example Script

```bash
python example_react_usage.py
```

1. **Deploy:**
   - See Kubernetes deployment in `ocp/ops-assistant/`
   - Use container image for production

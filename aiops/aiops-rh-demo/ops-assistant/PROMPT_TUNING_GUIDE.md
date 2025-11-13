# Prompt Tuning Guide for Tool Calling

## What Changed

I've optimized the system prompt and configuration to work better with Mistral-Small-24B-W8A8 and other local models.

### Key Changes:

1. **Simplified System Prompt** - More direct and clear about tool usage
2. **Removed tool_choice for Custom Endpoints** - By default, doesn't send `tool_choice` parameter for `openai/` prefixed models
3. **Added ENABLE_TOOL_CHOICE** - Environment variable for fine-tuning

## Quick Test

### Step 1: Set Your Configuration

Create a `.env` file (or export these variables):

```bash
# For your local Mistral endpoint
OPENAI_API_BASE=http://localhost:8000/v1
OPENAI_API_KEY=dummy-key
MODEL_NAME=openai/Mistral-Small-24B-W8A8

# MCP Server
MCP_SERVER_URL=https://mcp-server-aap.apps.cluster-5ffmt.5ffmt.sandbox1919.opentlc.com/mcp
MCP_VERIFY_SSL=false

# Start with tool_choice disabled (recommended for local models)
ENABLE_TOOL_CHOICE=false

# Other settings
SERVER_HOST=0.0.0.0
SERVER_PORT=5678
LOG_LEVEL=INFO
FORCE_COLOR=1
RECURSION_LIMIT=50
```

### Step 2: Run the Agent

```bash
cd /home/jveverka/git/rh-demos/aiops/aiops-rh-demo/ops-assistant
python ops_incident_assistant.py
```

Watch the startup logs - you should see:
```
Model: openai/Mistral-Small-24B-W8A8
Tool choice setting: Disabled
⚠️  Using custom endpoint with tool_choice disabled by default.
```

### Step 3: Test with a Simple Question

```bash
curl -X POST http://localhost:5678/webhook/7d1a79c6-2189-47d5-92c6-dfbac5b1fa59 \
  -H "Content-Type: application/json" \
  -d '{"question": "What job templates are available?"}'
```

### Expected Output:

✅ **Success looks like:**
```
>>>>>>> [Step 1] 🤖 LLM calling tools: ['get_job_templates']
  → get_job_templates with args: {}

>>>>>>> [Step 2] 🔧 Tool 'get_job_templates' response:
  [actual template list from AAP]
```

❌ **Failure looks like:**
```
>>>>>>> [Step 1] 💭 LLM response:
  [get_job_templates(project_id=null)]

⚠️  WARNING: Model is generating text about tools instead of calling them!
```

---

## If It Still Doesn't Work

Try these configurations in order:

### Try 0: Use Google Gemini (RECOMMENDED - Has free tier!)
```bash
# Get your free API key from: https://aistudio.google.com/app/apikey
GEMINI_API_KEY=your-gemini-api-key
MODEL_NAME=gemini/gemini-1.5-flash-latest
ENABLE_TOOL_CHOICE=auto
# Remove OPENAI_API_BASE if set
```

Gemini has:
- ✅ **Free tier** with generous limits (1500 requests/day for flash)
- ✅ **Excellent function calling** support
- ✅ **Fast** responses (especially gemini-1.5-flash)
- ✅ **Good reasoning** quality

### Try 1: Tool Choice = Required
```bash
ENABLE_TOOL_CHOICE=required
```
This forces the model to always use tools.

### Try 2: Alternative Prompts

Edit `ops_incident_assistant.py` and uncomment one of the alternative prompts:

**Option 2 - Ultra-minimal:**
```python
REACT_SYSTEM_PROMPT = """You are an operations assistant. Use the available tools to answer questions about Ansible Automation Platform. Always use tools to get real data."""
```

**Option 3 - Explicit ReAct format:**
```python
REACT_SYSTEM_PROMPT = """You are an assistant with access to tools for Ansible Automation Platform.

When the user asks a question:
1. Use the appropriate tool to get the information
2. Return the result to the user

Example: If asked "What templates are available?", use get_job_templates to retrieve them."""
```

### Try 3: Check Your Inference Server

If using vLLM, make sure it's configured for tool calling:

```bash
vllm serve mistralai/Mistral-Small-Instruct-2409 \
  --enable-auto-tool-choice \
  --tool-call-parser mistral \
  --host 0.0.0.0 \
  --port 8000
```

**Important:** Use the non-quantized version if possible. Quantization (W8A8) often breaks function calling.

### Try 4: Test with a Cloud Model

To verify your code is correct, temporarily test with a cloud model.

**Option A: Google Gemini (FREE - Recommended for testing):**
```bash
# Get free API key from: https://aistudio.google.com/app/apikey
GEMINI_API_KEY=your-gemini-api-key
MODEL_NAME=gemini/gemini-1.5-flash-latest
ENABLE_TOOL_CHOICE=auto
# Remove or comment out OPENAI_API_BASE
```

**Option B: OpenAI (Paid):**
```bash
OPENAI_API_KEY=your-openai-key
MODEL_NAME=gpt-3.5-turbo
# Remove or comment out OPENAI_API_BASE
```

If this works, the issue is definitely with your local model/endpoint.

---

## Environment Variable Reference

| Variable             | Values                           | Effect                                     |
| -------------------- | -------------------------------- | ------------------------------------------ |
| `ENABLE_TOOL_CHOICE` | `auto`                           | Let model decide (good for cloud)          |
|                      | `required`                       | Force tool usage (aggressive)              |
|                      | `none`                           | Don't prefer tools                         |
|                      | `false`                          | Skip tool_choice entirely (best for local) |
| `MODEL_NAME`         | `gemini/gemini-1.5-flash-latest` | Google Gemini (FREE, excellent)            |
|                      | `gemini/gemini-1.5-pro-latest`   | Google Gemini Pro (FREE, best)             |
|                      | `gpt-3.5-turbo`                  | OpenAI (paid, reliable)                    |
|                      | `gpt-4o`                         | OpenAI (paid, best)                        |
|                      | `claude-3-5-sonnet-20241022`     | Anthropic (paid, excellent)                |
|                      | `openai/ModelName`               | Custom endpoint (skip tool_choice)         |
| `OPENAI_API_BASE`    | `http://localhost:8000/v1`       | Your vLLM/local endpoint                   |
|                      | (not set)                        | Uses OpenAI's API                          |

---

## Debugging Tips

### 1. Enable Debug Logging
```bash
LOG_LEVEL=DEBUG python ops_incident_assistant.py
```

This shows the actual API requests/responses.

### 2. Check Tool Registration
Look for this in the startup logs:
```
Successfully initialized 8 MCP tools
Available tools: ['get_job_templates', 'launch_job_template', ...]
```

### 3. Watch for Tool Calls vs Text
When you send a question, the log should show:
- `🤖 LLM calling tools: [...]` - ✅ Good!
- `💭 LLM response: [tool_name(...)]` - ❌ Bad!

### 4. Test MCP Server Directly
```bash
curl -X POST https://mcp-server-aap.apps.cluster-5ffmt.5ffmt.sandbox1919.opentlc.com/mcp/list_tools \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}'
```

Should return the list of available tools.

---

## Best Practices

1. **Start Simple**: Use a cloud model to verify everything works
2. **Test Locally**: Switch to your local model once verified
3. **Tune Gradually**: Start with `ENABLE_TOOL_CHOICE=false`, then try other values
4. **Check Logs**: The colored output shows exactly what's happening
5. **Simplify Prompt**: If stuck, use the ultra-minimal prompt

---

## Common Issues

| Problem                                 | Solution                       |
| --------------------------------------- | ------------------------------ |
| Model generates `[tool_name(...)]` text | Set `ENABLE_TOOL_CHOICE=false` |
| No tools being called at all            | Check MCP server connection    |
| "NoneType is not callable" error        | Set `ENABLE_TOOL_RETRY=false`  |
| Recursion limit exceeded                | Increase `RECURSION_LIMIT=100` |
| SSL errors connecting to MCP            | Set `MCP_VERIFY_SSL=false`     |

---

## What's Your Mistral Setup?

Since tool calling WAS working before, make sure:
- Your inference server is the same (vLLM version, configuration)
- The model is the same (not a different quantization)
- Your API endpoint hasn't changed
- The endpoint properly implements OpenAI's function calling API

If you were using a different tool/framework before (like OpenAI's native SDK), the issue might be LiteLLM's abstraction layer. In that case, try `ENABLE_TOOL_CHOICE=required` to be more explicit.


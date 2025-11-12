# Quick Start Guide

## TL;DR

```bash
cd ops-assistant

# Build container
podman build -t ops-incident-assistant .

# Run container
podman run -p 5678:5678 --env-file .env ops-incident-assistant
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
Successfully initialized N MCP tools
Available tools: ['get_job_templates', 'launch_job_template', ...]
ReAct agent created successfully
INFO: Started server process
INFO: Waiting for application startup
INFO: Application startup complete
```

## Testing the Agent

### Quick Test

```bash
curl -X POST http://localhost:5678/webhook/YOUR-WEBHOOK-PATH \
  -H "Content-Type: application/json" \
  -d '{"question": "What job templates are available?"}'
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
```

## Common Use Cases

### Use Case 1: Run with Docker/Podman

```bash
# Build
podman build -t ops-incident-assistant .

# Run
podman run -p 5678:5678 --env-file .env ops-incident-assistant
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

## Troubleshooting Quick Fixes

### Problem: Port Already in Use
```bash
# Change port in .env
SERVER_PORT=8080
```

### Problem: MCP Server Not Accessible
- Agent will run without tools (limited functionality)
- Verify `MCP_SERVER_URL` is correct
- Check network connectivity

### Problem: LLM Not Responding
- Check `OPENAI_API_KEY` is set
- Verify `OPENAI_BASE_URL` is correct
- Test with: `curl $OPENAI_BASE_URL/health`

### Problem: Import Errors
```bash
# Reinstall dependencies
pip install --upgrade -r requirements.txt
```

For detailed troubleshooting, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md)

## Next Steps

1. **Review Documentation:**
   - [IMPLEMENTATION_GUIDE.md](IMPLEMENTATION_GUIDE.md) - Detailed implementation docs
   - [REACT_IMPLEMENTATION.md](REACT_IMPLEMENTATION.md) - ReAct agent details
   - [API_UPDATE_NOTES.md](API_UPDATE_NOTES.md) - Recent API changes

2. **Customize:**
   - Modify `REACT_SYSTEM_PROMPT` in `ops_incident_assistant.py`
   - Add custom tools to the agent
   - Adjust LLM parameters

3. **Deploy:**
   - See Kubernetes deployment in `ocp/ops-assistant/`
   - Use container image for production

## Support

If you encounter issues:
1. Check logs for error messages
2. Review [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
3. Verify all environment variables are set
4. Test MCP server connectivity separately


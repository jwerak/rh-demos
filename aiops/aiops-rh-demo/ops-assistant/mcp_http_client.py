"""
MCP Client for Ansible Automation Platform
Implements Model Context Protocol using langchain_mcp_adapters
"""

import httpx
import asyncio
from typing import Any, Dict, List, Optional
from langchain_core.tools import tool, StructuredTool
from langchain_mcp_adapters.client import MultiServerMCPClient
from functools import wraps


def create_retry_wrapper(func, max_retries=3, initial_delay=1.0):
    """
    Create a retry wrapper for async functions with exponential backoff

    Args:
        func: The async function to wrap
        max_retries: Maximum number of retry attempts
        initial_delay: Initial delay between retries in seconds

    Returns:
        Wrapped function with retry logic
    """

    @wraps(func)
    async def wrapper(*args, **kwargs):
        last_exception = None
        delay = initial_delay

        for attempt in range(max_retries + 1):
            try:
                # Ensure func is callable
                if func is None:
                    return "ERROR: Tool function is None - this is a bug in the retry wrapper setup"
                return await func(*args, **kwargs)
            except Exception as e:
                last_exception = e
                error_msg = str(e)

                # Add more context for debugging
                if "NoneType" in error_msg and "callable" in error_msg:
                    error_msg = f"{error_msg} (Tool function appears to be None - check MCP tool setup)"

                # Check if it's a retryable error (connection/stream issues)
                # vs non-retryable (parameter/validation/type errors)
                is_retryable = (
                    "ClosedResourceError" in error_msg
                    or "SSE" in error_msg
                    or "stream" in error_msg.lower()
                    or "connection" in error_msg.lower()
                    or "timeout" in error_msg.lower()
                )

                # Identify parameter/type/validation errors (should NOT retry)
                is_parameter_error = any(
                    [
                        "parameter" in error_msg.lower(),
                        "argument" in error_msg.lower(),
                        "validation" in error_msg.lower(),
                        "type" in error_msg.lower(),
                        "expected" in error_msg.lower()
                        and ("int" in error_msg.lower() or "str" in error_msg.lower()),
                        "invalid" in error_msg.lower(),
                        "required" in error_msg.lower(),
                        "missing" in error_msg.lower(),
                    ]
                )

                if attempt < max_retries and is_retryable and not is_parameter_error:
                    print(
                        f"⚠️  Tool call failed (attempt {attempt + 1}/{max_retries + 1}): {error_msg}"
                    )
                    print(f"   Retrying in {delay:.1f} seconds...")
                    await asyncio.sleep(delay)
                    delay *= 2  # Exponential backoff
                else:
                    # For parameter/type errors, provide detailed error message
                    if is_parameter_error:
                        error_detail = (
                            f"Parameter/Type Error: {error_msg}\n\n"
                            f"Hint: Check that:\n"
                            f"- All required parameters are provided\n"
                            f"- Parameter types are correct (e.g., integers not strings for IDs)\n"
                            f"- Parameter names match the tool's schema\n"
                            f"Please call the tool again with corrected parameters."
                        )
                    else:
                        error_detail = f"Tool execution failed after {attempt + 1} attempts: {error_msg}"

                    # Return error as string instead of raising exception
                    # This allows the agent to see the error and potentially retry with different params
                    return f"ERROR: {error_detail}"

        # Should not reach here, but just in case
        return f"ERROR: Tool execution failed after {max_retries + 1} attempts: {str(last_exception)}"

    return wrapper


class MCPHTTPClient:
    """HTTP client for MCP server"""

    def __init__(self, base_url: str, timeout: float = 30.0, verify_ssl: bool = True):
        self.base_url = base_url.rstrip("/")
        self.client = httpx.AsyncClient(timeout=timeout, verify=verify_ssl)
        self._tools_cache = None

    async def close(self):
        """Close the HTTP client"""
        await self.client.aclose()

    async def list_tools(self) -> List[Dict[str, Any]]:
        """List available tools from MCP server"""
        response = await self.client.post(
            f"{self.base_url}/list_tools",
            json={"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
        )
        response.raise_for_status()
        data = response.json()

        if "result" in data and "tools" in data["result"]:
            self._tools_cache = data["result"]["tools"]
            return self._tools_cache
        return []

    async def call_tool(self, tool_name: str, arguments: Dict[str, Any]) -> Any:
        """Call a specific tool on the MCP server"""
        response = await self.client.post(
            f"{self.base_url}/call_tool",
            json={
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": {"name": tool_name, "arguments": arguments},
            },
        )
        response.raise_for_status()
        data = response.json()

        if "result" in data:
            return data["result"]
        elif "error" in data:
            raise Exception(f"MCP tool error: {data['error']}")
        return None

    def create_langchain_tools(self, tools_metadata: Optional[List[Dict]] = None):
        """
        Create LangChain tools from MCP tools metadata

        Args:
            tools_metadata: List of tool metadata from MCP server
                           If None, uses cached tools
        """
        if tools_metadata is None:
            tools_metadata = self._tools_cache or []

        langchain_tools = []

        for tool_meta in tools_metadata:
            tool_name = tool_meta.get("name", "unknown")
            tool_description = tool_meta.get("description", "")
            input_schema = tool_meta.get("inputSchema", {})

            # Create a dynamic tool function
            langchain_tool = self._create_tool_function(
                tool_name, tool_description, input_schema
            )
            langchain_tools.append(langchain_tool)

        return langchain_tools

    def _create_tool_function(self, name: str, description: str, input_schema: Dict):
        """Create a LangChain tool function dynamically"""

        # Extract parameters from JSON schema
        properties = input_schema.get("properties", {})
        required = input_schema.get("required", [])

        # Build parameter annotations dynamically
        # For simplicity, we'll create a function that accepts **kwargs

        @tool(name=name, description=description)
        async def dynamic_tool(**kwargs) -> str:
            """Dynamically created MCP tool"""
            result = await self.call_tool(name, kwargs)
            return str(result)

        return dynamic_tool


# Example usage functions for specific AAP tools


async def create_aap_tools(
    mcp_url: str,
    verify_ssl: bool = True,
    max_retries: int = 3,
    enable_retry: bool = True,
):
    """
    Create AAP-specific tools from MCP server using langchain_mcp_adapters

    Args:
        mcp_url: URL of the MCP server
        verify_ssl: Whether to verify SSL certificates
        max_retries: Maximum number of retries for tool calls
        enable_retry: Whether to enable retry wrapper (set False for debugging)

    Returns:
        Tuple of (client, tools) where tools optionally have retry logic
    """
    try:
        # Use MultiServerMCPClient with streamable_http transport
        client = MultiServerMCPClient(
            {
                "aap": {
                    "transport": "streamable_http",
                    "url": mcp_url,
                }
            }
        )

        # Get tools from MCP server
        print(f"Connecting to MCP server (streamable_http): {mcp_url}")
        mcp_tools = await client.get_tools()
        print(f"Retrieved {len(mcp_tools)} tools from MCP server")

        # Return tools without wrapping if retry is disabled
        if not enable_retry:
            print(f"⚠️  Retry wrapper disabled - using tools as-is")
            return client, mcp_tools

        # Wrap each tool with retry logic
        wrapped_tools = []
        for tool in mcp_tools:
            # Get the original tool function (MCP tools are async, so check coroutine first)
            if hasattr(tool, "coroutine") and tool.coroutine is not None:
                original_func = tool.coroutine
            elif hasattr(tool, "func") and tool.func is not None:
                original_func = tool.func
            elif hasattr(tool, "_run"):
                original_func = tool._run
            else:
                # If we can't find the function, skip wrapping this tool
                print(f"⚠️  Warning: Could not wrap tool {tool.name}, using original")
                wrapped_tools.append(tool)
                continue

            # Wrap it with retry logic
            wrapped_func = create_retry_wrapper(original_func, max_retries=max_retries)

            # Create a new tool with the wrapped function, preserving all original properties
            # Since MCP tools are async, the wrapped function is always a coroutine
            tool_kwargs = {
                "name": tool.name,
                "description": tool.description,
                "coroutine": wrapped_func,
            }

            # Preserve optional attributes from original tool
            if hasattr(tool, "args_schema") and tool.args_schema is not None:
                tool_kwargs["args_schema"] = tool.args_schema
            if hasattr(tool, "return_direct"):
                tool_kwargs["return_direct"] = tool.return_direct
            if hasattr(tool, "verbose"):
                tool_kwargs["verbose"] = tool.verbose
            if hasattr(tool, "callbacks"):
                tool_kwargs["callbacks"] = tool.callbacks
            if hasattr(tool, "tags"):
                tool_kwargs["tags"] = tool.tags
            if hasattr(tool, "metadata"):
                tool_kwargs["metadata"] = tool.metadata

            try:
                wrapped_tool = StructuredTool(**tool_kwargs)
                wrapped_tools.append(wrapped_tool)
            except Exception as e:
                print(f"⚠️  Error wrapping tool {tool.name}: {e}")
                print(f"   Using original tool instead")
                wrapped_tools.append(tool)

        print(
            f"✅ Wrapped {len(wrapped_tools)} tools with retry logic (max {max_retries} retries)"
        )
        return client, wrapped_tools

    except Exception as e:
        import traceback

        print(f"Error creating AAP tools: {e}")
        print(f"Traceback: {traceback.format_exc()}")
        print(f"MCP URL: {mcp_url}")
        print(f"SSL Verification: {'Enabled' if verify_ssl else 'Disabled'}")
        raise


# Manually defined tools as fallback (based on expected AAP MCP interface)


@tool
async def get_job_templates(mcp_client: MCPHTTPClient) -> str:
    """
    Get list of available Ansible Automation Platform job templates.
    This should be called first to see what automation is available.
    """
    result = await mcp_client.call_tool("get_job_templates", {})
    return str(result)


@tool
async def launch_job_template(
    mcp_client: MCPHTTPClient,
    template_id: int,
    extra_vars: Optional[Dict[str, Any]] = None,
) -> str:
    """
    Launch an Ansible Automation Platform job template.

    Args:
        template_id: The ID of the job template to launch
        extra_vars: Optional extra variables to pass to the job
    """
    arguments = {"template_id": template_id}
    if extra_vars:
        arguments["extra_vars"] = extra_vars

    result = await mcp_client.call_tool("launch_job_template", arguments)
    return str(result)


@tool
async def get_job_status(mcp_client: MCPHTTPClient, job_id: int) -> str:
    """
    Get the status of a running Ansible Automation Platform job.

    Args:
        job_id: The ID of the job to check
    """
    result = await mcp_client.call_tool("get_job_status", {"job_id": job_id})
    return str(result)


@tool
async def get_job_output(mcp_client: MCPHTTPClient, job_id: int) -> str:
    """
    Get the output/logs of an Ansible Automation Platform job.

    Args:
        job_id: The ID of the job to get output for
    """
    result = await mcp_client.call_tool("get_job_output", {"job_id": job_id})
    return str(result)

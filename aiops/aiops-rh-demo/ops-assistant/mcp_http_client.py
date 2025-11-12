"""
MCP Client for Ansible Automation Platform
Implements Model Context Protocol using langchain_mcp_adapters
"""

import httpx
from typing import Any, Dict, List, Optional
from langchain_core.tools import tool
from langchain_mcp_adapters.client import MultiServerMCPClient


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


async def create_aap_tools(mcp_url: str, verify_ssl: bool = True):
    """Create AAP-specific tools from MCP server using langchain_mcp_adapters"""
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

        return client, mcp_tools

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

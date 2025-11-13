"""
Ops Incident Assistant - ReAct Agent Implementation using LangGraph
Reimplementation using LangGraph's built-in ReAct agent with FastAPI
"""

import os
from typing import Optional, List
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import uvicorn
from colorama import Fore, Style, init

from langchain_core.messages import HumanMessage
from langchain_core.tools import BaseTool
from langgraph.prebuilt import create_react_agent

# Initialize colorama with forced colors for container environments
# strip=False keeps colors even when output is not directly to terminal
# force colors if FORCE_COLOR env var is set
FORCE_COLOR = os.getenv("FORCE_COLOR", "0") in ("1", "true", "yes")
init(autoreset=True, strip=False if FORCE_COLOR else None)

try:
    from langchain_litellm import ChatLiteLLM
except Exception as e:
    # Fallback to deprecated version if langchain-litellm not installed
    # or if there are compatibility issues (e.g., aiohttp version conflicts)
    # Note: Can't use print_warning here as it's not defined yet
    print(
        f"{Fore.MAGENTA}Warning: Could not import langchain_litellm ({type(e).__name__}: {e}){Style.RESET_ALL}"
    )
    print(
        f"{Fore.MAGENTA}Falling back to langchain_community.chat_models.ChatLiteLLM (deprecated but functional){Style.RESET_ALL}"
    )
    from langchain_community.chat_models import ChatLiteLLM

# Import our MCP HTTP client
from mcp_http_client import MCPHTTPClient, create_aap_tools


# Configuration from environment variables
MCP_SERVER_URL = os.getenv(
    "MCP_SERVER_URL",
    "https://mcp-server-aap.apps.cluster-5ffmt.5ffmt.sandbox1919.opentlc.com/mcp",
)
MCP_VERIFY_SSL = os.getenv("MCP_VERIFY_SSL", "true").lower() in ("true", "1", "yes")
MODEL_NAME = os.getenv("MODEL_NAME", "DeepSeek-R1-Distill-Qwen-14B-W4A16")
MODEL_TEMPERATURE = float(os.getenv("MODEL_TEMPERATURE", "0"))
WEBHOOK_PATH = os.getenv("WEBHOOK_PATH", "7d1a79c6-2189-47d5-92c6-dfbac5b1fa59")
SERVER_HOST = os.getenv("SERVER_HOST", "0.0.0.0")
SERVER_PORT = int(os.getenv("SERVER_PORT", "5678"))
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO")
RECURSION_LIMIT = int(os.getenv("RECURSION_LIMIT", "50"))
MAX_TOOL_RETRIES = int(os.getenv("MAX_TOOL_RETRIES", "3"))
ENABLE_TOOL_RETRY = os.getenv("ENABLE_TOOL_RETRY", "true").lower() in (
    "true",
    "1",
    "yes",
)
ENABLE_TOOL_CHOICE = os.getenv("ENABLE_TOOL_CHOICE", "auto").lower()


# Color print helpers
def print_info(msg: str):
    """Print info messages in green"""
    print(f"{Fore.GREEN}{msg}{Style.RESET_ALL}")


def print_llm(msg: str):
    """Print LLM responses in cyan"""
    print(f"{Fore.CYAN}{msg}{Style.RESET_ALL}")


def print_tool(msg: str):
    """Print tool calls in yellow"""
    print(f"{Fore.YELLOW}{msg}{Style.RESET_ALL}")


def print_error(msg: str):
    """Print errors in red"""
    print(f"{Fore.RED}{msg}{Style.RESET_ALL}")


def print_warning(msg: str):
    """Print warnings in magenta"""
    print(f"{Fore.MAGENTA}{msg}{Style.RESET_ALL}")


# System prompt for the ReAct agent
# If tool calling doesn't work, try one of the alternative prompts below

# OPTION 1: Direct and imperative (current)
REACT_SYSTEM_PROMPT = """You are a helpful assistant that manages RHEL servers using Ansible Automation Platform.

You have access to tools. Use them to get accurate information. Never guess or make up data.
Don't ask the user for confirmation, always launch the templates you find appropriate.

Available actions:
- To see job templates: call get_job_templates
- To launch a job: call launch_job_template
- To check job status: call get_job_status
- To see job output: call get_job_output
- To list hosts: call get_host_inventories

Always call the appropriate tool to answer the user's question."""

# OPTION 2: Ultra-minimal (uncomment to try)
# REACT_SYSTEM_PROMPT = """You are an operations assistant. Use the available tools to answer questions about Ansible Automation Platform. Always use tools to get real data."""

# OPTION 3: Explicit ReAct format (uncomment to try)
# REACT_SYSTEM_PROMPT = """You are an assistant with access to tools for Ansible Automation Platform.
#
# When the user asks a question:
# 1. Use the appropriate tool to get the information
# 2. Return the result to the user
#
# Example: If asked "What templates are available?", use get_job_templates to retrieve them."""


class ReActAgent:
    """ReAct (Reasoning and Acting) Agent for Ops Incident Response using LangGraph"""

    def __init__(self, mcp_server_url: str, model_name: str):
        self.mcp_server_url = mcp_server_url
        self.model_name = model_name
        self.tools: List[BaseTool] = []
        self.mcp_client: Optional[MCPHTTPClient] = None
        self.graph = None

        # Initialize LLM with LiteLLM
        model_kwargs = {}

        # Configure tool_choice based on environment and model type
        # Options: "auto", "required", "none", or "false" to disable
        if ENABLE_TOOL_CHOICE and ENABLE_TOOL_CHOICE != "false":
            # For custom endpoints (openai/ prefix), tool_choice can cause issues
            # Skip it unless explicitly enabled
            if not model_name.startswith("openai/") or ENABLE_TOOL_CHOICE == "required":
                model_kwargs["tool_choice"] = ENABLE_TOOL_CHOICE

        self.llm = ChatLiteLLM(
            model=model_name,
            temperature=MODEL_TEMPERATURE,
            model_kwargs=model_kwargs,
        )

    async def initialize_mcp_tools(self):
        """Initialize MCP tools from the server"""
        try:
            # Create MCP client and get tools
            print_info(f"Connecting to MCP server: {self.mcp_server_url}")
            if MCP_VERIFY_SSL:
                print_info("SSL Verification: Enabled")
            else:
                print_warning("SSL Verification: Disabled (WARNING: Insecure)")

            self.mcp_client, self.tools = await create_aap_tools(
                self.mcp_server_url,
                verify_ssl=MCP_VERIFY_SSL,
                max_retries=MAX_TOOL_RETRIES,
                enable_retry=ENABLE_TOOL_RETRY,
            )
            print_info(f"Successfully initialized {len(self.tools)} MCP tools")
            if ENABLE_TOOL_RETRY:
                print_info(
                    f"Tool retry configuration: max {MAX_TOOL_RETRIES} retries with exponential backoff"
                )
            else:
                print_warning(
                    f"Tool retry is DISABLED - tools will not automatically retry on failures"
                )
            print_tool(f"Available tools: {[tool.name for tool in self.tools]}")

            # Create the ReAct agent using LangGraph's create_react_agent
            self.graph = create_react_agent(
                model=self.llm, tools=self.tools, prompt=REACT_SYSTEM_PROMPT
            )
            print_info("ReAct agent created successfully")

            # Show model and configuration
            print_info(f"Model: {self.model_name}")
            print_info(
                f"Tool choice setting: {ENABLE_TOOL_CHOICE if ENABLE_TOOL_CHOICE != 'false' else 'Disabled'}"
            )

            if self.model_name.startswith("openai/") and ENABLE_TOOL_CHOICE == "auto":
                print_warning(
                    "⚠️  Using custom endpoint with tool_choice disabled by default.\n"
                    "   If the model generates text instead of calling tools, try:\n"
                    "   - ENABLE_TOOL_CHOICE=false (skip tool_choice entirely)\n"
                    "   - ENABLE_TOOL_CHOICE=required (force tool usage)\n"
                    "   - Or simplify the system prompt (see prompt alternatives in code)"
                )
            else:
                print_info(
                    "ℹ️  Tool calling configuration:\n"
                    f"   - Tool choice: {ENABLE_TOOL_CHOICE}\n"
                    f"   - Model type: {'Custom endpoint' if self.model_name.startswith('openai/') else 'Cloud API'}\n"
                    "   If tools aren't being called, check FUNCTION_CALLING_TROUBLESHOOTING.md"
                )

        except Exception as e:
            import traceback

            print_error(f"Error initializing MCP tools: {e}")
            print_error(f"Traceback: {traceback.format_exc()}")
            print_warning(
                "Running without MCP tools - agent will have limited capabilities"
            )

            # Create agent even without tools
            self.graph = create_react_agent(
                model=self.llm, tools=[], prompt=REACT_SYSTEM_PROMPT
            )

    async def run(self, question: str) -> str:
        """
        Run the ReAct agent with streaming output

        Args:
            question: The user's question/request

        Returns:
            The final answer from the agent
        """
        if self.graph is None:
            raise RuntimeError(
                "Agent not initialized. Call initialize_mcp_tools() first."
            )

        print_info(f"\n{'='*80}")
        print_info(f"Question: {question}")
        print_tool(f"Available Tools: {[tool.name for tool in self.tools]}")
        print_info(f"{'='*80}\n")

        try:
            # Run the ReAct agent with streaming and increased recursion limit
            final_answer = ""
            msg_count = 0

            async for event in self.graph.astream(
                {"messages": [HumanMessage(content=question)]},
                config={"recursion_limit": RECURSION_LIMIT},
            ):
                # Each event is a dict with node name as key
                for node_name, node_output in event.items():
                    if "messages" in node_output:
                        messages = node_output["messages"]

                        # Process each new message in this event
                        for msg in (
                            messages if isinstance(messages, list) else [messages]
                        ):
                            msg_count += 1
                            msg_type = type(msg).__name__

                            if hasattr(msg, "tool_calls") and msg.tool_calls:
                                # This is an AI message with tool calls
                                tool_names = [tc.get("name") for tc in msg.tool_calls]
                                print_tool(
                                    f"\n>>>>>>> [Step {msg_count}] 🤖 LLM calling tools: {tool_names}"
                                )
                                for tc in msg.tool_calls:
                                    print_tool(
                                        f"  → {tc.get('name')} with args: {tc.get('args')}"
                                    )

                            elif msg_type == "ToolMessage":
                                # This is a tool response
                                tool_name = getattr(msg, "name", "unknown")
                                content = (
                                    msg.content if hasattr(msg, "content") else str(msg)
                                )
                                print_tool(
                                    f"\n>>>>>>> [Step {msg_count}] 🔧 Tool '{tool_name}' response:"
                                )
                                # Truncate long responses for readability
                                if len(content) > 500:
                                    print_tool(
                                        f"  {content[:500]}... (truncated, {len(content)} chars total)"
                                    )
                                else:
                                    print_tool(f"  {content}")

                            elif (
                                msg_type == "AIMessage"
                                and hasattr(msg, "content")
                                and msg.content
                            ):
                                # This is an AI response without tool calls (likely final answer)
                                content = msg.content
                                if content.strip():  # Only print non-empty content
                                    print_llm(
                                        f"\n>>>>>>> [Step {msg_count}] 💭 LLM response:"
                                    )
                                    print_llm(f"  {content}")

                                    # Detect if model is generating text that looks like tool calls
                                    # instead of actually calling tools
                                    if (
                                        any(
                                            tool_name in content
                                            for tool_name in [
                                                "get_job_templates",
                                                "launch_job_template",
                                                "get_job_status",
                                                "get_job_output",
                                                "get_host_inventories",
                                                "test_aap_connection",
                                            ]
                                        )
                                        and msg_count <= 2
                                    ):
                                        print_warning(
                                            "\n⚠️  WARNING: Model is generating text about tools instead of calling them!\n"
                                            "   This model may not support function calling properly.\n"
                                            "   Try using: gpt-4o, gpt-4-turbo, gpt-3.5-turbo, or claude-3-5-sonnet\n"
                                            "   See QUICK_START.md troubleshooting section for details.\n"
                                        )

                                    final_answer = (
                                        content  # Save as potential final answer
                                    )

            # Print final summary
            if final_answer:
                print_llm(f"\n{'='*80}")
                print_llm(f"✅ FINAL ANSWER:")
                print_llm(f"{final_answer}")
                print_llm(f"{'='*80}\n")
                return final_answer
            else:
                print_warning("⚠️  No response generated")
                return "No response generated"

        except Exception as e:
            import traceback

            error_msg = f"Error running ReAct agent: {str(e)}\n{traceback.format_exc()}"
            print_error(f"\n{'='*80}")
            print_error(f"❌ ERROR:")
            print_error(error_msg)
            print_error(f"{'='*80}\n")
            return f"Error: {error_msg}"

    async def cleanup(self):
        """Cleanup resources"""
        if self.mcp_client:
            try:
                # MultiServerMCPClient cleanup
                if hasattr(self.mcp_client, "close"):
                    await self.mcp_client.close()
                elif hasattr(self.mcp_client, "aclose"):
                    await self.mcp_client.aclose()
            except Exception as e:
                print_warning(f"Warning: Error during MCP client cleanup: {e}")


# FastAPI Webhook Server
app = FastAPI(title="Ops Incident Assistant")

# Global agent instance
agent = None


class WebhookRequest(BaseModel):
    """Request model for webhook"""

    question: str


class WebhookResponse(BaseModel):
    """Response model for webhook"""

    answer: str


@app.on_event("startup")
async def startup_event():
    """Initialize the agent on startup"""
    global agent
    agent = ReActAgent(MCP_SERVER_URL, MODEL_NAME)
    await agent.initialize_mcp_tools()
    print_info("ReAct Agent (LangGraph) initialized successfully")


@app.on_event("shutdown")
async def shutdown_event():
    """Cleanup on shutdown"""
    global agent
    if agent:
        await agent.cleanup()
        print_info("Agent cleaned up successfully")


@app.post(f"/webhook/{WEBHOOK_PATH}", response_model=WebhookResponse)
async def webhook_handler(request: WebhookRequest):
    """Handle incoming webhook requests"""
    if agent is None:
        raise HTTPException(status_code=500, detail="Agent not initialized")

    try:
        answer = await agent.run(request.question)
        return WebhookResponse(answer=answer)
    except Exception as e:
        import traceback

        error_detail = (
            f"Error processing question: {str(e)}\nTraceback: {traceback.format_exc()}"
        )
        print_error(error_detail)
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/health")
async def health_check():
    """Health check endpoint"""
    return {"status": "healthy", "agent_initialized": agent is not None}


def main():
    """Run the FastAPI server"""
    import logging

    # Configure logging
    logging.basicConfig(
        level=LOG_LEVEL, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
    )

    # Reduce noise from verbose libraries (only show warnings and errors)
    logging.getLogger("LiteLLM").setLevel(logging.WARNING)
    logging.getLogger("mcp.client.streamable_http").setLevel(
        logging.ERROR
    )  # Suppress SSE error noise
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)
    logging.getLogger("anyio").setLevel(
        logging.ERROR
    )  # Suppress ClosedResourceError noise

    print_info(f"🚀 Starting Ops Incident Assistant")
    print_info(f"   Host: {SERVER_HOST}:{SERVER_PORT}")
    print_info(f"   Model: {MODEL_NAME}")
    print_info(f"   Temperature: {MODEL_TEMPERATURE}")
    print_info(f"   MCP Server: {MCP_SERVER_URL}")
    print_info(f"   Recursion Limit: {RECURSION_LIMIT}")
    print_info(f"   Tool Retry Limit: {MAX_TOOL_RETRIES}")
    if not MCP_VERIFY_SSL:
        print_warning(f"   ⚠️  SSL Verification: Disabled")

    uvicorn.run(app, host=SERVER_HOST, port=SERVER_PORT, log_level=LOG_LEVEL.lower())


if __name__ == "__main__":
    main()

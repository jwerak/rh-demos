"""
Ops Incident Assistant - ReAct Agent Implementation using LangGraph
Reimplementation using LangGraph's built-in ReAct agent with FastAPI
"""

import os
from typing import Optional, List
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import uvicorn

from langchain_core.messages import HumanMessage
from langchain_core.tools import BaseTool
from langgraph.prebuilt import create_react_agent

try:
    from langchain_litellm import ChatLiteLLM
except Exception as e:
    # Fallback to deprecated version if langchain-litellm not installed
    # or if there are compatibility issues (e.g., aiohttp version conflicts)
    print(f"Warning: Could not import langchain_litellm ({type(e).__name__}: {e})")
    print(
        "Falling back to langchain_community.chat_models.ChatLiteLLM (deprecated but functional)"
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
WEBHOOK_PATH = os.getenv("WEBHOOK_PATH", "7d1a79c6-2189-47d5-92c6-dfbac5b1fa59")
SERVER_HOST = os.getenv("SERVER_HOST", "0.0.0.0")
SERVER_PORT = int(os.getenv("SERVER_PORT", "5678"))
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO")

REACT_SYSTEM_PROMPT = """You are an operations assistant for RHEL server management.
You are connected to Ansible Automation Platform via MCP tools:
- get_job_templates - list available automation
- launch_job_template - run automation
- get_job_status - check status of a job
- get_job_output - get output of a job
- get_host_inventories - get host inventories

RULES:
1. MUST use tools - never answer without them
2. ONLY provide info from actual tool calls

Never make up template/job IDs."""


class ReActAgent:
    """ReAct (Reasoning and Acting) Agent for Ops Incident Response using LangGraph"""

    def __init__(self, mcp_server_url: str, model_name: str):
        self.mcp_server_url = mcp_server_url
        self.model_name = model_name
        self.tools: List[BaseTool] = []
        self.mcp_client: Optional[MCPHTTPClient] = None
        self.graph = None

        # Initialize LLM with LiteLLM
        self.llm = ChatLiteLLM(
            model=model_name,
            temperature=0,
            # Enable tool calling
            model_kwargs={
                "tool_choice": "auto",  # Let model decide when to use tools
            },
        )

    async def initialize_mcp_tools(self):
        """Initialize MCP tools from the server"""
        try:
            # Create MCP client and get tools
            print(f"Connecting to MCP server: {self.mcp_server_url}")
            print(
                f"SSL Verification: {'Enabled' if MCP_VERIFY_SSL else 'Disabled (WARNING: Insecure)'}"
            )

            self.mcp_client, self.tools = await create_aap_tools(
                self.mcp_server_url, verify_ssl=MCP_VERIFY_SSL
            )
            print(f"Successfully initialized {len(self.tools)} MCP tools")
            print(f"Available tools: {[tool.name for tool in self.tools]}")

            # Create the ReAct agent using LangGraph's create_react_agent
            self.graph = create_react_agent(
                model=self.llm, tools=self.tools, prompt=REACT_SYSTEM_PROMPT
            )
            print("ReAct agent created successfully")

        except Exception as e:
            import traceback

            print(f"Error initializing MCP tools: {e}")
            print(f"Traceback: {traceback.format_exc()}")
            print("Running without MCP tools - agent will have limited capabilities")

            # Create agent even without tools
            self.graph = create_react_agent(
                model=self.llm, tools=[], prompt=REACT_SYSTEM_PROMPT
            )

    async def run(self, question: str) -> str:
        """
        Run the ReAct agent

        Args:
            question: The user's question/request

        Returns:
            The final answer from the agent
        """
        if self.graph is None:
            raise RuntimeError(
                "Agent not initialized. Call initialize_mcp_tools() first."
            )

        print(f"\nQ: {question}")
        print(f"Tools: {[tool.name for tool in self.tools]}")

        try:
            # Run the ReAct agent
            result = await self.graph.ainvoke(
                {"messages": [HumanMessage(content=question)]}
            )

            # Extract the final message content
            messages = result.get("messages", [])
            print(f"Messages: {len(messages)}")

            # Log tool calls for debugging
            for i, msg in enumerate(messages):
                if hasattr(msg, "tool_calls") and msg.tool_calls:
                    print(
                        f"Msg {i}: Tool calls = {[tc.get('name') for tc in msg.tool_calls]}"
                    )

            if messages:
                final_message = messages[-1]
                return (
                    final_message.content
                    if hasattr(final_message, "content")
                    else str(final_message)
                )
            else:
                return "No response generated"

        except Exception as e:
            import traceback

            error_msg = f"Error running ReAct agent: {str(e)}\n{traceback.format_exc()}"
            print(error_msg)
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
                print(f"Warning: Error during MCP client cleanup: {e}")


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
    print("ReAct Agent (LangGraph) initialized successfully")


@app.on_event("shutdown")
async def shutdown_event():
    """Cleanup on shutdown"""
    global agent
    if agent:
        await agent.cleanup()
        print("Agent cleaned up successfully")


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
        print(error_detail)
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

    logging.info(f"Starting Ops Incident Assistant on {SERVER_HOST}:{SERVER_PORT}")
    logging.info(f"Using model: {MODEL_NAME}")
    logging.info(f"MCP Server: {MCP_SERVER_URL}")
    logging.info(f"MCP SSL Verification: {'Enabled' if MCP_VERIFY_SSL else 'Disabled'}")

    uvicorn.run(app, host=SERVER_HOST, port=SERVER_PORT, log_level=LOG_LEVEL.lower())


if __name__ == "__main__":
    main()

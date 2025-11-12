"""
Unit tests for Ops Incident Assistant - ReAct Agent (LangGraph)
Run with: pytest test_ops_assistant.py -v
"""

import pytest
import os
from unittest.mock import Mock, AsyncMock, patch
import sys

sys.path.insert(0, "/home/jveverka/git/rh-demos/aiops/aiops-rh-demo/ops-assistant")

from ops_incident_assistant import ReActAgent, REACT_SYSTEM_PROMPT
from langchain_core.messages import HumanMessage, AIMessage


@pytest.fixture
def mock_mcp_client():
    """Mock MCP client"""
    client = Mock()
    client.list_tools = AsyncMock(
        return_value=[
            {
                "name": "get_job_templates",
                "description": "Get available job templates",
                "inputSchema": {"properties": {}, "required": []},
            }
        ]
    )
    client.call_tool = AsyncMock(return_value={"templates": ["template1", "template2"]})
    client.close = AsyncMock()
    return client


@pytest.fixture
def mock_llm():
    """Mock LLM"""
    llm = Mock()
    llm.bind_tools = Mock(return_value=llm)
    llm.invoke = Mock(return_value=AIMessage(content="Test response"))
    return llm


class TestReActAgent:
    """Test ReActAgent class"""

    def test_initialization(self):
        """Test agent initialization"""
        agent = ReActAgent(mcp_server_url="http://test.com", model_name="test-model")
        assert agent.mcp_server_url == "http://test.com"
        assert agent.model_name == "test-model"
        assert agent.tools == []
        assert agent.mcp_client is None
        assert agent.graph is None

    @pytest.mark.asyncio
    async def test_initialize_mcp_tools_success(self, mock_mcp_client):
        """Test successful MCP tools initialization"""
        with patch("ops_incident_assistant.create_aap_tools") as mock_create:
            with patch("ops_incident_assistant.create_react_agent") as mock_react:
                mock_tool = Mock()
                mock_tool.name = "test_tool"
                mock_tool.description = "Test tool description"
                mock_create.return_value = (mock_mcp_client, [mock_tool])
                mock_react.return_value = Mock()

                agent = ReActAgent(
                    mcp_server_url="http://test.com", model_name="test-model"
                )
                await agent.initialize_mcp_tools()

                assert agent.mcp_client is not None
                assert len(agent.tools) > 0
                assert agent.graph is not None

    @pytest.mark.asyncio
    async def test_initialize_mcp_tools_failure(self):
        """Test MCP tools initialization failure"""
        with patch("ops_incident_assistant.create_aap_tools") as mock_create:
            with patch("ops_incident_assistant.create_react_agent") as mock_react:
                mock_create.side_effect = Exception("Connection failed")
                mock_react.return_value = Mock()

                agent = ReActAgent(
                    mcp_server_url="http://test.com", model_name="test-model"
                )
                await agent.initialize_mcp_tools()

                # Should still create graph even without tools
                assert agent.graph is not None

    @pytest.mark.asyncio
    async def test_run_without_initialization(self):
        """Test running agent before initialization"""
        agent = ReActAgent(mcp_server_url="http://test.com", model_name="test-model")

        with pytest.raises(RuntimeError, match="Agent not initialized"):
            await agent.run("test question")

    @pytest.mark.asyncio
    async def test_cleanup(self, mock_mcp_client):
        """Test cleanup method"""
        agent = ReActAgent(mcp_server_url="http://test.com", model_name="test-model")
        agent.mcp_client = mock_mcp_client

        await agent.cleanup()

        mock_mcp_client.close.assert_called_once()


class TestSystemPrompt:
    """Test system prompt configuration"""

    def test_system_prompt_exists(self):
        """Test that system prompt is defined"""
        assert REACT_SYSTEM_PROMPT is not None
        assert len(REACT_SYSTEM_PROMPT) > 0

    def test_system_prompt_contains_react_guidance(self):
        """Test that system prompt contains ReAct guidance"""
        assert "ReAct" in REACT_SYSTEM_PROMPT
        assert "think" in REACT_SYSTEM_PROMPT.lower()

    def test_system_prompt_contains_rules(self):
        """Test that system prompt contains expected rules"""
        assert "CRITICAL" in REACT_SYSTEM_PROMPT
        assert "tools" in REACT_SYSTEM_PROMPT.lower()
        assert "ansible" in REACT_SYSTEM_PROMPT.lower()


class TestConfiguration:
    """Test configuration loading"""

    def test_environment_variables(self):
        """Test that configuration can be loaded from environment"""
        with patch.dict(
            os.environ,
            {
                "MCP_SERVER_URL": "http://custom.com",
                "MODEL_NAME": "custom-model",
                "WEBHOOK_PATH": "custom-path",
            },
        ):
            # Import after patching environment
            import importlib
            import ops_incident_assistant

            importlib.reload(ops_incident_assistant)

            assert ops_incident_assistant.MCP_SERVER_URL == "http://custom.com"
            assert ops_incident_assistant.MODEL_NAME == "custom-model"
            assert ops_incident_assistant.WEBHOOK_PATH == "custom-path"


@pytest.mark.integration
class TestIntegration:
    """Integration tests (require actual services)"""

    @pytest.mark.skip(reason="Requires actual MCP server")
    @pytest.mark.asyncio
    async def test_full_workflow(self):
        """Test full workflow with real services"""
        agent = ReActAgent(
            mcp_server_url=os.getenv("MCP_SERVER_URL"),
            model_name=os.getenv("MODEL_NAME", "gpt-4"),
        )

        await agent.initialize_mcp_tools()

        response = await agent.run("What job templates are available?")

        assert response is not None
        assert len(response) > 0

        await agent.cleanup()


if __name__ == "__main__":
    pytest.main([__file__, "-v"])

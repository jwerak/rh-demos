#!/usr/bin/env python3
"""
Test if the OpenAI-compatible endpoint supports function calling
"""
import os
import json

try:
    from langchain_litellm import ChatLiteLLM
except:
    from langchain_community.chat_models import ChatLiteLLM

from langchain_core.tools import tool


@tool
def get_weather(location: str) -> str:
    """Get weather for a location."""
    return f"Sunny in {location}"


def test_function_calling():
    model_name = os.getenv("MODEL_NAME", "openai/DeepSeek-R1-Distill-Qwen-14B-W4A16")

    print(f"Testing function calling with: {model_name}")
    print(f"API Base: {os.getenv('OPENAI_API_BASE', 'default')}")
    print("-" * 60)

    try:
        # Create LLM with tool binding
        llm = ChatLiteLLM(model=model_name, temperature=0)
        llm_with_tools = llm.bind_tools([get_weather])

        # Test invocation
        result = llm_with_tools.invoke("What's the weather in Boston?")

        print(f"\n✅ Response received")
        print(f"Type: {type(result).__name__}")
        print(f"Has tool_calls: {hasattr(result, 'tool_calls')}")

        if hasattr(result, 'tool_calls') and result.tool_calls:
            print(f"\n🎉 SUCCESS! Model supports function calling")
            print(f"Tool calls: {json.dumps(result.tool_calls, indent=2)}")
            return True
        else:
            print(f"\n❌ FAILED: No tool calls made")
            print(f"Response content: {result.content[:300]}")

            # Check if model is hallucinating tool calls
            if "get_weather" in str(result.content).lower():
                print("\n⚠️  Model is HALLUCINATING tool calls in text!")
                print("    The endpoint does NOT support function calling.")

            return False

    except Exception as e:
        print(f"\n❌ ERROR: {e}")
        import traceback
        traceback.print_exc()
        return False


if __name__ == "__main__":
    supports_tools = test_function_calling()

    print("\n" + "=" * 60)
    if supports_tools:
        print("✅ Your endpoint DOES support function calling")
        print("   The issue is elsewhere (check logs for tool invocations)")
    else:
        print("❌ Your endpoint DOES NOT support function calling")
        print("\nRECOMMENDED SOLUTIONS:")
        print("1. Use a different model endpoint that supports tools")
        print("2. Use GPT-4 or Claude: export MODEL_NAME=gpt-4o-mini")
        print("3. Check if your endpoint has function calling enabled")
    print("=" * 60)


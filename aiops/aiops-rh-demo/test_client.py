"""
Test client for Ops Incident Assistant
"""

import asyncio
import httpx
import json


async def test_webhook():
    """Test the webhook endpoint"""

    url = "http://localhost:5678/webhook/7d1a79c6-2189-47d5-92c6-dfbac5b1fa59"

    # Test questions
    test_questions = [
        "What job templates are available?",
        "Server disk is full, what should I do?",
        "Check the status of the monitoring setup",
    ]

    async with httpx.AsyncClient(timeout=60.0) as client:
        for question in test_questions:
            print(f"\n{'='*60}")
            print(f"Question: {question}")
            print(f"{'='*60}")

            try:
                response = await client.post(
                    url,
                    json={"question": question}
                )

                if response.status_code == 200:
                    result = response.json()
                    print(f"\nAnswer: {result['answer']}\n")
                else:
                    print(f"Error: {response.status_code}")
                    print(response.text)

            except Exception as e:
                print(f"Request failed: {e}")

            # Wait between requests
            await asyncio.sleep(2)


async def test_health():
    """Test the health endpoint"""
    url = "http://localhost:5678/health"

    async with httpx.AsyncClient() as client:
        try:
            response = await client.get(url)
            print("Health Check Response:")
            print(json.dumps(response.json(), indent=2))
        except Exception as e:
            print(f"Health check failed: {e}")


async def main():
    """Main test function"""
    print("Testing Ops Incident Assistant")
    print("="*60)

    # Test health first
    await test_health()

    # Test webhook
    await test_webhook()


if __name__ == "__main__":
    asyncio.run(main())


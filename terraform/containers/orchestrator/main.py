"""
Orchestrator agent — single Gateway, policy-controlled access.

The user authenticates via Cognito hosted UI and gets a JWT.
The client app passes that JWT to the orchestrator.
The orchestrator forwards it to the Gateway.
The Policy Engine evaluates Cedar policies against the JWT claims.

The orchestrator never fetches tokens itself — it's a pure relay.
"""

import logging
import os
import sys

from strands import Agent
from strands.tools.mcp import MCPClient
from mcp.client.streamable_http import streamablehttp_client
from bedrock_agentcore.runtime import BedrockAgentCoreApp

logging.basicConfig(level=logging.INFO, stream=sys.stdout)
logger = logging.getLogger(__name__)

app = BedrockAgentCoreApp()

GATEWAY_URL = os.environ["GATEWAY_MCP_URL"]


@app.entrypoint
def handler(event, context):
    prompt = event.get("prompt", "")

    # The user's JWT — obtained by the client app via Cognito hosted UI login.
    # Contains claims like custom:role that Cedar policies evaluate.
    token = event.get("token")

    if not token:
        return {
            "response": "Authentication required. Please log in and provide your token.",
            "login_required": True,
        }

    # Single MCP client — forward the user's token to the Gateway.
    # The Policy Engine decides what this user can do.
    gateway_mcp = MCPClient(
        lambda: streamablehttp_client(
            url=GATEWAY_URL,
            headers={"Authorization": f"Bearer {token}"},
        )
    )

    with gateway_mcp:
        tools = gateway_mcp.list_tools()

        if not tools:
            return {"response": "No tools available for your account."}

        logger.info(f"Loaded {len(tools)} tools from Gateway")

        agent = Agent(
            tools=tools,
            system_prompt=(
                "You have access to GitHub tools (repos, issues, PRs) "
                "and StackHawk security tools (scanning, triage, config). "
                "Use the tools available to fulfill the user's request. "
                "If a tool call is denied by policy, explain that the user "
                "doesn't have permission for that action."
            ),
        )
        result = agent(prompt)
        return {"response": str(result)}


app.run()

"""
StackHawk MCP wrapper for AgentCore Runtime.

Adapts the StackHawk MCP server (stdio) to streamable-HTTP on port 8000.
Fetches the StackHawk API key from Secrets Manager at startup — the key
never appears in environment variables or Terraform state.

AgentCore Runtime MCP contract:
  - Port 8000, path /mcp, JSON-RPC
  - GET /ping -> {"status": "Healthy"}
  - Host 0.0.0.0, ARM64

Set ALLOWED_TOOLS to filter which tools are exposed, or None for all.
"""

import asyncio
import json
import logging
import os
import sys

import boto3
from mcp.server.fastmcp import FastMCP
from mcp.client.stdio import stdio_client, StdioServerParameters
from starlette.responses import JSONResponse

logging.basicConfig(level=logging.INFO, stream=sys.stdout)
logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Tool filtering: set to None for all tools, or a set of names to expose.
ALLOWED_TOOLS = None
# Example — triage-only:
# ALLOWED_TOOLS = {"get_organization_info", "list_applications", "get_app_findings_for_triage"}

STACKHAWK_SERVER_CMD = [sys.executable, "-m", "stackhawk_mcp.server"]

# ---------------------------------------------------------------------------
# Secrets Manager — fetch API key at startup
# ---------------------------------------------------------------------------

def fetch_api_key():
    """
    Read the StackHawk API key from Secrets Manager using the Runtime's
    IAM role. The secret ARN is passed as an env var; the actual key is not.
    """
    secret_arn = os.environ.get("STACKHAWK_API_KEY_SECRET_ARN")
    if not secret_arn:
        # Fallback: allow direct env var for local dev
        key = os.environ.get("STACKHAWK_API_KEY")
        if key:
            logger.info("Using STACKHAWK_API_KEY from environment (local dev mode)")
            return key
        raise RuntimeError(
            "Neither STACKHAWK_API_KEY_SECRET_ARN nor STACKHAWK_API_KEY is set"
        )

    logger.info(f"Fetching StackHawk API key from Secrets Manager: {secret_arn}")
    client = boto3.client("secretsmanager")
    response = client.get_secret_value(SecretId=secret_arn)
    secret = response["SecretString"]

    # Handle both plain string and JSON-wrapped secrets
    try:
        parsed = json.loads(secret)
        return parsed.get("STACKHAWK_API_KEY", secret)
    except (json.JSONDecodeError, TypeError):
        return secret


# ---------------------------------------------------------------------------
# Proxy MCP server
# ---------------------------------------------------------------------------

proxy = FastMCP("StackHawkMCP", stateless_http=True)


def make_forwarding_tool(tool_name: str, tool_description: str, server_env: dict):
    """Create a forwarding function for a single tool."""

    async def forwarded(**kwargs):
        server_params = StdioServerParameters(
            command=STACKHAWK_SERVER_CMD[0],
            args=STACKHAWK_SERVER_CMD[1:],
            env=server_env,
        )
        async with stdio_client(server_params) as (read_stream, write_stream):
            from mcp.client.session import ClientSession

            async with ClientSession(read_stream, write_stream) as session:
                await session.initialize()
                result = await session.call_tool(tool_name, kwargs)
                if result.content:
                    return "\n".join(
                        c.text for c in result.content if hasattr(c, "text")
                    )
                return "No output"

    forwarded.__name__ = tool_name
    forwarded.__doc__ = tool_description
    proxy.tool(name=tool_name, description=tool_description)(forwarded)
    logger.info(f"Registered tool: {tool_name}")


async def discover_and_register_tools(server_env: dict):
    """Connect to the real StackHawk MCP server, discover tools, register them."""
    logger.info("Discovering tools from StackHawk MCP server...")

    server_params = StdioServerParameters(
        command=STACKHAWK_SERVER_CMD[0],
        args=STACKHAWK_SERVER_CMD[1:],
        env=server_env,
    )

    async with stdio_client(server_params) as (read_stream, write_stream):
        from mcp.client.session import ClientSession

        async with ClientSession(read_stream, write_stream) as session:
            await session.initialize()
            tools_result = await session.list_tools()

            for tool in tools_result.tools:
                if ALLOWED_TOOLS is not None and tool.name not in ALLOWED_TOOLS:
                    logger.info(f"Skipping filtered tool: {tool.name}")
                    continue

                make_forwarding_tool(
                    tool_name=tool.name,
                    tool_description=tool.description or "",
                    server_env=server_env,
                )

    logger.info("Tool discovery complete.")


@proxy.custom_route("/ping", methods=["GET"])
async def ping(request):
    return JSONResponse({"status": "Healthy"})


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    # Fetch the API key from Secrets Manager (or env for local dev)
    api_key = fetch_api_key()

    # Build the env dict for the subprocess — inject the real key
    server_env = {**os.environ, "STACKHAWK_API_KEY": api_key}

    # Discover and register tools, then serve
    asyncio.run(discover_and_register_tools(server_env))
    proxy.run(transport="streamable-http", host="0.0.0.0", port=8000)

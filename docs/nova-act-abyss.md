# Amazon Nova Act — Integration Reference for Abyss

> Last updated: March 2026. Nova Act is under active development; always cross-reference with [nova.amazon.com/act](https://nova.amazon.com/act) and the [aws/nova-act](https://github.com/aws/nova-act) repo for the latest SDK version.

---

## Table of Contents

1. [What is Nova Act](#1-what-is-nova-act)
2. [How It Works — Architecture & Model](#2-how-it-works--architecture--model)
3. [Prerequisites](#3-prerequisites)
4. [Authentication](#4-authentication)
5. [Installation](#5-installation)
6. [Core API Reference](#6-core-api-reference)
7. [Prompting Best Practices](#7-prompting-best-practices)
8. [Structured Data Extraction](#8-structured-data-extraction)
9. [Authentication & Browser Sessions](#9-authentication--browser-sessions)
10. [Parallelism & Concurrency](#10-parallelism--concurrency)
11. [Human-in-the-Loop (HITL)](#11-human-in-the-loop-hitl)
12. [Tool Use & MCP Integration](#12-tool-use--mcp-integration)
13. [Debugging, Logging & Tracing](#13-debugging-logging--tracing)
14. [macOS Setup & Apple Containers](#14-macos-setup--apple-containers)
15. [Production Deployment to AWS](#15-production-deployment-to-aws)
16. [Integration in Abyss](#16-integration-in-abyss)
17. [Known Limitations & Gotchas](#17-known-limitations--gotchas)
18. [Benchmark Reference](#18-benchmark-reference)

---

## 1. What is Nova Act

Amazon Nova Act is a foundation model fine-tuned specifically for **agentic browser execution** — meaning it is purpose-built to perceive UI state and take reliable actions in a web browser, not just generate text about them. It was announced March 31, 2025, and transitioned to a production preview in July 2025.

The SDK (`nova-act`) is a **Python library** that wraps the model behind a clean `act()` API. Under the hood it manages a Playwright-controlled Chrome/Chromium instance, routes screenshots and DOM state to the Nova Act model, and streams back action sequences (click, type, scroll, etc.) that are executed in the browser.

### Why Nova Act over general-purpose LLMs

| Property | General LLM agents | Nova Act |
|---|---|---|
| Reliability target | 30–60% end-to-end | 90%+ on enterprise workflows |
| Designed abstraction | Single monolithic prompt | Decomposed `act()` calls |
| Browser control layer | Varies | Playwright (built-in) |
| Structured extraction | Prompt engineering | Native Pydantic schema support |
| Deployment path | DIY | AWS AgentCore + CloudWatch |
| Parallelism | Manual | `ThreadPoolExecutor` pattern |

Nova Act scores **94% on ScreenSpot Web Text** and **best-in-class on GroundUI Web**, outperforming Claude 3.7 Sonnet (90%) and OpenAI CUA (88%) on element-level actuation benchmarks.

---

## 2. How It Works — Architecture & Model

### 2.1 Model

Nova Act is powered by a fine-tuned **Nova 2 Lite** checkpoint — a compact multimodal model optimized for:

- **Pixel-accurate element grounding**: locating and clicking the correct UI element given a natural language description, even when element text is visually rendered (not in DOM text nodes)
- **Robust UI interactions**: date pickers, multi-step dropdowns, modal dialogs, popups — areas where general models frequently fail
- **Instruction following with hints**: structured prompts guide the model toward specific interaction choices ("do not accept the insurance upsell")

### 2.2 Execution loop

Each `act()` call runs this loop:

```
1. Capture browser screenshot + accessibility tree snapshot
2. Send (screenshot, a11y tree, prompt, conversation history) → Nova Act API
3. Model returns a structured action: {type: "click", target: <element>, ...}
4. Playwright executes the action in the live browser
5. Repeat until the model signals DONE or an error condition
```

The model does not receive the full DOM HTML — it works from visual perception and the accessibility tree, which is why it handles dynamic/JS-heavy UIs that break selector-based automation.

### 2.3 Session model

A `NovaAct` object maps 1:1 to a Chrome session. The session is stateful — cookies, local storage, and navigation history persist across `act()` calls within the same `with NovaAct(...)` block.

```
NovaAct context
  └── Chrome instance (Playwright)
       ├── act("step 1")   → model call → Playwright actions
       ├── act("step 2")   → model call → Playwright actions
       └── act("step 3")   → model call → Playwright actions
```

Sessions are independent across `NovaAct` instances, enabling parallelism via `ThreadPoolExecutor`.

---

## 3. Prerequisites

| Requirement | Version |
|---|---|
| Operating System | macOS Sierra+, Ubuntu 22.04+, WSL2, Windows 10+ |
| Python | 3.10+ |
| Browser | Google Chrome (recommended; Chromium fallback available) |
| SDK version | `nova-act >= 3.0` (older versions unsupported) |
| Language | English only (as of March 2026) |

> **Note**: Nova Act uses port **9222** (Chrome DevTools) and port **8765** (internal communication) by default. Both must be available.

---

## 4. Authentication

### 4.1 API Key (development / local)

1. Navigate to [nova.amazon.com/act](https://nova.amazon.com/act)
2. Sign in with your Amazon account (US region required)
3. Generate an API key
4. Export it:

```bash
export NOVA_ACT_API_KEY="your_api_key_here"
```

Or pass it directly to the constructor (less preferred):

```python
from nova_act import NovaAct

with NovaAct(
    starting_page="https://example.com",
    nova_act_api_key="your_api_key_here"
) as nova:
    nova.act("...")
```

### 4.2 IAM-based Authentication (production / AWS)

For production workflows deployed via the Nova Act AWS service, use IAM credentials. The SDK auto-discovers credentials from the environment using `boto3`'s default credential chain (env vars → `~/.aws/credentials` → instance role).

```bash
# Configure AWS credentials
aws configure
# or
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_DEFAULT_REGION=us-east-1
```

IAM auth is required when using the `Workflow` construct for production deployments. See [Section 15](#15-production-deployment-to-aws).

---

## 5. Installation

```bash
# Install from PyPI (always use latest — >=3.0 required)
pip install nova-act

# Upgrade existing install
pip install --upgrade nova-act

# Verify version
pip show nova-act

# Optional: install Google Chrome if not present
# (Nova Act works best with Chrome; Chromium fallback is auto-managed by Playwright)
```

On first run, Nova Act installs Playwright browser modules — expect a 1–2 minute delay. Subsequent runs initialize in seconds. To skip the Playwright install check:

```bash
export NOVA_ACT_SKIP_PLAYWRIGHT_INSTALL=1
```

### VS Code / Cursor / Kiro Extension

The [Nova Act IDE Extension](https://github.com/aws/nova-act-extension) provides:

- Chat-to-script generation via `@novaAct` Copilot participant
- Live browser debugging inside the IDE
- One-click AWS deployment from the Deploy tab
- Session replay and step-by-step testing

Install from [VS Code Marketplace](https://marketplace.visualstudio.com/items?itemName=AmazonWebServices.amazon-nova-act-extension) or search "Nova Act" in the extensions panel.

---

## 6. Core API Reference

### 6.1 `NovaAct` Constructor

```python
from nova_act import NovaAct

with NovaAct(
    starting_page="https://example.com",  # Required: initial URL
    headless=False,                        # True = no visible browser window
    quiet=False,                           # True = suppress console logs
    user_data_dir=None,                    # Path to Chrome profile dir for auth persistence
    clone_user_data_dir=True,              # Clone (and delete on exit) the profile dir
    nova_act_api_key=None,                 # API key; else reads NOVA_ACT_API_KEY env var
    logs_directory=None,                   # Directory for trace HTML files
    record_video=False,                    # Record MP4 of the session
    user_agent=None,                       # Custom user agent string
    # proxy=None,                          # Proxy configuration dict
) as nova:
    ...
```

> The `NovaAct` user agent includes `NovaAct` in the string by default. If you customize it, Amazon recommends retaining `NovaAct` in the string so website operators can identify agent traffic.

### 6.2 `nova.act(prompt, schema=None)`

The core method. Sends a natural-language instruction to the model and executes the resulting browser actions.

```python
# Basic action — no return value needed
nova.act("Click the 'Sign In' button")

# Action with structured return
from pydantic import BaseModel

class SearchResult(BaseModel):
    title: str
    url: str
    snippet: str

class SearchResults(BaseModel):
    results: list[SearchResult]

result = nova.act(
    "Return the top 5 search results currently visible on the page",
    schema=SearchResults.model_json_schema()
)

# result.parsed_response is a SearchResults instance
data = result.parsed_response
```

**Return value** (`ActResult`):

| Field | Description |
|---|---|
| `parsed_response` | Pydantic model populated if `schema` was provided |
| `response` | Raw string response from the model |
| `metadata` | Step count, timings, trace path |
| `success` | Boolean — did the model report completion |

### 6.3 Interactive mode (REPL)

Use a standard Python shell (not iPython):

```python
>>> from nova_act import NovaAct
>>> nova = NovaAct(starting_page="https://www.google.com")
>>> nova.start()
>>> nova.act("Search for 'voice IDE Python'")
>>> nova.act("Click the first result")
>>> nova.stop()
```

> `ctrl+x` exits the current `act()` loop and leaves the browser intact. `ctrl+c` kills the browser and requires a full restart.

---

## 7. Prompting Best Practices

Nova Act is most reliable when tasks are **decomposed into short, atomic `act()` calls** — each targeting fewer than 30 model steps. Think of it as writing step-by-step instructions for another person, not a single high-level goal.

### 7.1 Decomposition pattern

```python
# Bad — monolithic prompt
nova.act("Go to Amazon, find a coffee maker, add the best reviewed one to cart")

# Good — decomposed
nova.act("Search for 'coffee maker' in the search bar")
nova.act("Click the result with the highest customer review rating")
nova.act("Scroll until you see the 'Add to Cart' button, then click it")
```

### 7.2 Be explicit about choices

```python
# Include decision criteria directly in the prompt
nova.act(
    "Select the 2-day shipping option. "
    "Do not select the Prime upsell even if it appears."
)
```

### 7.3 Date handling

Always use absolute dates for calendar interactions:

```python
# Unreliable
nova.act("Select a date two weeks from now")

# Reliable
nova.act("Select April 10, 2026 from the date picker")
```

### 7.4 Closing popups and banners

Make popup dismissal an explicit first step before your main flow:

```python
nova.act("Close any cookie consent banners or promotional popups if present")
nova.act("Search for apartments in Pittsburgh, PA")
```

### 7.5 Specifying what to return

When extracting data, be explicit about format and scope:

```python
result = nova.act(
    "Return the price, name, and availability status of the currently visible product. "
    "If any field is not visible, return null for that field.",
    schema=Product.model_json_schema()
)
```

---

## 8. Structured Data Extraction

Use Pydantic models to extract structured information from the current browser state. Nova Act maps visible screen content to the schema fields — no DOM parsing required.

```python
from pydantic import BaseModel
from nova_act import NovaAct

class JobPosting(BaseModel):
    title: str
    company: str
    location: str
    salary: str | None
    posted_date: str

class JobListings(BaseModel):
    jobs: list[JobPosting]

with NovaAct(starting_page="https://linkedin.com/jobs") as nova:
    nova.act("Search for 'Machine Learning Engineer' jobs in Pittsburgh")
    nova.act("Filter by 'Past week' posting date")

    result = nova.act(
        "Return all job postings currently visible on the page",
        schema=JobListings.model_json_schema()
    )

    for job in result.parsed_response.jobs:
        print(f"{job.title} at {job.company} — {job.salary}")
```

---

## 9. Authentication & Browser Sessions

By default, Nova Act clones the Chromium profile into a temp directory and deletes it on exit. To persist a logged-in session:

```python
import os
from nova_act import NovaAct

USER_DATA_DIR = os.path.expanduser("~/.nova-act-profiles/my-app")
os.makedirs(USER_DATA_DIR, exist_ok=True)

# Step 1: Authenticate interactively once
with NovaAct(
    starting_page="https://target-site.com/login",
    user_data_dir=USER_DATA_DIR,
    clone_user_data_dir=False   # Don't clone — keep changes
) as nova:
    input("Log in manually in the browser, then press Enter...")

# Step 2: Reuse the authenticated session in subsequent runs
with NovaAct(
    starting_page="https://target-site.com/dashboard",
    user_data_dir=USER_DATA_DIR,
    clone_user_data_dir=False,
    headless=True               # Safe to run headless now
) as nova:
    nova.act("Navigate to the Orders section")
    result = nova.act("Return all orders from the last 7 days", schema=Orders.model_json_schema())
```

> For Abyss, this pattern is useful for browser-based tool calls that require the user to be logged in (e.g., accessing Gmail via browser, submitting calendar events through UI).

---

## 10. Parallelism & Concurrency

`ThreadPoolExecutor` is the recommended pattern. Each `NovaAct` instance gets its own browser session, so parallelism is embarrassingly simple:

```python
from concurrent.futures import ThreadPoolExecutor, as_completed
from nova_act import NovaAct, ActError
from pydantic import BaseModel

class PageSummary(BaseModel):
    url: str
    title: str
    main_topic: str

def summarize_page(url: str) -> PageSummary | None:
    try:
        with NovaAct(starting_page=url, headless=True) as nova:
            result = nova.act(
                "Return the page title and main topic of this page",
                schema=PageSummary.model_json_schema()
            )
            return result.parsed_response
    except ActError as e:
        print(f"Failed on {url}: {e}")
        return None

urls = [
    "https://arxiv.org/abs/2501.00001",
    "https://arxiv.org/abs/2501.00002",
    "https://arxiv.org/abs/2501.00003",
]

summaries = []
with ThreadPoolExecutor(max_workers=5) as executor:
    futures = {executor.submit(summarize_page, url): url for url in urls}
    for future in as_completed(futures):
        result = future.result()
        if result:
            summaries.append(result)
```

> Limit `max_workers` to avoid rate limiting on the Nova Act API. Start with 5–10 for development; monitor for `ActError` responses signaling throttling.

---

## 11. Human-in-the-Loop (HITL)

Nova Act supports pausing workflows for human input without breaking the session. This is critical for Abyss workflows where the user may need to approve or correct an action before it proceeds.

```python
from nova_act import NovaAct

def get_human_approval(message: str) -> bool:
    """Block until the human approves or rejects the pending action."""
    response = input(f"\n[HITL] {message}\nApprove? (y/n): ")
    return response.strip().lower() == "y"

with NovaAct(starting_page="https://example.com/checkout") as nova:
    nova.act("Add the item to the cart")
    nova.act("Proceed to checkout")
    nova.act("Fill in the shipping address with: 5000 Forbes Ave, Pittsburgh PA 15213")

    # Show the order summary to the user before placing
    summary = nova.act(
        "Return the order total, item names, and estimated delivery date",
        schema=OrderSummary.model_json_schema()
    )

    print(f"Order total: {summary.parsed_response.total}")

    if get_human_approval("Place this order?"):
        nova.act("Click the 'Place Order' button")
    else:
        print("Order cancelled.")
```

> For Abyss voice workflows, the HITL callback can be a voice confirmation prompt — "Say 'confirm' to place the order or 'cancel' to abort."

---

## 12. Tool Use & MCP Integration

Nova Act can invoke external Python functions and MCP servers as part of a workflow. This enables hybrid flows where Nova Act handles UI interactions and your own code handles API calls, data transformations, or model inference.

### 12.1 Python function as tool

```python
from nova_act import NovaAct
import requests

def get_flight_data(origin: str, destination: str, date: str) -> dict:
    """Tool that fetches flight availability from an external API."""
    response = requests.get(
        "https://api.flights.example.com/search",
        params={"from": origin, "to": destination, "date": date}
    )
    return response.json()

# Pass tools into the workflow context
with NovaAct(
    starting_page="https://flights.example.com",
    tools={"get_flight_data": get_flight_data}
) as nova:
    nova.act(
        "Use the get_flight_data tool to find flights from Boston to Pittsburgh on April 10, 2026. "
        "Then book the cheapest available option."
    )
```

### 12.2 MCP server integration (preview)

Nova Act supports remote MCP servers. This enables calling tools like Calendar, Gmail, Slack, or your own custom MCP endpoints directly within a Nova Act workflow.

```python
from nova_act import NovaAct

MCP_SERVER_URL = "https://your-mcp-server.example.com/sse"

with NovaAct(
    starting_page="https://example.com",
    mcp_servers=[{"type": "url", "url": MCP_SERVER_URL, "name": "my-tools"}]
) as nova:
    nova.act("Use the calendar tool to check availability on Friday and book a 1-hour slot")
```

### 12.3 Strands Agents integration

Nova Act can run as a **tool inside a Strands Agent** — letting an orchestrator LLM delegate browser tasks to Nova Act:

```python
from strands import Agent, tool
from nova_act import NovaAct

@tool
def browser_action(url: str, instruction: str) -> str:
    """Execute a browser action via Nova Act."""
    with NovaAct(starting_page=url, headless=True) as nova:
        result = nova.act(instruction)
        return result.response

agent = Agent(tools=[browser_action])
agent("Go to LinkedIn and find the current CTO of Shopify")
```

---

## 13. Debugging, Logging & Tracing

### 13.1 HTML trace files

Every `act()` call writes an HTML trace file showing a step-by-step screenshot replay. The path is printed to the console. Open in any browser:

```bash
open ~/.nova-act/traces/session_20260310_142300/act_001.html
```

Configure the output directory:

```python
with NovaAct(
    starting_page="https://example.com",
    logs_directory="./nova-traces"
) as nova:
    ...
```

### 13.2 Video recording

```python
with NovaAct(
    starting_page="https://example.com",
    record_video=True,
    logs_directory="./nova-recordings"
) as nova:
    nova.act("Complete the checkout flow")
# MP4 saved to logs_directory after context exits
```

### 13.3 Log verbosity

```bash
export NOVA_ACT_LOG_LEVEL=10   # DEBUG
export NOVA_ACT_LOG_LEVEL=20   # INFO (default)
export NOVA_ACT_LOG_LEVEL=30   # WARNING
```

### 13.4 Headless debugging

When running headless (CI/CD or server), use the IDE extension's **Live Debugging** panel to attach to a running headless session and observe it in real time.

Port conflicts on startup:

```
# Nova Act uses port 9222 (Chrome DevTools) and 8765 (internal)
# Check for conflicts:
lsof -i :9222
lsof -i :8765

# Kill blocking processes or configure alternate ports via constructor:
with NovaAct(starting_page="...", cdp_port=9333, ws_port=8766) as nova:
    ...
```

---

## 14. macOS Setup & Apple Containers

### 14.1 Running Nova Act on macOS

Nova Act runs natively on macOS (Sierra+), including Apple Silicon (M-series chips). Python 3.10+ is required.

```bash
# Recommended: use a virtual environment
python3 -m venv .venv
source .venv/bin/activate
pip install nova-act

# Install Google Chrome if not already installed
# brew install --cask google-chrome
```

The SDK detects Chrome automatically. If Chrome is not found, it falls back to Chromium managed by Playwright.

### 14.2 Apple Containers (macOS 26 / Tahoe)

At WWDC 2025, Apple announced native Linux container support via two new open-source projects:

- **Containerization** — a Swift framework providing the VM runtime layer
- **container** — a CLI tool for building, running, and managing OCI-compliant Linux containers

**Architecture**: each container runs inside its own lightweight virtual machine (not a shared VM like Docker's model), providing VM-level isolation per container with sub-second startup times. No port forwarding required — each container gets its own IP address.

**Why this matters for Nova Act in Abyss**: you can run Nova Act workflows inside an Apple Container (Linux/Ubuntu), giving you:

1. A clean, reproducible Ubuntu 22.04 environment for Nova Act
2. VM-level isolation between agent sessions
3. No Docker Desktop dependency on macOS 26+

**Install `container` CLI** (requires macOS 26 Tahoe):

```bash
# Download from: https://github.com/apple/container/releases
# Install the signed .pkg, then:
container --version
```

**Run Nova Act in an Apple Container**:

```bash
# Pull a base Ubuntu image
container pull ubuntu:22.04

# Run interactively
container run -it ubuntu:22.04 /bin/bash

# Inside the container:
apt update && apt install -y python3.11 python3-pip chromium-browser
pip install nova-act
export NOVA_ACT_API_KEY="your_key"
python3 your_workflow.py
```

**Dockerfile-compatible build** (Apple `container` supports Dockerfiles):

```dockerfile
FROM ubuntu:22.04

RUN apt-get update && apt-get install -y \
    python3.11 \
    python3-pip \
    chromium-browser \
    && rm -rf /var/lib/apt/lists/*

RUN pip install nova-act

ENV NOVA_ACT_API_KEY=""
ENV NOVA_ACT_SKIP_PLAYWRIGHT_INSTALL=1

COPY workflows/ /app/workflows/
WORKDIR /app

CMD ["python3", "workflows/main.py"]
```

```bash
container build -t nova-act-abyss .
container run \
    -e NOVA_ACT_API_KEY="$NOVA_ACT_API_KEY" \
    nova-act-abyss
```

**Limitations (macOS 26 beta, as of March 2026)**:

- `container` is supported on macOS 26 (Tahoe); limited functionality on macOS 15 Sequoia (no container-to-container networking)
- Nova Act GUI browser sessions (non-headless) require a display server inside the container; use `headless=True` for containerized workflows
- Cross-OS keyboard shortcuts behave differently — `agent_type()` using `ControlOrMeta+A` may not translate correctly between macOS host and Linux container

### 14.3 Alternative: Docker Desktop on macOS

For current stable macOS (Sequoia and earlier), Docker Desktop remains the recommended containerization approach:

```bash
# Install Docker Desktop: https://www.docker.com/products/docker-desktop/

# Build and run
docker build -t nova-act-abyss .
docker run \
    -e NOVA_ACT_API_KEY="$NOVA_ACT_API_KEY" \
    --shm-size=1g \
    nova-act-abyss
```

> `--shm-size=1g` is important — Chrome inside Docker requires sufficient shared memory or it crashes.

---

## 15. Production Deployment to AWS

### 15.1 Deployment path overview

```
Local script (API key auth)
  → Workflow decorator + IAM auth
    → nova-act CLI deploy
      → AWS AgentCore Runtime
        → CloudWatch monitoring
```

### 15.2 Workflow construct

```python
from nova_act import NovaAct
from nova_act.workflow import workflow, Workflow

# Option A: decorator-based
@workflow(name="abyss-browser-task")
def run_browser_task(url: str, instruction: str):
    with NovaAct(starting_page=url, headless=True) as nova:
        result = nova.act(instruction)
        return result.response

# Option B: context manager
def run_browser_task(url: str, instruction: str):
    workflow_def = Workflow(name="abyss-browser-task")
    with workflow_def:
        with NovaAct(starting_page=url, headless=True) as nova:
            result = nova.act(instruction)
            return result.response
```

### 15.3 AWS AgentCore Browser Tool

For high-scale production deployments, Nova Act integrates with the **Amazon Bedrock AgentCore Browser Tool** — a fully managed cloud-based browser that handles:

- VM-level session isolation
- Federated identity integration
- AWS CloudTrail logging + session replay
- Thousands of parallel workflow sessions

```python
from nova_act import NovaAct
from nova_act.agentcore import AgentCoreBrowserConfig

config = AgentCoreBrowserConfig(
    region="us-east-1",
    # Additional IAM and endpoint config
)

with NovaAct(
    starting_page="https://example.com",
    agentcore_browser=config,
    headless=True
) as nova:
    nova.act("Complete the task")
```

> **Important**: When the SDK runs on macOS and AgentCore Browser runs on Linux, OS-dependent keyboard shortcuts (`ControlOrMeta+A`, etc.) may not translate correctly. Use `nova.act()` natural language instructions for text selection/input rather than `agent_type()` keyboard shortcuts.

### 15.4 CDK deployment samples

AWS provides CDK templates for Lambda, ECS, and AgentCore deployments at [amazon-agi-labs/nova-act-samples](https://github.com/amazon-agi-labs/nova-act-samples):

```
nova-act-samples/
  cdk/
    lambda/     # Serverless single-execution workflows
    ecs/        # Long-running containerized workers
    agentcore/  # Production fleet management
```

---

## 16. Integration in Abyss

Abyss is a voice-first assistant for coding, email, calendar, and productivity. Nova Act unlocks a new class of capabilities: **browser-driven tool execution** triggered by voice commands.

### 16.1 Recommended architecture

```
User voice input
  → Whisper STT → NLU (intent + entities)
    → Route to Nova Act if browser action required
      → NovaAct.act(generated_prompt)
        → Browser task completes
          → Extract result (structured or text)
            → TTS response back to user
```

### 16.2 Voice-to-browser workflow

```python
from nova_act import NovaAct, ActError
from pydantic import BaseModel

class CalendarEvent(BaseModel):
    title: str
    date: str
    time: str
    duration_minutes: int

def book_calendar_event_via_browser(
    title: str,
    date: str,
    time: str,
    duration_minutes: int,
    user_profile_dir: str
) -> str:
    """Execute a calendar booking via browser control."""
    try:
        with NovaAct(
            starting_page="https://calendar.google.com",
            user_data_dir=user_profile_dir,
            clone_user_data_dir=False,
            headless=True
        ) as nova:
            nova.act("Close any welcome dialogs or notification prompts")
            nova.act(f"Create a new event titled '{title}'")
            nova.act(f"Set the date to {date}")
            nova.act(f"Set the start time to {time}")
            nova.act(f"Set the duration to {duration_minutes} minutes")
            nova.act("Save the event")
        return f"Event '{title}' booked for {date} at {time}."
    except ActError as e:
        return f"Browser action failed: {e}"
```

### 16.3 Email composition and send

```python
def send_email_via_browser(
    to: str,
    subject: str,
    body: str,
    user_profile_dir: str
) -> str:
    with NovaAct(
        starting_page="https://mail.google.com",
        user_data_dir=user_profile_dir,
        clone_user_data_dir=False,
        headless=True
    ) as nova:
        nova.act("Click the 'Compose' button")
        nova.act(f"Enter '{to}' in the To field")
        nova.act(f"Enter '{subject}' in the Subject field")
        nova.act(f"Type the following in the message body: {body}")
        nova.act("Click the 'Send' button")
    return "Email sent."
```

### 16.4 HITL voice confirmation

```python
def voice_confirm(prompt: str, tts_fn, stt_fn) -> bool:
    """Ask user for voice confirmation before executing a browser action."""
    tts_fn(f"{prompt}. Say confirm to proceed or cancel to abort.")
    response = stt_fn(timeout=10).lower()
    return "confirm" in response

# Usage in a workflow
if voice_confirm(f"I'll book a 1-hour meeting on Friday at 2pm.", tts, stt):
    book_calendar_event_via_browser(...)
else:
    tts("Cancelled.")
```

### 16.5 Headless mode for background tasks

For scheduled or background Abyss tasks (e.g., "order lunch every Tuesday"), always run headless:

```python
import schedule
import time

def weekly_lunch_order():
    with NovaAct(
        starting_page="https://sweetgreen.com",
        user_data_dir="~/.nova-profiles/sweetgreen",
        clone_user_data_dir=False,
        headless=True
    ) as nova:
        nova.act("Find my saved 'Tuesday Salad' order and reorder it")
        nova.act("Select the earliest available delivery slot")
        nova.act("Confirm and place the order")

schedule.every().tuesday.at("11:30").do(weekly_lunch_order)
while True:
    schedule.run_pending()
    time.sleep(60)
```

---

## 17. Known Limitations & Gotchas

1. **No iPython support**: use the standard `python` REPL, not Jupyter or iPython.
2. **Max ~30 steps per `act()` call**: beyond this, reliability degrades. Break long tasks into multiple calls.
3. **Captchas**: Nova Act cannot solve captchas. Use a persistent authenticated session (`user_data_dir`) to avoid captcha triggers where possible.
4. **English only**: Nova Act model supports English instructions only (as of March 2026).
5. **US account required**: API key access requires a US Amazon account.
6. **Cross-OS keyboard shortcuts**: running the SDK on macOS with AgentCore Browser on Linux causes `ControlOrMeta+A` and similar shortcuts to behave differently. Prefer natural language instructions for text operations.
7. **Port conflicts**: ports 9222 and 8765 must be free. Check with `lsof -i :9222`.
8. **Headless + Google services**: Google aggressively detects headless Chrome and may present additional verification. Use authenticated `user_data_dir` sessions and add realistic delays between actions.
9. **Rate limiting**: the Nova Act API is rate-limited. Excessive parallel sessions (>10) may trigger `ActError`. Back off and retry.
10. **SDK version**: versions older than 3.0 are unsupported. Always pin to a recent version in `requirements.txt`.

---

## 18. Benchmark Reference

| Benchmark | Nova Act | OpenAI CUA | Claude 3.7 Sonnet |
|---|---|---|---|
| ScreenSpot Web Text | **94%** | 88% | 90% |
| GroundUI Web | **Best-in-class*** | — | — |
| Internal date picking | **>90%** | — | — |
| Internal dropdown | **>90%** | — | — |
| Enterprise workflow end-to-end | **90%+** | — | — |

*Benchmarked by Amazon's team. GroundUI Web scores for competitors not publicly disclosed.

---

## References

- [Nova Act homepage](https://nova.amazon.com/act)
- [aws/nova-act GitHub](https://github.com/aws/nova-act)
- [Nova Act extension (VS Code / Cursor / Kiro)](https://github.com/aws/nova-act-extension)
- [nova-act-samples (CDK + examples)](https://github.com/amazon-agi-labs/nova-act-samples)
- [AWS Nova Act service page](https://aws.amazon.com/nova/act/)
- [Nova Act User Guide (AWS docs)](https://docs.aws.amazon.com/nova-act/latest/userguide/)
- [Amazon Bedrock AgentCore Browser Tool](https://aws.amazon.com/blogs/machine-learning/amazon-nova-act-sdk-preview-path-to-production-for-browser-automation-agents/)
- [apple/container CLI (macOS 26)](https://github.com/apple/container)
- [Apple Containerization framework (WWDC 2025)](https://developer.apple.com/videos/play/wwdc2025/346/)

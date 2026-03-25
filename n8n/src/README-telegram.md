
# AI Order-to-Cash — Telegram Bot Workflow

## Overview

This workflow connects a Telegram bot to the order-to-cash pipeline. Customers send their order in natural language via Telegram and receive a formatted invoice reply with payment confirmation — all without leaving the chat.

**Workflow file:** `workflow-telegram.json`
**Trigger:** Telegram Bot (long polling via n8n Telegram Trigger node)
**FastAPI backend:** `http://localhost:8000`

---

## Architecture

```
Customer sends Telegram message
        |
        v
[Telegram Trigger] — native n8n node, listens for messages
        |
        v
[Parse Telegram Message] — JS code
        |  extracts text, name, chat_id from Telegram payload
        v
[Send Acknowledgement] — "⏳ Processing your order..."
        |
        v
[Extract Order] → POST localhost:8000/extract-order
        |          Bedrock AI parses natural language into items
        v
[Check Inventory] → POST localhost:8000/check-inventory
        |            Checks stock levels and prices
        v
[Build Invoice] — JS code node
        |          Calculates totals, generates invoice number
        v
[Can Fulfill?] — IF node
       /  \
     YES   NO
      |     |
      v     v
[Process    [Format Out of Stock Message]
 Payment]         |
      |           v
      v     [Send Out of Stock Reply] → Telegram
[Fulfill
 Order]
      |
      v
[Format Success Message] — JS code
      |
      v
[Send Success Reply] → Telegram
```

---

## Node Reference

| # | Node | Type | Purpose |
|---|------|------|---------|
| 1 | Telegram Trigger | Telegram Trigger | Listens for incoming messages via bot token |
| 2 | Parse Telegram Message | Code (JS) | Extracts `customer_message`, `customer_name`, `phone_number` (Telegram user ID), `chat_id` |
| 3 | Send Acknowledgement | Telegram | Immediately replies `⏳ Processing your order...` so customer knows it's working |
| 4 | Extract Order | HTTP Request | Calls FastAPI `/extract-order` — AI parses message into `[{product, quantity}]` |
| 5 | Check Inventory | HTTP Request | Calls FastAPI `/check-inventory` — returns prices, availability, remaining stock |
| 6 | Build Invoice | Code (JS) | Calculates line totals, total amount in KES, generates `INV-{timestamp}` |
| 7 | Can Fulfill? | IF | Branches on whether all items are available |
| 8 | Process Payment | HTTP Request | Calls FastAPI `/process-payment` — simulates M-Pesa STK push |
| 9 | Fulfill Order | HTTP Request | Calls FastAPI `/fulfill-order` — deducts stock |
| 10 | Format Success Message | Code (JS) | Builds Markdown-formatted success message |
| 11 | Send Success Reply | Telegram | Sends formatted invoice to customer's chat |
| 12 | Format Out of Stock Message | Code (JS) | Builds Markdown-formatted out-of-stock message |
| 13 | Send Out of Stock Reply | Telegram | Notifies customer which items are unavailable |

---

## Customer Journey

### Happy Path (all items in stock)

1. Customer opens Telegram, finds the bot, sends a message:
   ```
   Nipee 2 rice na 3 cooking oil
   ```
2. **Telegram Trigger** fires, passes the raw Telegram payload to the workflow
3. **Parse Telegram Message** extracts:
   - `customer_message`: `"Nipee 2 rice na 3 cooking oil"`
   - `customer_name`: Telegram display name (e.g. `"John Doe"`)
   - `chat_id`: Telegram chat ID (used to send replies back)
4. **Send Acknowledgement** immediately sends `⏳ Processing your order, please wait...` to the customer
5. **Extract Order** sends the message to Bedrock AI — returns `[{product: "rice", quantity: 2}, {product: "cooking oil", quantity: 3}]`
6. **Check Inventory** validates stock — rice: 50 available ✅, cooking oil: 30 available ✅
7. **Build Invoice** computes totals:
   - rice × 2 @ KES 150 = KES 300
   - cooking oil × 3 @ KES 200 = KES 600
   - Total: KES 900
8. **Can Fulfill?** → true (all available)
9. **Process Payment** simulates M-Pesa — returns `status: success`, ref `MPX1A2B3C4D`
10. **Fulfill Order** deducts stock — rice: 48 remaining, cooking oil: 27 remaining
11. **Format Success Message** builds Markdown reply
12. **Send Success Reply** delivers to customer:

```
✅ Order Confirmed!

👤 Customer: John Doe
🧾 Invoice: INV-1716000000000

Order Items:
  • rice x2 @ KES 150 = KES 300
  • cooking oil x3 @ KES 200 = KES 600

💰 Total: KES 900

📱 Payment: SUCCESS
🔖 Ref: MPX1A2B3C4D

Thank you for your order! We will deliver shortly. 🙏
```

### Sad Path (item out of stock)

1–7. Same as above
8. **Can Fulfill?** → false (one or more items unavailable)
9. **Format Out of Stock Message** builds reply listing unavailable items
10. **Send Out of Stock Reply** delivers to customer:

```
❌ Some items are out of stock

Unavailable:
  • cooking oil: Only 2 units available, 3 requested

Available items:
  • rice x2 = KES 300

Please update your order and try again.
```

### Non-text message (image, voice, etc.)

- **Parse Telegram Message** returns empty — workflow stops silently (no reply sent for non-text)

---

## Setup

### Prerequisites
- n8n running on EC2 (port 5678 open in security group)
- FastAPI (`bedrock_rapper.py`) running on EC2 port 8000
- AWS Bedrock access granted to the EC2 IAM role

### Step 1 — Create the Telegram Bot
1. Open Telegram → search `@BotFather`
2. Send `/newbot`
3. Enter a bot name and username (must end in `bot`)
4. Copy the **bot token**

### Step 2 — Add Credentials in n8n
1. n8n → Credentials → Add Credential → **Telegram API**
2. Name: `Telegram Bot`
3. Access Token: paste bot token
4. Save

### Step 3 — Import Workflow
1. n8n → Workflows → Add Workflow → Import from file
2. Select `workflow-telegram.json`

### Step 4 — Activate
Toggle the **Active** switch on in the workflow editor.

### Step 5 — Test
Open your bot on Telegram and send:
```
Nipee 2 rice na 3 cooking oil
```

---

## FastAPI Endpoints Used

| Endpoint | Method | Input | Output |
|----------|--------|-------|--------|
| `/extract-order` | POST | `{ message: string }` | `{ items: [{product, quantity}] }` |
| `/check-inventory` | POST | `{ items: [{product, quantity}] }` | `{ inventory_results: [...] }` |
| `/process-payment` | POST | `{ phone_number, amount, invoice_number }` | `{ status, payment_reference }` |
| `/fulfill-order` | POST | `{ invoice_number, items, customer_name }` | `{ status, fulfilled_items }` |

---

## Telegram Payload Reference

The Telegram Trigger provides this structure — key fields used by the workflow:

```json
{
  "message": {
    "text": "Nipee 2 rice na 3 cooking oil",
    "chat": { "id": 123456789 },
    "from": {
      "id": 123456789,
      "first_name": "John",
      "last_name": "Doe"
    }
  }
}
```

---

## Mock Inventory

| Product | Unit Price (KES) | Initial Stock |
|---------|-----------------|---------------|
| rice | 150 | 50 |
| cooking oil | 200 | 30 |
| unga | 120 | 40 |
| sugar | 180 | 25 |
| salt | 50 | 100 |
| milk | 60 | 20 |
| bread | 65 | 15 |
| flour | 130 | 35 |

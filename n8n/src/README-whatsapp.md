# AI Order-to-Cash — WhatsApp Workflow

## Overview

This workflow connects WhatsApp Business Cloud (Meta) to the order-to-cash pipeline. Customers send their order in natural language via WhatsApp and receive a structured reply with invoice and payment confirmation.

**Workflow file:** `workflow-whatsapp.json`
**Trigger:** WhatsApp Cloud API webhook (Meta Graph API)
**FastAPI backend:** `http://localhost:8000`
**Environment variable required:** `WHATSAPP_TOKEN`

---

## Architecture

```
Customer sends WhatsApp message
        |
        v
Meta Cloud API → POST /whatsapp-webhook (n8n)
        |
        v
[WhatsApp Incoming] — POST webhook node
        |
        v
[Parse WhatsApp Message] — JS code
        |  extracts text, name, phone_number, phone_number_id
        v
[Is Text Order?] — IF node
       /  \
    YES    NO (image, audio, etc.)
     |      |
     v      v
     |   [Send Format Hint] → WhatsApp
     |      "Please type your order as text..."
     v
[Extract Order] → POST localhost:8000/extract-order
     |             Bedrock AI parses natural language
     v
[Check Inventory] → POST localhost:8000/check-inventory
     |
     v
[Build Invoice] — JS code
     |
     v
[Can Fulfill?] — IF node
    /  \
  YES   NO
   |     |
   v     v
[Process  [Format Out of Stock Message]
 Payment]        |
   |             v
   v        [Send Out of Stock Reply] → WhatsApp Graph API
[Fulfill
  Order]
   |
   v
[Format Success Message] — JS code
   |
   v
[Send Success Reply] → WhatsApp Graph API

--- (separate branch, same path) ---

GET /whatsapp-webhook
[WhatsApp Verify] → [Return Challenge]
(Meta webhook verification handshake)
```

---

## Node Reference

| # | Node | Type | Purpose |
|---|------|------|---------|
| V1 | WhatsApp Verify | Webhook (GET) | Handles Meta's one-time webhook verification challenge |
| V2 | Return Challenge | Respond to Webhook | Echoes back `hub.challenge` to complete verification |
| 1 | WhatsApp Incoming | Webhook (POST) | Receives all incoming WhatsApp events |
| 2 | Parse WhatsApp Message | Code (JS) | Validates event type, extracts message text, sender name, phone number, phone_number_id |
| 3 | Is Text Order? | IF | Skips non-text messages (images, voice notes, etc.) |
| 4 | Send Format Hint | HTTP Request | Sends guidance reply to customers who send non-text |
| 5 | Extract Order | HTTP Request | Calls FastAPI `/extract-order` — AI parses message into items |
| 6 | Check Inventory | HTTP Request | Calls FastAPI `/check-inventory` — prices and stock levels |
| 7 | Build Invoice | Code (JS) | Calculates totals, generates invoice number, carries `phone_number_id` |
| 8 | Can Fulfill? | IF | Branches on stock availability |
| 9 | Process Payment | HTTP Request | Calls FastAPI `/process-payment` — simulates M-Pesa |
| 10 | Fulfill Order | HTTP Request | Calls FastAPI `/fulfill-order` — deducts stock |
| 11 | Format Success Message | Code (JS) | Builds WhatsApp-formatted success message |
| 12 | Send Success Reply | HTTP Request | POSTs to `graph.facebook.com/v18.0/{phone_number_id}/messages` |
| 13 | Format Out of Stock Message | Code (JS) | Builds out-of-stock message |
| 14 | Send Out of Stock Reply | HTTP Request | POSTs to WhatsApp Graph API |

---

## Customer Journey

### Happy Path (all items in stock)

1. Customer sends a WhatsApp message to your business number:
   ```
   Nipee 2 rice na 3 cooking oil
   ```
2. Meta Cloud API delivers the event to `POST /whatsapp-webhook`
3. **Parse WhatsApp Message** extracts from the nested Meta payload:
   - `customer_message`: `"Nipee 2 rice na 3 cooking oil"`
   - `customer_name`: WhatsApp display name (e.g. `"John Doe"`)
   - `phone_number`: `"254712345678"` (sender's WhatsApp number)
   - `phone_number_id`: Meta's phone number ID (needed to send reply)
4. **Is Text Order?** → yes → proceeds to pipeline
5. **Extract Order** → Bedrock AI returns `[{product: "rice", quantity: 2}, {product: "cooking oil", quantity: 3}]`
6. **Check Inventory** → rice: ✅ KES 150, cooking oil: ✅ KES 200
7. **Build Invoice** → KES 900 total, invoice `INV-1716000000000`
8. **Can Fulfill?** → true
9. **Process Payment** → `status: success`, ref `MPX1A2B3C4D`
10. **Fulfill Order** → stock deducted
11. **Format Success Message** builds reply text
12. **Send Success Reply** calls Graph API — customer receives on WhatsApp:

```
✅ Order Confirmed!

👤 Customer: John Doe
🧾 Invoice: INV-1716000000000

Items:
  • rice x2 = KES 300
  • cooking oil x3 = KES 600

💰 Total: KES 900

📱 Payment: SUCCESS
🔖 Ref: MPX1A2B3C4D

Thank you for your order! 🙏
```

### Sad Path (item out of stock)

1–7. Same as above
8. **Can Fulfill?** → false
9. **Format Out of Stock Message** builds reply
10. **Send Out of Stock Reply** → customer receives:

```
❌ Some items are unavailable

🧾 Invoice: INV-1716000000000

Out of stock:
  • cooking oil: Only 2 units available, 3 requested

Please update your order and try again.
```

### Non-text message (image, voice, sticker)

1. **Parse WhatsApp Message** detects `msg.type !== 'text'`
2. Sets `skip: true` with a hint reply
3. **Is Text Order?** → false branch
4. **Send Format Hint** → customer receives:
   ```
   Sorry, I only understand text messages. Please type your order, e.g: "Nipee 2 rice na 3 cooking oil"
   ```

### Webhook Verification (one-time Meta setup)

When you first register the webhook URL in Meta Developer Console:
1. Meta sends `GET /whatsapp-webhook?hub.mode=subscribe&hub.verify_token=...&hub.challenge=...`
2. **WhatsApp Verify** node catches the GET request
3. **Return Challenge** responds with the `hub.challenge` value
4. Meta confirms the webhook and starts delivering events

---

## Setup

### Prerequisites
- n8n running on EC2 (port 5678 open)
- FastAPI running on EC2 port 8000
- Meta Developer account with a WhatsApp Business app
- `WHATSAPP_TOKEN` environment variable set in n8n

### Step 1 — Meta Developer Setup
1. Go to [developers.facebook.com](https://developers.facebook.com)
2. Create App → **Business** type
3. Add **WhatsApp** product
4. Under WhatsApp → API Setup, note:
   - **Phone Number ID**
   - **WhatsApp Business Account ID**
5. Generate a **Permanent Access Token** via System User (recommended) or use the temporary token for testing

### Step 2 — Set WHATSAPP_TOKEN in n8n
Add to your EC2 environment or docker-compose:
```bash
WHATSAPP_TOKEN=your_meta_permanent_access_token
```
Restart n8n after adding.

### Step 3 — Import Workflow
1. n8n → Workflows → Add Workflow → Import from file
2. Select `workflow-whatsapp.json`
3. Activate the workflow

### Step 4 — Register Webhook with Meta
1. Meta Developer Console → WhatsApp → Configuration → Webhooks
2. **Callback URL:** `http://<EC2_IP>:5678/webhook/whatsapp-webhook`
3. **Verify Token:** any string you choose (only used for verification — not stored in the workflow)
4. Click **Verify and Save**
5. Subscribe to the **messages** field

### Step 5 — Test
Send a WhatsApp message to your registered business number:
```
Nipee 2 rice na 3 cooking oil
```

---

## Environment Variables

| Variable | Description |
|----------|-------------|
| `WHATSAPP_TOKEN` | Meta permanent access token for sending messages via Graph API |

---

## FastAPI Endpoints Used

| Endpoint | Method | Input | Output |
|----------|--------|-------|--------|
| `/extract-order` | POST | `{ message: string }` | `{ items: [{product, quantity}] }` |
| `/check-inventory` | POST | `{ items: [{product, quantity}] }` | `{ inventory_results: [...] }` |
| `/process-payment` | POST | `{ phone_number, amount, invoice_number }` | `{ status, payment_reference }` |
| `/fulfill-order` | POST | `{ invoice_number, items, customer_name }` | `{ status, fulfilled_items }` |

---

## WhatsApp Payload Reference

Meta delivers this structure to the webhook. Key fields used by the workflow:

```json
{
  "object": "whatsapp_business_account",
  "entry": [{
    "changes": [{
      "value": {
        "metadata": {
          "phone_number_id": "123456789"
        },
        "contacts": [{
          "profile": { "name": "John Doe" },
          "wa_id": "254712345678"
        }],
        "messages": [{
          "from": "254712345678",
          "type": "text",
          "text": { "body": "Nipee 2 rice na 3 cooking oil" }
        }]
      }
    }]
  }]
}
```

---

## Comparison with Telegram Workflow

| | WhatsApp | Telegram |
|--|----------|----------|
| Setup complexity | High (Meta business verification) | Low (BotFather, 2 min) |
| Token management | Expires, needs system user | Never expires |
| Sending replies | Manual Graph API HTTP request | Native n8n Telegram node |
| Webhook verification | Required (GET challenge) | Not required |
| Cost | Free tier, then pay-per-message | Free |
| Best for | Production with existing WhatsApp customers | Quick demos and testing |

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

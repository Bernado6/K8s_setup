# AI Order-to-Cash — Webhook (cURL / API) Workflow

## Overview

This is the base workflow triggered by a direct HTTP POST request. It is used for testing, system integrations, and any client that can make HTTP calls (mobile apps, POS systems, other services).

**Workflow file:** `workflow-telegram.json` (original base workflow)
**Trigger:** `POST http://<EC2_IP>:5678/webhook/ai-order-demo`
**FastAPI backend:** `http://localhost:8000`

---

## Architecture

```
HTTP Client (curl / app)
        |
        v
[Webhook] POST /ai-order-demo
        |
        v
[Set Input] — extract message, customer_name, phone_number from body
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
[Process    [Out of Stock
 Payment]    Response]
      |
      v
[Fulfill Order] → POST localhost:8000/fulfill-order
      |            Deducts stock
      v
[Success Response] — JSON back to HTTP client
```

---

## Node Reference

| # | Node | Type | Purpose |
|---|------|------|---------|
| 1 | Webhook | Webhook | Receives POST request, exposes `/ai-order-demo` |
| 2 | Set Input | Set | Normalises `message`, `customer_name`, `phone_number` from request body |
| 3 | Extract Order | HTTP Request | Calls FastAPI `/extract-order` — AI parses message into `[{product, quantity}]` |
| 4 | Check Inventory | HTTP Request | Calls FastAPI `/check-inventory` — returns prices, availability, remaining stock |
| 5 | Build Invoice | Code (JS) | Calculates line totals, total amount, generates `INV-{timestamp}` invoice number |
| 6 | Can Fulfill? | IF | Branches on whether all items are in stock |
| 7 | Process Payment | HTTP Request | Calls FastAPI `/process-payment` — simulates M-Pesa STK push |
| 8 | Fulfill Order | HTTP Request | Calls FastAPI `/fulfill-order` — deducts stock, confirms order |
| 9 | Success Response | Respond to Webhook | Returns full order JSON to caller |
| 10 | Out of Stock Response | Respond to Webhook | Returns which items are unavailable |

---

## Customer Journey

### Happy Path (all items in stock)

1. Client sends POST with customer message in natural language
2. **Set Input** extracts and normalises the three required fields
3. **Extract Order** sends the message to Bedrock AI — returns structured items e.g. `[{product: "rice", quantity: 2}]`
4. **Check Inventory** validates each item against the mock store — returns unit price, availability, remaining stock
5. **Build Invoice** computes line totals, overall total in KES, assigns invoice number
6. **Can Fulfill?** evaluates — all items available → true branch
7. **Process Payment** simulates M-Pesa payment — returns `status: success` and a reference like `MPX1A2B3C4D`
8. **Fulfill Order** deducts quantities from in-memory inventory
9. **Success Response** returns JSON to the caller:

```json
{
  "success": true,
  "customer_name": "John Doe",
  "invoice_number": "INV-1716000000000",
  "total_amount": 900,
  "currency": "KES",
  "payment_status": "success",
  "payment_reference": "MPX1A2B3C4D",
  "fulfillment_status": "fulfilled",
  "items": [
    { "product": "rice", "quantity": 2, "unit_price": 150, "line_total": 300, "available": true },
    { "product": "cooking oil", "quantity": 3, "unit_price": 200, "line_total": 600, "available": true }
  ]
}
```

### Sad Path (item out of stock)

1–5. Same as above
6. **Can Fulfill?** evaluates — one or more items unavailable → false branch
7. **Out of Stock Response** returns immediately:

```json
{
  "success": false,
  "message": "Some items are out of stock",
  "invoice_number": "INV-1716000000000",
  "total_amount": 900,
  "currency": "KES",
  "items": [
    { "product": "cooking oil", "available": false, "reason": "Only 2 units available, 3 requested" }
  ]
}
```

---

## Setup

### Prerequisites
- n8n running on EC2 (port 5678)
- FastAPI (`bedrock_rapper.py`) running on EC2 (port 8000)
- AWS Bedrock access with `eu.anthropic.claude-3-5-sonnet-20240620-v1:0`

### Import
1. n8n → Workflows → Add Workflow → Import from file
2. Select the workflow JSON file
3. Activate the workflow

### Test
```bash
curl -X POST "http://<EC2_IP>:5678/webhook/ai-order-demo" \
  -H "Content-Type: application/json" \
  -d '{
    "message": "Nipee 2 rice na 3 cooking oil",
    "customer_name": "John Doe",
    "phone_number": "254712345678"
  }'
```

---

## FastAPI Endpoints Used

| Endpoint | Method | Input | Output |
|----------|--------|-------|--------|
| `/extract-order` | POST | `{ message: string }` | `{ items: [{product, quantity}] }` |
| `/check-inventory` | POST | `{ items: [{product, quantity}] }` | `{ inventory_results: [{product, quantity, unit_price, available, remaining_stock, reason}] }` |
| `/process-payment` | POST | `{ phone_number, amount, invoice_number }` | `{ status, payment_reference, ... }` |
| `/fulfill-order` | POST | `{ invoice_number, items, customer_name }` | `{ status, fulfilled_items, ... }` |

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

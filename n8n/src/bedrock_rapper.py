from fastapi import FastAPI
from pydantic import BaseModel
from typing import List
import boto3
import json
import uuid

app = FastAPI()

client = boto3.client("bedrock-runtime", region_name="eu-west-1")

MODEL_ID = "eu.anthropic.claude-3-5-sonnet-20240620-v1:0"

# ---------- Mock inventory store ----------
INVENTORY = {
    "rice":        {"unit_price": 150, "stock": 50},
    "cooking oil": {"unit_price": 200, "stock": 30},
    "unga":        {"unit_price": 120, "stock": 40},
    "sugar":       {"unit_price": 180, "stock": 25},
    "salt":        {"unit_price": 50,  "stock": 100},
    "milk":        {"unit_price": 60,  "stock": 20},
    "bread":       {"unit_price": 65,  "stock": 15},
    "flour":       {"unit_price": 130, "stock": 35},
}


# ---------- Request models ----------

class ChatRequest(BaseModel):
    prompt: str
    system: str = "You are a helpful AI agent for African businesses."


class ExtractOrderRequest(BaseModel):
    message: str


class OrderItem(BaseModel):
    product: str
    quantity: int


class CheckInventoryRequest(BaseModel):
    items: List[OrderItem]


class ProcessPaymentRequest(BaseModel):
    phone_number: str
    amount: float
    invoice_number: str


class FulfillItem(BaseModel):
    product: str
    quantity: int
    unit_price: float
    line_total: float
    available: bool
    remaining_stock: int
    reason: str = ""


class FulfillOrderRequest(BaseModel):
    invoice_number: str
    items: List[FulfillItem]
    customer_name: str


# ---------- Helpers ----------

def bedrock_chat(prompt: str, system: str) -> str:
    response = client.converse(
        modelId=MODEL_ID,
        system=[{"text": system}],
        messages=[{"role": "user", "content": [{"text": prompt}]}],
        inferenceConfig={"maxTokens": 500, "temperature": 0.2},
    )
    return response["output"]["message"]["content"][0]["text"]


# ---------- Endpoints ----------

@app.post("/chat")
def chat(req: ChatRequest):
    return {"response": bedrock_chat(req.prompt, req.system)}


@app.post("/extract-order")
def extract_order(req: ExtractOrderRequest):
    """
    Use Bedrock to parse a natural-language order message into
    a structured list of { product, quantity } items.
    """
    system = (
        "You are an order parsing AI for an African grocery/FMCG business. "
        "Extract ordered items from the customer message. "
        "Return ONLY valid JSON in this exact format, no explanation:\n"
        '{"items": [{"product": "<product name lowercase>", "quantity": <integer>}]}'
    )
    raw = bedrock_chat(req.message, system)

    # Strip markdown fences if present
    cleaned = raw.strip()
    if cleaned.startswith("```"):
        cleaned = cleaned.split("```")[1]
        if cleaned.startswith("json"):
            cleaned = cleaned[4:]
    cleaned = cleaned.strip()

    parsed = json.loads(cleaned)
    return parsed   # { items: [...] }


@app.post("/check-inventory")
def check_inventory(req: CheckInventoryRequest):
    """
    Check each requested item against the mock inventory store.
    Returns availability, unit price, and remaining stock.
    """
    results = []
    for item in req.items:
        key = item.product.lower().strip()
        inv = INVENTORY.get(key)

        if inv is None:
            results.append({
                "product": item.product,
                "quantity": item.quantity,
                "unit_price": 0,
                "available": False,
                "remaining_stock": 0,
                "reason": f"Product '{item.product}' not found in inventory",
            })
        elif inv["stock"] < item.quantity:
            results.append({
                "product": item.product,
                "quantity": item.quantity,
                "unit_price": inv["unit_price"],
                "available": False,
                "remaining_stock": inv["stock"],
                "reason": f"Only {inv['stock']} units available, {item.quantity} requested",
            })
        else:
            results.append({
                "product": item.product,
                "quantity": item.quantity,
                "unit_price": inv["unit_price"],
                "available": True,
                "remaining_stock": inv["stock"],
                "reason": "",
            })

    return {"inventory_results": results}


@app.post("/process-payment")
def process_payment(req: ProcessPaymentRequest):
    """
    Simulate an M-Pesa STK push / payment processing.
    In production replace this with a real Daraja API call.
    """
    # Simulate successful payment
    payment_reference = f"MPX{uuid.uuid4().hex[:8].upper()}"
    return {
        "status": "success",
        "payment_reference": payment_reference,
        "phone_number": req.phone_number,
        "amount": req.amount,
        "invoice_number": req.invoice_number,
        "message": f"Payment of KES {req.amount} received from {req.phone_number}",
    }


@app.post("/fulfill-order")
def fulfill_order(req: FulfillOrderRequest):
    """
    Deduct fulfilled items from the in-memory inventory and confirm the order.
    """
    fulfilled = []
    for item in req.items:
        if item.available:
            key = item.product.lower().strip()
            if key in INVENTORY:
                INVENTORY[key]["stock"] -= item.quantity
            fulfilled.append(item.product)

    return {
        "status": "fulfilled",
        "invoice_number": req.invoice_number,
        "customer_name": req.customer_name,
        "fulfilled_items": fulfilled,
        "message": f"Order {req.invoice_number} fulfilled successfully for {req.customer_name}",
    }

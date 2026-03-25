import boto3

client = boto3.client("bedrock-runtime", region_name="eu-west-1")

response = client.converse(
    modelId="eu.anthropic.claude-sonnet-4-5-20250929-v1:0",
    messages=[
        {
            "role": "user",
            "content": [{"text": "Say hello"}]
        }
    ]
)

print(response)
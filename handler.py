import json
import boto3
from pymongo import MongoClient

# Create SSM client once
ssm = boto3.client('ssm')

def get_mongo_uri():
    """Fetch the MongoDB URI from SSM Parameter Store"""
    response = ssm.get_parameter(
        Name='/coventry-sim/MONGODB_URI',
        WithDecryption=True
    )
    return response['Parameter']['Value']

def lambda_handler(event, context):
    # Get HTTP method from API Gateway event
    method = event.get("requestContext", {}).get("http", {}).get("method", "GET")

    # Connect to MongoDB
    client = MongoClient(get_mongo_uri())
    db = client["coventrydb"]
    coll = db["messages"]

    # Handle POST request -> insert document
    if method == "POST":
        body = json.loads(event.get("body", "{}"))
        name = body.get("name", "Anonymous")
        doc = {"name": name}
        coll.insert_one(doc)
        return {
            "statusCode": 200,
            "body": json.dumps({"message": f"Saved {name} to MongoDB ✅"})
        }

    # Handle GET request -> return all documents
    elif method == "GET":
        docs = list(coll.find({}, {"_id": 0}))
        return {
            "statusCode": 200,
            "body": json.dumps(docs)
        }

    # Unsupported methods
    else:
        return {
            "statusCode": 405,
            "body": "Method Not Allowed"
        }

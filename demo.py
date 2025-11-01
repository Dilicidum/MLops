
import requests
import json

API_URL = "http://localhost:5000"


def demo():
    print("=" * 60)
    print(" DYNAMIC PRICING API DEMO")
    print("=" * 60)

    print("\n1. Health Check")
    response = requests.get(f"{API_URL}/health")
    print(f"   Status: {response.json()['status']}")
    print(f"   Model Loaded: {response.json()['model_loaded']}")

    print("\n2. Get Product Price (GET)")
    response = requests.get(f"{API_URL}/Model/v1/Products/1")
    if response.status_code == 200:
        print(f"   Product 1 current price: ${response.json().get('current_price', 'N/A')}")
    else:
        print(f"   Product not found (expected for new database)")

    print("\n3. Predict Optimal Price (POST)")
    data = {
        "current_price": 25.99,
        "competitor_price": 24.50,
        "inventory_level": 150,
        "sales_last_7_days": 45,
        "day_of_week": 3,
        "is_promotion": 0
    }
    response = requests.post(
        f"{API_URL}/Model/v1/Products/1",
        json=data
    )
    result = response.json()
    print(f"   Current Price: ${data['current_price']}")
    print(f"   Recommended Price: ${result['recommended_price']:.2f}")
    print(f"   Price Change: {result['price_change']:.1f}%")

    print("\n4. Batch Prediction")
    batch_data = {
        "products": [
            {
                "product_id": 1,
                "current_price": 10.00,
                "competitor_price": 9.50,
                "inventory_level": 200,
                "sales_last_7_days": 30
            },
            {
                "product_id": 2,
                "current_price": 50.00,
                "competitor_price": 52.00,
                "inventory_level": 50,
                "sales_last_7_days": 10
            },
            {
                "product_id": 3,
                "current_price": 25.00,
                "competitor_price": 24.00,
                "inventory_level": 300,
                "sales_last_7_days": 60
            }
        ]
    }
    response = requests.post(f"{API_URL}/batch_predict", json=batch_data)
    results = response.json()['predictions']

    print(f"   Processed {len(results)} products:")
    for item in results:
        change = (item['recommended_price'] - item['current_price']) / item['current_price'] * 100
        print(
            f"   - Product {item['product_id']}: ${item['current_price']:.2f} → ${item['recommended_price']:.2f} ({change:+.1f}%)")

    print("\n5. Update Product Price (PUT)")
    update_data = {"price": 29.99}
    response = requests.put(
        f"{API_URL}/Model/v1/Products/1",
        json=update_data
    )
    if response.status_code == 200:
        print(f"   Product 1 price updated to ${update_data['price']}")

    print("\n6. Trigger Model Retraining (POST)")
    print("   Sending retrain request...")
    print("   Retrain request would be sent (skipped for demo speed)")

    print("\n" + "=" * 60)
    print(" DEMO COMPLETE")
    print("=" * 60)


if __name__ == "__main__":
    try:
        demo()
    except requests.exceptions.ConnectionError:
        print("   Cannot connect to API. Please ensure it's running:")
        print("   python api.py")
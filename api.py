
from flask import Flask, request, jsonify
import pickle
import pandas as pd
import numpy as np
import yaml
from pathlib import Path
import sqlite3
from datetime import datetime

app = Flask(__name__)

with open('config.yaml', 'r') as f:
    config = yaml.safe_load(f)


model = None
scaler = None
feature_cols = None


def load_model():
    global model, scaler, feature_cols

    model_path = Path("models/pricing_model.pkl")
    if model_path.exists():
        with open(model_path, 'rb') as f:
            artifacts = pickle.load(f)
            model = artifacts['model']
            scaler = artifacts['scaler']
            feature_cols = artifacts['feature_cols']
        return True
    return False


if not load_model():
    print("⚠️  No model found. Please run train_model.py first")


@app.route('/health', methods=['GET'])
def health_check():
    return jsonify({
        'status': 'healthy',
        'model_loaded': model is not None,
        'timestamp': datetime.now().isoformat()
    })


@app.route('/Model/<version>/Products/<int:product_id>', methods=['GET'])
def get_product_price(version, product_id):
    if model is None:
        return jsonify({'error': 'Model not loaded'}), 503

    conn = sqlite3.connect(config['data']['database'])
    cursor = conn.cursor()

    cursor.execute(
        "SELECT current_price FROM training_data WHERE product_id = ? LIMIT 1",
        (product_id,)
    )
    result = cursor.fetchone()
    conn.close()

    if result:
        return jsonify({
            'product_id': product_id,
            'current_price': result[0],
            'model_version': version
        })
    else:
        return jsonify({'error': f'Product {product_id} not found'}), 404


@app.route('/Model/<version>/Products/<int:product_id>', methods=['POST'])
def predict_price(version, product_id):
    if model is None:
        return jsonify({'error': 'Model not loaded'}), 503

    try:
        data = request.json

        features = pd.DataFrame([{
            'current_price': data.get('current_price', 10.0),
            'competitor_price': data.get('competitor_price', 10.0),
            'inventory_level': data.get('inventory_level', 100),
            'sales_last_7_days': data.get('sales_last_7_days', 20),
            'day_of_week': data.get('day_of_week', 0),
            'is_promotion': data.get('is_promotion', 0)
        }])

        features_scaled = scaler.transform(features[feature_cols])
        predicted_price = model.predict(features_scaled)[0]

        min_price = data.get('min_price', config['pricing']['min_price'])
        max_price = data.get('max_price', config['pricing']['max_price'])
        predicted_price = np.clip(predicted_price, min_price, max_price)

        return jsonify({
            'product_id': product_id,
            'recommended_price': float(predicted_price),
            'current_price': data.get('current_price', 10.0),
            'price_change': float(
                (predicted_price - data.get('current_price', 10.0)) / data.get('current_price', 10.0) * 100),
            'model_version': version,
            'timestamp': datetime.now().isoformat()
        })

    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/Model/<version>/Products/<int:product_id>', methods=['PUT'])
def update_product_price(version, product_id):
    try:
        data = request.json
        new_price = data.get('price')

        if new_price is None:
            return jsonify({'error': 'Price not provided'}), 400

        conn = sqlite3.connect(config['data']['database'])
        cursor = conn.cursor()
        cursor.execute(
            "UPDATE training_data SET current_price = ? WHERE product_id = ?",
            (new_price, product_id)
        )
        conn.commit()
        conn.close()

        return jsonify({
            'product_id': product_id,
            'new_price': new_price,
            'status': 'updated'
        })

    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/Model/<version>/Products/<int:product_id>', methods=['DELETE'])
def delete_product(version, product_id):
    try:
        conn = sqlite3.connect(config['data']['database'])
        cursor = conn.cursor()
        cursor.execute("DELETE FROM training_data WHERE product_id = ?", (product_id,))
        conn.commit()
        rows_deleted = cursor.rowcount
        conn.close()

        if rows_deleted > 0:
            return jsonify({
                'product_id': product_id,
                'status': 'deleted'
            })
        else:
            return jsonify({'error': f'Product {product_id} not found'}), 404

    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/Model/<version>/retrain', methods=['POST'])
def retrain_model(version):
    try:
        import subprocess
        result = subprocess.run(['python', 'train_model.py'], capture_output=True, text=True)

        if result.returncode == 0:
            load_model()
            return jsonify({
                'status': 'success',
                'message': 'Model retrained successfully',
                'version': version,
                'timestamp': datetime.now().isoformat()
            })
        else:
            return jsonify({
                'status': 'failed',
                'error': result.stderr
            }), 500

    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/batch_predict', methods=['POST'])
def batch_predict():
    if model is None:
        return jsonify({'error': 'Model not loaded'}), 503

    try:
        products = request.json.get('products', [])
        results = []

        for product in products:
            features = pd.DataFrame([{
                'current_price': product.get('current_price', 10.0),
                'competitor_price': product.get('competitor_price', 10.0),
                'inventory_level': product.get('inventory_level', 100),
                'sales_last_7_days': product.get('sales_last_7_days', 20),
                'day_of_week': product.get('day_of_week', 0),
                'is_promotion': product.get('is_promotion', 0)
            }])

            features_scaled = scaler.transform(features[feature_cols])
            predicted_price = model.predict(features_scaled)[0]

            results.append({
                'product_id': product.get('product_id'),
                'recommended_price': float(predicted_price),
                'current_price': product.get('current_price', 10.0)
            })

        return jsonify({
            'predictions': results,
            'count': len(results),
            'timestamp': datetime.now().isoformat()
        })

    except Exception as e:
        return jsonify({'error': str(e)}), 500


if __name__ == '__main__':
    app.run(
        host=config['api']['host'],
        port=config['api']['port'],
        debug=True
    )
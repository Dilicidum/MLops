
import pandas as pd
import numpy as np
import sqlite3
import yaml
import os
import pickle
from pathlib import Path
from sklearn.model_selection import train_test_split
from sklearn.preprocessing import StandardScaler
from sklearn.metrics import mean_absolute_error, mean_squared_error, r2_score
import xgboost as xgb
import mlflow
import mlflow.xgboost
from datetime import datetime

with open('config.yaml', 'r') as f:
    config = yaml.safe_load(f)

tracking_uri = os.getenv("MLFLOW_TRACKING_URI", config['mlflow']['tracking_uri'])
mlflow.set_tracking_uri(tracking_uri)
experiment_name = os.getenv("MLFLOW_EXPERIMENT", config['mlflow']['experiment_name'])
mlflow.set_experiment(experiment_name)


def load_data_from_db():
    conn = sqlite3.connect(config['data']['database'])

    cursor = conn.cursor()
    cursor.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='training_data'")

    if cursor.fetchone() is None:
        print("Creating sample training data...")
        create_sample_data(conn)

    query = "SELECT * FROM training_data"
    df = pd.read_sql_query(query, conn)
    conn.close()

    return df


def create_sample_data(conn):
    np.random.seed(42)
    n_samples = 10000

    data = pd.DataFrame({
        'product_id': np.random.randint(1, 100, n_samples),
        'current_price': np.random.uniform(5, 100, n_samples),
        'competitor_price': np.random.uniform(5, 100, n_samples),
        'inventory_level': np.random.randint(0, 500, n_samples),
        'sales_last_7_days': np.random.randint(0, 100, n_samples),
        'day_of_week': np.random.randint(0, 7, n_samples),
        'is_promotion': np.random.choice([0, 1], n_samples, p=[0.8, 0.2])
    })

    base_price = data['current_price']
    demand_factor = 1 + (data['sales_last_7_days'] - 50) / 100
    competition_factor = data['competitor_price'] / data['current_price']
    inventory_factor = 1 - (data['inventory_level'] - 250) / 500

    data['optimal_price'] = (
            base_price * demand_factor * competition_factor * inventory_factor
    ).clip(config['pricing']['min_price'], config['pricing']['max_price'])

    data.to_sql('training_data', conn, if_exists='replace', index=False)
    print(f"Created {len(data)} training samples")


def prepare_features(df):
    feature_cols = [
        'current_price', 'competitor_price', 'inventory_level',
        'sales_last_7_days', 'day_of_week', 'is_promotion'
    ]

    X = df[feature_cols]
    y = df['optimal_price']

    return X, y, feature_cols


def train_model():
    print("Starting model training...")

    with mlflow.start_run():
        df = load_data_from_db()
        X, y, feature_cols = prepare_features(df)

        X_train, X_test, y_train, y_test = train_test_split(
            X, y, test_size=0.2, random_state=42
        )

        scaler = StandardScaler()
        X_train_scaled = scaler.fit_transform(X_train)
        X_test_scaled = scaler.transform(X_test)

        mlflow.log_param("n_samples", len(df))
        mlflow.log_param("n_features", len(feature_cols))
        mlflow.log_param("test_size", 0.2)

        model = xgb.XGBRegressor(**config['model']['params'])
        model.fit(X_train_scaled, y_train)

        for param, value in config['model']['params'].items():
            mlflow.log_param(f"model_{param}", value)

        train_pred = model.predict(X_train_scaled)
        test_pred = model.predict(X_test_scaled)

        train_mae = mean_absolute_error(y_train, train_pred)
        train_rmse = np.sqrt(mean_squared_error(y_train, train_pred))
        train_r2 = r2_score(y_train, train_pred)

        test_mae = mean_absolute_error(y_test, test_pred)
        test_rmse = np.sqrt(mean_squared_error(y_test, test_pred))
        test_r2 = r2_score(y_test, test_pred)

        mlflow.log_metric("train_mae", train_mae)
        mlflow.log_metric("train_rmse", train_rmse)
        mlflow.log_metric("train_r2", train_r2)
        mlflow.log_metric("test_mae", test_mae)
        mlflow.log_metric("test_rmse", test_rmse)
        mlflow.log_metric("test_r2", test_r2)

        print(f"Training MAE: {train_mae:.2f}")
        print(f"Test MAE: {test_mae:.2f}")
        print(f"Test R2: {test_r2:.3f}")

        model_dir = Path("models")
        model_dir.mkdir(exist_ok=True)

        model_path = model_dir / "pricing_model.pkl"
        with open(model_path, 'wb') as f:
            pickle.dump({
                'model': model,
                'scaler': scaler,
                'feature_cols': feature_cols,
                'config': config
            }, f)

        mlflow.xgboost.log_model(model, "model")
        mlflow.log_artifact(str(model_path))

        scaler_path = model_dir / "scaler.pkl"
        with open(scaler_path, 'wb') as f:
            pickle.dump(scaler, f)
        mlflow.log_artifact(str(scaler_path))

        print(f"Model saved to {model_path}")
        print(f"MLFlow run ID: {mlflow.active_run().info.run_id}")

        return model, scaler, feature_cols


if __name__ == "__main__":
    Path("data").mkdir(exist_ok=True)
    Path("models").mkdir(exist_ok=True)
    Path("mlruns").mkdir(exist_ok=True)

    model, scaler, features = train_model()
    print("\n  Model training completed")
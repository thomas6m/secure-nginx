import requests
from flask import Flask, jsonify

app = Flask(__name__)

@app.route('/proxy', methods=['GET'])
def proxy():
    """Proxy endpoint that calls App2 using mTLS."""
    try:
        response = requests.get(
            'https://app2-service:5002/data',
            cert=('/certs/app1.crt', '/certs/app1.key'),
            verify='/certs/ca.crt'
        )
        return jsonify({"app2_response": response.json()}), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/healthz', methods=['GET'])
def healthz():
    """Health check endpoint for Kubernetes probes."""
    return "OK", 200

if __name__ == '__main__':
    app.run(
        host='0.0.0.0',
        port=5001,
        ssl_context=('/certs/app1.crt', '/certs/app1.key')
    )

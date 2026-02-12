from flask import Flask

app = Flask(__name__)

@app.route('/data', methods=['GET'])
def data():
    """Returns data — accessed by App1 via mTLS."""
    return {"message": "Response from App2 over mTLS"}, 200

@app.route('/healthz', methods=['GET'])
def healthz():
    """Health check endpoint for Kubernetes probes."""
    return "OK", 200

if __name__ == '__main__':
    # Flask runs plain HTTP — Nginx sidecar handles TLS/mTLS termination
    app.run(host='0.0.0.0', port=5000)

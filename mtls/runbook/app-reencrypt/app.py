from flask import Flask, jsonify
import ssl

app = Flask(__name__)

@app.route('/')
def hello():
    return jsonify({"message": "Hello from Flask with re-encrypt TLS!"})

@app.route('/healthz')
def healthz():
    return "OK", 200

if __name__ == "__main__":
    context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    context.load_cert_chain(certfile='/certs/server.crt', keyfile='/certs/server.key')
    context.load_verify_locations(cafile='/certs/ca.crt')
    context.verify_mode = ssl.CERT_OPTIONAL

    app.run(host='0.0.0.0', port=5000, ssl_context=context)

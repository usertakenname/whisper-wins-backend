import subprocess
import time
from flask import Flask, request, jsonify

app = Flask(__name__)

""" @app.route('/start-auction', methods=['GET', 'POST'])
def start_auction():
    # Optional: Check request data (if needed)
    if request.method == 'POST':
        data = request.get_json()  # Retrieve JSON data from the POST request
        print("Received data:", data)
        result = subprocess.run(["go", "run", "script.go", data.get("contract")], capture_output=True, text=True)
        return jsonify({"message": result.stdout, "error": result.stderr})  # Return a response

    else:
         return jsonify({"message": "No data provided"})  # Return a response """

@app.route('/reveal-bidders', methods=['POST'])
def reveal_bidders():
    # Optional: Check request data (if needed)
    data = request.get_json()  # Retrieve JSON data from the POST request
    print("Received data:", data)
    timeout = int(data.get("timeout"))
    time.sleep(timeout) # waits x seconds before executing the script
    result = subprocess.run(["go", "run", "./server/script.go", data.get("contract")], capture_output=True, text=True)
    return jsonify({"Winner": result.stdout, "Loser": result.stderr})  # Return a response


if __name__ == '__main__':
    app.run(debug=True, port=8001)  # Run on port 8001

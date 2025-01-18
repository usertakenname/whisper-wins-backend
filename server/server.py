import sched
import subprocess
import time
from datetime import datetime
from flask import Flask, request, jsonify

scheduler = sched.scheduler(time.time, time.sleep)
app = Flask(__name__)

def execute_script(contract_address):
    print("Executing script for contract: ", contract_address)
    result = subprocess.run(["go", "run", "./server/script.go", contract_address], capture_output=True, text=True)
    print("Error output: ", result.stderr)
    print("Winner: ", result.stdout) # Return winner


@app.route('/register-contract', methods=['POST'])
def register_contract():
    data = request.get_json()
    print("Received register request:", data)
    exec_unix_timestamp = int(data.get("end_timestamp")) + 5 # add some puffer seconds
    delay = (datetime.utcfromtimestamp(exec_unix_timestamp) - datetime.now()).total_seconds()
    contract_address = data.get("address")
    if delay > 0:
        scheduler.enter(delay, 1, execute_script, (contract_address,))
        print(f"Scheduled script execution in {delay} seconds.")
        return jsonify({"result": "scheduled in {} seconds".format(delay)})
    else:
        print(f"Timestamp has already passed. Executing immediately.")
        execute_script(contract_address)
        return jsonify({"result": "executed directly"})


if __name__ == '__main__':
    scheduler.run()
    app.run(debug=True, port=8001)  # Run on port 8001





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

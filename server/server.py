import sched
import subprocess
import threading
import time
from datetime import datetime, timezone
from flask import Flask, request, jsonify

scheduler = sched.scheduler(time.time, time.sleep)
app = Flask(__name__)

def execute_script(contract_address):
    print("Executing script for contract: ", contract_address)
    result = subprocess.run(["go", "run", "./server/script.go", contract_address], capture_output=True, text=True)
    if result.stdout == "":        
        print("Error output: ", result.stderr)
        threading.Timer(10, handle_error, args=(contract_address,2)).start()
    else:
        print("Winner: ", result.stdout)

def handle_error(contract_address,rerun):
    if rerun >= 5:
        return # give up 
    print("Something went wrong the previous run. Executing script for contract: ", contract_address, " for the ",rerun, "x time")
    result = subprocess.run(["go", "run", "./server/script.go", contract_address], capture_output=True, text=True)
    if result.stdout == "":        
        print("Error output: ", result.stderr)
        threading.Timer(3, handle_error, args=(contract_address,rerun+1)).start()
    else:
        print("Winner: ", result.stdout)

# one can simply register a contract via a POST request => no DoS strategy / access control in place as this is a toy example
# => possibility for someone registering a malicious contract which exploits our contract interaction to drain our funds
@app.route('/register-contract', methods=['POST'])
def register_contract():
    data = request.get_json()
    print("Received register request:", data)
    exec_unix_timestamp = int(data.get("end_timestamp")) + 10 # add some puffer seconds
    delay = (datetime.fromtimestamp(exec_unix_timestamp, tz=timezone.utc) - datetime.now(timezone.utc)).total_seconds()
    contract_address = data.get("address")
    if delay > 0:
        threading.Timer(delay, execute_script, args=(contract_address,)).start()
        print(f"Scheduled script execution in {delay} seconds.")
        return jsonify({"result": "scheduled in {} seconds".format(delay)})
    else:
        print(f"Timestamp has already passed. Executing immediately.")
        execute_script(contract_address)
        return jsonify({"result": "executed directly"})


if __name__ == '__main__':
    scheduler.run()
    app.run(debug=True, port=8001)  # Run on port 8001

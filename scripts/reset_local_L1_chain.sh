rm -rf ./geth
geth init --datadir myDatadir genesis.json

bash ./scripts/start_local_L1_chain.sh